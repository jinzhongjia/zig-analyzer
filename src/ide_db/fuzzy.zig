//! Fuzzy matching for completion, ported from gopls: `gopls/internal/fuzzy/matcher.go` and
//! `input.go` of golang/tools `5dd9c3348317` (Copyright 2019 The Go Authors; see
//! tools/gopls/LICENSE for the copyright and license). The lengths of the input and the candidate
//! are not limited: gopls truncates them to 63 and 127 bytes, and truncation changes whether long
//! names can match.
//!
//! The characters of the input appear in the candidate in order, case-insensitively. Bonuses go
//! to matches at word starts (an uppercase letter, or a letter or digit after a non-alphanumeric
//! character), consecutive matches, matches in the last segment of the candidate (separated by
//! `.` / `:`), and matches whose case agrees with the input (word starts also count when the
//! input is all lowercase); penalties go to skipping the start of the first or the last segment
//! and to starting a match in the middle of a word. When the first character matches in the
//! middle of a word, the first min(3, input length) characters of the input must match
//! consecutively from there; a word start in the input cannot match a character in the middle of
//! a word in the candidate; a match with two or more fragments of fewer than 3 characters in the
//! middle of words does not count. Scores are normalized to (0, 1], and are 1 when the input
//! equals the candidate (case-insensitively).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Role = enum(u8) {
    /// Not part of a word: whitespace, punctuation
    none,
    /// Segment separator: `.`, `:`
    sep,
    /// Lowercase letters and digits inside a word
    tail,
    /// An uppercase letter in a run of uppercase letters that does not start a word
    uc_tail,
    head,
};

const CharType = enum(u8) { none, punct, lower, upper };

/// Non-ASCII bytes count as lowercase letters; so do digits
fn charType(c: u8) CharType {
    if (c >= 0x80 or std.ascii.isLower(c) or std.ascii.isDigit(c)) return .lower;
    if (std.ascii.isUpper(c)) return .upper;
    return switch (c) {
        '.', '/', ':' => .punct,
        else => .none,
    };
}

/// The role of each byte in `text`, written into `out` (the same length as `text`)
pub fn roles(text: []const u8, out: []Role) void {
    var prev: CharType = .none;
    var prev2: CharType = .none;
    for (text, out, 0..) |c, *o, i| {
        const curr = charType(c);
        var role: Role = .none;
        switch (curr) {
            .lower => role = if (prev == .none or prev == .punct) .head else .tail,
            .upper => {
                role = .head;
                // The second of two uppercase letters at the end: `C` in `aBC`
                if (prev == .upper and i + 1 == text.len) role = .uc_tail;
            },
            .punct => if (c == '.' or c == ':') {
                role = .sep;
            },
            .none => {},
        }
        // The previous two characters are uppercase and the current one is not lowercase: the
        // previous one does not start a word (`B` in `ABC` and `AB.`)
        if (curr != .lower and i > 1 and out[i - 1] == .head and prev2 == .upper and (out[i - 2] == .head or out[i - 2] == .uc_tail)) {
            out[i - 1] = .uc_tail;
        }
        o.* = role;
        prev2 = prev;
        prev = curr;
    }
}

const min_score = -10000;
const consecutive_bonus = 2;
const max_char_score = 4;

/// A cell of the score table: the best score up to here, and which cell of the previous row it
/// comes from (0: the previous character did not match, 1: it matched)
const Entry = struct { val: i32, prev: u1 };
const Cell = [2]Entry;

