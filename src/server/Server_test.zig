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

    /// Parses all responses in the server's output in order (excluding notifications the server
    /// sends on its own)
    fn messages(s: *Session) ![]std.json.Value {
        return s.collect(.responses);
    }

    /// Notifications the server sends on its own (such as publishDiagnostics)
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
    // zig points to a nonexistent path: the background startup (zig env, loading std) fails
    // deterministically and does not race with the file count and revision in status.
    // The warnings on failure are expected and are not written to stderr
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

    // The incremental change has been applied
    const id = (try s.server.vfs.lookup(try za.base.uri.toPath(s.arena.allocator(), file_uri))).?;
    var ctx = s.server.db.beginRead(testing.allocator);
    defer ctx.end();
    try testing.expectEqualStrings("const a = 42;\n", (try ctx.get(FileText, id)).?);

    // Valid code: the last pushed diagnostics are empty
    const notes = try s.notifications();
    try testing.expect(notes.len >= 1);
    const last = notes[notes.len - 1].object;
    try testing.expectEqualStrings("textDocument/publishDiagnostics", last.get("method").?.string);
    try testing.expectEqual(0, last.get("params").?.object.get("diagnostics").?.array.items.len);
}

test "duplicate initialized is ignored, including after shutdown" {
    var s: Session = undefined;
    // Uses the real zig to query the environment: a duplicate initialized should not start
    // loading again
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
    // Live diagnostics on open (shutdown waits for publishing to finish)
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
    // Cleared after close: the publish on open may run concurrently with the publish on close, so
    // only the last result is asserted
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
        // The publishes on open and close may be merged; if there are any, the last one must be
        // an empty list
        if (notes.len != 0) {
            const last = notes[notes.len - 1].object.get("params").?.object;
            try testing.expectEqual(0, last.get("diagnostics").?.array.items.len);
        }
    }
}

test "close: non-file documents clear diagnostics on the client URI" {
    const untitled = "untitled:Untitled-1";
    // On open, diagnostics are published for the client URI
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
    // After close, an empty list is sent for the client URI, not for the internal virtual path
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
        // The publishes on open and close may be merged; if there are any, the last one must be
        // an empty list
        if (notes.len != 0) {
            const params = notes[notes.len - 1].object.get("params").?.object;
            try testing.expectEqual(0, params.get("diagnostics").?.array.items.len);
        }
    }
}

test "syntax features end to end" {
    var s: Session = undefined;
    try s.run(frame(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"textDocument":{"documentSymbol":{"hierarchicalDocumentSymbolSupport":true}}}}}
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

    // A standalone file without a workspace that belongs to no project
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
    // zig cannot be found under `zig build test`: startup warnings are not written to stderr
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
        // The temporary directory is in this repository's .zig-cache: the search for the owning
        // project does not go past it
        .{ &.{"scratch.zig"}, "detached" },
        // Only Build.zig (like `std/Build.zig` in the standard library): on a case-insensitive
        // file system, accessing build.zig by path succeeds as well; this guards against treating
        // such a directory as a project
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
    // Anonymous structs nested 150 levels deep, and 500 levels of parentheses
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
    // Wait for startup to finish: the write transaction that updates the module graph after the
    // zig environment query cancels in-flight requests (answered with ContentModified)
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
    // Exits without having received shutdown
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

test "unknown methods and messages that are not requests get the error code of their case" {
    // Unknown methods got MethodNotFound before initialize and after shutdown, and valid JSON
    // that is not a request got ParseError
    var s: Session = undefined;
    try s.run(frame(
        \\{"jsonrpc":"2.0","id":1,"method":"foo/bar","params":{}}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":2,"method":"$/foo"}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"capabilities":{}}}
    ) ++ frame(
        \\[]
    ) ++ frame(
        \\{"jsonrpc":"2.0","method":1,"params":"bar"}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":true,"method":"zig-analyzer/status"}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":4,"method":"foo/bar"}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":5,"method":"$/foo"}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":6,"method":"shutdown"}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":7,"method":"foo/bar"}
    ) ++ frame(
        \\{"jsonrpc":"2.0","id":8,"method":"$/foo"}
    ) ++ frame(
        \\{"jsonrpc":"2.0","method":"exit"}
    ));
    defer s.deinit();
    try testing.expectEqual(0, s.exit_code);
    const msgs = try s.messages();
    try testing.expectEqual(11, msgs.len);
    try testing.expectEqual(-32002, errorCode(msgs[0]));
    try testing.expectEqual(-32601, errorCode(msgs[1]));
    try testing.expect(msgs[2].object.get("result").? == .object);
    for (msgs[3..6]) |msg| {
        try testing.expectEqual(-32600, errorCode(msg));
        try testing.expect(msg.object.get("id").? == .null);
    }
    try testing.expectEqual(-32601, errorCode(msgs[6]));
    try testing.expectEqual(-32601, errorCode(msgs[7]));
    try testing.expect(msgs[8].object.get("result").? == .null);
    try testing.expectEqual(-32600, errorCode(msgs[9]));
    try testing.expectEqual(-32601, errorCode(msgs[10]));
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

