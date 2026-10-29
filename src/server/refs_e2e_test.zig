//! End-to-end: find references, document highlight, rename, workspace symbol and code actions
//! (across modules; unopened files are brought into scope through the module graph).

const std = @import("std");
const testing = std.testing;
const za = @import("../zig_analyzer.zig");
const fixture = za.project.fixture;
const Harness = @import("test_harness.zig").Harness;

const Empty = struct {};

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
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
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
    }

    // workspace symbol
    {
        const resp = try h.request("workspace/symbol", .{ .query = "hel" });
        const syms = resp.object.get("result").?.array.items;
        try testing.expect(syms.len >= 1);
        try testing.expectEqualStrings("hello", syms[0].object.get("name").?.string);

        // Indexing in progress: only indexed files and open documents are searched (lib.zig is
        // neither indexed yet nor open)
        h.server.indexing.store(true, .release);
        h.server.indexed_mutex.lockUncancelable(testing.io);
        h.server.indexed.clearRetainingCapacity();
        h.server.indexed_mutex.unlock(testing.io);
        defer h.server.indexing.store(false, .release);
        const partial = try h.request("workspace/symbol", .{ .query = "hel" });
        try testing.expectEqual(0, partial.object.get("result").?.array.items.len);
        const open_doc = try h.request("workspace/symbol", .{ .query = "main" });
        try testing.expectEqualStrings("main", open_doc.object.get("result").?.array.items[0].object.get("name").?.string);
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
        _ = try za.ide.hover.hover(&r, lib, @intCast(std.mem.indexOf(u8, lib_text, "hello();").?));
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
        try testing.expectEqualStrings("cannot rename `Close` to `close`: the type here is unknown, so whether this refers to the same declaration cannot be confirmed (src/conn.zig:7:33)", resp.object.get("error").?.object.get("message").?.string);
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
        try testing.expectEqualStrings("cannot rename `close` to `shut`: the file has syntax errors, so references in it may be missed (src/main.zig)", resp.object.get("error").?.object.get("message").?.string);
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
    _ = try h.request("initialize", .{ .rootUri = try za.base.uri.fromPath(a, project.root), .capabilities = Empty{} });
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
        const refs = try h.request("textDocument/references", .{ .textDocument = .{ .uri = lib_uri }, .position = at, .context = .{ .includeDeclaration = true } });
        try testing.expect(std.mem.startsWith(u8, refs.object.get("error").?.object.get("message").?.string, "cannot find all references: "));
        const renamed = try h.request("textDocument/rename", .{ .textDocument = .{ .uri = lib_uri }, .position = at, .newName = "double" });
        try testing.expect(std.mem.startsWith(u8, renamed.object.get("error").?.object.get("message").?.string, "cannot rename `scale` to `double`: "));
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
