//! LSP 服务器：主循环、消息调度、读写分离与取消。
//!
//! - 写消息（文档同步等通知）在主循环中串行执行：`beginWrite` 取消进行中的读查询后修改 input。
//! - 读请求在 `group` 中并发执行，各自持有一个读事务；被写事务打断时回复 `ContentModified`，
//!   被 `$/cancelRequest` 取消时回复 `RequestCancelled`。

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;

const za = @import("../zig_analyzer.zig");
const types = za.lsp.types;
const jsonrpc = za.lsp.jsonrpc;
const transport = za.lsp.transport;
const offsets = za.util.offsets;
const never = za.util.assert.never;
const panic_context = za.util.panic_context;
const uri = za.base.uri;
const Vfs = za.base.Vfs;
const database = @import("../database.zig");
const Db = database.Db;
const FileText = database.inputs.FileText;
const syntax_q = database.syntax;
const live = database.live;
const ide = za.ide;
const compiler = za.diagnostics.compiler;
const ZigEnv = za.project.ZigEnv;
const Workspace = @import("Workspace.zig");
const origin = @import("origin.zig");
const ModuleGraph = za.names.ModuleGraph;
const Resolver = za.names.resolve.Resolver;
const InternPool = za.sema.InternPool;
pub const Progress = @import("progress.zig");
pub const Config = @import("Config.zig");
const SemanticCache = @import("semantic_cache.zig");
const watch = @import("watch.zig");
const client_process = @import("client_process.zig");

const log = std.log.scoped(.server);

const Server = @This();

io: Io,
gpa: Allocator,
db: Db,
vfs: Vfs,
ip: InternPool,
env: database.Env,
out: *transport.Writer,
state: State = .uninitialized,
encoding: offsets.Encoding = .utf16,
/// 并发执行中的读请求。只有主循环向其中提交任务，因此主循环可以安全地 await 它。
group: Io.Group = .init,
pending_mutex: Io.Mutex = .init,
pending: std.ArrayList(*Pending) = .empty,

/// 后台任务：项目的构建系统协议读取、诊断发布。多个线程都会向其中提交任务，
/// 而 `Io.Group` 不允许在 await 期间提交，因此只在退出时（所有项目停止后）cancel 一次；
/// 平时用 `busy` 计数判断是否空闲。
bg_group: Io.Group = .init,
/// 诊断发布队列：固定数量的 worker 依次取出，避免按文件线性的任务与读事务
publish_queue_mutex: Io.Mutex = .init,
publish_queue: std.ArrayList(PublishJob) = .empty,
publish_workers: usize = 0,
/// 排队中或正在发布的文件（受 publish_queue_mutex 保护），见 `publishFiles`
publish_files: std.AutoHashMapUnmanaged(Vfs.FileId, PublishState) = .empty,
busy_mutex: Io.Mutex = .init,
busy_cond: Io.Condition = .init,
busy: usize = 0,

/// 工作区根目录（绝对路径）：initialize 时给出，之后随 `workspace/didChangeWorkspaceFolders` 增减
roots: std.ArrayList([]u8) = .empty,
/// 与 `roots` 一一对应：根目录下是否有 build.zig（加入时同步检查，避免项目加载完成前误判；build.zig 新建或删除时
/// 更新，见 `refreshRoot`）
root_has_build: std.ArrayList(bool) = .empty,
/// 保护 `roots` 与 `root_has_build`
roots_mutex: Io.Mutex = .init,

single_mutex: Io.Mutex = .init,
/// 单文件模式（独立的 .zig 文件，见 `FileContext.detached`）的编译结果，按编译的根文件组织。结果中也有被根文件
/// import 的文件中的错误
single: std.AutoArrayHashMapUnmanaged(Vfs.FileId, SingleFile) = .empty,
/// 已取出的编译结果序号（项目的构建与单文件编译共用，见 `nextCompileGeneration`）
compile_generation: std.atomic.Value(u64) = .init(0),
env_mutex: Io.Mutex = .init,
/// 启动后在后台查询；查询完成前为 null
zig_env: ?ZigEnv = null,
/// 启动阶段已经结束：zig 环境就绪，带 build.zig 的根目录已经启动项目。此前不按单文件编译（结束时补上），
/// 项目开始加载之前还不能推迟属于项目的文件的编译（见 `projectsLoading`）
startup_done: std.atomic.Value(bool) = .init(false),
/// 不属于任何项目的文件使用的 builtin.zig（本机目标、Debug）；受 env_mutex 保护
default_builtin: ?[]u8 = null,
warned: bool = false,
workspaces_mutex: Io.Mutex = .init,
/// 各项目当前可见的实例（各持有一个引用）。在锁外使用其中的实例前先 `acquire`
workspaces: std.ArrayList(*Workspace) = .empty,
/// 已开始停止所有项目（shutdown / exit / deinit）：此后不再重启项目
shutting_down: bool = false,
/// 尚未释放的 Workspace 实例数（统计与测试用）
live_workspaces: std.atomic.Value(usize) = .init(0),

progress: Progress = .{},

/// 串行化模块图的更新，避免较旧的快照覆盖较新的
graph_mutex: Io.Mutex = .init,
/// 后台索引的代数：模块图每次更新加一
index_generation: std.atomic.Value(u64) = .init(0),
/// 配置 `sema.callsite_seeding`（经 `Env` 供 IDE 层读取）
callsite_seeding: std.atomic.Value(bool) = .init(true),
/// 统计分配器（可执行文件设置，用于 `zig-analyzer/status` 的 `heap_bytes`）
heap: ?*const za.util.mem.Counting = null,
/// 慢请求日志的阈值（毫秒，0 为关闭），来自配置 `log.slow_request_ms`
slow_request_ms: std.atomic.Value(u32) = .init(100),
/// InternPool 超过这么多 MB 时整代回收类型信息（0 为不回收），来自配置 `sema.max_intern_pool_mb`
max_intern_pool_mb: std.atomic.Value(u32) = .init(64),
/// 是否有线程正在整代回收（同时只进行一次）
sema_resetting: std.atomic.Value(bool) = .init(false),
/// 编辑触发的诊断发布的防抖（毫秒），来自配置 `diagnostics.debounce_ms`
debounce_ms: std.atomic.Value(u32) = .init(50),
/// 编辑触发的待发布文件（见 `publishDebounced`）
edits_mutex: Io.Mutex = .init,
edits: std.AutoHashMapUnmanaged(Vfs.FileId, Edit) = .empty,
/// 诊断发布在读事务之外预先算好的 live 诊断（经 `Env` 供 `AstCheck` 取用）
live_prepared: live.Prepared = undefined,
/// 是否有索引任务在运行（同时只运行一个）
indexing: std.atomic.Value(bool) = .init(false),
/// 已建立索引的文件：索引进行中时 workspace symbol 只在这些文件（与打开的文档）中查找
indexed: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty,
indexed_mutex: Io.Mutex = .init,
config_mutex: Io.Mutex = .init,
config: Config = .{},
// ── 拉取配置（只在主循环中访问）──
/// 客户端支持 `workspace/configuration`
pull_config: bool = false,
/// 客户端支持动态注册 `workspace/didChangeConfiguration`（注册后客户端在配置变化时通知，内容由服务器拉取）
register_config: bool = false,
/// 客户端支持动态注册 `workspace/didChangeWatchedFiles`（监听磁盘上的外部改动）
register_watch: bool = false,
/// 客户端支持 `workspace/inlayHint/refresh`（inlay hints 的配置变化后请客户端重新请求）
inlay_refresh: bool = false,
/// 客户端支持 `codeAction/resolve` 延后计算 `edit`（且原样带回 `data`）：命名的修复在用户选择之后才查找引用
code_action_resolve: bool = false,
/// 客户端支持代码操作的 `disabled`（显示为不可用并说明原因）
code_action_disabled: bool = false,
/// 客户端支持 `documentChanges` 中带变更注解的编辑：公开名字的改名要求用户确认
change_annotations: bool = false,
/// 客户端支持工作区语义令牌刷新；同一时间最多等待一个刷新响应。
semantic_refresh: bool = false,
semantic_refresh_mutex: Io.Mutex = .init,
semantic_refresh_pending: bool = false,
semantic_refresh_dirty: bool = false,
semantic_cache: SemanticCache = .{},
/// 已发出的拉取请求数；只采纳最近一次请求的响应
config_requests: u32 = 0,
/// 尚未收到响应的拉取请求数：等待期间计为忙碌（waitIdle 会等待配置生效）
config_outstanding: u32 = 0,
/// 首次拉取的响应到达前推迟项目启动（启动要用 zig.path 与构建参数）
startup_pending: bool = false,
/// `initialized` 已处理：LSP 规定只发送一次，重复的忽略
initialized_received: bool = false,
/// 监视客户端进程（`initialize` 的 `processId`）的后台任务
parent_watch: ?Io.Future(void) = null,
/// `parent_watch` 等待的客户端进程
parent_process: ?*client_process.Watch = null,
/// 项目已启动：此后修改 zig.path 需要重启服务器
started: bool = false,

/// 串行化修改服务器状态的消息处理：主循环处理每条消息时持有，服务器发现的外部改动也在它之下处理（见 `watch.zig`）
write_mutex: Io.Mutex = .init,
/// 未打开的已知文件在外部改动中读到、并已据此重新构建的磁盘内容（哈希；null 为不存在），见
/// `didChangeWatchedFiles`。打开文档时清除：打开期间保存的内容不经过外部改动。只在 write_mutex 下访问
watched_built: std.AutoHashMapUnmanaged(Vfs.FileId, ?u64) = .empty,
/// 服务器发现外部改动的后台任务（`startProjects` 时创建）
watcher: ?*watch.Watcher = null,
/// 原生文件监听不可用时，轮询的最短间隔（毫秒）
poll_interval_ms: std.atomic.Value(u32) = .init(1000),
/// 服务器发现的外部改动已处理的批数，测试据此等待（受 `watch_mutex` 保护，变化时广播 `watch_cond`）
watch_batches: u64 = 0,
watch_mutex: Io.Mutex = .init,
watch_cond: Io.Condition = .init,
docs_mutex: Io.Mutex = .init,
/// 已打开的文档：客户端使用的 URI（发布诊断时原样使用）
open_docs: std.AutoArrayHashMapUnmanaged(Vfs.FileId, []u8) = .empty,
/// 客户端最近一次使用的 URI：文档关闭后仍用于发布诊断（清除旧诊断、编译器重新发布），
/// 避免按内部路径重新编码 URI。虚拟文档清除后即删除
last_uris: std.AutoArrayHashMapUnmanaged(Vfs.FileId, []u8) = .empty,
/// 当前显示着非空诊断的文件（需要时发布空列表清除）
published: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty,
/// 诊断计算的序号：每次计算在读取编译结果、文本等状态之前取一个（见 `sendDiagnostics`）
publish_seq: std.atomic.Value(u64) = .init(0),
publish_mutex: Io.Mutex = .init,
/// 文件 → 已发送的诊断的序号（受 publish_mutex 保护）
sent_seq: std.AutoHashMapUnmanaged(Vfs.FileId, u64) = .empty,

pub const State = enum { uninitialized, running, shutdown };

const SingleFile = struct {
    result: ?*compiler.BuildResult = null,
    /// FileId → `result` 中的条目（根文件自身与被它 import 的文件）
    files: std.AutoArrayHashMapUnmanaged(Vfs.FileId, *const compiler.FileResult) = .empty,
    /// 得到 `result` 的那次编译读取的、根文件所在目录下的文件（含被它 import 的）：其中任何一个变化都需要重新编译
    inputs: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty,
    /// `result` 存入时取的编译结果序号：越大越新
    generation: u64 = 0,
    running: bool = false,
    rerun: bool = false,
    /// 编译被推迟（有项目尚在首次加载）：加载结束后补上（见 `reconcileSingle`）
    pending: bool = false,

    fn clearResult(sf: *SingleFile, gpa: Allocator) void {
        if (sf.result) |r| r.release(gpa);
        sf.result = null;
        sf.files.deinit(gpa);
        sf.files = .empty;
        sf.inputs.deinit(gpa);
        sf.inputs = .empty;
    }
};

const Pending = struct {
    id: jsonrpc.Id,
    cancel: std.atomic.Value(bool) = .init(false),
};

pub const HandlerError = error{
    Canceled,
    OutOfMemory,
    InvalidParams,
    /// 重命名的目标不在工作区内（标准库、依赖包）
    RenameOutsideWorkspace,
    /// 新名字不是合法的标识符
    InvalidIdentifier,
    /// 泛型函数体内的引用在一些实例下指向其他定义：重命名会破坏这些实例
    RenameAmbiguous,
    /// 名字出现在嵌套超过上限、没有分析的代码中：那里的引用无法确认，重命名会漏改
    RenameUnanalyzed,
};

/// 原地初始化：查询引擎持有指向 `server.env` 的指针，因此 Server 不能在初始化后移动。
pub fn init(server: *Server, io: Io, gpa: Allocator, out: *transport.Writer) Allocator.Error!void {
    server.* = .{ .io = io, .gpa = gpa, .db = undefined, .vfs = .init(io, gpa), .ip = try .init(gpa, io), .env = undefined, .out = out };
    server.live_prepared = .{ .gpa = gpa };
    server.env = .{ .vfs = &server.vfs, .ip = &server.ip, .callsite_seeding = &server.callsite_seeding, .live_prepared = &server.live_prepared };
    server.db = .init(io, gpa, &server.env);
}

pub fn deinit(server: *Server) void {
    if (server.parent_watch) |*f| {
        // 等待退出通知时不响应取消：先让它返回
        server.parent_process.?.stop();
        f.cancel(server.io);
        server.parent_process.?.destroy(server.gpa);
    }
    server.group.cancel(server.io);
    server.stopWorkspaces();
    server.waitIdle();
    server.bg_group.cancel(server.io);
    if (server.watcher) |w| {
        server.vfs.listener.store(null, .release);
        w.destroy();
    }
    // 后台任务都已结束，只剩列表持有的引用
    server.publish_queue.deinit(server.gpa);
    server.publish_files.deinit(server.gpa);
    for (server.workspaces.items) |ws| ws.release();
    server.workspaces.deinit(server.gpa);
    server.indexed.deinit(server.gpa);
    server.edits.deinit(server.gpa);
    server.live_prepared.deinit();
    za.util.log.setFile(null) catch {};
    for (server.roots.items) |r| server.gpa.free(r);
    server.roots.deinit(server.gpa);
    server.root_has_build.deinit(server.gpa);
    for (server.single.values()) |*sf| sf.clearResult(server.gpa);
    server.single.deinit(server.gpa);
    if (server.zig_env) |*env| env.deinit(server.gpa);
    if (server.default_builtin) |p| server.gpa.free(p);
    for (server.open_docs.values()) |u| server.gpa.free(u);
    server.open_docs.deinit(server.gpa);
    for (server.last_uris.values()) |u| server.gpa.free(u);
    server.last_uris.deinit(server.gpa);
    server.published.deinit(server.gpa);
    server.sent_seq.deinit(server.gpa);
    server.semantic_cache.deinit(server.gpa);
    server.watched_built.deinit(server.gpa);
    server.progress.deinit(server.gpa);
    server.config.deinit(server.gpa);
    server.pending.deinit(server.gpa);
    server.db.deinit();
    server.ip.deinit();
    server.vfs.deinit();
    server.* = undefined;
}

/// 运行主循环直到收到 `exit` 或输入结束，返回进程退出码。返回前停止各项目的构建系统进程，等待已调度的
/// 后台任务（诊断发布等）收尾。输入结束而未收到 `exit` 时客户端已经退出：不再等待它对服务器请求的回复。
pub fn run(server: *Server, reader: *Io.Reader) !u8 {
    var exited = false;
    while (true) {
        const arena = try server.gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(server.gpa);
        // 消息体分配在 arena 上：解析出的字符串可能直接引用它，需与请求同生命周期
        const body = transport.readMessage(reader, arena.allocator()) catch |err| {
            server.destroyArena(arena);
            switch (err) {
                error.EndOfStream => break,
                else => {
                    log.err("failed to read message: {t}", .{err});
                    break;
                },
            }
        };
        if (try server.processMessage(arena, body) == .exit) {
            exited = true;
            break;
        }
    }
    server.group.await(server.io) catch {};
    if (!exited) server.abandonConfigRequests();
    server.stopWorkspaces();
    server.waitIdle();
    return if (server.state == .shutdown) 0 else 1;
}

/// 不再等待客户端对配置请求的回复（关闭时，或客户端已经退出）
fn abandonConfigRequests(server: *Server) void {
    server.startup_pending = false;
    while (server.config_outstanding > 0) : (server.config_outstanding -= 1) server.busyEnd();
}

/// 每隔这么久检查一次客户端进程是否还在
/// 监视客户端进程：它退出后服务器随之退出（见 `client_process.zig`）。在主循环中创建监视，之后的停止不会丢失
fn watchParent(server: *Server, pid: i32) void {
    if (pid <= 0 or server.parent_watch != null) return;
    const w = client_process.Watch.create(server.gpa, server.io, pid) catch
        return log.warn("cannot watch the client process {d}: out of memory", .{pid});
    server.parent_watch = server.io.concurrent(parentWatcher, .{ server, w }) catch |err| {
        w.destroy(server.gpa);
        return log.warn("cannot watch the client process {d}: {t}", .{ pid, err });
    };
    server.parent_process = w;
}

fn parentWatcher(server: *Server, w: *client_process.Watch) void {
    if (w.wait() == .stopped) return;
    log.warn("client process {d} has exited, exiting", .{w.pid});
    server.stopWorkspaces();
    std.process.exit(1);
}

const Flow = enum { @"continue", exit };

/// 处理一条消息；`arena` 的所有权转交给本函数。
fn processMessage(server: *Server, arena: *std.heap.ArenaAllocator, body: []const u8) !Flow {
    const a = arena.allocator();
    const message = jsonrpc.parse(a, body) catch |err| {
        server.destroyArena(arena);
        if (err == error.OutOfMemory) return err;
        server.sendError(null, jsonrpc.error_codes.parse_error, "failed to parse JSON-RPC message");
        return .@"continue";
    };
    server.write_mutex.lockUncancelable(server.io);
    defer server.write_mutex.unlock(server.io);
    var pc: panic_context.Text = .{};
    switch (message) {
        .request => |req| messageContext(&pc, "request", req.method, req.params),
        .notification => |n| messageContext(&pc, "notification", n.method, n.params),
        .response => pc.enter("response", .{}),
    }
    defer pc.leave();
    switch (message) {
        .request => |req| try server.processRequest(arena, req.id, req.method, req.params),
        .notification => |n| {
            defer server.destroyArena(arena);
            return server.processNotification(a, n.method, n.params);
        },
        .response => |resp| {
            defer server.destroyArena(arena);
            if (resp.id) |id| switch (id) {
                .integer => |i| _ = server.progress.handleResponse(server, i, resp.@"error" == null),
                .string => |s| if (std.mem.startsWith(u8, s, config_request_prefix)) {
                    try server.handleConfigResponse(s, resp.result, resp.@"error" != null);
                } else if (std.mem.eql(u8, s, semantic_refresh_id)) {
                    server.semanticRefreshFinished();
                },
            };
        },
    }
    return .@"continue";
}

/// panic 上下文中的消息：种类、方法，以及参数中的文档
fn messageContext(pc: *panic_context.Text, kind: []const u8, method: []const u8, params: json.Value) void {
    const document_uri: ?[]const u8 = blk: {
        if (params != .object) break :blk null;
        const doc = params.object.get("textDocument") orelse break :blk null;
        if (doc != .object) break :blk null;
        const u = doc.object.get("uri") orelse break :blk null;
        break :blk if (u == .string) u.string else null;
    };
    if (document_uri) |u| pc.enter("{s} {s} {s}", .{ kind, method, u }) else pc.enter("{s} {s}", .{ kind, method });
}

/// panic 上下文中的读请求：方法，以及参数中的文档与位置（行列从 1 开始）
fn requestContext(pc: *panic_context.Text, comptime method: []const u8, params: anytype) void {
    const P = @TypeOf(params);
    if (@typeInfo(P) != .@"struct" or !@hasField(P, "textDocument")) return pc.enter("request {s}", .{method});
    const doc = params.textDocument.uri;
    if (@hasField(P, "position")) {
        return pc.enter("request {s} {s}:{d}:{d}", .{ method, doc, params.position.line + 1, params.position.character + 1 });
    }
    if (@hasField(P, "range")) {
        return pc.enter("request {s} {s}:{d}:{d}", .{ method, doc, params.range.start.line + 1, params.range.start.character + 1 });
    }
    pc.enter("request {s} {s}", .{ method, doc });
}

// ── 请求 ─────────────────────────────────────────────────────────────

const Mode = enum {
    /// 在主循环中同步执行（改变服务器状态的请求）
    sync,
    /// 在独立线程中持有读事务并发执行
    read,
    /// 在独立任务中执行，不持有读事务（会长时间等待的请求，不能阻塞主循环）
    background,
    /// 同 `read`，处理函数通过 Resolver 做名字解析与类型查询
    semantic,
};

const request_handlers = .{
    .{ "initialize", Mode.sync, initialize },
    .{ "shutdown", Mode.sync, shutdown },
    .{ "zig-analyzer/waitIdle", Mode.background, waitIdleRequest },
    .{ "zig-analyzer/status", Mode.read, status },
    .{ "zig-analyzer/fileStatus", Mode.read, fileStatus },
    .{ "zig-analyzer/syntaxTree", Mode.read, syntaxTree },
    .{ "zig-analyzer/moduleGraph", Mode.read, moduleGraph },
    .{ "zig-analyzer/reloadWorkspace", Mode.sync, reloadWorkspace },
    .{ "textDocument/formatting", Mode.read, formatting },
    .{ "textDocument/documentSymbol", Mode.read, documentSymbol },
    .{ "textDocument/foldingRange", Mode.read, foldingRange },
    .{ "textDocument/selectionRange", Mode.read, selectionRange },
    .{ "textDocument/semanticTokens/full", Mode.semantic, semanticTokensFull },
    .{ "textDocument/semanticTokens/full/delta", Mode.semantic, semanticTokensDelta },
    .{ "textDocument/semanticTokens/range", Mode.semantic, semanticTokensRange },
    .{ "textDocument/definition", Mode.semantic, definition },
    .{ "textDocument/declaration", Mode.semantic, declaration },
    .{ "textDocument/typeDefinition", Mode.semantic, typeDefinition },
    .{ "textDocument/completion", Mode.semantic, completion },
    .{ "textDocument/hover", Mode.semantic, hover },
    .{ "textDocument/signatureHelp", Mode.semantic, signatureHelp },
    .{ "textDocument/inlayHint", Mode.semantic, inlayHint },
    .{ "textDocument/references", Mode.semantic, references },
    .{ "textDocument/documentHighlight", Mode.semantic, documentHighlight },
    .{ "textDocument/prepareRename", Mode.semantic, prepareRename },
    .{ "textDocument/rename", Mode.semantic, rename },
    .{ "workspace/symbol", Mode.semantic, workspaceSymbol },
    .{ "textDocument/codeAction", Mode.semantic, codeAction },
    .{ "codeAction/resolve", Mode.semantic, codeActionResolve },
};

fn processRequest(server: *Server, arena: *std.heap.ArenaAllocator, id: jsonrpc.Id, method: []const u8, params_value: json.Value) !void {
    const a = arena.allocator();
    // 字符串 ID 引用 arena 中的内存：错误响应须在释放 arena 之前序列化，因此错误出口都用 defer 释放
    inline for (request_handlers) |h| {
        if (std.mem.eql(u8, method, h[0])) {
            const is_initialize = comptime std.mem.eql(u8, h[0], "initialize");
            if (server.state == .uninitialized and !is_initialize) {
                defer server.destroyArena(arena);
                return server.sendError(id, jsonrpc.error_codes.server_not_initialized, "server not initialized");
            }
            if (server.state != .uninitialized and is_initialize or server.state == .shutdown) {
                defer server.destroyArena(arena);
                return server.sendError(id, jsonrpc.error_codes.invalid_request, "request not allowed in current state");
            }

            const func = h[2];
            const Params = LastParam(@TypeOf(func));
            const params = jsonrpc.parseParams(Params, a, params_value) catch |err| {
                defer server.destroyArena(arena);
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return server.sendError(id, jsonrpc.error_codes.invalid_params, "malformed params");
            };

            switch (h[1]) {
                .sync => {
                    defer server.destroyArena(arena);
                    const result = func(server, a, params) catch |err| return server.sendHandlerError(id, err, false);
                    server.sendResponse(id, result);
                },
                .read, .semantic => {
                    const pending = server.addPending(a, id) catch |err| {
                        defer server.destroyArena(arena);
                        server.sendError(id, jsonrpc.error_codes.internal_error, "out of memory");
                        return err;
                    };
                    const Task = if (h[1] == .read) ReadTask(func, h[0]) else SemanticTask(func, h[0]);
                    // semantic 必须在独立线程中执行：`async` 在线程数达到上限（CPU 核数 - 1，长期阻塞的项目任务
                    // 也占名额）时会在主循环中同步执行，而后台请求会等待需要主循环处理的消息（如配置拉取的响应），导致死锁
                    spawn(server.io, &server.group, Task.run, .{ server, arena, pending, params });
                },
                .background => server.group.concurrent(server.io, BackgroundTask(func).run, .{ server, arena, id, params }) catch {
                    defer server.destroyArena(arena);
                    server.sendError(id, jsonrpc.error_codes.internal_error, "failed to start background task");
                },
            }
            return;
        }
    }
    defer server.destroyArena(arena);
    server.sendError(id, jsonrpc.error_codes.method_not_found, "method not supported");
}

