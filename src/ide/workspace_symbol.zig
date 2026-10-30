//! workspace/symbol: fuzzy-matches declarations by name in the ItemTrees of the project files.
//!
//! Matching rule: the query string (ignoring case) is a subsequence of the name. Exact matches
//! come first, then prefixes, then subsequences; ties are broken by name length.

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
    /// Name of the enclosing container: the declaration it is the value of, or the local constant
    /// it initializes; null at the top level of a file and for anonymous containers
    container: ?[]const u8,
    file: FileId,
    start: u32,
    end: u32,
    rank: u8,
};

/// Returns at most `limit` symbols (the best ones after sorting by match rank). Name positions
/// come from `ItemSummaries` (never evicted): when there are more project files than the parse
/// result cache holds, repeated queries do not need to reparse every file
pub fn search(r: *Resolver, files: []const FileId, query: []const u8, limit: usize) resolve.Error![]const Symbol {
    var out: std.ArrayList(Symbol) = .empty;
    for (files) |file| {
        const tree = try r.itemTree(file);
        // Fetched only when a member matches: files without matches need not compute summaries
        var summaries: ?*const syntax.ItemSummaries.Summaries = null;
        for (tree.items, 0..) |item, i| {
            switch (item.kind) {
                .@"test", .@"comptime", .zon => continue,
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
                .name = try document_symbol.symbolName(r.arena, ast.identName(name)),
                .kind = document_symbol.symbolKind(tree, @intCast(i), container.kind),
                .container = container.name orelse if (container.is_value) tree.items[container.parent_item.?].name else null,
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

/// Match rank: 0 exact, 1 prefix, 2 subsequence; null when there is no match (all ignoring case)
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

/// The results as "name(container):text in range", joined by spaces
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

test "blank names are shown in their quoted form" {
    const text = "pub fn @\" \"() void {}\nconst @\"\" = 1;\n";
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    try testing.expectEqualStrings("@\"\"(-):@\"\" @\" \"(-):@\" \"", try describe(&w, file, text, ""));
}

test "container names are the declarations that bind the containers" {
    // A member of a container nested in another declaration is not named after that declaration
    const text =
        \\const std = @import("std");
        \\const List = std.ArrayList(struct { a: u8 });
        \\fn helper() void { const A = struct { a1: u8 }; _ = A; }
        \\test "sort" { const S = struct { fn lessThan() void {} }; _ = S; }
        \\pub fn Wrapper(comptime T: type) type { const Impl = struct { inner: T }; return struct { impl: Impl }; }
        \\fn take(opts: struct { verbose: bool = false }) void { _ = opts; }
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    for ([_][2][]const u8{
        .{ "a", "a(-):a" },
        .{ "a1", "a1(A):a1" },
        .{ "lessThan", "lessThan(S):lessThan" },
        .{ "inner", "inner(Impl):inner" },
        .{ "impl", "impl(Wrapper):impl" },
        .{ "verbose", "verbose(-):verbose" },
    }) |c| {
        var results = std.mem.splitScalar(u8, try describe(&w, file, text, c[0]), ' ');
        try testing.expectEqualStrings(c[1], results.first());
    }
}

// Guards against fetching syntax tree nodes for matching members on every query: when there are
// more files than the parse result cache holds, repeated queries would reparse most files
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
    // After editing one file, only that file is reparsed
    _ = try w.add("/p/f0.zig", "pub fn alpha() void {\n    _ = 1;\n}\npub const Abc = struct { a: u32 };\n");
    try testing.expectEqual(3 * n, try Run.run(&w, &files));
    try testing.expectEqual(parses + 1, w.db.executions(syntax.ParseFile));
}
