//! String literals of a file: the decoded values outside test names, each with the offset of its
//! first occurrence in scan order.
//!
//! Renaming a declaration or a field refuses when its name appears as a string literal (`@field`,
//! `@hasDecl`, serialization refer to names by string, and the rename cannot update them), and
//! error names may be compared with a string. Unlike `FileIndex`, this keeps the decoded values,
//! so the check reads it instead of parsing and decoding the file again.

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const Vfs = @import("../base/Vfs.zig");
const Parse = @import("Parse.zig");
const queries = @import("queries.zig");
const ast = @import("ast.zig");
const mem = @import("../util/mem.zig");

const StringLiterals = @This();

/// One decoded value and the offset of its first occurrence
pub const Literal = struct { value: []const u8, offset: u32 };

const List = struct {
    arena: std.heap.ArenaAllocator.State,
    /// Deduplicated and sorted by value
    literals: []const Literal,

    /// Offset of the first occurrence of `name`, or null when it does not appear
    pub fn offsetOf(l: *const List, name: []const u8) ?u32 {
        var lo: usize = 0;
        var hi: usize = l.literals.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, l.literals[mid].value, name)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return l.literals[mid].offset,
            }
        }
        return null;
    }

    fn deinit(l: *List, gpa: Allocator) void {
        var arena = l.arena.promote(gpa);
        arena.deinit();
        l.* = undefined;
    }
};

/// The literals of `root`. Trivia does not end a multiline literal: the compiler joins its lines
/// across whitespace and comments
pub fn build(gpa: Allocator, root: ast.SyntaxNode) Allocator.Error!List {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var multiline: std.ArrayList(u8) = .empty;
    defer multiline.deinit(gpa);
    var values: std.StringHashMapUnmanaged(u32) = .empty;
    defer values.deinit(gpa);
    var scan: Scan = .{
        .arena = arena.allocator(),
        .scratch = &scratch,
        .multiline = &multiline,
        .values = &values,
        .gpa = gpa,
    };
    try scan.scan(root);
    try scan.flush();

    const literals = try arena.allocator().alloc(Literal, values.count());
    var it = values.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) literals[i] = .{ .value = e.key_ptr.*, .offset = e.value_ptr.* };
    std.mem.sort(Literal, literals, {}, struct {
        fn lt(_: void, x: Literal, y: Literal) bool {
            return std.mem.lessThan(u8, x.value, y.value);
        }
    }.lt);
    return .{ .arena = arena.state, .literals = literals };
}

const Scan = struct {
    arena: Allocator,
    scratch: *std.heap.ArenaAllocator,
    /// Decoded value of the multiline literal being read
    multiline: *std.ArrayList(u8),
    multiline_start: u32 = 0,
    in_multiline: bool = false,
    values: *std.StringHashMapUnmanaged(u32),
    gpa: Allocator,

    fn scan(s: *Scan, node: ast.SyntaxNode) Allocator.Error!void {
        // A direct token child of a test declaration is its name, which describes the test and
        // cannot name a declaration
        const test_name = node.kind() == .test_decl;
        var it = node.children();
        while (it.next()) |e| switch (e) {
            .token => |t| try s.token(t, test_name),
            .node => |c| try s.scan(c),
        };
    }

    fn token(s: *Scan, t: ast.SyntaxToken, test_name: bool) Allocator.Error!void {
        switch (t.kind) {
            .whitespace, .line_comment, .unknown => return,
            .multiline_string_literal_line => {
                if (s.in_multiline) {
                    try s.multiline.append(s.gpa, '\n');
                } else {
                    s.in_multiline = true;
                    s.multiline_start = t.offset;
                    s.multiline.clearRetainingCapacity();
                }
                // The token starts with `\\`; the rest is the line's contents
                try s.multiline.appendSlice(s.gpa, t.text[2..]);
                return;
            },
            else => {},
        }
        try s.flush();
        if (t.kind != .string_literal or test_name) return;
        if (t.text.len < 2) return;
        if (std.mem.indexOfScalar(u8, t.text, '\\') == null) {
            try s.add(t.text[1 .. t.text.len - 1], t.offset);
            return;
        }
        _ = s.scratch.reset(.retain_capacity);
        const value = std.zig.string_literal.parseAlloc(s.scratch.allocator(), t.text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidLiteral => return,
        };
        try s.add(value, t.offset);
    }

    fn flush(s: *Scan) Allocator.Error!void {
        if (!s.in_multiline) return;
        s.in_multiline = false;
        try s.add(s.multiline.items, s.multiline_start);
    }

    fn add(s: *Scan, value: []const u8, offset: u32) Allocator.Error!void {
        if (s.values.contains(value)) return;
        try s.values.put(s.gpa, try s.arena.dupe(u8, value), offset);
    }
};

pub const Query = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = *const List;

    pub fn bytes(v: Value) usize {
        return @sizeOf(List) + mem.arenaBytes(v.arena);
    }

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        const parse = try ctx.get(queries.ParseFile, file);
        const gpa = ctx.db.gpa;
        const result = try gpa.create(List);
        errdefer gpa.destroy(result);
        result.* = try build(gpa, parse.rootNode());
        return result;
    }

    /// The offsets are part of the value: after an edit that shifts literals without changing
    /// them, keeping the old value would report the old position
    pub fn eql(a: Value, b: Value) bool {
        if (a.literals.len != b.literals.len) return false;
        for (a.literals, b.literals) |x, y| {
            if (x.offset != y.offset or !std.mem.eql(u8, x.value, y.value)) return false;
        }
        return true;
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        const l: *List = @constCast(v.*);
        l.deinit(gpa);
        gpa.destroy(l);
    }
};

test "StringLiterals: deduplicated by value, sorted, first occurrence" {
    const text =
        \\const a = "b";
        \\const c = "a";
        \\const d = "b";
        \\const e = "a\x62";
        \\const f =
        \\    \\b
        \\;
        \\test "b" {
        \\    _ = "b";
        \\}
        \\test "onlyInName" {}
    ;
    const parse = try Parse.create(std.testing.allocator, text, .zig);
    defer parse.destroy();
    var list = try build(std.testing.allocator, parse.rootNode());
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqual(3, list.literals.len);
    try std.testing.expectEqualStrings("a", list.literals[0].value);
    try std.testing.expectEqualStrings("ab", list.literals[1].value);
    try std.testing.expectEqualStrings("b", list.literals[2].value);
    // The test name does not count; the literal in its body does
    try std.testing.expectEqual(@as(?u32, @intCast(std.mem.indexOf(u8, text, "\"a\"").?)), list.offsetOf("a"));
    try std.testing.expectEqual(@as(?u32, @intCast(std.mem.indexOf(u8, text, "\"b\"").?)), list.offsetOf("b"));
    try std.testing.expectEqual(@as(?u32, null), list.offsetOf("c"));
    // A value that appears only as a test name is not a string reference
    try std.testing.expectEqual(@as(?u32, null), list.offsetOf("onlyInName"));
}
