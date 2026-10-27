//! Property tests for position conversion (fixed-seed random input + coverage-guided fuzzing):
//!
//! 1. `LineIndex.position` agrees with `offsetToPosition`, which scans character by character;
//! 2. position → offset → position round-trips are stable, and offsets never land in the middle of
//!    a multi-byte character or `\r\n`;
//! 3. incremental changes give the same result as "splicing the text directly".

const std = @import("std");
const testing = std.testing;
const offsets = @import("offsets.zig");
const types = @import("../lsp/types.zig");
const Entropy = @import("Entropy.zig");

const pieces = [_][]const u8{ "a", "Z", " ", "\n", "\r\n", "\r", "\t", "é", "€", "😀", "\xff", "\xe2\x82", "\x00" };

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
            // Round trip: the offset converted back from the position does not exceed the original
            // offset, and converting it again gives the same position
            const back = offsets.positionToOffset(text.items, pos, enc);
            try testing.expect(back <= off);
            try testing.expectEqual(pos, li.position(back, enc));
        }
    }

    // Incremental change: pick a range by byte offsets, convert it to positions and apply it; the
    // result equals direct splicing
    const enc: offsets.Encoding = e.pick(offsets.Encoding, &.{ .utf8, .utf16, .utf32 });
    var start = e.below(text.items.len + 1);
    var end = start + e.below(text.items.len - start + 1);
    // Align to boundaries that positions can represent exactly
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
