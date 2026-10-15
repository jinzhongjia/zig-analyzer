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
const ModuleGraph = za.names.ModuleGraph;
const Resolver = za.names.resolve.Resolver;
const InternPool = za.sema.InternPool;
pub const Progress = @import("progress.zig");
pub const Config = @import("Config.zig");

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
busy_mutex: Io.Mutex = .init,
busy_cond: Io.Condition = .init,
busy: usize = 0,

/// 工作区根目录（绝对路径）：initialize 时给出，之后随 `workspace/didChangeWorkspaceFolders` 增减
roots: std.ArrayList([]u8) = .empty,
/// 与 `roots` 一一对应：根目录下是否有 build.zig（加入时同步检查，避免项目加载完成前误判）
root_has_build: std.ArrayList(bool) = .empty,
/// 保护 `roots` 与 `root_has_build`
roots_mutex: Io.Mutex = .init,

single_mutex: Io.Mutex = .init,
/// 单文件模式（不属于任何带 build.zig 的工作区）的编译结果
single: std.AutoArrayHashMapUnmanaged(Vfs.FileId, SingleFile) = .empty,
env_mutex: Io.Mutex = .init,
/// 启动后在后台查询；查询完成前为 null
zig_env: ?ZigEnv = null,
/// 不属于任何项目的文件使用的 builtin.zig（本机目标、Debug）；受 env_mutex 保护
default_builtin: ?[]u8 = null,
warned: bool = false,
workspaces_mutex: Io.Mutex = .init,
workspaces: std.ArrayList(*Workspace) = .empty,
/// 已开始停止所有项目（shutdown / exit / deinit）：此后不再重启项目
shutting_down: bool = false,
/// 已被重启替换的实例：其后台任务可能仍在收尾，退出时统一释放
retired: std.ArrayList(*Workspace) = .empty,

progress: Progress = .{},

/// 串行化模块图的更新，避免较旧的快照覆盖较新的
graph_mutex: Io.Mutex = .init,
/// 后台索引的代数：模块图每次更新加一
index_generation: std.atomic.Value(u64) = .init(0),
/// 配置 `sema.callsite_seeding`（经 `Env` 供 IDE 层读取）
callsite_seeding: std.atomic.Value(bool) = .init(true),
/// 慢请求日志的阈值（毫秒，0 为关闭），来自配置 `log.slow_request_ms`
slow_request_ms: std.atomic.Value(u32) = .init(100),
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
/// 已发出的拉取请求数；只采纳最近一次请求的响应
config_requests: u32 = 0,
/// 尚未收到响应的拉取请求数：等待期间计为忙碌（waitIdle 会等待配置生效）
config_outstanding: u32 = 0,
/// 首次拉取的响应到达前推迟项目启动（启动要用 zig.path 与构建参数）
startup_pending: bool = false,
/// 项目已启动：此后修改 zig.path 需要重启服务器
started: bool = false,

docs_mutex: Io.Mutex = .init,
/// 已打开的文档：客户端使用的 URI（发布诊断时原样使用）
open_docs: std.AutoArrayHashMapUnmanaged(Vfs.FileId, []u8) = .empty,
/// 当前显示着非空诊断的文件（需要时发布空列表清除）
published: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty,

pub const State = enum { uninitialized, running, shutdown };

const SingleFile = struct {
    result: ?compiler.BuildResult = null,
    running: bool = false,
    rerun: bool = false,
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
};

/// 原地初始化：查询引擎持有指向 `server.env` 的指针，因此 Server 不能在初始化后移动。
pub fn init(server: *Server, io: Io, gpa: Allocator, out: *transport.Writer) Allocator.Error!void {
    server.* = .{ .io = io, .gpa = gpa, .db = undefined, .vfs = .init(io, gpa), .ip = try .init(gpa, io), .env = undefined, .out = out };
    server.live_prepared = .{ .gpa = gpa };
    server.env = .{ .vfs = &server.vfs, .ip = &server.ip, .callsite_seeding = &server.callsite_seeding, .live_prepared = &server.live_prepared };
    server.db = .init(io, gpa, &server.env);
}

pub fn deinit(server: *Server) void {
    server.group.cancel(server.io);
    server.stopWorkspaces();
    server.waitIdle();
    server.bg_group.cancel(server.io);
    for (server.workspaces.items) |ws| ws.destroy();
    server.workspaces.deinit(server.gpa);
    server.indexed.deinit(server.gpa);
    server.edits.deinit(server.gpa);
    server.live_prepared.deinit();
    za.util.log.setFile(null) catch {};
    for (server.retired.items) |ws| ws.destroy();
    server.retired.deinit(server.gpa);
    for (server.roots.items) |r| server.gpa.free(r);
    server.roots.deinit(server.gpa);
    server.root_has_build.deinit(server.gpa);
    for (server.single.values()) |*sf| if (sf.result) |*r| r.deinit(server.gpa);
    server.single.deinit(server.gpa);
    if (server.zig_env) |*env| env.deinit(server.gpa);
    if (server.default_builtin) |p| server.gpa.free(p);
    for (server.open_docs.values()) |u| server.gpa.free(u);
    server.open_docs.deinit(server.gpa);
    server.published.deinit(server.gpa);
    server.progress.deinit(server.gpa);
    server.config.deinit(server.gpa);
    server.pending.deinit(server.gpa);
    server.db.deinit();
    server.ip.deinit();
    server.vfs.deinit();
    server.* = undefined;
}

/// 运行主循环直到收到 `exit` 或输入结束，返回进程退出码。
/// 返回前等待已调度的后台任务（诊断发布等）收尾；收到 `exit` 时还会停止各项目的构建系统进程。
/// 输入结束而未收到 `exit` 时项目继续运行，可以用新的输入再次调用（测试中用于在两段输入之间修改磁盘文件）。
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
    if (exited) server.stopWorkspaces();
    server.waitIdle();
    return if (server.state == .shutdown) 0 else 1;
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
                },
            };
        },
    }
    return .@"continue";
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
    .{ "textDocument/formatting", Mode.read, formatting },
    .{ "textDocument/documentSymbol", Mode.read, documentSymbol },
    .{ "textDocument/foldingRange", Mode.read, foldingRange },
    .{ "textDocument/selectionRange", Mode.read, selectionRange },
    .{ "textDocument/semanticTokens/full", Mode.read, semanticTokensFull },
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
};

