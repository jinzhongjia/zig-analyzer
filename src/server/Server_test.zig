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
        try s.server.init(testing.io, testing.allocator, &s.writer);
        s.arena = .init(testing.allocator);
        var reader: std.Io.Reader = .fixed(input);
        s.exit_code = try s.server.run(&reader);
    }

    fn deinit(s: *Session) void {
        s.server.deinit();
        s.out.deinit();
        s.arena.deinit();
    }

    /// 按顺序解析服务器输出的全部响应（不含服务器主动发出的通知）
    fn messages(s: *Session) ![]std.json.Value {
        return s.collect(.responses);
    }

    /// 服务器主动发出的通知（如 publishDiagnostics）
    fn notifications(s: *Session) ![]std.json.Value {
        return s.collect(.notifications);
    }

    fn collect(s: *Session, which: enum { responses, notifications }) ![]std.json.Value {
        var reader: std.Io.Reader = .fixed(s.out.written());
        var list: std.ArrayList(std.json.Value) = .empty;
        const a = s.arena.allocator();
        while (transport.readMessage(&reader, a)) |body| {
            const msg = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
            const is_notification = msg.object.get("method") != null;
            if (is_notification == (which == .notifications)) try list.append(a, msg);
        } else |err| if (err != error.EndOfStream) return err;
        return list.items;
    }
};

fn errorCode(msg: std.json.Value) i64 {
    return msg.object.get("error").?.object.get("code").?.integer;
}

test "full lifecycle: initialize, document sync, read requests, shutdown" {
    var s: Session = undefined;
    // zig 指向不存在的路径：后台启动（zig env、加载 std）确定地失败，不与 status 的文件数与 revision 竞争
    try s.run(frame(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"general":{"positionEncodings":["utf-16","utf-8"]}},"initializationOptions":{"zig":{"path":"/nonexistent/zig"}}}}
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

    // 合法代码：最后一次推送的诊断为空
    const notes = try s.notifications();
    try testing.expect(notes.len >= 1);
    const last = notes[notes.len - 1].object;
    try testing.expectEqualStrings("textDocument/publishDiagnostics", last.get("method").?.string);
    try testing.expectEqual(0, last.get("params").?.object.get("diagnostics").?.array.items.len);
}

test "push live diagnostics, clear on close" {
    var s: Session = undefined;
    try s.run(frame(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"
    ++ file_uri ++
        \\","languageId":"zig","version":1,"text":"fn f() void {\n    var x = 1;\n}\n"}}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
    ) ++ frame(
        \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"
    ++ file_uri ++
        \\"}}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","method":"exit"}
    ));
    defer s.deinit();

    const notes = try s.notifications();
    try testing.expectEqual(2, notes.len);
    const diags = notes[0].object.get("params").?.object.get("diagnostics").?.array.items;
    try testing.expectEqual(1, diags.len);
    const d = diags[0].object;
    try testing.expectEqualStrings("unused local variable", d.get("message").?.string);
    try testing.expectEqualStrings("zig ast-check", d.get("source").?.string);
    const start = d.get("range").?.object.get("start").?.object;
    try testing.expectEqual(1, start.get("line").?.integer);
    try testing.expectEqual(8, start.get("character").?.integer);
    // didClose 后清空
    try testing.expectEqual(0, notes[1].object.get("params").?.object.get("diagnostics").?.array.items.len);
}

