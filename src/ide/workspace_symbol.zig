//! workspace/symbol：在项目文件的 ItemTree 中按名字模糊匹配声明。
//!
//! 匹配规则：查询串（忽略大小写）是名字的子序列。完全相同优先，其次前缀，再次子序列；同级按名字长度。

const std = @import("std");
const types = @import("../lsp/types.zig");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const syntax = @import("../database.zig").syntax;
const ast = @import("../syntax/ast.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const document_symbol = @import("document_symbol.zig");

pub const Symbol = struct {
    name: []const u8,
    kind: types.SymbolKind,
    /// 所在容器的名字（文件顶层为 null）
    container: ?[]const u8,
    file: FileId,
    start: u32,
    end: u32,
    rank: u8,
};

/// 至多返回 `limit` 个（按匹配等级排序后最好的）。名字的位置取自 `ItemSummaries`（不淘汰）：项目文件多于解析结果的
/// 缓存容量时，重复的查询不必重新解析各文件
pub fn search(r: *Resolver, files: []const FileId, query: []const u8, limit: usize) resolve.Error![]const Symbol {
    var out: std.ArrayList(Symbol) = .empty;
    for (files) |file| {
        const tree = try r.itemTree(file);
        // 有成员匹配时才取：没有匹配的文件不必计算摘要
        var summaries: ?*const syntax.ItemSummaries.Summaries = null;
        for (tree.items, 0..) |item, i| {
            switch (item.kind) {
                .@"test", .@"comptime" => continue,
                else => {},
            }
            const name = item.name orelse continue;
            const rank = match(name, query) orelse continue;
            const s = summaries orelse try r.ctx.get(syntax.ItemSummaries, file);
            summaries = s;
            const at = s.items[i];
            if (at.name_len == 0) continue;
            const container = tree.containers[item.container];
            try out.append(r.arena, .{
                .name = ast.identName(name),
                .kind = document_symbol.symbolKind(tree, @intCast(i), container.kind),
                .container = if (container.parent_item) |p| tree.items[p].name else null,
                .file = file,
                .start = at.name_offset,
                .end = at.name_offset + at.name_len,
                .rank = rank,
            });
        }
    }
    std.mem.sort(Symbol, out.items, {}, struct {
        fn lt(_: void, a: Symbol, b: Symbol) bool {
            if (a.rank != b.rank) return a.rank < b.rank;
            if (a.name.len != b.name.len) return a.name.len < b.name.len;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return out.items[0..@min(out.items.len, limit)];
}

/// 匹配等级：0 完全相同，1 前缀，2 子序列；不匹配为 null（均忽略大小写）
fn match(raw_name: []const u8, query: []const u8) ?u8 {
    const name = ast.identName(raw_name);
    if (std.ascii.eqlIgnoreCase(name, query)) return 0;
    if (std.ascii.startsWithIgnoreCase(name, query)) return 1;
    var i: usize = 0;
    for (name) |c| {
        if (i == query.len) break;
        if (std.ascii.toLower(c) == std.ascii.toLower(query[i])) i += 1;
    }
    return if (i == query.len) 2 else null;
}

test match {
    try std.testing.expectEqual(0, match("Foo", "foo"));
    try std.testing.expectEqual(1, match("ArrayList", "arr"));
    try std.testing.expectEqual(2, match("ArrayList", "al"));
    try std.testing.expectEqual(null, match("ArrayList", "la"));
    try std.testing.expectEqual(2, match("@\"a b\"", "ab"));
}

const testing = std.testing;
const World = @import("../names/resolve_test.zig").World;

/// 结果：「名字(容器):范围内的文本」以空格连接
fn describe(w: *World, file: FileId, text: []const u8, query: []const u8) ![]const u8 {
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    var out: std.ArrayList(u8) = .empty;
    for (try search(&r, &.{file}, query, std.math.maxInt(usize)), 0..) |s, i| {
        try testing.expectEqual(file, s.file);
        if (i > 0) try out.append(w.arena.allocator(), ' ');
        try out.print(w.arena.allocator(), "{s}({s}):{s}", .{ s.name, s.container orelse "-", text[s.start..s.end] });
    }
    return out.items;
}

test "search returns the name token of each matching declaration" {
    const text =
        \\pub const Point = struct { x: i32, @"p q": i32 };
        \\const Color = enum { red, purple };
        \\const U = union(enum) { pick: u8 };
        \\pub fn plot() void {}
        \\test "plot" {}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    try testing.expectEqualStrings(
        "p q(Point):@\"p q\" pick(U):pick plot(-):plot Point(-):Point purple(Color):purple",
        try describe(&w, file, text, "p"),
    );
    try testing.expectEqualStrings("", try describe(&w, file, text, "zzz"));
}

// 防止每次查询都为匹配的成员取语法树节点：文件数多于解析结果的缓存容量时，重复查询会重新解析大部分文件
test "repeated searches do not reparse files evicted from the parse cache" {
    const n = syntax.parse_lru + 16;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    var files: [n]FileId = undefined;
    @setEvalBranchQuota(100_000);
    inline for (&files, 0..) |*f, i| {
        f.* = (try w.add(std.fmt.comptimePrint("/p/f{d}.zig", .{i}), "pub fn alpha() void {}\npub const Abc = struct { a: u32 };\n")).file;
    }
    const Run = struct {
        fn run(world: *World, scope: []const FileId) !usize {
            var ctx = world.db.beginRead(world.arena.allocator());
            defer ctx.end();
            var r: Resolver = .{ .ctx = &ctx, .arena = world.arena.allocator() };
            return (try search(&r, scope, "a", std.math.maxInt(usize))).len;
        }
    };
    try testing.expectEqual(3 * n, try Run.run(&w, &files));
    try testing.expect(w.db.trySweep());
    const parses = w.db.executions(syntax.ParseFile);
    try testing.expectEqual(3 * n, try Run.run(&w, &files));
    try testing.expectEqual(parses, w.db.executions(syntax.ParseFile));
    // 编辑一个文件后：只重新解析这一个
    _ = try w.add("/p/f0.zig", "pub fn alpha() void {\n    _ = 1;\n}\npub const Abc = struct { a: u32 };\n");
    try testing.expectEqual(3 * n, try Run.run(&w, &files));
    try testing.expectEqual(parses + 1, w.db.executions(syntax.ParseFile));
}
