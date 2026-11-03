//! End-to-end: find references, document highlight, rename, workspace symbol and code actions
//! (across modules; unopened files are brought into scope through the module graph).

const std = @import("std");
const testing = std.testing;
const za = @import("../zig_analyzer.zig");
const fixture = za.project.fixture;
const Harness = @import("test_harness.zig").Harness;

const Empty = struct {};
/// Code action literal support, without which no code actions are returned (each carries an edit)
const literal_actions = .{ .codeActionKind = .{ .valueSet = &[_][]const u8{ "quickfix", "refactor", "source" } } };

const main_text =
    \\const std = @import("std");
    \\const lib = @import("lib");
    \\pub fn main() void {
    \\    lib.hello();
    \\    lib.hello();
    \\    _ = std.mem.Allocator;
    \\}
    \\
;
const lib_text =
    \\pub fn hello() void {}
    \\test {
    \\    hello();
    \\}
    \\
;

const project_files = [_]fixture.File{
    .{ .path = "build.zig", .text = fixture.basic[0].text },
    .{ .path = "src/main.zig", .text = main_text },
    .{ .path = "src/lib.zig", .text = lib_text },
};

fn position(text: []const u8, needle: []const u8) struct { line: u32, character: u32 } {
    const offset = std.mem.indexOf(u8, text, needle).?;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..offset], '\n')) |i| i + 1 else 0;
    return .{ .line = @intCast(std.mem.count(u8, text[0..offset], "\n")), .character = @intCast(offset - line_start) };
}

fn basename(u: []const u8) []const u8 {
    return u[std.mem.lastIndexOfScalar(u8, u, '/').? + 1 ..];
}

/// "file:line:column"
fn loc(h: *Harness, u: []const u8, range: std.json.Value) ![]const u8 {
    const start = range.object.get("start").?.object;
    return std.fmt.allocPrint(h.arena.allocator(), "{s}:{d}:{d}", .{ basename(u), start.get("line").?.integer, start.get("character").?.integer });
}

fn join(h: *Harness, list: []const []const u8) ![]const u8 {
    return std.mem.join(h.arena.allocator(), " ", list);
}