/// 登记进行中的请求（可被 `$/cancelRequest` 取消）；Pending 分配在请求的 arena 中
fn addPending(server: *Server, a: Allocator, id: jsonrpc.Id) !*Pending {
    const pending = try a.create(Pending);
    pending.* = .{ .id = id };
    server.pending_mutex.lockUncancelable(server.io);
    defer server.pending_mutex.unlock(server.io);
    try server.pending.append(server.gpa, pending);
    return pending;
}

/// 在独立线程中执行任务。不用 `async`：线程数达到上限（CPU 核数 - 1，长期阻塞的项目任务也占名额）时
/// 它在调用方同步执行，主循环中执行期间收不到 `$/cancelRequest`，后续请求排队。`concurrent` 默认
/// 没有数量上限，只在无法创建线程时失败，这时退回 `async`
fn spawn(io: Io, group: *Io.Group, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) void {
    group.concurrent(io, function, args) catch group.async(io, function, args);
}

/// 处理函数最后一个参数即请求参数类型
fn LastParam(comptime F: type) type {
    const param_types = @typeInfo(F).@"fn".param_types;
    return param_types[param_types.len - 1].?;
}

fn BackgroundTask(comptime func: anytype) type {
    const Params = LastParam(@TypeOf(func));
    return struct {
        fn run(server: *Server, arena: *std.heap.ArenaAllocator, id: jsonrpc.Id, params: Params) Io.Cancelable!void {
            defer server.destroyArena(arena);
            const result = func(server, arena.allocator(), params) catch |err| return server.sendHandlerError(id, err, false);
            server.sendResponse(id, result);
        }
    };
}

fn ReadTask(comptime func: anytype, comptime method: []const u8) type {
    const Params = LastParam(@TypeOf(func));
    return struct {
        fn run(server: *Server, arena: *std.heap.ArenaAllocator, pending: *Pending, params: Params) Io.Cancelable!void {
            defer {
                server.removePending(pending);
                server.destroyArena(arena);
                // 读事务已结束：有 query 超出缓存容量且没有其他读事务时淘汰
                if (server.db.wantsSweep()) _ = server.db.trySweep();
                server.maybeResetSema();
            }
            const a = arena.allocator();
            var ctx = server.db.beginRead(a);
            ctx.cancel = &pending.cancel;
            defer ctx.end();
            var trace: za.db.Trace = .{ .gpa = a };
            ctx.trace = &trace;
            var pc: panic_context.Text = .{};
            requestContext(&pc, method, params);
            defer pc.leave();
            const zone = za.util.tracy.zone(@src(), method);
            defer zone.end();
            const t0 = Io.Clock.awake.now(server.io);
            defer server.reportIfSlow(&ctx, method, t0, &trace);

            const result = func(server, &ctx, a, params) catch |err| {
                return server.sendHandlerError(pending.id, err, pending.cancel.load(.acquire));
            };
            // 处理函数可能以回退值吞掉了 `Canceled`（如类型渲染中的 `catch null`），结果不完整
            ctx.checkCanceled() catch |err| return server.sendHandlerError(pending.id, err, pending.cancel.load(.acquire));
            server.sendResponse(pending.id, result);
        }
    };
}

/// 同 ReadTask，处理函数拿到的是 Resolver
fn SemanticTask(comptime func: anytype, comptime method: []const u8) type {
    const Params = LastParam(@TypeOf(func));
    return struct {
        fn run(server: *Server, arena: *std.heap.ArenaAllocator, pending: *Pending, params: Params) Io.Cancelable!void {
            defer {
                server.removePending(pending);
                server.destroyArena(arena);
                // 读事务已结束：有 query 超出缓存容量且没有其他读事务时淘汰
                if (server.db.wantsSweep()) _ = server.db.trySweep();
                server.maybeResetSema();
            }
            const a = arena.allocator();
            var ctx = server.db.beginRead(a);
            ctx.cancel = &pending.cancel;
            defer ctx.end();
            var trace: za.db.Trace = .{ .gpa = a };
            ctx.trace = &trace;
            var pc: panic_context.Text = .{};
            requestContext(&pc, method, params);
            defer pc.leave();
            const zone = za.util.tracy.zone(@src(), method);
            defer zone.end();
            const t0 = Io.Clock.awake.now(server.io);
            defer server.reportIfSlow(&ctx, method, t0, &trace);
            var r: Resolver = .{ .ctx = &ctx, .arena = a };
            const result = func(server, &r, a, params) catch |err| {
                return server.sendHandlerError(pending.id, err, pending.cancel.load(.acquire));
            };
            // 同 ReadTask：吞掉 `Canceled` 的处理函数结果不完整
            ctx.checkCanceled() catch |err| return server.sendHandlerError(pending.id, err, pending.cancel.load(.acquire));
            if (comptime isOutcome(@TypeOf(result))) switch (result) {
                .ok => |v| server.sendResponse(pending.id, v),
                .failed => |message| server.sendError(pending.id, jsonrpc.error_codes.request_failed, message),
            } else server.sendResponse(pending.id, result);
        }
    };
}

/// 处理函数的结果：成功，或失败的原因（以 `request_failed` 回复，客户端把原因显示给用户）
fn Outcome(comptime T: type) type {
    return union(enum) {
        ok: T,
        failed: []const u8,
    };
}

fn isOutcome(comptime T: type) bool {
    return @typeInfo(T) == .@"union" and @hasField(T, "ok") and @hasField(T, "failed");
}

// ── 慢请求日志 ─────────────────────────────────────────────────────

/// 请求耗时超过 `log.slow_request_ms` 时记录：按 query 汇总的自身耗时与调用树中的耗时路径。
/// 在读事务结束前调用（描述 key 时读取 ItemTree）
fn reportIfSlow(server: *Server, ctx: *Db.Ctx, method: []const u8, t0: Io.Timestamp, trace: *const za.db.Trace) void {
    // 测试中请求耗时随机器负载波动，warn 会写到 stderr，让构建输出出现误导性的 `failed command`；
    // 报告内容由直接调用 writeSlowReport 的测试覆盖
    if (@import("builtin").is_test) return;
    const threshold = server.slow_request_ms.load(.monotonic);
    if (threshold == 0) return;
    const ns: u64 = @intCast(@max(0, t0.durationTo(Io.Clock.awake.now(server.io)).nanoseconds));
    if (ns < @as(u64, threshold) * std.time.ns_per_ms) return;
    var out: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer out.deinit();
    // 调用树只展开耗时达到总耗时 2%（至少 1 ms）的节点
    server.writeSlowReport(&out.writer, ctx, trace, @max(std.time.ns_per_ms, ns / 50)) catch return;
    log.warn("slow request {s}: {d:.1} ms, {d} queries executed\n{s}", .{ method, za.db_report.ms(ns), trace.events.items.len, out.written() });
}

/// 慢请求报告中调用树的最大行数
const slow_tree_lines = 40;

/// 慢请求报告：按 query 汇总的自身耗时，与调用树中耗时不少于 `min_ns` 的节点
pub fn writeSlowReport(server: *Server, w: *std.Io.Writer, ctx: *Db.Ctx, trace: *const za.db.Trace, min_ns: u64) !void {
    const events = trace.events.items;
    // 自身耗时：先序事件中，每个事件的子事件是其后深度更大的连续事件
    var self_by_query: [Db.query_types.len]u64 = @splat(0);
    var count_by_query: [Db.query_types.len]u32 = @splat(0);
    for (events, 0..) |e, i| {
        var children: u64 = 0;
        var j = i + 1;
        while (j < events.len and events[j].depth > e.depth) : (j += 1) {
            if (events[j].depth == e.depth + 1) children += events[j].ns;
        }
        self_by_query[e.query] += e.ns -| children;
        count_by_query[e.query] += 1;
    }
    var order: [Db.query_types.len]usize = undefined;
    for (&order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, &order, &self_by_query, struct {
        fn gt(t: *const [Db.query_types.len]u64, a: usize, b: usize) bool {
            return t[a] > t[b];
        }
    }.gt);
    try w.writeAll("  by query (self time):\n");
    for (order[0..@min(order.len, 8)]) |qi| {
        if (count_by_query[qi] == 0) break;
        try w.print("    {s:<26} {d:>6}x {d:>9.1} ms\n", .{ za.db_report.shortName(queryName(qi)), count_by_query[qi], za.db_report.ms(self_by_query[qi]) });
    }
    try w.writeAll("  slowest paths:\n");
    var lines: usize = 0;
    var skip_below: ?u16 = null;
    for (events) |e| {
        if (skip_below) |d| {
            if (e.depth > d) continue;
            skip_below = null;
        }
        if (e.ns < min_ns) {
            skip_below = e.depth;
            continue;
        }
        if (lines == slow_tree_lines) {
            try w.writeAll("    ...\n");
            break;
        }
        lines += 1;
        try w.splatByteAll(' ', 4 + @as(usize, e.depth) * 2);
        try w.print("{s} ", .{za.db_report.shortName(queryName(e.query))});
        try server.describeKey(w, ctx, e.query, e.key);
        try w.print(" {d:.1} ms{s}{s}\n", .{ za.db_report.ms(e.ns), if (e.cutoff) " (cutoff)" else "", if (e.failed) " (canceled)" else "" });
    }
}

fn queryName(qi: usize) []const u8 {
    inline for (Db.query_types, 0..) |Q, i| if (i == qi) return @typeName(Q);
    unreachable;
}

/// key 的可读形式：文件取文件名，成员取「文件名:成员名」，其余字段原样输出
fn describeKey(server: *Server, w: *std.Io.Writer, ctx: *Db.Ctx, qi: usize, index: u32) !void {
    inline for (Db.query_types, 0..) |Q, i| if (i == qi) {
        if (Q.Key == void) return;
        return server.writeValue(w, ctx, server.db.keyAt(Q, index));
    };
}

fn writeValue(server: *Server, w: *std.Io.Writer, ctx: *Db.Ctx, value: anytype) !void {
    const T = @TypeOf(value);
    if (T == Vfs.FileId) return w.writeAll(std.fs.path.basename(server.vfs.path(value)));
    if (T == za.database.hir.OwnerKey) {
        try w.writeAll(std.fs.path.basename(server.vfs.path(value.file)));
        const tree = ctx.get(syntax_q.FileItemTree, value.file) catch return w.print("#{d}", .{@backingInt(value.item)});
        for (tree.items) |it| if (it.ast_id == value.item) return w.print(":{s}", .{it.name orelse "_"});
        return w.print("#{d}", .{@backingInt(value.item)});
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            try w.writeAll("{");
            inline for (info.field_names, 0..) |name, i| {
                if (i > 0) try w.writeAll(" ");
                try w.print("{s}=", .{name});
                try server.writeValue(w, ctx, @field(value, name));
            }
            try w.writeAll("}");
        },
        .optional => if (value) |v| try server.writeValue(w, ctx, v) else try w.writeAll("null"),
        .@"enum" => try w.print("{any}", .{value}),
        else => try w.print("{any}", .{value}),
    }
}

/// 与目标相关的值运算参数（指针位宽、向量与标量类型的布局规则）：取各模块的 builtin 中一致的部分，
/// 不一致的为未知（与之相关的值为未知）；没有项目模块时取默认 builtin（本机）
fn targetAbi(server: *Server, modules: []const ModuleGraph.Module, default_builtin: ?Vfs.FileId) Allocator.Error!za.sema.InternPool.Target {
    var result: za.sema.InternPool.Target = .{};
    // 参数相同的模块共用同一份 builtin，重复合并同一目标不改变结果：每份只读取、解析一次
    var seen: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty;
    defer seen.deinit(server.gpa);
    for (modules) |m| {
        const file = m.builtin orelse continue;
        if ((try seen.getOrPut(server.gpa, file)).found_existing) continue;
        const t = server.builtinTarget(file);
        if (seen.count() == 1) {
            result = t;
            continue;
        }
        if (result.pointer_bits != t.pointer_bits) result.pointer_bits = null;
        if (result.vector_abi != t.vector_abi) result.vector_abi = .unknown;
        result.scalar_abi = result.scalar_abi.merge(t.scalar_abi);
    }
    if (seen.count() != 0) return result;
    if (default_builtin) |f| return server.builtinTarget(f);
    return .{};
}

fn builtinTarget(server: *Server, file: Vfs.FileId) za.sema.InternPool.Target {
    const text = Io.Dir.cwd().readFileAlloc(server.io, server.vfs.path(file), server.gpa, .limited(4 * 1024 * 1024)) catch return .{ .pointer_bits = null, .scalar_abi = .unknown };
    defer server.gpa.free(text);
    const facts = za.project.builtin.vectorFacts(text);
    const target = za.project.builtin.target(text);
    return .{
        .pointer_bits = za.project.builtin.pointerBits(text),
        .vector_abi = if (facts) |f| .of(f.backend, f.arch, f.avx, f.avx512f, f.soft_float) else .unknown,
        .scalar_abi = if (target) |*t| .of(t) else .unknown,
    };
}

/// 汇总各项目的构建图与编译集合，更新模块图 input
pub fn updateModuleGraph(server: *Server) void {
    server.updateModuleGraphInner() catch |err| return log.err("failed to update module graph: {t}", .{err});
    // 须在写事务结束之后：索引任务可能就地执行
    server.scheduleIndexing();
}

fn updateModuleGraphInner(server: *Server) Allocator.Error!void {
    server.graph_mutex.lockUncancelable(server.io);
    defer server.graph_mutex.unlock(server.io);
    var b: ModuleGraph.Builder = .init(server.gpa, &server.vfs);
    var builder_owned = true;
    errdefer if (builder_owned) b.deinit();
    const list = try server.workspaceList(server.gpa);
    defer server.releaseList(server.gpa, list);
    for (list) |ws| {
        ws.mutex.lockUncancelable(server.io);
        defer ws.mutex.unlock(server.io);
        if (ws.model) |*m| if (ws.compile_set) |*cs| try b.add(m, cs, if (ws.resolve_set) |*e| e else null);
    }
    const std_root: ?Vfs.FileId = if (server.zigEnv()) |env| blk: {
        const p = try std.fs.path.join(server.gpa, &.{ env.std_dir, "std.zig" });
        defer server.gpa.free(p);
        break :blk try server.vfs.intern(p);
    } else null;
    const default_builtin: ?Vfs.FileId = blk: {
        server.env_mutex.lockUncancelable(server.io);
        defer server.env_mutex.unlock(server.io);
        break :blk if (server.default_builtin) |p| try server.vfs.intern(p) else null;
    };
    const t = try server.targetAbi(b.modules.items, default_builtin);
    const graph = try server.gpa.create(ModuleGraph);
    var graph_owned = true;
    errdefer if (graph_owned) server.gpa.destroy(graph);
    graph.* = try b.finish(std_root, default_builtin);
    // `finish` 把 builder 的 arena 转移给了 graph
    builder_owned = false;
    // 模块图与目标都没有变化时不开写事务：每次构建结束都会走到这里，而写事务会取消进行中的计算与请求
    // （请求以 ContentModified 失败）
    const unchanged = server.moduleGraphUnchanged(graph, t) catch |err| {
        var unused: ModuleGraph.Input.Value = graph;
        ModuleGraph.Input.deinit(&unused, server.gpa);
        graph_owned = false;
        return err;
    };
    if (unchanged) {
        var unused: ModuleGraph.Input.Value = graph;
        ModuleGraph.Input.deinit(&unused, server.gpa);
        graph_owned = false;
        return;
    }
    // 持有 graph_mutex 开写事务是安全的：没有读事务会等待它
    server.db.beginWrite();
    defer server.db.endWrite();
    // `set` 只在 key 尚未驻留时分配：先确保两个 key，之后两次 set 不会失败，也不会留下部分更新
    try server.db.ensureInput(ModuleGraph.Input, {});
    try server.db.ensureInput(za.sema.queries.TargetAbi, {});
    server.db.set(ModuleGraph.Input, {}, graph, .medium) catch unreachable;
    graph_owned = false;
    server.db.set(za.sema.queries.TargetAbi, {}, t, .medium) catch unreachable;
    server.ip.setTarget(t);
}

/// 当前的模块图与目标已与 `graph`、`t` 相同。在持有 graph_mutex 时调用：模块图只在这里写入，比较之后
/// 不会被其他人改变
fn moduleGraphUnchanged(server: *Server, graph: *const ModuleGraph, t: za.sema.InternPool.Target) Allocator.Error!bool {
    var ctx = server.db.beginRead(server.gpa);
    defer ctx.end();
    const current = ctx.get(ModuleGraph.Input, {}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // 另有写事务在等待：按有变化处理
        error.Canceled => return false,
    };
    const target = ctx.get(za.sema.queries.TargetAbi, {}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return false,
    };
    return ModuleGraph.Input.eql(current, graph) and std.meta.eql(target, t);
}

const index_progress_delay_ms = 200;

/// 每批索引的文件数：每批一个读事务，编辑（写事务）最多等一批
const index_batch = 8;

/// 后台为项目文件建立索引（文件索引、ItemTree 与成员摘要）：引用查找、workspace symbol 与调用点种子
/// 只需读取索引，不必在请求中解析全部文件。解析结果随后按 LRU 淘汰，索引保留。
///
/// 同时只运行一个任务：模块图在项目加载与构建期间会多次更新，运行中的任务不中断，做完一遍后
/// 发现模块图变了就再做一遍（已建立的索引直接命中缓存）
fn scheduleIndexing(server: *Server) void {
    _ = server.index_generation.fetchAdd(1, .monotonic);
    if (server.indexing.swap(true, .acq_rel)) return;
    server.busyBegin();
    spawn(server.io, &server.bg_group, indexTask, .{server});
}

fn indexTask(server: *Server) Io.Cancelable!void {
    defer server.busyEnd();
    while (true) {
        const generation = server.index_generation.load(.monotonic);
        server.indexOnce() catch |err| {
            server.indexing.store(false, .release);
            return err;
        };
        if (server.index_generation.load(.monotonic) != generation) continue;
        server.indexing.store(false, .release);
        // 释放标志后又有更新，且没有其他任务接手：继续
        if (server.index_generation.load(.monotonic) == generation) {
            server.requestSemanticRefresh();
            return;
        }
        if (server.indexing.swap(true, .acq_rel)) return;
    }
}

fn indexOnce(server: *Server) Io.Cancelable!void {
    var pc: panic_context.Text = .{};
    pc.enter("workspace symbol indexing", .{});
    defer pc.leave();
    var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_state.deinit();
    const files = blk: {
        var ctx = server.db.beginRead(arena_state.allocator());
        defer ctx.end();
        var r: Resolver = .{ .ctx = &ctx, .arena = arena_state.allocator() };
        break :blk za.ide_db.search.projectFiles(&r) catch return;
    };
    if (files.len == 0) return;
    // 大多数文件已有索引时一遍很快：超过一定时间才显示进度
    const t0 = Io.Clock.awake.now(server.io);
    var progress: ?*Progress.Progress = null;
    var progress_started = false;
    var done: usize = 0;
    defer if (progress) |p| server.progress.end(server, p, if (done == files.len) "Done" else "Interrupted");
    var scratch: std.heap.ArenaAllocator = .init(server.gpa);
    defer scratch.deinit();
    while (done < files.len) {
        if (server.isShuttingDown()) return;
        const end = @min(done + index_batch, files.len);
        _ = scratch.reset(.retain_capacity);
        {
            var ctx = server.db.beginRead(scratch.allocator());
            defer ctx.end();
            indexFiles(&ctx, files[done..end]) catch |err| switch (err) {
                // 被编辑打断：重试这一批
                error.Canceled => continue,
                error.OutOfMemory => return log.err("out of memory while indexing", .{}),
            };
        }
        {
            server.indexed_mutex.lockUncancelable(server.io);
            defer server.indexed_mutex.unlock(server.io);
            for (files[done..end]) |f| server.indexed.put(server.gpa, f, {}) catch {};
        }
        done = end;
        if (server.db.wantsSweep()) _ = server.db.trySweep();
        if (!progress_started and t0.durationTo(Io.Clock.awake.now(server.io)).nanoseconds > index_progress_delay_ms * std.time.ns_per_ms) {
            progress = server.progress.begin(server, "Indexing", true);
            progress_started = true;
        }
        var buf: [32]u8 = undefined;
        if (progress) |p| server.progress.report(server, p, std.fmt.bufPrint(&buf, "{d}/{d} files", .{ done, files.len }) catch null, @intCast(done * 100 / files.len));
    }
}

fn indexFiles(ctx: *Db.Ctx, files: []const Vfs.FileId) za.db.Error!void {
    for (files) |f| {
        _ = try ctx.get(za.syntax.FileIndex.Query, f);
        _ = try ctx.get(syntax_q.FileItemTree, f);
        _ = try ctx.get(syntax_q.ItemSummaries, f);
    }
}

fn removePending(server: *Server, pending: *Pending) void {
    server.pending_mutex.lockUncancelable(server.io);
    defer server.pending_mutex.unlock(server.io);
    for (server.pending.items, 0..) |p, i| {
        if (p == pending) {
            _ = server.pending.swapRemove(i);
            return;
        }
    }
}

fn cancelPending(server: *Server, id: jsonrpc.Id) void {
    server.pending_mutex.lockUncancelable(server.io);
    defer server.pending_mutex.unlock(server.io);
    for (server.pending.items) |p| {
        if (p.id.eql(id)) p.cancel.store(true, .release);
    }
}

const semantic_refresh_id = "zig-analyzer/semanticTokensRefresh";

fn openDocumentCount(server: *Server) usize {
    server.docs_mutex.lockUncancelable(server.io);
    defer server.docs_mutex.unlock(server.io);
    return server.open_docs.count();
}

/// 编辑只在防抖完成后刷新其他文档；索引只在稳定的一轮结束后刷新。
/// 等待客户端响应期间发生的变化合并为下一次刷新，不在任何读事务或状态锁内发送。
fn requestSemanticRefresh(server: *Server) void {
    if (!server.semantic_refresh or server.isShuttingDown() or server.openDocumentCount() == 0) return;
    server.semantic_refresh_mutex.lockUncancelable(server.io);
    if (server.semantic_refresh_pending) {
        server.semantic_refresh_dirty = true;
        server.semantic_refresh_mutex.unlock(server.io);
        return;
    }
    server.semantic_refresh_pending = true;
    server.semantic_refresh_mutex.unlock(server.io);
    const bytes = jsonrpc.request(server.gpa, .{ .string = semantic_refresh_id }, "workspace/semanticTokens/refresh", null) catch {
        server.semantic_refresh_mutex.lockUncancelable(server.io);
        server.semantic_refresh_pending = false;
        server.semantic_refresh_mutex.unlock(server.io);
        return log.err("out of memory while building semantic tokens refresh", .{});
    };
    server.send(bytes);
    // 写出 refresh 之后再作废：此后发出的结果都排在 refresh 之后到达客户端。先作废的话，两者之间发出的结果
    // 可能先于 refresh 到达，成为客户端刷新后 delta 请求的基线。
    server.semantic_cache.retireBaselines(server.io);
}

fn semanticRefreshFinished(server: *Server) void {
    server.semantic_refresh_mutex.lockUncancelable(server.io);
    const dirty = server.semantic_refresh_dirty;
    server.semantic_refresh_pending = false;
    server.semantic_refresh_dirty = false;
    server.semantic_refresh_mutex.unlock(server.io);
    if (dirty) server.requestSemanticRefresh();
}

// ── 通知 ─────────────────────────────────────────────────────────────

fn processNotification(server: *Server, arena: Allocator, method: []const u8, params_value: json.Value) !Flow {
    if (std.mem.eql(u8, method, "exit")) return .exit;
    // 初始化前与 shutdown 之后除 exit 外的通知一律丢弃
    if (server.state == .uninitialized or server.state == .shutdown) return .@"continue";

    const handlers = .{
        .{ "$/cancelRequest", cancelRequest },
        .{ "textDocument/didOpen", didOpen },
        .{ "textDocument/didChange", didChange },
        .{ "textDocument/didClose", didClose },
        .{ "textDocument/didSave", didSave },
        .{ "workspace/didChangeConfiguration", didChangeConfiguration },
        .{ "workspace/didChangeWatchedFiles", didChangeWatchedFiles },
        .{ "workspace/didChangeWorkspaceFolders", didChangeWorkspaceFolders },
        .{ "initialized", initialized },
    };
    inline for (handlers) |h| {
        if (std.mem.eql(u8, method, h[0])) {
            const Params = types.ParamsType(h[0]);
            const params = jsonrpc.parseParams(Params, arena, params_value) catch |err| {
                log.warn("{s}: malformed params: {t}", .{ h[0], err });
                return .@"continue";
            };
            h[1](server, arena, params) catch |err| log.err("{s} failed: {t}", .{ h[0], err });
            return .@"continue";
        }
    }
    return .@"continue";
}

