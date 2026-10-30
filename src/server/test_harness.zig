//! Interactive test harness: the Server runs on its own thread, and tests send and receive
//! messages one at a time through in-memory pipes; they can wait for responses, and read requests
//! from the server and answer them on the spot.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Server = @import("Server.zig");
const za = @import("../zig_analyzer.zig");
const transport = za.lsp.transport;

/// Thread-safe in-memory pipe: one end writes through `Io.Writer`, and the other end does
/// blocking reads through `Io.Reader`
pub const Pipe = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    data: std.ArrayList(u8) = .empty,
    read_pos: usize = 0,
    closed: bool = false,
    /// Buffer of the read end (reading message headers line by line needs a buffer); attached to
    /// `reader` by `Harness.start` once its address is stable
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

    /// Reads one complete LSP message (blocking; returns an error on timeout)
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
    /// All server messages received (notifications, server requests, responses), in arrival order
    received: std.ArrayList(std.json.Value) = .empty,
    /// When true, requests sent by the server are answered with an error
    reject_requests: bool = false,
    /// When true, requests sent by the server are not answered (simulating a client that
    /// delays its replies)
    hold_requests: bool = false,
    /// The `zig-analyzer` configuration section in replies to `workspace/configuration`
    /// (null means not set)
    configuration: std.json.Value = .null,

    /// `h` must be at a stable address (the Server holds pointers into it)
    pub fn start(h: *Harness) !void {
        return h.startIo(testing.io);
    }

    /// Like `start`, but the server uses the given Io (such as an `Io.Threaded` that limits the
    /// number of threads)
    pub fn startIo(h: *Harness, io: Io) !void {
        return h.startWith(io, null);
    }

    /// Like `start`, with the case rule of file identity given (to cover the case-insensitive
    /// rules on any platform)
    pub fn startCase(h: *Harness, case: za.base.Vfs.CaseRule) !void {
        return h.startWith(testing.io, case);
    }

    fn startWith(h: *Harness, io: Io, case: ?za.base.Vfs.CaseRule) !void {
        h.* = .{};
        h.arena = .init(testing.allocator);
        h.input.reader.buffer = &h.input.read_buf;
        h.writer = .{ .io = testing.io, .inner = &h.output.writer };
        try h.server.init(io, testing.allocator, &h.writer);
        h.server.environ = testing.environ;
        if (case) |c| h.server.vfs.case = c;
        h.thread = try std.Thread.spawn(.{}, runServer, .{h});
    }

    fn runServer(h: *Harness) void {
        h.exit_code = h.server.run(&h.input.reader) catch 255;
        h.output.close();
    }

    /// Closes the input and waits for the server thread to finish
    pub fn finish(h: *Harness) void {
        h.input.close();
        h.thread.join();
        h.server.deinit();
        h.input.deinit();
        h.output.deinit();
        h.arena.deinit();
    }

    pub fn write(h: *Harness, value: anytype) !void {
        const body = try std.json.Stringify.valueAlloc(testing.allocator, value, .{ .emit_null_optional_fields = false });
        defer testing.allocator.free(body);
        try h.writeBody(body);
    }

    /// Sends `body` as one message, byte for byte
    pub fn writeBody(h: *Harness, body: []const u8) !void {
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

    /// Sends a request and waits for its response (other messages that arrive meanwhile are
    /// recorded in `received`)
    pub fn request(h: *Harness, method: []const u8, params: anytype) !std.json.Value {
        return h.response(try h.send(method, params));
    }

    /// Only sends a request and returns its id (wait for it later with `response`)
    pub fn send(h: *Harness, method: []const u8, params: anytype) !i64 {
        const id = h.next_id;
        h.next_id += 1;
        if (@TypeOf(params) == void) {
            try h.write(.{ .jsonrpc = "2.0", .id = id, .method = method });
        } else {
            try h.write(.{ .jsonrpc = "2.0", .id = id, .method = method, .params = params });
        }
        return id;
    }

    /// Waits for the response with the given id; one already received is looked up in `received`
    pub fn response(h: *Harness, id: i64) !std.json.Value {
        for (h.received.items) |msg| {
            if (msg.object.get("method") == null) if (msg.object.get("id")) |i| if (i == .integer and i.integer == id) return msg;
        }
        while (true) {
            const msg = try h.next();
            if (msg.object.get("method") == null) if (msg.object.get("id")) |i| if (i == .integer and i.integer == id) return msg;
        }
    }

    /// Reads the next server message; server requests are handled by `on_request` (answered with
    /// success by default)
    pub fn next(h: *Harness) !std.json.Value {
        const msg = try h.output.readMessage(h.arena.allocator(), 120_000);
        try h.received.append(h.arena.allocator(), msg);
        if (msg.object.get("method") != null) if (msg.object.get("id")) |id| {
            if (h.hold_requests) {
                // Do not reply
            } else if (h.reject_requests) {
                try h.write(.{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = -32603, .message = "rejected" } });
            } else if (std.mem.eql(u8, msg.object.get("method").?.string, "workspace/configuration")) {
                try h.write(.{ .jsonrpc = "2.0", .id = id, .result = &[_]std.json.Value{h.configuration} });
            } else {
                try h.write(.{ .jsonrpc = "2.0", .id = id, .result = null });
            }
        };
        return msg;
    }

    /// Notifications of the given method received so far
    pub fn notifications(h: *Harness, method: []const u8) ![]std.json.Value {
        var out: std.ArrayList(std.json.Value) = .empty;
        for (h.received.items) |m| {
            if (m.object.get("id") != null) continue;
            const mm = m.object.get("method") orelse continue;
            if (std.mem.eql(u8, mm.string, method)) try out.append(h.arena.allocator(), m);
        }
        return out.items;
    }

    /// Diagnostics last published for each file (the last segment of the URI):
    /// "line:column source: message"
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
