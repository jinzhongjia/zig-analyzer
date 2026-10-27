//! Error set declarations `error{ ... }` in a file: each member's name, position, and doc comment.
//!
//! Go-to-definition for `error.Foo` searches for declarations in several files along imports;
//! repeated lookups read from here instead of reparsing those files.
//! The value is small and never evicted.

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const Vfs = @import("../base/Vfs.zig");
const syntax = @import("queries.zig");
const ast = @import("ast.zig");
const SyntaxNode = ast.SyntaxNode;
const deepEql = @import("../util/deep_eql.zig").deepEql;
const mem = @import("../util/mem.zig");

const ErrorSets = @This();

arena: std.heap.ArenaAllocator.State,
/// In source order
sets: []const Set,

pub const Set = struct {
    /// In source order
    members: []const Member,
};

pub const Member = struct {
    /// With the `@"..."` quotes removed
    name: []const u8,
    /// Start and end positions of the name token
    start: u32,
    end: u32,
    /// Doc comment immediately preceding the member (`///` and one following space removed,
    /// lines joined with newlines)
    doc: ?[]const u8,
};

pub fn build(gpa: Allocator, root: SyntaxNode) Allocator.Error!ErrorSets {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var sets: std.ArrayList(Set) = .empty;
    try walk(a, root, &sets);
    return .{ .arena = arena.state, .sets = sets.items };
}

fn walk(a: Allocator, node: SyntaxNode, sets: *std.ArrayList(Set)) Allocator.Error!void {
    if (node.kind() == .error_set_decl) return sets.append(a, try collect(a, node));
    var it = node.children();
    while (it.nextNode()) |c| try walk(a, c, sets);
}

fn collect(a: Allocator, set: SyntaxNode) Allocator.Error!Set {
    var members: std.ArrayList(Member) = .empty;
    var doc: std.ArrayList(u8) = .empty;
    var it = set.children();
    while (it.next()) |el| {
        const t = switch (el) {
            .token => |t| t,
            .node => continue,
        };
        switch (t.kind) {
            .doc_comment => {
                var line = t.text["///".len..];
                if (std.mem.startsWith(u8, line, " ")) line = line[1..];
                if (doc.items.len != 0) try doc.append(a, '\n');
                try doc.appendSlice(a, std.mem.trimEnd(u8, line, "\r"));
            },
            .identifier => {
                // Consistent with FileIndex and HIR: decode the escapes in `@"..."`
                const name = try ast.identNameAlloc(a, t.text);
                try members.append(a, .{
                    .name = try a.dupe(u8, name),
                    .start = t.offset,
                    .end = t.offset + @as(u32, @intCast(t.text.len)),
                    .doc = if (doc.items.len != 0) try a.dupe(u8, doc.items) else null,
                });
                doc.clearRetainingCapacity();
            },
            else => {},
        }
    }
    return .{ .members = members.items };
}

pub fn deinit(sets: *ErrorSets, gpa: Allocator) void {
    var arena = sets.arena.promote(gpa);
    arena.deinit();
    sets.* = undefined;
}

pub const Query = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = *const ErrorSets;

    pub fn bytes(v: Value) usize {
        return @sizeOf(ErrorSets) + mem.arenaBytes(v.arena);
    }

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        const parse = try ctx.get(syntax.ParseFile, file);
        const gpa = ctx.db.gpa;
        const result = try gpa.create(ErrorSets);
        errdefer gpa.destroy(result);
        result.* = try build(gpa, parse.rootNode());
        return result;
    }

    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a.sets, b.sets);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        const s: *ErrorSets = @constCast(v.*);
        s.deinit(gpa);
        gpa.destroy(s);
    }
};

test build {
    const Parse = @import("Parse.zig");
    const text =
        \\const E = error{
        \\    /// first
        \\    /// line two
        \\    A,
        \\    @"b c",
        \\    @"\x45scaped",
        \\};
        \\fn f() error{C}!void {}
        \\
    ;
    const p = try Parse.create(std.testing.allocator, text);
    defer p.destroy();
    var sets = try build(std.testing.allocator, p.rootNode());
    defer sets.deinit(std.testing.allocator);
    try std.testing.expectEqual(2, sets.sets.len);
    const e = sets.sets[0].members;
    try std.testing.expectEqual(3, e.len);
    try std.testing.expectEqualStrings("A", e[0].name);
    try std.testing.expectEqualStrings("first\nline two", e[0].doc.?);
    try std.testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, text, "A,").?)), e[0].start);
    try std.testing.expectEqualStrings("b c", e[1].name);
    try std.testing.expectEqual(null, e[1].doc);
    // Escaped names are stored decoded; the range covers the token itself
    try std.testing.expectEqualStrings("Escaped", e[2].name);
    const escaped: u32 = @intCast(std.mem.indexOf(u8, text, "@\"\\x45scaped\"").?);
    try std.testing.expectEqual(escaped, e[2].start);
    try std.testing.expectEqual(escaped + "@\"\\x45scaped\"".len, e[2].end);
    try std.testing.expectEqualStrings("C", sets.sets[1].members[0].name);
}
