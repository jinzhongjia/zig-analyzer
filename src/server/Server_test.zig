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
    // zig 指向不存在的路径：后台启动（zig env、加载 std）确定地失败，不与 status 的文件数与 revision 竞争。
    // 失败时的警告是预期的，不写到 stderr
    const prev_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = prev_level;
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

test "duplicate initialized is ignored, including after shutdown" {
    var s: Session = undefined;
    // 使用真实的 zig 查询环境：重复的 initialized 不应再次启动加载
    try s.run(frame(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"initializationOptions":{"zig":{"path":"zig"}}}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
    ) ++ frame(
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","method":"exit"}
    ));
    defer s.deinit();
    try testing.expectEqual(0, s.exit_code);
}

test "push live diagnostics, clear on close" {
    // 打开时的 live 诊断（shutdown 等待发布完成）
    {
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
            \\{"jsonrpc":"2.0","method":"exit"}
        ));
        defer s.deinit();

        const notes = try s.notifications();
        try testing.expectEqual(1, notes.len);
        const diags = notes[0].object.get("params").?.object.get("diagnostics").?.array.items;
        try testing.expectEqual(1, diags.len);
        const d = diags[0].object;
        try testing.expectEqualStrings("unused local variable", d.get("message").?.string);
        try testing.expectEqualStrings("zig ast-check", d.get("source").?.string);
        const start = d.get("range").?.object.get("start").?.object;
        try testing.expectEqual(1, start.get("line").?.integer);
        try testing.expectEqual(8, start.get("character").?.integer);
    }
    // 关闭后清空：打开时的发布可能与关闭的发布并发，只断言最后一次结果
    {
        var s: Session = undefined;
        try s.run(frame(
            \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ) ++ frame(
            \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"
        ++ file_uri ++
            \\","languageId":"zig","version":1,"text":"fn f() void {\n    var x = 1;\n}\n"}}}
        ) ++ frame(
            \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"
        ++ file_uri ++
            \\"}}}
        ) ++ frame(
            \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ) ++ frame(
            \\{"jsonrpc":"2.0","method":"exit"}
        ));
        defer s.deinit();

        const notes = try s.notifications();
        for (notes) |n| {
            const params = n.object.get("params").?.object;
            try testing.expectEqualStrings(file_uri, params.get("uri").?.string);
        }
        // 打开与关闭的发布可能合并；有发布时最后一次必须是空列表
        if (notes.len != 0) {
            const last = notes[notes.len - 1].object.get("params").?.object;
            try testing.expectEqual(0, last.get("diagnostics").?.array.items.len);
        }
    }
}

