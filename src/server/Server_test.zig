const std = @import("std");
const testing = std.testing;
const Server = @import("Server.zig");
const za = @import("../zig_analyzer.zig");
const transport = za.lsp.transport;
const FileText = @import("../database.zig").inputs.FileText;

inline fn frame(comptime body: []const u8) []const u8 {
    return comptime std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

const file_uri = if (@import("builtin").target.os.tag == .windows) "file:///C:/tmp/a.zig" else "file:///tmp/a.zig";

const Session = struct {
    out: std.Io.Writer.Allocating,
    writer: transport.Writer,
    server: Server,
    exit_code: u8,
    arena: std.heap.ArenaAllocator,

    fn run(s: *Session, input: []const u8) !void {
        s.out = .init(testing.allocator);
        s.writer = .{ .io = testing.io, .inner = &s.out.writer };
        s.server = .init(testing.io, testing.allocator, &s.writer);
        s.arena = .init(testing.allocator);
        var reader: std.Io.Reader = .fixed(input);
        s.exit_code = try s.server.run(&reader);
    }

    fn deinit(s: *Session) void {
        s.server.deinit();
        s.out.deinit();
        s.arena.deinit();
    }

    /// 按顺序解析服务器输出的全部消息
    fn messages(s: *Session) ![]std.json.Value {
        var reader: std.Io.Reader = .fixed(s.out.written());
        var list: std.ArrayList(std.json.Value) = .empty;
        const a = s.arena.allocator();
        while (transport.readMessage(&reader, a)) |body| {
            try list.append(a, try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}));
        } else |err| if (err != error.EndOfStream) return err;
        return list.items;
    }
};

fn errorCode(msg: std.json.Value) i64 {
    return msg.object.get("error").?.object.get("code").?.integer;
}

test "完整生命周期：初始化、文档同步、读请求、关闭" {
    var s: Session = undefined;
    try s.run(frame(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"general":{"positionEncodings":["utf-16","utf-8"]}}}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"
    ++ file_uri ++
        \\","languageId":"zig","version":1,"text":"const a = 1;\n"}}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"
    ++ file_uri ++
        \\","version":2},"contentChanges":[{"range":{"start":{"line":0,"character":10},"end":{"line":0,"character":11}},"text":"42"}]}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":2,"method":"zig-analyzer/status"}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
    ) ++ frame(
        \\{"jsonrpc":"2.0","method":"exit"}
    ));
    defer s.deinit();
    try testing.expectEqual(0, s.exit_code);

    const msgs = try s.messages();
    try testing.expectEqual(3, msgs.len);

    const init_result = msgs[0].object.get("result").?.object;
    try testing.expectEqualStrings("utf-8", init_result.get("capabilities").?.object.get("positionEncoding").?.string);
    try testing.expectEqualStrings("zig-analyzer", init_result.get("serverInfo").?.object.get("name").?.string);

    const st = msgs[1].object.get("result").?.object;
    try testing.expectEqual(2, msgs[1].object.get("id").?.integer);
    try testing.expectEqual(1, st.get("files").?.integer);
    try testing.expectEqual(3, st.get("revision").?.integer);

    try testing.expectEqual(3, msgs[2].object.get("id").?.integer);
    try testing.expect(msgs[2].object.get("result").? == .null);

    // 增量变更已应用
    const id = (try s.server.vfs.lookup(try za.base.uri.toPath(s.arena.allocator(), file_uri))).?;
    var ctx = s.server.db.beginRead(testing.allocator);
    defer ctx.end();
    try testing.expectEqualStrings("const a = 42;\n", (try ctx.get(FileText, id)).?);
}

test "初始化前的请求返回 ServerNotInitialized，未知方法返回 MethodNotFound" {
    var s: Session = undefined;
    try s.run(frame(
        \\{"jsonrpc":"2.0","id":1,"method":"zig-analyzer/status"}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"capabilities":{}}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/unknownThing","params":{}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":4,"method":"initialize","params":{"capabilities":{}}}
    ) ++ frame(
        \\not json
    ) ++ frame(
        \\{"jsonrpc":"2.0","method":"exit"}
    ));
    defer s.deinit();
    // 未收到 shutdown 就退出
    try testing.expectEqual(1, s.exit_code);

    const msgs = try s.messages();
    try testing.expectEqual(5, msgs.len);
    try testing.expectEqual(-32002, errorCode(msgs[0]));
    try testing.expectEqualStrings("utf-16", msgs[1].object.get("result").?.object.get("capabilities").?.object.get("positionEncoding").?.string);
    try testing.expectEqual(-32601, errorCode(msgs[2]));
    try testing.expectEqual(-32600, errorCode(msgs[3]));
    try testing.expectEqual(-32700, errorCode(msgs[4]));
}

test "参数格式错误返回 InvalidParams" {
    var s: Session = undefined;
    try s.run(frame(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":42}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","method":"exit"}
    ));
    defer s.deinit();
    const msgs = try s.messages();
    try testing.expectEqual(-32602, errorCode(msgs[0]));
}