test "requests at the largest position coordinates are answered" {
    // The panic context of a read request converted a coordinate of 2^32 - 1 to 1-based in
    // `u32`, overflowing and aborting the server
    const Harness = @import("test_harness.zig").Harness;
    const prev_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = prev_level;
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const Empty = struct {};
    _ = try h.request("initialize", .{ .capabilities = Empty{}, .initializationOptions = .{ .zig = .{ .path = "/nonexistent/zig" } } });
    try h.notify("initialized", Empty{});
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = file_uri, .languageId = "zig", .version = 1, .text = "pub const a: u32 = 1;\n" } });
    _ = try h.request("zig-analyzer/waitIdle", {});

    const max = std.math.maxInt(u32);
    const Position = struct { line: u32, character: u32 };
    const doc = .{ .uri = file_uri };
    const corners = [_]Position{ .{ .line = max, .character = 0 }, .{ .line = 0, .character = max }, .{ .line = max, .character = max } };
    for (corners) |p| {
        const hover = try h.request("textDocument/hover", .{ .textDocument = doc, .position = p });
        try testing.expect(hover.object.get("result") != null);
        const range = .{ .start = p, .end = Position{ .line = max, .character = max } };
        const hints = try h.request("textDocument/inlayHint", .{ .textDocument = doc, .range = range });
        try testing.expect(hints.object.get("result") != null);
        const tokens = try h.request("textDocument/semanticTokens/range", .{ .textDocument = doc, .range = range });
        try testing.expect(tokens.object.get("result") != null);
        const actions = try h.request("textDocument/codeAction", .{ .textDocument = doc, .range = range, .context = .{ .diagnostics = &[_]Empty{} } });
        try testing.expect(actions.object.get("result") != null);
    }
    // The server is still running
    const hover = try h.request("textDocument/hover", .{ .textDocument = doc, .position = Position{ .line = 0, .character = 10 } });
    try testing.expect(hover.object.get("result").? == .object);
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "read requests run on their own threads: a blocked read does not stall the main loop" {
    const Harness = @import("test_harness.zig").Harness;
    // No free slot in the thread pool: `async` runs synchronously on the caller, so zig env may
    // fail; the warnings on failure are not written to stderr
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

    // Hold the write lock: the read request waits at the start of its read transaction
    h.server.db.beginWrite();
    var writing = true;
    defer if (writing) h.server.db.endWrite();
    const blocked = try h.send("zig-analyzer/status", {});
    try h.notify("$/cancelRequest", .{ .id = blocked });
    // The main loop is still processing messages
    try testing.expectEqual(-32601, errorCode(try h.request("zig-analyzer/probe", {})));

    h.server.db.endWrite();
    writing = false;
    // The cancellation arrives while the read request is blocked
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
    // Wait until the configuration request is sent, and do not answer it yet
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
    // A configuration response sent belatedly after shutdown is ignored
    try h.write(.{ .jsonrpc = "2.0", .id = config_id.?, .result = &[_]std.json.Value{.null} });
    try h.notify("exit", {});
}

test "input closing while a configuration request is unanswered ends the main loop" {
    // When the client exits without answering the configuration request, the main loop keeps
    // waiting for that answer and the process does not exit
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
    // Once the main loop returns, the output is closed with it; if it is still waiting, this
    // times out with an error (finish is not called, to avoid waiting on a stuck thread)
    while (true) _ = h.next() catch |err| switch (err) {
        error.EndOfStream => break,
        else => return err,
    };
    h.finish();
    try testing.expectEqual(1, h.exit_code);
}

test "exit without shutdown ends the main loop while a configuration request or waitIdle is unanswered" {
    // Guards against the process waiting forever for the client's reply after `exit` (or the end
    // of input with a `waitIdle` request in flight)
    const Harness = @import("test_harness.zig").Harness;
    const Empty = struct {};
    for ([_]enum { exit, wait_then_eof, wait_then_exit }{ .exit, .wait_then_eof, .wait_then_exit }) |ending| {
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
        switch (ending) {
            .exit => try h.notify("exit", {}),
            .wait_then_eof => {
                _ = try h.send("zig-analyzer/waitIdle", {});
                h.input.close();
            },
            .wait_then_exit => {
                _ = try h.send("zig-analyzer/waitIdle", {});
                try h.notify("exit", {});
            },
        }
        // Once the main loop returns, the output is closed with it; if it is still waiting, this
        // times out with an error (finish is not called, to avoid waiting on a stuck thread)
        while (true) _ = h.next() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        h.finish();
        try testing.expectEqual(1, h.exit_code);
    }
}

