//! Property tests for position conversion (fixed-seed random input + coverage-guided fuzzing):
//!
//! 1. `LineIndex.position` and `Line.position` agree with `offsetToPosition`, which scans character
//!    by character;
//! 2. the line table, `positionToOffset`, `LineIndex.offsetOf` and `unitCount` agree with scalar
//!    references that go byte by byte, for every position in and past the text (the conversions
//!    scan in vector chunks, and the long ASCII piece makes runs that cross chunk boundaries);
//!    `LineIndex.lineAt` gives the line `Line.init` finds;
//! 3. position → offset → position round-trips are stable, and offsets never land in the middle of
//!    a multi-byte character or `\r\n`;
//! 4. incremental changes give the same result as "splicing the text directly";
//! 5. a batch of changes at arbitrary positions (out of range, reversed, splitting or joining
//!    `\r\n`) gives the same result as converting and splicing each change on the whole text.

const std = @import("std");
const testing = std.testing;
const offsets = @import("offsets.zig");
const types = @import("../lsp/types.zig");
const Entropy = @import("Entropy.zig");

const pieces = [_][]const u8{ "a", "Z", " ", "\n", "\r\n", "\r", "\t", "é", "€", "😀", "\xff", "\xe2\x82", "\x00", "const value = 1; " };

fn genText(e: *Entropy, out: *std.ArrayList(u8)) !void {
    const n = e.below(48);
    for (0..n) |_| try out.appendSlice(testing.allocator, e.pick([]const u8, &pieces));
}

/// Byte length and units of the character at the start of `bytes`; an invalid sequence, or one
/// cut off by the end of `bytes`, is one byte of one unit
fn refChar(bytes: []const u8, enc: offsets.Encoding) struct { len: usize, units: u32 } {
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return .{ .len = 1, .units = 1 };
    if (len > bytes.len) return .{ .len = 1, .units = 1 };
    const cp = std.unicode.utf8Decode(bytes[0..len]) catch return .{ .len = 1, .units = 1 };
    return .{ .len = len, .units = switch (enc) {
        .utf8 => @intCast(len),
        .utf16 => if (cp >= 0x10000) 2 else 1,
        .utf32 => 1,
    } };
}

fn isBreak(c: u8) bool {
    return c == '\r' or c == '\n';
}

