const std = @import("std");
const testing = std.testing;
const lint = @import("lint.zig");
const resolve = @import("../names/resolve.zig");
const World = @import("../names/resolve_test.zig").World;

/// The findings for the first file in the fixture, one per line: the code, the marked text, and the
/// fix (if any) after `=>`
fn expectFindings(fixture: []const u8, expected: []const u8) !void {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(fixture);
    const a = w.arena.allocator();
    var ctx = w.db.beginRead(a);
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = a };
    const text = (try ctx.get(@import("../database.zig").syntax.SourceText, f.files[0])).text;
    var out: std.ArrayList(u8) = .empty;
    for (try lint.findings(&r, f.files[0], null)) |x| {
        try out.print(a, "{s}: {s}", .{ x.rule.code(), text[x.start..x.end] });
        if (x.fix) |fix| try out.print(a, " => {s}", .{fix.text});
        try out.append(a, '\n');
    }
    try testing.expectEqualStrings(expected, out.items);
}

/// The message of the only finding
fn expectMessage(fixture: []const u8, expected: []const u8) !void {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(fixture);
    const a = w.arena.allocator();
    var ctx = w.db.beginRead(a);
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = a };
    const found = try lint.findings(&r, f.files[0], null);
    try testing.expectEqual(1, found.len);
    try testing.expectEqualStrings(expected, found[0].message);
}

test "@as of an operand that already has the type is redundant" {
    try expectFindings(
        \\//- /p/main.zig
        \\const S = struct { len: u8, wide: u16 };
        \\var counter: u32 = 0;
        \\pub fn f(x: u8, s: S, buf: []const u8) usize {
        \\    const y: u8 = 1;
        \\    _ = @as(u8, x);
        \\    _ = @as(u8, y);
        \\    _ = @as(u8, s.len);
        \\    _ = @as(u32, counter);
        \\    _ = @as(u16, x);
        \\    _ = @as(u16, s.len);
        \\    return @as(usize, buf.len);
        \\}
        \\
    ,
        \\lint.redundant_cast: @as(u8, x) => x
        \\lint.redundant_cast: @as(u8, y) => y
        \\lint.redundant_cast: @as(u8, s.len) => s.len
        \\lint.redundant_cast: @as(u32, counter) => counter
        \\lint.redundant_cast: @as(usize, buf.len) => buf.len
        \\
    );
}

test "@intCast, @truncate and @floatCast to the type of their operand are redundant" {
    try expectFindings(
        \\//- /p/main.zig
        \\pub fn f(x: u8, w: u16, g: f32) !u8 {
        \\    const a: u8 = @intCast(x);
        \\    const b: u8 = @intCast(w);
        \\    var c: f32 = @floatCast(g);
        \\    c = @floatCast(g);
        \\    _ = @as(u8, @truncate(x));
        \\    _ = a + b;
        \\    return @intCast(x);
        \\}
        \\pub fn h(x: u8) ?u8 {
        \\    return @intCast(x);
        \\}
        \\
    ,
        \\lint.redundant_cast: @intCast(x) => x
        \\lint.redundant_cast: @floatCast(g) => g
        \\lint.redundant_cast: @floatCast(g) => g
        \\lint.redundant_cast: @truncate(x) => x
        \\lint.redundant_cast: @intCast(x) => x
        \\lint.redundant_cast: @intCast(x) => x
        \\
    );
}

test "casts whose types are not both written as the same primitive name are kept" {
    // `Int` may be another type under another build configuration, a literal is a
    // `comptime_int`, and a capture's type is not written anywhere
    try expectFindings(
        \\//- /p/main.zig
        \\const Int = u8;
        \\pub fn f(x: u8, y: Int, xs: []const u8) void {
        \\    _ = @as(Int, x);
        \\    _ = @as(u8, y);
        \\    _ = @as(u8, 5);
        \\    for (xs) |b| _ = @as(u8, b);
        \\    const z: Int = @intCast(x);
        \\    _ = z;
        \\}
        \\
    , "");
}

test "casts in generic functions and in types they return are not checked" {
    try expectFindings(
        \\//- /p/main.zig
        \\pub fn f(comptime T: type, x: u8) T {
        \\    _ = @as(u8, x);
        \\    return undefined;
        \\}
        \\pub fn List(comptime T: type) type {
        \\    return struct {
        \\        len: u8,
        \\        fn get(self: @This(), x: u8) u8 {
        \\            _ = T;
        \\            _ = self;
        \\            return @as(u8, x);
        \\        }
        \\    };
        \\}
        \\
    , "");
}