fn processRequest(server: *Server, arena: *std.heap.ArenaAllocator, id: jsonrpc.Id, method: []const u8, params_value: json.Value) !void {
    const a = arena.allocator();
    inline for (request_handlers) |h| {
        if (std.mem.eql(u8, method, h[0])) {
            const is_initialize = comptime std.mem.eql(u8, h[0], "initialize");
            if (server.state == .uninitialized and !is_initialize) {
                server.destroyArena(arena);
                return server.sendError(id, jsonrpc.error_codes.server_not_initialized, "server not initialized");
            }
            if (server.state != .uninitialized and is_initialize or server.state == .shutdown) {
                server.destroyArena(arena);
                return server.sendError(id, jsonrpc.error_codes.invalid_request, "request not allowed in current state");
            }

            const func = h[2];
            const Params = LastParam(@TypeOf(func));
            const params = jsonrpc.parseParams(Params, a, params_value) catch |err| {
                server.destroyArena(arena);
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return server.sendError(id, jsonrpc.error_codes.invalid_params, "malformed params");
            };

            switch (h[1]) {
                .sync => {
                    defer server.destroyArena(arena);
                    const result = func(server, a, params) catch |err| return server.sendHandlerError(id, err, false);
                    server.sendResponse(id, result);
                },
                .read => {
                    const pending = try a.create(Pending);
                    pending.* = .{ .id = id };
                    {
                        server.pending_mutex.lockUncancelable(server.io);
                        defer server.pending_mutex.unlock(server.io);
                        server.pending.append(server.gpa, pending) catch |err| {
                            server.destroyArena(arena);
                            return err;
                        };
                    }
                    spawn(server.io, &server.group, ReadTask(func, h[0]).run, .{ server, arena, pending, params });
                },
                // 必须在独立线程中执行：`async` 在线程数达到上限（CPU 核数 - 1，长期阻塞的项目任务也占名额）时
                // 会在主循环中同步执行，而后台请求会等待需要主循环处理的消息（如配置拉取的响应），导致死锁
                .semantic => {
                    const pending = try a.create(Pending);
                    pending.* = .{ .id = id };
                    {
                        server.pending_mutex.lockUncancelable(server.io);
                        defer server.pending_mutex.unlock(server.io);
                        server.pending.append(server.gpa, pending) catch |err| {
                            server.destroyArena(arena);
                            return err;
                        };
                    }
                    spawn(server.io, &server.group, SemanticTask(func, h[0]).run, .{ server, arena, pending, params });
                },
                .background => server.group.concurrent(server.io, BackgroundTask(func).run, .{ server, arena, id, params }) catch {
                    server.destroyArena(arena);
                    server.sendError(id, jsonrpc.error_codes.internal_error, "failed to start background task");
                },
            }
            return;
        }
    }
    server.destroyArena(arena);
    server.sendError(id, jsonrpc.error_codes.method_not_found, "method not supported");
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
            }
            const a = arena.allocator();
            var ctx = server.db.beginRead(a);
            ctx.cancel = &pending.cancel;
            defer ctx.end();
            var trace: za.db.Trace = .{ .gpa = a };
            ctx.trace = &trace;
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
            }
            const a = arena.allocator();
            var ctx = server.db.beginRead(a);
            ctx.cancel = &pending.cancel;
            defer ctx.end();
            var trace: za.db.Trace = .{ .gpa = a };
            ctx.trace = &trace;
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
            server.sendResponse(pending.id, result);
        }
    };
}

// ── 慢请求日志（设计 §14）────────────────────────────────────────────

