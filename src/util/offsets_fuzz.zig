//! 位置换算的性质测试（固定种子随机输入 + 覆盖率引导模糊测试）：
//!
//! 1. `LineIndex.position` 与逐字扫描的 `offsetToPosition` 结果一致；
//! 2. 位置 → 偏移 → 位置 往返稳定，偏移不会落在多字节字符或 `\r\n` 中间；
//! 3. 增量变更与「从文本直接拼接」的结果一致。

const std = @import("std");
const testing = std.testing;
const offsets = @import("offsets.zig");
const types = @import("../lsp/types.zig");
const Entropy = @import("Entropy.zig");

const pieces = [_][]const u8{ "a", "Z", " ", "\n", "\r\n", "\r", "\t", "é", "中", "😀", "\xff", "\xe4\xb8", "\x00" };

fn genText(e: *Entropy, out: *std.ArrayList(u8)) !void {
    const n = e.below(48);
    for (0..n) |_| try out.appendSlice(testing.allocator, e.pick([]const u8, &pieces));
}

fn checkAll(input: []const u8) !void {
    const a = testing.allocator;
    var e: Entropy = .{ .bytes = input };
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    try genText(&e, &text);

    var li = try offsets.LineIndex.init(a, text.items);
    defer li.deinit(a);
    for ([_]offsets.Encoding{ .utf8, .utf16, .utf32 }) |enc| {
        for (0..text.items.len + 1) |off| {
            const pos = li.position(off, enc);
            try testing.expectEqual(offsets.offsetToPosition(text.items, off, enc), pos);
            // 往返：位置换回的偏移不超过原偏移，再换一次位置不变
            const back = offsets.positionToOffset(text.items, pos, enc);
            try testing.expect(back <= off);
            try testing.expectEqual(pos, li.position(back, enc));
        }
    }

    // 增量变更：按字节偏移选区间，转换为位置后应用，结果等于直接拼接
    const enc: offsets.Encoding = e.pick(offsets.Encoding, &.{ .utf8, .utf16, .utf32 });
    var start = e.below(text.items.len + 1);
    var end = start + e.below(text.items.len - start + 1);
    // 对齐到位置可以精确表示的边界
    start = offsets.positionToOffset(text.items, li.position(start, enc), enc);
    end = @max(start, offsets.positionToOffset(text.items, li.position(end, enc), enc));
    var insert: std.ArrayList(u8) = .empty;
    defer insert.deinit(a);
    try genText(&e, &insert);

    const changes = [_]types.TextDocumentContentChangeEvent{.{ .TextDocumentContentChangePartial = .{
        .range = .{ .start = li.position(start, enc), .end = li.position(end, enc) },
        .text = insert.items,
    } }};
    const applied = try offsets.applyChanges(a, text.items, &changes, enc);
    defer a.free(applied);
    const expected = try std.mem.concat(a, u8, &.{ text.items[0..start], insert.items, text.items[end..] });
    defer a.free(expected);
    try testing.expectEqualStrings(expected, applied);
}

test "position conversion properties: fixed-seed random input" {
    var prng: std.Random.DefaultPrng = .init(0x0ff5_e7a1);
    var buf: [128]u8 = undefined;
    for (0..Entropy.iterations(5_000)) |_| {
        const len = prng.random().uintLessThan(usize, buf.len + 1);
        prng.random().bytes(buf[0..len]);
        try checkAll(buf[0..len]);
    }
}

test "position conversion properties: coverage-guided fuzzing" {
    try testing.fuzz({}, struct {
        fn one(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const len = smith.slice(&buf);
            try checkAll(buf[0..len]);
        }
    }.one, .{});
}
