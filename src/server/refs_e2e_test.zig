//! 端到端：查找引用、文档高亮、重命名、workspace symbol 与 code action（跨模块，未打开的文件经由模块图纳入范围）。

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

/// 「文件名:行:列」
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

    // 查找引用：lib.zig 未打开，经由模块图纳入
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

    // 文档高亮：只在当前文件
    {
        const resp = try h.request("textDocument/documentHighlight", .{ .textDocument = doc, .position = position(main_text, "hello") });
        var out: std.ArrayList([]const u8) = .empty;
        for (resp.object.get("result").?.array.items) |x| try out.append(a, try loc(&h, uri, x.object.get("range").?));
        try testing.expectEqualStrings("main.zig:3:8 main.zig:4:8", try join(&h, out.items));
    }

    // 重命名
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
        // 关键字作为新名字：用 @"..." 包裹
        const kw = try h.request("textDocument/rename", .{ .textDocument = doc, .position = position(main_text, "hello"), .newName = "fn" });
        var kw_it = kw.object.get("result").?.object.get("changes").?.object.iterator();
        try testing.expectEqualStrings("@\"fn\"", kw_it.next().?.value_ptr.array.items[0].object.get("newText").?.string);
        // 标准库中的声明不能重命名
        const std_rename = try h.request("textDocument/prepareRename", .{ .textDocument = doc, .position = position(main_text, "Allocator") });
        try testing.expect(std_rename.object.get("error") != null);
    }

    // workspace symbol
    {
        const resp = try h.request("workspace/symbol", .{ .query = "hel" });
        const syms = resp.object.get("result").?.array.items;
        try testing.expect(syms.len >= 1);
        try testing.expectEqualStrings("hello", syms[0].object.get("name").?.string);

        // 索引进行中：只在已建立索引的文件与打开的文档中查找（lib.zig 尚未索引、也未打开）
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

    // code action：未使用的局部常量
    {
        const extra = "fn f() void {\n    const x = 1;\n}\n";
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
    }

    // 可观测性（设计 §14）：status 的查询统计与慢请求报告
    {
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

        // lib.zig 的 test 体尚未推导过：hover 时记录实际执行的 query 并生成报告
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
        // 调用树中的 key 以「文件名:成员名」显示（test 没有名字）
        try testing.expect(std.mem.indexOf(u8, report, "queries.Infer {owner=lib.zig:_") != null);
    }
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
    // `read` 中的 `p.x` 在 T 的实例下是 T.x：不返回只改了一部分的结果
    const resp = try h.request("textDocument/rename", .{ .textDocument = .{ .uri = uri }, .position = position(text, "x"), .newName = "y" });
    try testing.expect(resp.object.get("error") != null);
    // 查找引用仍然包含它
    const refs = try h.request("textDocument/references", .{ .textDocument = .{ .uri = uri }, .position = position(text, "x"), .context = .{ .includeDeclaration = true } });
    try testing.expectEqual(3, refs.object.get("result").?.array.items.len);
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}