/// 请求耗时超过 `log.slow_request_ms` 时记录：按 query 汇总的自身耗时与调用树中的耗时路径。
/// 在读事务结束前调用（描述 key 时读取 ItemTree）
fn reportIfSlow(server: *Server, ctx: *Db.Ctx, method: []const u8, t0: Io.Timestamp, trace: *const za.db.Trace) void {
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

/// 与目标相关的值运算参数（指针位宽、向量的布局规则）：各模块的 builtin 一致时取该值，不一致时为未知
/// （与大小相关的值为未知）；没有项目模块时取默认 builtin（本机）
fn targetAbi(server: *Server, graph: *const ModuleGraph) za.sema.InternPool.Target {
    var result: za.sema.InternPool.Target = .{};
    var any = false;
    for (graph.modules) |m| {
        const file = m.builtin orelse continue;
        const t = server.builtinTarget(file);
        if (!any) {
            result = t;
            any = true;
            continue;
        }
        if (result.pointer_bits != t.pointer_bits) result.pointer_bits = null;
        if (result.vector_abi != t.vector_abi) result.vector_abi = .unknown;
    }
    if (any) return result;
    if (graph.default_builtin) |f| return server.builtinTarget(f);
    return .{};
}

fn builtinTarget(server: *Server, file: Vfs.FileId) za.sema.InternPool.Target {
    const text = Io.Dir.cwd().readFileAlloc(server.io, server.vfs.path(file), server.gpa, .limited(4 * 1024 * 1024)) catch return .{ .pointer_bits = null };
    defer server.gpa.free(text);
    const facts = za.project.builtin.vectorFacts(text);
    return .{
        .pointer_bits = za.project.builtin.pointerBits(text),
        .vector_abi = if (facts) |f| .of(f.backend, f.arch, f.avx, f.avx512f, f.soft_float) else .unknown,
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
    errdefer b.deinit();
    server.workspaces_mutex.lockUncancelable(server.io);
    const list = server.gpa.dupe(*Workspace, server.workspaces.items) catch |err| {
        server.workspaces_mutex.unlock(server.io);
        return err;
    };
    server.workspaces_mutex.unlock(server.io);
    defer server.gpa.free(list);
    for (list) |ws| {
        ws.mutex.lockUncancelable(server.io);
        defer ws.mutex.unlock(server.io);
        if (ws.model) |*m| if (ws.compile_set) |*cs| try b.add(m, cs);
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
    const graph = try server.gpa.create(ModuleGraph);
    errdefer server.gpa.destroy(graph);
    graph.* = try b.finish(std_root, default_builtin);
    const t = server.targetAbi(graph);
    // 持有 graph_mutex 开写事务是安全的：没有读事务会等待它
    server.db.beginWrite();
    defer server.db.endWrite();
    try server.db.set(ModuleGraph.Input, {}, graph, .medium);
    try server.db.set(za.sema.queries.TargetAbi, {}, t, .medium);
    server.ip.setTarget(t);
}

const index_progress_delay_ms = 200;

/// 每批索引的文件数：每批一个读事务，编辑（写事务）最多等一批
const index_batch = 8;

/// 后台为项目文件建立索引（文件索引与 ItemTree）：引用查找、workspace symbol 与调用点种子
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
        if (server.index_generation.load(.monotonic) == generation or server.indexing.swap(true, .acq_rel)) return;
    }
}

fn indexOnce(server: *Server) Io.Cancelable!void {
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
        _ = try ctx.get(za.ide_db.FileIndex.Query, f);
        _ = try ctx.get(syntax_q.FileItemTree, f);
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

// ── 通知 ─────────────────────────────────────────────────────────────

fn processNotification(server: *Server, arena: Allocator, method: []const u8, params_value: json.Value) !Flow {
    if (std.mem.eql(u8, method, "exit")) return .exit;
    // 初始化前除 exit 外的通知一律丢弃
    if (server.state == .uninitialized) return .@"continue";

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

fn isVirtual(path: []const u8) bool {
    return Workspace.isUnder(path, virtual_root);
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
        server.docs_mutex.lockUncancelable(server.io);
        defer server.docs_mutex.unlock(server.io);
        const gop = server.open_docs.getOrPut(server.gpa, id) catch |err| {
            server.gpa.free(owned);
            return err;
        };
        if (gop.found_existing) server.gpa.free(gop.value_ptr.*);
        gop.value_ptr.* = owned;
    }
    try server.setFileText(id, params.textDocument.text);
    server.publishFiles(&.{id}, false);
    if (server.isSingleFile(id)) server.compileSingle(id);
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
    // 关闭后按磁盘内容重新发布（编译集合中的文件仍可能有编译器诊断）
    server.publishFiles(&.{id}, true);
}

fn didSave(server: *Server, arena: Allocator, params: types.DidSaveTextDocumentParams) !void {
    const id = try server.fileIdFromUri(arena, params.textDocument.uri) orelse return;
    const path = server.vfs.path(id);
    const base = std.fs.path.basename(path);
    const is_build_file = isProjectFile(base);

    if (server.isSingleFile(id)) return server.compileSingle(id);

    server.workspaces_mutex.lockUncancelable(server.io);
    const list = try arena.dupe(*Workspace, server.workspaces.items);
    server.workspaces_mutex.unlock(server.io);
    for (list) |ws| {
        if (!ws.owns(id)) continue;
        if (is_build_file and std.mem.eql(u8, std.fs.path.dirname(path) orelse "", ws.root)) {
            // 非 watch 模式下 maker 不会自动重新配置：重启
            server.restartWorkspace(ws, 0);
        } else {
            ws.requestBuild();
        }
    }
}

/// 项目根目录中变化时需要重启项目的文件
fn isProjectFile(base: []const u8) bool {
    return std.mem.eql(u8, base, "build.zig") or std.mem.eql(u8, base, "build.zig.zon") or std.mem.eql(u8, base, Config.project_file);
}

/// 磁盘上的外部改动（编辑器之外：git checkout、代码生成等）。打开的文件以缓冲区为准；其余已知的文件
/// 按磁盘内容更新（删除的置为不存在）。工作区根目录的 build.zig / build.zig.zon / zig-analyzer.json 变化时重启该项目，
/// 其他文件变化时项目重新构建、单文件重新编译
fn didChangeWatchedFiles(server: *Server, arena: Allocator, params: types.DidChangeWatchedFilesParams) !void {
    const Change = struct { file: Vfs.FileId, text: ?[]u8 };
    var changes: std.ArrayList(Change) = .empty;
    defer for (changes.items) |c| if (c.text) |t| server.gpa.free(t);
    var build_files: std.ArrayList([]const u8) = .empty;
    for (params.changes) |event| {
        const path = uri.toPath(arena, event.uri) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnsupportedScheme, error.InvalidUri => continue,
        };
        if (!std.fs.path.isAbsolute(path)) continue;
        const base = std.fs.path.basename(path);
        if (isProjectFile(base)) try build_files.append(arena, std.fs.path.dirname(path) orelse "");
        // 从未接触过的文件与分析无关（新建的文件被 import 时再加载）
        const file = try server.vfs.lookup(path) orelse continue;
        {
            server.docs_mutex.lockUncancelable(server.io);
            defer server.docs_mutex.unlock(server.io);
            if (server.open_docs.contains(file)) continue;
        }
        const text = if (event.type == .Deleted) null else server.vfs.readFromDisk(file, server.gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            error.FileTooBig => null,
        };
        try changes.append(arena, .{ .file = file, .text = text });
    }
    if (changes.items.len != 0) {
        server.db.beginWrite();
        defer server.db.endWrite();
        for (changes.items) |*c| {
            try server.db.set(FileText, c.file, c.text, server.fileDurability(server.vfs.path(c.file)));
            c.text = null;
        }
    }

    server.workspaces_mutex.lockUncancelable(server.io);
    const list = try arena.dupe(*Workspace, server.workspaces.items);
    server.workspaces_mutex.unlock(server.io);
    for (list) |ws| {
        // 非 watch 模式下 maker 不会自动重新配置：重启
        const reconfigure = for (build_files.items) |dir| {
            if (std.mem.eql(u8, dir, ws.root)) break true;
        } else false;
        if (reconfigure) {
            server.restartWorkspace(ws, 0);
            continue;
        }
        for (changes.items) |c| if (ws.owns(c.file)) {
            ws.requestBuild();
            break;
        };
    }
    if (changes.items.len == 0) return;
    const files = try arena.alloc(Vfs.FileId, changes.items.len);
    for (changes.items, files) |c, *f| f.* = c.file;
    server.publishFiles(files, true);
    // 单文件模式：被它 import 的文件可能变了
    server.docs_mutex.lockUncancelable(server.io);
    const open = try arena.dupe(Vfs.FileId, server.open_docs.keys());
    server.docs_mutex.unlock(server.io);
    for (open) |file| if (server.isSingleFile(file)) server.compileSingle(file);
}

/// 文件内容的变化频率：标准库几乎不变，依赖包很少变化，项目文件经常变化
pub fn fileDurability(server: *Server, path: []const u8) database.Durability {
    const env = server.zigEnv() orelse return .low;
    if (Workspace.isUnder(path, env.lib_dir)) return .high;
    if (Workspace.isUnder(path, env.global_cache_dir)) return .medium;
    return .low;
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
    const inactive_changed = server.config.inactive_code != new.inactive_code;
    const build_was_enabled = server.config.build_enable;
    const inlay_changed = server.config.inlay_types != new.inlay_types or server.config.inlay_parameters != new.inlay_parameters or
        server.config.hide_redundant_param_names != new.hide_redundant_param_names or server.config.callsite_seeding != new.callsite_seeding;
    const compiler_disabled = server.config.compiler_diagnostics and !new.compiler_diagnostics;
    const log_file_changed = !eqlOptionalStr(server.config.log_file, new.log_file);
    server.applyLogging(&new, log_file_changed);
    server.config.deinit(server.gpa);
    server.config = new;
    server.config_mutex.unlock(server.io);
    if (inactive_changed) server.publishOpenFiles();

    if (zig_changed and server.started) server.showWarning("zig.path takes effect after restarting zig-analyzer");
    if (compiler_disabled) server.clearSingleFileResults();
    if (inlay_changed and server.inlay_refresh) server.sendRequest(.{ .string = "zig-analyzer/inlayHintRefresh" }, "workspace/inlayHint/refresh", null);
    if (build_changed) {
        if (!new.build_enable) {
            // 关闭构建系统集成：停止各项目，其文件改按单文件处理
            server.stopProjects();
        } else if (!build_was_enabled) {
            if (server.zigEnv() != null) server.startProjectsForRoots();
        } else {
            server.workspaces_mutex.lockUncancelable(server.io);
            const list = server.gpa.dupe(*Workspace, server.workspaces.items) catch {
                server.workspaces_mutex.unlock(server.io);
                return error.OutOfMemory;
            };
            server.workspaces_mutex.unlock(server.io);
            defer server.gpa.free(list);
            if (list.len != 0) log.info("build settings changed, restarting projects", .{});
            for (list) |ws| server.restartWorkspace(ws, 0);
        }
    }
}

/// 构建系统集成与编译器诊断是否开启
fn buildFlags(server: *Server) struct { build: bool, compiler: bool } {
    server.config_mutex.lockUncancelable(server.io);
    defer server.config_mutex.unlock(server.io);
    return .{ .build = server.config.build_enable, .compiler = server.config.compiler_diagnostics };
}

/// 停止全部项目（保留到退出时释放），清除其发布过的编译器诊断，模块图随之更新
fn stopProjects(server: *Server) void {
    // 先在锁内取出列表（不在持有 workspaces_mutex 时锁各项目的 mutex）
    const list = blk: {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        server.retired.appendSlice(server.gpa, server.workspaces.items) catch return;
        const list = server.gpa.dupe(*Workspace, server.workspaces.items) catch return;
        server.workspaces.clearRetainingCapacity();
        break :blk list;
    };
    defer server.gpa.free(list);
    var stale: std.ArrayList(Vfs.FileId) = .empty;
    defer stale.deinit(server.gpa);
    for (list) |ws| {
        ws.stop();
        ws.mutex.lockUncancelable(server.io);
        stale.appendSlice(server.gpa, ws.result_files.keys()) catch {};
        ws.mutex.unlock(server.io);
    }
    server.updateModuleGraph();
    server.publishFiles(stale.items, true);
    server.publishOpenFiles();
    // 打开的文件改按单文件编译
    server.docs_mutex.lockUncancelable(server.io);
    const open = server.gpa.dupe(Vfs.FileId, server.open_docs.keys()) catch {
        server.docs_mutex.unlock(server.io);
        return;
    };
    server.docs_mutex.unlock(server.io);
    defer server.gpa.free(open);
    for (open) |file| server.compileSingle(file);
}

/// 为有 build.zig 的根目录启动项目
fn startProjectsForRoots(server: *Server) void {
    var roots: std.ArrayList([]u8) = .empty;
    defer {
        for (roots.items) |r| server.gpa.free(r);
        roots.deinit(server.gpa);
    }
    {
        server.roots_mutex.lockUncancelable(server.io);
        defer server.roots_mutex.unlock(server.io);
        for (server.roots.items, server.root_has_build.items) |root, has_build| {
            if (!has_build) continue;
            const copy = server.gpa.dupe(u8, root) catch return;
            roots.append(server.gpa, copy) catch {
                server.gpa.free(copy);
                return;
            };
        }
    }
    for (roots.items) |root| server.startWorkspace(root);
}

/// 清除单文件模式的编译器诊断（关闭编译器诊断时）
fn clearSingleFileResults(server: *Server) void {
    var files: std.ArrayList(Vfs.FileId) = .empty;
    defer files.deinit(server.gpa);
    {
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        for (server.single.keys(), server.single.values()) |f, *sf| if (sf.result) |*r| {
            r.deinit(server.gpa);
            sf.result = null;
            files.append(server.gpa, f) catch {};
        };
    }
    server.publishFiles(files.items, true);
}

/// 日志级别、慢请求阈值；`reopen_file` 时按配置重新打开日志文件
fn applyLogging(server: *Server, config: *const Config, reopen_file: bool) void {
    za.util.log.setLevel(config.log_level);
    server.slow_request_ms.store(config.slow_request_ms, .monotonic);
    server.debounce_ms.store(config.debounce_ms, .monotonic);
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
}

// ── 项目与后台任务 ───────────────────────────────────────────────────

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
        server.env_mutex.lockUncancelable(server.io);
        defer server.env_mutex.unlock(server.io);
        server.zig_env = env;
    }
    log.info("zig {s} ({s})", .{ env.version, env.zig_exe });
    // 默认的 builtin.zig（单文件模式）：按 `zig test` 的设置，test 块中依赖 `builtin.is_test` 的
    // `std.testing.allocator` 等可以推导（与有 test step 的模块一致，见 configuration.zig）
    const default_builtin = za.project.builtin.generate(server.gpa, server.io, &env, &.{"test"}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => null,
    };
    if (default_builtin) |path| {
        server.env_mutex.lockUncancelable(server.io);
        defer server.env_mutex.unlock(server.io);
        server.default_builtin = path;
    }
    if (!env.matchesBuiltin()) {
        // 进程内 AstGen 与用户 zig 不一定一致：live 诊断改用用户的 zig ast-check（§11.2）
        server.showWarningOnce("zig version differs from the one zig-analyzer was built with: live diagnostics fall back to zig ast-check, compiler diagnostics are unavailable");
        const exe = server.gpa.dupe(u8, env.zig_exe) catch return;
        server.db.beginWrite();
        defer server.db.endWrite();
        server.db.set(live.LiveBackend, {}, .{ .subprocess = exe }, .high) catch {};
    }
    server.updateModuleGraph();
    if (server.buildFlags().build) server.startProjectsForRoots();
    // 启动前已打开的单文件：zig 环境就绪后补一次编译
    server.docs_mutex.lockUncancelable(server.io);
    const open = server.gpa.dupe(Vfs.FileId, server.open_docs.keys()) catch {
        server.docs_mutex.unlock(server.io);
        return;
    };
    server.docs_mutex.unlock(server.io);
    defer server.gpa.free(open);
    for (open) |file| if (server.isSingleFile(file)) server.compileSingle(file);
}