test "syntax features end to end" {
    var s: Session = undefined;
    try s.run(frame(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"
    ++ file_uri ++
        \\","languageId":"zig","version":1,"text":"const  S = struct {\n    a: u32,\n};\n"}}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"
    ++ file_uri ++
        \\"}}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/formatting","params":{"textDocument":{"uri":"
    ++ file_uri ++
        \\"},"options":{"tabSize":4,"insertSpaces":true}}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/foldingRange","params":{"textDocument":{"uri":"
    ++ file_uri ++
        \\"}}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"
    ++ file_uri ++
        \\"}}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":6,"method":"textDocument/selectionRange","params":{"textDocument":{"uri":"
    ++ file_uri ++
        \\"},"positions":[{"line":1,"character":4}]}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":7,"method":"shutdown"}
    ) ++ frame(
        \\{"jsonrpc":"2.0","method":"exit"}
    ));
    defer s.deinit();

    const msgs = try s.messages();
    var by_id: [8]?std.json.ObjectMap = @splat(null);
    for (msgs) |m| by_id[@intCast(m.object.get("id").?.integer)] = m.object;

    const symbols = by_id[2].?.get("result").?.array.items;
    try testing.expectEqualStrings("S", symbols[0].object.get("name").?.string);
    try testing.expectEqual(1, symbols[0].object.get("children").?.array.items.len);

    const edits = by_id[3].?.get("result").?.array.items;
    try testing.expectEqual(1, edits.len);
    try testing.expectEqualStrings("const S = struct {\n", edits[0].object.get("newText").?.string);

    try testing.expectEqual(1, by_id[4].?.get("result").?.array.items.len);
    try testing.expect(by_id[5].?.get("result").?.object.get("data").?.array.items.len > 0);

    const sel = by_id[6].?.get("result").?.array.items[0].object;
    try testing.expectEqual(4, sel.get("range").?.object.get("start").?.object.get("character").?.integer);
}

test "requests before initialize return ServerNotInitialized, unknown methods return MethodNotFound" {
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

test "malformed params return InvalidParams" {
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

test "read requests run on their own threads: a blocked read does not stall the main loop" {
    const Harness = @import("test_harness.zig").Harness;
    // 线程池没有空位：`async` 会在调用方同步执行
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .async_limit = .nothing });
    defer threaded.deinit();
    var h: Harness = undefined;
    try h.startIo(threaded.io());
    defer h.finish();
    const Empty = struct {};
    _ = try h.request("initialize", .{ .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    _ = try h.request("zig-analyzer/waitIdle", {});

    // 持有写锁：读请求等在读事务的开始处
    h.server.db.beginWrite();
    var writing = true;
    defer if (writing) h.server.db.endWrite();
    const blocked = try h.send("zig-analyzer/status", {});
    try h.notify("$/cancelRequest", .{ .id = blocked });
    // 主循环仍在处理消息
    try testing.expectEqual(-32601, errorCode(try h.request("zig-analyzer/probe", {})));

    h.server.db.endWrite();
    writing = false;
    // 取消在读请求阻塞期间送达
    try testing.expectEqual(-32800, errorCode(try h.response(blocked)));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "live diagnostics are debounced per file and AstGen runs outside the read transaction" {
    const Harness = @import("test_harness.zig").Harness;
    const Empty = struct {};
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    // 防抖取得较长，使连续的编辑必然落在同一窗口内
    const options = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(),
        \\{"diagnostics": {"debounce_ms": 300}}
    , .{});
    _ = try h.request("initialize", .{ .capabilities = Empty{}, .initializationOptions = options });
    try h.notify("initialized", Empty{});
    const uri = "untitled:Untitled-1";
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = "const a = 1;\n" } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const before = (try h.notifications("textDocument/publishDiagnostics")).len;

    const texts = [_][]const u8{ "const a = 1", "const a = 1;\nconst", "const a = 1;\nconst b", "const a = 1;\nconst b =", "const a = 1;\nconst b = ;\n" };
    for (texts, 2..) |text, version| {
        try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .text = text }} });
    }
    _ = try h.request("zig-analyzer/waitIdle", {});
    const published = try h.notifications("textDocument/publishDiagnostics");
    // 五次编辑只发布一次，按最后的文本
    try testing.expectEqual(before + 1, published.len);
    const diags = published[published.len - 1].object.get("params").?.object.get("diagnostics").?.array.items;
    try testing.expectEqual(1, diags.len);
    try testing.expectEqualStrings("expected expression, found ';'", diags[0].object.get("message").?.string);
    // AstCheck 取用了在读事务之外算好的结果
    try testing.expect(h.server.live_prepared.hits >= 2);
    try testing.expectEqual(0, h.server.live_prepared.entries.items.len);

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "resetting type information gives the same hover results" {
    const Harness = @import("test_harness.zig").Harness;
    const Empty = struct {};
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try h.request("initialize", .{ .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = "untitled:Untitled-2";
    const text =
        \\fn List(comptime T: type) type {
        \\    return struct { items: []T };
        \\}
        \\const L = List(u8);
        \\pub fn main() void {
        \\    const l: L = undefined;
        \\    _ = l.items;
        \\}
        \\
    ;
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const at = .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 6, .character = 11 } };
    const before = try h.request("textDocument/hover", at);
    const contents = before.object.get("result").?.object.get("contents").?.object.get("value").?.string;
    try testing.expect(std.mem.indexOf(u8, contents, "[]u8") != null);

    const items = h.server.ip.count();
    h.server.resetSema();
    try testing.expect(h.server.ip.count() < items);
    const after = try h.request("textDocument/hover", at);
    try testing.expectEqualStrings(contents, after.object.get("result").?.object.get("contents").?.object.get("value").?.string);

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}