test "configuration replies with a null error or an incomplete error object still start the projects" {
    // Such replies were rejected as unparsable messages, so the startup waiting for the
    // configuration never began
    const Harness = @import("test_harness.zig").Harness;
    const Empty = struct {};
    const prev_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = prev_level;
    const replies = [_][]const u8{
        \\{"jsonrpc":"2.0","id":"zig-analyzer/configuration/0","result":[null],"error":null}
        ,
        \\{"jsonrpc":"2.0","id":"zig-analyzer/configuration/0","error":{"code":-32603}}
        ,
    };
    for (replies) |reply| {
        var h: Harness = undefined;
        try h.start();
        defer h.finish();
        _ = try h.request("initialize", .{
            .capabilities = .{ .workspace = .{ .configuration = true } },
            .initializationOptions = .{ .zig = .{ .path = "/nonexistent/zig" } },
        });
        h.hold_requests = true;
        try h.notify("initialized", Empty{});
        while (true) {
            const msg = try h.next();
            const method = msg.object.get("method") orelse continue;
            if (std.mem.eql(u8, method.string, "workspace/configuration")) break;
        }
        h.hold_requests = false;
        try h.writeBody(reply);
        // The main loop handles the reply before this request
        _ = try h.request("zig-analyzer/status", {});
        try testing.expect(h.server.started);
        for (h.received.items) |msg| try testing.expect(msg.object.get("error") == null);
        _ = try h.request("zig-analyzer/waitIdle", {});
        _ = try h.request("shutdown", {});
        try h.notify("exit", {});
    }
}

test "live diagnostics are debounced per file and AstGen runs outside the read transaction" {
    const Harness = @import("test_harness.zig").Harness;
    const Empty = struct {};
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    // The debounce is long so that consecutive edits always fall within the same window
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
    // Five edits publish only once, for the final text
    try testing.expectEqual(before + 1, published.len);
    const diags = published[published.len - 1].object.get("params").?.object.get("diagnostics").?.array.items;
    try testing.expectEqual(1, diags.len);
    try testing.expectEqualStrings("expected expression, found ';'", diags[0].object.get("message").?.string);
    // AstCheck used the results computed outside the read transaction
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
    // The reclaim waits until the task of the hover request has ended its read transaction
    while (!h.server.resetSema()) std.Thread.yield() catch {};
    try testing.expect(h.server.ip.count() < items);
    const after = try h.request("textDocument/hover", at);
    try testing.expectEqualStrings(contents, after.object.get("result").?.object.get("contents").?.object.get("value").?.string);

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

/// Whether the read or semantic request with this id is in flight (its task has not finished)
fn inFlight(server: *Server, id: i64) bool {
    server.pending_mutex.lockUncancelable(testing.io);
    defer server.pending_mutex.unlock(testing.io);
    for (server.pending.items) |p| if (p.id == .integer and p.id.integer == id) return true;
    return false;
}

test "reclaiming type information does not cancel in-flight requests and runs once they finish" {
    // Guards against the reclaim at the end of one request canceling the other requests in flight
    // (answered with ContentModified), which also starved requests whose own inference exceeded
    // the limit
    const Harness = @import("test_harness.zig").Harness;
    const Empty = struct {};
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try h.request("initialize", .{ .capabilities = Empty{}, .initializationOptions = .{ .sema = .{ .max_intern_pool_mb = 1 } } });
    try h.notify("initialized", Empty{});
    const uri = "untitled:Untitled-3";
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
    const doc = .{ .textDocument = .{ .uri = uri } };
    const expected = (try h.request("textDocument/semanticTokens/full", doc)).object.get("result").?.object.get("data").?.array.items;

    var gate: Server.TestGate = .{ .method = "textDocument/semanticTokens/full", .point = .in_read };
    h.server.test_gate = &gate;
    defer h.server.test_gate = null;
    defer gate.release.set(testing.io);
    const held = try h.send("textDocument/semanticTokens/full", doc);
    try gate.entered.wait(testing.io);
    // Push the InternPool over the limit while the request holds its read transaction
    var bits: u16 = 1;
    while (h.server.ip.bytes() < 2 * 1024 * 1024) : (bits += 1) _ = try h.server.ip.intType(.unsigned, bits);
    const items = h.server.ip.count();
    // Another request finishes in the meantime and checks whether to reclaim
    const other = try h.send("textDocument/documentSymbol", doc);
    _ = try h.response(other);
    while (inFlight(&h.server, other) and h.server.db.pending_write.load(.acquire) == 0) std.Thread.yield() catch {};
    try testing.expectEqual(0, h.server.db.pending_write.load(.acquire));

    gate.release.set(testing.io);
    const tokens = try h.response(held);
    try testing.expect(tokens.object.get("error") == null);
    try testing.expectEqualDeep(expected, tokens.object.get("result").?.object.get("data").?.array.items);
    // No read transaction is left once the held request finishes: it reclaims
    while (inFlight(&h.server, held)) std.Thread.yield() catch {};
    try testing.expect(h.server.ip.count() < items);

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "a request whose task starts after a later edit is not answered on the edited text" {
    // Guards against a request sent before a didChange being answered on the text after the
    // change, when its task starts reading only after the main loop has applied the change
    const Harness = @import("test_harness.zig").Harness;
    const Empty = struct {};
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try h.request("initialize", .{ .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = "untitled:Untitled-4";
    const text =
        \\const alpha_value: u32 = 1;
        \\pub fn main() void {
        \\    _ = alpha_value;
        \\}
        \\
    ;
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});

    var gate: Server.TestGate = .{ .method = "textDocument/hover", .point = .before_read };
    h.server.test_gate = &gate;
    defer h.server.test_gate = null;
    defer gate.release.set(testing.io);
    const hover = try h.send("textDocument/hover", .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 0, .character = 6 } });
    try gate.entered.wait(testing.io);
    const insert = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = 2 }, .contentChanges = &.{.{ .range = insert, .text = "const beta_flag: bool = true;\n" }} });
    // The main loop has applied the change once it answers a later request
    try testing.expectEqual(-32601, errorCode(try h.request("zig-analyzer/probe", {})));
    gate.release.set(testing.io);

    // Either the answer on the text the request was sent for, or ContentModified
    const response = try h.response(hover);
    if (response.object.get("error")) |e| {
        try testing.expectEqual(-32801, e.object.get("code").?.integer);
    } else {
        const contents = response.object.get("result").?.object.get("contents").?.object.get("value").?.string;
        try testing.expect(std.mem.indexOf(u8, contents, "alpha_value") != null);
    }

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "exit and the end of input cancel the requests in flight instead of waiting for them" {
    // Guards against the process outliving `exit` (or the end of its input) until the requests in
    // flight have computed their results, which nobody reads anymore
    const Harness = @import("test_harness.zig").Harness;
    const Empty = struct {};
    for ([_]enum { exit, end_of_input }{ .exit, .end_of_input }) |ending| {
        var h: Harness = undefined;
        try h.start();
        defer h.finish();
        _ = try h.request("initialize", .{ .capabilities = Empty{} });
        try h.notify("initialized", Empty{});
        const uri = "untitled:Untitled-5";
        try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = "const a: u32 = 1;\n" } });
        _ = try h.request("zig-analyzer/waitIdle", {});

        // The request stays at the gate until it is canceled
        var gate: Server.TestGate = .{ .method = "textDocument/semanticTokens/full", .point = .in_read };
        h.server.test_gate = &gate;
        defer h.server.test_gate = null;
        defer gate.release.set(testing.io);
        const held = try h.send("textDocument/semanticTokens/full", .{ .textDocument = .{ .uri = uri } });
        try gate.entered.wait(testing.io);
        switch (ending) {
            .exit => try h.notify("exit", {}),
            .end_of_input => h.input.close(),
        }
        // The main loop returns, and the output is closed with it
        while (true) _ = h.next() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try testing.expectEqual(-32800, errorCode(try h.response(held)));
        try testing.expectEqual(1, h.exit_code);
    }
}

