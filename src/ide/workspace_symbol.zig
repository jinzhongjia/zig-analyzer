//! workspace/symbol: fuzzy-matches declarations by name in the ItemTrees of the project files.
//!
//! Matching rule: the query string (ignoring case) is a subsequence of the name. Exact matches
//! come first, then prefixes, then subsequences; ties are broken by name length, then name, then
//! the order the scan found them.

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

/// Returns the best `limit` symbols by match rank, name length, and name, and every exact match
/// beyond them: same-named symbols tie on the name alone, so the limit cannot choose among them
/// and typing more of the name cannot select a dropped one. Matches with equal rank, name length,
/// and name are ordered by their position in the scan, as sorting every match and truncating does.
/// Only the selected matches get a `Symbol`: a short query matches much of the project, and the
/// limit drops most matches. Name positions come from `ItemSummaries` (never evicted): when there
/// are more project files than the parse result cache holds, repeated queries do not need to
/// reparse every file
pub fn search(r: *Resolver, files: []const FileId, query: []const u8, limit: usize) resolve.Error![]const Symbol {
    var top: Top = .{ .arena = r.arena, .limit = limit };
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
            try top.add(.{
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
    const selected = try top.selected();
    const out = try r.arena.alloc(Symbol, selected.len);
    for (selected, out) |m, *s| s.* = .{
        .name = m.name,
        .kind = m.kind,
        .container = m.container,
        .file = m.file,
        .start = m.start,
        .end = m.end,
        .rank = m.rank,
    };
    return out;
}

/// A matched declaration with everything its `Symbol` needs, taken during the scan so that the
/// selected matches need not fetch their tree and summaries again. A match the limit drops is not
/// stored.
const Match = struct {
    name: []const u8,
    container: ?[]const u8,
    kind: types.SymbolKind,
    file: FileId,
    start: u32,
    end: u32,
    rank: u8,
    /// Position in the scan; breaks ties so that equal keys keep the order a stable sort of every
    /// match gives
    order: u32 = 0,
};

/// Whether `a` sorts before `b`: match rank, then name length, then name, then scan order
fn before(_: void, a: Match, b: Match) bool {
    if (a.rank != b.rank) return a.rank < b.rank;
    if (a.name.len != b.name.len) return a.name.len < b.name.len;
    const cmp = std.mem.order(u8, a.name, b.name);
    if (cmp != .eq) return cmp == .lt;
    return a.order < b.order;
}

/// The matches selected so far: every exact match and the best `limit` others. The others live in
/// a max-heap; a match that does not beat the worst selected one is dropped without being stored.
const Top = struct {
    arena: std.mem.Allocator,
    limit: usize,
    exact: std.ArrayList(Match) = .empty,
    rest: std.PriorityQueue(Match, void, worstFirst) = .empty,
    order: u32 = 0,

    fn add(t: *Top, candidate: Match) std.mem.Allocator.Error!void {
        var m = candidate;
        m.order = t.order;
        t.order += 1;
        if (m.rank == 0) return t.exact.append(t.arena, m);
        if (t.limit == 0) return;
        if (t.rest.count() >= t.limit) {
            if (!before({}, m, t.rest.peek().?)) return;
            _ = t.rest.pop();
        }
        try t.rest.push(t.arena, m);
    }

    /// The selected matches in sort order: all exact matches and as many of the others as the
    /// limit leaves room for
    fn selected(t: *Top) std.mem.Allocator.Error![]const Match {
        std.mem.sort(Match, t.exact.items, {}, before);
        const room = if (t.limit > t.exact.items.len) t.limit - t.exact.items.len else 0;
        const n = @min(room, t.rest.count());
        // The heap is not used again, so its storage is sorted in place
        std.mem.sort(Match, t.rest.items, {}, before);
        const out = try t.arena.alloc(Match, t.exact.items.len + n);
        @memcpy(out[0..t.exact.items.len], t.exact.items);
        @memcpy(out[t.exact.items.len..], t.rest.items[0..n]);
        return out;
    }

    /// Reverse of `before`: the worst match has the priority, so `peek` returns the one a new
    /// match has to beat
    fn worstFirst(_: void, a: Match, b: Match) std.math.Order {
        return if (before({}, a, b)) .gt else if (before({}, b, a)) .lt else .eq;
    }
};

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

// The selection must keep the entries a sort of every match followed by truncation keeps: with
// many matches sharing a whole key, only the scan-order tie-break decides which survive
test "the selection keeps what sorting every match and truncating keeps" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var all: std.ArrayList(Match) = .empty;
    for (0..900) |i| {
        // Three names that differ in length and three ranks: a whole key repeats often
        const name = switch (i % 3) {
            0 => "same",
            1 => "same1",
            else => "sa",
        };
        try all.append(a, .{
            .name = name,
            .container = if (i % 2 == 0) "C" else null,
            .kind = .Function,
            .file = @fromBackingInt(@intCast(i % 7)),
            .start = @intCast(i),
            .end = @intCast(i + 1),
            .rank = @intCast(i % 3),
            .order = @intCast(i),
        });
    }
    // The sort of every match and the truncation applied to it, which the selection must match:
    // `std.mem.sort` is stable, so equal keys keep the scan order
    const sorted = try a.dupe(Match, all.items);
    std.mem.sort(Match, sorted, {}, struct {
        fn lt(_: void, x: Match, y: Match) bool {
            if (x.rank != y.rank) return x.rank < y.rank;
            if (x.name.len != y.name.len) return x.name.len < y.name.len;
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    for ([_]usize{ 0, 1, 2, 3, 7, 16, 255, 256, 257, 450, 899, 900, std.math.maxInt(usize) }) |limit| {
        var top: Top = .{ .arena = a, .limit = limit };
        for (all.items) |m| try top.add(m);
        const got = try top.selected();
        var kept = @min(sorted.len, limit);
        while (kept < sorted.len and sorted[kept].rank == 0) kept += 1;
        try testing.expectEqual(kept, got.len);
        for (got, sorted[0..kept]) |x, y| {
            try testing.expectEqual(y.file, x.file);
            try testing.expectEqual(y.kind, x.kind);
            try testing.expectEqual(y.start, x.start);
            try testing.expectEqual(y.end, x.end);
            try testing.expectEqual(y.rank, x.rank);
            try testing.expectEqual(y.order, x.order);
            if (y.container) |c| try testing.expectEqualStrings(c, x.container.?) else try testing.expectEqual(null, x.container);
            try testing.expectEqualStrings(y.name, x.name);
        }
    }
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

test "the limit keeps every exact match" {
    // Same-named symbols past the limit would be unreachable by any query
    var text: std.ArrayList(u8) = .empty;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const a = w.arena.allocator();
    for (0..300) |i| try text.print(a, "pub const Kind{d:0>3} = struct {{ pub fn init() void {{}} }};\npub fn initAll{d}() void {{}}\n", .{ i, i });
    const file = (try w.add("/p/main.zig", text.items)).file;
    var ctx = w.db.beginRead(a);
    defer ctx.end();
    var r: Resolver = .{ .ctx = &ctx, .arena = a };
    const found = try search(&r, &.{file}, "init", 256);
    try testing.expectEqual(300, found.len);
    var last = false;
    for (found) |s| {
        try testing.expectEqualStrings("init", s.name);
        if (std.mem.eql(u8, s.container.?, "Kind299")) last = true;
    }
    try testing.expect(last);
    // Prefix matches are still cut at the limit
    try testing.expectEqual(10, (try search(&r, &.{file}, "initAll", 10)).len);
}

test "equal-key matches are kept in scan order" {
    // Every declaration of a name in another file shares the whole key, so the limit decides
    // by scan order, as sorting every match does
    const n = 40;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const a = w.arena.allocator();
    var files: std.ArrayList(FileId) = .empty;
    for (0..n) |i| {
        const file = (try w.addNative(try std.fmt.allocPrint(a, "/p/f{d}.zig", .{i}), "pub fn dup() void {}\npub fn dupA() void {}\npub fn dupB() void {}\npub fn durp() void {}\n")).file;
        try files.append(a, file);
    }
    var ctx = w.db.beginRead(a);
    defer ctx.end();
    var r: Resolver = .{ .ctx = &ctx, .arena = a };
    const all = try search(&r, files.items, "dup", std.math.maxInt(usize));
    try testing.expectEqual(4 * n, all.len);
    // Exact matches first, then prefixes by name, then subsequences, each group in file order
    for (all, 0..) |s, i| {
        const rank: u8 = if (i < n) 0 else if (i < 3 * n) 1 else 2;
        try testing.expectEqual(rank, s.rank);
        try testing.expectEqual(files.items[i % n], s.file);
    }
    for ([_]usize{ 0, 1, 10, n, n + 1, 2 * n, 3 * n, 3 * n + 1, all.len - 1, all.len, std.math.maxInt(usize) }) |limit| {
        const found = try search(&r, files.items, "dup", limit);
        var kept = @min(all.len, limit);
        while (kept < all.len and all[kept].rank == 0) kept += 1;
        try testing.expectEqual(kept, found.len);
        for (found, all[0..kept]) |x, y| {
            try testing.expectEqual(y.file, x.file);
            try testing.expectEqual(y.kind, x.kind);
            try testing.expectEqual(y.rank, x.rank);
            try testing.expectEqual(y.start, x.start);
            try testing.expectEqual(y.end, x.end);
            if (y.container) |c| try testing.expectEqualStrings(c, x.container.?) else try testing.expectEqual(null, x.container);
            try testing.expectEqualStrings(y.name, x.name);
        }
    }
}

test "the selection orders by the rendered symbol name" {
    // A blank name is rendered as `@"..."`, which is longer than the decoded name, so the rendered
    // name decides which matches the limit keeps, as sorting every match does
    const text =
        \\pub fn a() void {}
        \\pub fn abc() void {}
        \\pub fn @" "() void {}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    const a = w.arena.allocator();
    for ([_]struct { limit: usize, expected: []const u8 }{
        .{ .limit = 1, .expected = "a" },
        .{ .limit = 2, .expected = "a abc" },
        .{ .limit = 3, .expected = "a abc @\" \"" },
        .{ .limit = 4, .expected = "a abc @\" \"" },
    }) |c| {
        var names: std.ArrayList([]const u8) = .empty;
        for (try search(&r, &.{file}, "", c.limit)) |s| try names.append(a, s.name);
        try testing.expectEqualStrings(c.expected, try std.mem.join(a, " ", names.items));
    }
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
