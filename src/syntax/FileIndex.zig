//! File index: the identifier names that appear in a file, and (`ImportStrings`) its `@import`
//! strings.
//!
//! Find references, call-site seeding, and workspace symbol use it to pre-filter candidate files,
//! then resolve precisely within the candidates.
//! Names have the `@"..."` quotes removed; only their hashes are kept. Depends only on the syntax
//! tree: when the content is unchanged, downstream is not recomputed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const Vfs = @import("../base/Vfs.zig");
const syntax = @import("queries.zig");
const ast = @import("ast.zig");
const SyntaxNode = ast.SyntaxNode;
const deepEql = @import("../util/deep_eql.zig").deepEql;
const mem = @import("../util/mem.zig");
const Parse = @import("Parse.zig");
const green = @import("green.zig");

const FileIndex = @This();

arena: std.heap.ArenaAllocator.State,
/// Deduplicated and sorted hashes of the identifier names (see `nameHash`)
hashes: []const u64,

/// Hash of an identifier name. A collision only adds a file to a pre-filter, whose files are then
/// checked precisely.
pub const NameHash = u64;

pub fn nameHash(name: []const u8) NameHash {
    return std.hash.Wyhash.hash(0, name);
}

pub fn contains(index: *const FileIndex, name: []const u8) bool {
    const hash = nameHash(name);
    return std.sort.binarySearch(u64, index.hashes, hash, struct {
        fn order(key: u64, h: u64) std.math.Order {
            return std.math.order(key, h);
        }
    }.order) != null;
}

pub fn build(gpa: Allocator, root: SyntaxNode) Allocator.Error!FileIndex {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var hashes: std.AutoArrayHashMapUnmanaged(u64, void) = .empty;
    defer hashes.deinit(gpa);
    try walk(gpa, a, root, &hashes);

    const sorted = try a.dupe(u64, hashes.keys());
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
    return .{ .arena = arena.state, .hashes = sorted };
}