test "references, highlight, rename and workspace symbol" {
    var project = try fixture.Project.create(&project_files);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = .{ .textDocument = .{ .codeAction = .{ .codeActionLiteralSupport = literal_actions } } } });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = main_text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const doc = .{ .uri = uri };

    // Background indexing has already computed member summaries for the unopened lib.zig: workspace
    // symbol does not compute them in the request (computing them needs the syntax tree)
    {
        const before = h.server.db.executions(za.syntax.queries.ItemSummaries);
        const resp = try h.request("workspace/symbol", .{ .query = "hello" });
        try testing.expectEqualStrings("hello", resp.object.get("result").?.array.items[0].object.get("name").?.string);
        try testing.expectEqual(before, h.server.db.executions(za.syntax.queries.ItemSummaries));
    }

    // Find references: lib.zig is not open and is included through the module graph
    {
        const resp = try h.request("textDocument/references", .{ .textDocument = doc, .position = position(main_text, "hello"), .context = .{ .includeDeclaration = true } });
        var out: std.ArrayList([]const u8) = .empty;
        for (resp.object.get("result").?.array.items) |l| try out.append(a, try loc(&h, l.object.get("uri").?.string, l.object.get("range").?));
        std.mem.sort([]const u8, out.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        try testing.expectEqualStrings("lib.zig:0:7 lib.zig:2:4 main.zig:3:8 main.zig:4:8", try join(&h, out.items));
    }

    // Document highlight: only in the current file
    {
        const resp = try h.request("textDocument/documentHighlight", .{ .textDocument = doc, .position = position(main_text, "hello") });
        var out: std.ArrayList([]const u8) = .empty;
        for (resp.object.get("result").?.array.items) |x| try out.append(a, try loc(&h, uri, x.object.get("range").?));
        try testing.expectEqualStrings("main.zig:3:8 main.zig:4:8", try join(&h, out.items));
    }

    // Rename
    {
        const prep = try h.request("textDocument/prepareRename", .{ .textDocument = doc, .position = position(main_text, "hello") });
        try testing.expectEqualStrings("hello", prep.object.get("result").?.object.get("placeholder").?.string);
        const resp = try h.request("textDocument/rename", .{ .textDocument = doc, .position = position(main_text, "hello"), .newName = "greet" });
        const changes = resp.object.get("result").?.object.get("changes").?.object;
        try testing.expectEqual(2, changes.count());
        var it = changes.iterator();
        while (it.next()) |kv| {
            const edits = kv.value_ptr.array.items;
            try testing.expectEqual(2, edits.len);
            for (edits) |e| try testing.expectEqualStrings("greet", e.object.get("newText").?.string);
        }
        // A keyword as the new name: wrapped in @"..."
        const kw = try h.request("textDocument/rename", .{ .textDocument = doc, .position = position(main_text, "hello"), .newName = "fn" });
        var kw_it = kw.object.get("result").?.object.get("changes").?.object.iterator();
        try testing.expectEqualStrings("@\"fn\"", kw_it.next().?.value_ptr.array.items[0].object.get("newText").?.string);
        // Names of primitive types: also wrapped in @"..." (written as is, the name would clash
        // with the primitive type, which is a compile error)
        const prim = try h.request("textDocument/rename", .{ .textDocument = doc, .position = position(main_text, "hello"), .newName = "u8" });
        var prim_it = prim.object.get("result").?.object.get("changes").?.object.iterator();
        try testing.expectEqualStrings("@\"u8\"", prim_it.next().?.value_ptr.array.items[0].object.get("newText").?.string);
        // Declarations in the standard library cannot be renamed
        const std_rename = try h.request("textDocument/prepareRename", .{ .textDocument = doc, .position = position(main_text, "Allocator") });
        try testing.expect(std_rename.object.get("error") != null);
        // The import of a workspace file is not a name: it used to be refused as a symbol defined
        // outside the workspace
        const import_rename = try h.request("textDocument/rename", .{ .textDocument = doc, .position = position(main_text, "lib\")"), .newName = "helpers" });
        try testing.expectEqualStrings("cannot rename: the cursor is on the import of a file, and files cannot be renamed", import_rename.object.get("error").?.object.get("message").?.string);
        // std calls `root.main`: renaming it in the root source file used to break the build
        const main_rename = try h.request("textDocument/rename", .{ .textDocument = doc, .position = position(main_text, "main"), .newName = "run" });
        try testing.expectEqualStrings(fixture.separators("cannot rename `main` to `run`: the standard library looks up `root.main` by this name in the root source file (src/main.zig:3:8)"), main_rename.object.get("error").?.object.get("message").?.string);
    }

    // workspace symbol
    {
        const resp = try h.request("workspace/symbol", .{ .query = "hel" });
        const syms = resp.object.get("result").?.array.items;
        try testing.expect(syms.len >= 1);
        try testing.expectEqualStrings("hello", syms[0].object.get("name").?.string);

        // Indexing in progress: the request waits until the symbol index covers the module graph
        // as it was when the request started, then searches every file. Answering at once
        // searched only the files indexed so far, silently leaving out the others (here lib.zig,
        // which is not open).
        h.server.indexing.store(true, .release);
        const target = h.server.index_generation.fetchAdd(1, .monotonic) + 1;
        const waiting = try h.send("workspace/symbol", .{ .query = "hel" });
        // A waiting request can be canceled
        const canceled = try h.send("workspace/symbol", .{ .query = "hel" });
        try h.notify("$/cancelRequest", .{ .id = canceled });
        const cancel_resp = try h.response(canceled);
        try testing.expectEqual(za.lsp.jsonrpc.error_codes.request_cancelled, cancel_resp.object.get("error").?.object.get("code").?.integer);
        for (h.received.items) |m| if (m.object.get("method") == null) if (m.object.get("id")) |id| {
            try testing.expect(!(id == .integer and id.integer == waiting));
        };
        {
            h.server.index_mutex.lockUncancelable(testing.io);
            defer h.server.index_mutex.unlock(testing.io);
            h.server.symbols_indexed = target;
            h.server.index_cond.broadcast(testing.io);
        }
        const during = (try h.response(waiting)).object.get("result").?.array.items;
        try testing.expectEqual(1, during.len);
        try testing.expectEqualStrings("hello", during[0].object.get("name").?.string);
        h.server.indexing.store(false, .release);
    }

    // code action: unused local constant
    {
        const extra = "const y = 2;\nfn f() void {\n    const x = 1;\n}\n";
        const extra_uri = try za.base.uri.fromPath(a, try project.path(a, "src/extra.zig"));
        try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = extra_uri, .languageId = "zig", .version = 1, .text = extra } });
        const p = position(extra, "x =");
        const resp = try h.request("textDocument/codeAction", .{
            .textDocument = .{ .uri = extra_uri },
            .range = .{ .start = p, .end = p },
            .context = .{ .diagnostics = &[_]Empty{} },
        });
        const actions = resp.object.get("result").?.array.items;
        try testing.expectEqual(1, actions.len);
        try testing.expectEqualStrings("discard `x`", actions[0].object.get("title").?.string);
        const edits = actions[0].object.get("edit").?.object.get("changes").?.object.get(extra_uri).?.array.items;
        try testing.expectEqualStrings("\n    _ = x;", edits[0].object.get("newText").?.string);

        // A range with start and end reversed is handled as if swapped (without the swap,
        // subtracting the offsets underflows and the server crashes)
        const reversed = try h.request("textDocument/codeAction", .{
            .textDocument = .{ .uri = extra_uri },
            .range = .{ .start = p, .end = .{ .line = 0, .character = 0 } },
            .context = .{ .diagnostics = &[_]Empty{} },
        });
        try testing.expect(reversed.object.get("result") != null);
    }

    // Observability: query statistics in status and slow request reports
    {
        // hover infers the body of main, so the statistics include executed Infer queries
        _ = try h.request("textDocument/hover", .{ .textDocument = doc, .position = position(main_text, "hello();") });
        const st = try h.request("zig-analyzer/status", {});
        var found = false;
        for (st.object.get("result").?.object.get("queries").?.array.items) |q| {
            if (!std.mem.endsWith(u8, q.object.get("name").?.string, ".Infer")) continue;
            found = true;
            try testing.expect(q.object.get("executions").?.integer > 0);
            const total = q.object.get("total_ms").?.float;
            try testing.expect(total >= q.object.get("self_ms").?.float);
        }
        try testing.expect(found);

        // The test body in lib.zig has not been inferred yet: hover records the queries actually
        // executed and generates a report
        var ctx = h.server.db.beginRead(a);
        defer ctx.end();
        var trace: za.db.Trace = .{ .gpa = a };
        ctx.trace = &trace;
        var r: za.names.resolve.Resolver = .{ .ctx = &ctx, .arena = a };
        const lib = (try h.server.vfs.lookup(try project.path(a, "src/lib.zig"))).?;
        _ = try za.ide.hover.hover(&r, lib, @intCast(std.mem.indexOf(u8, lib_text, "hello();").?), &.{});
        try testing.expect(trace.events.items.len > 0);
        var out: std.Io.Writer.Allocating = .init(a);
        try h.server.writeSlowReport(&out.writer, &ctx, &trace, 0);
        const report = out.written();
        try testing.expect(std.mem.indexOf(u8, report, "by query (self time):") != null);
        // Keys in the call tree are shown as "file:member" (a test has no name)
        try testing.expect(std.mem.indexOf(u8, report, "queries.Infer {owner=lib.zig:_") != null);
    }
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "rename reaches references in deeply nested code" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    // Each term of a left-associative operator chain is one level deeper: the leftmost `one` is
    // over 1500 levels deep in the syntax tree
    try text.appendSlice(testing.allocator, "const one: u32 = 1;\nconst sum = one");
    for (0..1500) |_| try text.appendSlice(testing.allocator, " + one");
    try text.appendSlice(testing.allocator, ";\npub fn main() void {\n    _ = sum;\n}\n");
    const files = [_]fixture.File{
        .{ .path = "build.zig", .text = fixture.basic[0].text },
        .{ .path = "src/main.zig", .text = text.items },
    };
    var project = try fixture.Project.create(&files);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    _ = try h.request("initialize", .{ .rootUri = try za.base.uri.fromPath(a, project.root), .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text.items } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const renamed = try h.request("textDocument/rename", .{ .textDocument = .{ .uri = uri }, .position = position(text.items, "one"), .newName = "two" });
    const changes = renamed.object.get("result").?.object.get("changes").?.object;
    try testing.expectEqual(1502, changes.get(uri).?.array.items.len);
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "rename refuses when a generic reference also refers to other declarations" {
    const text =
        \\const S = struct { x: u32 };
        \\const T = struct { x: u32 };
        \\fn read(p: anytype) u32 {
        \\    return p.x;
        \\}
        \\pub fn main() void {
        \\    _ = read(S{ .x = 1 });
        \\    _ = read(T{ .x = 2 });
        \\}
        \\
    ;
    const files = [_]fixture.File{
        .{ .path = "build.zig", .text = fixture.basic[0].text },
        .{ .path = "src/main.zig", .text = text },
    };
    var project = try fixture.Project.create(&files);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    _ = try h.request("initialize", .{ .rootUri = try za.base.uri.fromPath(a, project.root), .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    // `p.x` in `read` is T.x in T's instance: no partially renamed result is returned
    const resp = try h.request("textDocument/rename", .{ .textDocument = .{ .uri = uri }, .position = position(text, "x"), .newName = "y" });
    try testing.expect(resp.object.get("error") != null);
    // Find references still includes it
    const refs = try h.request("textDocument/references", .{ .textDocument = .{ .uri = uri }, .position = position(text, "x"), .context = .{ .includeDeclaration = true } });
    try testing.expectEqual(3, refs.object.get("result").?.array.items.len);
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "rename refuses when a reference cannot be confirmed" {
    const impls_text =
        \\pub const Tcp = struct {
        \\    pub fn Close(_: *Tcp) void {}
        \\};
        \\pub const Udp = struct {
        \\    pub fn Close(_: *Udp) void {}
        \\};
        \\
    ;
    const conn_text =
        \\const impls = @import("impls.zig");
        \\pub const Conn = union(enum) {
        \\    tcp: impls.Tcp,
        \\    udp: impls.Udp,
        \\    pub fn close(self: *Conn) void {
        \\        switch (self.*) {
        \\            inline else => |*c| c.Close(),
        \\        }
        \\    }
        \\};
        \\
    ;
    const main_body =
        \\const Conn = @import("conn.zig").Conn;
        \\pub fn main() void {
        \\    var c: Conn = .{ .tcp = .{} };
        \\    c.close();
        \\}
        \\
    ;
    const files = [_]fixture.File{
        .{ .path = "build.zig", .text = fixture.basic[0].text },
        .{ .path = "src/main.zig", .text = main_body },
        .{ .path = "src/lib.zig", .text = "pub fn hello() void {}\n" },
        .{ .path = "src/conn.zig", .text = conn_text },
        .{ .path = "src/impls.zig", .text = impls_text },
    };
    var project = try fixture.Project.create(&files);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    _ = try h.request("initialize", .{ .rootUri = try za.base.uri.fromPath(a, project.root), .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const impls_uri = try za.base.uri.fromPath(a, try project.path(a, "src/impls.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = impls_uri, .languageId = "zig", .version = 1, .text = impls_text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    // `c.Close()` in the `inline else` prong is Tcp.Close in one expansion and Udp.Close in the
    // other: a rename returned only the declaration and broke the build
    {
        const resp = try h.request("textDocument/rename", .{ .textDocument = .{ .uri = impls_uri }, .position = position(impls_text, "Close"), .newName = "close" });
        try testing.expectEqualStrings(fixture.separators("cannot rename `Close` to `close`: this reference also refers to other declarations in other instantiations of its generic function or `inline` prong, iterations of its loop, or build configurations (src/conn.zig:7:33)"), resp.object.get("error").?.object.get("message").?.string);
    }
    // A file that mentions the name but has syntax errors may hide references
    {
        const conn_uri = try za.base.uri.fromPath(a, try project.path(a, "src/conn.zig"));
        try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = conn_uri, .languageId = "zig", .version = 1, .text = conn_text } });
        const main_uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
        const broken = "const Conn = @import(\"conn.zig\").Conn;\npub fn main() void {\n    if (true) {\n    var c: Conn = .{ .tcp = .{} };\n    c.close();\n}\n";
        try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = main_uri, .languageId = "zig", .version = 1, .text = broken } });
        _ = try h.request("zig-analyzer/waitIdle", {});
        const resp = try h.request("textDocument/rename", .{ .textDocument = .{ .uri = conn_uri }, .position = position(conn_text, "close"), .newName = "shut" });
        try testing.expectEqualStrings(fixture.separators("cannot rename `close` to `shut`: the file has syntax errors, so references in it may be missed (src/main.zig)"), resp.object.get("error").?.object.get("message").?.string);
    }
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

/// "file:line:column" of every edit in a rename result, sorted
fn renameEdits(h: *Harness, resp: std.json.Value) ![]const u8 {
    const a = h.arena.allocator();
    var out: std.ArrayList([]const u8) = .empty;
    var it = resp.object.get("result").?.object.get("changes").?.object.iterator();
    while (it.next()) |kv| for (kv.value_ptr.array.items) |e| try out.append(a, try loc(h, kv.key_ptr.*, e.object.get("range").?));
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return join(h, out.items);
}

test "references and rename reach closed files outside any build graph" {
    const scale_text = "pub fn scale(x: u32) u32 {\n    return x * 2;\n}\n";
    const main_body = "const lib = @import(\"lib.zig\");\npub fn main() void {\n    _ = lib.scale(3);\n}\n";
    // Single-file mode: no build.zig, and main.zig and util.zig are never opened
    const files = [_]fixture.File{
        .{ .path = "lib.zig", .text = scale_text },
        .{ .path = "main.zig", .text = main_body },
        .{ .path = "util.zig", .text = "pub fn helperOne() void {}\n" },
    };
    var project = try fixture.Project.create(&files);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    // The client watches the files: a server-side notification of the file created below could
    // arrive after waitIdle and start another scan, during which rename is refused
    _ = try h.request("initialize", .{ .rootUri = try za.base.uri.fromPath(a, project.root), .capabilities = .{ .workspace = .{ .didChangeWatchedFiles = .{ .dynamicRegistration = true } } } });
    try h.notify("initialized", Empty{});
    const lib_uri = try za.base.uri.fromPath(a, try project.path(a, "lib.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = lib_uri, .languageId = "zig", .version = 1, .text = scale_text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const at = position(scale_text, "scale");
    {
        const resp = try h.request("textDocument/references", .{ .textDocument = .{ .uri = lib_uri }, .position = at, .context = .{ .includeDeclaration = true } });
        var out: std.ArrayList([]const u8) = .empty;
        for (resp.object.get("result").?.array.items) |l| try out.append(a, try loc(&h, l.object.get("uri").?.string, l.object.get("range").?));
        std.mem.sort([]const u8, out.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        try testing.expectEqualStrings("lib.zig:0:7 main.zig:2:12", try join(&h, out.items));
        const renamed = try h.request("textDocument/rename", .{ .textDocument = .{ .uri = lib_uri }, .position = at, .newName = "double" });
        try testing.expectEqualStrings("lib.zig:0:7 main.zig:2:12", try renameEdits(&h, renamed));
    }
    // Workspace symbol lists declarations of closed files too
    {
        const resp = try h.request("workspace/symbol", .{ .query = "helperOne" });
        const syms = resp.object.get("result").?.array.items;
        try testing.expectEqual(1, syms.len);
        try testing.expectEqualStrings("util.zig", basename(syms[0].object.get("location").?.object.get("uri").?.string));
    }
    // A file created on disk later joins the scope
    {
        const other = "const lib = @import(\"lib.zig\");\ntest {\n    _ = lib.scale(1);\n}\n";
        try project.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "other.zig", .data = other });
        try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = try za.base.uri.fromPath(a, try project.path(a, "other.zig")), .type = 1 }} });
        _ = try h.request("zig-analyzer/waitIdle", {});
        const renamed = try h.request("textDocument/rename", .{ .textDocument = .{ .uri = lib_uri }, .position = at, .newName = "double" });
        try testing.expectEqualStrings("lib.zig:0:7 main.zig:2:12 other.zig:2:12", try renameEdits(&h, renamed));
    }
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "rename reaches build scripts and their helpers" {
    const helpers_text =
        \\const std = @import("std");
        \\pub fn addThing(b: *std.Build, exe: *std.Build.Step.Compile) void {
        \\    b.installArtifact(exe);
        \\}
        \\
    ;
    const files = [_]fixture.File{
        .{ .path = "build.zig", .text =
        \\const std = @import("std");
        \\const helpers = @import("build_helpers.zig");
        \\pub fn build(b: *std.Build) void {
        \\    const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = b.graph.host }) });
        \\    helpers.addThing(b, exe);
        \\}
        \\
        },
        .{ .path = "build_helpers.zig", .text = helpers_text },
        .{ .path = "main.zig", .text = "pub fn main() void {}\n" },
    };
    var project = try fixture.Project.create(&files);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    _ = try h.request("initialize", .{ .rootUri = try za.base.uri.fromPath(a, project.root), .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const helpers_uri = try za.base.uri.fromPath(a, try project.path(a, "build_helpers.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = helpers_uri, .languageId = "zig", .version = 1, .text = helpers_text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    // build.zig is not in the module graph of any compile step and is not open
    const renamed = try h.request("textDocument/rename", .{ .textDocument = .{ .uri = helpers_uri }, .position = position(helpers_text, "addThing"), .newName = "addArtifact" });
    try testing.expectEqualStrings("build.zig:4:12 build_helpers.zig:1:7", try renameEdits(&h, renamed));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

/// The error message of a request sent while the project loads: a read interrupted by a write
/// transaction of the load itself (the module graph update after the zig environment query, the
/// workspace scan) is answered with ContentModified, which asks for a retry; the request is sent
/// again, and since the load is still blocked, the refusal that explains why the results are not
/// available comes back at once. Fails when the request is answered instead.
fn loadingError(h: *Harness, method: []const u8, params: anytype) ![]const u8 {
    // A load whose writes keep interrupting the request fails the test instead of looping forever
    for (0..50) |_| {
        const resp = try h.request(method, params);
        if (resp.object.get("result") != null) return error.TestUnexpectedResult;
        const e = resp.object.get("error").?.object;
        if (e.get("code").?.integer == za.lsp.jsonrpc.error_codes.content_modified) continue;
        return e.get("message").?.string;
    }
    return error.ContentModified;
}

test "references and rename fail instead of returning partial results while the project loads" {
    const scale_text = "pub fn scale(x: u32) u32 {\n    return x * 2;\n}\n";
    const files = [_]fixture.File{
        .{ .path = "src/lib.zig", .text = scale_text },
        .{ .path = "src/util.zig", .text = "const lib = @import(\"lib.zig\");\npub fn twice(x: u32) u32 {\n    return lib.scale(x);\n}\n" },
        .{ .path = "src/main.zig", .text = "const lib = @import(\"lib.zig\");\nconst util = @import(\"util.zig\");\npub fn main() void {\n    _ = lib.scale(2) + util.twice(3);\n}\n" },
    };
    var project = try fixture.Project.create(&files);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    // The first load waits until the marker file exists
    const marker = try project.path(a, "go");
    const build_text = try std.fmt.allocPrint(a,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {{
        \\    while (true) {{
        \\        std.Io.Dir.accessAbsolute(b.graph.io, "{f}", .{{}}) catch {{
        \\            b.graph.io.sleep(.fromMilliseconds(10), .awake) catch {{}};
        \\            continue;
        \\        }};
        \\        break;
        \\    }}
        \\    const exe = b.addExecutable(.{{ .name = "app", .root_module = b.createModule(.{{ .root_source_file = b.path("src/main.zig"), .target = b.graph.host }}) }});
        \\    b.installArtifact(exe);
        \\}}
        \\
    , .{std.zig.fmtString(marker)});
    try project.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data = build_text });
    _ = try h.request("initialize", .{ .rootUri = try za.base.uri.fromPath(a, project.root), .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const lib_uri = try za.base.uri.fromPath(a, try project.path(a, "src/lib.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = lib_uri, .languageId = "zig", .version = 1, .text = scale_text } });
    const at = position(scale_text, "scale");
    // Only the open file is known while loading: answering would have returned one reference and a
    // rename editing lib.zig alone
    {
        const refs = try loadingError(&h, "textDocument/references", .{ .textDocument = .{ .uri = lib_uri }, .position = at, .context = .{ .includeDeclaration = true } });
        try testing.expect(std.mem.startsWith(u8, refs, "cannot find all references: "));
        const renamed = try loadingError(&h, "textDocument/rename", .{ .textDocument = .{ .uri = lib_uri }, .position = at, .newName = "double" });
        try testing.expect(std.mem.startsWith(u8, renamed, "cannot rename `scale` to `double`: "));
    }
    try project.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "go", .data = "" });
    _ = try h.request("zig-analyzer/waitIdle", {});
    {
        const refs = try h.request("textDocument/references", .{ .textDocument = .{ .uri = lib_uri }, .position = at, .context = .{ .includeDeclaration = true } });
        try testing.expectEqual(3, refs.object.get("result").?.array.items.len);
        const renamed = try h.request("textDocument/rename", .{ .textDocument = .{ .uri = lib_uri }, .position = at, .newName = "double" });
        try testing.expectEqualStrings("lib.zig:0:7 main.zig:3:12 util.zig:2:15", try renameEdits(&h, renamed));
    }
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "generic bodies get the instances of callers in files outside any build graph" {
    const util_text = "pub fn area(shape: anytype) u32 {\n    const w = shape.width;\n    return w * shape.height;\n}\n";
    const main_body = "const util = @import(\"util.zig\");\n\nconst Rect = struct { width: u32, height: u32 };\n\npub fn main() void {\n    const r: Rect = .{ .width = 2, .height = 3 };\n    _ = util.area(r);\n}\n";
    // Single-file mode: no build.zig
    const files = [_]fixture.File{
        .{ .path = "util.zig", .text = util_text },
        .{ .path = "main.zig", .text = main_body },
    };
    var project = try fixture.Project.create(&files);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    _ = try h.request("initialize", .{ .rootUri = try za.base.uri.fromPath(a, project.root), .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const util_uri = try za.base.uri.fromPath(a, try project.path(a, "util.zig"));
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = util_uri, .languageId = "zig", .version = 1, .text = util_text } });
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = main_uri, .languageId = "zig", .version = 1, .text = main_body } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    // The call in main.zig instantiates `area`: `w` was unknown, and rename missed `shape.width`
    const hover = try h.request("textDocument/hover", .{ .textDocument = .{ .uri = util_uri }, .position = position(util_text, "w =") });
    const value = hover.object.get("result").?.object.get("contents").?.object.get("value").?.string;
    try testing.expect(std.mem.indexOf(u8, value, "const w: u32") != null);
    const renamed = try h.request("textDocument/rename", .{ .textDocument = .{ .uri = main_uri }, .position = position(main_body, "width"), .newName = "wide" });
    try testing.expectEqualStrings("main.zig:2:22 main.zig:5:24 util.zig:1:20", try renameEdits(&h, renamed));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "rename reaches typed .zon files imported from files outside any build graph" {
    const main_body = "const S = struct { x: u32, y: bool = false };\nconst cfg: S = @import(\"cfg.zon\");\npub fn main() void {\n    _ = cfg.x;\n}\n";
    // Single-file mode: no build.zig, and cfg.zon is never opened
    const files = [_]fixture.File{
        .{ .path = "main.zig", .text = main_body },
        .{ .path = "cfg.zon", .text = ".{ .x = 1 }\n" },
    };
    var project = try fixture.Project.create(&files);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    _ = try h.request("initialize", .{ .rootUri = try za.base.uri.fromPath(a, project.root), .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = main_uri, .languageId = "zig", .version = 1, .text = main_body } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    // The `.zon` file got no result type from its importer in no module: the rename left `.x` in
    // it and the build failed with "unexpected field 'x'"
    const renamed = try h.request("textDocument/rename", .{ .textDocument = .{ .uri = main_uri }, .position = position(main_body, "x"), .newName = "count" });
    try testing.expectEqualStrings("cfg.zon:0:4 main.zig:0:19 main.zig:3:12", try renameEdits(&h, renamed));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "renames and fixes refuse to edit fetched packages" {
    // A dependency fetched by hash (faked: maker does not fetch it again when the package
    // directory already has it), placed outside the build root with `--pkg-dir`
    const hash = "foo-0.0.1-OjQ08eFlFQAb4BLnwZNNE3R5Dx2TI67EIpAsy2h0ZyoC";
    const pkg_root = "pub fn callIt(x: anytype) u32 {\n    return x.method() + x.withExtra(7);\n}\n";
    const main_body =
        \\const dep = @import("foo");
        \\const Mine = struct {
        \\    n: u32 = 3,
        \\    pub fn method(self: Mine) u32 {
        \\        return self.n;
        \\    }
        \\    pub fn withExtra(self: Mine, extra: u32) u32 {
        \\        return self.n;
        \\    }
        \\};
        \\export fn entry() u32 {
        \\    return dep.callIt(Mine{});
        \\}
        \\
    ;
    const files = [_]fixture.File{
        .{ .path = "proj/build.zig.zon", .text = ".{ .name = .proj, .version = \"0.0.0\", .fingerprint = 0x520c3c90be36badb, .paths = .{\"\"}, " ++
            ".dependencies = .{ .foo = .{ .url = \"https://example.invalid/foo.tar.gz\", .hash = \"" ++ hash ++ "\" } } }\n" },
        .{ .path = "proj/build.zig", .text =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const foo = b.dependency("foo", .{});
        \\    const root = b.createModule(.{
        \\        .root_source_file = b.path("main.zig"),
        \\        .target = b.graph.host,
        \\        .imports = &.{.{ .name = "foo", .module = foo.module("foo") }},
        \\    });
        \\    b.step("check", "Check").dependOn(&b.addObject(.{ .name = "probe", .root_module = root }).step);
        \\}
        \\
        },
        .{ .path = "proj/main.zig", .text = main_body },
        .{ .path = "proj/zig-analyzer.zon", .text = ".{ .build = .{ .args = .{ \"--pkg-dir\", \"../pkgs\" } } }" },
        .{ .path = "pkgs/" ++ hash ++ "/build.zig.zon", .text = ".{ .name = .foo, .version = \"0.0.1\", .fingerprint = 0x8c736521e67512df, .paths = .{\"\"} }\n" },
        .{ .path = "pkgs/" ++ hash ++ "/build.zig", .text =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    _ = b.addModule("foo", .{ .root_source_file = b.path("src/root.zig") });
        \\}
        \\
        },
        .{ .path = "pkgs/" ++ hash ++ "/src/root.zig", .text = pkg_root },
    };
    var project = try fixture.Project.create(&files);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    _ = try h.request("initialize", .{
        .rootUri = try za.base.uri.fromPath(a, try project.path(a, "proj")),
        .capabilities = .{ .textDocument = .{ .codeAction = .{ .codeActionLiteralSupport = literal_actions, .dataSupport = true, .disabledSupport = true, .resolveSupport = .{ .properties = &[_][]const u8{"edit"} } } } },
    });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "proj/main.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = main_uri, .languageId = "zig", .version = 1, .text = main_body } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    // `x.method()` in the package refers to `Mine.method` through the instance: references list it,
    // but a rename used to edit the package, whose copy restored by hash elsewhere then broke
    const refs = try h.request("textDocument/references", .{ .textDocument = .{ .uri = main_uri }, .position = position(main_body, "method"), .context = .{ .includeDeclaration = true } });
    try testing.expectEqual(2, refs.object.get("result").?.array.items.len);
    const pkg_file = try project.path(a, "pkgs/" ++ hash ++ "/src/root.zig");
    {
        const resp = try h.request("textDocument/rename", .{ .textDocument = .{ .uri = main_uri }, .position = position(main_body, "method"), .newName = "run" });
        const expected = try std.fmt.allocPrint(a, "cannot rename `method` to `run`: this use is in a dependency library (the Zig installation, a fetched package, a generated file) or a stale copy of one, which must not be edited ({s}:2:14)", .{pkg_file});
        try testing.expectEqualStrings(expected, resp.object.get("error").?.object.get("message").?.string);
    }
    {
        const p = position(main_body, "extra:");
        const actions = (try h.request("textDocument/codeAction", .{
            .textDocument = .{ .uri = main_uri },
            .range = .{ .start = p, .end = p },
            .context = .{ .diagnostics = &[_]Empty{} },
        })).object.get("result").?.array.items;
        const fix = for (actions) |x| {
            if (std.mem.eql(u8, x.object.get("title").?.string, "remove parameter `extra`")) break x;
        } else return error.NoFix;
        const resp = try h.request("codeAction/resolve", fix);
        const message = resp.object.get("error").?.object.get("message").?.string;
        try testing.expect(std.mem.startsWith(u8, message, "cannot remove parameter `extra`: this use is in a dependency library (the Zig installation, a fetched package, a generated file) or a stale copy of one, which must not be edited ("));
        try testing.expect(std.mem.indexOf(u8, message, pkg_file) != null);
    }
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "rename refuses new names that conflict with existing ones" {
    const text =
        \\const S = struct {
        \\    a: u32 = 0,
        \\    b: u32 = 0,
        \\    fn len(s: S) u32 {
        \\        return s.a + s.b;
        \\    }
        \\};
        \\
        \\fn helper(x: u32) u32 {
        \\    const y: u32 = 2;
        \\    const z: u32 = 3;
        \\    return x + y + z;
        \\}
        \\
        \\const max = 10;
        \\const Limits = struct {
        \\    const limit = 5;
        \\    fn get() u32 {
        \\        return max + limit;
        \\    }
        \\};
        \\
        \\pub fn main() void {
        \\    const s: S = .{ .a = 1, .b = 2 };
        \\    _ = s.len() + helper(1) + Limits.get();
        \\}
        \\
    ;
    // Single-file mode: no build.zig
    var project = try fixture.Project.create(&.{.{ .path = "main.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    _ = try h.request("initialize", .{ .rootUri = try za.base.uri.fromPath(a, project.root), .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    // Each of these used to return edits that AstGen rejects
    for ([_]struct { []const u8, []const u8, []const u8 }{
        .{ "y:", "z", "cannot rename `y` to `z`: " },
        .{ "y:", "x", "cannot rename `y` to `x`: " },
        .{ "s: S)", "len", "cannot rename `s` to `len`: " },
        .{ "a: u32", "b", "cannot rename `a` to `b`: `b` is already declared in the same container (main.zig:3:5)" },
        .{ "max =", "limit", "cannot rename `max` to `limit`: " },
    }) |c| {
        const resp = try h.request("textDocument/rename", .{ .textDocument = .{ .uri = uri }, .position = position(text, c[0]), .newName = c[1] });
        const message = resp.object.get("error").?.object.get("message").?.string;
        testing.expect(std.mem.startsWith(u8, message, c[2])) catch |err| {
            std.debug.print("{s} -> {s}: {s}\n", .{ c[0], c[1], message });
            return err;
        };
    }
    const ok = try h.request("textDocument/rename", .{ .textDocument = .{ .uri = uri }, .position = position(text, "y:"), .newName = "yy" });
    try testing.expectEqualStrings("main.zig:11:15 main.zig:9:10", try renameEdits(&h, ok));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "rename covers tags named after fields and refuses names used in strings" {
    const text =
        \\const std = @import("std");
        \\const Item = struct {
        \\    id: u32,
        \\    node: u8 = 0,
        \\};
        \\test {
        \\    var list: std.MultiArrayList(Item) = .empty;
        \\    defer list.deinit(std.testing.allocator);
        \\    try list.append(std.testing.allocator, .{ .id = 7 });
        \\    try std.testing.expectEqual(@as(u32, 7), list.items(.id)[0]);
        \\    const item: Item = .{ .id = 1 };
        \\    _ = @field(item, "node");
        \\}
        \\
    ;
    // Single-file mode: no build.zig
    var project = try fixture.Project.create(&.{.{ .path = "main.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    _ = try h.request("initialize", .{ .rootUri = try za.base.uri.fromPath(a, project.root), .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    // `.id` in `list.items(.id)` is a tag of `std.meta.FieldEnum(Item)`, named after the field: it
    // used to be missing, and the renamed copy failed with "has no member named 'id'"
    const renamed = try h.request("textDocument/rename", .{ .textDocument = .{ .uri = uri }, .position = position(text, "id:"), .newName = "key" });
    try testing.expectEqualStrings("main.zig:10:27 main.zig:2:4 main.zig:8:47 main.zig:9:57", try renameEdits(&h, renamed));
    // `@field(item, "node")` names the field by a string that a rename would not update
    const node = try h.request("textDocument/rename", .{ .textDocument = .{ .uri = uri }, .position = position(text, "node:"), .newName = "link" });
    try testing.expectEqualStrings("cannot rename `node` to `link`: `node` appears in a string literal, which may refer to it by name (as `@field` and serialization do) and would not be updated (main.zig:12:22)", node.object.get("error").?.object.get("message").?.string);
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "labels and error names: references, highlight and rename" {
    const text =
        \\const std = @import("std");
        \\const E = error{ Oops, Other };
        \\const F = error{Oops};
        \\fn f(x: u32) E!u32 {
        \\    if (x == 0) return error.Oops;
        \\    if (x == 9) return E.Oops;
        \\    const v: u32 = blk: {
        \\        if (x == 1) break :blk 1;
        \\        break :blk 2;
        \\    };
        \\    var n: u32 = 0;
        \\    outer: while (n < 3) : (n += 1) {
        \\        inner: for (0..2) |_| {
        \\            if (n == 1) continue :outer;
        \\            if (n == 2) break :inner;
        \\        }
        \\        if (n == 2) break :outer;
        \\    }
        \\    return v + n;
        \\}
        \\fn grow(a: std.mem.Allocator) error{OutOfMemory}!void {
        \\    a.free(try a.alloc(u8, 1));
        \\}
        \\test {
        \\    const r = f(2) catch |err| switch (err) {
        \\        error.Oops => 0,
        \\        error.Other => 1,
        \\    };
        \\    try std.testing.expect(r == 4);
        \\    try std.testing.expect(@intFromError(E.Oops) == @intFromError(F.Oops));
        \\    try grow(std.testing.allocator);
        \\}
        \\
    ;
    // Single-file mode: no build.zig
    var project = try fixture.Project.create(&.{.{ .path = "main.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    _ = try h.request("initialize", .{ .rootUri = try za.base.uri.fromPath(a, project.root), .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    const doc = .{ .uri = uri };
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    // All of these returned null although goto resolved them
    {
        const resp = try h.request("textDocument/references", .{ .textDocument = doc, .position = position(text, "blk:"), .context = .{ .includeDeclaration = true } });
        var out: std.ArrayList([]const u8) = .empty;
        for (resp.object.get("result").?.array.items) |l| try out.append(a, try loc(&h, uri, l.object.get("range").?));
        try testing.expectEqualStrings("main.zig:6:19 main.zig:7:27 main.zig:8:15", try join(&h, out.items));
    }
    {
        const resp = try h.request("textDocument/documentHighlight", .{ .textDocument = doc, .position = position(text, "outer;") });
        var out: std.ArrayList([]const u8) = .empty;
        for (resp.object.get("result").?.array.items) |x| try out.append(a, try std.fmt.allocPrint(a, "{s}/{d}", .{ try loc(&h, uri, x.object.get("range").?), x.object.get("kind").?.integer }));
        try testing.expectEqualStrings("main.zig:11:4/3 main.zig:13:34/2 main.zig:16:27/2", try join(&h, out.items));
    }
    // The target of an assignment is written (`Write` = 3), other uses read (`Read` = 2)
    {
        const resp = try h.request("textDocument/documentHighlight", .{ .textDocument = doc, .position = position(text, "n: u32") });
        var out: std.ArrayList([]const u8) = .empty;
        for (resp.object.get("result").?.array.items) |x| try out.append(a, try std.fmt.allocPrint(a, "{s}/{d}", .{ try loc(&h, uri, x.object.get("range").?), x.object.get("kind").?.integer }));
        try testing.expectEqualStrings("main.zig:10:8/3 main.zig:11:18/2 main.zig:11:28/3 main.zig:13:16/2 main.zig:14:16/2 main.zig:16:12/2 main.zig:18:15/2", try join(&h, out.items));
    }
    {
        const prep = try h.request("textDocument/prepareRename", .{ .textDocument = doc, .position = position(text, "blk 2") });
        try testing.expectEqualStrings("blk", prep.object.get("result").?.object.get("placeholder").?.string);
        const renamed = try h.request("textDocument/rename", .{ .textDocument = doc, .position = position(text, "blk 2"), .newName = "done" });
        try testing.expectEqualStrings("main.zig:6:19 main.zig:7:27 main.zig:8:15", try renameEdits(&h, renamed));
        // A label must not redefine the label of an enclosing loop
        const redefined = try h.request("textDocument/rename", .{ .textDocument = doc, .position = position(text, "inner:"), .newName = "outer" });
        try testing.expectEqualStrings("cannot rename `inner` to `outer`: redefinition of label 'outer' (main.zig:13:9)", redefined.object.get("error").?.object.get("message").?.string);
    }
    // Error names are global: every error set that contains the name, and `E.X` on error sets
    {
        const resp = try h.request("textDocument/references", .{ .textDocument = doc, .position = position(text, "Oops;"), .context = .{ .includeDeclaration = true } });
        var out: std.ArrayList([]const u8) = .empty;
        for (resp.object.get("result").?.array.items) |l| try out.append(a, try loc(&h, uri, l.object.get("range").?));
        try testing.expectEqualStrings("main.zig:1:17 main.zig:2:16 main.zig:4:29 main.zig:5:25 main.zig:25:14 main.zig:29:43 main.zig:29:68", try join(&h, out.items));
        const prep = try h.request("textDocument/prepareRename", .{ .textDocument = doc, .position = position(text, "Oops =>") });
        try testing.expectEqualStrings("Oops", prep.object.get("result").?.object.get("placeholder").?.string);
        const renamed = try h.request("textDocument/rename", .{ .textDocument = doc, .position = position(text, "Oops =>"), .newName = "Failed" });
        try testing.expectEqualStrings("main.zig:1:17 main.zig:25:14 main.zig:29:43 main.zig:29:68 main.zig:2:16 main.zig:4:29 main.zig:5:25", try renameEdits(&h, renamed));
    }
    // Renaming to an existing error name would merge the two errors (the switch prongs would
    // become duplicates)
    {
        const resp = try h.request("textDocument/rename", .{ .textDocument = doc, .position = position(text, "Oops;"), .newName = "Other" });
        try testing.expectEqualStrings("cannot rename `Oops` to `Other`: `Other` is already an error name: error names are global, so the renamed error would become this one (main.zig:2:24)", resp.object.get("error").?.object.get("message").?.string);
    }
    // The standard library uses `error.OutOfMemory` and is not renamed
    {
        const resp = try h.request("textDocument/rename", .{ .textDocument = doc, .position = position(text, "OutOfMemory"), .newName = "Oom" });
        const message = resp.object.get("error").?.object.get("message").?.string;
        try testing.expect(std.mem.startsWith(u8, message, "cannot rename `OutOfMemory` to `Oom`: this file also uses the error `OutOfMemory` and is not renamed: error names are global, so it would no longer be the same error ("));
    }
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}