fn cancelRequest(server: *Server, _: Allocator, params: types.CancelParams) !void {
    server.cancelPending(switch (params.id) {
        .integer => |i| .{ .integer = i },
        .string => |s| .{ .string = s },
    });
}

fn fileIdFromUri(server: *Server, arena: Allocator, document_uri: []const u8) !?Vfs.FileId {
    const path = try documentPath(arena, document_uri) orelse return null;
    return try server.vfs.intern(path);
}

/// 文档的路径：file URI 为其路径；`untitled:` 等非 file URI 的文档映射到虚拟目录下按 URI 命名的
/// 路径（不与真实文件冲突，磁盘上不存在，因此不交给编译器；其余功能按单文件处理）
fn documentPath(arena: Allocator, document_uri: []const u8) Allocator.Error!?[]const u8 {
    const path = uri.toPath(arena, document_uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedScheme => {
            const ext = if (std.mem.endsWith(u8, document_uri, ".zon")) ".zon" else ".zig";
            return try std.fmt.allocPrint(arena, "{s}{c}{x:0>16}{s}", .{ virtual_root, std.fs.path.sep, std.hash.Wyhash.hash(0, document_uri), ext });
        },
        error.InvalidUri => return null,
    };
    if (!std.fs.path.isAbsolute(path)) return null;
    return path;
}

/// 非 file URI 文档的虚拟目录
const virtual_root = if (@import("builtin").os.tag == .windows) "C:\\.zig-analyzer-virtual" else "/.zig-analyzer-virtual";

pub fn isVirtual(path: []const u8) bool {
    return Vfs.isUnderStyle(.native, .sensitive, path, virtual_root);
}

fn setFileText(server: *Server, id: Vfs.FileId, text: ?[]const u8) !void {
    const owned = if (text) |t| try server.gpa.dupe(u8, t) else null;
    server.db.beginWrite();
    defer server.db.endWrite();
    try server.db.set(FileText, id, owned, .low);
}

fn didOpen(server: *Server, arena: Allocator, params: types.DidOpenTextDocumentParams) !void {
    const id = try server.fileIdFromUri(arena, params.textDocument.uri) orelse return;
    {
        const owned = try server.gpa.dupe(u8, params.textDocument.uri);
        const last = try server.gpa.dupe(u8, params.textDocument.uri);
        server.docs_mutex.lockUncancelable(server.io);
        defer server.docs_mutex.unlock(server.io);
        const gop = server.open_docs.getOrPut(server.gpa, id) catch |err| {
            server.gpa.free(owned);
            server.gpa.free(last);
            return err;
        };
        if (gop.found_existing) server.gpa.free(gop.value_ptr.*);
        gop.value_ptr.* = owned;
        const lgop = server.last_uris.getOrPut(server.gpa, id) catch |err| {
            server.gpa.free(last);
            return err;
        };
        if (lgop.found_existing) server.gpa.free(lgop.value_ptr.*);
        lgop.value_ptr.* = last;
    }
    _ = server.watched_built.remove(id);
    {
        const owned = try server.gpa.dupe(u8, params.textDocument.text);
        server.db.beginWrite();
        defer server.db.endWrite();
        try server.db.set(FileText, id, owned, .low);
        // 开启新会话前先等旧读请求退出，不能继承关闭期间或旧会话的增量基线。
        server.semantic_cache.remove(server.io, server.gpa, id);
    }
    server.publishFiles(&.{id}, false);
    if (server.openDocumentCount() > 1) server.requestSemanticRefresh();
    server.compileSingle(id);
}

fn didChange(server: *Server, arena: Allocator, params: types.DidChangeTextDocumentParams) !void {
    const id = try server.fileIdFromUri(arena, params.textDocument.uri) orelse return;
    {
        server.db.beginWrite();
        defer server.db.endWrite();
        const old = server.db.peek(FileText, id) orelse "";
        const new = try offsets.applyChanges(server.gpa, old, params.contentChanges, server.encoding);
        try server.db.set(FileText, id, new, .low);
    }
    server.publishDebounced(id);
}

fn didClose(server: *Server, arena: Allocator, params: types.DidCloseTextDocumentParams) !void {
    const id = try server.fileIdFromUri(arena, params.textDocument.uri) orelse return;
    defer {
        // 即使读取磁盘或替换文本失败，也先等旧读请求退出，防止关闭后重新写入快照。
        server.db.beginWrite();
        defer server.db.endWrite();
        server.semantic_cache.remove(server.io, server.gpa, id);
    }
    // 关闭后以磁盘内容为准
    const disk = server.vfs.readFromDisk(id, arena) catch |err| switch (err) {
        error.FileTooBig => null,
        else => |e| return e,
    };
    try server.setFileText(id, disk);
    {
        server.docs_mutex.lockUncancelable(server.io);
        defer server.docs_mutex.unlock(server.io);
        if (server.open_docs.fetchSwapRemove(id)) |kv| server.gpa.free(kv.value);
    }
    server.requestSemanticRefresh();
    // 单文件模式的根文件在打开期间从磁盘删除时（外部改动的通知不处理打开的文件），关闭时丢弃它的编译结果，
    // 被它 import 的文件一并重新发布
    if (disk == null and server.dropSingle(id)) return;
    // 关闭后不再需要的结果立即释放，避免长会话中随打开过的文件线性增长
    server.releaseSingleIfUnused(id);
    // 关闭后按磁盘内容重新发布（编译集合中的文件仍可能有编译器诊断）
    server.publishFiles(&.{id}, true);
}

/// 关闭文档后释放不再需要保留的单文件结果：没有在编译，且结果中没有诊断（诊断会在关闭后继续发布）。
/// 关闭后重新打开或保存时按需重新编译
fn releaseSingleIfUnused(server: *Server, file: Vfs.FileId) void {
    {
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        const sf = server.single.getPtr(file) orelse return;
        if (sf.running or sf.pending) return;
        if (sf.result) |r| for (r.files.values()) |fr| {
            if (fr.items.len != 0) return;
        };
        sf.clearResult(server.gpa);
        _ = server.single.swapRemove(file);
    }
}

fn didSave(server: *Server, arena: Allocator, params: types.DidSaveTextDocumentParams) !void {
    const id = try server.fileIdFromUri(arena, params.textDocument.uri) orelse return;
    const path = server.vfs.path(id);
    const base = std.fs.path.basename(path);
    const is_build_file = isProjectFile(base);

    // 根目录下新建的 build.zig：启动项目
    if (std.mem.eql(u8, base, "build.zig")) if (std.fs.path.dirname(path)) |dir| {
        if (try server.refreshRoot(dir)) return;
    };

    // 包含该文件的各个项目都重新构建（共用的模块、标准库）
    const list = try server.workspaceList(arena);
    defer server.releaseList(arena, list);
    for (list) |ws| {
        if (!ws.owns(id)) continue;
        if ((is_build_file and std.mem.eql(u8, std.fs.path.dirname(path) orelse "", ws.root)) or ws.isBuildScript(id)) {
            // 非 watch 模式下 maker 不会自动重新配置：重启
            server.restartWorkspace(ws, 0);
        } else {
            server.requestBuild(ws);
        }
    }
    // 单文件模式：文件自身是独立文件时编译它，上一次编译读取过它或在其中报告过错误的根文件同样重新编译
    server.recompileSingle(&.{id}, &.{id});
}

/// 项目根目录中变化时需要重启项目的文件
fn isProjectFile(base: []const u8) bool {
    return std.mem.eql(u8, base, "build.zig") or std.mem.eql(u8, base, "build.zig.zon") or std.mem.eql(u8, base, Config.project_file);
}

/// 磁盘上的外部改动（编辑器之外：git checkout、代码生成等）。打开的文件以缓冲区为准；其余已知的文件
/// 按磁盘内容更新（删除的置为不存在），内容与已知的相同时不写入、不重新发布。工作区根目录的 build.zig / build.zig.zon /
/// zig-analyzer.json 或项目的构建脚本变化时重启该项目，根目录下新建或删除 build.zig 时启动或停止项目，其他文件变化时
/// 项目重新构建、单文件重新编译；磁盘内容与上一次据此重新构建时的相同时不重新构建
fn didChangeWatchedFiles(server: *Server, arena: Allocator, params: types.DidChangeWatchedFilesParams) !void {
    const Change = struct {
        file: Vfs.FileId,
        path: []const u8,
        text: ?[]u8,
        durability: database.Durability,
        /// 磁盘内容的哈希，null 为不存在
        disk: ?u64,
        /// 与已知的文本不同：写入、重新发布
        edited: bool = true,
        /// 与 `watched_built` 记录的不同：重新构建
        rebuild: bool = true,
    };
    var changes: std.ArrayList(Change) = .empty;
    defer for (changes.items) |c| if (c.text) |t| server.gpa.free(t);
    const rules = try server.originRules(arena);
    var build_files: std.ArrayList([]const u8) = .empty;
    var build_zig_dirs: std.ArrayList([]const u8) = .empty;
    // 变化的已知文件（含打开的文件：maker 读取磁盘）
    var known: std.ArrayList(Vfs.FileId) = .empty;
    // 同一个文件在一批中多次变化时以最后一次为准：原子保存先删除、再新建，内容不变时两次合起来不是改动
    var events: std.StringArrayHashMapUnmanaged(types.FileChangeType) = .empty;
    for (params.changes) |event| {
        const path = uri.toPath(arena, event.uri) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnsupportedScheme, error.InvalidUri => continue,
        };
        if (!std.fs.path.isAbsolute(path)) continue;
        try events.put(arena, path, event.type);
    }
    for (events.keys(), events.values()) |path, kind| {
        const base = std.fs.path.basename(path);
        const dir = std.fs.path.dirname(path) orelse "";
        if (std.mem.eql(u8, base, "build.zig")) try build_zig_dirs.append(arena, dir);
        // 从未接触过的文件与分析无关（新建的文件被 import 时再加载）；项目文件无从比较内容，按变化处理
        const file = try server.vfs.lookup(path) orelse {
            if (isProjectFile(base)) try build_files.append(arena, dir);
            continue;
        };
        const is_open = blk: {
            server.docs_mutex.lockUncancelable(server.io);
            defer server.docs_mutex.unlock(server.io);
            break :blk server.open_docs.contains(file);
        };
        if (is_open) {
            if (isProjectFile(base)) try build_files.append(arena, dir);
            try known.append(arena, file);
            continue;
        }
        const text = if (kind == .Deleted) null else server.vfs.readFromDisk(file, server.gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            error.FileTooBig => null,
        };
        changes.append(arena, .{
            .file = file,
            .path = path,
            .text = text,
            .durability = origin.classify(&server.vfs, rules, server.vfs.path(file), false).durability(),
            .disk = if (text) |t| std.hash.Wyhash.hash(0, t) else null,
        }) catch |err| {
            if (text) |t| server.gpa.free(t);
            return err;
        };
    }
    // 构建步骤每次都原样重写源码树中的文件（如生成代码）时，写事务会取消进行中的计算与请求，重新构建又会再次重写，
    // 形成循环。是否重新构建不能按已知的文本判断：构建读取磁盘，而已知的文本也可能来自打开、关闭文档或首次加载时
    // 的读取，构建不一定读到过
    if (changes.items.len != 0) {
        var ctx = server.db.beginRead(arena);
        defer ctx.end();
        var kept: usize = 0;
        for (changes.items) |*c| {
            c.edited = !sameText(&ctx, c.file, c.text);
            c.rebuild = if (server.watched_built.get(c.file)) |built| !std.meta.eql(built, c.disk) else true;
            if (!c.edited and !c.rebuild) {
                if (c.text) |t| server.gpa.free(t);
                continue;
            }
            changes.items[kept] = c.*;
            kept += 1;
        }
        changes.shrinkRetainingCapacity(kept);
    }
    var edited: std.ArrayList(Vfs.FileId) = .empty;
    var rebuilt: std.ArrayList(Vfs.FileId) = .empty;
    for (changes.items) |c| {
        if (c.edited) try edited.append(arena, c.file);
        if (!c.rebuild) continue;
        try rebuilt.append(arena, c.file);
        try known.append(arena, c.file);
        if (isProjectFile(std.fs.path.basename(c.path))) try build_files.append(arena, std.fs.path.dirname(c.path) orelse "");
    }
    if (edited.items.len != 0) {
        server.db.beginWrite();
        defer server.db.endWrite();
        for (changes.items) |*c| if (c.edited) {
            try server.db.set(FileText, c.file, c.text, c.durability);
            c.text = null;
        };
    }

    // 根目录下新建或删除了 build.zig：启动或停止项目，刚启动的项目不必重启
    var refreshed: std.ArrayList([]const u8) = .empty;
    for (build_zig_dirs.items) |dir| if (try server.refreshRoot(dir)) try refreshed.append(arena, dir);

    const list = try server.workspaceList(arena);
    defer server.releaseList(arena, list);
    for (list) |ws| {
        // 非 watch 模式下 maker 不会自动重新配置：重启
        const reconfigure = for (build_files.items) |dir| {
            if (std.mem.eql(u8, dir, ws.root)) break true;
        } else for (known.items) |file| {
            if (ws.isBuildScript(file)) break true;
        } else false;
        if (reconfigure) {
            const started = for (refreshed.items) |dir| {
                if (std.mem.eql(u8, dir, ws.root)) break true;
            } else false;
            if (!started) server.restartWorkspace(ws, 0);
            continue;
        }
        for (rebuilt.items) |file| if (ws.owns(file)) {
            server.requestBuild(ws);
            break;
        };
    }
    if (edited.items.len != 0) {
        server.publishFiles(edited.items, true);
        server.requestSemanticRefresh();
    }
    if (rebuilt.items.len == 0) return;
    // 单文件模式：打开的文件 import 的文件可能变了
    server.docs_mutex.lockUncancelable(server.io);
    const open = try arena.dupe(Vfs.FileId, server.open_docs.keys());
    server.docs_mutex.unlock(server.io);
    server.recompileSingle(open, rebuilt.items);
    // 记录不了时下一次照常重新构建
    for (changes.items) |c| if (c.rebuild) server.watched_built.put(server.gpa, c.file, c.disk) catch {};
}

/// 文件已知的文本与 `text` 相同（都不存在也算）；读取失败时按不同处理
fn sameText(ctx: *Db.Ctx, file: Vfs.FileId, text: ?[]const u8) bool {
    const current = ctx.get(FileText, file) catch return false;
    const known = current orelse return text == null;
    return std.mem.eql(u8, known, text orelse return false);
}

/// 服务器发现的外部改动：与客户端的 `workspace/didChangeWatchedFiles` 通知同样处理，与主循环的消息处理串行
pub fn applyWatchedChanges(server: *Server, arena: Allocator, changes: []const types.FileEvent) void {
    defer {
        server.watch_mutex.lockUncancelable(server.io);
        server.watch_batches += 1;
        server.watch_mutex.unlock(server.io);
        server.watch_cond.broadcast(server.io);
    }
    server.write_mutex.lockUncancelable(server.io);
    defer server.write_mutex.unlock(server.io);
    if (server.state != .running or server.isShuttingDown()) return;
    // 处理期间计为忙碌：重启项目时旧的新实例先结束、新实例随后才计为忙碌，监听任务自身又不计为忙碌，
    // 中间不能让等待空闲的一方（waitIdle、shutdown）返回
    server.busyBegin();
    defer server.busyEnd();
    server.didChangeWatchedFiles(arena, .{ .changes = changes }) catch |err| log.err("applying changes on disk failed: {t}", .{err});
}

/// 服务器发现外部改动时关注的文件（另有各根目录的项目文件）：`.zig` / `.zon`，不是虚拟文档，不在依赖库中。
/// zig 环境未知时还分不出依赖库，都不关注
pub fn watchable(server: *Server, rules: origin.Rules, path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".zig") and !std.mem.endsWith(u8, path, ".zon")) return false;
    if (rules.zig_lib == null) return false;
    return switch (origin.classify(&server.vfs, rules, path, false)) {
        .user, .other => true,
        .virtual, .zig_lib, .generated, .package => false,
    };
}

/// `path` 是打开的文档
pub fn isOpen(server: *Server, path: []const u8) bool {
    const file = (server.vfs.lookup(path) catch return false) orelse return false;
    server.docs_mutex.lockUncancelable(server.io);
    defer server.docs_mutex.unlock(server.io);
    return server.open_docs.contains(file);
}

/// 关注的文件或监听方式可能变化：让监听任务重新计算
fn resyncWatcher(server: *Server) void {
    if (server.watcher) |w| w.requestResync();
}

/// 是否由服务器发现外部改动（见 `Config.Watcher`）
pub fn watchesFiles(server: *Server) bool {
    server.config_mutex.lockUncancelable(server.io);
    defer server.config_mutex.unlock(server.io);
    return switch (server.config.files_watcher) {
        .auto => !server.register_watch,
        .client => false,
        .server => true,
    };
}

/// 文件来源的分类依据（见 `origin.classify`），复制到 `arena` 中：zig 环境、工作区根目录，以及各项目的本地缓存与
/// 依赖包（在项目读入构建图之后才知道）。依次在 roots_mutex 与 workspaces_mutex 期间读取，不能在写事务中调用
pub fn originRules(server: *Server, arena: Allocator) Allocator.Error!origin.Rules {
    var rules: origin.Rules = .{};
    if (server.zigEnv()) |env| {
        rules.zig_lib = try arena.dupe(u8, env.lib_dir);
        rules.global_cache = try arena.dupe(u8, env.global_cache_dir);
    }
    {
        server.roots_mutex.lockUncancelable(server.io);
        defer server.roots_mutex.unlock(server.io);
        const roots = try arena.alloc([]const u8, server.roots.items.len);
        for (server.roots.items, roots) |root, *r| r.* = try arena.dupe(u8, root);
        rules.roots = roots;
    }
    var local_caches: std.ArrayList([]const u8) = .empty;
    var packages: std.ArrayList([]const u8) = .empty;
    {
        // 先 workspaces_mutex 后 ws.mutex
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        for (server.workspaces.items) |ws| try ws.libraryDirs(arena, &local_caches, &packages);
    }
    rules.local_caches = local_caches.items;
    rules.packages = packages.items;
    return rules;
}

/// 文件属于某个项目的模块图（编译集合，或者可由其余的编译 step 到达）
fn inProject(server: *Server, file: Vfs.FileId) bool {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    for (server.workspaces.items) |ws| if (ws.contains(file)) return true;
    return false;
}

/// 文件的来源（见 `origin.classify`）
pub fn fileOrigin(server: *Server, file: Vfs.FileId) origin.Origin {
    return server.originOf(file, server.inProject(file));
}

/// 内存不足、取不到分类依据时按其余文件处理
fn originOf(server: *Server, file: Vfs.FileId, in_project: bool) origin.Origin {
    var arena: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena.deinit();
    const rules = server.originRules(arena.allocator()) catch return .other;
    return origin.classify(&server.vfs, rules, server.vfs.path(file), in_project);
}

fn didChangeConfiguration(server: *Server, _: Allocator, params: types.DidChangeConfigurationParams) !void {
    // 只通知「配置已变化」而不带内容的客户端（如 VS Code）：向客户端拉取
    if (params.settings == .null) {
        if (server.pull_config) server.requestConfig();
        return;
    }
    const fresh = Config.parse(server.gpa, params.settings) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidConfig => return server.showWarning("invalid zig-analyzer settings, keeping the previous ones"),
    };
    try server.applyConfig(fresh);
}

/// 替换当前配置；构建相关配置变化时重启各项目
fn applyConfig(server: *Server, fresh: Config) Allocator.Error!void {
    var new = fresh;
    server.reportConfigWarnings("zig-analyzer settings", &new);
    server.config_mutex.lockUncancelable(server.io);
    const zig_changed = !server.config.sameZig(&new);
    const build_changed = !server.config.sameBuild(&new);
    const semantic_changed = server.config.callsite_seeding != new.callsite_seeding;
    const inactive_changed = server.config.inactive_code != new.inactive_code;
    const naming_changed = !server.config.sameNaming(&new);
    const build_was_enabled = server.config.build_enable;
    const watcher_changed = server.config.files_watcher != new.files_watcher;
    const inlay_changed = server.config.inlay_types != new.inlay_types or server.config.inlay_parameters != new.inlay_parameters or
        server.config.hide_redundant_param_names != new.hide_redundant_param_names or server.config.callsite_seeding != new.callsite_seeding;
    const compiler_disabled = server.config.compiler_diagnostics and !new.compiler_diagnostics;
    const log_file_changed = !eqlOptionalStr(server.config.log_file, new.log_file);
    server.applyLogging(&new, log_file_changed);
    server.config.deinit(server.gpa);
    server.config = new;
    server.config_mutex.unlock(server.io);
    if (inactive_changed or naming_changed) server.publishOpenFiles();
    if (watcher_changed) server.resyncWatcher();

    if (zig_changed and server.started) server.showWarning("zig.path takes effect after restarting zig-analyzer");
    if (compiler_disabled) server.clearSingleFileResults();
    if (inlay_changed and server.inlay_refresh) server.sendRequest(.{ .string = "zig-analyzer/inlayHintRefresh" }, "workspace/inlayHint/refresh", null);
    if (semantic_changed) server.requestSemanticRefresh();
    if (build_changed) {
        if (!new.build_enable) {
            // 关闭构建系统集成：停止各项目，其文件改按单文件处理
            server.stopProjects();
        } else if (!build_was_enabled) {
            if (server.zigEnv() != null) server.startProjectsForRoots();
        } else {
            const list = try server.workspaceList(server.gpa);
            defer server.releaseList(server.gpa, list);
            if (list.len != 0) log.info("build settings changed, restarting projects", .{});
            for (list) |ws| server.restartWorkspace(ws, 0);
        }
        // 文件的编译上下文可能变化，编译器诊断可能重新开启
        server.reconcileSingle();
    }
}

/// 构建系统集成与编译器诊断是否开启
fn buildFlags(server: *Server) struct { build: bool, compiler: bool } {
    server.config_mutex.lockUncancelable(server.io);
    defer server.config_mutex.unlock(server.io);
    return .{ .build = server.config.build_enable, .compiler = server.config.compiler_diagnostics };
}

/// 停止全部项目，清除其发布过的编译器诊断，模块图随之更新
fn stopProjects(server: *Server) void {
    // 从列表中取出（连同列表持有的引用）
    const list = blk: {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        const list = server.gpa.dupe(*Workspace, server.workspaces.items) catch return;
        server.workspaces.clearRetainingCapacity();
        break :blk list;
    };
    defer server.releaseList(server.gpa, list);
    var stale: std.ArrayList(Vfs.FileId) = .empty;
    defer stale.deinit(server.gpa);
    for (list) |ws| {
        server.stopProject(ws);
        ws.mutex.lockUncancelable(server.io);
        stale.appendSlice(server.gpa, ws.result_files.keys()) catch {};
        ws.mutex.unlock(server.io);
    }
    server.updateModuleGraph();
    server.publishFiles(stale.items, true);
    server.publishOpenFiles();
    // 打开的文件改按单文件编译
    server.reconcileSingle();
}

/// 为有 build.zig 的根目录启动项目（按磁盘重新检查：加入根目录之后 build.zig 可能被新建或删除）
fn startProjectsForRoots(server: *Server) void {
    var roots: std.ArrayList([]u8) = .empty;
    defer {
        for (roots.items) |r| server.gpa.free(r);
        roots.deinit(server.gpa);
    }
    {
        server.roots_mutex.lockUncancelable(server.io);
        defer server.roots_mutex.unlock(server.io);
        for (server.roots.items) |root| {
            const copy = server.gpa.dupe(u8, root) catch return;
            roots.append(server.gpa, copy) catch {
                server.gpa.free(copy);
                return;
            };
        }
    }
    for (roots.items) |root| {
        const has_build = server.hasBuildZig(root) catch return;
        _ = server.setRootHasBuild(root, has_build);
        if (has_build) server.startWorkspace(root);
    }
}

/// 目录下是否有 build.zig
fn hasBuildZig(server: *Server, dir: []const u8) Allocator.Error!bool {
    const path = try std.fs.path.join(server.gpa, &.{ dir, "build.zig" });
    defer server.gpa.free(path);
    Io.Dir.cwd().access(server.io, path, .{}) catch return false;
    return true;
}

