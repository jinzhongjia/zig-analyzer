//! Property tests for the parser (fixed-seed random input + coverage-guided fuzzing):
//!
//! 1. Any byte input parses into a lossless syntax tree without crashing or hanging;
//! 2. For any edit to any text, local reparse gives exactly the same result as a full parse
//!    (including reuse chains formed by consecutive edits), including deeply nested text.

const std = @import("std");
const testing = std.testing;
const Parse = @import("Parse.zig");
const Entropy = @import("../util/Entropy.zig");

/// Pieces favor structural tokens of Zig syntax, which more readily trigger the various
/// recovery and reparse paths
const pieces = [_][]const u8{
    "{",      "}",   "(",      ")",      "[",     "]",     ";",        ",",     ".",      ":",
    "=",      "\n",  " ",      "\"",     "'",     "//",    "///",      "\\\\",  "fn",     "f",
    "const",  "var", "pub",    "struct", "enum",  "union", "if",       "else",  "while",  "for",
    "switch", "=>",  "return", "try",    "catch", "|x|",   "comptime", "test",  "error",  "!",
    "?",      "*",   "&",      "..",     "...",   "@as",   "1",        "0x1p3", "blk:",   "break",
    ".{",     "a.b", "x()",    "u32",    "\t",    "\r\n",  "\xff",     "\x00",  "extern", "packed",
};

fn repeat(comptime s: []const u8, comptime n: usize) []const u8 {
    comptime {
        @setEvalBranchQuota(100 * s.len * n);
        var buf: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(buf[i * s.len ..][0..s.len], s);
        const final = buf;
        return &final;
    }
}

/// Long pieces: a few of them together give over a thousand levels of nesting
const deep_pieces = [_][]const u8{
    repeat("(", 100),  repeat(")", 100),  repeat("{", 100),              repeat("}", 100),
    repeat("!", 100),  repeat("f(", 100), repeat("if (a) b else ", 100), repeat("1 + ", 100),
    repeat(".b", 100), repeat("?", 100),  repeat("[]", 100),
};

/// Picks a piece: with `deep`, about 1 in 8 is a long piece
fn pickPiece(e: *Entropy, deep: bool) []const u8 {
    if (deep and e.below(8) == 0) return e.pick([]const u8, &deep_pieces);
    return e.pick([]const u8, &pieces);
}

fn genSource(e: *Entropy, out: *std.ArrayList(u8), deep: bool) !void {
    const n = e.below(64);
    for (0..n) |_| try out.appendSlice(testing.allocator, pickPiece(e, deep));
}

fn expectLossless(p: *const Parse, text: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeText(p.rootNode(), &out.writer);
    try testing.expectEqualStrings(text, out.written());
}

fn writeText(n: @import("tree.zig").SyntaxNode, w: *std.Io.Writer) !void {
    var it = n.children();
    while (it.next()) |e| switch (e) {
        .node => |c| try writeText(c, w),
        .token => |t| try w.writeAll(t.text),
    };
}

fn checkAll(input: []const u8) !void {
    const a = testing.allocator;
    // Raw bytes used directly as source
    for ([_]Parse.Mode{ .zig, .zon }) |mode| {
        const p = try Parse.create(a, input, mode);
        defer p.destroy();
        try expectLossless(p, input);
    }
    try checkEdits(input, false);
}

/// Builds source from pieces, then applies random edits in succession
fn checkEdits(input: []const u8, deep: bool) !void {
    const a = testing.allocator;
    var e: Entropy = .{ .bytes = input };
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    try genSource(&e, &text, deep);
    var chain = try Parse.create(a, text.items, .zig);
    defer chain.destroy();
    try expectLossless(chain, text.items);

    const edits = e.below(6);
    for (0..edits) |_| {
        const at = e.below(text.items.len + 1);
        const del = @min(e.below(5), text.items.len - at);
        const ins = if (e.below(2) == 0) pickPiece(&e, deep) else "";
        try text.replaceRange(a, at, del, ins);

        const inc = try Parse.reparse(a, chain, text.items);
        chain.destroy();
        chain = inc;
        const full = try Parse.create(a, text.items, .zig);
        defer full.destroy();
        if (!inc.sameAs(full)) {
            std.debug.print("incremental and full parse differ:\n---\n{s}\n---\n", .{text.items});
            return error.TestUnexpectedResult;
        }
        try expectLossless(inc, text.items);
    }
}

test "parser properties: fixed-seed random input" {
    var prng: std.Random.DefaultPrng = .init(0x9a25_e11e);
    var buf: [192]u8 = undefined;
    for (0..Entropy.iterations(3_000)) |_| {
        const len = prng.random().uintLessThan(usize, buf.len + 1);
        prng.random().bytes(buf[0..len]);
        try checkAll(buf[0..len]);
    }
}

test "parser properties: random edits on deeply nested text" {
    var prng: std.Random.DefaultPrng = .init(0xdee9_11e5);
    var buf: [192]u8 = undefined;
    for (0..Entropy.iterations(300)) |_| {
        prng.random().bytes(&buf);
        try checkEdits(&buf, true);
    }
}

test "parser properties: coverage-guided fuzzing" {
    try testing.fuzz({}, struct {
        fn one(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [1024]u8 = undefined;
            const len = smith.slice(&buf);
            try checkAll(buf[0..len]);
        }
    }.one, .{ .corpus = &.{ "fn f() void { a(); }", "const S = struct { a: u32 };", "test { if (a) {} else {} }" } });
}