test "a module graph update does not cancel the outline, folding and selection requests in flight" {
    // Guards against server writes that change no text (the module graph after the zig
    // environment query or a build) answering the syntax requests in flight with ContentModified,
    // although their results cannot change
    const Harness = @import("test_harness.zig").Harness;
    const Empty = struct {};
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    _ = try h.request("initialize", .{ .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = "untitled:Untitled-6";
    const text =
        \\const S = struct {
        \\    a: u32,
        \\    fn f(s: S) u32 {
        \\        return s.a;
        \\    }
        \\};
        \\
    ;
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});

    const doc = .{ .textDocument = .{ .uri = uri } };
    const positions = .{ .textDocument = .{ .uri = uri }, .positions = &[_]struct { line: u32, character: u32 }{.{ .line = 3, .character = 17 }} };
    inline for (.{ .{ "textDocument/documentSymbol", doc }, .{ "textDocument/foldingRange", doc }, .{ "textDocument/selectionRange", positions } }, 0..) |r, i| {
        const expected = try std.json.Stringify.valueAlloc(a, (try h.request(r[0], r[1])).object.get("result").?, .{});

        var gate: Server.TestGate = .{ .method = r[0], .point = .in_read };
        h.server.test_gate = &gate;
        defer h.server.test_gate = null;
        defer gate.release.set(testing.io);
        const held = try h.send(r[0], r[1]);
        try gate.entered.wait(testing.io);
        // Another default builtin.zig changes the module graph, as a zig environment query does
        {
            h.server.env_mutex.lockUncancelable(testing.io);
            defer h.server.env_mutex.unlock(testing.io);
            if (h.server.default_builtin) |p| testing.allocator.free(p);
            h.server.default_builtin = try std.fmt.allocPrint(testing.allocator, "/zig-analyzer-test/builtin-{d}.zig", .{i});
        }
        const update = try std.Thread.spawn(.{}, Server.updateModuleGraph, .{&h.server});
        defer update.join();
        // The update waits for the held request
        while (h.server.db.pending_write.load(.acquire) == 0) std.Thread.yield() catch {};
        gate.release.set(testing.io);
        const response = try h.response(held);
        try testing.expect(response.object.get("error") == null);
        try testing.expectEqualStrings(expected, try std.json.Stringify.valueAlloc(a, response.object.get("result").?, .{}));
    }

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "function completions carry no signature in the list and resolve to the signature and doc" {
    const Harness = @import("test_harness.zig").Harness;
    const Empty = struct {};
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try h.request("initialize", .{ .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = "untitled:Untitled-3";
    const text =
        \\/// Adds two numbers.
        \\fn add(a: u32, b: u32) u32 {
        \\    return a + b;
        \\}
        \\pub fn main() void {
        \\    _ = ad;
        \\}
        \\
    ;
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const resp = try h.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 5, .character = 10 } });
    const result = resp.object.get("result").?;
    const items = if (result == .array) result.array.items else result.object.get("items").?.array.items;
    const item = for (items) |it| {
        if (std.mem.eql(u8, it.object.get("label").?.string, "add")) break it;
    } else return error.MissingCompletion;
    try testing.expect(item.object.get("detail") == null);
    try testing.expect(item.object.get("labelDetails") == null);
    try testing.expect(item.object.get("data") != null);
    const resolved = (try h.request("completionItem/resolve", item)).object.get("result").?;
    try testing.expectEqualStrings("fn add(a: u32, b: u32) u32", resolved.object.get("detail").?.string);
    const doc = resolved.object.get("documentation").?.object.get("value").?.string;
    try testing.expect(std.mem.startsWith(u8, doc, "Adds two numbers.\n\nDefined in `"));

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

/// Initializes with `capabilities` and `options`, then completes at `_ = ad|;`: `add` inserts the
/// snippet `snippet`; when null, no completion item is a snippet
fn expectAddCompletion(capabilities: anytype, options: anytype, snippet: ?[]const u8) !void {
    const Harness = @import("test_harness.zig").Harness;
    const Empty = struct {};
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try h.request("initialize", .{ .capabilities = capabilities, .initializationOptions = options });
    try h.notify("initialized", Empty{});
    const uri = "untitled:snippets.zig";
    const text =
        \\fn add(a: u32, b: u32) u32 {
        \\    return a + b;
        \\}
        \\pub fn main() void {
        \\    _ = ad;
        \\}
        \\
    ;
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const resp = try h.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 4, .character = 10 } });
    const result = resp.object.get("result").?;
    const items = if (result == .array) result.array.items else result.object.get("items").?.array.items;
    const item = for (items) |it| {
        if (std.mem.eql(u8, it.object.get("label").?.string, "add")) break it;
    } else return error.MissingCompletion;
    if (snippet) |expected| {
        try testing.expectEqual(2, item.object.get("insertTextFormat").?.integer);
        const edit = item.object.get("textEdit").?.object;
        try testing.expectEqualStrings(expected, edit.get("newText").?.string);
        const range = edit.get("range").?.object;
        try testing.expectEqual(8, range.get("start").?.object.get("character").?.integer);
        try testing.expectEqual(10, range.get("end").?.object.get("character").?.integer);
    } else for (items) |it| {
        try testing.expect(it.object.get("insertTextFormat") == null);
        try testing.expect(it.object.get("kind").?.integer != 15);
        if (it.object.get("textEdit")) |edit| {
            try testing.expectEqualStrings(it.object.get("label").?.string, edit.object.get("newText").?.string);
        }
    }

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "function completions insert calls with placeholders only for clients that support snippets" {
    const Empty = struct {};
    const snippet_client = .{ .textDocument = .{ .completion = .{ .completionItem = .{ .snippetSupport = true } } } };
    try expectAddCompletion(snippet_client, Empty{}, "add(${1:a}, ${2:b})");
    try expectAddCompletion(Empty{}, Empty{}, null);
    try expectAddCompletion(.{ .textDocument = .{ .completion = .{ .completionItem = .{ .snippetSupport = false } } } }, Empty{}, null);
    try expectAddCompletion(snippet_client, .{ .completion = .{ .snippets = false } }, null);
    try expectAddCompletion(snippet_client, .{ .completion = .{ .argument_placeholders = false } }, "add($1)");
}

