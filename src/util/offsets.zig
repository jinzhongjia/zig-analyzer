//! Conversion between LSP positions (line + column counted in units of the encoding) and byte
//! offsets, and application of incremental document changes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");

pub const Encoding = enum {
    utf8,
    utf16,
    utf32,

    pub fn fromLsp(kind: []const u8) ?Encoding {
        const map = std.StaticStringMap(Encoding).initComptime(.{
            .{ "utf-8", .utf8 },
            .{ "utf-16", .utf16 },
            .{ "utf-32", .utf32 },
        });
        return map.get(kind);
    }

    pub fn toLsp(enc: Encoding) []const u8 {
        return switch (enc) {
            .utf8 => types.PositionEncodingKind.UTF8,
            .utf16 => types.PositionEncodingKind.UTF16,
            .utf32 => types.PositionEncodingKind.UTF32,
        };
    }
};

fn lineEnd(text: []const u8, start: usize) usize {
    return std.mem.indexOfAnyPos(u8, text, start, "\r\n") orelse text.len;
}

/// Decodes one UTF-8 character and returns its byte length and its number of units in `enc`.
/// Invalid bytes count as 1 byte and 1 unit.
fn charWidth(bytes: []const u8, enc: Encoding) struct { len: usize, units: u32 } {
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return .{ .len = 1, .units = 1 };
    if (len > bytes.len) return .{ .len = 1, .units = 1 };
    _ = std.unicode.utf8Decode(bytes[0..len]) catch return .{ .len = 1, .units = 1 };
    return .{ .len = len, .units = switch (enc) {
        .utf8 => @intCast(len),
        .utf16 => if (len == 4) 2 else 1,
        .utf32 => 1,
    } };
}

/// Number of code units in `text[from..target]`, where `end` is the end offset of the content of
/// the line; a `target` in the middle of a multi-byte character is rounded down
fn countUnits(text: []const u8, from: usize, target: usize, end: usize, enc: Encoding) u32 {
    const stop = @min(target, end);
    var i = from;
    var n: u32 = 0;
    while (i < stop) {
        const w = charWidth(text[i..end], enc);
        if (i + w.len > stop) break;
        n += w.units;
        i += w.len;
    }
    return n;
}

/// Number of code units in `text` (a line break counts as one unit, like any other character)
pub fn unitCount(text: []const u8, enc: Encoding) u32 {
    return countUnits(text, 0, text.len, text.len, enc);
}

/// One line of the text: converts positions and offsets within this line only, without building a
/// line table for the whole file
pub const Line = struct {
    text: []const u8,
    number: u32,
    /// Byte offset where the line starts
    start: usize,
    /// End offset of the content of the line (excluding the line break)
    end: usize,

    /// Line `number`; null when the text has fewer lines
    pub fn init(text: []const u8, number: u32) ?Line {
        var start: usize = 0;
        for (0..number) |_| {
            const nl = std.mem.indexOfAnyPos(u8, text, start, "\r\n") orelse return null;
            start = nl + 1;
            if (text[nl] == '\r' and start < text.len and text[start] == '\n') start += 1;
        }
        return .{ .text = text, .number = number, .start = start, .end = lineEnd(text, start) };
    }

    /// Offset of code unit `character` in the line; the end of the line when past it
    pub fn offset(l: Line, character: u32, enc: Encoding) usize {
        var i = l.start;
        var units: u32 = 0;
        while (i < l.end and units < character) {
            const w = charWidth(l.text[i..l.end], enc);
            // When the column falls in the middle of a multi-unit character, round down to its start
            if (units + w.units > character) break;
            units += w.units;
            i += w.len;
        }
        return i;
    }

    /// Position of offset `at` (as `offsetToPosition`); null when `at` is not in the content of the
    /// line (`start` to `end`, both inclusive)
    pub fn position(l: Line, at: usize, enc: Encoding) ?types.Position {
        if (at < l.start or at > l.end) return null;
        return .{ .line = l.number, .character = countUnits(l.text, l.start, at, l.end, enc) };
    }
};

pub fn positionToOffset(text: []const u8, pos: types.Position, enc: Encoding) usize {
    const line = Line.init(text, pos.line) orelse return text.len;
    return line.offset(pos.character, enc);
}