test "close: non-file documents clear diagnostics on the client URI" {
    const untitled = "untitled:Untitled-1";
    // 打开时对客户端 URI 发布诊断
    {
        var s: Session = undefined;
        try s.run(frame(
            \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ) ++ frame(
            \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"
        ++ untitled ++
            \\","languageId":"zig","version":1,"text":"fn f() void {\n    var x = 1;\n}\n"}}}
        ) ++ frame(
            \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ) ++ frame(
            \\{"jsonrpc":"2.0","method":"exit"}
        ));
        defer s.deinit();
        const notes = try s.notifications();
        try testing.expectEqual(1, notes.len);
        const params = notes[0].object.get("params").?.object;
        try testing.expectEqualStrings(untitled, params.get("uri").?.string);
        try testing.expectEqual(1, params.get("diagnostics").?.array.items.len);
    }
    // 关闭后对客户端 URI 发送空列表，而不是内部的虚拟路径
    {
        var s: Session = undefined;
        try s.run(frame(
            \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
        ) ++ frame(
            \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"
        ++ untitled ++
            \\","languageId":"zig","version":1,"text":"fn f() void {\n    var x = 1;\n}\n"}}}
        ) ++ frame(
            \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"
        ++ untitled ++
            \\"}}}
        ) ++ frame(
            \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
        ) ++ frame(
            \\{"jsonrpc":"2.0","method":"exit"}
        ));
        defer s.deinit();
        const notes = try s.notifications();
        for (notes) |n| {
            const params = n.object.get("params").?.object;
            try testing.expectEqualStrings(untitled, params.get("uri").?.string);
        }
        // 打开与关闭的发布可能合并；有发布时最后一次必须是空列表
        if (notes.len != 0) {
            const params = notes[notes.len - 1].object.get("params").?.object;
            try testing.expectEqual(0, params.get("diagnostics").?.array.items.len);
        }
    }
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

test "inspection requests for a standalone file: file status, syntax tree, module graph and reload" {
    var s: Session = undefined;
    try s.run(frame(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"
    ++ file_uri ++
        \\","languageId":"zig","version":1,"text":"const a = ;\n"}}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":2,"method":"zig-analyzer/fileStatus","params":{"textDocument":{"uri":"
    ++ file_uri ++
        \\"}}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":3,"method":"zig-analyzer/syntaxTree","params":{"textDocument":{"uri":"
    ++ file_uri ++
        \\"}}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":4,"method":"zig-analyzer/moduleGraph"}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":5,"method":"zig-analyzer/reloadWorkspace"}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":6,"method":"shutdown"}
    ) ++ frame(
        \\{"jsonrpc":"2.0","method":"exit"}
    ));
    defer s.deinit();

    const msgs = try s.messages();
    var by_id: [7]?std.json.ObjectMap = @splat(null);
    for (msgs) |m| by_id[@intCast(m.object.get("id").?.integer)] = m.object;

    // 没有工作区、不属于任何项目的独立文件
    const status = by_id[2].?.get("result").?.object;
    try testing.expectEqualStrings("other", status.get("origin").?.string);
    try testing.expectEqualStrings("detached", status.get("context").?.string);
    try testing.expect(status.get("open").?.bool);
    try testing.expectEqual(0, status.get("modules").?.array.items.len);
    try testing.expectEqual(0, status.get("projects").?.array.items.len);

    const tree = by_id[3].?.get("result").?.string;
    try testing.expect(std.mem.startsWith(u8, tree, "source_file@0..12\n"));
    try testing.expect(std.mem.indexOf(u8, tree, "error@") != null);

    try testing.expectEqual(0, by_id[4].?.get("result").?.object.get("modules").?.array.items.len);
    try testing.expect(by_id[5].?.get("error") == null);
}

test "files under a build.zig outside the workspace belong to a project that is not loaded" {
    const Harness = @import("test_harness.zig").Harness;
    // `zig build test` 中找不到 zig：启动阶段的警告不写到 stderr
    const prev_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = prev_level;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "proj/src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "proj/build.zig", .data = "" });
    try tmp.dir.createDirPath(testing.io, "capital");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "capital/Build.zig", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const Empty = struct {};
    _ = try h.request("initialize", .{ .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const cases = [_]struct { []const []const u8, []const u8 }{
        .{ &.{ "proj", "src", "main.zig" }, "unloaded_project" },
        // 临时目录在本仓库的 .zig-cache 中：查找所属的项目时不越过它
        .{ &.{"scratch.zig"}, "detached" },
        // 只有 Build.zig（如标准库的 `std/Build.zig`）：大小写不敏感的文件系统上按路径访问 build.zig 同样成功，
        // 防止把这样的目录当作项目
        .{ &.{ "capital", "main.zig" }, "detached" },
    };
    for (cases) |c| {
        const path = try std.fs.path.join(a, &.{ root, try std.fs.path.join(a, c[0]) });
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "pub fn main() void {}\n" });
        const document_uri = try za.base.uri.fromPath(a, path);
        try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = document_uri, .languageId = "zig", .version = 1, .text = "pub fn main() void {}\n" } });
        const status = try h.request("zig-analyzer/fileStatus", .{ .textDocument = .{ .uri = document_uri } });
        try testing.expectEqualStrings(c[1], status.object.get("result").?.object.get("context").?.string);
    }
    _ = try h.request("zig-analyzer/waitIdle", {});
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "responses for deeply nested code stay within the JSON nesting limit" {
    const Harness = @import("test_harness.zig").Harness;
    const prev_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = prev_level;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    // 嵌套 150 层的匿名结构体，以及 500 层括号
    try text.appendSlice(testing.allocator, "const S = struct {\n");
    for (0..150) |_| try text.appendSlice(testing.allocator, "a: struct {\n");
    for (0..150) |_| try text.appendSlice(testing.allocator, "},\n");
    try text.appendSlice(testing.allocator, "};\nconst x = ");
    for (0..500) |_| try text.append(testing.allocator, '(');
    try text.append(testing.allocator, '1');
    for (0..500) |_| try text.append(testing.allocator, ')');
    try text.appendSlice(testing.allocator, ";\n");

    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const Empty = struct {};
    _ = try h.request("initialize", .{ .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const document_uri = try za.base.uri.fromPath(a, try std.fs.path.join(a, &.{ root, "deep.zig" }));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = document_uri, .languageId = "zig", .version = 1, .text = text.items } });
    // 等启动完成：查询 zig 环境之后更新模块图的写事务会取消进行中的请求（回复 ContentModified）
    _ = try h.request("zig-analyzer/waitIdle", {});
    const symbols = try h.request("textDocument/documentSymbol", .{ .textDocument = .{ .uri = document_uri } });
    try testing.expect(symbols.object.get("result").? == .array);
    const line: u32 = @intCast(std.mem.count(u8, text.items, "\n") - 1);
    const ranges = try h.request("textDocument/selectionRange", .{ .textDocument = .{ .uri = document_uri }, .positions = &[_]struct { line: u32, character: u32 }{.{ .line = line, .character = 510 }} });
    try testing.expect(ranges.object.get("result").? == .array);
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
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

test "error responses keep string request ids" {
    var s: Session = undefined;
    try s.run(frame(
        \\{"jsonrpc":"2.0","id":"before-init","method":"zig-analyzer/status"}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"capabilities":{}}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":"unknown-method","method":"not-a-real-method"}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":"reinit","method":"initialize","params":{"capabilities":{}}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":"bad-params","method":"textDocument/hover","params":{"textDocument":42}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","method":"exit"}
    ));
    defer s.deinit();
    const msgs = try s.messages();
    const expected = [_][]const u8{ "before-init", "init", "unknown-method", "reinit", "bad-params" };
    try testing.expectEqual(expected.len, msgs.len);
    for (expected, msgs) |id, msg| try testing.expectEqualStrings(id, msg.object.get("id").?.string);
    try testing.expectEqual(-32602, errorCode(msgs[4]));
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
    // 线程池没有空位：`async` 会在调用方同步执行，zig env 因此可能失败，失败时的警告不写到 stderr
    const prev_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = prev_level;
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