/// 记录根目录 `root` 下是否有 build.zig；返回记录是否因此改变（`root` 不是根目录时为 false）
fn setRootHasBuild(server: *Server, root: []const u8, has_build: bool) bool {
    server.roots_mutex.lockUncancelable(server.io);
    defer server.roots_mutex.unlock(server.io);
    for (server.roots.items, server.root_has_build.items) |r, *flag| if (std.mem.eql(u8, r, root)) {
        if (flag.* == has_build) return false;
        flag.* = has_build;
        return true;
    };
    return false;
}

/// 目录 `dir` 下的 build.zig 可能被新建或删除：按磁盘重新检查。`dir` 是根目录且有变化时，新出现则启动项目；
/// 消失则停止项目，其中的文件不再属于项目（改为独立文件；祖先目录还有 build.zig 时属于未加载的项目）。返回是否
/// 有变化
fn refreshRoot(server: *Server, dir: []const u8) Allocator.Error!bool {
    const has_build = try server.hasBuildZig(dir);
    if (!server.setRootHasBuild(dir, has_build)) return false;
    if (has_build) {
        log.info("{s}: build.zig was created", .{dir});
        if (server.zigEnv() != null) server.startWorkspace(dir);
    } else {
        log.info("{s}: build.zig was deleted", .{dir});
        server.removeProject(dir);
        server.updateModuleGraph();
    }
    // 打开的文件：单文件模式的结果不再适用，或改按单文件编译
    server.publishOpenFiles();
    server.reconcileSingle();
    return true;
}

/// 清除单文件模式的编译器诊断（关闭编译器诊断时）。没有在编译的根文件不再记录，重新开启时按打开的文件重新编译
fn clearSingleFileResults(server: *Server) void {
    var files: std.ArrayList(Vfs.FileId) = .empty;
    defer files.deinit(server.gpa);
    {
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        var i: usize = server.single.count();
        while (i > 0) {
            i -= 1;
            const sf = &server.single.values()[i];
            if (sf.result != null) {
                files.append(server.gpa, server.single.keys()[i]) catch {};
                files.appendSlice(server.gpa, sf.files.keys()) catch {};
            }
            sf.clearResult(server.gpa);
            if (!sf.running) server.single.swapRemoveAt(i);
        }
    }
    server.publishFiles(files.items, true);
}

/// 日志级别、慢请求阈值；`reopen_file` 时按配置重新打开日志文件
fn applyLogging(server: *Server, config: *const Config, reopen_file: bool) void {
    za.util.log.setLevel(config.log_level);
    server.slow_request_ms.store(config.slow_request_ms, .monotonic);
    server.debounce_ms.store(config.debounce_ms, .monotonic);
    server.max_intern_pool_mb.store(config.max_intern_pool_mb, .monotonic);
    server.callsite_seeding.store(config.callsite_seeding, .monotonic);
    if (!reopen_file) return;
    za.util.log.setFile(config.log_file) catch |err| {
        log.warn("cannot open log file {s}: {t}", .{ config.log_file.?, err });
        server.showWarning("cannot open log.file, logging to stderr only");
    };
}

fn eqlOptionalStr(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

const config_request_prefix = "zig-analyzer/configuration/";

/// 向客户端拉取 `zig-analyzer` 配置节；响应由 `handleConfigResponse` 处理
fn requestConfig(server: *Server) void {
    var buf: [64]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, config_request_prefix ++ "{d}", .{server.config_requests}) catch unreachable;
    server.config_requests += 1;
    server.config_outstanding += 1;
    server.busyBegin();
    server.sendRequest(.{ .string = id }, "workspace/configuration", types.ConfigurationParams{ .items = &.{.{ .section = "zig-analyzer" }} });
}

fn handleConfigResponse(server: *Server, id: []const u8, result: json.Value, failed: bool) Allocator.Error!void {
    const n = std.fmt.parseInt(u32, id[config_request_prefix.len..], 10) catch return;
    // shutdown 时已不再等待
    if (server.config_outstanding == 0) return;
    defer {
        server.config_outstanding -= 1;
        server.busyEnd();
    }
    // 之后又发出了新的请求：等待最新的响应
    if (n + 1 != server.config_requests) return;
    defer if (server.startup_pending) {
        server.startup_pending = false;
        server.startProjects();
    };
    if (failed) return log.info("client failed to provide configuration", .{});
    // 结果与请求的 items 一一对应；该节未设置时为 null，即全部使用默认值
    const section: json.Value = if (result == .array and result.array.items.len == 1) result.array.items[0] else .null;
    const fresh: Config = if (section == .null) .{} else Config.parse(server.gpa, section) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidConfig => return server.showWarning("invalid zig-analyzer settings, keeping the previous ones"),
    };
    try server.applyConfig(fresh);
}

/// 当前配置的副本（调用方释放）
pub fn configSnapshot(server: *Server) Allocator.Error!Config {
    server.config_mutex.lockUncancelable(server.io);
    defer server.config_mutex.unlock(server.io);
    return server.config.clone(server.gpa);
}

fn initialized(server: *Server, arena: Allocator, _: types.InitializedParams) !void {
    if (server.initialized_received) return;
    server.initialized_received = true;
    var registrations: std.ArrayList(types.Registration) = .empty;
    if (server.register_config) try registrations.append(arena, .{ .id = "zig-analyzer/didChangeConfiguration", .method = "workspace/didChangeConfiguration" });
    if (server.register_watch) {
        // 编辑器之外的改动（git checkout、代码生成等）：源文件、build.zig.zon 与项目配置文件
        const options = try std.json.parseFromSliceLeaky(std.json.Value, arena,
            \\{"watchers": [{"globPattern": "**/*.zig"}, {"globPattern": "**/*.zon"}, {"globPattern": "**/zig-analyzer.json"}]}
        , .{});
        try registrations.append(arena, .{ .id = "zig-analyzer/didChangeWatchedFiles", .method = "workspace/didChangeWatchedFiles", .registerOptions = options });
    }
    if (registrations.items.len != 0) {
        server.sendRequest(.{ .string = "zig-analyzer/register" }, "client/registerCapability", types.RegistrationParams{ .registrations = registrations.items });
    }
    if (server.pull_config) {
        // 拉取到配置后再启动项目
        server.startup_pending = true;
        server.requestConfig();
    } else {
        server.startProjects();
    }
}

fn startProjects(server: *Server) void {
    server.started = true;
    server.busyBegin();
    server.bg_group.concurrent(server.io, startup, .{server}) catch |err| {
        server.busyEnd();
        log.err("failed to start project loading task: {t}", .{err});
    };
    // 在主循环中创建，之后的唤醒与停止不会丢失。一直运行到服务器关闭，不计为忙碌；不能退回在主循环中同步执行
    const w = watch.Watcher.create(server) catch return log.err("out of memory while starting to watch files on disk", .{});
    server.watcher = w;
    server.vfs.listener.store(&w.listener, .release);
    server.bg_group.concurrent(server.io, watch.Watcher.run, .{w}) catch |err| {
        log.warn("failed to start watching files on disk: {t}", .{err});
        server.vfs.listener.store(null, .release);
        server.watcher = null;
        w.destroy();
    };
}

// ── 项目与后台任务 ───────────────────────────────────────────────────

/// 用户 zig 与编译时的版本不同时的提示（用户的版本、编译时的版本、编译时的版本、用户的版本）。构建图文件没有版本号、
/// 按结构体逐字节读取，格式不符时会越界，所以带 build.zig 的项目不加载（见 `startWorkspace`）：除了编译器诊断，
/// 命名模块的 import 也无法解析，跳转、hover、补全随之受影响
const version_mismatch_message = "zig {s} differs from zig {s} that zig-analyzer was built with. " ++
    "Projects with build.zig are not loaded: they get no compiler diagnostics, and imports of named modules " ++
    "(dependencies, build options) are not resolved. Live diagnostics use zig ast-check. " ++
    "Use zig {s}, or a zig-analyzer built for zig {s}.";

/// 查询 zig 环境，并为每个带 build.zig 的工作区启动构建系统协议
fn startup(server: *Server) Io.Cancelable!void {
    defer server.busyEnd();
    var config = server.configSnapshot() catch return;
    defer config.deinit(server.gpa);
    const env = ZigEnv.query(server.gpa, server.io, config.zig_path) catch |err| {
        log.warn("failed to run zig env ({t}): compiler diagnostics are unavailable", .{err});
        return;
    };
    {
        var fresh = true;
        server.env_mutex.lockUncancelable(server.io);
        defer server.env_mutex.unlock(server.io);
        if (server.zig_env == null) {
            server.zig_env = env;
        } else fresh = false;
        if (!fresh) {
            // 已有环境（不应发生：`initialized` 只处理一次）：保留旧值，释放这次查询的结果
            var stale = env;
            stale.deinit(server.gpa);
            return;
        }
    }
    log.info("zig {s} ({s})", .{ env.version, env.zig_exe });
    // 默认的 builtin.zig（单文件模式）：按 `zig test` 的设置，test 块中依赖 `builtin.is_test` 的
    // `std.testing.allocator` 等可以推导（与有 test step 的模块一致，见 configuration.zig）
    const default_builtin = za.project.builtin.generate(server.gpa, server.io, &env, &.{"test"}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => null,
    };
    if (default_builtin) |path| {
        var keep = true;
        {
            server.env_mutex.lockUncancelable(server.io);
            defer server.env_mutex.unlock(server.io);
            if (server.default_builtin == null) server.default_builtin = path else keep = false;
        }
        if (!keep) server.gpa.free(path);
    }
    if (!env.matchesBuiltin()) {
        // 进程内 AstGen 与用户 zig 不一定一致：live 诊断改用用户的 zig ast-check
        const built = @import("builtin").zig_version_string;
        const message = std.fmt.allocPrint(server.gpa, version_mismatch_message, .{ env.version, built, built, env.version }) catch null;
        defer if (message) |m| server.gpa.free(m);
        server.showWarningOnce(message orelse "zig version differs from the one zig-analyzer was built with");
        const exe = server.gpa.dupe(u8, env.zig_exe) catch return;
        server.db.beginWrite();
        defer server.db.endWrite();
        server.db.set(live.LiveBackend, {}, .{ .subprocess = exe }, .high) catch {};
    }
    server.updateModuleGraph();
    if (server.buildFlags().build) server.startProjectsForRoots();
    // 启动前已打开的独立文件：zig 环境就绪、项目开始加载之后补一次编译
    server.startup_done.store(true, .release);
    server.reconcileSingle();
}

// ── 单文件模式 ───────────────────────────────────────────────────────

/// 文件的编译上下文：决定它能否作为单文件模式的根编译，以及单文件编译的结果是否用于它的诊断。
/// 依次判断：依赖库、项目的模块图、带 build.zig 的根目录、祖先目录中没有加载的项目；以上都不是的 .zig 文件
/// 才是独立文件
const FileContext = enum {
    /// 不参与编译：虚拟文档，以及不属于任何项目的非 .zig 文件
    none,
    /// 依赖库（见 `origin.Origin.isLibrary`）中的文件：只作为依赖参与编译，不作为根。真实的编译入口在其中
    /// 报告的错误照常发布
    library,
    /// 在某个项目的模块图中（编译集合，或者可由其余的编译 step 到达）：编译器诊断来自项目的构建
    project,
    /// 带 build.zig 的根目录下、不在模块图中的文件：由项目处理，不单独编译
    project_dir,
    /// 祖先目录有 build.zig、那个项目却没有加载的 .zig 文件（如工作区外另一个项目中的文件）：按名字的 import
    /// 只有那个项目的构建能解析，不单独编译；打开时提示把项目加入工作区（见 `appendUnloadedProjectHint`）
    unloaded_project,
    /// 独立的 .zig 文件：作为根单独编译
    detached,

    /// 单文件编译的结果是否用于这类文件：项目中的文件被独立文件按相对路径 import 时处在另一个模块中，
    /// 按名字的 import 与项目中不同，只采用项目的构建结果
    fn usesSingle(context: FileContext) bool {
        return switch (context) {
            .none, .library, .detached => true,
            .project, .project_dir, .unloaded_project => false,
        };
    }
};

fn fileContext(server: *Server, file: Vfs.FileId) FileContext {
    const in_project = server.inProject(file);
    switch (server.originOf(file, in_project)) {
        .virtual => return .none,
        .zig_lib, .generated, .package => return .library,
        .user, .other => {},
    }
    if (in_project) return .project;
    const path = server.vfs.path(file);
    const build = server.buildFlags().build;
    if (build) {
        server.roots_mutex.lockUncancelable(server.io);
        defer server.roots_mutex.unlock(server.io);
        for (server.roots.items, server.root_has_build.items) |root, has_build| {
            if (has_build and server.vfs.isUnder(path, root)) return .project_dir;
        }
    }
    if (!std.mem.endsWith(u8, path, ".zig")) return .none;
    if (build and server.projectDirOf(path) != null) return .unloaded_project;
    return .detached;
}

/// 文件所属项目的目录：所在目录及其祖先中第一个有 build.zig 的。遇到 `.zig-cache`、`zig-pkg` 时停止：其中的
/// 文件（缓存、获取的依赖包）不是外层项目的源码
fn projectDirOf(server: *Server, path: []const u8) ?[]const u8 {
    var dir = std.fs.path.dirname(path);
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        const name = std.fs.path.basename(d);
        if (std.mem.eql(u8, name, ".zig-cache") or std.mem.eql(u8, name, "zig-pkg")) return null;
        if (server.hasBuildZig(d) catch false) return d;
    }
    return null;
}

/// 有项目尚在首次加载（见 `Workspace.load_done`）：还不知道哪些根目录外的文件属于项目
fn projectsLoading(server: *Server) bool {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    for (server.workspaces.items) |ws| if (ws.isLoading()) return true;
    return false;
}

/// 在后台用 `zig build-obj -fno-emit-bin` 编译独立文件；编译期间再次请求时，结束后重新编译
fn compileSingle(server: *Server, file: Vfs.FileId) void {
    if (!server.startup_done.load(.acquire)) return; // 启动结束时会补编译
    if (server.fileContext(file) != .detached) return;
    if (!server.buildFlags().compiler) return;
    // 编译器读取磁盘：不在磁盘上的文件（尚未保存的新文件、已被删除的文件）不编译，丢弃它上一次的编译结果
    Io.Dir.cwd().access(server.io, server.vfs.path(file), .{}) catch {
        _ = server.dropSingle(file);
        return;
    };
    // 项目首次加载期间文件可能随后归入项目：加载结束时补编译，不在错误的上下文中编译（见 `reconcileSingle`）
    const deferred = server.projectsLoading();
    {
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        const gop = server.single.getOrPut(server.gpa, file) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        if (deferred) {
            gop.value_ptr.pending = true;
            return;
        }
        gop.value_ptr.pending = false;
        if (gop.value_ptr.running) {
            gop.value_ptr.rerun = true;
            return;
        }
        gop.value_ptr.running = true;
    }
    server.busyBegin();
    // 编译耗时数秒，尽量不在主循环中同步执行（否则期间无法处理进度 token 的响应等消息）
    spawn(server.io, &server.bg_group, singleFileTask, .{ server, file });
}

/// 按文件当前的编译上下文收敛单文件模式，在上下文可能变化之后调用（zig 环境就绪，项目加载结束、编译集合变化、
/// 新实例替换旧实例，项目与根目录的增删，构建集成与编译器诊断的开关）：不再是独立文件的根丢弃编译结果；
/// 推迟了的编译，以及打开的、没有编译过的独立文件补上编译。单文件结果是否用于某个文件取决于该文件的上下文
/// （见 `FileContext.usesSingle`），结果中的文件随之重新发布
pub fn reconcileSingle(server: *Server) void {
    if (server.isShuttingDown()) return;
    const gpa = server.gpa;
    var roots: std.ArrayList(Vfs.FileId) = .empty;
    defer roots.deinit(gpa);
    var affected: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty;
    defer affected.deinit(gpa);
    var compile: std.ArrayList(Vfs.FileId) = .empty;
    defer compile.deinit(gpa);
    {
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        roots.appendSlice(gpa, server.single.keys()) catch return;
        for (server.single.values()) |*sf| for (sf.files.keys()) |f| affected.put(gpa, f, {}) catch return;
    }
    // 上下文在锁外判断：要获取项目与根目录的锁
    for (roots.items) |root| {
        const detached = server.fileContext(root) == .detached;
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        const sf = server.single.getPtr(root) orelse continue;
        if (detached) {
            if (sf.pending) compile.append(gpa, root) catch {};
            continue;
        }
        affected.put(gpa, root, {}) catch {};
        for (sf.files.keys()) |f| affected.put(gpa, f, {}) catch {};
        if (sf.running) {
            // 编译结束时按上下文丢弃（见 `singleFileTask`）
            sf.rerun = true;
        } else {
            sf.clearResult(gpa);
            _ = server.single.swapRemove(root);
        }
    }
    server.publishFiles(affected.keys(), true);

    server.docs_mutex.lockUncancelable(server.io);
    const open = gpa.dupe(Vfs.FileId, server.open_docs.keys()) catch {
        server.docs_mutex.unlock(server.io);
        return;
    };
    server.docs_mutex.unlock(server.io);
    defer gpa.free(open);
    {
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        for (open) |file| if (!server.single.contains(file)) compile.append(gpa, file) catch {};
    }
    for (compile.items) |file| server.compileSingle(file);
    // 未加载的项目中的文件：提示推迟到了启动阶段结束、项目加载结束（见 `appendUnloadedProjectHint`），上下文也
    // 可能刚变为这一种
    var unloaded: std.ArrayList(Vfs.FileId) = .empty;
    defer unloaded.deinit(gpa);
    for (open) |file| if (server.fileContext(file) == .unloaded_project) unloaded.append(gpa, file) catch {};
    server.publishFiles(unloaded.items, false);
}

/// 编译结果的序号：项目的构建与单文件编译存入结果时各取一个，越大越新
pub fn nextCompileGeneration(server: *Server) u64 {
    return server.compile_generation.fetchAdd(1, .monotonic) + 1;
}

/// 丢弃已不在磁盘上的根文件 `file` 的编译结果，并重新发布其中有错误的文件（被它 import 的文件上的错误也随之
/// 清除）。返回是否丢弃了结果（`file` 已随之重新发布）
fn dropSingle(server: *Server, file: Vfs.FileId) bool {
    var affected: std.ArrayList(Vfs.FileId) = .empty;
    defer affected.deinit(server.gpa);
    {
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        const sf = server.single.getPtr(file) orelse return false;
        // 正在进行的编译可能在删除之前就读取了文件：结束后重新编译（文件已不在磁盘上，得到空结果）
        if (sf.running) sf.rerun = true;
        if (sf.result == null) return false;
        affected.append(server.gpa, file) catch {};
        affected.appendSlice(server.gpa, sf.files.keys()) catch {};
        sf.clearResult(server.gpa);
    }
    server.publishFiles(affected.items, true);
    return true;
}

fn singleFileTask(server: *Server, file: Vfs.FileId) Io.Cancelable!void {
    defer server.busyEnd();
    const env = server.zigEnv().?;
    const path = server.vfs.path(file);
    var pc: panic_context.Text = .{};
    pc.enter("single-file compile {s}", .{path});
    defer pc.leave();
    var title_buf: [256]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Compiling {s}", .{std.fs.path.basename(path)}) catch "Compiling";
    const progress = server.progress.begin(server, title, false);
    var errors: usize = 0;
    defer server.progress.end(server, progress, if (errors == 0) "Done" else "Has errors");
    while (true) {
        var inputs: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty;
        const result: ?*compiler.BuildResult = blk: {
            // 文件已从磁盘删除（编译期间被删除时由 `dropSingle` 要求重新编译）：没有结果
            Io.Dir.cwd().access(server.io, path, .{}) catch break :blk null;
            var compiled = za.project.bsp.compileSingleFile(server.gpa, server.io, env.zig_exe, path) catch |err| {
                log.warn("{s}: single-file compile failed: {t}", .{ path, err });
                break :blk null;
            };
            defer compiled.deinit(server.gpa);
            errors = compiled.errors.errorMessageCount();
            for (compiled.inputs) |p| {
                const id = server.vfs.intern(p) catch continue;
                inputs.put(server.gpa, id, {}) catch continue;
            }
            break :blk compiler.collect(server.gpa, &.{compiled.errors}, std.fs.path.dirname(path) orelse ".", path, server, readDisk) catch null;
        };
        var files: std.AutoArrayHashMapUnmanaged(Vfs.FileId, *const compiler.FileResult) = .empty;
        if (result) |r| for (r.files.keys(), r.files.values()) |p, *fr| {
            const id = server.vfs.intern(p) catch continue;
            files.put(server.gpa, id, fr) catch continue;
        };
        // 编译期间文件可能不再是独立文件（所属项目加载完成、所在根目录新建了 build.zig 等），
        // 编译器诊断也可能已被关闭：都不采用这次的结果
        const detached = server.fileContext(file) == .detached and server.buildFlags().compiler;
        server.single_mutex.lockUncancelable(server.io);
        const sf = server.single.getPtr(file).?;
        if (detached and sf.rerun) {
            sf.rerun = false;
            server.single_mutex.unlock(server.io);
            files.deinit(server.gpa);
            inputs.deinit(server.gpa);
            if (result) |r| r.release(server.gpa);
            continue;
        }
        // 受影响的文件：根文件自身，以及上一次与本次结果中有错误的文件（被 import 的文件也在其中）
        var affected: std.ArrayList(Vfs.FileId) = .empty;
        defer affected.deinit(server.gpa);
        affected.append(server.gpa, file) catch {};
        affected.appendSlice(server.gpa, sf.files.keys()) catch {};
        sf.clearResult(server.gpa);
        if (detached) {
            affected.appendSlice(server.gpa, files.keys()) catch {};
            sf.result = result;
            sf.files = files;
            sf.inputs = inputs;
            sf.generation = server.nextCompileGeneration();
            sf.running = false;
        } else {
            // 不采用这次的结果，也不再记录这个根文件
            files.deinit(server.gpa);
            inputs.deinit(server.gpa);
            if (result) |r| r.release(server.gpa);
            _ = server.single.swapRemove(file);
        }
        server.single_mutex.unlock(server.io);
        server.publishFiles(affected.items, true);
        return;
    }
}

/// 重新编译单文件模式的根文件：`roots`，以及上一次编译读取过 `changed` 中的文件或在其中报告过错误的根文件
/// （例如 import 了被保存的文件）。每个根文件只编译一次
fn recompileSingle(server: *Server, roots: []const Vfs.FileId, changed: []const Vfs.FileId) void {
    var list: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty;
    defer list.deinit(server.gpa);
    for (roots) |root| list.put(server.gpa, root, {}) catch return;
    {
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        for (server.single.keys(), server.single.values()) |root, *sf| {
            for (changed) |f| if (sf.inputs.contains(f) or sf.files.contains(f)) {
                list.put(server.gpa, root, {}) catch return;
                break;
            };
        }
    }
    for (list.keys()) |root| server.compileSingle(root);
}

fn readDisk(ctx: *anyopaque, gpa: Allocator, path: []const u8) ?[]u8 {
    const server: *Server = @ptrCast(@alignCast(ctx));
    return Io.Dir.cwd().readFileAlloc(server.io, path, gpa, .limited(Vfs.max_file_size)) catch null;
}

/// 为根目录启动项目；同一根目录已有项目时不重复启动（启动阶段与工作区文件夹的变化可能同时进行）。
/// 用户 zig 与编译时的版本不同时不启动：构建图的格式由标准库定义，读不了。这样的项目只有 live 诊断（zig ast-check），
/// 不按单文件编译（使用命名模块的文件会报出找不到模块）
fn startWorkspace(server: *Server, root: []const u8) void {
    if (server.isShuttingDown() or !server.buildFlags().build) return;
    if (server.zigEnv()) |env| if (!env.matchesBuiltin()) return;
    {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        for (server.workspaces.items) |w| if (std.mem.eql(u8, w.root, root)) return;
    }
    const ws = Workspace.start(server, root, 0) catch |err| {
        log.err("{s}: failed to start build system protocol: {t}", .{ root, err });
        return;
    };
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    // 列表接管 `start` 返回的引用。期间同一根目录已启动了项目，或列表无法增长：新实例作废
    const added = server.visibleFor(root) == null and
        (if (server.workspaces.append(server.gpa, ws)) |_| true else |_| false);
    if (!added) ws.stop();
    ws.placed.set(server.io);
    if (!added) ws.release();
}

