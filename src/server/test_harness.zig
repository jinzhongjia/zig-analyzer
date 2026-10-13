//! 交互式测试工具：Server 在独立线程中运行，测试通过内存管道逐条收发消息，
//! 可以等待响应、读取服务器发来的请求并当场回复。

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Server = @import("Server.zig");
const za = @import("../zig_analyzer.zig");
const transport = za.lsp.transport;

/// 线程安全的内存管道：一端通过 `Io.Writer` 写入，另一端通过 `Io.Reader` 阻塞读取
pub const Pipe = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    data: std.ArrayList(u8) = .empty,
    read_pos: usize = 0,
    closed: bool = false,
    /// 读端缓冲（按行读取消息头需要缓冲）；地址稳定后由 `Harness.start` 接到 `reader` 上
    read_buf: [64 * 1024]u8 = undefined,

    reader: Io.Reader = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },
    writer: Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

    pub fn deinit(p: *Pipe) void {
        p.data.deinit(testing.allocator);
    }

    pub fn close(p: *Pipe) void {
        p.mutex.lockUncancelable(testing.io);
        defer p.mutex.unlock(testing.io);
        p.closed = true;
        p.cond.broadcast(testing.io);
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const p: *Pipe = @alignCast(@fieldParentPtr("reader", r));
        p.mutex.lockUncancelable(testing.io);
        defer p.mutex.unlock(testing.io);
        while (p.read_pos == p.data.items.len) {
            if (p.closed) return error.EndOfStream;
            p.cond.waitUncancelable(testing.io, &p.mutex);
        }
        const available = p.data.items[p.read_pos..];
        const n = limit.minInt(available.len);
        try w.writeAll(available[0..n]);
        p.read_pos += n;
        return n;
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const p: *Pipe = @alignCast(@fieldParentPtr("writer", w));
        p.mutex.lockUncancelable(testing.io);
        defer p.mutex.unlock(testing.io);
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            p.data.appendSlice(testing.allocator, d) catch return error.WriteFailed;
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            p.data.appendSlice(testing.allocator, last) catch return error.WriteFailed;
            n += last.len;
        }
        p.cond.broadcast(testing.io);
        return n;
    }

    /// 读取一条完整的 LSP 消息（阻塞，超时返回错误）
    fn readMessage(p: *Pipe, arena: Allocator, timeout_ms: i64) !std.json.Value {
        const deadline = Io.Clock.Timestamp.fromNow(testing.io, .{ .clock = .awake, .raw = .fromMilliseconds(timeout_ms) });
        p.mutex.lockUncancelable(testing.io);
        defer p.mutex.unlock(testing.io);
        while (true) {
            const available = p.data.items[p.read_pos..];
            if (std.mem.indexOf(u8, available, "\r\n\r\n")) |header_end| {
                var r: Io.Reader = .fixed(available);
                const body = transport.readMessage(&r, arena) catch |err| switch (err) {
                    error.EndOfStream => null,
                    else => |e| return e,
                };
                _ = header_end;
                if (body) |b| {
                    p.read_pos += r.seek;
                    return std.json.parseFromSliceLeaky(std.json.Value, arena, b, .{});
                }
            }
            if (p.closed) return error.EndOfStream;
            p.cond.waitTimeout(testing.io, &p.mutex, .{ .deadline = deadline }) catch return error.Timeout;
        }
    }
};

