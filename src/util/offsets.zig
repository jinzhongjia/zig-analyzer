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
///
/// Each change is located from the line of the previous one, and the text is edited in a gap
/// buffer whose gap follows the edits: a batch of changes that moves through the document in one
/// direction (such as the edits of a replace-all, which clients send from the last one up) costs
/// one pass over the text plus the lines it touches, instead of a scan from the start of the text
/// and a move of everything after the edit for each change.
pub fn applyChanges(
    gpa: Allocator,
    text: []const u8,
    changes: []const types.TextDocumentContentChangeEvent,
    enc: Encoding,
) Allocator.Error![]u8 {
    var buf: GapBuffer = try .init(gpa, text);
    errdefer buf.deinit(gpa);
    for (changes) |change| switch (change) {
        .TextDocumentContentChangeWholeDocument => |whole| try buf.reset(gpa, whole.text),
        .TextDocumentContentChangePartial => |partial| {
            const start, const end = buf.rangeOffsets(partial.range, enc);
            try buf.replace(gpa, start, end, partial.text);
        },
    };
    return buf.toOwnedSlice(gpa);
}

/// The text being edited by `applyChanges`: `buf[0..gap_start]` followed by `buf[gap_end..]`.
/// Offsets are logical (in the text, not in `buf`).
const GapBuffer = struct {
    buf: []u8,
    gap_start: usize,
    gap_end: usize,
    /// Line `cursor_line` starts at offset `cursor`, and no edit at or after `cursor` can move
    /// that line start; changes are located by scanning from there
    cursor_line: u32 = 0,
    cursor: usize = 0,

    const min_gap = 4096;

    fn init(gpa: Allocator, text: []const u8) Allocator.Error!GapBuffer {
        const buf = try gpa.alloc(u8, text.len + min_gap);
        @memcpy(buf[0..text.len], text);
        return .{ .buf = buf, .gap_start = text.len, .gap_end = buf.len };
    }

    fn deinit(b: *GapBuffer, gpa: Allocator) void {
        gpa.free(b.buf);
    }

    fn len(b: *const GapBuffer) usize {
        return b.buf.len - (b.gap_end - b.gap_start);
    }

    /// The text before the gap
    fn before(b: *const GapBuffer) []const u8 {
        return b.buf[0..b.gap_start];
    }

    /// The text after the gap
    fn after(b: *const GapBuffer) []const u8 {
        return b.buf[b.gap_end..];
    }

    fn moveGap(b: *GapBuffer, at: usize) void {
        if (at < b.gap_start) {
            const n = b.gap_start - at;
            @memmove(b.buf[b.gap_end - n .. b.gap_end], b.buf[at..b.gap_start]);
            b.gap_start = at;
            b.gap_end -= n;
        } else if (at > b.gap_start) {
            const n = at - b.gap_start;
            @memmove(b.buf[b.gap_start..][0..n], b.buf[b.gap_end..][0..n]);
            b.gap_start = at;
            b.gap_end += n;
        }
    }

    fn reset(b: *GapBuffer, gpa: Allocator, text: []const u8) Allocator.Error!void {
        if (b.buf.len < text.len) {
            const buf = try gpa.alloc(u8, text.len + min_gap);
            gpa.free(b.buf);
            b.buf = buf;
        }
        @memcpy(b.buf[0..text.len], text);
        b.gap_start = text.len;
        b.gap_end = b.buf.len;
        b.cursor_line = 0;
        b.cursor = 0;
    }

    /// Offset of the start of line `line`, null when the text has fewer lines (as `Line.init`).
    /// Leaves the gap at the returned offset, so the text from there on is `after()`.
    fn lineStart(b: *GapBuffer, line: u32) ?usize {
        b.moveGap(b.cursor);
        var at = b.cursor;
        if (line < b.cursor_line) {
            for (line..b.cursor_line) |_| at = prevLineStart(b.before(), at);
        } else {
            const rest = b.after();
            var i: usize = 0;
            for (b.cursor_line..line) |_| i = nextLineStart(rest, i) orelse return null;
            at += i;
        }
        b.moveGap(at);
        return at;
    }

    /// Offsets of the start and end of `range`, as `positionToOffset` gives them on the whole
    /// text (an end before the start is the start). Moves the cursor to the start line.
    fn rangeOffsets(b: *GapBuffer, range: types.Range, enc: Encoding) struct { usize, usize } {
        const line_start = b.lineStart(range.start.line) orelse return .{ b.len(), b.len() };
        const rest = b.after();
        const start = line_start + lineIn(rest, 0).offset(range.start.character, enc);
        // Every later edit starts at or after `line_start`: a line start after `\n` stays put,
        // while one after a lone `\r` moves when the edit inserts `\n` right at it, so the
        // cursor then stays one line up
        if (line_start == 0 or b.before()[line_start - 1] == '\n') {
            b.cursor_line = range.start.line;
            b.cursor = line_start;
        } else {
            b.cursor_line = range.start.line - 1;
            b.cursor = prevLineStart(b.before(), line_start);
        }
        if (range.end.line < range.start.line) return .{ start, start };
        var i: usize = 0;
        for (range.start.line..range.end.line) |_| i = nextLineStart(rest, i) orelse return .{ start, b.len() };
        const end = line_start + lineIn(rest, i).offset(range.end.character, enc);
        return .{ start, @max(start, end) };
    }

    /// Replaces `start..end` with `text`
    fn replace(b: *GapBuffer, gpa: Allocator, start: usize, end: usize, text: []const u8) Allocator.Error!void {
        b.moveGap(start);
        b.gap_end += end - start;
        if (b.gap_end - b.gap_start < text.len) {
            // Grow in proportion to the text, so that growing stays amortized O(1) per byte
            const length = b.len();
            const buf = try gpa.alloc(u8, length + text.len + @max(min_gap, length / 2));
            const tail = b.buf.len - b.gap_end;
            @memcpy(buf[0..b.gap_start], b.before());
            @memcpy(buf[buf.len - tail ..], b.after());
            gpa.free(b.buf);
            b.buf = buf;
            b.gap_end = buf.len - tail;
        }
        @memcpy(b.buf[b.gap_start..][0..text.len], text);
        b.gap_start += text.len;
    }

    fn toOwnedSlice(b: *GapBuffer, gpa: Allocator) Allocator.Error![]u8 {
        const length = b.len();
        b.moveGap(length);
        return gpa.realloc(b.buf, length);
    }

    /// The line of `text` that starts at `start`
    fn lineIn(text: []const u8, start: usize) Line {
        return .{ .text = text, .number = undefined, .start = start, .end = lineEnd(text, start) };
    }

    /// Start of the line after the one that contains `at`; null on the last line
    fn nextLineStart(text: []const u8, at: usize) ?usize {
        const nl = std.mem.indexOfAnyPos(u8, text, at, "\r\n") orelse return null;
        var next = nl + 1;
        if (text[nl] == '\r' and next < text.len and text[next] == '\n') next += 1;
        return next;
    }

    /// Start of the line before the one that starts at `line_start` (> 0) in `text`, which
    /// extends at least to `line_start`
    fn prevLineStart(text: []const u8, line_start: usize) usize {
        var i = line_start - 1;
        if (text[i] == '\n' and i > 0 and text[i - 1] == '\r') i -= 1;
        const nl = std.mem.lastIndexOfAny(u8, text[0..i], "\r\n") orelse return 0;
        return nl + 1;
    }
};

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

