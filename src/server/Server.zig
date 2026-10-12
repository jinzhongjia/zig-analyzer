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

const log = std.log.scoped(.server);

const Server = @This();

io: Io,
gpa: Allocator,
db: Db,
vfs: Vfs,
out: *transport.Writer,
state: State = .uninitialized,
encoding: offsets.Encoding = .utf16,
/// 并发执行中的读请求
group: Io.Group = .init,
pending_mutex: Io.Mutex = .init,
pending: std.ArrayList(*Pending) = .empty,

pub const State = enum { uninitialized, running, shutdown };

const Pending = struct {
    id: jsonrpc.Id,
    cancel: std.atomic.Value(bool) = .init(false),
};

pub const HandlerError = error{ Canceled, OutOfMemory, InvalidParams };

/// 原地初始化：查询引擎持有指向 `server.vfs` 的指针，因此 Server 不能在初始化后移动。
pub fn init(server: *Server, io: Io, gpa: Allocator, out: *transport.Writer) void {
    server.* = .{ .io = io, .gpa = gpa, .db = undefined, .vfs = .init(io, gpa), .out = out };
    server.db = .init(io, gpa, &server.vfs);
}

pub fn deinit(server: *Server) void {
    server.group.cancel(server.io);
    server.pending.deinit(server.gpa);
    server.db.deinit();
    server.vfs.deinit();
    server.* = undefined;
}

/// 运行主循环直到收到 `exit` 或输入结束，返回进程退出码。
pub fn run(server: *Server, reader: *Io.Reader) !u8 {
    while (true) {
        const arena = try server.gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(server.gpa);
        // 消息体分配在 arena 上：解析出的字符串可能直接引用它，需与请求同生命周期
        const body = transport.readMessage(reader, arena.allocator()) catch |err| {
            server.destroyArena(arena);
            switch (err) {
                error.EndOfStream => break,
                else => {
                    log.err("读取消息失败: {t}", .{err});
                    break;
                },
            }
        };
        if (try server.processMessage(arena, body) == .exit) break;
    }
    server.group.await(server.io) catch {};
    return if (server.state == .shutdown) 0 else 1;
}

const Flow = enum { @"continue", exit };

/// 处理一条消息；`arena` 的所有权转交给本函数。
fn processMessage(server: *Server, arena: *std.heap.ArenaAllocator, body: []const u8) !Flow {
    const a = arena.allocator();
    const message = jsonrpc.parse(a, body) catch |err| {
        server.destroyArena(arena);
        if (err == error.OutOfMemory) return err;
        server.sendError(null, jsonrpc.error_codes.parse_error, "无法解析 JSON-RPC 消息");
        return .@"continue";
    };
    switch (message) {
        .request => |req| try server.processRequest(arena, req.id, req.method, req.params),
        .notification => |n| {
            defer server.destroyArena(arena);
            return server.processNotification(a, n.method, n.params);
        },
        .response => server.destroyArena(arena),
    }
    return .@"continue";
}

// ── 请求 ─────────────────────────────────────────────────────────────

const Mode = enum {
    /// 在主循环中同步执行（改变服务器状态的请求）
    sync,
    /// 在独立任务中持有读事务并发执行
    read,
};

const request_handlers = .{
    .{ "initialize", Mode.sync, initialize },
    .{ "shutdown", Mode.sync, shutdown },
    .{ "zig-analyzer/status", Mode.read, status },
    .{ "textDocument/formatting", Mode.read, formatting },
    .{ "textDocument/documentSymbol", Mode.read, documentSymbol },
    .{ "textDocument/foldingRange", Mode.read, foldingRange },
    .{ "textDocument/selectionRange", Mode.read, selectionRange },
    .{ "textDocument/semanticTokens/full", Mode.read, semanticTokensFull },
};

fn processRequest(server: *Server, arena: *std.heap.ArenaAllocator, id: jsonrpc.Id, method: []const u8, params_value: json.Value) !void {
    const a = arena.allocator();
    inline for (request_handlers) |h| {
        if (std.mem.eql(u8, method, h[0])) {
            const is_initialize = comptime std.mem.eql(u8, h[0], "initialize");
            if (server.state == .uninitialized and !is_initialize) {
                server.destroyArena(arena);
                return server.sendError(id, jsonrpc.error_codes.server_not_initialized, "服务器尚未初始化");
            }
            if (server.state != .uninitialized and is_initialize or server.state == .shutdown) {
                server.destroyArena(arena);
                return server.sendError(id, jsonrpc.error_codes.invalid_request, "当前状态下不能处理该请求");
            }

            const func = h[2];
            const Params = LastParam(@TypeOf(func));
            const params = jsonrpc.parseParams(Params, a, params_value) catch |err| {
                server.destroyArena(arena);
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return server.sendError(id, jsonrpc.error_codes.invalid_params, "参数格式错误");
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
                    server.group.async(server.io, ReadTask(func).run, .{ server, arena, pending, params });
                },
            }
            return;
        }
    }
    server.destroyArena(arena);
    server.sendError(id, jsonrpc.error_codes.method_not_found, "不支持的方法");
}

