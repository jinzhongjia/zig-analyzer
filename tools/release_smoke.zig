//! Smoke test of a released executable: starts it as a real editor would, over stdin/stdout,
//! opens a file of a project, checks a hover result, and shuts it down.
//!
//! Usage: zig build release-smoke -- <zig-analyzer> <project root> [<expected version>]
//!
//! The project is `editors/test-project` (or a copy of it): the hover is on the call of
//! `shapes.area` in `src/main.zig`, and must show its signature and doc comment. The answer waits
//! for the project to load (`sema.wait_for_project`), so the check covers the build system
//! protocol and the zig in PATH as well. With an expected version, `serverInfo.version` must equal
//! it. The exit code is 0 when every step succeeds.

const std = @import("std");
const Io = std.Io;
const json = std.json;
const za = @import("zig_analyzer");
const transport = za.lsp.transport;

const Client = struct {
    io: Io,
    arena: std.mem.Allocator,
    child: std.process.Child,
    reader: Io.File.Reader,
    writer: Io.File.Writer,
    read_buffer: [64 * 1024]u8 = undefined,
    write_buffer: [64 * 1024]u8 = undefined,
    next_id: i64 = 1,

    fn send(c: *Client, value: anytype) !void {
        const body = try json.Stringify.valueAlloc(c.arena, value, .{ .emit_null_optional_fields = false });
        const w = &c.writer.interface;
        try w.print("Content-Length: {d}\r\n\r\n", .{body.len});
        try w.writeAll(body);
        try w.flush();
    }

    fn notify(c: *Client, method: []const u8, params: anytype) !void {
        try c.send(.{ .jsonrpc = "2.0", .method = method, .params = params });
    }

    /// The result of the request; requests from the server are answered with null meanwhile
    fn request(c: *Client, method: []const u8, params: anytype) !json.Value {
        const id = c.next_id;
        c.next_id += 1;
        if (@TypeOf(params) == void) {
            try c.send(.{ .jsonrpc = "2.0", .id = id, .method = method });
        } else {
            try c.send(.{ .jsonrpc = "2.0", .id = id, .method = method, .params = params });
        }
        while (true) {
            const body = try transport.readMessage(&c.reader.interface, c.arena);
            const msg = try json.parseFromSliceLeaky(json.Value, c.arena, body, .{});
            const got = msg.object.get("id") orelse continue;
            if (msg.object.get("method") != null) {
                try c.send(.{ .jsonrpc = "2.0", .id = got, .result = null });
                continue;
            }
            if (got != .integer or got.integer != id) continue;
            if (msg.object.get("error")) |err| {
                std.debug.print("error: {s} failed: {f}\n", .{ method, std.json.fmt(err, .{}) });
                return error.RequestFailed;
            }
            return msg.object.get("result") orelse .null;
        }
    }
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3 and args.len != 4) {
        std.debug.print("usage: {s} <zig-analyzer> <project root> [<expected version>]\n", .{args[0]});
        return 2;
    }
    const root = try Io.Dir.cwd().realPathFileAlloc(io, args[2], arena);
    const root_uri = try za.base.uri.fromPath(arena, root);
    const main_path = try std.fs.path.join(arena, &.{ root, "src", "main.zig" });
    const main_uri = try za.base.uri.fromPath(arena, main_path);
    const text = try Io.Dir.cwd().readFileAlloc(io, main_path, arena, .unlimited);

    // The position of `area` in `shapes.area(square)`, as a line and an ASCII column
    const call = std.mem.indexOf(u8, text, "shapes.area(square)") orelse {
        std.debug.print("error: {s} has no call of shapes.area\n", .{main_path});
        return 1;
    };
    const offset = call + "shapes.".len;
    const line = std.mem.count(u8, text[0..offset], "\n");
    const column = offset - (if (std.mem.lastIndexOfScalar(u8, text[0..offset], '\n')) |nl| nl + 1 else 0);

    var c: Client = .{ .io = io, .arena = arena, .child = undefined, .reader = undefined, .writer = undefined };
    c.child = try std.process.spawn(io, .{ .argv = &.{args[1]}, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit });
    c.reader = c.child.stdout.?.readerStreaming(io, &c.read_buffer);
    c.writer = c.child.stdin.?.writerStreaming(io, &c.write_buffer);

    const init_result = try c.request("initialize", .{
        .processId = null,
        .rootUri = root_uri,
        .workspaceFolders = &.{.{ .uri = root_uri, .name = "test-project" }},
        .capabilities = .{ .textDocument = .{ .hover = .{ .contentFormat = &[_][]const u8{"markdown"} } } },
        .initializationOptions = .{ .sema = .{ .wait_for_project = true } },
    });
    const server_info = init_result.object.get("serverInfo").?.object;
    const version = server_info.get("version").?.string;
    std.debug.print("server: {s} {s}\n", .{ server_info.get("name").?.string, version });
    if (args.len == 4 and !std.mem.eql(u8, version, args[3])) {
        std.debug.print("error: the server reports version {s}, expected {s}\n", .{ version, args[3] });
        return 1;
    }
    try c.notify("initialized", struct {}{});
    try c.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = main_uri, .languageId = "zig", .version = 1, .text = text } });

    const hover = try c.request("textDocument/hover", .{
        .textDocument = .{ .uri = main_uri },
        .position = .{ .line = line, .character = column },
    });
    const contents = if (hover == .object) hover.object.get("contents") else null;
    const value = if (contents) |v| if (v == .object) v.object.get("value") else null else null;
    const hover_text = if (value) |v| v.string else "";
    for ([_][]const u8{ "fn area(s: Square) u32", "The area of a square." }) |expected| {
        if (std.mem.indexOf(u8, hover_text, expected) == null) {
            std.debug.print("error: the hover lacks `{s}`:\n{s}\n", .{ expected, hover_text });
            return 1;
        }
    }
    std.debug.print("hover: ok\n", .{});

    _ = try c.request("shutdown", {});
    try c.notify("exit", null);
    const term = try c.child.wait(io);
    if (!term.success()) {
        std.debug.print("error: the server ended with {any}\n", .{term});
        return 1;
    }
    std.debug.print("shutdown: ok\n", .{});
    return 0;
}
