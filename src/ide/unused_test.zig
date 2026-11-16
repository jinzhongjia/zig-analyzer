const std = @import("std");
const testing = std.testing;
const unused = @import("unused.zig");
const resolve = @import("../names/resolve.zig");
const World = @import("../names/resolve_test.zig").World;

/// Names of the findings for the first file in the fixture, one per line
fn expectFindings(fixture: []const u8, expected: []const u8) !void {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.fixture(fixture);
    const a = w.arena.allocator();
    var ctx = w.db.beginRead(a);
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = a };
    var out: std.ArrayList(u8) = .empty;
    for (try unused.findings(&r, f.files[0])) |x| try out.print(a, "{s}\n", .{x.name});
    try testing.expectEqualStrings(expected, out.items);
}

test "unused private declarations are reported, reachable ones are kept" {
    try expectFindings(
        \\//- /p/main.zig
        \\fn unusedFn() void {}
        \\const unusedConst = 1;
        \\var unusedVar: u32 = 0;
        \\fn usedFn() void {
        \\    usedHelper();
        \\}
        \\fn usedHelper() void {}
        \\pub fn run() void {
        \\    usedFn();
        \\}
        \\test "t" {
        \\    usedHelper();
        \\}
        \\
    , "unusedFn\nunusedConst\nunusedVar\n");
}

test "a helper used only by unused declarations is unused too" {
    try expectFindings(
        \\//- /p/main.zig
        \\fn outer() void {
        \\    inner();
        \\}
        \\fn inner() void {}
        \\pub fn main2() void {}
        \\
    , "outer\ninner\n");
}

test "a cycle of private declarations that nothing reaches is reported" {
    try expectFindings(
        \\//- /p/main.zig
        \\fn a() void {
        \\    b();
        \\}
        \\fn b() void {
        \\    a();
        \\}
        \\
    , "a\nb\n");
}

test "a live container keeps its interface and the declarations those use" {
    try expectFindings(
        \\//- /p/main.zig
        \\const S = struct {
        \\    const helper = 1;
        \\    pub fn method() u8 {
        \\        return helper;
        \\    }
        \\    test "t" {
        \\        _ = method;
        \\    }
        \\};
        \\pub fn use() u8 {
        \\    return S.method();
        \\}
        \\
    , "");
}

test "a dead container does not keep its interface alive" {
    try expectFindings(
        \\//- /p/main.zig
        \\const Dead = struct {
        \\    const helper = 1;
        \\    pub fn method() u8 {
        \\        return helper;
        \\    }
        \\};
        \\pub fn use() void {}
        \\
    , "Dead\nhelper\n");
}

test "a test or comptime block of a dead container does not keep helpers alive" {
    try expectFindings(
        \\//- /p/main.zig
        \\const Dead = struct {
        \\    fn helper() void {}
        \\    test "t" {
        \\        helper();
        \\    }
        \\    comptime {
        \\        helper();
        \\    }
        \\};
        \\pub fn use() void {}
        \\
    , "Dead\nhelper\n");
}

test "a field with the same name is not a reference to a declaration" {
    try expectFindings(
        \\//- /p/main.zig
        \\fn helper() void {}
        \\const S = struct {
        \\    helper: u32,
        \\};
        \\pub fn use() u32 {
        \\    return 1;
        \\}
        \\
    , "helper\nS\n");
}

test "a plain string literal that equals a name is not a reference" {
    try expectFindings(
        \\//- /p/main.zig
        \\fn helper() void {}
        \\pub fn use() []const u8 {
        \\    return "helper";
        \\}
        \\
    , "helper\n");
}

test "a named @field or @hasDecl is a reference" {
    try expectFindings(
        \\//- /p/main.zig
        \\const S = struct {
        \\    fn kept() void {}
        \\};
        \\fn has_decl() void {}
        \\pub fn use() void {
        \\    @field(S, "kept")();
        \\    _ = @hasDecl(@This(), "has_decl");
        \\}
        \\
    , "");
}

test "a computed @field name disables the check for the file" {
    try expectFindings(
        \\//- /p/main.zig
        \\fn kept() void {}
        \\pub fn use(comptime T: type, comptime name: []const u8) void {
        \\    _ = @field(T, name);
        \\}
        \\
    , "");
}

test "a named @field in a dead declaration does not keep the target alive" {
    try expectFindings(
        \\//- /p/main.zig
        \\const S = struct {
        \\    fn kept() void {}
        \\};
        \\fn dead() void {
        \\    @field(S, "kept")();
        \\}
        \\pub fn use() void {}
        \\
    , "S\nkept\ndead\n");
}

test "a test or comptime block at file scope keeps the declarations it uses" {
    try expectFindings(
        \\//- /p/main.zig
        \\fn from_test() void {}
        \\fn from_comptime() void {}
        \\test "t" {
        \\    from_test();
        \\}
        \\comptime {
        \\    _ = from_comptime;
        \\}
        \\
    , "");
}

test "a method call is a reference" {
    try expectFindings(
        \\//- /p/main.zig
        \\const S = struct {
        \\    fn method() void {}
        \\};
        \\pub fn use(s: S) void {
        \\    s.method();
        \\}
        \\
    , "");
}

test "an underscore-prefixed declaration keeps what it references alive" {
    try expectFindings(
        \\//- /p/main.zig
        \\fn _wrapper() void {
        \\    helper();
        \\}
        \\fn helper() void {}
        \\pub fn use() void {
        \\    _wrapper();
        \\}
        \\
    , "");
}

test "a quoted declaration keeps what it references alive" {
    try expectFindings(
        \\//- /p/main.zig
        \\fn @"quoted helper"() void {
        \\    helper();
        \\}
        \\fn helper() void {}
        \\pub fn use() void {}
        \\
    , "");
}

test "a public, exported, extern and underscore name is not reported" {
    try expectFindings(
        \\//- /p/main.zig
        \\fn _kept() void {}
        \\pub fn publicFn() void {}
        \\export fn exported() void {}
        \\extern fn external() void;
        \\fn reported() void {}
        \\
    , "reported\n");
}

test "a file with syntax errors has no findings" {
    try expectFindings(
        \\//- /p/main.zig
        \\fn helper() void {}
        \\fn broken( {
        \\
    , "");
}

test "a file with only root declarations has no findings" {
    try expectFindings(
        \\//- /p/main.zig
        \\pub fn a() void {}
        \\pub const b = 1;
        \\
    , "");
}