/// Character columns of the ranges of a completion edit in one line: the insert range (null for a
/// plain text edit) and the replaced range
const EditRanges = struct { insert: ?[2]i64, replace: [2]i64 };

/// The edit ranges of the completion item `label` at `line:character`
fn completionEditRanges(capabilities: anytype, line: u32, character: u32, label: []const u8) !EditRanges {
    const Harness = @import("test_harness.zig").Harness;
    const Empty = struct {};
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try h.request("initialize", .{ .capabilities = capabilities });
    try h.notify("initialized", Empty{});
    const uri = "untitled:ranges.zig";
    const text =
        \\const s = @import("std");
        \\fn f(c: bool) u32 {
        \\    _ = c;
        \\    ifreturn 1;
        \\}
        \\
    ;
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const resp = try h.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = .{ .line = line, .character = character } });
    const result = resp.object.get("result").?;
    const items = if (result == .array) result.array.items else result.object.get("items").?.array.items;
    const item = for (items) |it| {
        if (std.mem.eql(u8, it.object.get("label").?.string, label)) break it;
    } else return error.MissingCompletion;
    const edit = item.object.get("textEdit").?.object;
    const columns = struct {
        fn of(range: std.json.Value) [2]i64 {
            const start = range.object.get("start").?.object;
            const end = range.object.get("end").?.object;
            std.debug.assert(start.get("line").?.integer == end.get("line").?.integer);
            return .{ start.get("character").?.integer, end.get("character").?.integer };
        }
    }.of;
    const out: EditRanges = if (edit.get("range")) |range|
        .{ .insert = null, .replace = columns(range) }
    else
        .{ .insert = columns(edit.get("insert").?), .replace = columns(edit.get("replace").?) };

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
    return out;
}

