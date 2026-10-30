//! textDocument/selectionRange: expands level by level from the token at the cursor outward to the
//! syntax nodes containing it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const offsets = @import("../util/offsets.zig");
const tree = @import("../syntax/tree.zig");
const SyntaxNode = tree.SyntaxNode;
const kind_mod = @import("../syntax/kind.zig");
const isTrivia = kind_mod.isTrivia;

/// Maximum number of levels returned per position, keeping the innermost ones. Each level of
/// the `parent` chain nests one level deeper in JSON, and `std.json.Stringify` panics when
/// nesting exceeds 256 levels in builds with safety checks
pub const max_levels = 200;

pub fn selectionRanges(
    arena: Allocator,
    root: SyntaxNode,
    lines: offsets.LineIndex,
    enc: offsets.Encoding,
    positions: []const types.Position,
) Allocator.Error![]const types.SelectionRange {
    const result = try arena.alloc(types.SelectionRange, positions.len);
    for (positions, result) |pos, *out| {
        const offset = expansionOffset(root, @intCast(offsets.positionToOffset(lines.text, pos, enc)));
        const path = try root.coveringPath(arena, offset);

        // Built from the outside in; parent points to the outer level
        var chain: std.ArrayList(*types.SelectionRange) = .empty;
        var last: ?[2]u32 = null;
        for (path) |node| {
            const r = node.range();
            if (last != null and last.?[0] == r.start and last.?[1] == r.end) continue;
            last = .{ r.start, r.end };
            const sr = try arena.create(types.SelectionRange);
            sr.* = .{ .range = lines.range(r.start, r.end, enc), .parent = if (chain.items.len > 0) chain.items[chain.items.len - 1] else null };
            try chain.append(arena, sr);
        }
        if (root.tokenAtOffset(offset)) |t| {
            const r = t.range();
            if (!isTrivia(t.kind) and !(last != null and last.?[0] == r.start and last.?[1] == r.end)) {
                const sr = try arena.create(types.SelectionRange);
                sr.* = .{ .range = lines.range(r.start, r.end, enc), .parent = chain.items[chain.items.len - 1] };
                try chain.append(arena, sr);
            }
        }
        if (chain.items.len > max_levels) chain.items[chain.items.len - max_levels].parent = null;
        out.* = chain.items[chain.items.len - 1].*;
    }
    return result;
}

/// The offset whose token the selection starts from. Between two tokens the position belongs to
/// both; as in rust-analyzer, the token on the left is taken when it is a word (a name, keyword or
/// literal) and the right one is not, or when the right one is whitespace or a comment: with a bar
/// cursor right after `b` in `f(a, b)`, the selection starts at `b`, not at `)`
fn expansionOffset(root: SyntaxNode, offset: u32) u32 {
    if (offset == 0) return offset;
    const left = root.tokenAtOffset(offset - 1) orelse return offset;
    if (left.offset + left.text.len != offset or isTrivia(left.kind)) return offset;
    const right = root.tokenAtOffset(offset) orelse return left.offset;
    if (right.offset != offset) return offset;
    return if (isTrivia(right.kind) or (isWord(left) and !isWord(right))) left.offset else offset;
}

fn isWord(t: tree.SyntaxToken) bool {
    return switch (t.kind) {
        .identifier, .builtin, .number_literal, .char_literal, .string_literal => true,
        else => if (kind_mod.toTokenTag(t.kind)) |tag| std.mem.startsWith(u8, @tagName(tag), "keyword_") else false,
    };
}

const testing = std.testing;
const Parse = @import("../syntax/Parse.zig");

test selectionRanges {
    const text = "const a = foo(bar + 1);";
    const parse = try Parse.create(testing.allocator, text, .zig);
    defer parse.destroy();
    var lines = try offsets.LineIndex.init(testing.allocator, text);
    defer lines.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // The cursor is on `bar`
    const result = try selectionRanges(arena.allocator(), parse.rootNode(), lines, .utf8, &.{.{ .line = 0, .character = 15 }});
    var texts: std.ArrayList([]const u8) = .empty;
    var cur: ?*const types.SelectionRange = &result[0];
    while (cur) |sr| : (cur = sr.parent) {
        try texts.append(arena.allocator(), text[sr.range.start.character..sr.range.end.character]);
    }
    try testing.expectEqualSlices(u8, "bar", texts.items[0]);
    try testing.expectEqualStrings("bar + 1", texts.items[1]);
    try testing.expectEqualStrings("(bar + 1)", texts.items[2]);
    try testing.expectEqualStrings("foo(bar + 1)", texts.items[3]);
    try testing.expectEqualStrings(text, texts.items[texts.items.len - 1]);
}