fn walk(gpa: Allocator, a: Allocator, node: SyntaxNode, hashes: *std.AutoArrayHashMapUnmanaged(u64, void)) Allocator.Error!void {
    var it = node.children();
    while (it.next()) |e| switch (e) {
        .token => |t| if (t.kind == .identifier) try hashes.put(gpa, nameHash(try ast.identNameAlloc(a, t.text)), {}),
        .node => |c| try walk(gpa, a, c, hashes),
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

/// An `@import("...")` with its decoded string and the range of the string literal
pub const ImportSite = struct { name: []const u8, start: u32, end: u32 };

/// The `@import("...")` calls in the tree, in order of appearance, allocated in `a`
pub fn importSites(a: Allocator, root: SyntaxNode) Allocator.Error![]const ImportSite {
    var sites: std.ArrayList(ImportSite) = .empty;
    try walkImportSites(a, root, &sites);
    return sites.items;
}

fn walkImportSites(a: Allocator, node: SyntaxNode, sites: *std.ArrayList(ImportSite)) Allocator.Error!void {
    if (ast.cast(ast.BuiltinCall, node)) |call| if (call.name()) |n| if (std.mem.eql(u8, n.text, "@import")) {
        var args = call.args();
        if (args.next()) |arg| if (arg.firstToken()) |t| if (t.kind == .string_literal) {
            const range = t.range();
            if (std.zig.string_literal.parseAlloc(a, t.text)) |str| try sites.append(a, .{ .name = str, .start = range.start, .end = range.end }) else |_| {}
        };
    };
    var it = node.children();
    while (it.nextNode()) |c| try walkImportSites(a, c, sites);
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
        // Equal hash arrays answer every membership query the same way, so keeping the old value
        // when the hashes match is exact: a name set that changed to the same hashes (a collision)
        // is indistinguishable to the consumers, which only test membership by hash
        return std.mem.eql(u64, a.hashes, b.hashes);
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
        /// Per child node of the root, the end of the strings found in it
        node_ends: []const u32,
        /// Id of a parse result whose tree has these strings in these nodes (`Parse.id`): the
        /// tree they were collected from or one with the same strings in each node; not compared
        /// by `eql`
        basis: std.atomic.Value(u64) = .init(0),
    };

    pub fn bytes(v: Value) usize {
        return @sizeOf(Strings) + mem.arenaBytes(v.arena);
    }

    /// After an incremental parse, copies the strings of the child nodes of the root the new tree
    /// shares with the tree `prev` describes
    pub fn computeIncremental(ctx: anytype, file: Key, prev: ?Value) engine.Error!Value {
        const parse = try ctx.get(syntax.ParseFile, file);
        const old: ?*const Parse = if (prev) |p| parse.inChain(p.basis.load(.monotonic)) else null;
        const result = try collect(ctx.db.gpa, parse.rootNode(), if (old) |o| .{ .prev = prev.?, .old_root = o.rootNode() } else null);
        result.basis.store(parse.id, .monotonic);
        if (prev) |p| if (eql(p, result) and std.mem.eql(u32, p.node_ends, result.node_ends)) {
            @constCast(p).basis.store(parse.id, .monotonic);
        };
        return result;
    }

    pub const Reuse = struct {
        prev: *const Strings,
        /// The root of the tree `prev` describes; must still be alive
        old_root: SyntaxNode,
    };

    /// The strings of `root` (see `importStrings`). With `reuse`, those of each child node of the
    /// root that is the same green node as in `reuse.old_root` are copied
    pub fn collect(gpa: Allocator, root: SyntaxNode, reuse: ?Reuse) Allocator.Error!*Strings {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var old_nodes: std.AutoHashMapUnmanaged(*const green.GreenNode, [2]u32) = .empty;
        defer old_nodes.deinit(gpa);
        if (reuse) |r| {
            var it = r.old_root.children();
            var k: usize = 0;
            var start: u32 = 0;
            while (it.nextNode()) |n| : (k += 1) {
                if (k == r.prev.node_ends.len) break;
                try old_nodes.put(gpa, n.green, .{ start, r.prev.node_ends[k] });
                start = r.prev.node_ends[k];
            }
        }
        var imports: std.ArrayList([]const u8) = .empty;
        var node_ends: std.ArrayList(u32) = .empty;
        var it = root.children();
        while (it.nextNode()) |n| {
            if (old_nodes.get(n.green)) |range| {
                for (reuse.?.prev.imports[range[0]..range[1]]) |str| try imports.append(a, try a.dupe(u8, str));
            } else try walkImports(a, n, &imports);
            try node_ends.append(a, @intCast(imports.items.len));
        }
        const result = try gpa.create(Strings);
        result.* = .{ .arena = undefined, .imports = imports.items, .node_ends = node_ends.items };
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

test "build stores the sorted unique hashes of the names" {
    const p = try Parse.create(std.testing.allocator,
        \\const a = 1;
        \\const b = a;
        \\const c = a;
    , .zig);
    defer p.destroy();
    var index = try build(std.testing.allocator, p.rootNode());
    defer index.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), index.hashes.len);
    try std.testing.expect(std.sort.isSorted(u64, index.hashes, {}, std.sort.asc(u64)));
    try std.testing.expect(index.contains("a"));
    try std.testing.expect(index.contains("c"));
    try std.testing.expect(!index.contains("d"));
}

test importSites {
    const text =
        \\const std = @import("std");
        \\const dep = @import("d\x65p");
    ;
    const p = try Parse.create(std.testing.allocator, text, .zig);
    defer p.destroy();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const sites = try importSites(arena.allocator(), p.rootNode());
    try std.testing.expectEqual(2, sites.len);
    try std.testing.expectEqualStrings("dep", sites[1].name);
    try std.testing.expectEqualStrings("\"d\\x65p\"", text[sites[1].start..sites[1].end]);
}
