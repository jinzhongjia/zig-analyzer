//! File index: the identifier names that appear in a file, and (`ImportStrings`) its `@import`
//! strings.
//!
//! Find references, call-site seeding, and workspace symbol use it to pre-filter candidate files,
//! then resolve precisely within the candidates.
//! Names have the `@"..."` quotes removed. Depends only on the syntax tree: when the content is
//! unchanged, downstream is not recomputed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const Vfs = @import("../base/Vfs.zig");
const syntax = @import("queries.zig");
const ast = @import("ast.zig");
const SyntaxNode = ast.SyntaxNode;
const deepEql = @import("../util/deep_eql.zig").deepEql;
const mem = @import("../util/mem.zig");

const FileIndex = @This();

arena: std.heap.ArenaAllocator.State,
/// Deduplicated and sorted lexicographically
names: []const []const u8,

pub fn contains(index: *const FileIndex, name: []const u8) bool {
    return std.sort.binarySearch([]const u8, index.names, name, struct {
        fn order(n: []const u8, x: []const u8) std.math.Order {
            return std.mem.order(u8, n, x);
        }
    }.order) != null;
}

pub fn build(gpa: Allocator, root: SyntaxNode) Allocator.Error!FileIndex {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer names.deinit(gpa);
    try walk(gpa, a, root, &names);

    const sorted = try a.alloc([]const u8, names.count());
    for (names.keys(), sorted) |k, *s| s.* = try a.dupe(u8, k);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return .{ .arena = arena.state, .names = sorted };
}

fn walk(gpa: Allocator, a: Allocator, node: SyntaxNode, names: *std.StringArrayHashMapUnmanaged(void)) Allocator.Error!void {
    var it = node.children();
    while (it.next()) |e| switch (e) {
        .token => |t| if (t.kind == .identifier) try names.put(gpa, try ast.identNameAlloc(a, t.text), {}),
        .node => |c| try walk(gpa, a, c, names),
    };
}

/// The strings of `@import("...")` in the tree (decoded), in order of appearance, allocated in `a`
pub fn importStrings(a: Allocator, root: SyntaxNode) Allocator.Error![]const []const u8 {
    var imports: std.ArrayList([]const u8) = .empty;
    try walkImports(a, root, &imports);
    return imports.items;
}

fn walkImports(a: Allocator, node: SyntaxNode, imports: *std.ArrayList([]const u8)) Allocator.Error!void {
    if (ast.cast(ast.BuiltinCall, node)) |call| if (call.name()) |n| if (std.mem.eql(u8, n.text, "@import")) {
        var args = call.args();
        if (args.next()) |arg| if (arg.firstToken()) |t| if (t.kind == .string_literal) {
            if (std.zig.string_literal.parseAlloc(a, t.text)) |str| try imports.append(a, str) else |_| {}
        };
    };
    var it = node.children();
    while (it.nextNode()) |c| try walkImports(a, c, imports);
}

pub fn deinit(index: *FileIndex, gpa: Allocator) void {
    var arena = index.arena.promote(gpa);
    arena.deinit();
    index.* = undefined;
}

pub const Query = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = *const FileIndex;

    pub fn bytes(v: Value) usize {
        return @sizeOf(FileIndex) + mem.arenaBytes(v.arena);
    }

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        const parse = try ctx.get(syntax.ParseFile, file);
        const gpa = ctx.db.gpa;
        const result = try gpa.create(FileIndex);
        errdefer gpa.destroy(result);
        result.* = try build(gpa, parse.rootNode());
        return result;
    }

    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a.names, b.names);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        const i: *FileIndex = @constCast(v.*);
        i.deinit(gpa);
        gpa.destroy(i);
    }
};

/// The `@import` strings of a file (see `importStrings`). Kept apart from `Query`: the module
/// graph and the uses that follow imports read them after every edit of a file, and collecting the
/// names as well would cost more than twice as much
pub const ImportStrings = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = *const Strings;

    pub const Strings = struct {
        arena: std.heap.ArenaAllocator.State,
        imports: []const []const u8,
    };

    pub fn bytes(v: Value) usize {
        return @sizeOf(Strings) + mem.arenaBytes(v.arena);
    }

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        const parse = try ctx.get(syntax.ParseFile, file);
        const gpa = ctx.db.gpa;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const imports = try importStrings(arena.allocator(), parse.rootNode());
        const result = try gpa.create(Strings);
        result.* = .{ .arena = undefined, .imports = imports };
        result.arena = arena.state;
        return result;
    }

    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a.imports, b.imports);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        const s: *Strings = @constCast(v.*);
        var arena = s.arena.promote(gpa);
        arena.deinit();
        gpa.destroy(s);
    }
};

test build {
    const Parse = @import("Parse.zig");
    const p = try Parse.create(std.testing.allocator,
        \\const std = @import("std");
        \\const lib = @import("lib/a.zig");
        \\fn f(@"x y": u8, z: u8) void { _ = .{ @"x y", z, std.mem }; }
    , .zig);
    defer p.destroy();
    var index = try build(std.testing.allocator, p.rootNode());
    defer index.deinit(std.testing.allocator);
    try std.testing.expect(index.contains("mem"));
    try std.testing.expect(index.contains("x y"));
    try std.testing.expect(!index.contains("import"));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const imports = try importStrings(arena.allocator(), p.rootNode());
    try std.testing.expectEqual(2, imports.len);
    try std.testing.expectEqualStrings("lib/a.zig", imports[1]);
}