pub const Matcher = struct {
    pattern: []const u8,
    lower: []const u8,
    /// The first min(3, length) characters of the input (lowercased)
    short: []const u8,
    pattern_roles: []const Role,
    /// The input contains uppercase letters: only matches in the same case get a bonus
    case_sensitive: bool,
    arena: Allocator,
    /// The following are reused across candidates
    text: std.ArrayList(u8) = .empty,
    text_lower: std.ArrayList(u8) = .empty,
    text_roles: std.ArrayList(Role) = .empty,
    table: std.ArrayList(Cell) = .empty,

    pub fn init(arena: Allocator, pattern: []const u8) Allocator.Error!Matcher {
        const lower = try std.ascii.allocLowerString(arena, pattern);
        const pattern_roles = try arena.alloc(Role, pattern.len);
        roles(pattern, pattern_roles);
        return .{
            .pattern = pattern,
            .lower = lower,
            .short = lower[0..@min(3, lower.len)],
            .pattern_roles = pattern_roles,
            .case_sensitive = !std.mem.eql(u8, pattern, lower),
            .arena = arena,
        };
    }

    /// Score of the concatenation of `parts` in order (see `score`)
    pub fn scoreJoined(m: *Matcher, parts: []const []const u8) Allocator.Error!?f32 {
        m.text.clearRetainingCapacity();
        for (parts) |part| try m.text.appendSlice(m.arena, part);
        return m.score(m.text.items);
    }

    /// null when it does not match; an empty input matches everything with a score of 1
    pub fn score(m: *Matcher, text: []const u8) Allocator.Error!?f32 {
        if (m.pattern.len == 0) return 1;
        try m.text_lower.resize(m.arena, text.len);
        const lower = m.text_lower.items;
        for (text, lower) |c, *l| l.* = std.ascii.toLower(c);
        if (!isSubsequence(m.lower, lower)) return null;
        try m.text_roles.resize(m.arena, text.len);
        roles(text, m.text_roles.items);
        const result = try m.compute(text, lower);
        if (result <= min_score / 2 or m.poor(text.len)) return null;
        if (m.pattern.len == text.len) return 1;
        const normalized = @min(@as(f32, @floatFromInt(@max(result, 0))) / @as(f32, @floatFromInt(max_char_score * m.pattern.len)), 1);
        return if (normalized > 0) normalized else null;
    }

    fn cell(m: *Matcher, i: usize, j: usize) *Cell {
        return &m.table.items[i * (m.pattern.len + 1) + j];
    }

    fn bestK(m: *Matcher, i: usize, j: usize) u1 {
        const c = m.cell(i, j);
        return if (c[0].val < c[1].val) 1 else 0;
    }

    fn compute(m: *Matcher, text: []const u8, lower: []const u8) Allocator.Error!i32 {
        const pattern_len = m.pattern.len;
        try m.table.resize(m.arena, (text.len + 1) * (pattern_len + 1));
        const text_roles = m.text_roles.items;
        for (0..pattern_len + 1) |j| m.cell(0, j).* = .{ .{ .val = min_score, .prev = 0 }, .{ .val = min_score, .prev = 0 } };
        m.cell(0, 0)[0] = .{ .val = 0, .prev = 0 };

        var segments_left: usize = 1;
        var last_segment_start: usize = 0;
        for (text_roles, 0..) |role, i| if (role == .sep) {
            segments_left += 1;
            last_segment_start = i + 1;
        };

        for (1..text.len + 1) |i| {
            const role = text_roles[i - 1];
            if (role == .sep and segments_left > 1) segments_left -= 1;
            // Skipping the start of the first or the last segment
            const skip_penalty: i32 = if (i == 1 or i - 1 == last_segment_start) 1 else 0;
            for (0..pattern_len + 1) |j| {
                const here = m.cell(i, j);
                here[1] = .{ .val = min_score, .prev = 0 };
                // This character does not match
                const k = m.bestK(i - 1, j);
                var skip = m.cell(i - 1, j)[k].val;
                // Characters after the last matched character are not penalized
                if (j != pattern_len) skip -= skip_penalty;
                here[0] = .{ .val = skip, .prev = k };

                if (j == 0 or lower[i - 1] != m.lower[j - 1]) continue;
                const pattern_role = m.pattern_roles[j - 1];
                if (role == .tail and pattern_role == .head) {
                    // A word start in the input cannot match a character in the middle of a word,
                    // except for the first character: it can when the first few characters of the
                    // input match consecutively from here
                    if (j > 1 or !std.mem.startsWith(u8, lower[i - 1 ..], m.short)) continue;
                }

                var char_score: i32 = 0;
                // In the last segment of the candidate
                if (segments_left <= 1) char_score += 1;
                // Same case; when the input is all lowercase (no word boundaries), word starts
                // in the candidate also count
                if (text[i - 1] == m.pattern[j - 1] or (role == .head and !m.case_sensitive)) char_score += 1;
                if (role == .tail and pattern_role == .head) char_score -= 1;
                // The first character matches in the middle of a word
                if (j == 1 and role == .tail) char_score -= 4;

                for ([_]u1{ 0, 1 }) |prev_k| {
                    var sc = m.cell(i - 1, j - 1)[prev_k].val + char_score;
                    // Consecutive match; a match at the start or at the start of the last segment
                    // also counts, so that a prefix normalizes to a score of 1
                    if (prev_k == 1 or i - 1 == 0 or i - 1 == last_segment_start) sc += consecutive_bonus;
                    // Starting a match in the middle of a segment (the previous character
                    // did not match)
                    if (prev_k == 0 and (role == .tail or role == .uc_tail)) sc -= 3;
                    if (sc > here[1].val) here[1] = .{ .val = sc, .prev = prev_k };
                }
            }
        }
        return m.cell(text.len, pattern_len)[m.bestK(text.len, pattern_len)].val;
    }

    /// The best match has two or more fragments of fewer than 3 characters in the middle of words
    fn poor(m: *Matcher, text_len: usize) bool {
        if (m.pattern.len < 2) return false;
        var i = text_len;
        var j = m.pattern.len;
        var k = m.bestK(i, j);
        var counter: usize = 0;
        var len: usize = 0;
        while (i > 0) : (i -= 1) {
            const take = k == 1;
            k = m.cell(i, j)[k].prev;
            if (take) {
                len += 1;
                if (k == 0 and len < 3 and m.text_roles.items[i - 1] == .tail) {
                    counter += 1;
                    if (counter > 1) return true;
                }
                j -= 1;
            } else len = 0;
        }
        return false;
    }
};

