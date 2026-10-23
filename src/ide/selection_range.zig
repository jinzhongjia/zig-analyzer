//! textDocument/selectionRange：从光标处的 token 逐层向外扩展到包含它的语法节点。

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const offsets = @import("../util/offsets.zig");
const SyntaxNode = @import("../syntax/tree.zig").SyntaxNode;
const isTrivia = @import("../syntax/kind.zig").isTrivia;

/// 每个位置至多返回的层数，保留最内层的。`parent` 链每层在 JSON 中嵌套一层，而 `std.json.Stringify`
/// 在带安全检查的构建中嵌套超过 256 层时 panic
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
        const offset: u32 = @intCast(offsets.positionToOffset(lines.text, pos, enc));
        const path = try root.coveringPath(arena, offset);

        // 由外向内构建，parent 指向外层
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

test "selection ranges keep the innermost levels of a deep path" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "const a = ");
    for (0..500) |_| try text.append(testing.allocator, '(');
    try text.append(testing.allocator, 'x');
    for (0..500) |_| try text.append(testing.allocator, ')');
    try text.append(testing.allocator, ';');
    const parse = try Parse.create(testing.allocator, text.items);
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
