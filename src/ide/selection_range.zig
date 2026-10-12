//! textDocument/selectionRange：从光标处的 token 逐层向外扩展到包含它的语法节点。

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const offsets = @import("../util/offsets.zig");
const SyntaxNode = @import("../syntax/tree.zig").SyntaxNode;
const isTrivia = @import("../syntax/kind.zig").isTrivia;

pub fn selectionRanges(
    arena: Allocator,
    root: SyntaxNode,
    lines: offsets.LineIndex,
    enc: offsets.Encoding,
    positions: []const types.Position,
) Allocator.Error![]const types.SelectionRange {
    const result = try arena.alloc(types.SelectionRange, positions.len);
    for (positions, result) |pos, *out| {
        const offset: u32 = @intCast(offsets.positionToOffset(lines.text, pos, enc));
        const path = try root.coveringPath(arena, offset);

        // 由外向内构建，parent 指向外层
        var parent: ?*const types.SelectionRange = null;
        var last: ?[2]u32 = null;
        for (path) |node| {
            const r = node.range();
            if (last != null and last.?[0] == r.start and last.?[1] == r.end) continue;
            last = .{ r.start, r.end };
            const sr = try arena.create(types.SelectionRange);
            sr.* = .{ .range = lines.range(r.start, r.end, enc), .parent = parent };
            parent = sr;
        }
        if (root.tokenAtOffset(offset)) |t| {
            const r = t.range();
            if (!isTrivia(t.kind) and !(last != null and last.?[0] == r.start and last.?[1] == r.end)) {
                const sr = try arena.create(types.SelectionRange);
                sr.* = .{ .range = lines.range(r.start, r.end, enc), .parent = parent };
                parent = sr;
            }
        }
        out.* = parent.?.*;
    }
    return result;
}

const testing = std.testing;
const Parse = @import("../syntax/Parse.zig");

test selectionRanges {
    const text = "const a = foo(bar + 1);";
    const parse = try Parse.create(testing.allocator, text);
    defer parse.destroy();
    var lines = try offsets.LineIndex.init(testing.allocator, text);
    defer lines.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // 光标在 `bar` 上
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