/// 加入工作区根目录（`uri` 为目录的 URI）。zig 环境已就绪时立即启动项目，否则由启动阶段启动
fn addRoot(server: *Server, root_uri: []const u8) !void {
    const path = uri.toPath(server.gpa, root_uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer server.gpa.free(path);
    const normalized = try Vfs.normalize(.native, server.gpa, path) orelse return;
    var owned = true;
    defer if (owned) server.gpa.free(normalized);
    const has_build = try server.hasBuildZig(normalized);
    {
        server.roots_mutex.lockUncancelable(server.io);
        defer server.roots_mutex.unlock(server.io);
        for (server.roots.items) |r| if (std.mem.eql(u8, r, normalized)) return;
        try server.root_has_build.ensureUnusedCapacity(server.gpa, 1);
        try server.roots.append(server.gpa, normalized);
        server.root_has_build.appendAssumeCapacity(has_build);
        owned = false;
    }
    if (has_build and server.zigEnv() != null) server.startWorkspace(normalized);
}

/// 移除工作区根目录：停止其项目，清除其发布过的编译器诊断
fn removeRoot(server: *Server, arena: Allocator, root_uri: []const u8) !void {
    const path = uri.toPath(arena, root_uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    const normalized = try Vfs.normalize(.native, arena, path) orelse return;
    {
        server.roots_mutex.lockUncancelable(server.io);
        defer server.roots_mutex.unlock(server.io);
        for (server.roots.items, 0..) |r, i| if (std.mem.eql(u8, r, normalized)) {
            server.gpa.free(server.roots.orderedRemove(i));
            _ = server.root_has_build.orderedRemove(i);
            break;
        };
    }
    server.removeProject(normalized);
}

/// 停止根目录 `root` 的项目，清除其发布过的编译器诊断（模块图由调用方更新）
fn removeProject(server: *Server, root: []const u8) void {
    var removed: ?*Workspace = null;
    {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        // 连同列表持有的引用一起取出
        for (server.workspaces.items, 0..) |w, i| if (std.mem.eql(u8, w.root, root)) {
            removed = server.workspaces.orderedRemove(i);
            break;
        };
    }
    const ws = removed orelse return;
    defer ws.release();
    server.stopProject(ws);
    ws.mutex.lockUncancelable(server.io);
    const stale = server.gpa.dupe(Vfs.FileId, ws.result_files.keys()) catch &.{};
    ws.mutex.unlock(server.io);
    defer server.gpa.free(stale);
    server.publishFiles(stale, true);
}

/// 工作区文件夹的增减
fn didChangeWorkspaceFolders(server: *Server, arena: Allocator, params: types.DidChangeWorkspaceFoldersParams) !void {
    for (params.event.removed) |f| try server.removeRoot(arena, f.uri);
    for (params.event.added) |f| try server.addRoot(f.uri);
    server.updateModuleGraph();
    // 打开的文件可能进出项目目录与未加载的项目（提示随之出现或消失）
    server.publishOpenFiles();
    server.reconcileSingle();
    server.resyncWatcher();
}

/// 重启 `ws` 所在的项目（按根目录找到项目当前的实例：调用方持有的列表快照可能已过时）。`crash_restarts` 为
/// maker 连续崩溃后自动重启的次数（正常重启为 0）。
///
/// 先结束旧的 maker（不与新实例同时构建），再启动新实例。新实例在首次构建完成（或配置失败；旧实例没有模型时
/// 为配置完成）前不可见（见 `promote`）：其间列表中仍是旧实例，其模型、编译集合与编译器诊断继续生效，构建请求
/// 转给新实例（见 `requestBuild`）
pub fn restartWorkspace(server: *Server, ws: *Workspace, crash_restarts: u8) void {
    ws.stop();
    {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        // 所在项目已被移除
        const visible = server.visibleFor(ws.root) orelse return;
        visible.stop();
        if (visible.successor) |pending| pending.stop();
    }
    if (server.isShuttingDown()) return;
    const fresh = Workspace.start(server, ws.root, crash_restarts) catch |err| {
        log.err("{s}: failed to restart build system protocol: {t}", .{ ws.root, err });
        return;
    };
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    // 启动新实例期间服务器开始关闭，或所在项目已被移除：新实例作废
    const visible = (if (server.shutting_down) null else server.visibleFor(ws.root)) orelse {
        fresh.stop();
        fresh.placed.set(server.io);
        fresh.release();
        return;
    };
    // 此前（或并发的重启）产生、尚未替换旧实例的新实例同样作废
    if (visible.successor) |pending| {
        pending.stop();
        pending.release();
    }
    visible.successor = fresh;
    fresh.placed.set(server.io);
}

/// 新实例替换旧实例的时机。`built`：首次构建完成（或配置失败、读不了构建图、不需要构建），总是替换。
/// `configured`：读入构建图并算出编译集合，只在旧实例不参与模块图（配置失败、读不了构建图、配置前 maker 崩溃）
/// 时替换：旧实例没有可沿用的模块，不必等整次构建结束才能解析命名模块
pub const PromoteStage = enum { configured, built };

/// 重启产生的新实例 `ws` 到了 `stage`：替换列表中的旧实例。返回被替换的实例（连同列表持有的引用，
/// 调用方释放）；`ws` 不是等待替换的新实例或时机未到时返回 null
pub fn promote(server: *Server, ws: *Workspace, stage: PromoteStage) ?*Workspace {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    if (server.shutting_down) return null;
    for (server.workspaces.items) |*w| if (w.*.successor == ws) {
        const old = w.*;
        if (stage == .configured and old.inModuleGraph()) return null;
        // 列表接管 `successor` 持有的引用
        old.successor = null;
        w.* = ws;
        return old;
    };
    return null;
}

/// 重启产生的新实例 `ws` 不再继续（maker 反复崩溃、协议版本不符）：不再等它替换旧实例。旧实例的模型与
/// 编译集合继续用于模块归属；其编译器诊断不再更新，予以清除
pub fn abandon(server: *Server, ws: *Workspace) void {
    const old = blk: {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        for (server.workspaces.items) |w| if (w.successor == ws) {
            w.successor = null;
            w.acquire();
            break :blk w;
        };
        return;
    };
    defer old.release();
    // `successor` 持有的引用（调用方另持有一个）
    ws.release();
    old.clearResult();
}

/// `ws` 是否是列表中（可见）的实例
pub fn isVisible(server: *Server, ws: *Workspace) bool {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    return std.mem.indexOfScalar(*Workspace, server.workspaces.items, ws) != null;
}

/// 停止列表中的实例 `ws` 以及尚未替换它的新实例
fn stopProject(server: *Server, ws: *Workspace) void {
    ws.stop();
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    if (ws.successor) |s| s.stop();
}

/// 请求构建 `ws` 所在的项目（按根目录找到项目当前的实例：调用方持有的列表快照可能已过时）：重启期间转给新实例
pub fn requestBuild(server: *Server, ws: *Workspace) void {
    const target = blk: {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        // 所在项目已被移除
        const visible = server.visibleFor(ws.root) orelse return;
        const t = visible.successor orelse visible;
        t.acquire();
        break :blk t;
    };
    defer target.release();
    target.requestBuild();
}

/// 根目录 `root` 的项目在列表中的实例；调用方持有 `workspaces_mutex`
fn visibleFor(server: *Server, root: []const u8) ?*Workspace {
    for (server.workspaces.items) |w| if (std.mem.eql(u8, w.root, root)) return w;
    return null;
}

/// 列表中各实例的快照（各持有一个引用，用 `releaseList` 释放）
fn workspaceList(server: *Server, a: Allocator) Allocator.Error![]*Workspace {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    const list = try a.dupe(*Workspace, server.workspaces.items);
    for (list) |ws| ws.acquire();
    return list;
}

fn releaseList(server: *Server, a: Allocator, list: []*Workspace) void {
    _ = server;
    for (list) |ws| ws.release();
    a.free(list);
}

fn stopWorkspaces(server: *Server) void {
    {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        server.shutting_down = true;
        for (server.workspaces.items) |ws| {
            ws.stop();
            if (ws.successor) |s| s.stop();
        }
    }
    if (server.watcher) |w| w.stop();
}

pub fn isShuttingDown(server: *Server) bool {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    return server.shutting_down;
}

pub fn zigEnv(server: *Server) ?*const ZigEnv {
    server.env_mutex.lockUncancelable(server.io);
    defer server.env_mutex.unlock(server.io);
    return if (server.zig_env) |*e| e else null;
}

/// 配置中未知的项与类型错误的项：合并为一条提示
/// 合并提示配置中的问题；`source` 为配置的来源（客户端的配置或项目配置文件的路径）
pub fn reportConfigWarnings(server: *Server, source: []const u8, config: *const Config) void {
    if (config.warnings.len == 0) return;
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{s}: ", .{source}) catch {};
    for (config.warnings, 0..) |msg, i| w.print("{s}{s}", .{ if (i > 0) "; " else "", msg }) catch break;
    server.showWarning(w.buffered());
}

pub fn showWarning(server: *Server, message: []const u8) void {
    // 已经提示给用户：日志只作记录
    log.info("shown to the user: {s}", .{message});
    server.sendNotification("window/showMessage", types.ShowMessageParams{ .type = .Warning, .message = message });
}

pub fn showWarningOnce(server: *Server, message: []const u8) void {
    server.env_mutex.lockUncancelable(server.io);
    const first = !server.warned;
    server.warned = true;
    server.env_mutex.unlock(server.io);
    if (first) server.showWarning(message);
}

pub fn busyBegin(server: *Server) void {
    server.busy_mutex.lockUncancelable(server.io);
    defer server.busy_mutex.unlock(server.io);
    server.busy += 1;
}

pub fn busyEnd(server: *Server) void {
    server.busy_mutex.lockUncancelable(server.io);
    defer server.busy_mutex.unlock(server.io);
    server.busy -= 1;
    if (server.busy == 0) server.busy_cond.broadcast(server.io);
}

/// 等待所有后台任务（构建、编译集合计算、诊断发布）完成
fn waitIdle(server: *Server) void {
    server.busy_mutex.lockUncancelable(server.io);
    defer server.busy_mutex.unlock(server.io);
    while (server.busy != 0) server.busy_cond.waitUncancelable(server.io, &server.busy_mutex);
}

fn waitIdleRequest(server: *Server, _: Allocator, _: void) HandlerError!void {
    server.waitIdle();
}

// ── 诊断发布 ───────────────────────────────────────────────────

/// 每批发布的并发上限：大批量变更（watcher、构建错误）不能按文件数生成任务与读事务
pub const max_publish_workers = 8;

/// `tracked` 时文件的状态记在 `publish_files` 中，`clear` 在开始时从那里取；记不下状态（分配失败）时不合并
const PublishJob = struct { file: Vfs.FileId, clear: bool = false, tracked: bool = true };

const PublishState = struct {
    /// 在队列中，尚未开始
    queued: bool = true,
    /// 开始计算之后又有了发布请求：完成后再发布一次
    again: bool = false,
    /// 下一次发布即使没有诊断也发送（合并的请求取并集）
    clear: bool,
};

/// 在后台重新计算并发布这些文件的诊断。`clear` 为 true 时即使没有诊断也发布（用于清除旧诊断）。
/// 同一文件已在排队时合并，正在计算时在完成后再发布一次：每次状态变化（如构建结束）都会请求发布打开的文件，
/// 并发计算同一文件只是重复的工作，而完成后的那一次读到的是最新的状态。任务数不超过 `max_publish_workers`
pub fn publishFiles(server: *Server, files: []const Vfs.FileId, clear: bool) void {
    if (files.len == 0) return;
    var spawn_count: usize = 0;
    {
        server.publish_queue_mutex.lockUncancelable(server.io);
        defer server.publish_queue_mutex.unlock(server.io);
        for (files) |file| {
            const gop = server.publish_files.getOrPut(server.gpa, file) catch {
                server.publish_queue.append(server.gpa, .{ .file = file, .clear = clear, .tracked = false }) catch {};
                continue;
            };
            if (gop.found_existing) {
                gop.value_ptr.clear = gop.value_ptr.clear or clear;
                if (!gop.value_ptr.queued) gop.value_ptr.again = true;
                continue;
            }
            gop.value_ptr.* = .{ .clear = clear };
            server.publish_queue.append(server.gpa, .{ .file = file }) catch {
                _ = server.publish_files.remove(file);
            };
        }
        if (server.publish_workers < max_publish_workers and server.publish_queue.items.len != 0) {
            spawn_count = @min(max_publish_workers - server.publish_workers, server.publish_queue.items.len);
            server.publish_workers += spawn_count;
        }
    }
    for (0..spawn_count) |_| {
        server.busyBegin();
        spawn(server.io, &server.bg_group, publishWorker, .{server});
    }
}

fn publishWorker(server: *Server) Io.Cancelable!void {
    defer server.busyEnd();
    var counted = true;
    defer if (counted) {
        server.publish_queue_mutex.lockUncancelable(server.io);
        server.publish_workers -= 1;
        server.publish_queue_mutex.unlock(server.io);
    };
    while (true) {
        const job = blk: {
            server.publish_queue_mutex.lockUncancelable(server.io);
            defer server.publish_queue_mutex.unlock(server.io);
            if (server.publish_queue.items.len == 0) {
                // 与入队用同一把锁：退出前先减计数，避免入队方看到 worker 仍在而不再补任务
                server.publish_workers -= 1;
                counted = false;
                return;
            }
            var job = server.publish_queue.swapRemove(0);
            if (job.tracked) {
                const state = server.publish_files.getPtr(job.file).?;
                state.queued = false;
                job.clear = state.clear;
                state.clear = false;
            }
            break :blk job;
        };
        server.publishNow(job.file, job.clear, null);
        if (job.tracked) server.publishDone(job.file);
        server.maybeResetSema();
    }
}

/// 一次发布完成：计算期间又有请求时重新排队（由仍在运行的 worker 处理）
fn publishDone(server: *Server, file: Vfs.FileId) void {
    server.publish_queue_mutex.lockUncancelable(server.io);
    defer server.publish_queue_mutex.unlock(server.io);
    const state = server.publish_files.getPtr(file).?;
    if (!state.again) {
        _ = server.publish_files.remove(file);
        return;
    }
    state.again = false;
    state.queued = true;
    server.publish_queue.append(server.gpa, .{ .file = file }) catch {
        _ = server.publish_files.remove(file);
    };
}

pub fn publishOpenFiles(server: *Server) void {
    server.docs_mutex.lockUncancelable(server.io);
    const files = server.gpa.dupe(Vfs.FileId, server.open_docs.keys()) catch {
        server.docs_mutex.unlock(server.io);
        return;
    };
    server.docs_mutex.unlock(server.io);
    defer server.gpa.free(files);
    server.publishFiles(files, false);
}

/// 文件的编辑代数，与是否已有等待中的发布任务
const Edit = struct { generation: u64 = 0, scheduled: bool = false };

/// 编辑触发的发布：同一文件最多一个等待中的任务，`diagnostics.debounce_ms` 内没有新的编辑时才计算。
/// 逐字输入时不为每次按键计算诊断（AstGen 与非活动代码的推导），也不堆积被写事务反复打断的任务
fn publishDebounced(server: *Server, file: Vfs.FileId) void {
    {
        server.edits_mutex.lockUncancelable(server.io);
        defer server.edits_mutex.unlock(server.io);
        const gop = server.edits.getOrPut(server.gpa, file) catch return server.publishFiles(&.{file}, false);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.generation += 1;
        if (gop.value_ptr.scheduled) return;
        gop.value_ptr.scheduled = true;
    }
    // 在锁外提交：退回 `async` 时任务在这里同步执行，会再获取 `edits_mutex`
    server.busyBegin();
    spawn(server.io, &server.bg_group, debounceTask, .{ server, file });
}

fn debounceTask(server: *Server, file: Vfs.FileId) Io.Cancelable!void {
    defer server.busyEnd();
    var seen: ?u64 = null;
    while (true) {
        {
            server.edits_mutex.lockUncancelable(server.io);
            defer server.edits_mutex.unlock(server.io);
            const edit = server.edits.getPtr(file).?;
            if (seen == edit.generation) {
                edit.scheduled = false;
                break;
            }
            seen = edit.generation;
        }
        const ms = server.debounce_ms.load(.monotonic);
        if (ms > 0) try (Io.Clock.Duration{ .raw = .fromMilliseconds(ms), .clock = .awake }).sleep(server.io);
    }
    server.publishNow(file, false, seen);
    if (server.openDocumentCount() > 1) server.requestSemanticRefresh();
    server.maybeResetSema();
}

fn editGeneration(server: *Server, file: Vfs.FileId) u64 {
    server.edits_mutex.lockUncancelable(server.io);
    defer server.edits_mutex.unlock(server.io);
    return if (server.edits.get(file)) |e| e.generation else 0;
}

/// InternPool 超过 `sema.max_intern_pool_mb` 时整代回收（见 `resetSema`）。在读事务之外的空闲处调用
fn maybeResetSema(server: *Server) void {
    const limit = server.max_intern_pool_mb.load(.monotonic);
    if (limit == 0) return;
    if (server.ip.bytes() < @as(usize, limit) * 1024 * 1024 and server.semaKeys() < sema_reset_keys) return;
    if (server.sema_resetting.swap(true, .acq_rel)) return;
    defer server.sema_resetting.store(false, .release);
    server.resetSema();
}

/// 类型信息相关 query 的 key 总数超过此值时同样整代回收：key 与依赖边不随淘汰释放，长时间会话中
/// 随访问过的成员与实例持续增长（Zig 编译器源码 40 轮约 25 万个，连同依赖边数十 MB）
const sema_reset_keys = 200_000;

/// 整代回收所清空的 query
const sema_queries = .{ database.sema.Infer, database.sema.LocalValue, database.sema.DeclType, database.sema.CallEval, database.sema.ErrorSetOf, database.sema.InactiveRanges, database.ide_db.seed.Query, database.ide_db.seed.Instances };

fn semaKeys(server: *Server) usize {
    var n: usize = 0;
    inline for (sema_queries) |Q| n += server.db.keyCount(Q);
    return n;
}

/// 同 `semaKeys`；调用者持有写事务
fn semaKeysLocked(server: *Server) usize {
    var n: usize = 0;
    inline for (sema_queries) |Q| n += server.db.keyCountLocked(Q);
    return n;
}

/// 整代回收类型信息：清空 InternPool 中非预置的项，以及 key 或值引用它们的 query（其余 query 中依赖
/// 它们的 memo 一并丢弃）。InternPool 与这些 query 的 key、依赖边只增不减，长时间会话中随访问过的
/// 泛型实例持续增长；回收后再请求时按需重新推导
pub fn resetSema(server: *Server) void {
    const before = server.ip.bytes();
    server.db.beginWrite();
    defer server.db.endWrite();
    const keys = server.semaKeysLocked();
    server.db.resetQueries(&sema_queries);
    server.ip.reset() catch return log.err("out of memory while resetting the intern pool", .{});
    log.info("reclaimed type information ({d} MB in the intern pool, {d} keys)", .{ before / (1024 * 1024), keys });
}

/// `generation`：编辑触发的发布所针对的编辑代数。被打断时若已有更新的编辑就放弃，由那次编辑触发的发布接替
fn publishNow(server: *Server, file: Vfs.FileId, clear: bool, generation: ?u64) void {
    var pc: panic_context.Text = .{};
    pc.enter("publish diagnostics {s}", .{server.vfs.path(file)});
    defer pc.leave();
    var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_state.deinit();
    // 虚拟文档没有磁盘文件：关闭并清除诊断之后不再为内部路径发布
    if (isVirtual(server.vfs.path(file))) {
        server.docs_mutex.lockUncancelable(server.io);
        const wanted = server.open_docs.contains(file) or server.last_uris.contains(file);
        server.docs_mutex.unlock(server.io);
        if (!wanted) return;
    }
    // 被写事务取消时重试：构建结果触发的发布不能因无关的编辑而丢失
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        if (generation) |g| if (server.editGeneration(file) != g) return;
        server.prepareLive(file);
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        var ctx = server.db.beginRead(arena);
        // 准备之后又有了编辑：重新在锁外准备，不在读事务中做 AstGen（逐字输入时 AstGen 可能慢于按键）
        const ready = server.liveReady(&ctx, file) catch false;
        if (!ready) {
            ctx.end();
            continue;
        }
        // 在读取编译结果等状态之前取序号（见 `sendDiagnostics`）
        const seq = server.publish_seq.fetchAdd(1, .acq_rel);
        const params = server.computeDiagnostics(&ctx, arena, file) catch |err| {
            ctx.end();
            switch (err) {
                error.Canceled => continue,
                error.OutOfMemory => return log.err("out of memory while computing diagnostics", .{}),
            }
        };
        // 计算中吞掉了 `Canceled` 时结果不完整：同样重试
        const canceled = if (ctx.checkCanceled()) |_| false else |_| true;
        ctx.end();
        if (canceled) continue;
        server.sendDiagnostics(file, params, clear, seq);
        return;
    }
}

/// 在读事务之外对文件的当前文本做 AstGen（见 `live.Prepared`）：AstGen 不检查取消，在读事务中进行时
/// 写事务要等它结束。只读取文本时短暂持有读事务。任何失败都只是退回在 query 中计算
fn prepareLive(server: *Server, file: Vfs.FileId) void {
    if (!server.liveEligible(file)) return;
    var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text, const backend = blk: {
        var ctx = server.db.beginRead(a);
        defer ctx.end();
        const backend: live.Backend = switch (ctx.get(live.LiveBackend, {}) catch return) {
            .in_process => .in_process,
            .subprocess => |exe| .{ .subprocess = a.dupe(u8, exe) catch return },
        };
        const t = (ctx.get(FileText, file) catch return) orelse return;
        break :blk .{ a.dupe(u8, t) catch return, backend };
    };
    const mode = live.modeOf(server.vfs.path(file));
    if (!server.live_prepared.claim(server.io, file, live.Prepared.hash(text, mode, backend))) return;
    const result = live.checkWith(server.gpa, server.io, backend, text, mode) catch return;
    server.live_prepared.put(server.io, file, text, mode, backend, result) catch {};
}

/// 当前文本的 live 诊断已在读事务之外准备过（或不需要准备）
fn liveReady(server: *Server, ctx: *Db.Ctx, file: Vfs.FileId) !bool {
    if (!server.liveEligible(file)) return true;
    const backend = try ctx.get(live.LiveBackend, {});
    const text = try ctx.get(FileText, file) orelse return true;
    return server.live_prepared.prepared(server.io, file, live.Prepared.hash(text, live.modeOf(server.vfs.path(file)), backend));
}

/// 发送 `seq` 号计算的诊断，已发送过序号更大的结果时丢弃。同一文件的多个发布任务并发计算，先开始的可能后算完。
/// 状态每次变化之后都会发起新的发布：它在变化之后取号，序号大于变化之前取号的所有计算，读到的是变化之后的状态。
/// 所以只发送序号不小于已发送序号的结果时，最后发出的结果读到的是最后一次变化之后的状态。比较与写出都在
/// publish_mutex 内，写出的先后与比较的结果一致；序列化在锁外进行
fn sendDiagnostics(server: *Server, file: Vfs.FileId, params: types.PublishDiagnosticsParams, clear: bool, seq: u64) void {
    const bytes = jsonrpc.notification(server.gpa, "textDocument/publishDiagnostics", params) catch return log.err("out of memory while building notification", .{});
    var sent = false;
    defer if (!sent) server.gpa.free(bytes);
    server.publish_mutex.lockUncancelable(server.io);
    defer server.publish_mutex.unlock(server.io);
    if (server.sent_seq.getOrPut(server.gpa, file)) |gop| {
        if (gop.found_existing and gop.value_ptr.* > seq) return;
        gop.value_ptr.* = seq;
    } else |_| {}
    {
        server.docs_mutex.lockUncancelable(server.io);
        defer server.docs_mutex.unlock(server.io);
        const was_published = server.published.contains(file);
        if (params.diagnostics.len == 0) {
            // 从未显示过诊断的文件不必发送空列表（已打开的文件除外，客户端可能仍显示着旧结果）
            if (!was_published and !clear and !server.open_docs.contains(file)) return;
            _ = server.published.swapRemove(file);
        } else {
            server.published.put(server.gpa, file, {}) catch {};
        }
    }
    sent = true;
    server.send(bytes);
    // 虚拟文档的清除已发出：之后不再需要它的 URI
    if (isVirtual(server.vfs.path(file))) {
        server.docs_mutex.lockUncancelable(server.io);
        defer server.docs_mutex.unlock(server.io);
        if (!server.open_docs.contains(file)) if (server.last_uris.fetchSwapRemove(file)) |kv| server.gpa.free(kv.value);
    }
}

test "sendDiagnostics: a result computed earlier is not sent after a later one" {
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var writer: transport.Writer = .{ .io = std.testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(std.testing.io, gpa, &writer);
    defer server.deinit();
    const native = @import("../util/test_path.zig").native;
    const a = try server.vfs.intern(native("/a.zig"));
    const b = try server.vfs.intern(native("/b.zig"));
    const stale: types.Diagnostic = .{ .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } }, .message = .{ .string = "stale" } };
    // 第 2 次计算先算完并发送；第 1 次计算基于更旧的状态，后算完时丢弃。其他文件不受影响
    server.sendDiagnostics(a, .{ .uri = "file:///a.zig", .diagnostics = &.{} }, true, 2);
    server.sendDiagnostics(a, .{ .uri = "file:///a.zig", .diagnostics = &.{stale} }, true, 1);
    server.sendDiagnostics(b, .{ .uri = "file:///b.zig", .diagnostics = &.{stale} }, true, 0);
    server.sendDiagnostics(a, .{ .uri = "file:///a.zig", .diagnostics = &.{stale} }, true, 3);

    var reader: Io.Reader = .fixed(out.written());
    var sent: std.ArrayList(u8) = .empty;
    defer sent.deinit(gpa);
    while (transport.readMessage(&reader, gpa)) |body| {
        defer gpa.free(body);
        const msg = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
        defer msg.deinit();
        const params = msg.value.object.get("params").?.object;
        const uri_text = params.get("uri").?.string;
        try sent.print(gpa, "{s}:{d} ", .{ uri_text[uri_text.len - 5 ..], params.get("diagnostics").?.array.items.len });
    } else |err| if (err != error.EndOfStream) return err;
    try std.testing.expectEqualStrings("a.zig:0 b.zig:1 a.zig:1 ", sent.items);
}

