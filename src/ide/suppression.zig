//! Inline suppression comments for analyzer-owned diagnostics. Compiler diagnostics are never
//! suppressed: published diagnostics must equal the compiler's output (see `docs/diagnostics.md`).
//!
//! Directives are line comments; they are read from the tokens of the parse, not from the raw
//! text, so a `//` inside a string or a doc comment is not a directive:
//!
//!     // zig-analyzer-disable-next-line
//!     // zig-analyzer-disable-next-line: naming, unused
//!     // zig-analyzer-disable
//!     // zig-analyzer-disable: naming.type
//!     // zig-analyzer-enable
//!     // zig-analyzer-enable: naming.type
//!
//! A code in a directive names itself and its family (`naming` covers `naming.type`; see
//! `hints.familyMatches`), and no code means every analyzer-owned hint.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Parse = @import("../syntax/Parse.zig");
const tree = @import("../syntax/tree.zig");
const SyntaxNode = tree.SyntaxNode;
const SyntaxToken = tree.SyntaxToken;
const kind_mod = @import("../syntax/kind.zig");
const offsets = @import("../util/offsets.zig");
const hints = @import("hints.zig");

/// A range of lines a `disable` directive suppresses, until the matching `enable`
pub const Range = struct {
    /// First line the range covers
    start: u32,
    /// Line the range ends at, exclusive; null extends to the end of the file
    end: ?u32,
    /// Codes the range suppresses; empty means every analyzer-owned hint
    codes: []const []const u8,
};

/// A `disable-next-line` directive: the next line with code after the comment
pub const NextLine = struct {
    line: u32,
    codes: []const []const u8,
};

pub const Map = struct {
    next_lines: []const NextLine = &.{},
    ranges: []const Range = &.{},

    /// Whether a diagnostic covering the lines `start` through `end` (inclusive) with `code` is
    /// suppressed: a directive anywhere in its range applies to the whole diagnostic
    pub fn isSuppressed(m: Map, start: u32, end: u32, code: []const u8) bool {
        for (m.next_lines) |n| if (start <= n.line and n.line <= end and matches(n.codes, code)) return true;
        for (m.ranges) |r| {
            if (end < r.start) continue;
            if (r.end) |r_end| if (start >= r_end) continue;
            if (matches(r.codes, code)) return true;
        }
        return false;
    }
};

fn matches(codes: []const []const u8, code: []const u8) bool {
    if (codes.len == 0) return true;
    for (codes) |c| if (hints.familyMatches(c, code)) return true;
    return false;
}

const Kind = enum { next_line, disable, enable };

const Directive = struct {
    kind: Kind,
    /// Line of the comment (0-based)
    line: u32,
    /// Empty means every analyzer-owned hint
    codes: []const []const u8,
};

/// The directives of a file, with the lines they cover
pub fn parse(a: Allocator, result: *const Parse, lines: offsets.LineIndex) Allocator.Error!Map {
    var collector: Collector = .{ .a = a, .lines = lines };
    try collector.node(result.rootNode());

    var next_lines: std.ArrayList(NextLine) = .empty;
    var ranges: std.ArrayList(Range) = .empty;
    var active_all: ?u32 = null;
    var active_codes: std.StringHashMap(u32) = .init(a);
    defer active_codes.deinit();

    for (collector.directives.items) |d| switch (d.kind) {
        .next_line => if (nextCodeLine(collector.code_lines.items, d.line)) |line| {
            try next_lines.append(a, .{ .line = line, .codes = d.codes });
        },
        .disable => if (d.codes.len == 0) {
            if (active_all == null) active_all = d.line;
        } else for (d.codes) |code| {
            // The earliest disable wins, so nested disables of the same code close together
            if (!active_codes.contains(code)) try active_codes.put(code, d.line);
        },
        .enable => if (d.codes.len == 0) {
            if (active_all) |start| try ranges.append(a, .{ .start = start, .end = d.line, .codes = &.{} });
            active_all = null;
            var it = active_codes.iterator();
            while (it.next()) |entry| try ranges.append(a, .{
                .start = entry.value_ptr.*,
                .end = d.line,
                .codes = try single(a, entry.key_ptr.*),
            });
            active_codes.clearRetainingCapacity();
        } else for (d.codes) |code| {
            if (active_codes.fetchRemove(code)) |entry| try ranges.append(a, .{
                .start = entry.value,
                .end = d.line,
                .codes = try single(a, code),
            });
        },
    };
    if (active_all) |start| try ranges.append(a, .{ .start = start, .end = null, .codes = &.{} });
    var it = active_codes.iterator();
    while (it.next()) |entry| try ranges.append(a, .{
        .start = entry.value_ptr.*,
        .end = null,
        .codes = try single(a, entry.key_ptr.*),
    });
    return .{ .next_lines = next_lines.items, .ranges = ranges.items };
}

fn single(a: Allocator, code: []const u8) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, 1);
    out[0] = code;
    return out;
}

/// The first line after `after` that contains code
fn nextCodeLine(code_lines: []const u32, after: u32) ?u32 {
    for (code_lines) |line| if (line > after) return line;
    return null;
}

const Collector = struct {
    a: Allocator,
    lines: offsets.LineIndex,
    /// Lines with at least one token that is not whitespace or a comment
    code_lines: std.ArrayList(u32) = .empty,
    directives: std.ArrayList(Directive) = .empty,

    fn node(self: *Collector, n: SyntaxNode) Allocator.Error!void {
        var children = n.children();
        while (children.next()) |child| switch (child) {
            .node => |c| try self.node(c),
            .token => |t| try self.token(t),
        };
    }

    fn token(self: *Collector, t: SyntaxToken) Allocator.Error!void {
        const line = self.lines.lineOf(t.offset);
        if (t.kind == .line_comment) {
            if (try directive(self.a, t.text, line)) |d| try self.directives.append(self.a, d);
            return;
        }
        if (kind_mod.isTrivia(t.kind) or t.kind == .doc_comment or t.kind == .container_doc_comment) return;
        if (self.code_lines.items.len > 0 and self.code_lines.items[self.code_lines.items.len - 1] == line) return;
        try self.code_lines.append(self.a, line);
    }
};

fn directive(a: Allocator, text: []const u8, line: u32) Allocator.Error!?Directive {
    if (!std.mem.startsWith(u8, text, "//")) return null;
    const rest = std.mem.trimStart(u8, text[2..], " \t");
    const names = [_]struct { []const u8, Kind }{
        .{ "zig-analyzer-disable-next-line", .next_line },
        .{ "zig-analyzer-disable", .disable },
        .{ "zig-analyzer-enable", .enable },
    };
    for (names) |entry| {
        if (!std.mem.startsWith(u8, rest, entry[0])) continue;
        const after = std.mem.trimStart(u8, rest[entry[0].len..], " \t");
        if (after.len == 0) return .{ .kind = entry[1], .line = line, .codes = &.{} };
        if (after[0] != ':') return null;
        return .{ .kind = entry[1], .line = line, .codes = try codeList(a, after[1..]) };
    }
    return null;
}

fn codeList(a: Allocator, list: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |part| {
        const code = std.mem.trim(u8, part, " \t");
        if (code.len > 0) try out.append(a, code);
    }
    return out.items;
}

test {
    _ = @import("suppression_test.zig");
}