test "applyChanges: edits that join or split line breaks move the later lines" {
    const gpa = testing.allocator;
    const Change = types.TextDocumentContentChangeEvent;
    const at = struct {
        fn at(line: u32, character: u32, text: []const u8) Change {
            const pos: types.Position = .{ .line = line, .character = character };
            return .{ .TextDocumentContentChangePartial = .{ .range = .{ .start = pos, .end = pos }, .text = text } };
        }
    }.at;
    const cases = [_]struct { text: []const u8, changes: []const Change, expected: []const u8 }{
        // `\n` inserted after a lone `\r` joins them into one line break
        .{ .text = "a\rb\nc", .changes = &.{ at(1, 0, "\n"), at(2, 0, "x") }, .expected = "a\r\nb\nxc" },
        // `\r` inserted before `\n`, and a deletion that splits `\r\n`
        .{ .text = "a\nb\nc", .changes = &.{ at(0, 1, "\r"), at(1, 0, "y"), at(2, 1, "z") }, .expected = "a\r\nyb\ncz" },
        .{ .text = "a\r\nb\nc", .changes = &.{
            .{ .TextDocumentContentChangePartial = .{ .range = .{ .start = .{ .line = 0, .character = 1 }, .end = .{ .line = 1, .character = 0 } }, .text = "\r" } },
            at(1, 0, "\n"),
            at(2, 0, "w"),
            at(0, 0, "v"),
        }, .expected = "va\r\nb\nwc" },
        // Backwards over `\r\n`, lone `\r` and empty lines, then past the last line
        .{ .text = "0\r\n1\r\r\n\n4", .changes = &.{ at(4, 1, "d"), at(3, 0, "c"), at(1, 1, "b"), at(0, 0, "a"), at(5, 0, "e") }, .expected = "a0\r\n1b\r\r\nc\n4de" },
    };
    for (cases) |c| {
        const out = try applyChanges(gpa, c.text, c.changes, .utf16);
        defer gpa.free(out);
        try testing.expectEqualStrings(c.expected, out);
    }
}