test "comparisons that the range of a fixed-width integer type decides" {
    try expectFindings(
        \\//- /p/main.zig
        \\pub fn f(x: u8, y: i8, n: usize) u32 {
        \\    var c: u32 = 0;
        \\    if (x < 256) c += 1;
        \\    if (x <= 255) c += 1;
        \\    if (x >= 0) c += 1;
        \\    if (x < 0) c += 1;
        \\    if (x == 300) c += 1;
        \\    if (x != 0x100) c += 1;
        \\    if (256 > x) c += 1;
        \\    if (y >= -128) c += 1;
        \\    if (y < -200) c += 1;
        \\    if (x < 255) c += 1;
        \\    if (x == 0) c += 1;
        \\    if (y > -128) c += 1;
        \\    if (n <= 0xFFFFFFFF) c += 1;
        \\    if (x < 1_000_000_000_000_000_000_000_000) c += 1;
        \\    return c;
        \\}
        \\
    ,
        \\lint.constant_comparison: x < 256
        \\lint.constant_comparison: x <= 255
        \\lint.constant_comparison: x >= 0
        \\lint.constant_comparison: x < 0
        \\lint.constant_comparison: x == 300
        \\lint.constant_comparison: x != 0x100
        \\lint.constant_comparison: 256 > x
        \\lint.constant_comparison: y >= -128
        \\lint.constant_comparison: y < -200
        \\lint.constant_comparison: x < 1_000_000_000_000_000_000_000_000
        \\
    );
}

test "a comparison message states the result and the type" {
    try expectMessage(
        \\//- /p/main.zig
        \\pub fn f(x: u8) bool {
        \\    return x < 256;
        \\}
        \\
    , "comparison is always true: no value of type `u8` gives another result");
}

test "an errdefer in a function that cannot return an error never runs" {
    try expectFindings(
        \\//- /p/main.zig
        \\fn cleanup() void {}
        \\pub fn f() void {
        \\    errdefer cleanup();
        \\}
        \\pub fn g() anyerror {
        \\    errdefer cleanup();
        \\    return error.A;
        \\}
        \\
    ,
        \\lint.dead_errdefer: errdefer cleanup();
        \\
    );
}

test "an errdefer with no error return after it in its block never runs" {
    try expectFindings(
        \\//- /p/main.zig
        \\fn cleanup() void {}
        \\fn make() !u8 {
        \\    return 1;
        \\}
        \\pub fn f() !u8 {
        \\    const x = try make();
        \\    errdefer cleanup();
        \\    return x;
        \\}
        \\pub fn g(c: bool) !u8 {
        \\    if (c) {
        \\        errdefer cleanup();
        \\        _ = c;
        \\    }
        \\    return make();
        \\}
        \\pub fn h() !u8 {
        \\    errdefer cleanup();
        \\    const x = try make();
        \\    return x;
        \\}
        \\pub fn k() !u8 {
        \\    errdefer cleanup();
        \\    return make();
        \\}
        \\pub fn m(c: bool) !u8 {
        \\    errdefer cleanup();
        \\    if (c) return error.Bad;
        \\    return 1;
        \\}
        \\
    ,
        \\lint.dead_errdefer: errdefer cleanup();
        \\lint.dead_errdefer: errdefer cleanup();
        \\
    );
}

test "breaking out of a block with an error does not run its errdefer" {
    try expectFindings(
        \\//- /p/main.zig
        \\fn cleanup() void {}
        \\pub fn f() !void {
        \\    (blk: {
        \\        errdefer cleanup();
        \\        break :blk error.X;
        \\    }) catch return error.Y;
        \\}
        \\
    ,
        \\lint.dead_errdefer: errdefer cleanup();
        \\
    );
}

test "an errdefer asserting that no error follows is not reported" {
    try expectFindings(
        \\//- /p/main.zig
        \\pub fn f() !u8 {
        \\    errdefer comptime unreachable;
        \\    return 1;
        \\}
        \\pub fn g() !u8 {
        \\    errdefer unreachable;
        \\    return 1;
        \\}
        \\
    , "");
}

test "a file with syntax errors gets no lint hints" {
    try expectFindings(
        \\//- /p/main.zig
        \\pub fn f(x: u8) bool {
        \\    return x < 256
        \\}
        \\
    , "");
}