/// Offset after the line break at `i`
fn refBreakEnd(text: []const u8, i: usize) usize {
    return if (text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n') i + 2 else i + 1;
}

fn refLineStarts(a: std.mem.Allocator, text: []const u8) ![]u32 {
    var starts: std.ArrayList(u32) = .empty;
    errdefer starts.deinit(a);
    try starts.append(a, 0);
    var i: usize = 0;
    while (i < text.len) {
        if (isBreak(text[i])) {
            i = refBreakEnd(text, i);
            try starts.append(a, @intCast(i));
        } else i += 1;
    }
    return starts.toOwnedSlice(a);
}

fn refPositionToOffset(text: []const u8, pos: types.Position, enc: offsets.Encoding) usize {
    var i: usize = 0;
    for (0..pos.line) |_| {
        while (i < text.len and !isBreak(text[i])) i += 1;
        if (i == text.len) return text.len;
        i = refBreakEnd(text, i);
    }
    var end = i;
    while (end < text.len and !isBreak(text[end])) end += 1;
    var units: u32 = 0;
    while (i < end and units < pos.character) {
        const c = refChar(text[i..end], enc);
        // A column in the middle of a multi-unit character rounds down to its start
        if (units + c.units > pos.character) break;
        units += c.units;
        i += c.len;
    }
    return i;
}

fn refUnitCount(text: []const u8, enc: offsets.Encoding) u32 {
    var i: usize = 0;
    var units: u32 = 0;
    while (i < text.len) {
        const c = refChar(text[i..], enc);
        units += c.units;
        i += c.len;
    }
    return units;
}

fn checkAll(input: []const u8) !void {
    const a = testing.allocator;
    var e: Entropy = .{ .bytes = input };
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    try genText(&e, &text);

    var li = try offsets.LineIndex.init(a, text.items);
    defer li.deinit(a);
    const ref_starts = try refLineStarts(a, text.items);
    defer a.free(ref_starts);
    try testing.expectEqualSlices(u32, ref_starts, li.line_starts);
    for (0..ref_starts.len + 1) |n| try testing.expectEqual(offsets.Line.init(text.items, @intCast(n)), li.lineAt(@intCast(n)));
    for ([_]offsets.Encoding{ .utf8, .utf16, .utf32 }) |enc| {
        try testing.expectEqual(refUnitCount(text.items, enc), offsets.unitCount(text.items, enc));
        // Every column of every line up to two past its end, a huge column, and a line past the end
        for (0..ref_starts.len + 1) |line| {
            const line_len = if (line < ref_starts.len) (if (line + 1 < ref_starts.len) ref_starts[line + 1] else text.items.len) - ref_starts[line] else 0;
            for (0..line_len + 3) |character| {
                const pos: types.Position = .{ .line = @intCast(line), .character = if (character == line_len + 2) std.math.maxInt(u32) else @intCast(character) };
                const expected = refPositionToOffset(text.items, pos, enc);
                try testing.expectEqual(expected, offsets.positionToOffset(text.items, pos, enc));
                try testing.expectEqual(expected, li.offsetOf(pos, enc));
            }
        }
    }
    for ([_]offsets.Encoding{ .utf8, .utf16, .utf32 }) |enc| {
        for (0..text.items.len + 1) |off| {
            const pos = li.position(off, enc);
            try testing.expectEqual(offsets.offsetToPosition(text.items, off, enc), pos);
            // Round trip: the offset converted back from the position does not exceed the original
            // offset, and converting it again gives the same position
            const back = offsets.positionToOffset(text.items, pos, enc);
            try testing.expect(back <= off);
            try testing.expectEqual(pos, li.position(back, enc));
            // Line-local conversion: agrees with the line table for offsets in the content of the line,
            // and gives nothing for offsets in the line break
            const line = offsets.Line.init(text.items, pos.line).?;
            if (line.position(off, enc)) |p| try testing.expectEqual(pos, p) else try testing.expect(off > line.end);
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

    // A batch of changes at arbitrary positions, against a splice of each change in turn
    const batch_enc: offsets.Encoding = e.pick(offsets.Encoding, &.{ .utf8, .utf16, .utf32 });
    var batch: [6]types.TextDocumentContentChangeEvent = undefined;
    var inserts: [batch.len]std.ArrayList(u8) = @splat(.empty);
    defer for (&inserts) |*i| i.deinit(a);
    const n = 1 + e.below(batch.len);
    for (batch[0..n], inserts[0..n]) |*c, *ins| {
        try genText(&e, ins);
        if (e.below(16) == 0) {
            c.* = .{ .TextDocumentContentChangeWholeDocument = .{ .text = ins.items } };
            continue;
        }
        const pos = struct {
            fn pos(en: *Entropy) types.Position {
                return .{ .line = @intCast(en.below(8)), .character = @intCast(en.below(10)) };
            }
        }.pos;
        c.* = .{ .TextDocumentContentChangePartial = .{ .range = .{ .start = pos(&e), .end = pos(&e) }, .text = ins.items } };
    }
    var reference: std.ArrayList(u8) = .empty;
    defer reference.deinit(a);
    try reference.appendSlice(a, text.items);
    for (batch[0..n]) |c| switch (c) {
        .TextDocumentContentChangeWholeDocument => |whole| {
            reference.clearRetainingCapacity();
            try reference.appendSlice(a, whole.text);
        },
        .TextDocumentContentChangePartial => |p| {
            const s = offsets.positionToOffset(reference.items, p.range.start, batch_enc);
            const t = @max(s, offsets.positionToOffset(reference.items, p.range.end, batch_enc));
            try reference.replaceRange(a, s, t - s, p.text);
        },
    };
    const batched = try offsets.applyChanges(a, text.items, batch[0..n], batch_enc);
    defer a.free(batched);
    try testing.expectEqualStrings(reference.items, batched);
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