test "completion edits carry insert and replace ranges for clients that support both" {
    const both = .{ .textDocument = .{ .completion = .{ .completionItem = .{ .snippetSupport = true, .insertReplaceSupport = true } } } };
    const replace_only = .{ .textDocument = .{ .completion = .{ .completionItem = .{ .snippetSupport = true } } } };
    // A snippet at `if|return 1;` inserts up to the cursor and replaces the whole word; a path at
    // `"st|d"` inserts up to the cursor and replaces the rest of the string
    try testing.expectEqualDeep(EditRanges{ .insert = .{ 4, 6 }, .replace = .{ 4, 12 } }, try completionEditRanges(both, 3, 6, "if"));
    try testing.expectEqualDeep(EditRanges{ .insert = .{ 19, 21 }, .replace = .{ 19, 22 } }, try completionEditRanges(both, 0, 21, "std"));
    // Without the capability, every item replaces the whole word or path
    try testing.expectEqualDeep(EditRanges{ .insert = null, .replace = .{ 4, 12 } }, try completionEditRanges(replace_only, 3, 6, "if"));
    try testing.expectEqualDeep(EditRanges{ .insert = null, .replace = .{ 19, 22 } }, try completionEditRanges(replace_only, 0, 21, "std"));
}

test "completion triggered by `/` or `\"` lists only paths" {
    const Harness = @import("test_harness.zig").Harness;
    const Empty = struct {};
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try h.request("initialize", .{ .capabilities = .{ .textDocument = .{ .completion = .{ .contextSupport = true } } } });
    try h.notify("initialized", Empty{});
    const uri = "untitled:triggers.zig";
    const text =
        \\const std = @import("std");
        \\pub fn main() void {
        \\    const a: u32 = 4;
        \\    const b = a /
        \\    / a;
        \\    const t = "abc";
        \\    const q = @import("std");
        \\    _ = .{ b, t, q };
        \\}
        \\
    ;
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const cases = [_]struct { u32, u32, u32, []const u8, []const u8 }{
        // A division, a `/` at the start of a line, a closing quote of a string and of an import
        .{ 3, 17, 2, "/", "" },
        .{ 4, 5, 2, "/", "" },
        .{ 5, 19, 2, "\"", "" },
        .{ 6, 27, 2, "\"", "" },
        // The opening quote of an import lists its paths; invoked completion lists names
        .{ 6, 23, 2, "\"", "std builtin root" },
        .{ 3, 17, 1, "", "a std main" },
    };
    for (cases) |c| {
        const resp = if (c[2] == 2)
            try h.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = .{ .line = c[0], .character = c[1] }, .context = .{ .triggerKind = c[2], .triggerCharacter = c[3] } })
        else
            try h.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = .{ .line = c[0], .character = c[1] }, .context = .{ .triggerKind = c[2] } });
        const result = resp.object.get("result").?;
        const items = if (result == .array) result.array.items else result.object.get("items").?.array.items;
        var labels: std.ArrayList([]const u8) = .empty;
        defer labels.deinit(testing.allocator);
        for (items) |it| try labels.append(testing.allocator, it.object.get("label").?.string);
        const got = try std.mem.join(testing.allocator, " ", labels.items);
        defer testing.allocator.free(got);
        testing.expectEqualStrings(c[4], got) catch |err| {
            std.debug.print("at {d}:{d}\n", .{ c[0], c[1] });
            return err;
        };
    }

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
    // Only field_types changes: the pushed configuration replaces the whole configuration, and
    // the other settings are the same as at initialization
    try h.notify("workspace/didChangeConfiguration", .{ .settings = .{ .@"zig-analyzer" = .{ .inlay_hints = .{ .types = false, .field_types = false, .exclude_single_argument = false } } } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expect(refreshes(&h) > before);
    try testing.expectEqualStrings("n:", try labels(&h));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "refresh requests carry no params and at most one of each awaits the client" {
    // Refresh requests were sent with `"params": null`, which JSON-RPC does not allow
    const Harness = @import("test_harness.zig").Harness;
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try h.request("initialize", .{ .capabilities = .{ .workspace = .{
        .inlayHint = .{ .refreshSupport = true },
        .semanticTokens = .{ .refreshSupport = true },
    } } });
    // The client never answers the refreshes
    h.hold_requests = true;
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = "untitled:refresh.zig", .languageId = "zig", .version = 1, .text = "pub fn f(x: u32) u32 {\n    const y = x + 1;\n    return y;\n}\n" } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    for ([_]bool{ false, true }) |on| {
        try h.notify("workspace/didChangeConfiguration", .{ .settings = .{ .@"zig-analyzer" = .{
            .inlay_hints = .{ .types = on },
            .semantic_tokens = .{ .mode = if (on) "full" else "partial" },
        } } });
        _ = try h.request("zig-analyzer/waitIdle", {});
    }
    var inlay: usize = 0;
    var semantic: usize = 0;
    for (h.received.items) |message| if (message.object.get("method")) |method| {
        const is_inlay = std.mem.eql(u8, method.string, "workspace/inlayHint/refresh");
        const is_semantic = std.mem.eql(u8, method.string, "workspace/semanticTokens/refresh");
        if (!is_inlay and !is_semantic) continue;
        try testing.expect(message.object.get("params") == null);
        if (is_inlay) inlay += 1 else semantic += 1;
    };
    try testing.expectEqual(1, inlay);
    try testing.expectEqual(1, semantic);
    h.hold_requests = false;
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "a null configuration section keeps the settings from initialization and earlier pushes" {
    // A null section replaced the configuration with the defaults, discarding
    // `initializationOptions` and settings pushed before the reply
    const Harness = @import("test_harness.zig").Harness;
    const Empty = struct {};
    const text =
        \\fn get() u32 {
        \\    return 1;
        \\}
        \\pub fn main() void {
        \\    const x = get();
        \\    _ = x;
        \\}
        \\
    ;
    for ([_]bool{ false, true }) |push| {
        var h: Harness = undefined;
        try h.start();
        defer h.finish();
        const capabilities = .{ .workspace = .{ .configuration = true } };
        if (push) {
            _ = try h.request("initialize", .{ .capabilities = capabilities });
        } else {
            _ = try h.request("initialize", .{ .capabilities = capabilities, .initializationOptions = .{ .inlay_hints = .{ .types = false } } });
        }
        h.hold_requests = true;
        try h.notify("initialized", Empty{});
        while (true) {
            const msg = try h.next();
            const method = msg.object.get("method") orelse continue;
            if (std.mem.eql(u8, method.string, "workspace/configuration")) break;
        }
        if (push) try h.notify("workspace/didChangeConfiguration", .{ .settings = .{ .@"zig-analyzer" = .{ .inlay_hints = .{ .types = false } } } });
        h.hold_requests = false;
        try h.writeBody(
            \\{"jsonrpc":"2.0","id":"zig-analyzer/configuration/0","result":[null]}
        );
        try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = "untitled:null-section.zig", .languageId = "zig", .version = 1, .text = text } });
        _ = try h.request("zig-analyzer/waitIdle", {});
        const resp = try h.request("textDocument/inlayHint", .{
            .textDocument = .{ .uri = "untitled:null-section.zig" },
            .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 7, .character = 0 } },
        });
        for (resp.object.get("result").?.array.items) |hint| {
            try testing.expect(!std.mem.eql(u8, hint.object.get("label").?.string, ": u32"));
        }
        _ = try h.request("shutdown", {});
        try h.notify("exit", {});
    }
}

