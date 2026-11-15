//! Line diff between two texts (a patience diff): the modified regions as disjoint replacement
//! ranges in whole lines.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A differing range between the old and new text: old text [start, old_end) is replaced by the
/// new text that ends at `new_end`. `old_end` and `new_end` are offsets in their own text, so
/// `new_end - old_end` is the total shift of everything after this range, including the length
/// differences of the ranges before it.
pub const Edit = struct {
    start: u32,
    old_end: u32,
    new_end: u32,
    /// Only the line terminator differs (`\r\n` and `\n`): the lines on both sides are the same
    line_break: bool = false,
};

/// A line of a text: its content [start, end) and the start of the next line; the line terminator
/// lies in between
const Line = struct { start: u32, end: u32, next: u32 };

/// Line `old` of the old text matched with the identical line `new` of the new text
const Match = struct {
    old: usize,
    new: usize,

    fn before(_: void, a: Match, b: Match) bool {
        return a.old < b.old;
    }
};

/// Compares the old and new text line by line (a patience diff) and returns disjoint replacement
/// ranges sorted by position. Lines are compared without their terminator (`\r\n` and `\n` are
/// equivalent); identical lines whose terminators differ yield a `line_break`
/// edit. In each range of lines still to compare, identical lines at its start and end are
/// matched; of the remaining lines, those identical and unique on both sides within the range are
/// matched along their longest increasing subsequence, and the ranges between them are compared
/// the same way. Lines left without a match form the modified regions, so no region starts or ends
/// with a line that is identical on both sides.
pub fn diff(a: Allocator, old: []const u8, new: []const u8) Allocator.Error![]const Edit {
    if (std.mem.eql(u8, old, new)) return &.{};
    const old_lines = try splitLines(a, old);
    const new_lines = try splitLines(a, new);
    const Range = struct { old_start: usize, old_end: usize, new_start: usize, new_end: usize };
    // Occurrences of a line in the range on each side, and the old line it first occurs on
    const Count = struct { old: usize, new: usize, old_line: usize };
    var matches: std.ArrayList(Match) = .empty;
    var pending: std.ArrayList(Range) = .empty;
    var counts: std.StringHashMapUnmanaged(Count) = .empty;
    var unique: std.ArrayList(Match) = .empty;
    try pending.append(a, .{ .old_start = 0, .old_end = old_lines.len, .new_start = 0, .new_end = new_lines.len });
    while (pending.pop()) |range| {
        var r = range;
        while (r.old_start < r.old_end and r.new_start < r.new_end and
            std.mem.eql(u8, lineText(old, old_lines, r.old_start), lineText(new, new_lines, r.new_start)))
        {
            try matches.append(a, .{ .old = r.old_start, .new = r.new_start });
            r.old_start += 1;
            r.new_start += 1;
        }
        while (r.old_start < r.old_end and r.new_start < r.new_end and
            std.mem.eql(u8, lineText(old, old_lines, r.old_end - 1), lineText(new, new_lines, r.new_end - 1)))
        {
            r.old_end -= 1;
            r.new_end -= 1;
            try matches.append(a, .{ .old = r.old_end, .new = r.new_end });
        }
        counts.clearRetainingCapacity();
        for (r.old_start..r.old_end) |i| {
            const gop = try counts.getOrPut(a, lineText(old, old_lines, i));
            if (gop.found_existing) gop.value_ptr.old += 1 else gop.value_ptr.* = .{ .old = 1, .new = 0, .old_line = i };
        }
        for (r.new_start..r.new_end) |i| {
            if (counts.getPtr(lineText(new, new_lines, i))) |c| c.new += 1;
        }
        unique.clearRetainingCapacity();
        for (r.new_start..r.new_end) |i| {
            const c = counts.get(lineText(new, new_lines, i)) orelse continue;
            if (c.old == 1 and c.new == 1) try unique.append(a, .{ .old = c.old_line, .new = i });
        }
        const anchors = try longestIncreasing(a, unique.items);
        if (anchors.len == 0) continue;
        var old_start = r.old_start;
        var new_start = r.new_start;
        for (anchors) |m| {
            try matches.append(a, m);
            try pending.append(a, .{ .old_start = old_start, .old_end = m.old, .new_start = new_start, .new_end = m.new });
            old_start = m.old + 1;
            new_start = m.new + 1;
        }
        try pending.append(a, .{ .old_start = old_start, .old_end = r.old_end, .new_start = new_start, .new_end = r.new_end });
    }
    std.mem.sort(Match, matches.items, {}, Match.before);
    var edits: std.ArrayList(Edit) = .empty;
    var oi: usize = 0;
    var ni: usize = 0;
    for (matches.items) |m| {
        try addEdit(a, &edits, old, new, old_lines, new_lines, oi, m.old, ni, m.new);
        const ol = old_lines[m.old];
        const nl = new_lines[m.new];
        if (!std.mem.eql(u8, old[ol.end..ol.next], new[nl.end..nl.next])) {
            try edits.append(a, .{ .start = ol.end, .old_end = ol.next, .new_end = nl.next, .line_break = true });
        }
        oi = m.old + 1;
        ni = m.new + 1;
    }
    try addEdit(a, &edits, old, new, old_lines, new_lines, oi, old_lines.len, ni, new_lines.len);
    return edits.items;
}

