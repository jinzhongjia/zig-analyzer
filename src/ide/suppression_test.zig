const std = @import("std");
const testing = std.testing;
const suppression = @import("suppression.zig");
const Parse = @import("../syntax/Parse.zig");
const offsets = @import("../util/offsets.zig");

const Case = struct { line: u32, code: []const u8, expected: bool };

fn expectSuppressed(text: []const u8, cases: []const Case) !void {
    const a = testing.allocator;
    const parse = try Parse.create(a, text, .zig);
    defer parse.destroy();
    var lines = try offsets.LineIndex.init(a, parse.source);
    defer lines.deinit(a);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const map = try suppression.parse(arena.allocator(), parse, lines);
    for (cases) |c| testing.expectEqual(c.expected, map.isSuppressed(c.line, c.line, c.code)) catch |err| {
        std.debug.print("{s} at line {d}: expected {}\n", .{ c.code, c.line, c.expected });
        return err;
    };
}

test "the next line with code is suppressed" {
    try expectSuppressed(
        \\const a = 1;
        \\// zig-analyzer-disable-next-line
        \\const b = 2;
        \\const c = 3;
        \\
    , &.{
        .{ .line = 0, .code = "naming.type", .expected = false },
        .{ .line = 1, .code = "naming.type", .expected = false },
        .{ .line = 2, .code = "naming.type", .expected = true },
        .{ .line = 3, .code = "naming.type", .expected = false },
    });
}

test "a next-line directive can name codes" {
    try expectSuppressed(
        \\// zig-analyzer-disable-next-line: naming, unused
        \\const a = 1;
        \\
    , &.{
        .{ .line = 1, .code = "naming.type", .expected = true },
        .{ .line = 1, .code = "unused.declaration", .expected = true },
        .{ .line = 1, .code = "inactive", .expected = false },
    });
}

test "a next-line directive skips blank lines and doc comments" {
    try expectSuppressed(
        \\// zig-analyzer-disable-next-line
        \\
        \\/// It is documented.
        \\const a = 1;
        \\
    , &.{
        .{ .line = 2, .code = "naming.type", .expected = false },
        .{ .line = 3, .code = "naming.type", .expected = true },
    });
}

test "a trailing next-line directive applies to the line after it" {
    try expectSuppressed(
        \\const a = 1; // zig-analyzer-disable-next-line
        \\const b = 2;
        \\
    , &.{
        .{ .line = 0, .code = "naming.type", .expected = false },
        .{ .line = 1, .code = "naming.type", .expected = true },
    });
}

test "disable and enable cover a range" {
    try expectSuppressed(
        \\const a = 1;
        \\// zig-analyzer-disable: naming
        \\const b = 2;
        \\// zig-analyzer-enable: naming
        \\const c = 3;
        \\
    , &.{
        .{ .line = 0, .code = "naming.type", .expected = false },
        .{ .line = 2, .code = "naming.type", .expected = true },
        .{ .line = 2, .code = "unused.declaration", .expected = false },
        .{ .line = 4, .code = "naming.type", .expected = false },
    });
}

test "enable without codes closes every range" {
    try expectSuppressed(
        \\// zig-analyzer-disable: naming
        \\// zig-analyzer-disable: unused
        \\const a = 1;
        \\// zig-analyzer-enable
        \\const b = 2;
        \\
    , &.{
        .{ .line = 2, .code = "naming.type", .expected = true },
        .{ .line = 2, .code = "unused.declaration", .expected = true },
        .{ .line = 4, .code = "naming.type", .expected = false },
        .{ .line = 4, .code = "unused.declaration", .expected = false },
    });
}

test "a code names its family at the dot boundary" {
    try expectSuppressed(
        \\// zig-analyzer-disable: naming
        \\const a = 1;
        \\// zig-analyzer-enable: naming
        \\// zig-analyzer-disable: naming.t
        \\const b = 2;
        \\
    , &.{
        .{ .line = 1, .code = "naming.type_function", .expected = true },
        .{ .line = 4, .code = "naming.type", .expected = false },
        .{ .line = 4, .code = "naming.type_function", .expected = false },
    });
}

test "repeated disables of the same code close together" {
    try expectSuppressed(
        \\// zig-analyzer-disable
        \\// zig-analyzer-disable
        \\const a = 1;
        \\// zig-analyzer-enable
        \\const b = 2;
        \\
    , &.{
        .{ .line = 2, .code = "naming.type", .expected = true },
        .{ .line = 4, .code = "naming.type", .expected = false },
    });
}

test "a range without enable extends to the end of the file" {
    try expectSuppressed(
        \\const a = 1;
        \\// zig-analyzer-disable: unused
        \\const b = 2;
        \\
    , &.{
        .{ .line = 2, .code = "unused.declaration", .expected = true },
        .{ .line = 2, .code = "naming.type", .expected = false },
    });
}

test "a directive in a string literal is not a directive" {
    try expectSuppressed(
        \\const s = "// zig-analyzer-disable";
        \\const a = 1;
        \\
    , &.{
        .{ .line = 1, .code = "naming.type", .expected = false },
    });
}

test "a directive in a doc comment is not a directive" {
    try expectSuppressed(
        \\/// zig-analyzer-disable
        \\const a = 1;
        \\
    , &.{
        .{ .line = 1, .code = "naming.type", .expected = false },
    });
}

test "a longer directive name is not a directive" {
    try expectSuppressed(
        \\// zig-analyzer-disabled
        \\const a = 1;
        \\
    , &.{
        .{ .line = 1, .code = "naming.type", .expected = false },
    });
}

test "a trailing disable covers the line it is written on" {
    try expectSuppressed(
        \\const a = 1; // zig-analyzer-disable: naming
        \\const b = 2;
        \\
    , &.{
        .{ .line = 0, .code = "naming.type", .expected = true },
        .{ .line = 1, .code = "naming.type", .expected = true },
    });
}