// ── 单文件模式 ───────────────────────────────────────────────────────

/// 不在任何带 build.zig 的工作区根目录之下的 .zig 文件
fn isSingleFile(server: *Server, file: Vfs.FileId) bool {
    const path = server.vfs.path(file);
    if (!std.mem.endsWith(u8, path, ".zig")) return false;
    // 关闭构建系统集成时所有文件都按单文件处理
    if (!server.buildFlags().build) return true;
    server.roots_mutex.lockUncancelable(server.io);
    defer server.roots_mutex.unlock(server.io);
    for (server.roots.items, server.root_has_build.items) |root, has_build| {
        if (has_build and Workspace.isUnder(path, root)) return false;
    }
    return true;
}

/// 在后台用 `zig build-obj -fno-emit-bin` 编译单个文件；编译期间再次请求时，结束后重新编译
fn compileSingle(server: *Server, file: Vfs.FileId) void {
    if (server.zigEnv() == null) return; // 启动完成后会补编译
    if (!server.buildFlags().compiler) return;
    // 编译器读取磁盘：尚未保存到磁盘的新文件不编译
    Io.Dir.cwd().access(server.io, server.vfs.path(file), .{}) catch return;
    {
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        const gop = server.single.getOrPut(server.gpa, file) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
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

fn singleFileTask(server: *Server, file: Vfs.FileId) Io.Cancelable!void {
    defer server.busyEnd();
    const env = server.zigEnv().?;
    const path = server.vfs.path(file);
    var title_buf: [256]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Compiling {s}", .{std.fs.path.basename(path)}) catch "Compiling";
    const progress = server.progress.begin(server, title, false);
    var errors: usize = 0;
    defer server.progress.end(server, progress, if (errors == 0) "Done" else "Has errors");
    while (true) {
        var result: ?compiler.BuildResult = blk: {
            var eb = za.project.bsp.compileSingleFile(server.gpa, server.io, env.zig_exe, path) catch |err| {
                log.warn("{s}: single-file compile failed: {t}", .{ path, err });
                break :blk null;
            };
            defer eb.deinit(server.gpa);
            errors = eb.errorMessageCount();
            break :blk compiler.collect(server.gpa, &.{eb}, std.fs.path.dirname(path) orelse ".", path, server, readDisk) catch null;
        };
        server.single_mutex.lockUncancelable(server.io);
        const sf = server.single.getPtr(file).?;
        if (sf.rerun) {
            sf.rerun = false;
            server.single_mutex.unlock(server.io);
            if (result) |*r| r.deinit(server.gpa);
            continue;
        }
        if (sf.result) |*old| old.deinit(server.gpa);
        sf.result = result;
        sf.running = false;
        server.single_mutex.unlock(server.io);
        server.publishFiles(&.{file}, true);
        return;
    }
}

fn readDisk(ctx: *anyopaque, gpa: Allocator, path: []const u8) ?[]u8 {
    const server: *Server = @ptrCast(@alignCast(ctx));
    return Io.Dir.cwd().readFileAlloc(server.io, path, gpa, .limited(Vfs.max_file_size)) catch null;
}

/// 为根目录启动项目；同一根目录已有项目时不重复启动（启动阶段与工作区文件夹的变化可能同时进行）
fn startWorkspace(server: *Server, root: []const u8) void {
    if (server.isShuttingDown() or !server.buildFlags().build) return;
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
    for (server.workspaces.items) |w| if (std.mem.eql(u8, w.root, root)) {
        ws.stop();
        server.retired.append(server.gpa, ws) catch {};
        return;
    };
    server.workspaces.append(server.gpa, ws) catch {
        ws.stop();
        server.retired.append(server.gpa, ws) catch {};
    };
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
    const build_zig = try std.fs.path.join(server.gpa, &.{ normalized, "build.zig" });
    defer server.gpa.free(build_zig);
    const has_build = if (Io.Dir.cwd().access(server.io, build_zig, .{})) |_| true else |_| false;
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
    var removed: ?*Workspace = null;
    {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        for (server.workspaces.items, 0..) |w, i| if (std.mem.eql(u8, w.root, normalized)) {
            // 后台任务可能仍在运行：保留到退出时统一释放
            try server.retired.ensureUnusedCapacity(server.gpa, 1);
            server.retired.appendAssumeCapacity(server.workspaces.orderedRemove(i));
            removed = w;
            break;
        };
    }
    const ws = removed orelse return;
    ws.stop();
    ws.mutex.lockUncancelable(server.io);
    const stale = try arena.dupe(Vfs.FileId, ws.result_files.keys());
    ws.mutex.unlock(server.io);
    server.publishFiles(stale, true);
}

/// 工作区文件夹的增减
fn didChangeWorkspaceFolders(server: *Server, arena: Allocator, params: types.DidChangeWorkspaceFoldersParams) !void {
    for (params.event.removed) |f| try server.removeRoot(arena, f.uri);
    for (params.event.added) |f| try server.addRoot(f.uri);
    server.updateModuleGraph();
}

/// 停止 `ws` 并以新实例替换。`crash_restarts` 为 maker 连续崩溃后自动重启的次数（正常重启为 0）
pub fn restartWorkspace(server: *Server, ws: *Workspace, crash_restarts: u8) void {
    ws.stop();
    if (server.isShuttingDown()) return;
    const root = server.gpa.dupe(u8, ws.root) catch return;
    defer server.gpa.free(root);
    const fresh = Workspace.start(server, root, crash_restarts) catch |err| {
        log.err("{s}: failed to restart build system protocol: {t}", .{ root, err });
        return;
    };
    // 旧实例发布过的编译器诊断由新实例在首次构建后清除（新结果中没有的文件）。
    // 新实例的后台任务已在运行，两边都要加锁（先后各持一把，不同时持有）
    ws.mutex.lockUncancelable(server.io);
    const stale = server.gpa.dupe(Vfs.FileId, ws.result_files.keys()) catch &.{};
    ws.mutex.unlock(server.io);
    defer server.gpa.free(stale);
    fresh.mutex.lockUncancelable(server.io);
    fresh.stale_files.appendSlice(server.gpa, stale) catch {};
    fresh.mutex.unlock(server.io);
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    // 旧实例保留在列表中直到退出时统一释放（其后台任务可能仍在运行），但不再参与调度
    // 启动新实例期间服务器开始关闭：新实例同样停止
    if (server.shutting_down) fresh.stop();
    for (server.workspaces.items) |*w| if (w.* == ws) {
        w.* = fresh;
        server.retired.append(server.gpa, ws) catch {};
        return;
    };
    // `ws` 已被其他重启替换（并发的崩溃重启与配置变化）：新实例作废
    fresh.stop();
    server.retired.append(server.gpa, fresh) catch {};
}

fn stopWorkspaces(server: *Server) void {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    server.shutting_down = true;
    for (server.workspaces.items) |ws| ws.stop();
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

// ── 诊断发布（设计 §11.5） ───────────────────────────────────────────

/// 在后台重新计算并发布这些文件的诊断。`clear` 为 true 时即使没有诊断也发布（用于清除旧诊断）。
pub fn publishFiles(server: *Server, files: []const Vfs.FileId, clear: bool) void {
    for (files) |file| {
        server.busyBegin();
        spawn(server.io, &server.bg_group, publishTask, .{ server, file, clear });
    }
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
}

fn editGeneration(server: *Server, file: Vfs.FileId) u64 {
    server.edits_mutex.lockUncancelable(server.io);
    defer server.edits_mutex.unlock(server.io);
    return if (server.edits.get(file)) |e| e.generation else 0;
}

fn publishTask(server: *Server, file: Vfs.FileId, clear: bool) Io.Cancelable!void {
    defer server.busyEnd();
    server.publishNow(file, clear, null);
}

/// `generation`：编辑触发的发布所针对的编辑代数。被打断时若已有更新的编辑就放弃，由那次编辑触发的发布接替
fn publishNow(server: *Server, file: Vfs.FileId, clear: bool, generation: ?u64) void {
    var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_state.deinit();
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
        server.sendDiagnostics(file, params, clear);
        return;
    }
}

/// 在读事务之外对文件的当前文本做 AstGen（见 `live.Prepared`）：AstGen 不检查取消，在读事务中进行时
/// 写事务要等它结束。只读取文本时短暂持有读事务。任何失败都只是退回在 query 中计算
fn prepareLive(server: *Server, file: Vfs.FileId) void {
    const eligible = if (server.workspaceFor(file)) |w| w.liveEligible(file) else true;
    if (!eligible) return;
    var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = blk: {
        var ctx = server.db.beginRead(a);
        defer ctx.end();
        if ((ctx.get(live.LiveBackend, {}) catch return) != .in_process) return;
        const t = (ctx.get(FileText, file) catch return) orelse return;
        break :blk a.dupe(u8, t) catch return;
    };
    const mode = live.modeOf(server.vfs.path(file));
    if (!(server.live_prepared.claim(server.io, file, live.Prepared.hash(text, mode)) catch return)) return;
    const result = live.check(server.gpa, text, mode) catch return;
    server.live_prepared.put(server.io, text, mode, result) catch {};
}

/// 当前文本的 live 诊断已在读事务之外准备过（或不需要准备）
fn liveReady(server: *Server, ctx: *Db.Ctx, file: Vfs.FileId) !bool {
    const eligible = if (server.workspaceFor(file)) |w| w.liveEligible(file) else true;
    if (!eligible or try ctx.get(live.LiveBackend, {}) != .in_process) return true;
    const text = try ctx.get(FileText, file) orelse return true;
    return server.live_prepared.prepared(server.io, file, live.Prepared.hash(text, live.modeOf(server.vfs.path(file))));
}

fn sendDiagnostics(server: *Server, file: Vfs.FileId, params: types.PublishDiagnosticsParams, clear: bool) void {
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
    server.sendNotification("textDocument/publishDiagnostics", params);
}

/// 文件所属的项目（第一个包含它的工作区）
fn workspaceFor(server: *Server, file: Vfs.FileId) ?*Workspace {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    for (server.workspaces.items) |ws| if (ws.owns(file)) return ws;
    return null;
}

fn uriFor(server: *Server, arena: Allocator, file: Vfs.FileId) Allocator.Error![]const u8 {
    server.docs_mutex.lockUncancelable(server.io);
    defer server.docs_mutex.unlock(server.io);
    if (server.open_docs.get(file)) |u| return arena.dupe(u8, u);
    return uri.fromPath(arena, server.vfs.path(file));
}

const OtherFiles = struct {
    server: *Server,
    ctx: *Db.Ctx,

    fn get(opaque_ctx: *anyopaque, arena: Allocator, path: []const u8) ?compiler.OtherFile {
        const self: *OtherFiles = @ptrCast(@alignCast(opaque_ctx));
        const file = self.server.vfs.lookup(path) catch return null;
        const loaded: ?[]const u8 = if (file) |f| (self.ctx.get(FileText, f) catch null) orelse null else null;
        const text = loaded orelse Io.Dir.cwd().readFileAlloc(self.server.io, path, arena, .limited(Vfs.max_file_size)) catch return null;
        const u = if (file) |f| self.server.uriFor(arena, f) catch return null else uri.fromPath(arena, path) catch return null;
        return .{ .uri = u, .text = text };
    }
};

fn computeDiagnostics(server: *Server, ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId) !types.PublishDiagnosticsParams {
    const document_uri = try server.uriFor(arena, file);
    const text = try ctx.get(FileText, file);
    const ws = server.workspaceFor(file);

    // live 诊断：文件已加载，且（不属于任何项目，或编译集合尚未算出，或在编译集合中）
    var live_result: ?*live.Result = null;
    if (text != null) {
        const eligible = if (ws) |w| w.liveEligible(file) else true;
        if (eligible) live_result = try ctx.get(live.AstCheck, file);
    }

    var other: OtherFiles = .{ .server = server, .ctx = ctx };
    var diags: []const types.Diagnostic = &.{};
    if (ws) |w| {
        w.mutex.lockUncancelable(server.io);
        defer w.mutex.unlock(server.io);
        const fr = w.result_files.get(file);
        const current = text orelse if (fr) |r| r.base_text else "";
        diags = try compiler.merge(arena, .{
            .text = current,
            .lines = try offsets.LineIndex.init(arena, current),
            .encoding = server.encoding,
            .uri = document_uri,
            .live = live_result,
            .compiler = fr,
            .other_file = OtherFiles.get,
            .other_ctx = &other,
        });
    } else if (text) |current| {
        // 单文件模式：只使用编译结果中本文件的诊断
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        const fr: ?*const compiler.FileResult = if (server.single.getPtr(file)) |sf|
            if (sf.result) |*r| r.files.getPtr(server.vfs.path(file)) else null
        else
            null;
        diags = try compiler.merge(arena, .{
            .text = current,
            .lines = try offsets.LineIndex.init(arena, current),
            .encoding = server.encoding,
            .uri = document_uri,
            .live = live_result,
            .compiler = fr,
            .other_file = OtherFiles.get,
            .other_ctx = &other,
        });
    }
    if (text) |current| if (server.wantsInactiveCode(file)) {
        diags = try server.appendInactiveCode(ctx, arena, file, current, diags);
    };
    return .{ .uri = document_uri, .diagnostics = diags };
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
    for (ranges, out[diags.len..]) |x, *d| d.* = .{
        .range = lines.range(x.start, x.end, server.encoding),
        .severity = .Hint,
        .source = "zig-analyzer",
        .message = .{ .string = "code is inactive: a comptime condition excludes it under the current build configuration" },
        .tags = &.{.Unnecessary},
    };
    return out;
}

// ── 请求处理函数 ──────────────────────────────────────────────────────

/// 读请求中把 URI 换成已知文件；未打开或不存在的文件返回 null
fn lookupFile(server: *Server, arena: Allocator, document_uri: []const u8) !?Vfs.FileId {
    const path = try documentPath(arena, document_uri) orelse return null;
    return try server.vfs.lookup(path);
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

fn semanticTokensFull(server: *Server, ctx: *Db.Ctx, arena: Allocator, params: types.SemanticTokensParams) HandlerError!types.ResultType("textDocument/semanticTokens/full") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const parse = try ctx.get(syntax_q.ParseFile, file);
    const lines = try fileLines(ctx, arena, file);
    return .{ .data = try ide.semantic_tokens.semanticTokens(arena, parse.rootNode(), lines, server.encoding) };
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
    }
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
            .codeActionProvider = .{ .CodeActionOptions = .{ .codeActionKinds = &.{ types.CodeActionKind.QuickFix, types.CodeActionKind.RefactorExtract } } },
            .semanticTokensProvider = .{ .SemanticTokensOptions = .{
                .legend = ide.semantic_tokens.legend,
                .full = .{ .boolean = true },
            } },
        },
        .serverInfo = .{ .name = "zig-analyzer", .version = za.version },
    };
}