test "publishFiles: large batches use a bounded number of workers" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var writer: transport.Writer = .{ .io = std.testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(std.testing.io, gpa, &writer);
    defer server.deinit();
    const text = "fn f() void {\n    var x = 1;\n}\n";
    const files = try gpa.alloc(Vfs.FileId, 200);
    defer gpa.free(files);
    for (files, 0..) |*file, i| {
        const path = try std.fmt.allocPrint(gpa, "/tmp/zig-analyzer-publish-{d}.zig", .{i});
        defer gpa.free(path);
        file.* = try server.vfs.intern(path);
        server.db.beginWrite();
        defer server.db.endWrite();
        try server.db.set(FileText, file.*, try gpa.dupe(u8, text), .low);
    }
    server.publishFiles(files, true);
    {
        server.publish_queue_mutex.lockUncancelable(server.io);
        defer server.publish_queue_mutex.unlock(server.io);
        try std.testing.expect(server.publish_workers <= max_publish_workers);
    }
    server.waitIdle();

    var reader: Io.Reader = .fixed(out.written());
    var published: usize = 0;
    while (transport.readMessage(&reader, gpa)) |body| {
        defer gpa.free(body);
        const msg = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
        defer msg.deinit();
        const method = msg.value.object.get("method") orelse continue;
        if (std.mem.eql(u8, method.string, "textDocument/publishDiagnostics")) published += 1;
    } else |err| if (err != error.EndOfStream) return err;
    try std.testing.expectEqual(files.len, published);
}

test "publishFiles: requests for a file being published coalesce into one more run" {
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var writer: transport.Writer = .{ .io = std.testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(std.testing.io, gpa, &writer);
    defer server.deinit();
    const file = try server.vfs.intern("/tmp/zig-analyzer-publish-coalesce.zig");
    {
        server.db.beginWrite();
        defer server.db.endWrite();
        try server.db.set(FileText, file, try gpa.dupe(u8, "fn f() void {\n    var x = 1;\n}\n"), .low);
    }
    const before = server.publish_seq.load(.monotonic);
    // 写事务期间发布任务停在读事务之前：之后的请求都在第一次发布排队或计算时到达
    server.db.beginWrite();
    for (0..10) |_| server.publishFiles(&.{file}, true);
    server.db.endWrite();
    server.waitIdle();
    // 排队中的请求合并，计算开始之后的请求在完成后合为一次
    const computed = server.publish_seq.load(.monotonic) - before;
    try std.testing.expect(computed >= 1 and computed <= 2);
    try std.testing.expectEqual(0, server.publish_files.count());
}

test "updateModuleGraph keeps the old inputs when an allocation fails" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var writer: transport.Writer = .{ .io = std.testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(std.testing.io, failing.allocator(), &writer);
    defer {
        failing.fail_index = std.math.maxInt(usize);
        server.deinit();
    }

    // 首次更新：任何失败点都不应留下部分写入的 input
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        try std.testing.expect(fail_index < 10_000);
        failing.alloc_index = 0;
        failing.resize_index = 0;
        failing.has_induced_failure = false;
        failing.fail_index = fail_index;
        if (server.updateModuleGraphInner()) |_| {
            failing.fail_index = std.math.maxInt(usize);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failing.fail_index = std.math.maxInt(usize);
            server.db.beginWrite();
            const graph = server.db.peek(ModuleGraph.Input, {});
            const target = server.db.peek(za.sema.queries.TargetAbi, {});
            server.db.endWrite();
            try std.testing.expectEqual(null, graph);
            try std.testing.expect(std.meta.eql(za.sema.queries.TargetAbi.default, target));
        }
    }

    server.db.beginWrite();
    const old_graph = server.db.peek(ModuleGraph.Input, {});
    const old_target = server.db.peek(za.sema.queries.TargetAbi, {});
    server.db.endWrite();
    try std.testing.expect(old_graph != null);

    // 之后的更新失败时保留旧图与 TargetAbi。换一个默认的 builtin.zig，使新图与旧图不同而走到写入
    server.default_builtin = try failing.allocator().dupe(u8, "/zig-analyzer-test/builtin.zig");
    fail_index = 0;
    while (true) : (fail_index += 1) {
        try std.testing.expect(fail_index < 10_000);
        failing.alloc_index = 0;
        failing.resize_index = 0;
        failing.has_induced_failure = false;
        failing.fail_index = fail_index;
        if (server.updateModuleGraphInner()) |_| {
            failing.fail_index = std.math.maxInt(usize);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failing.fail_index = std.math.maxInt(usize);
            server.db.beginWrite();
            const graph = server.db.peek(ModuleGraph.Input, {});
            const target = server.db.peek(za.sema.queries.TargetAbi, {});
            server.db.endWrite();
            try std.testing.expectEqual(old_graph, graph);
            try std.testing.expect(std.meta.eql(old_target, target));
        }
    }
    server.db.beginWrite();
    const new_graph = server.db.peek(ModuleGraph.Input, {});
    server.db.endWrite();
    try std.testing.expect(new_graph != old_graph);
}

test "updateModuleGraph takes no write transaction when nothing changed" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var writer: transport.Writer = .{ .io = std.testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, &writer);
    defer server.deinit();
    try server.updateModuleGraphInner();
    const writes = server.db.writes.load(.monotonic);
    // 每次构建结束都会更新模块图：没有变化时开写事务会取消进行中的计算与请求
    try server.updateModuleGraphInner();
    try std.testing.expectEqual(writes, server.db.writes.load(.monotonic));
    server.default_builtin = try std.testing.allocator.dupe(u8, "/zig-analyzer-test/builtin.zig");
    try server.updateModuleGraphInner();
    try std.testing.expectEqual(writes + 1, server.db.writes.load(.monotonic));
}

/// 是否发布文件的 live 诊断：不属于任何项目，或所属的项目中有一个认为需要（见 `Workspace.liveEligible`）
fn liveEligible(server: *Server, file: Vfs.FileId) bool {
    // 在持有 workspaces_mutex 期间使用各项目（先 workspaces_mutex 后 ws.mutex）
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    var owned = false;
    for (server.workspaces.items) |ws| if (ws.owns(file)) {
        if (ws.liveEligible(file)) return true;
        owned = true;
    };
    return !owned;
}

fn uriFor(server: *Server, arena: Allocator, file: Vfs.FileId) Allocator.Error![]const u8 {
    server.docs_mutex.lockUncancelable(server.io);
    defer server.docs_mutex.unlock(server.io);
    if (server.open_docs.get(file)) |u| return arena.dupe(u8, u);
    if (server.last_uris.get(file)) |u| return arena.dupe(u8, u);
    return uri.fromPath(arena, server.vfs.path(file));
}

const OtherFiles = struct {
    server: *Server,
    ctx: *Db.Ctx,
    /// 编译器诊断的附注所在文件在那次编译时的文本（附注的区间以它为准），按附注中的路径
    texts: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// 取用的编译结果，各持有一份引用（`release` 时释放）：诊断算完之前不会因被新的结果替换而释放
    builds: std.ArrayList(*compiler.BuildResult) = .empty,

    fn get(opaque_ctx: *anyopaque, arena: Allocator, path: []const u8) ?compiler.OtherFile {
        const self: *OtherFiles = @ptrCast(@alignCast(opaque_ctx));
        const file = self.server.vfs.lookup(path) catch return null;
        const loaded: ?[]const u8 = if (file) |f| (self.ctx.get(FileText, f) catch null) orelse null else null;
        const text = loaded orelse Io.Dir.cwd().readFileAlloc(self.server.io, path, arena, .limited(Vfs.max_file_size)) catch return null;
        const u = if (file) |f| self.server.uriFor(arena, f) catch return null else uri.fromPath(arena, path) catch return null;
        return .{ .uri = u, .text = text, .base_text = self.texts.get(path) };
    }

    /// 取用编译结果 `build` 中的 `fr`（在持有 `build` 所在的锁时调用），并记下其附注所在文件在这次编译时的文本
    /// （同一路径只取最先记下的）
    fn use(self: *OtherFiles, arena: Allocator, fr: *const compiler.FileResult, build: *compiler.BuildResult) Allocator.Error!*const compiler.FileResult {
        try self.builds.ensureUnusedCapacity(arena, 1);
        self.builds.appendAssumeCapacity(build.retain());
        for (fr.items) |item| for (item.notes) |n| {
            if (self.texts.contains(n.path)) continue;
            const text = build.texts.get(n.path) orelse continue;
            try self.texts.put(arena, n.path, text);
        };
        return fr;
    }

    fn release(self: *OtherFiles) void {
        for (self.builds.items) |b| b.release(self.server.gpa);
        self.builds.clearRetainingCapacity();
    }
};

/// `file` 的编译器诊断：包含它的各个项目最近一次构建的结果，单文件编译的结果按文件的上下文决定是否采用
/// （见 `FileContext.usesSingle`）；有多个时按 `compiler.combine` 合并，以最新一次编译读取的文本为准。
/// 各个结果在其所在的锁内取得引用，记入 `other`（附注所在文件的文本也记入），合并时不持有锁
fn compilerResult(server: *Server, arena: Allocator, file: Vfs.FileId, other: *OtherFiles) Allocator.Error!?*const compiler.FileResult {
    const Found = struct {
        generation: u64,
        result: *const compiler.FileResult,

        fn newer(_: void, a: @This(), b: @This()) bool {
            return a.generation > b.generation;
        }
    };
    var found: std.ArrayList(Found) = .empty;
    {
        const list = try server.workspaceList(arena);
        defer server.releaseList(arena, list);
        for (list) |ws| {
            ws.mutex.lockUncancelable(server.io);
            defer ws.mutex.unlock(server.io);
            const fr = ws.result_files.get(file) orelse continue;
            const build = ws.result orelse {
                _ = never(true, @src(), "workspace has result files without a result");
                continue;
            };
            try found.append(arena, .{ .generation = ws.result_generation, .result = try other.use(arena, fr, build) });
        }
    }
    if (server.fileContext(file).usesSingle()) {
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        for (server.single.values()) |*sf| if (sf.files.get(file)) |fr| {
            const build = sf.result orelse {
                _ = never(true, @src(), "single-file root has result files without a result");
                continue;
            };
            try found.append(arena, .{ .generation = sf.generation, .result = try other.use(arena, fr, build) });
        };
    }
    switch (found.items.len) {
        0 => return null,
        1 => return found.items[0].result,
        else => {},
    }
    std.mem.sort(Found, found.items, {}, Found.newer);
    const results = try arena.alloc(*const compiler.FileResult, found.items.len);
    for (found.items, results) |f, *r| r.* = f.result;
    const combined = try arena.create(compiler.FileResult);
    combined.* = try compiler.combine(arena, results);
    return combined;
}

fn computeDiagnostics(server: *Server, ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId) !types.PublishDiagnosticsParams {
    const document_uri = try server.uriFor(arena, file);
    const text = try ctx.get(FileText, file);

    // live 诊断：文件已加载，且（不属于任何项目，或编译集合尚未算出，或在编译集合中）
    var live_result: ?*live.Result = null;
    if (text != null and server.liveEligible(file)) live_result = try ctx.get(live.AstCheck, file);

    // 编译器诊断：被 import 的文件中的错误由编译它的项目或根文件报告
    var other: OtherFiles = .{ .server = server, .ctx = ctx };
    defer other.release();
    const fr = try server.compilerResult(arena, file, &other);
    const current = text orelse if (fr) |r| r.base_text else "";
    var diags = try compiler.merge(arena, .{
        .text = current,
        .lines = try offsets.LineIndex.init(arena, current),
        .encoding = server.encoding,
        .uri = document_uri,
        .live = live_result,
        .compiler = fr,
        .other_file = OtherFiles.get,
        .other_ctx = &other,
    });
    if (text) |t| if (server.wantsInactiveCode(file)) {
        diags = try server.appendInactiveCode(ctx, arena, file, t, diags);
    };
    if (text) |t| if (try server.namingFor(arena, file, t)) |settings| {
        diags = try server.appendNaming(ctx, arena, file, t, settings, diags);
    };
    if (text) |t| diags = try server.appendUnloadedProjectHint(arena, file, t, diags);
    return .{ .uri = document_uri, .diagnostics = diags };
}

/// 打开的、属于没有加载的项目的文件（见 `FileContext.unloaded_project`）：提示把项目目录加入工作区。同
/// rust-analyzer 对不属于任何 crate 的文件，是只标出文件开头几个字符的 Hint。启动阶段结束之前与项目首次加载
/// 期间不提示：文件可能随后出现在项目的模块图中（以路径加入的模块）
fn appendUnloadedProjectHint(server: *Server, arena: Allocator, file: Vfs.FileId, text: []const u8, diags: []const types.Diagnostic) ![]const types.Diagnostic {
    const path = server.vfs.path(file);
    if (!server.isOpen(path) or !server.startup_done.load(.acquire) or server.projectsLoading()) return diags;
    if (server.fileContext(file) != .unloaded_project) return diags;
    const dir = server.projectDirOf(path) orelse return diags;
    var end: usize = 0;
    var chars: usize = 0;
    while (chars < 3 and end < text.len and text[end] != '\n' and text[end] != '\r') : (chars += 1) {
        end += std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
    }
    const lines = try offsets.LineIndex.init(arena, text);
    const out = try arena.alloc(types.Diagnostic, diags.len + 1);
    @memcpy(out[0..diags.len], diags);
    out[diags.len] = .{
        .range = lines.range(0, @intCast(@min(end, text.len)), server.encoding),
        .severity = .Hint,
        .source = "zig-analyzer",
        .message = .{ .string = try std.fmt.allocPrint(arena, "this file belongs to the project at {s}, which is not loaded: it is not compiled on its own, " ++
            "since only the project's build can resolve its imports by name; add the directory to the workspace folders to load the project", .{dir}) },
    };
    return out;
}

/// 只为打开的文件显示非活动代码：需要推导文件中的全部成员
fn wantsInactiveCode(server: *Server, file: Vfs.FileId) bool {
    {
        server.config_mutex.lockUncancelable(server.io);
        defer server.config_mutex.unlock(server.io);
        if (!server.config.inactive_code) return false;
    }
    server.docs_mutex.lockUncancelable(server.io);
    defer server.docs_mutex.unlock(server.io);
    return server.open_docs.contains(file);
}

/// 当前构建配置下不编译的代码（comptime 已知不执行的分支）：带 `Unnecessary` 标记的提示，编辑器以淡色显示
fn appendInactiveCode(server: *Server, ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId, text: []const u8, diags: []const types.Diagnostic) ![]const types.Diagnostic {
    var r: Resolver = .{ .ctx = ctx, .arena = arena };
    const ranges = try za.ide.inactive.ranges(&r, file);
    if (ranges.len == 0) return diags;
    const lines = try offsets.LineIndex.init(arena, text);
    const out = try arena.alloc(types.Diagnostic, diags.len + ranges.len);
    @memcpy(out[0..diags.len], diags);
    var n = diags.len;
    for (ranges) |x| {
        // builtin 按 zig test 生成，推导可能把诊断那次编译实际执行的分支标为非活动：与编译器诊断
        // 重叠时不发布提示，避免同一处代码同时是错误与非活动
        if (conflictsWithCompilerError(diags, text, server.encoding, x)) continue;
        out[n] = .{
            .range = lines.range(x.start, x.end, server.encoding),
            .severity = .Hint,
            .source = "zig-analyzer",
            .message = .{ .string = "code is inactive: a comptime condition excludes it under the current build configuration" },
            .tags = &.{.Unnecessary},
        };
        n += 1;
    }
    return out[0..n];
}

fn conflictsWithCompilerError(diags: []const types.Diagnostic, text: []const u8, enc: offsets.Encoding, range: za.ide.inactive.Range) bool {
    for (diags) |d| {
        const source = d.source orelse continue;
        if (!std.mem.eql(u8, source, "zig")) continue;
        const start: u32 = @intCast(offsets.positionToOffset(text, d.range.start, enc));
        const end: u32 = @intCast(offsets.positionToOffset(text, d.range.end, enc));
        if (range.start < end and start < range.end) return true;
    }
    return false;
}

/// 一个文件的命名检查配置：客户端的配置，以包含文件的项目的 `zig-analyzer.json` 中出现的项覆盖
const NamingSettings = struct {
    ignore: []const []const u8,
    rules: Config.NamingRules,

    fn allows(s: NamingSettings, f: ide.naming.Located) bool {
        const enabled = switch (f.rule) {
            inline else => |rule| @field(s.rules, @tagName(rule)),
        };
        if (!enabled) return false;
        for (s.ignore) |pattern| if (ide.naming.globMatch(pattern, f.name)) return false;
        return true;
    }
};

/// 文件是否做命名检查及其配置：开启了检查的、打开的用户代码（见 `origin.Origin.user`），不在 `naming.exclude` 中，
/// 也不是生成的代码（见 `naming.isGenerated`）
fn namingFor(server: *Server, arena: Allocator, file: Vfs.FileId, text: []const u8) Allocator.Error!?NamingSettings {
    {
        server.docs_mutex.lockUncancelable(server.io);
        defer server.docs_mutex.unlock(server.io);
        if (!server.open_docs.contains(file)) return null;
    }
    const path = server.vfs.path(file);
    var enable: bool = undefined;
    var ignore: []const []const u8 = undefined;
    var exclude: []const []const u8 = undefined;
    var rules: Config.NamingRules = undefined;
    {
        server.config_mutex.lockUncancelable(server.io);
        defer server.config_mutex.unlock(server.io);
        enable = server.config.naming_enable;
        ignore = try dupeStrings(arena, server.config.naming_ignore);
        exclude = try dupeStrings(arena, server.config.naming_exclude);
        rules = server.config.naming_rules;
    }
    // `naming.exclude` 的路径相对工作区根目录，来自 `zig-analyzer.json` 时相对项目根目录
    var base = try server.rootOf(arena, path);
    {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        // 嵌套的项目取最内层的
        var best: ?*Workspace = null;
        for (server.workspaces.items) |ws| {
            if (server.vfs.isUnder(path, ws.root) and (best == null or ws.root.len > best.?.root.len)) best = ws;
        }
        if (best) |ws| if (ws.project) |*p| {
            if (p.isSet("naming_enable")) enable = p.naming_enable;
            if (p.isSet("naming_ignore")) ignore = try dupeStrings(arena, p.naming_ignore);
            if (p.isSet("naming_rules")) rules = p.naming_rules;
            if (p.isSet("naming_exclude")) {
                exclude = try dupeStrings(arena, p.naming_exclude);
                base = try arena.dupe(u8, ws.root);
            }
        };
    }
    if (!enable) return null;
    if (exclude.len != 0) {
        var rel = path;
        if (base) |b| if (b.len < path.len) {
            rel = path[b.len..];
            while (rel.len > 0 and (rel[0] == '/' or rel[0] == '\\')) rel = rel[1..];
        };
        const normalized = try arena.dupe(u8, rel);
        std.mem.replaceScalar(u8, normalized, '\\', '/');
        for (exclude) |pattern| if (ide.naming.globMatch(pattern, normalized)) return null;
    }
    switch (server.fileOrigin(file)) {
        .virtual, .user => {},
        .zig_lib, .generated, .package, .other => return null,
    }
    if (ide.naming.isGenerated(text)) return null;
    return .{ .ignore = ignore, .rules = rules };
}

fn dupeStrings(arena: Allocator, list: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, list.len);
    for (list, out) |src, *dst| dst.* = try arena.dupe(u8, src);
    return out;
}

/// 包含 `path` 的工作区根目录（嵌套时取最内层的），复制到 `arena` 中
fn rootOf(server: *Server, arena: Allocator, path: []const u8) Allocator.Error!?[]const u8 {
    server.roots_mutex.lockUncancelable(server.io);
    defer server.roots_mutex.unlock(server.io);
    var best: ?[]const u8 = null;
    for (server.roots.items) |root| {
        if (server.vfs.isUnder(path, root) and (best == null or root.len > best.?.len)) best = root;
    }
    return if (best) |b| try arena.dupe(u8, b) else null;
}

/// 不符合命名约定的名字（见 `naming`）：低强度的提示，code 为 `naming.<规则>`，附官方规则的链接
fn appendNaming(server: *Server, ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId, text: []const u8, settings: NamingSettings, diags: []const types.Diagnostic) ![]const types.Diagnostic {
    var r: Resolver = .{ .ctx = ctx, .arena = arena };
    const found = try ide.naming.findings(&r, file, null);
    if (found.len == 0) return diags;
    const lines = try offsets.LineIndex.init(arena, text);
    var out: std.ArrayList(types.Diagnostic) = .empty;
    try out.appendSlice(arena, diags);
    for (found) |f| {
        if (!settings.allows(f)) continue;
        try out.append(arena, .{
            .range = lines.range(f.start, f.end, server.encoding),
            .severity = .Hint,
            .code = .{ .string = f.rule.code() },
            .codeDescription = .{ .href = ide.naming.guide_url },
            .source = "zig-analyzer",
            .message = .{ .string = try ide.naming.message(arena, f) },
        });
    }
    return out.items;
}

// ── 请求处理函数 ──────────────────────────────────────────────────────

/// 读请求中把 URI 换成已知文件；未打开或不存在的文件返回 null
fn lookupFile(server: *Server, arena: Allocator, document_uri: []const u8) !?Vfs.FileId {
    const path = try documentPath(arena, document_uri) orelse return null;
    return try server.vfs.lookup(path);
}

/// 请求中的区间换算为字节偏移；起止颠倒的区间按交换后处理
fn rangeOffsets(server: *const Server, text: []const u8, range: types.Range) struct { u32, u32 } {
    const a: u32 = @intCast(offsets.positionToOffset(text, range.start, server.encoding));
    const b: u32 = @intCast(offsets.positionToOffset(text, range.end, server.encoding));
    return .{ @min(a, b), @max(a, b) };
}

/// 文件文本与行索引
fn fileLines(ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId) !offsets.LineIndex {
    const text = try ctx.get(FileText, file) orelse "";
    return offsets.LineIndex.init(arena, text);
}

fn formatting(server: *Server, ctx: *Db.Ctx, arena: Allocator, params: types.DocumentFormattingParams) HandlerError!types.ResultType("textDocument/formatting") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const lines = try fileLines(ctx, arena, file);
    const mode: ide.format.Mode = if (std.mem.endsWith(u8, server.vfs.path(file), ".zon")) .zon else .zig;
    return ide.format.format(arena, lines, mode, server.encoding);
}

fn documentSymbol(server: *Server, ctx: *Db.Ctx, arena: Allocator, params: types.DocumentSymbolParams) HandlerError!types.ResultType("textDocument/documentSymbol") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const items = try ctx.get(syntax_q.FileItemTree, file);
    const map = try ctx.get(syntax_q.FileAstIdMap, file);
    const lines = try fileLines(ctx, arena, file);
    return .{ .array_of_DocumentSymbol = try ide.document_symbol.documentSymbols(arena, items, map, lines, server.encoding) };
}

fn foldingRange(server: *Server, ctx: *Db.Ctx, arena: Allocator, params: types.FoldingRangeParams) HandlerError!types.ResultType("textDocument/foldingRange") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const parse = try ctx.get(syntax_q.ParseFile, file);
    const lines = try fileLines(ctx, arena, file);
    return try ide.folding.foldingRanges(arena, parse.rootNode(), lines);
}

fn selectionRange(server: *Server, ctx: *Db.Ctx, arena: Allocator, params: types.SelectionRangeParams) HandlerError!types.ResultType("textDocument/selectionRange") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const parse = try ctx.get(syntax_q.ParseFile, file);
    const lines = try fileLines(ctx, arena, file);
    return try ide.selection_range.selectionRanges(arena, parse.rootNode(), lines, server.encoding, params.positions);
}

fn semanticTokensFull(server: *Server, r: *Resolver, arena: Allocator, params: types.SemanticTokensParams) HandlerError!types.ResultType("textDocument/semanticTokens/full") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const lines = try fileLines(r.ctx, arena, file);
    const data = try ide.semantic_tokens.semanticTokens(r, file, lines, server.encoding, null);
    const result = try server.semanticTokensResult(r.ctx, arena, file, data, null);
    return result.SemanticTokens;
}