/// 处理函数最后一个参数即请求参数类型
fn LastParam(comptime F: type) type {
    const param_types = @typeInfo(F).@"fn".param_types;
    return param_types[param_types.len - 1].?;
}

fn ReadTask(comptime func: anytype) type {
    const Params = LastParam(@TypeOf(func));
    return struct {
        fn run(server: *Server, arena: *std.heap.ArenaAllocator, pending: *Pending, params: Params) Io.Cancelable!void {
            defer {
                server.removePending(pending);
                server.destroyArena(arena);
            }
            const a = arena.allocator();
            var ctx = server.db.beginRead(a);
            ctx.cancel = &pending.cancel;
            defer ctx.end();

            const result = func(server, &ctx, a, params) catch |err| {
                return server.sendHandlerError(pending.id, err, pending.cancel.load(.acquire));
            };
            server.sendResponse(pending.id, result);
        }
    };
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
    };
    inline for (handlers) |h| {
        if (std.mem.eql(u8, method, h[0])) {
            const Params = types.ParamsType(h[0]);
            const params = jsonrpc.parseParams(Params, arena, params_value) catch |err| {
                log.warn("{s}: 参数格式错误: {t}", .{ h[0], err });
                return .@"continue";
            };
            h[1](server, arena, params) catch |err| log.err("{s} 处理失败: {t}", .{ h[0], err });
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
    const path = uri.toPath(arena, document_uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // untitled: 等非文件文档暂不处理
        error.UnsupportedScheme, error.InvalidUri => return null,
    };
    if (!std.fs.path.isAbsolute(path)) return null;
    return try server.vfs.intern(path);
}

fn setFileText(server: *Server, id: Vfs.FileId, text: ?[]const u8) !void {
    const owned = if (text) |t| try server.gpa.dupe(u8, t) else null;
    server.db.beginWrite();
    defer server.db.endWrite();
    try server.db.set(FileText, id, owned, .low);
}

fn didOpen(server: *Server, arena: Allocator, params: types.DidOpenTextDocumentParams) !void {
    const id = try server.fileIdFromUri(arena, params.textDocument.uri) orelse return;
    try server.setFileText(id, params.textDocument.text);
    try server.scheduleDiagnostics(id, params.textDocument.uri);
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
    try server.scheduleDiagnostics(id, params.textDocument.uri);
}

fn didClose(server: *Server, arena: Allocator, params: types.DidCloseTextDocumentParams) !void {
    const id = try server.fileIdFromUri(arena, params.textDocument.uri) orelse return;
    // 关闭后以磁盘内容为准
    const disk = server.vfs.readFromDisk(id, arena) catch |err| switch (err) {
        error.FileTooBig => null,
        else => |e| return e,
    };
    try server.setFileText(id, disk);
    // 关闭的文档不再显示 live 诊断（M2 起由编译器诊断接管）
    server.sendNotification("textDocument/publishDiagnostics", types.PublishDiagnosticsParams{ .uri = params.textDocument.uri, .diagnostics = &.{} });
}

// ── live 诊断推送 ─────────────────────────────────────────────────────

/// 在后台计算并推送诊断。之后的编辑会通过写事务取消尚未完成的计算。
fn scheduleDiagnostics(server: *Server, file: Vfs.FileId, document_uri: []const u8) !void {
    const owned_uri = try server.gpa.dupe(u8, document_uri);
    server.group.async(server.io, diagnosticsTask, .{ server, file, owned_uri });
}

fn diagnosticsTask(server: *Server, file: Vfs.FileId, document_uri: []u8) Io.Cancelable!void {
    defer server.gpa.free(document_uri);
    var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx = server.db.beginRead(arena);
    defer ctx.end();
    const params = buildDiagnostics(server, &ctx, arena, file, document_uri) catch |err| switch (err) {
        // 被新的编辑取消：新的编辑会重新调度
        error.Canceled => return,
        error.OutOfMemory => return log.err("计算诊断时内存不足", .{}),
    };
    server.sendNotification("textDocument/publishDiagnostics", params);
}

fn buildDiagnostics(server: *Server, ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId, document_uri: []const u8) !types.PublishDiagnosticsParams {
    const result = try ctx.get(live.AstCheck, file);
    const text = try ctx.get(FileText, file) orelse "";
    const lines = try offsets.LineIndex.init(arena, text);
    const diags = try arena.alloc(types.Diagnostic, result.items.len);
    for (result.items, diags) |d, *out| {
        const related = try arena.alloc(types.DiagnosticRelatedInformation, d.notes.len);
        for (d.notes, related) |n, *r| r.* = .{
            .location = .{ .uri = document_uri, .range = lines.range(n.start, n.end, server.encoding) },
            .message = n.message,
        };
        out.* = .{
            .range = lines.range(d.start, d.end, server.encoding),
            .severity = .Error,
            .source = "zig ast-check",
            .message = .{ .string = d.message },
            .relatedInformation = if (related.len == 0) null else related,
        };
    }
    return .{ .uri = document_uri, .diagnostics = diags };
}

// ── 请求处理函数 ──────────────────────────────────────────────────────

/// 读请求中把 URI 换成已知文件；未打开或不存在的文件返回 null
fn lookupFile(server: *Server, arena: Allocator, document_uri: []const u8) !?Vfs.FileId {
    const path = uri.toPath(arena, document_uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedScheme, error.InvalidUri => return null,
    };
    if (!std.fs.path.isAbsolute(path)) return null;
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
    log.info("初始化完成，位置编码 {t}", .{server.encoding});

    return .{
        .capabilities = .{
            .positionEncoding = server.encoding.toLsp(),
            .textDocumentSync = .{ .TextDocumentSyncOptions = .{
                .openClose = true,
                .change = .Incremental,
            } },
            .documentFormattingProvider = .{ .boolean = true },
            .documentSymbolProvider = .{ .boolean = true },
            .foldingRangeProvider = .{ .boolean = true },
            .selectionRangeProvider = .{ .boolean = true },
            .semanticTokensProvider = .{ .SemanticTokensOptions = .{
                .legend = ide.semantic_tokens.legend,
                .full = .{ .boolean = true },
            } },
        },
        .serverInfo = .{ .name = "zig-analyzer", .version = za.version },
    };
}

fn shutdown(server: *Server, _: Allocator, _: void) HandlerError!void {
    // 等待进行中的读请求完成
    server.group.await(server.io) catch {};
    server.state = .shutdown;
}

const StatusResult = struct {
    revision: u64,
    files: usize,
    deep_verifications: u64,
    queries: []const struct { name: []const u8, executions: u64 },
};

fn status(server: *Server, _: *Db.Ctx, arena: Allocator, _: void) HandlerError!StatusResult {
    var counts: [Db.query_types.len]u64 = undefined;
    const stats = server.db.stats(&counts);
    const queries = try arena.alloc(@typeInfo(@FieldType(StatusResult, "queries")).pointer.child, counts.len);
    inline for (Db.query_types, 0..) |Q, i| {
        queries[i] = .{ .name = @typeName(Q), .executions = counts[i] };
    }
    const files = server.vfs.count();
    return .{
        .revision = stats.revision,
        .files = files,
        .deep_verifications = stats.deep_verifications,
        .queries = queries,
    };
}

// ── 发送 ─────────────────────────────────────────────────────────────

fn send(server: *Server, bytes: []u8) void {
    defer server.gpa.free(bytes);
    server.out.writeMessage(bytes) catch |err| log.err("写出消息失败: {t}", .{err});
}

fn sendResponse(server: *Server, id: jsonrpc.Id, result: anytype) void {
    const bytes = jsonrpc.response(server.gpa, id, result) catch return log.err("构造响应时内存不足", .{});
    server.send(bytes);
}

fn sendNotification(server: *Server, method: []const u8, params: anytype) void {
    const bytes = jsonrpc.notification(server.gpa, method, params) catch return log.err("构造通知时内存不足", .{});
    server.send(bytes);
}

fn sendError(server: *Server, id: ?jsonrpc.Id, code: i32, message: []const u8) void {
    const bytes = jsonrpc.errorResponse(server.gpa, id, code, message) catch return log.err("构造错误响应时内存不足", .{});
    server.send(bytes);
}

fn sendHandlerError(server: *Server, id: jsonrpc.Id, err: anyerror, canceled_by_client: bool) void {
    switch (err) {
        error.Canceled => if (canceled_by_client)
            server.sendError(id, jsonrpc.error_codes.request_cancelled, "请求已取消")
        else
            server.sendError(id, jsonrpc.error_codes.content_modified, "文档已修改"),
        error.InvalidParams => server.sendError(id, jsonrpc.error_codes.invalid_params, "参数无效"),
        else => server.sendError(id, jsonrpc.error_codes.internal_error, @errorName(err)),
    }
}

fn destroyArena(server: *Server, arena: *std.heap.ArenaAllocator) void {
    arena.deinit();
    server.gpa.destroy(arena);
}

test {
    _ = @import("Server_test.zig");
}