fn shutdown(server: *Server, _: Allocator, _: void) HandlerError!void {
    // 等待进行中的读请求完成；停止各项目的构建系统进程，并等后台任务（诊断发布等）收尾
    server.group.await(server.io) catch {};
    // 客户端一直没有回复配置请求：不再等待
    server.startup_pending = false;
    while (server.config_outstanding > 0) : (server.config_outstanding -= 1) server.busyEnd();
    server.stopWorkspaces();
    server.waitIdle();
    server.state = .shutdown;
}

const StatusResult = struct {
    revision: u64,
    files: usize,
    deep_verifications: u64,
    /// 进程的常驻内存峰值（KB；不支持的平台为 0）
    max_rss_kb: u64,
    /// InternPool 中的类型与值的个数
    intern_pool_items: usize,
    queries: []const struct {
        name: []const u8,
        executions: u64,
        hits: u64,
        cutoffs: u64,
        total_ms: f64,
        self_ms: f64,
        max_ms: f64,
        memos: usize,
        incomplete: u64,
    },
    /// 结果不完整的原因（环、栈深度、燃料）的累计次数
    incomplete_causes: struct { cycle: u64, stack: u64, fuel: u64 },
};

fn definition(server: *Server, r: *Resolver, arena: Allocator, params: types.DefinitionParams) HandlerError!types.ResultType("textDocument/definition") {
    const loc = try server.gotoTarget(r, arena, params.textDocument.uri, params.position, ide.definition.definition) orelse return null;
    return .{ .Definition = .{ .Location = loc } };
}