test "shutdown does not deadlock with waitIdle while a configuration request is unanswered" {
    const Harness = @import("test_harness.zig").Harness;
    const Empty = struct {};
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try h.request("initialize", .{ .capabilities = .{ .workspace = .{ .configuration = true } } });
    h.hold_requests = true;
    try h.notify("initialized", Empty{});
    // 等到配置请求发出，暂不回复
    var config_id: ?std.json.Value = null;
    while (config_id == null) {
        const msg = try h.next();
        const method = msg.object.get("method") orelse continue;
        if (std.mem.eql(u8, method.string, "workspace/configuration")) config_id = msg.object.get("id").?;
    }
    const wait = try h.send("zig-analyzer/waitIdle", {});
    _ = try h.request("shutdown", {});
    _ = try h.response(wait);
    h.hold_requests = false;
    // 关闭后补发的配置响应被忽略
    try h.write(.{ .jsonrpc = "2.0", .id = config_id.?, .result = &[_]std.json.Value{.null} });
    try h.notify("exit", {});
}

test "input closing while a configuration request is unanswered ends the main loop" {
    // 客户端没有回复配置请求就退出时，主循环一直等待这个回复，进程不退出
    const Harness = @import("test_harness.zig").Harness;
    const Empty = struct {};
    var h: Harness = undefined;
    try h.start();
    _ = try h.request("initialize", .{ .capabilities = .{ .workspace = .{ .configuration = true } } });
    h.hold_requests = true;
    try h.notify("initialized", Empty{});
    while (true) {
        const msg = try h.next();
        const method = msg.object.get("method") orelse continue;
        if (std.mem.eql(u8, method.string, "workspace/configuration")) break;
    }
    h.input.close();
    // 主循环返回后输出随之关闭；仍在等待时这里超时出错（不调用 finish，免得等待卡住的线程）
    while (true) _ = h.next() catch |err| switch (err) {
        error.EndOfStream => break,
        else => return err,
    };
    h.finish();
    try testing.expectEqual(1, h.exit_code);
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

test "inlay hint settings apply to requests and refresh the client when they change" {
    const Harness = @import("test_harness.zig").Harness;
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try h.request("initialize", .{
        .capabilities = .{ .workspace = .{ .inlayHint = .{ .refreshSupport = true } } },
        .initializationOptions = .{ .inlay_hints = .{ .types = false, .exclude_single_argument = false } },
    });
    const uri = "untitled:inlay-hints.zig";
    const text =
        \\const P = struct { x: u32 };
        \\fn one(n: u32) u32 {
        \\    return n;
        \\}
        \\fn f() void {
        \\    const p: P = .{ .x = one(1) };
        \\    _ = p;
        \\}
        \\
    ;
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const labels = struct {
        fn of(hh: *Harness) ![]const u8 {
            const resp = try hh.request("textDocument/inlayHint", .{
                .textDocument = .{ .uri = "untitled:inlay-hints.zig" },
                .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 8, .character = 0 } },
            });
            var out: std.ArrayList([]const u8) = .empty;
            for (resp.object.get("result").?.array.items) |hint| try out.append(hh.arena.allocator(), hint.object.get("label").?.string);
            return std.mem.join(hh.arena.allocator(), " ", out.items);
        }
    }.of;
    const refreshes = struct {
        fn count(hh: *Harness) usize {
            var n: usize = 0;
            for (hh.received.items) |message| if (message.object.get("method")) |method| {
                if (std.mem.eql(u8, method.string, "workspace/inlayHint/refresh")) n += 1;
            };
            return n;
        }
    }.count;
    try testing.expectEqualStrings(": u32 n:", try labels(&h));

    const before = refreshes(&h);
    // 只改 field_types：推送的配置替换整份配置，其余项与初始化时相同
    try h.notify("workspace/didChangeConfiguration", .{ .settings = .{ .@"zig-analyzer" = .{ .inlay_hints = .{ .types = false, .field_types = false, .exclude_single_argument = false } } } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expect(refreshes(&h) > before);
    try testing.expectEqualStrings("n:", try labels(&h));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "cache settings from initialization and later configuration limit the retained syntax trees" {
    // 防止只在推送配置时设置缓存容量，初始化时的配置不生效
    const Harness = @import("test_harness.zig").Harness;
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try h.request("initialize", .{ .capabilities = struct {}{}, .initializationOptions = .{ .cache = .{ .capacity = 2 } } });
    const uris = [_][]const u8{ "untitled:a.zig", "untitled:b.zig", "untitled:c.zig", "untitled:d.zig" };
    for (uris) |uri| try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = "const x: u32 = 1;\n" } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const trees = struct {
        /// 逐个请求各文件的 document symbol（读取解析结果），之后保留着的解析结果个数
        fn retained(hh: *Harness) !i64 {
            for (uris) |uri| _ = try hh.request("textDocument/documentSymbol", .{ .textDocument = .{ .uri = uri } });
            const status = try hh.request("zig-analyzer/status", {});
            for (status.object.get("result").?.object.get("queries").?.array.items) |q| {
                if (std.mem.endsWith(u8, q.object.get("name").?.string, ".ParseFile")) return q.object.get("memos").?.integer;
            }
            return error.TestUnexpectedResult;
        }
    }.retained;
    try testing.expect(try trees(&h) <= 2);
    try h.notify("workspace/didChangeConfiguration", .{ .settings = .{ .cache = .{ .capacity = 0 } } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(@as(i64, uris.len), try trees(&h));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "organize imports is offered with the cursor in an import block or when requested, and follows the imports settings" {
    const Harness = @import("test_harness.zig").Harness;
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try h.request("initialize", .{
        .capabilities = struct {}{},
        .initializationOptions = .{ .imports = .{ .derived = "separate" } },
    });
    const uri = "untitled:organize-imports.zig";
    const text =
        \\const zed = @import("zed.zig");
        \\const Allocator = std.mem.Allocator;
        \\const std = @import("std");
        \\
        \\pub fn main() void {}
        \\
    ;
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const Pos = struct { line: u32, character: u32 };
    const actions = struct {
        fn at(hh: *Harness, line: u32, only: ?[]const []const u8) ![]const std.json.Value {
            const pos: Pos = .{ .line = line, .character = 0 };
            const resp = try hh.request("textDocument/codeAction", .{
                .textDocument = .{ .uri = "untitled:organize-imports.zig" },
                .range = .{ .start = pos, .end = pos },
                .context = .{ .diagnostics = &[_]std.json.Value{}, .only = only },
            });
            var out: std.ArrayList(std.json.Value) = .empty;
            for (resp.object.get("result").?.array.items) |a| {
                if (std.mem.eql(u8, a.object.get("kind").?.string, "source.organizeImports")) try out.append(hh.arena.allocator(), a);
            }
            return out.items;
        }
    }.at;
    // 菜单（没有指定种类）：光标在 import 块中才提供
    try testing.expectEqual(1, (try actions(&h, 1, null)).len);
    try testing.expectEqual(0, (try actions(&h, 4, null)).len);
    try testing.expectEqual(0, (try actions(&h, 1, &.{"quickfix"})).len);
    // 明确要求（快捷键、保存时整理）：不看光标位置；`source` 包含 `source.organizeImports`
    const requested = try actions(&h, 4, &.{"source"});
    try testing.expectEqual(1, requested.len);
    const edits = requested[0].object.get("edit").?.object.get("changes").?.object.get(uri).?.array.items;
    try testing.expectEqual(1, edits.len);
    try testing.expectEqualStrings(
        \\const std = @import("std");
        \\
        \\const zed = @import("zed.zig");
        \\
        \\const Allocator = std.mem.Allocator;
    , edits[0].object.get("newText").?.string);
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "workspace symbol returns at most workspace_symbol.limit best matches, all of them with 0" {
    const Harness = @import("test_harness.zig").Harness;
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try h.request("initialize", .{
        .capabilities = struct {}{},
        .initializationOptions = .{ .workspace_symbol = .{ .limit = 2 } },
    });
    const text =
        \\const another_alpha = 3;
        \\const alphabet = 2;
        \\const alpha = 1;
        \\const zeta = 4;
        \\
    ;
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = "untitled:symbols.zig", .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const names = struct {
        fn of(hh: *Harness) ![]const u8 {
            const resp = try hh.request("workspace/symbol", .{ .query = "alpha" });
            var out: std.ArrayList([]const u8) = .empty;
            for (resp.object.get("result").?.array.items) |s| try out.append(hh.arena.allocator(), s.object.get("name").?.string);
            return std.mem.join(hh.arena.allocator(), " ", out.items);
        }
    }.of;
    // 保留匹配最好的：完全相同、前缀，然后是子序列
    try testing.expectEqualStrings("alpha alphabet", try names(&h));
    try h.notify("workspace/didChangeConfiguration", .{ .settings = .{ .@"zig-analyzer" = .{ .workspace_symbol = .{ .limit = 0 } } } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("alpha alphabet another_alpha", try names(&h));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}