test "selection between two tokens starts at the word that ends at the cursor" {
    // A bar cursor right after a name must not select only the punctuation after it
    const text = "const a = foo(bar, 1);\nconst b = x;\n";
    const parse = try Parse.create(testing.allocator, text, .zig);
    defer parse.destroy();
    var lines = try offsets.LineIndex.init(testing.allocator, text);
    defer lines.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // The cursor is at `needle` plus `delta`
    const cases = [_]struct { []const u8, usize, []const u8 }{
        .{ "bar,", 3, "bar" },
        .{ "foo(", 3, "foo" },
        .{ "x;", 1, "x" },
        // After a line-final `;`
        .{ ";\nconst b", 1, ";" },
        // Between `(` and a name: the name on the right
        .{ "(bar", 1, "bar" },
    };
    for (cases) |c| {
        const at = std.mem.indexOf(u8, text, c[0]).? + c[1];
        const result = try selectionRanges(arena.allocator(), parse.rootNode(), lines, .utf8, &.{lines.position(at, .utf8)});
        const r = result[0].range;
        const start = offsets.positionToOffset(text, r.start, .utf8);
        const end = offsets.positionToOffset(text, r.end, .utf8);
        try testing.expectEqualStrings(c[2], text[start..end]);
    }
}

test "selection ranges keep the innermost levels of a deep path" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "const a = ");
    for (0..500) |_| try text.append(testing.allocator, '(');
    try text.append(testing.allocator, 'x');
    for (0..500) |_| try text.append(testing.allocator, ')');
    try text.append(testing.allocator, ';');
    const parse = try Parse.create(testing.allocator, text.items, .zig);
    defer parse.destroy();
    var lines = try offsets.LineIndex.init(testing.allocator, text.items);
    defer lines.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const result = try selectionRanges(arena.allocator(), parse.rootNode(), lines, .utf8, &.{.{ .line = 0, .character = 510 }});
    var levels: usize = 0;
    var cur: ?*const types.SelectionRange = &result[0];
    while (cur) |sr| : (cur = sr.parent) levels += 1;
    try testing.expectEqual(max_levels, levels);
    try testing.expectEqual(510, result[0].range.start.character);
    try testing.expectEqual(511, result[0].range.end.character);
}

test "zon selection ranges match the same text parsed as zig" {
    const text =
        \\// a
        \\.{
        \\    .name = .demo,
        \\    .dependencies = .{ .foo = .{ .url = "u", .lazy = true } },
        \\    .paths = .{ "build.zig", "src" },
        \\}
        \\
    ;
    var lines = try offsets.LineIndex.init(testing.allocator, text);
    defer lines.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Parsed as Zig, the root expression sits in an unnamed field
    const zig = try Parse.create(testing.allocator, text, .zig);
    defer zig.destroy();
    const zon = try Parse.create(testing.allocator, text, .zon);
    defer zon.destroy();

    const positions = try a.alloc(types.Position, text.len + 1);
    for (positions, 0..) |*p, offset| p.* = lines.position(offset, .utf8);
    const expected = try selectionRanges(a, zig.rootNode(), lines, .utf8, positions);
    const actual = try selectionRanges(a, zon.rootNode(), lines, .utf8, positions);
    for (expected, actual) |e, z| {
        var ec: ?*const types.SelectionRange = &e;
        var zc: ?*const types.SelectionRange = &z;
        while (ec != null or zc != null) : ({
            ec = ec.?.parent;
            zc = zc.?.parent;
        }) {
            try testing.expect(ec != null and zc != null);
            try testing.expectEqual(ec.?.range, zc.?.range);
        }
    }
}