test "cache settings from initialization and later configuration limit the retained syntax trees" {
    // Guards against the cache capacity being set only when configuration is pushed, while the
    // configuration at initialization has no effect
    const Harness = @import("test_harness.zig").Harness;
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    _ = try h.request("initialize", .{ .capabilities = struct {}{}, .initializationOptions = .{ .cache = .{ .capacity = 2 } } });
    const uris = [_][]const u8{ "untitled:a.zig", "untitled:b.zig", "untitled:c.zig", "untitled:d.zig" };
    for (uris) |uri| try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = "const x: u32 = 1;\n" } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const trees = struct {
        /// Number of parse results still retained after requesting the document symbols of each
        /// file in turn (which reads the parse results)
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
        .capabilities = .{ .textDocument = .{ .codeAction = .{ .codeActionLiteralSupport = .{ .codeActionKind = .{ .valueSet = &[_][]const u8{ "quickfix", "source.organizeImports" } } } } } },
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
    // Menu (no kind specified): offered only when the cursor is in an import block
    try testing.expectEqual(1, (try actions(&h, 1, null)).len);
    try testing.expectEqual(0, (try actions(&h, 4, null)).len);
    try testing.expectEqual(0, (try actions(&h, 1, &.{"quickfix"})).len);
    // Explicitly requested (a shortcut, organize on save): the cursor position does not matter;
    // `source` includes `source.organizeImports`
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
    // The best matches are kept: exact matches, prefixes, then subsequences
    try testing.expectEqualStrings("alpha alphabet", try names(&h));
    try h.notify("workspace/didChangeConfiguration", .{ .settings = .{ .@"zig-analyzer" = .{ .workspace_symbol = .{ .limit = 0 } } } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("alpha alphabet another_alpha", try names(&h));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "initialize and results follow the capabilities the client declares" {
    // A client without these capabilities must not get option objects, trees, kinds or formats
    // the protocol allows only for clients that declare them
    const Harness = @import("test_harness.zig").Harness;
    const text =
        \\/// Adds `a` and **b**.
        \\fn add(a: u32, b: u32) u32 {
        \\    return a + b;
        \\}
        \\const Point = struct { x: i32 };
        \\pub fn main() void {
        \\    const p: Point = .{ .x = 1 };
        \\    _ = p;
        \\    const unused = 1;
        \\    _ = add(1, 2);
        \\    Poi
        \\}
        \\
    ;
    const uri = "untitled:capabilities.zig";
    const Pos = struct { line: u32, character: u32 };
    const Client = struct {
        h: Harness = undefined,

        fn open(c: *@This(), capabilities: anytype) !std.json.ObjectMap {
            try c.h.start();
            const init = try c.h.request("initialize", .{ .capabilities = capabilities });
            try c.h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
            _ = try c.h.request("zig-analyzer/waitIdle", {});
            return init.object.get("result").?.object.get("capabilities").?.object;
        }

        fn result(c: *@This(), method: []const u8, params: anytype) !std.json.Value {
            return (try c.h.request(method, params)).object.get("result").?;
        }

        fn close(c: *@This()) !void {
            _ = try c.h.request("shutdown", {});
            try c.h.notify("exit", {});
            c.h.finish();
        }

        fn kindOf(items: []const std.json.Value, label_key: []const u8, label: []const u8) !i64 {
            for (items) |it| if (std.mem.eql(u8, it.object.get(label_key).?.string, label)) return it.object.get("kind").?.integer;
            return error.MissingItem;
        }
    };
    const hover_at: Pos = .{ .line = 9, .character = 9 };
    const name_at: Pos = .{ .line = 10, .character = 7 };
    const unused_at: Pos = .{ .line = 8, .character = 10 };

    // Client A declares nothing
    {
        var c: Client = .{};
        const caps = try c.open(struct {}{});
        try testing.expect(caps.get("renameProvider").? == .bool);
        try testing.expect(caps.get("codeActionProvider").? == .bool);
        try testing.expect(try c.result("textDocument/codeAction", .{
            .textDocument = .{ .uri = uri },
            .range = .{ .start = unused_at, .end = unused_at },
            .context = .{ .diagnostics = &[_]std.json.Value{} },
        }) == .null);
        // A flat `SymbolInformation[]` with kinds up to `Array` (18)
        const symbols = (try c.result("textDocument/documentSymbol", .{ .textDocument = .{ .uri = uri } })).array.items;
        for (symbols) |s| {
            try testing.expect(s.object.get("children") == null);
            try testing.expect(s.object.get("location") != null);
            try testing.expect(s.object.get("kind").?.integer <= 18);
        }
        try testing.expectEqual(5, try Client.kindOf(symbols, "name", "Point"));
        for (symbols) |s| if (std.mem.eql(u8, s.object.get("name").?.string, "x")) {
            try testing.expectEqualStrings("Point", s.object.get("containerName").?.string);
        };
        for ((try c.result("workspace/symbol", .{ .query = "Point" })).array.items) |s| try testing.expect(s.object.get("kind").?.integer <= 18);
        // Completion kinds up to `Reference` (18)
        const completion = try c.result("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = name_at });
        const items = switch (completion) {
            .array => |a| a.items,
            else => completion.object.get("items").?.array.items,
        };
        for (items) |it| try testing.expect(it.object.get("kind").?.integer <= 18);
        try testing.expectEqual(7, try Client.kindOf(items, "label", "Point"));
        try c.close();
    }
    // Client B accepts only plain text
    {
        var c: Client = .{};
        const plain = &[_][]const u8{"plaintext"};
        _ = try c.open(.{ .textDocument = .{
            .hover = .{ .contentFormat = plain },
            .signatureHelp = .{ .signatureInformation = .{ .documentationFormat = plain } },
            .completion = .{ .completionItem = .{ .documentationFormat = plain } },
        } });
        const contents = (try c.result("textDocument/hover", .{ .textDocument = .{ .uri = uri }, .position = hover_at })).object.get("contents").?.object;
        try testing.expectEqualStrings("plaintext", contents.get("kind").?.string);
        try testing.expect(std.mem.indexOf(u8, contents.get("value").?.string, "```") == null);
        try testing.expect(std.mem.indexOf(u8, contents.get("value").?.string, "fn add(a: u32, b: u32) u32") != null);
        const sig = (try c.result("textDocument/signatureHelp", .{ .textDocument = .{ .uri = uri }, .position = Pos{ .line = 9, .character = 12 } })).object;
        try testing.expectEqualStrings("plaintext", sig.get("signatures").?.array.items[0].object.get("documentation").?.object.get("kind").?.string);
        try c.close();
    }
    // Client C declares everything
    {
        var c: Client = .{};
        const caps = try c.open(.{ .textDocument = .{
            .rename = .{ .prepareSupport = true },
            .codeAction = .{ .codeActionLiteralSupport = .{ .codeActionKind = .{ .valueSet = &[_][]const u8{"quickfix"} } } },
            .documentSymbol = .{ .hierarchicalDocumentSymbolSupport = true, .symbolKind = .{ .valueSet = &[_]u32{ 5, 23 } } },
            .completion = .{ .completionItemKind = .{ .valueSet = &[_]u32{ 7, 22 } } },
        } });
        try testing.expect(caps.get("renameProvider").?.object.get("prepareProvider").?.bool);
        try testing.expect(caps.get("codeActionProvider").? == .object);
        const symbols = (try c.result("textDocument/documentSymbol", .{ .textDocument = .{ .uri = uri } })).array.items;
        try testing.expectEqual(23, try Client.kindOf(symbols, "name", "Point"));
        const hover = (try c.result("textDocument/hover", .{ .textDocument = .{ .uri = uri }, .position = hover_at })).object.get("contents").?.object;
        try testing.expectEqualStrings("markdown", hover.get("kind").?.string);
        try c.close();
    }
}