fn isSubsequence(pattern: []const u8, text: []const u8) bool {
    var i: usize = 0;
    for (text) |c| {
        if (c == pattern[i]) {
            i += 1;
            if (i == pattern.len) return true;
        }
    }
    return false;
}

const testing = std.testing;

/// The tests are taken from `matcher_test.go` and `input_test.go` of gopls
fn scoreOf(pattern: []const u8, text: []const u8) !f32 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var m: Matcher = try .init(arena.allocator(), pattern);
    return try m.score(text) orelse 0;
}

test "fuzzy roles" {
    const cases = [_][2][]const u8{
        .{ "abc::def::goo", "Ccc//Ccc//Ccc" },
        .{ "proto::Message", "Ccccc//Ccccccc" },
        .{ "AbstractSWTFactory", "CcccccccCuuCcccccc" },
        .{ "Abs012", "Cccccc" },
        .{ "/", " " },
        .{ "fOO", "CCu" },
        .{ "fo_oo.o_oo", "Cc Cc/C Cc" },
    };
    for (cases) |c| {
        var out: [32]Role = undefined;
        roles(c[0], out[0..c[0].len]);
        var got: [32]u8 = undefined;
        for (out[0..c[0].len], got[0..c[0].len]) |r, *g| g.* = " /cuC"[@backingInt(r)];
        try testing.expectEqualStrings(c[1], got[0..c[0].len]);
    }
}

test "fuzzy scores" {
    const cases = [_]struct { []const u8, []const u8, f32 }{
        .{ "abc", "abc", 1 },
        .{ "abc", "Abc", 1 },
        .{ "abc", "Abcdef", 1 },
        .{ "strc", "StrCat", 1 },
        .{ "abc_def", "abc_def_xyz", 1 },
        .{ "abcdef", "abc_def_xyz", 0.91667 },
        .{ "abcxyz", "abc_def_xyz", 0.91667 },
        .{ "sc", "StrCat", 0.75 },
        .{ "abc", "AbstrBasicCtor", 0.83333 },
        .{ "foo", "abc::foo", 0.91667 },
        .{ "afoo", "abc::foo", 0.9375 },
        .{ "abr", "abc::bar", 0.5 },
        .{ "br", "abc::bar", 0.25 },
        .{ "aar", "abc::bar", 0.41667 },
        .{ "edin", "foo.TexteditNum", 0.125 },
        .{ "ediu", "foo.TexteditNum", 0 },
        .{ "up", "unique_ptr", 0.75 },
        .{ "up", "upper_bound", 1 },
        .{ "", "def", 1 },
        .{ "abc", "def", 0 },
        .{ "abc", "abd", 0 },
        .{ "U", "ErrUnexpectedEOF.Error", 0 },
    };
    for (cases) |c| {
        testing.expectApproxEqAbs(c[2], try scoreOf(c[0], c[1]), 0.00001) catch |err| {
            std.debug.print("score({s}, {s})\n", .{ c[0], c[1] });
            return err;
        };
    }
}

test "fuzzy match rejects short matches in the middle of words" {
    const cases = [_][2][]const u8{
        .{ "TEdit", "foo.Textedit" },
        .{ "ee", "foo.Textedit" },
        .{ "exdi", "foo.Textedit" },
        .{ "exdit", "foo.Textedit" },
        .{ "edt", "foo.Textedit" },
    };
    for (cases) |c| try testing.expectEqual(0, try scoreOf(c[0], c[1]));
    // A match that starts in the middle of a word with a non-positive score (used only for
    // highlighting in gopls) does not count either
    try testing.expectEqual(0, try scoreOf("ex", "foo.Textedit"));
    for ([_][2][]const u8{ .{ "extdit", "foo.Textedit" }, .{ "edit", "foo.Textedit" } }) |c| {
        try testing.expect(try scoreOf(c[0], c[1]) > 0);
    }
}

test "fuzzy match orders candidates" {
    const cases = [_]struct { []const u8, []const []const []const u8 }{
        .{ "Foo", &.{ &.{"Barfoo"}, &.{"Faoo"}, &.{"F_o_o"}, &.{ "FaoFooa", "BarFoo" }, &.{ "F__oo", "F_oo" }, &.{ "FooA", "FooBar", "Foo" } } },
        .{ "U", &.{ &.{"ErrUnexpectedEOF.Error"}, &.{"ErrUnexpectedEOF"} } },
        .{ "N", &.{ &.{"name"}, &.{"Name"} } },
    };
    for (cases) |c| {
        var prev: f32 = -1;
        for (c[1]) |group| {
            const first = try scoreOf(c[0], group[0]);
            for (group[1..]) |other| try testing.expectEqual(first, try scoreOf(c[0], other));
            try testing.expect(first > prev);
            try testing.expect(first >= 0 and first <= 1);
            prev = first;
        }
    }
}

test "fuzzy match does not truncate long candidates" {
    var long: [208]u8 = undefined;
    @memcpy(long[0..4], "std.");
    @memset(long[4..204], 'a');
    @memcpy(long[204..], ".eql");
    try testing.expect(try scoreOf("eql", &long) > 0);
}