test "applyChanges: a batch of edits at the end of a large text costs no scan from its start per edit" {
    // A replace-all in a 1.5 MB file: 26000 filler lines, then 4000 edited lines, edited from the
    // last one up, as clients send them. Scanning the text from its start for each edit took
    // seconds even in optimized builds.
    const gpa = testing.allocator;
    const filler_lines = 26000;
    const edited_lines = 4000;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(gpa);
    for (0..filler_lines) |i| {
        const line = try std.fmt.allocPrint(gpa, "const pad_{d:0>7}: u32 = 0; // filler line to reach the size\n", .{i});
        defer gpa.free(line);
        try text.appendSlice(gpa, line);
        try expected.appendSlice(gpa, line);
    }
    try text.appendSlice(gpa, "fn target(abcd: u32) void {\n");
    try expected.appendSlice(gpa, "fn target(wxyz_: u32) void {\n");
    for (0..edited_lines) |_| {
        try text.appendSlice(gpa, "    _ = abcd;\n");
        try expected.appendSlice(gpa, "    _ = wxyz_;\n");
    }
    try text.appendSlice(gpa, "}\n");
    try expected.appendSlice(gpa, "}\n");

    const changes = try gpa.alloc(types.TextDocumentContentChangeEvent, edited_lines + 1);
    defer gpa.free(changes);
    for (changes[0..edited_lines], 0..) |*c, i| {
        const line: u32 = @intCast(filler_lines + edited_lines - i);
        c.* = .{ .TextDocumentContentChangePartial = .{ .range = .{ .start = .{ .line = line, .character = 8 }, .end = .{ .line = line, .character = 12 } }, .text = "wxyz_" } };
    }
    changes[edited_lines] = .{ .TextDocumentContentChangePartial = .{ .range = .{ .start = .{ .line = filler_lines, .character = 10 }, .end = .{ .line = filler_lines, .character = 14 } }, .text = "wxyz_" } };

    const t0 = std.Io.Clock.awake.now(testing.io);
    const out = try applyChanges(gpa, text.items, changes, .utf16);
    const elapsed = t0.durationTo(std.Io.Clock.awake.now(testing.io));
    defer gpa.free(out);
    try testing.expectEqualStrings(expected.items, out);
    // The edits touch only their own lines; the bound leaves a wide margin for slow machines and
    // Debug builds
    try testing.expect(elapsed.toMilliseconds() < 2000);
}

test {
    _ = @import("offsets_fuzz.zig");
}