fn declaration(server: *Server, r: *Resolver, arena: Allocator, params: types.DeclarationParams) HandlerError!types.ResultType("textDocument/declaration") {
    const loc = try server.gotoTarget(r, arena, params.textDocument.uri, params.position, ide.definition.declaration) orelse return null;
    return .{ .Declaration = .{ .Location = loc } };
}

fn typeDefinition(server: *Server, r: *Resolver, arena: Allocator, params: types.TypeDefinitionParams) HandlerError!types.ResultType("textDocument/typeDefinition") {
    const loc = try server.gotoTarget(r, arena, params.textDocument.uri, params.position, ide.definition.typeDefinition) orelse return null;
    return .{ .Definition = .{ .Location = loc } };
}

/// 按 `find` 求光标处的跳转目标
fn gotoTarget(server: *Server, r: *Resolver, arena: Allocator, document_uri: []const u8, pos: types.Position, comptime find: anytype) !?types.Location {
    const at = try server.textPosition(r, arena, document_uri, pos) orelse return null;
    const t = try find(r, at.file, at.offset) orelse return null;
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
        .activeParameter = sig.active,
        .documentation = if (sig.doc) |d| .{ .MarkupContent = .{ .kind = .markdown, .value = d } } else null,
    };
    return .{ .signatures = info, .activeSignature = 0, .activeParameter = sig.active };
}