pub const Harness = struct {
    input: Pipe = .{},
    output: Pipe = .{},
    writer: transport.Writer = undefined,
    server: Server = undefined,
    thread: std.Thread = undefined,
    exit_code: u8 = 255,
    arena: std.heap.ArenaAllocator = undefined,
    next_id: i64 = 1,
    /// 收到的全部服务器消息（通知、服务器请求、响应），按到达顺序
    received: std.ArrayList(std.json.Value) = .empty,
    /// 为 true 时以错误回复服务器发来的请求
    reject_requests: bool = false,
    /// 回复 `workspace/configuration` 的 `zig-analyzer` 配置节（null 表示未设置）
    configuration: std.json.Value = .null,

    /// `h` 必须位于稳定的地址（Server 持有指向其内部的指针）
    pub fn start(h: *Harness) !void {
        h.* = .{};
        h.arena = .init(testing.allocator);
        h.input.reader.buffer = &h.input.read_buf;
        h.writer = .{ .io = testing.io, .inner = &h.output.writer };
        try h.server.init(testing.io, testing.allocator, &h.writer);
        h.thread = try std.Thread.spawn(.{}, runServer, .{h});
    }

    fn runServer(h: *Harness) void {
        h.exit_code = h.server.run(&h.input.reader) catch 255;
        h.output.close();
    }

    /// 关闭输入并等待服务器线程结束
    pub fn finish(h: *Harness) void {
        h.input.close();
        h.thread.join();
        h.server.deinit();
        h.input.deinit();
        h.output.deinit();
        h.arena.deinit();
    }

    fn write(h: *Harness, value: anytype) !void {
        const body = try std.json.Stringify.valueAlloc(testing.allocator, value, .{ .emit_null_optional_fields = false });
        defer testing.allocator.free(body);
        var header: [64]u8 = undefined;
        const w = &h.input.writer;
        try w.writeAll(try std.fmt.bufPrint(&header, "Content-Length: {d}\r\n\r\n", .{body.len}));
        try w.writeAll(body);
    }

    pub fn notify(h: *Harness, method: []const u8, params: anytype) !void {
        if (@TypeOf(params) == void) {
            try h.write(.{ .jsonrpc = "2.0", .method = method });
        } else {
            try h.write(.{ .jsonrpc = "2.0", .method = method, .params = params });
        }
    }

    /// 发送请求并等待其响应（期间到达的其他消息记入 `received`）
    pub fn request(h: *Harness, method: []const u8, params: anytype) !std.json.Value {
        const id = h.next_id;
        h.next_id += 1;
        if (@TypeOf(params) == void) {
            try h.write(.{ .jsonrpc = "2.0", .id = id, .method = method });
        } else {
            try h.write(.{ .jsonrpc = "2.0", .id = id, .method = method, .params = params });
        }
        while (true) {
            const msg = try h.next();
            if (msg.object.get("method") == null) if (msg.object.get("id")) |i| if (i == .integer and i.integer == id) return msg;
        }
    }

    /// 读取下一条服务器消息；服务器请求由 `on_request` 处理（默认回复成功）
    pub fn next(h: *Harness) !std.json.Value {
        const msg = try h.output.readMessage(h.arena.allocator(), 120_000);
        try h.received.append(h.arena.allocator(), msg);
        if (msg.object.get("method") != null) if (msg.object.get("id")) |id| {
            if (h.reject_requests) {
                try h.write(.{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = -32603, .message = "rejected" } });
            } else if (std.mem.eql(u8, msg.object.get("method").?.string, "workspace/configuration")) {
                try h.write(.{ .jsonrpc = "2.0", .id = id, .result = &[_]std.json.Value{h.configuration} });
            } else {
                try h.write(.{ .jsonrpc = "2.0", .id = id, .result = null });
            }
        };
        return msg;
    }

    /// 已收到的、指定方法的通知
    pub fn notifications(h: *Harness, method: []const u8) ![]std.json.Value {
        var out: std.ArrayList(std.json.Value) = .empty;
        for (h.received.items) |m| {
            if (m.object.get("id") != null) continue;
            const mm = m.object.get("method") orelse continue;
            if (std.mem.eql(u8, mm.string, method)) try out.append(h.arena.allocator(), m);
        }
        return out.items;
    }

    /// 每个文件（URI 的最后一段）最后一次发布的诊断：「行:列 来源: 文案」
    pub fn diagnostics(h: *Harness) !std.StringArrayHashMapUnmanaged([]const []const u8) {
        const a = h.arena.allocator();
        var result: std.StringArrayHashMapUnmanaged([]const []const u8) = .empty;
        for (try h.notifications("textDocument/publishDiagnostics")) |m| {
            const params = m.object.get("params").?.object;
            const diags = params.get("diagnostics").?.array.items;
            const lines = try a.alloc([]const u8, diags.len);
            for (diags, lines) |d, *l| {
                const pos = d.object.get("range").?.object.get("start").?.object;
                l.* = try std.fmt.allocPrint(a, "{d}:{d} {s}: {s}", .{
                    pos.get("line").?.integer,
                    pos.get("character").?.integer,
                    d.object.get("source").?.string,
                    d.object.get("message").?.string,
                });
            }
            const uri = params.get("uri").?.string;
            try result.put(a, uri[std.mem.lastIndexOfScalar(u8, uri, '/').? + 1 ..], lines);
        }
        return result;
    }
};
