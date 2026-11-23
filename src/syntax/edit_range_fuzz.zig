//! Property test for the edit range of an incremental reparse (fixed-seed random input +
//! coverage-guided fuzzing): the vector chunk scans find the same byte-exact common prefix and
//! suffix as a byte-by-byte reference, so a reparse takes the same range as the scalar scan.

const std = @import("std");
const testing = std.testing;
const Parse = @import("Parse.zig");
const Entropy = @import("../util/Entropy.zig");

const pieces = [_][]const u8{ "a", "Z", " ", "\n", "\r\n", "\t", "é", "€", "😀", "\xff", "const value = 1; ", "fn f() void {}\n" };

/// The edit range of `old_text` → `text`, scanned one byte at a time
fn refEditRange(old_text: []const u8, text: []const u8) ?Parse.EditRange {
    const prefix = std.mem.indexOfDiff(u8, old_text, text) orelse return null;
    const max_suffix = @min(old_text.len, text.len) - prefix;
    var suffix: usize = 0;
    while (suffix < max_suffix and old_text[old_text.len - 1 - suffix] == text[text.len - 1 - suffix]) suffix += 1;
    return .{ .prefix = @intCast(prefix), .suffix = @intCast(suffix) };
}

fn genText(e: *Entropy, out: *std.ArrayList(u8)) !void {
    const n = e.below(48);
    for (0..n) |_| try out.appendSlice(testing.allocator, e.pick([]const u8, &pieces));
}

fn check(old_text: []const u8, text: []const u8) !void {
    const expected = refEditRange(old_text, text);
    const actual = Parse.editRange(old_text, text);
    try testing.expectEqual(expected == null, actual == null);
    const e = expected orelse return;
    const a = actual.?;
    try testing.expectEqual(e.prefix, a.prefix);
    try testing.expectEqual(e.suffix, a.suffix);
    // The range is byte-exact: the prefix is common and stops at a difference or the end, the
    // suffix is common and stops before the prefix, and together they cover no more than the
    // shorter text
    const shorter = @min(old_text.len, text.len);
    try testing.expect(a.prefix <= shorter and a.suffix <= shorter - a.prefix);
    try testing.expect(std.mem.eql(u8, old_text[0..a.prefix], text[0..a.prefix]));
    try testing.expect(std.mem.eql(u8, old_text[old_text.len - a.suffix ..], text[text.len - a.suffix ..]));
    if (a.prefix < shorter) try testing.expect(old_text[a.prefix] != text[a.prefix]);
    if (a.suffix < shorter - a.prefix) try testing.expect(old_text[old_text.len - 1 - a.suffix] != text[text.len - 1 - a.suffix]);
}

fn checkInput(input: []const u8) !void {
    const a = testing.allocator;
    var e: Entropy = .{ .bytes = input };
    var old: std.ArrayList(u8) = .empty;
    defer old.deinit(a);
    try genText(&e, &old);
    var other: std.ArrayList(u8) = .empty;
    defer other.deinit(a);
    try genText(&e, &other);

    try check(old.items, old.items);
    try check(old.items, other.items);
    try check("", old.items);
    try check(old.items, "");

    // An edit of the first text: the common prefix and suffix usually reach across whole chunks
    var edited: std.ArrayList(u8) = .empty;
    defer edited.deinit(a);
    try edited.appendSlice(a, old.items);
    const at = e.below(edited.items.len + 1);
    const del = @min(e.below(40), edited.items.len - at);
    var insert: std.ArrayList(u8) = .empty;
    defer insert.deinit(a);
    for (0..e.below(3)) |_| try insert.appendSlice(a, e.pick([]const u8, &pieces));
    try edited.replaceRange(a, at, del, insert.items);
    try check(old.items, edited.items);
}

test "edit range properties: fixed-seed random input" {
    var prng: std.Random.DefaultPrng = .init(0x5eed_ed17);
    var buf: [128]u8 = undefined;
    for (0..Entropy.iterations(5_000)) |_| {
        const len = prng.random().uintLessThan(usize, buf.len + 1);
        prng.random().bytes(buf[0..len]);
        try checkInput(buf[0..len]);
    }
}

test "edit range properties: coverage-guided fuzzing" {
    try testing.fuzz({}, struct {
        fn one(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const len = smith.slice(&buf);
            try checkInput(buf[0..len]);
        }
    }.one, .{});
}