fn splitLines(a: Allocator, text: []const u8) Allocator.Error![]const Line {
    var lines: std.ArrayList(Line) = .empty;
    var start: usize = 0;
    while (start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n');
        const next = if (nl) |i| i + 1 else text.len;
        const end = if (nl) |i| if (i > start and text[i - 1] == '\r') i - 1 else i else text.len;
        try lines.append(a, .{ .start = @intCast(start), .end = @intCast(end), .next = @intCast(next) });
        start = next;
    }
    return lines.items;
}

fn lineText(text: []const u8, lines: []const Line, i: usize) []const u8 {
    return text[lines[i].start..lines[i].end];
}

fn lineOffset(lines: []const Line, text: []const u8, i: usize) u32 {
    return @intCast(if (i < lines.len) lines[i].start else text.len);
}

fn addEdit(
    a: Allocator,
    edits: *std.ArrayList(Edit),
    old: []const u8,
    new: []const u8,
    old_lines: []const Line,
    new_lines: []const Line,
    old_start: usize,
    old_end: usize,
    new_start: usize,
    new_end: usize,
) Allocator.Error!void {
    const os = lineOffset(old_lines, old, old_start);
    const oe = lineOffset(old_lines, old, old_end);
    const ns = lineOffset(new_lines, new, new_start);
    const ne = lineOffset(new_lines, new, new_end);
    if (os == oe and ns == ne) return;
    try edits.append(a, .{ .start = os, .old_end = oe, .new_end = ne });
}

/// `pairs` is sorted by increasing `new`; returns the longest subsequence with strictly increasing
/// `old`
fn longestIncreasing(a: Allocator, pairs: []const Match) Allocator.Error![]const Match {
    if (pairs.len == 0) return &.{};
    const tails = try a.alloc(usize, pairs.len);
    const prev = try a.alloc(?usize, pairs.len);
    var len: usize = 0;
    for (pairs, 0..) |p, i| {
        var lo: usize = 0;
        var hi: usize = len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (pairs[tails[mid]].old < p.old) lo = mid + 1 else hi = mid;
        }
        prev[i] = if (lo > 0) tails[lo - 1] else null;
        tails[lo] = i;
        if (lo == len) len += 1;
    }
    const out = try a.alloc(Match, len);
    var k: ?usize = if (len > 0) tails[len - 1] else null;
    var i: usize = len;
    while (k) |x| : (k = prev[x]) {
        i -= 1;
        out[i] = pairs[x];
    }
    return out;
}