fn inlayHint(server: *Server, r: *Resolver, arena: Allocator, params: types.InlayHintParams) HandlerError!types.ResultType("textDocument/inlayHint") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const text = (try r.ctx.get(syntax_q.SourceText, file)).text;
    const start: u32 = @intCast(offsets.positionToOffset(text, params.range.start, server.encoding));
    const end: u32 = @intCast(offsets.positionToOffset(text, params.range.end, server.encoding));
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

/// workspace symbol 的范围：索引进行中时只取已建立索引的文件与打开的文档，不在请求中解析其余文件
/// （LSP 的 workspace/symbol 没有 isIncomplete：客户端随输入重新请求，结果随索引的进展补全）
fn symbolScope(server: *Server, r: *Resolver) ![]const Vfs.FileId {
    const all = try server.searchScope(r);
    if (!server.indexing.load(.acquire)) return all;
    var out: std.ArrayList(Vfs.FileId) = .empty;
    server.indexed_mutex.lockUncancelable(server.io);
    defer server.indexed_mutex.unlock(server.io);
    server.docs_mutex.lockUncancelable(server.io);
    defer server.docs_mutex.unlock(server.io);
    for (all) |f| if (server.indexed.contains(f) or server.open_docs.contains(f)) try out.append(r.arena, f);
    return out.items;
}