pub fn offsetToPosition(text: []const u8, offset: usize, enc: Encoding) types.Position {
    const target = @min(offset, text.len);
    var line: u32 = 0;
    var start: usize = 0;
    while (true) {
        const nl = std.mem.indexOfAnyPos(u8, text, start, "\r\n") orelse break;
        var next = nl + 1;
        if (text[nl] == '\r' and next < text.len and text[next] == '\n') next += 1;
        if (next > target) break;
        start = next;
        line += 1;
    }
    const end = lineEnd(text, start);
    var i = start;
    var units: u32 = 0;
    while (i < @min(target, end)) {
        const w = charWidth(text[i..end], enc);
        // When the offset falls in the middle of a multi-byte character, round down to its start
        if (i + w.len > target) break;
        units += w.units;
        i += w.len;
    }
    return .{ .line = line, .character = units };
}

/// Table of line start offsets: converts byte offsets to LSP positions in O(log n).
pub const LineIndex = struct {
    text: []const u8,
    line_starts: []const u32,

    pub fn init(gpa: Allocator, text: []const u8) Allocator.Error!LineIndex {
        var starts: std.ArrayList(u32) = .empty;
        errdefer starts.deinit(gpa);
        try starts.append(gpa, 0);
        var i: usize = 0;
        while (std.mem.indexOfAnyPos(u8, text, i, "\r\n")) |nl| {
            i = nl + 1;
            if (text[nl] == '\r' and i < text.len and text[i] == '\n') i += 1;
            try starts.append(gpa, @intCast(i));
        }
        return .{ .text = text, .line_starts = try starts.toOwnedSlice(gpa) };
    }

    pub fn deinit(li: *LineIndex, gpa: Allocator) void {
        gpa.free(li.line_starts);
    }

    pub fn lineOf(li: LineIndex, offset: usize) u32 {
        const target: u32 = @intCast(@min(offset, li.text.len));
        // The last line start <= target
        var lo: usize = 0;
        var hi: usize = li.line_starts.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (li.line_starts[mid] <= target) lo = mid else hi = mid;
        }
        return @intCast(lo);
    }

    pub fn position(li: LineIndex, offset: usize, enc: Encoding) types.Position {
        const line = li.lineOf(offset);
        return .{ .line = line, .character = li.units(line, li.line_starts[line], offset, enc) };
    }

    /// Same as `position`. `prev` is the position of `prev_offset` (a character boundary): when it
    /// is on the same line as `offset` and not after it, counting continues from there. Used when
    /// converting offsets one by one in increasing order, since counting from the start of the line
    /// each time is quadratic on very long lines.
    pub fn positionAfter(li: LineIndex, prev_offset: usize, prev: types.Position, offset: usize, enc: Encoding) types.Position {
        const line = li.lineOf(offset);
        if (line != prev.line or offset < prev_offset or prev_offset < li.line_starts[line]) return li.position(offset, enc);
        return .{ .line = line, .character = prev.character + li.units(line, prev_offset, offset, enc) };
    }

    /// Number of code units in line `line` from `from` (a character boundary) to `offset`; an
    /// offset in the middle of a multi-byte character is rounded down
    fn units(li: LineIndex, line: u32, from: usize, offset: usize, enc: Encoding) u32 {
        return countUnits(li.text, from, offset, li.contentEnd(line), enc);
    }

    /// End offset of the content of line `line` (excluding the line break)
    fn contentEnd(li: LineIndex, line: u32) usize {
        if (line + 1 >= li.line_starts.len) return li.text.len;
        var end: usize = li.line_starts[line + 1];
        if (end > 0 and li.text[end - 1] == '\n') end -= 1;
        if (end > li.line_starts[line] and li.text[end - 1] == '\r') end -= 1;
        return end;
    }

    pub fn range(li: LineIndex, start: usize, end: usize, enc: Encoding) types.Range {
        return .{ .start = li.position(start, enc), .end = li.position(end, enc) };
    }
};

test LineIndex {
    const text = "x\r\na😀b\nlast\r\r\n😀😀";
    var li: LineIndex = try .init(testing.allocator, text);
    defer li.deinit(testing.allocator);
    for ([_]Encoding{ .utf8, .utf16, .utf32 }) |enc| {
        var prev_offset: usize = 0;
        var prev: types.Position = .{ .line = 0, .character = 0 };
        for (0..text.len + 1) |off| {
            const expected = offsetToPosition(text, off, enc);
            try testing.expectEqual(expected, li.position(off, enc));
            try testing.expectEqual(expected, li.positionAfter(prev_offset, prev, off, enc));
            // Continue only from character boundaries
            if (off == text.len or (text[off] & 0xc0) != 0x80) {
                prev_offset = off;
                prev = expected;
            }
        }
    }
}