fn semanticTokensDelta(server: *Server, r: *Resolver, arena: Allocator, params: types.SemanticTokensDeltaParams) HandlerError!types.ResultType("textDocument/semanticTokens/full/delta") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const lines = try fileLines(r.ctx, arena, file);
    const data = try ide.semantic_tokens.semanticTokens(r, file, lines, server.encoding, null);
    return try server.semanticTokensResult(r.ctx, arena, file, data, params.previousResultId);
}

fn semanticTokensResult(server: *Server, ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId, data: []const u32, previous_id: ?[]const u8) HandlerError!SemanticCache.Result {
    const is_open = blk: {
        server.docs_mutex.lockUncancelable(server.io);
        defer server.docs_mutex.unlock(server.io);
        break :blk server.open_docs.contains(file);
    };
    try ctx.checkCanceled();
    // 读事务保证关闭时会先等本请求退出；未打开的文档只返回数据，不保存可跨会话复用的快照。
    if (!is_open) return .{ .SemanticTokens = .{ .data = data } };
    return try server.semantic_cache.update(server.io, server.gpa, arena, file, data, previous_id);
}

fn semanticTokensRange(server: *Server, r: *Resolver, arena: Allocator, params: types.SemanticTokensRangeParams) HandlerError!types.ResultType("textDocument/semanticTokens/range") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const lines = try fileLines(r.ctx, arena, file);
    return .{ .data = try ide.semantic_tokens.semanticTokens(r, file, lines, server.encoding, params.range) };
}

fn initialize(server: *Server, _: Allocator, params: types.InitializeParams) HandlerError!types.InitializeResult {
    // 优先 UTF-8（与内部字节偏移一致），否则回落到协议默认的 UTF-16
    if (params.capabilities.general) |general| {
        if (general.positionEncodings) |encodings| {
            for (encodings) |e| {
                if (offsets.Encoding.fromLsp(e) == .utf8) server.encoding = .utf8;
            }
        }
    }
    server.state = .running;
    if (params.capabilities.window) |window| server.progress.enabled = window.workDoneProgress orelse false;
    if (params.capabilities.workspace) |ws| {
        server.pull_config = ws.configuration orelse false;
        if (ws.didChangeConfiguration) |d| server.register_config = d.dynamicRegistration orelse false;
        if (ws.didChangeWatchedFiles) |d| server.register_watch = d.dynamicRegistration orelse false;
        if (ws.inlayHint) |ih| server.inlay_refresh = ih.refreshSupport orelse false;
        if (ws.semanticTokens) |st| server.semantic_refresh = st.refreshSupport orelse false;
        if (ws.workspaceEdit) |we| server.change_annotations = (we.documentChanges orelse false) and we.changeAnnotationSupport != null;
    }
    if (params.capabilities.textDocument) |td| if (td.codeAction) |ca| {
        server.code_action_disabled = ca.disabledSupport orelse false;
        if (ca.resolveSupport) |rs| for (rs.properties) |p| {
            if (std.mem.eql(u8, p, "edit")) server.code_action_resolve = ca.dataSupport orelse false;
        };
    };
    if (params.initializationOptions) |options| if (options != .null) {
        server.config = Config.parse(server.gpa, options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidConfig => blk: {
                server.showWarning("invalid zig-analyzer initializationOptions, using defaults");
                break :blk .{};
            },
        };
        server.reportConfigWarnings("zig-analyzer settings", &server.config);
        server.applyLogging(&server.config, server.config.log_file != null);
    };
    log.info("initialized, position encoding {t}", .{server.encoding});
    if (params.processId) |pid| server.watchParent(pid);

    // 工作区根目录：优先 workspaceFolders，其次 rootUri / rootPath
    var root_uris: std.ArrayList([]const u8) = .empty;
    defer root_uris.deinit(server.gpa);
    if (params.workspaceFolders) |folders| for (folders) |f| try root_uris.append(server.gpa, f.uri);
    if (root_uris.items.len == 0) if (params.rootUri) |r| try root_uris.append(server.gpa, r);
    for (root_uris.items) |root_uri| try server.addRoot(root_uri);

    return .{
        .capabilities = .{
            .positionEncoding = server.encoding.toLsp(),
            .textDocumentSync = .{ .TextDocumentSyncOptions = .{
                .openClose = true,
                .change = .Incremental,
                .save = .{ .boolean = true },
            } },
            .documentFormattingProvider = .{ .boolean = true },
            .documentSymbolProvider = .{ .boolean = true },
            .foldingRangeProvider = .{ .boolean = true },
            .selectionRangeProvider = .{ .boolean = true },
            .definitionProvider = .{ .boolean = true },
            .declarationProvider = .{ .boolean = true },
            .typeDefinitionProvider = .{ .boolean = true },
            .completionProvider = .{ .triggerCharacters = &.{ ".", "@", "\"", "/" } },
            .hoverProvider = .{ .boolean = true },
            .signatureHelpProvider = .{ .triggerCharacters = &.{ "(", "," } },
            .inlayHintProvider = .{ .boolean = true },
            .referencesProvider = .{ .boolean = true },
            .documentHighlightProvider = .{ .boolean = true },
            .renameProvider = .{ .RenameOptions = .{ .prepareProvider = true } },
            .workspaceSymbolProvider = .{ .boolean = true },
            .workspace = .{ .workspaceFolders = .{ .supported = true, .changeNotifications = .{ .boolean = true } } },
            .codeActionProvider = .{ .CodeActionOptions = .{
                .codeActionKinds = &.{ types.CodeActionKind.QuickFix, types.CodeActionKind.RefactorExtract },
                .resolveProvider = true,
            } },
            .semanticTokensProvider = .{ .SemanticTokensOptions = .{
                .legend = ide.semantic_tokens.legend,
                .full = .{ .SemanticTokensFullDelta = .{ .delta = true } },
                .range = .{ .boolean = true },
            } },
        },
        .serverInfo = .{ .name = "zig-analyzer", .version = za.version },
    };
}

fn shutdown(server: *Server, _: Allocator, _: void) HandlerError!void {
    // 先解除依赖主循环的等待：客户端一直没有回复配置请求时不再等待。之后主循环阻塞在 await 上，
    // 处理不了补发的响应，进行中的 `waitIdle` 请求只能靠这里结束
    server.abandonConfigRequests();
    // 停止各项目的构建系统进程；等待进行中的请求完成，再等后台任务（诊断发布等）收尾
    server.stopWorkspaces();
    server.group.await(server.io) catch {};
    server.waitIdle();
    server.state = .shutdown;
}

const StatusResult = struct {
    revision: u64,
    files: usize,
    deep_verifications: u64,
    /// 写事务的次数（见 `db.Stats.writes`）
    writes: u64,
    /// 进程的常驻内存峰值（KB；不支持的平台为 0）
    max_rss_kb: u64,
    /// InternPool 中的类型与值的个数
    intern_pool_items: usize,
    /// InternPool 占用的字节数
    intern_pool_bytes: usize,
    /// 经由服务器分配器分配、尚未释放的字节数（可执行文件以 `mem.Counting` 包装分配器时；否则为 0）
    heap_bytes: usize,
    queries: []const struct {
        name: []const u8,
        executions: u64,
        hits: u64,
        cutoffs: u64,
        total_ms: f64,
        self_ms: f64,
        max_ms: f64,
        memos: usize,
        keys: usize,
        /// 保留着的值占用的字节数（声明了 `bytes` 的 query；否则为 0）
        bytes: usize,
        deps: usize,
        incomplete: u64,
    },
    /// 结果不完整的原因（环、栈深度、燃料）的累计次数
    incomplete_causes: struct { cycle: u64, stack: u64, fuel: u64 },
};

fn definition(server: *Server, r: *Resolver, arena: Allocator, params: types.DefinitionParams) HandlerError!types.ResultType("textDocument/definition") {
    const locs = try server.gotoTargets(r, arena, params.textDocument.uri, params.position, ide.definition.definitionTargets);
    return switch (locs.len) {
        0 => null,
        1 => .{ .Definition = .{ .Location = locs[0] } },
        else => .{ .Definition = .{ .array_of_Location = locs } },
    };
}

fn declaration(server: *Server, r: *Resolver, arena: Allocator, params: types.DeclarationParams) HandlerError!types.ResultType("textDocument/declaration") {
    const locs = try server.gotoTargets(r, arena, params.textDocument.uri, params.position, ide.definition.declarationTargets);
    return switch (locs.len) {
        0 => null,
        1 => .{ .Declaration = .{ .Location = locs[0] } },
        else => .{ .Declaration = .{ .array_of_Location = locs } },
    };
}

fn typeDefinition(server: *Server, r: *Resolver, arena: Allocator, params: types.TypeDefinitionParams) HandlerError!types.ResultType("textDocument/typeDefinition") {
    const at = try server.textPosition(r, arena, params.textDocument.uri, params.position) orelse return null;
    const t = try ide.definition.typeDefinition(r, at.file, at.offset) orelse return null;
    return .{ .Definition = .{ .Location = try server.targetLocation(r, arena, t) } };
}

/// 按 `find` 求光标处的全部跳转目标
fn gotoTargets(server: *Server, r: *Resolver, arena: Allocator, document_uri: []const u8, pos: types.Position, comptime find: anytype) ![]const types.Location {
    const at = try server.textPosition(r, arena, document_uri, pos) orelse return &.{};
    const targets = try find(r, at.file, at.offset);
    const locs = try arena.alloc(types.Location, targets.len);
    for (targets, locs) |t, *loc| loc.* = try server.targetLocation(r, arena, t);
    return locs;
}

fn targetLocation(server: *Server, r: *Resolver, arena: Allocator, t: ide.definition.Target) !types.Location {
    const target_text = (try r.ctx.get(syntax_q.SourceText, t.file)).text;
    const lines = try offsets.LineIndex.init(arena, target_text);
    return .{ .uri = try server.uriFor(arena, t.file), .range = lines.range(t.start, t.end, server.encoding) };
}

fn completion(server: *Server, r: *Resolver, arena: Allocator, params: types.CompletionParams) HandlerError!types.ResultType("textDocument/completion") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const text = try r.ctx.get(FileText, file) orelse return null;
    const offset: u32 = @intCast(offsets.positionToOffset(text, params.position, server.encoding));
    const items = try ide.completion.complete(r, file, offset);
    const out = try arena.alloc(types.CompletionItem, items.len);
    var lines: ?offsets.LineIndex = null;
    for (items, out) |it, *o| {
        o.* = .{
            .label = it.label,
            .kind = switch (it.kind) {
                .param, .local, .capture, .variable => .Variable,
                .function, .builtin => .Function,
                .constant => .Constant,
                .field => .Field,
                .enum_member => .EnumMember,
                .error_name => .Constant,
                .module => .Module,
                .file => .File,
                .folder => .Folder,
                .label => .Reference,
            },
            .documentation = if (it.doc) |d| .{ .MarkupContent = .{ .kind = .markdown, .value = d } } else null,
            .detail = it.detail,
        };
        if (it.replace) |range| {
            if (lines == null) lines = try offsets.LineIndex.init(arena, text);
            o.textEdit = .{ .TextEdit = .{ .range = lines.?.range(range.start, range.end, server.encoding), .newText = it.label } };
        }
    }
    return .{ .array_of_CompletionItem = out };
}

/// 请求中的文件、内容与位置
fn textPosition(server: *Server, r: *Resolver, arena: Allocator, document_uri: []const u8, pos: types.Position) !?struct { file: Vfs.FileId, text: []const u8, offset: u32 } {
    const file = try server.lookupFile(arena, document_uri) orelse return null;
    const text = (try r.ctx.get(syntax_q.SourceText, file)).text;
    return .{ .file = file, .text = text, .offset = @intCast(offsets.positionToOffset(text, pos, server.encoding)) };
}

fn hover(server: *Server, r: *Resolver, arena: Allocator, params: types.HoverParams) HandlerError!types.ResultType("textDocument/hover") {
    const at = try server.textPosition(r, arena, params.textDocument.uri, params.position) orelse return null;
    const info = try ide.hover.hover(r, at.file, at.offset) orelse return null;
    const lines = try offsets.LineIndex.init(arena, at.text);
    return .{
        .contents = .{ .MarkupContent = .{ .kind = .markdown, .value = info.text } },
        .range = lines.range(info.start, info.end, server.encoding),
    };
}

fn signatureHelp(server: *Server, r: *Resolver, arena: Allocator, params: types.SignatureHelpParams) HandlerError!types.ResultType("textDocument/signatureHelp") {
    const at = try server.textPosition(r, arena, params.textDocument.uri, params.position) orelse return null;
    const sig = try ide.signature_help.signatureHelp(r, at.file, at.offset) orelse return null;
    const ps = try arena.alloc(types.ParameterInformation, sig.params.len);
    for (sig.params, ps) |p, *o| o.* = .{ .label = .{ .string = p } };
    const info = try arena.alloc(types.SignatureInformation, 1);
    info[0] = .{
        .label = sig.label,
        .parameters = ps,
        .activeParameter = if (ps.len == 0) null else sig.active,
        .documentation = if (sig.doc) |d| .{ .MarkupContent = .{ .kind = .markdown, .value = d } } else null,
    };
    return .{ .signatures = info, .activeSignature = 0, .activeParameter = if (ps.len == 0) null else sig.active };
}

fn inlayHint(server: *Server, r: *Resolver, arena: Allocator, params: types.InlayHintParams) HandlerError!types.ResultType("textDocument/inlayHint") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const text = (try r.ctx.get(syntax_q.SourceText, file)).text;
    const start, const end = server.rangeOffsets(text, params.range);
    const opts: ide.inlay_hints.Options = blk: {
        server.config_mutex.lockUncancelable(server.io);
        defer server.config_mutex.unlock(server.io);
        break :blk .{ .types = server.config.inlay_types, .parameters = server.config.inlay_parameters, .hide_redundant_param_names = server.config.hide_redundant_param_names };
    };
    const hints = try ide.inlay_hints.inlayHints(r, file, start, end, opts);
    const lines = try offsets.LineIndex.init(arena, text);
    const out = try arena.alloc(types.InlayHint, hints.len);
    for (hints, out) |h, *o| o.* = .{
        .position = lines.position(h.offset, server.encoding),
        .label = .{ .string = h.label },
        .kind = switch (h.kind) {
            .type => .Type,
            .parameter => .Parameter,
        },
        .paddingRight = if (h.kind == .parameter) true else null,
        .tooltip = if (h.tooltip) |t| .{ .string = t } else null,
    };
    return out;
}

/// 引用查找与 workspace symbol 的范围：模块图中的项目文件（不含标准库）与打开的文档
fn searchScope(server: *Server, r: *Resolver) ![]const Vfs.FileId {
    var set: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty;
    for (try za.ide_db.search.projectFiles(r)) |f| try set.put(r.arena, f, {});
    server.docs_mutex.lockUncancelable(server.io);
    defer server.docs_mutex.unlock(server.io);
    for (server.open_docs.keys()) |f| try set.put(r.arena, f, {});
    return set.keys();
}

/// workspace symbol 的范围：默认不含依赖库中的文件，由 `workspace_symbol.dependencies` 开启。索引进行中时
/// 只取已建立索引的文件与打开的文档，不在请求中解析其余文件（LSP 的 workspace/symbol 没有 isIncomplete：客户端随
/// 输入重新请求，结果随索引的进展补全）
fn symbolScope(server: *Server, r: *Resolver) ![]const Vfs.FileId {
    var scope = try server.searchScope(r);
    const dependencies = blk: {
        server.config_mutex.lockUncancelable(server.io);
        defer server.config_mutex.unlock(server.io);
        break :blk server.config.workspace_symbol_dependencies;
    };
    if (!dependencies) {
        const rules = try server.originRules(r.arena);
        var user: std.ArrayList(Vfs.FileId) = .empty;
        for (scope) |f| if (!origin.classify(&server.vfs, rules, server.vfs.path(f), false).isLibrary()) try user.append(r.arena, f);
        scope = user.items;
    }
    if (!server.indexing.load(.acquire)) return scope;
    var out: std.ArrayList(Vfs.FileId) = .empty;
    server.indexed_mutex.lockUncancelable(server.io);
    defer server.indexed_mutex.unlock(server.io);
    server.docs_mutex.lockUncancelable(server.io);
    defer server.docs_mutex.unlock(server.io);
    for (scope) |f| if (server.indexed.contains(f) or server.open_docs.contains(f)) try out.append(r.arena, f);
    return out.items;
}

/// 光标处的定义及其全部引用
/// `ambiguous` 不为 null 时记录第一处有歧义的引用（见 `search.Options.ambiguous`），`unanalyzed` 同理
/// （见 `search.Options.unanalyzed`）
fn referencesAt(server: *Server, r: *Resolver, arena: Allocator, document_uri: []const u8, pos: types.Position, only_file: bool, ambiguous: ?*?za.ide_db.search.Reference, unanalyzed: ?*bool) !?struct { def: za.names.resolve.Def, refs: []const za.ide_db.search.Reference } {
    const at = try server.textPosition(r, arena, document_uri, pos) orelse return null;
    const def = try ide.definition.defAt(r, at.file, at.offset) orelse return null;
    const scope = try server.searchScope(r);
    const refs = try za.ide_db.search.findReferences(r, def, .{ .scope = scope, .only_file = if (only_file) at.file else null, .ambiguous = ambiguous, .unanalyzed = unanalyzed });
    return .{ .def = def, .refs = refs };
}

/// 引用位置转为 LSP 区间（按文件缓存行索引）
const RangeMapper = struct {
    server: *Server,
    r: *Resolver,
    file: ?Vfs.FileId = null,
    lines: offsets.LineIndex = undefined,

    fn range(m: *RangeMapper, file: Vfs.FileId, start: u32, end: u32) !types.Range {
        if (m.file != file) {
            m.lines = try offsets.LineIndex.init(m.r.arena, (try m.r.ctx.get(syntax_q.SourceText, file)).text);
            m.file = file;
        }
        return m.lines.range(start, end, m.server.encoding);
    }
};

fn references(server: *Server, r: *Resolver, arena: Allocator, params: types.ReferenceParams) HandlerError!types.ResultType("textDocument/references") {
    const found = try server.referencesAt(r, arena, params.textDocument.uri, params.position, false, null, null) orelse return null;
    var out: std.ArrayList(types.Location) = .empty;
    var m: RangeMapper = .{ .server = server, .r = r };
    for (found.refs) |ref| {
        if (ref.is_decl and !params.context.includeDeclaration) continue;
        try out.append(arena, .{ .uri = try server.uriFor(arena, ref.file), .range = try m.range(ref.file, ref.start, ref.end) });
    }
    return out.items;
}

fn documentHighlight(server: *Server, r: *Resolver, arena: Allocator, params: types.DocumentHighlightParams) HandlerError!types.ResultType("textDocument/documentHighlight") {
    const found = try server.referencesAt(r, arena, params.textDocument.uri, params.position, true, null, null) orelse return null;
    const out = try arena.alloc(types.DocumentHighlight, found.refs.len);
    var m: RangeMapper = .{ .server = server, .r = r };
    for (found.refs, out) |ref, *o| o.* = .{ .range = try m.range(ref.file, ref.start, ref.end), .kind = if (ref.is_decl) .Write else .Read };
    return out;
}

/// 可以重命名的定义：用户自己的代码（见 `origin.Origin.user`）与未保存的文档
fn renamable(server: *Server, r: *Resolver, def: za.names.resolve.Def) !bool {
    if (def == .file or try za.ide_db.search.defName(r, def) == null) return false;
    const file = switch (def) {
        .item => |it| it.file,
        .local => |l| l.file,
        .file => unreachable,
    };
    const rules = try server.originRules(r.arena);
    return switch (origin.classify(&server.vfs, rules, server.vfs.path(file), server.inProject(file))) {
        // 未保存的文档（`untitled:` 等）只存在于编辑器中
        .virtual, .user => true,
        .zig_lib, .generated, .package, .other => false,
    };
}

fn prepareRename(server: *Server, r: *Resolver, arena: Allocator, params: types.PrepareRenameParams) HandlerError!types.ResultType("textDocument/prepareRename") {
    const at = try server.textPosition(r, arena, params.textDocument.uri, params.position) orelse return null;
    const tok = try ide.definition.tokenAt(r, at.file, at.offset) orelse return null;
    if (tok.kind != .identifier) return null;
    const def = try ide.definition.defAt(r, at.file, at.offset) orelse return null;
    if (!try server.renamable(r, def)) return error.RenameOutsideWorkspace;
    const lines = try offsets.LineIndex.init(arena, at.text);
    return .{ .PrepareRenamePlaceholder = .{
        .range = lines.range(tok.offset, tok.offset + @as(u32, @intCast(tok.text.len)), server.encoding),
        .placeholder = za.syntax.ast.identName(tok.text),
    } };
}

fn rename(server: *Server, r: *Resolver, arena: Allocator, params: types.RenameParams) HandlerError!types.ResultType("textDocument/rename") {
    _ = try identifierText(arena, params.newName, false);
    var ambiguous: ?za.ide_db.search.Reference = null;
    var unanalyzed = false;
    const found = try server.referencesAt(r, arena, params.textDocument.uri, params.position, false, &ambiguous, &unanalyzed) orelse return null;
    if (!try server.renamable(r, found.def)) return error.RenameOutsideWorkspace;
    // 不返回只改了一部分的结果
    if (ambiguous != null) return error.RenameAmbiguous;
    if (unanalyzed) return error.RenameUnanalyzed;
    const is_field = switch (found.def) {
        .item => |it| (try r.itemTree(it.file)).items[it.item].kind == .field,
        .local, .file => false,
    };
    const new_name = try identifierText(arena, params.newName, is_field);
    return try server.renameEdit(r, arena, found.refs, new_name, null);
}

/// 把引用（按文件与位置排列，含声明处）改为 `new_text` 的编辑。`confirm` 不为 null 且客户端支持变更注解时，
/// 编辑带上要求用户确认的注解（`confirm` 为其标签），客户端应用之前先让用户确认
fn renameEdit(server: *Server, r: *Resolver, arena: Allocator, refs: []const za.ide_db.search.Reference, new_text: []const u8, confirm: ?[]const u8) !types.WorkspaceEdit {
    const annotated = confirm != null and server.change_annotations;
    const DocumentChange = @typeInfo(@typeInfo(@FieldType(types.WorkspaceEdit, "documentChanges")).optional.child).pointer.child;
    const DocumentEdit = @typeInfo(@FieldType(types.TextDocumentEdit, "edits")).pointer.child;
    const annotation_id = "zig-analyzer.rename-public";
    var changes: std.json.ArrayHashMap([]const types.TextEdit) = .{};
    var documents: std.ArrayList(DocumentChange) = .empty;
    var m: RangeMapper = .{ .server = server, .r = r };
    var i: usize = 0;
    while (i < refs.len) {
        const file = refs[i].file;
        const file_uri = try server.uriFor(arena, file);
        if (annotated) {
            var edits: std.ArrayList(DocumentEdit) = .empty;
            while (i < refs.len and refs[i].file == file) : (i += 1) {
                const ref = refs[i];
                try edits.append(arena, .{ .AnnotatedTextEdit = .{ .range = try m.range(file, ref.start, ref.end), .newText = new_text, .annotationId = annotation_id } });
            }
            try documents.append(arena, .{ .TextDocumentEdit = .{ .textDocument = .{ .uri = file_uri, .version = null }, .edits = edits.items } });
        } else {
            var edits: std.ArrayList(types.TextEdit) = .empty;
            while (i < refs.len and refs[i].file == file) : (i += 1) {
                const ref = refs[i];
                try edits.append(arena, .{ .range = try m.range(file, ref.start, ref.end), .newText = new_text });
            }
            try changes.map.put(arena, file_uri, edits.items);
        }
    }
    if (!annotated) return .{ .changes = changes };
    var annotations: std.json.ArrayHashMap(types.ChangeAnnotation) = .{};
    try annotations.map.put(arena, annotation_id, .{
        .label = confirm.?,
        .needsConfirmation = true,
        .description = "code outside this workspace that uses the name is not updated",
    });
    return .{ .documentChanges = documents.items, .changeAnnotations = annotations };
}