/// 光标处的定义及其全部引用
fn referencesAt(server: *Server, r: *Resolver, arena: Allocator, document_uri: []const u8, pos: types.Position, only_file: bool) !?struct { def: za.names.resolve.Def, refs: []const za.ide_db.search.Reference } {
    const at = try server.textPosition(r, arena, document_uri, pos) orelse return null;
    const def = try ide.definition.defAt(r, at.file, at.offset) orelse return null;
    const scope = try server.searchScope(r);
    const refs = try za.ide_db.search.findReferences(r, def, .{ .scope = scope, .only_file = if (only_file) at.file else null });
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
    const found = try server.referencesAt(r, arena, params.textDocument.uri, params.position, false) orelse return null;
    var out: std.ArrayList(types.Location) = .empty;
    var m: RangeMapper = .{ .server = server, .r = r };
    for (found.refs) |ref| {
        if (ref.is_decl and !params.context.includeDeclaration) continue;
        try out.append(arena, .{ .uri = try server.uriFor(arena, ref.file), .range = try m.range(ref.file, ref.start, ref.end) });
    }
    return out.items;
}

fn documentHighlight(server: *Server, r: *Resolver, arena: Allocator, params: types.DocumentHighlightParams) HandlerError!types.ResultType("textDocument/documentHighlight") {
    const found = try server.referencesAt(r, arena, params.textDocument.uri, params.position, true) orelse return null;
    const out = try arena.alloc(types.DocumentHighlight, found.refs.len);
    var m: RangeMapper = .{ .server = server, .r = r };
    for (found.refs, out) |ref, *o| o.* = .{ .range = try m.range(ref.file, ref.start, ref.end), .kind = if (ref.is_decl) .Write else .Read };
    return out;
}

/// 可以重命名的定义：位于某个工作区根目录内且不在其缓存目录中
fn renamable(server: *Server, r: *Resolver, def: za.names.resolve.Def) !bool {
    if (def == .file or try za.ide_db.search.defName(r, def) == null) return false;
    const file = switch (def) {
        .item => |it| it.file,
        .local => |l| l.file,
        .file => unreachable,
    };
    const path = server.vfs.path(file);
    // 未保存的文档（`untitled:` 等）只存在于编辑器中
    if (isVirtual(path)) return true;
    server.roots_mutex.lockUncancelable(server.io);
    defer server.roots_mutex.unlock(server.io);
    for (server.roots.items) |root| {
        if (!std.mem.startsWith(u8, path, root) or path.len <= root.len or !std.fs.path.isSep(path[root.len])) continue;
        const rest = path[root.len + 1 ..];
        if (std.mem.startsWith(u8, rest, ".zig-cache") or std.mem.startsWith(u8, rest, "zig-pkg")) continue;
        return true;
    }
    return false;
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
    const new_name = try identifierText(arena, params.newName);
    const found = try server.referencesAt(r, arena, params.textDocument.uri, params.position, false) orelse return null;
    if (!try server.renamable(r, found.def)) return error.RenameOutsideWorkspace;
    var changes: std.json.ArrayHashMap([]const types.TextEdit) = .{};
    var m: RangeMapper = .{ .server = server, .r = r };
    var i: usize = 0;
    while (i < found.refs.len) {
        const file = found.refs[i].file;
        var edits: std.ArrayList(types.TextEdit) = .empty;
        while (i < found.refs.len and found.refs[i].file == file) : (i += 1) {
            const ref = found.refs[i];
            try edits.append(arena, .{ .range = try m.range(file, ref.start, ref.end), .newText = new_name });
        }
        try changes.map.put(arena, try server.uriFor(arena, file), edits.items);
    }
    return .{ .changes = changes };
}

/// 新名字的源码写法：合法标识符原样使用，`@"..."` 原样使用，其余（关键字、含特殊字符）用 `@"..."` 包裹
fn identifierText(arena: Allocator, name: []const u8) HandlerError![]const u8 {
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "\"\n\r\\") != null and !std.mem.startsWith(u8, name, "@\"")) return error.InvalidIdentifier;
    if (std.mem.startsWith(u8, name, "@\"")) {
        if (name.len < 3 or name[name.len - 1] != '"') return error.InvalidIdentifier;
        return name;
    }
    if (std.zig.isValidId(name)) return name;
    return std.fmt.allocPrint(arena, "@\"{s}\"", .{name});
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
    const start: u32 = @intCast(offsets.positionToOffset(text, params.range.start, server.encoding));
    const end: u32 = @intCast(offsets.positionToOffset(text, params.range.end, server.encoding));
    const actions = try ide.code_actions.codeActions(r, file, start, end);
    const lines = try offsets.LineIndex.init(arena, text);
    const doc_uri = try server.uriFor(arena, file);
    const Item = @typeInfo(@typeInfo(types.ResultType("textDocument/codeAction")).optional.child).pointer.child;
    const out = try arena.alloc(Item, actions.len);
    for (actions, out) |a, *o| {
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
        o.* = .{ .CodeAction = .{
            .title = a.title,
            .kind = switch (a.kind) {
                .quickfix => types.CodeActionKind.QuickFix,
                .refactor_extract => types.CodeActionKind.RefactorExtract,
            },
            .diagnostics = diagnostics,
            .isPreferred = if (a.diagnostic != null) true else null,
            .edit = .{ .changes = changes },
        } };
    }
    return out;
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
            .incomplete = q.incomplete,
        };
    }
    return .{
        .revision = summary.revision,
        .files = server.vfs.count(),
        .deep_verifications = summary.deep_verifications,
        .max_rss_kb = maxRssKb(),
        .intern_pool_items = server.ip.count(),
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
    if (builtin_os == .windows or builtin_os == .wasi) return 0;
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
        error.InvalidIdentifier => server.sendError(id, jsonrpc.error_codes.request_failed, "new name is not a valid identifier"),
        else => server.sendError(id, jsonrpc.error_codes.internal_error, @errorName(err)),
    }
}

fn destroyArena(server: *Server, arena: *std.heap.ArenaAllocator) void {
    arena.deinit();
    server.gpa.destroy(arena);
}

test {
    _ = @import("Server_test.zig");
    _ = @import("compiler_e2e_test.zig");
    _ = @import("names_e2e_test.zig");
    _ = @import("refs_e2e_test.zig");
    _ = @import("workspace_e2e_test.zig");
}