test Line {
    const text = "x\r\na😀b\nlast\r\r\n😀😀";
    for ([_]Encoding{ .utf8, .utf16, .utf32 }) |enc| {
        for (0..text.len + 1) |off| {
            const expected = offsetToPosition(text, off, enc);
            var number: u32 = 0;
            while (Line.init(text, number)) |line| : (number += 1) {
                // Only offsets in the content of a line are converted, not those in its line break
                if (number == expected.line and off <= line.end) {
                    try testing.expectEqual(expected, line.position(off, enc).?);
                } else try testing.expectEqual(null, line.position(off, enc));
            }
            try testing.expectEqual(5, number);
        }
    }
}

/// Applies incremental changes in order and returns the new text (owned by the caller).
pub fn applyChanges(
    gpa: Allocator,
    text: []const u8,
    changes: []const types.TextDocumentContentChangeEvent,
    enc: Encoding,
) Allocator.Error![]u8 {
    var current: std.ArrayList(u8) = .empty;
    errdefer current.deinit(gpa);
    try current.appendSlice(gpa, text);

    for (changes) |change| switch (change) {
        .TextDocumentContentChangeWholeDocument => |whole| {
            current.clearRetainingCapacity();
            try current.appendSlice(gpa, whole.text);
        },
        .TextDocumentContentChangePartial => |partial| {
            const start = positionToOffset(current.items, partial.range.start, enc);
            const end = @max(start, positionToOffset(current.items, partial.range.end, enc));
            try current.replaceRange(gpa, start, end - start, partial.text);
        },
    };
    return current.toOwnedSlice(gpa);
}

const testing = std.testing;

test "positionToOffset / offsetToPosition round trip in all three encodings" {
    // In "a😀b", 😀 is 4 bytes, 2 UTF-16 units, and 1 code point
    const text = "x\r\na😀b\nlast";
    const b_offset = std.mem.indexOfScalar(u8, text, 'b').?;
    try testing.expectEqual(b_offset, positionToOffset(text, .{ .line = 1, .character = 5 }, .utf8));
    try testing.expectEqual(b_offset, positionToOffset(text, .{ .line = 1, .character = 3 }, .utf16));
    try testing.expectEqual(b_offset, positionToOffset(text, .{ .line = 1, .character = 2 }, .utf32));
    for ([_]Encoding{ .utf8, .utf16, .utf32 }) |enc| {
        for (0..text.len + 1) |off| {
            const pos = offsetToPosition(text, off, enc);
            const back = positionToOffset(text, pos, enc);
            // An offset in the middle of a multi-byte character or \r\n cannot round-trip exactly,
            // so only require that it does not move past the original offset
            try testing.expect(back <= off);
        }
        try testing.expectEqual(b_offset, positionToOffset(text, offsetToPosition(text, b_offset, enc), enc));
    }
}

test "out-of-range positions are clamped" {
    const text = "ab\ncd";
    try testing.expectEqual(2, positionToOffset(text, .{ .line = 0, .character = 100 }, .utf16));
    try testing.expectEqual(text.len, positionToOffset(text, .{ .line = 9, .character = 0 }, .utf16));
}

test applyChanges {
    const gpa = testing.allocator;
    const changes = [_]types.TextDocumentContentChangeEvent{
        .{ .TextDocumentContentChangePartial = .{ .range = .{ .start = .{ .line = 0, .character = 6 }, .end = .{ .line = 0, .character = 11 } }, .text = "zig" } },
        .{ .TextDocumentContentChangePartial = .{ .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 0 } }, .text = "// " } },
    };
    const out = try applyChanges(gpa, "hello world\nbye", &changes, .utf16);
    defer gpa.free(out);
    try testing.expectEqualStrings("hello zig\n// bye", out);

    const whole = [_]types.TextDocumentContentChangeEvent{.{ .TextDocumentContentChangeWholeDocument = .{ .text = "new" } }};
    const out2 = try applyChanges(gpa, out, &whole, .utf16);
    defer gpa.free(out2);
    try testing.expectEqualStrings("new", out2);
}

test {
    _ = @import("offsets_fuzz.zig");
}