/// 新名字的源码写法：`@"..."` 校验后原样使用；其余按需用 `@"..."` 包裹：关键字、含特殊字符的名字、`_`，
/// 以及原生类型与值的名字（`u8`、`true`；声明与局部变量不能与它们同名）。`is_field` 时原生名字原样使用：
/// 字段的声明与 `.` 之后的访问都可以用它们（如 `std.json.Value` 的 `null`、`bool`）
fn identifierText(arena: Allocator, name: []const u8, is_field: bool) HandlerError![]const u8 {
    if (std.mem.startsWith(u8, name, "@\"")) {
        // 整个名字须是一个标识符 token，引号中的转义合法、不为空且不含 NUL
        var tokenizer: std.zig.Tokenizer = .init(try arena.dupeSentinel(u8, name, 0));
        const token = tokenizer.next();
        if (token.tag != .identifier or token.loc.end != name.len) return error.InvalidIdentifier;
        const decoded = std.zig.string_literal.parseAlloc(arena, name[1..]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidLiteral => return error.InvalidIdentifier,
        };
        if (decoded.len == 0 or std.mem.indexOfScalar(u8, decoded, 0) != null) return error.InvalidIdentifier;
        return name;
    }
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "\"\n\r\\\x00") != null) return error.InvalidIdentifier;
    return std.fmt.allocPrint(arena, "{f}", .{std.zig.fmtIdFlags(name, .{ .allow_primitive = is_field })});
}

test "rename: source text of the new name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("greet", try identifierText(a, "greet", false));
    try std.testing.expectEqualStrings("@\"fn\"", try identifierText(a, "fn", false));
    try std.testing.expectEqualStrings("@\"a b\"", try identifierText(a, "a b", false));
    // 原生类型与值的名字、`_`：原样写入时声明与原生名字同名，编译错误
    try std.testing.expectEqualStrings("@\"u8\"", try identifierText(a, "u8", false));
    try std.testing.expectEqualStrings("@\"true\"", try identifierText(a, "true", false));
    try std.testing.expectEqualStrings("@\"_\"", try identifierText(a, "_", false));
    // 字段可以与原生名字同名；`_` 在枚举中表示非穷尽，仍要加引号
    try std.testing.expectEqualStrings("bool", try identifierText(a, "bool", true));
    try std.testing.expectEqualStrings("@\"_\"", try identifierText(a, "_", true));
    try std.testing.expectEqualStrings("@\"x\\\"y\"", try identifierText(a, "@\"x\\\"y\"", false));
    try std.testing.expectError(error.InvalidIdentifier, identifierText(a, "@\"a\"b\"", false));
    try std.testing.expectError(error.InvalidIdentifier, identifierText(a, "@\"\"", false));
    try std.testing.expectError(error.InvalidIdentifier, identifierText(a, "", false));
    // 编译器拒绝含 NUL 的标识符
    try std.testing.expectError(error.InvalidIdentifier, identifierText(a, "a\x00b", false));
    try std.testing.expectError(error.InvalidIdentifier, identifierText(a, "@\"a\\x00b\"", false));
    try std.testing.expectError(error.InvalidIdentifier, identifierText(a, "@\"\\u{0}\"", false));
}

fn workspaceSymbol(server: *Server, r: *Resolver, arena: Allocator, params: types.WorkspaceSymbolParams) HandlerError!types.ResultType("workspace/symbol") {
    const scope = try server.symbolScope(r);
    const syms = try ide.workspace_symbol.search(r, scope, params.query);
    const out = try arena.alloc(types.WorkspaceSymbol, syms.len);
    var m: RangeMapper = .{ .server = server, .r = r };
    for (syms, out) |s, *o| o.* = .{
        .name = s.name,
        .kind = s.kind,
        .containerName = s.container,
        .location = .{ .Location = .{ .uri = try server.uriFor(arena, s.file), .range = try m.range(s.file, s.start, s.end) } },
    };
    return .{ .array_of_WorkspaceSymbol = out };
}

fn codeAction(server: *Server, r: *Resolver, arena: Allocator, params: types.CodeActionParams) HandlerError!types.ResultType("textDocument/codeAction") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const text = (try r.ctx.get(syntax_q.SourceText, file)).text;
    const start, const end = server.rangeOffsets(text, params.range);
    const actions = try ide.code_actions.codeActions(r, file, start, end);
    const lines = try offsets.LineIndex.init(arena, text);
    const doc_uri = try server.uriFor(arena, file);
    const Item = @typeInfo(@typeInfo(types.ResultType("textDocument/codeAction")).optional.child).pointer.child;
    var out: std.ArrayList(Item) = .empty;
    for (actions) |a| {
        const edits = try arena.alloc(types.TextEdit, a.edits.len);
        for (a.edits, edits) |e, *te| te.* = .{ .range = lines.range(e.start, e.end, server.encoding), .newText = e.text };
        var changes: std.json.ArrayHashMap([]const types.TextEdit) = .{};
        try changes.map.put(arena, doc_uri, edits);
        // 关联客户端传来的同一条诊断，使修复显示在诊断上
        const diagnostics: ?[]const types.Diagnostic = if (a.diagnostic) |d| blk: {
            const range = lines.range(d.start, d.end, server.encoding);
            for (params.context.diagnostics) |cd| {
                if (std.meta.eql(cd.range, range)) break :blk try arena.dupe(types.Diagnostic, &.{cd});
            }
            break :blk null;
        } else null;
        try out.append(arena, .{ .CodeAction = .{
            .title = a.title,
            .kind = switch (a.kind) {
                .quickfix => types.CodeActionKind.QuickFix,
                .refactor_extract => types.CodeActionKind.RefactorExtract,
            },
            .diagnostics = diagnostics,
            .isPreferred = if (a.diagnostic != null) true else null,
            .edit = .{ .changes = changes },
        } });
    }
    if (try server.namingFor(arena, file, text)) |settings| {
        for (try ide.naming.findings(r, file, .{ .start = start, .end = end })) |f| {
            if (!settings.allows(f)) continue;
            const range = lines.range(f.start, f.end, server.encoding);
            if (try server.namingAction(r, arena, doc_uri, range, f, params.context.diagnostics)) |action| try out.append(arena, .{ .CodeAction = action });
        }
    }
    return out.items;
}

/// 命名修复在 `textDocument/codeAction` 与 `codeAction/resolve` 之间保存的数据（`CodeAction.data`）
const NamingData = struct {
    naming: struct {
        uri: []const u8,
        /// 名字的起点
        line: u32,
        character: u32,
        name: []const u8,
        new_name: []const u8,
    },
};

/// 不符合命名约定的名字的改名修复，只在用户选择后应用（不标为 preferred）。客户端支持 `codeAction/resolve` 时
/// 只给出标题与 `data`，选择之后才查找引用、检查冲突；否则当场算出编辑。不能安全改名时，客户端支持 `disabled`
/// 则带上原因，否则不提供
fn namingAction(server: *Server, r: *Resolver, arena: Allocator, doc_uri: []const u8, range: types.Range, f: ide.naming.Located, client_diagnostics: []const types.Diagnostic) !?types.CodeAction {
    const what = if (f.def == .item and f.public) (if (f.rule == .field) "field " else "public ") else "";
    var action: types.CodeAction = .{
        .title = try std.fmt.allocPrint(arena, "rename {s}`{s}` to `{s}`", .{ what, f.name, f.suggestion }),
        .kind = types.CodeActionKind.QuickFix,
    };
    // 关联客户端传来的同一条提示
    for (client_diagnostics) |d| {
        const c = d.code orelse continue;
        if (c == .string and std.mem.eql(u8, c.string, f.rule.code()) and std.meta.eql(d.range, range)) {
            action.diagnostics = try arena.dupe(types.Diagnostic, &.{d});
            break;
        }
    }
    // 声明处的冲突不必查找引用
    if (try ide.rename.declarationConflict(r, f.def, f.suggestion)) |p| {
        if (!server.code_action_disabled) return null;
        action.disabled = .{ .reason = try server.renameProblem(r, arena, f, p.file, p.offset, p.message) };
        return action;
    }
    if (server.code_action_resolve) {
        const inner: std.json.ObjectMap = try .init(arena, &.{ "uri", "line", "character", "name", "new_name" }, &.{
            .{ .string = doc_uri },
            .{ .integer = range.start.line },
            .{ .integer = range.start.character },
            .{ .string = f.name },
            .{ .string = f.suggestion },
        });
        action.data = .{ .object = try .init(arena, &.{"naming"}, &.{.{ .object = inner }}) };
        return action;
    }
    switch (try server.namingEdit(r, arena, f)) {
        .ok => |edit| action.edit = edit,
        .failed => |reason| {
            if (!server.code_action_disabled) return null;
            action.disabled = .{ .reason = reason };
        },
    }
    return action;
}

/// 补上命名修复的编辑；其他代码操作在 `textDocument/codeAction` 中已经完整，原样返回
fn codeActionResolve(server: *Server, r: *Resolver, arena: Allocator, params: types.CodeAction) HandlerError!Outcome(types.CodeAction) {
    const value = params.data orelse return .{ .ok = params };
    const data = std.json.parseFromValueLeaky(NamingData, arena, value, .{ .ignore_unknown_fields = true }) catch return .{ .ok = params };
    const d = data.naming;
    const at = try server.textPosition(r, arena, d.uri, .{ .line = d.line, .character = d.character }) orelse
        return .{ .failed = "cannot rename: the document is no longer available" };
    // 两次请求之间文档可能已经改变：按位置重新找到这个名字
    const found = for (try ide.naming.findings(r, at.file, .{ .start = at.offset, .end = at.offset })) |f| {
        if (f.start == at.offset and std.mem.eql(u8, f.name, d.name) and std.mem.eql(u8, f.suggestion, d.new_name)) break f;
    } else return .{ .failed = "cannot rename: the name has changed since the fix was offered" };
    var action = params;
    switch (try server.namingEdit(r, arena, found)) {
        .ok => |edit| action.edit = edit,
        .failed => |reason| return .{ .failed = reason },
    }
    return .{ .ok = action };
}

/// 把不符合命名约定的名字改为建议的写法。只返回完整而安全的编辑：引用有无法确认之处（歧义、未分析的代码、
/// 类型未知的成员访问、有语法错误的文件），新名字与已有的名字冲突，或者名字以字符串出现（反射）时都不改
fn namingEdit(server: *Server, r: *Resolver, arena: Allocator, f: ide.naming.Located) !Outcome(types.WorkspaceEdit) {
    const def = f.def;
    const def_file = switch (def) {
        .item => |it| it.file,
        .local => |l| l.file,
        .file => unreachable,
    };
    if (!try server.renamable(r, def)) return .{ .failed = "cannot rename a symbol defined outside the workspace" };
    const scope = try server.searchScope(r);
    var ambiguous: ?za.ide_db.search.Reference = null;
    var unanalyzed = false;
    var uncertain: ?za.ide_db.search.Reference = null;
    var syntax_error: ?Vfs.FileId = null;
    const refs = try za.ide_db.search.findReferences(r, def, .{
        .scope = scope,
        .ambiguous = &ambiguous,
        .unanalyzed = &unanalyzed,
        .uncertain = &uncertain,
        .syntax_error = &syntax_error,
    });
    if (syntax_error) |file| return .{ .failed = try server.renameProblem(r, arena, f, file, null, "the file has syntax errors, so references in it may be missed") };
    if (unanalyzed) return .{ .failed = try server.renameProblem(r, arena, f, def_file, null, "the name appears in code nested too deeply to be analyzed, where references cannot be found") };
    if (ambiguous) |a| return .{ .failed = try server.renameProblem(r, arena, f, a.file, a.start, "this reference inside a generic function also refers to other declarations in some instantiations") };
    if (uncertain) |u| return .{ .failed = try server.renameProblem(r, arena, f, u.file, u.start, "the type here is unknown, so whether this refers to the same declaration cannot be confirmed") };
    if (try ide.rename.declarationConflict(r, def, f.suggestion)) |p| return .{ .failed = try server.renameProblem(r, arena, f, p.file, p.offset, p.message) };
    if (try ide.rename.resolutionConflict(r, def, f.suggestion)) |p| return .{ .failed = try server.renameProblem(r, arena, f, p.file, p.offset, p.message) };
    // 只有容器的成员能以字符串引用；不是 pub 的声明只能在所在的文件中访问
    if (def == .item) {
        const files = if (f.public) try za.ide_db.search.importers(r, def_file, scope) else try arena.dupe(Vfs.FileId, &.{def_file});
        if (try ide.rename.stringReference(r, files, f.name)) |p| return .{ .failed = try server.renameProblem(r, arena, f, p.file, p.offset, p.message) };
    }
    const is_field = switch (def) {
        .item => |it| (try r.itemTree(it.file)).items[it.item].kind == .field,
        .local, .file => false,
    };
    const new_text = try identifierText(arena, f.suggestion, is_field);
    // 遮蔽与重名只会出现在声明所在的文件中，这个文件中漏改的引用也会报出：以改名后的文本做 AstGen 确认
    var edits: std.ArrayList(ide.rename.Edit) = .empty;
    for (refs) |ref| if (ref.file == def_file) try edits.append(arena, .{ .start = ref.start, .end = ref.end, .text = new_text });
    if (try ide.rename.verifyAstGen(r, def_file, edits.items)) |p| return .{ .failed = try server.renameProblem(r, arena, f, p.file, p.offset, p.message) };
    const confirm = if (f.public) try std.fmt.allocPrint(arena, "Rename public `{s}` to `{s}`", .{ f.name, f.suggestion }) else null;
    return .{ .ok = try server.renameEdit(r, arena, refs, new_text, confirm) };
}

/// 不能改名的说明：「cannot rename `a` to `b`: 原因 (文件:行:列)」，位置为 null 时只有文件
fn renameProblem(server: *Server, r: *Resolver, arena: Allocator, f: ide.naming.Located, file: Vfs.FileId, offset: ?u32, reason: []const u8) ![]const u8 {
    const path = server.vfs.path(file);
    const shown = if (try server.rootOf(arena, path)) |root| std.mem.trimStart(u8, path[root.len..], "/\\") else path;
    const at = offset orelse return std.fmt.allocPrint(arena, "cannot rename `{s}` to `{s}`: {s} ({s})", .{ f.name, f.suggestion, reason, shown });
    const text = (try r.ctx.get(syntax_q.SourceText, file)).text;
    const pos = (try offsets.LineIndex.init(arena, text)).position(at, server.encoding);
    return std.fmt.allocPrint(arena, "cannot rename `{s}` to `{s}`: {s} ({s}:{d}:{d})", .{ f.name, f.suggestion, reason, shown, pos.line + 1, pos.character + 1 });
}

/// 以文档为参数的检查请求
const DocumentParams = struct { textDocument: types.TextDocumentIdentifier };

const FileStatusResult = struct {
    path: []const u8,
    /// 文件的来源（见 `origin.Origin`）
    origin: origin.Origin,
    /// 编译上下文（见 `FileContext`）
    context: FileContext,
    open: bool,
    /// 文件在模块图中所属的模块（以根文件表示，标准库为 `std`，尚未得知路径的生成文件为空串），按优先级排列；
    /// 不在模块图中时为空
    modules: []const []const u8,
    /// 包含它的项目的根目录及其最近一次构建
    projects: []const struct { root: []const u8, last_build: ?Workspace.LastBuild },
    /// 读过它（或在其中报告了错误）的单文件编译的根文件
    single_file_roots: []const []const u8,
};

/// 文件被当作什么处理：来源、编译上下文、所属的模块与项目、相关的单文件编译。用户报告诊断或名字解析的问题时
/// 据此判断
fn fileStatus(server: *Server, ctx: *Db.Ctx, arena: Allocator, params: DocumentParams) HandlerError!?FileStatusResult {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const open = blk: {
        server.docs_mutex.lockUncancelable(server.io);
        defer server.docs_mutex.unlock(server.io);
        break :blk server.open_docs.contains(file);
    };
    var modules: std.ArrayList([]const u8) = .empty;
    if (try ctx.get(ModuleGraph.Input, {})) |g| if (g.entry(file)) |e| {
        try modules.append(arena, server.moduleName(g, e.module));
        for (e.others) |m| try modules.append(arena, server.moduleName(g, m));
    };
    const Project = @typeInfo(@FieldType(FileStatusResult, "projects")).pointer.child;
    var projects: std.ArrayList(Project) = .empty;
    {
        const list = try server.workspaceList(arena);
        defer server.releaseList(arena, list);
        for (list) |ws| if (ws.contains(file)) try projects.append(arena, .{ .root = try arena.dupe(u8, ws.root), .last_build = ws.lastBuild() });
    }
    var roots: std.ArrayList([]const u8) = .empty;
    {
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        for (server.single.keys(), server.single.values()) |root, *sf| {
            if (root == file or sf.inputs.contains(file) or sf.files.contains(file)) try roots.append(arena, server.vfs.path(root));
        }
    }
    return .{
        .path = server.vfs.path(file),
        .origin = server.fileOrigin(file),
        .context = server.fileContext(file),
        .open = open,
        .modules = modules.items,
        .projects = projects.items,
        .single_file_roots = roots.items,
    };
}

fn moduleName(server: *Server, g: *const ModuleGraph, module: u32) []const u8 {
    if (module == ModuleGraph.std_module) return "std";
    const root = g.modules[module].root orelse return "";
    return server.vfs.path(root);
}

/// 文档的语法树：缩进的节点与 token（不含 trivia），之后是语法错误。用于判断解析与错误恢复的问题
fn syntaxTree(server: *Server, ctx: *Db.Ctx, arena: Allocator, params: DocumentParams) HandlerError!?[]const u8 {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const parse = try ctx.get(syntax_q.ParseFile, file);
    var out: std.Io.Writer.Allocating = .init(arena);
    parse.rootNode().dump(&out.writer, .{}) catch return error.OutOfMemory;
    for (parse.errors) |e| out.writer.print("error@{d}: {s}\n", .{ e.offset, e.message }) catch return error.OutOfMemory;
    return out.written();
}

const ModuleGraphResult = struct {
    /// 标准库的根文件
    std_root: ?[]const u8,
    modules: []const struct {
        /// 根文件；尚未得知路径的生成文件为 null
        root: ?[]const u8,
        /// 按模块参数生成的 builtin.zig
        builtin: ?[]const u8,
        imports: []const struct { name: []const u8, module: u32 },
        /// 属于它的文件数（含同时属于其他模块的）
        files: usize,
    },
};

/// 模块图（由各项目的构建图汇总，见 `updateModuleGraph`）：各模块的根文件、builtin、import 与文件数。用于判断
/// import 与名字解析的问题
fn moduleGraph(server: *Server, ctx: *Db.Ctx, arena: Allocator, _: void) HandlerError!ModuleGraphResult {
    const g = try ctx.get(ModuleGraph.Input, {}) orelse return .{ .std_root = null, .modules = &.{} };
    const Item = @typeInfo(@FieldType(ModuleGraphResult, "modules")).pointer.child;
    const Import = @typeInfo(@FieldType(Item, "imports")).pointer.child;
    const out = try arena.alloc(Item, g.modules.len);
    for (g.modules, out) |m, *o| {
        const imports = try arena.alloc(Import, m.imports.len);
        // 响应在读事务结束后才序列化：模块图可能已被替换，名字复制出来
        for (m.imports, imports) |imp, *x| x.* = .{ .name = try arena.dupe(u8, imp.name), .module = imp.module };
        o.* = .{
            .root = if (m.root) |r| server.vfs.path(r) else null,
            .builtin = if (m.builtin) |b| server.vfs.path(b) else null,
            .imports = imports,
            .files = 0,
        };
    }
    // 标准库文件（`std_module`）不计入
    for (g.files) |e| {
        if (e.module < out.len) out[e.module].files += 1;
        for (e.others) |m| if (m < out.len) {
            out[m].files += 1;
        };
    }
    return .{ .std_root = if (g.std_root) |r| server.vfs.path(r) else null, .modules = out };
}

/// 重启全部项目（同保存 build.zig）：构建图或编译结果需要手动刷新时使用
fn reloadWorkspace(server: *Server, arena: Allocator, _: void) HandlerError!void {
    const list = try server.workspaceList(arena);
    defer server.releaseList(arena, list);
    if (list.len != 0) log.info("restarting projects on request", .{});
    for (list) |ws| server.restartWorkspace(ws, 0);
}

fn status(server: *Server, _: *Db.Ctx, arena: Allocator, _: void) HandlerError!StatusResult {
    var stats: [Db.query_types.len]za.db.QueryStats = undefined;
    const summary = server.db.stats(&stats);
    const queries = try arena.alloc(@typeInfo(@FieldType(StatusResult, "queries")).pointer.child, stats.len);
    inline for (Db.query_types, 0..) |Q, i| {
        const q = stats[i];
        queries[i] = .{
            .name = @typeName(Q),
            .executions = q.executions,
            .hits = q.hits,
            .cutoffs = q.cutoffs,
            .total_ms = za.db_report.ms(q.total_ns),
            .self_ms = za.db_report.ms(q.self_ns),
            .max_ms = za.db_report.ms(q.max_ns),
            .memos = q.memos,
            .keys = q.keys,
            .bytes = q.bytes,
            .deps = q.deps,
            .incomplete = q.incomplete,
        };
    }
    return .{
        .revision = summary.revision,
        .files = server.vfs.count(),
        .deep_verifications = summary.deep_verifications,
        .writes = summary.writes,
        .max_rss_kb = maxRssKb(),
        .intern_pool_items = server.ip.count(),
        .intern_pool_bytes = server.ip.bytes(),
        .heap_bytes = if (server.heap) |h| h.liveBytes() else 0,
        .queries = queries,
        .incomplete_causes = .{
            .cycle = summary.incomplete_causes.get(.cycle),
            .stack = summary.incomplete_causes.get(.stack),
            .fuel = summary.incomplete_causes.get(.fuel),
        },
    };
}

/// 进程的常驻内存峰值（KB）
fn maxRssKb() u64 {
    const builtin_os = @import("builtin").os.tag;
    if (builtin_os == .windows) {
        const w = std.os.windows;
        var c: w.PROCESS.VM_COUNTERS = undefined;
        if (w.ntdll.NtQueryInformationProcess(w.GetCurrentProcess(), .VmCounters, &c, @sizeOf(w.PROCESS.VM_COUNTERS), null) != .SUCCESS) return 0;
        return c.PeakWorkingSetSize / 1024;
    }
    if (builtin_os == .wasi) return 0;
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    const rss: u64 = @intCast(@max(0, usage.maxrss));
    // macOS 以字节为单位，Linux 以 KB 为单位
    return if (builtin_os == .macos) rss / 1024 else rss;
}

// ── 发送 ─────────────────────────────────────────────────────────────

fn send(server: *Server, bytes: []u8) void {
    defer server.gpa.free(bytes);
    server.out.writeMessage(bytes) catch |err| log.err("failed to write message: {t}", .{err});
}

fn sendResponse(server: *Server, id: jsonrpc.Id, result: anytype) void {
    const bytes = jsonrpc.response(server.gpa, id, result) catch return log.err("out of memory while building response", .{});
    server.send(bytes);
}

pub fn sendRequest(server: *Server, id: jsonrpc.Id, method: []const u8, params: anytype) void {
    const bytes = jsonrpc.request(server.gpa, id, method, params) catch return log.err("out of memory while building request", .{});
    server.send(bytes);
}

pub fn sendNotification(server: *Server, method: []const u8, params: anytype) void {
    const bytes = jsonrpc.notification(server.gpa, method, params) catch return log.err("out of memory while building notification", .{});
    server.send(bytes);
}

fn sendError(server: *Server, id: ?jsonrpc.Id, code: i32, message: []const u8) void {
    const bytes = jsonrpc.errorResponse(server.gpa, id, code, message) catch return log.err("out of memory while building error response", .{});
    server.send(bytes);
}

fn sendHandlerError(server: *Server, id: jsonrpc.Id, err: anyerror, canceled_by_client: bool) void {
    switch (err) {
        error.Canceled => if (canceled_by_client)
            server.sendError(id, jsonrpc.error_codes.request_cancelled, "request cancelled")
        else
            server.sendError(id, jsonrpc.error_codes.content_modified, "content modified"),
        error.InvalidParams => server.sendError(id, jsonrpc.error_codes.invalid_params, "invalid params"),
        error.RenameOutsideWorkspace => server.sendError(id, jsonrpc.error_codes.request_failed, "cannot rename a symbol defined outside the workspace"),
        error.RenameAmbiguous => server.sendError(id, jsonrpc.error_codes.request_failed, "cannot rename: a reference inside a generic function also refers to other declarations in some instantiations"),
        error.RenameUnanalyzed => server.sendError(id, jsonrpc.error_codes.request_failed, "cannot rename: the name appears in code nested too deeply to be analyzed, where references cannot be found"),
        error.InvalidIdentifier => server.sendError(id, jsonrpc.error_codes.request_failed, "new name is not a valid identifier"),
        else => server.sendError(id, jsonrpc.error_codes.internal_error, @errorName(err)),
    }
}

fn destroyArena(server: *Server, arena: *std.heap.ArenaAllocator) void {
    arena.deinit();
    server.gpa.destroy(arena);
}

test {
    _ = origin;
    _ = Workspace;
    _ = @import("Server_test.zig");
    _ = @import("semantic_tokens_test.zig");
    _ = @import("compiler_e2e_test.zig");
    _ = @import("names_e2e_test.zig");
    _ = @import("refs_e2e_test.zig");
    _ = @import("naming_e2e_test.zig");
    _ = @import("workspace_e2e_test.zig");
}
