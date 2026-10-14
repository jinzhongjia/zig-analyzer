const std = @import("std");
const testing = std.testing;
const resolve = @import("../names/resolve.zig");
const World = @import("../names/resolve_test.zig").World;
const code_actions = @import("code_actions.zig");

/// 在 `<|>` 处取标题为 `title` 的修复，返回应用后的文本
fn apply(text: []const u8, title_prefix: []const u8) ![]const u8 {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", text);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    const clean = (try ctx.get(@import("../database.zig").syntax.SourceText, added.file)).text;
    const actions = try code_actions.codeActions(&r, added.file, added.cursor, added.cursor);
    for (actions) |a| {
        if (!std.mem.startsWith(u8, a.title, title_prefix)) continue;
        var out: std.ArrayList(u8) = .empty;
        var pos: u32 = 0;
        for (a.edits) |e| {
            try out.appendSlice(testing.allocator, clean[pos..e.start]);
            try out.appendSlice(testing.allocator, e.text);
            pos = e.end;
        }
        try out.appendSlice(testing.allocator, clean[pos..]);
        return out.toOwnedSlice(testing.allocator);
    }
    return testing.allocator.dupe(u8, "no action");
}

fn expectAction(text: []const u8, title: []const u8, expected: []const u8) !void {
    const got = try apply(text, title);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "discard unused locals, parameters and captures" {
    try expectAction(
        \\fn f(<|>a: u32) void {
        \\    return;
        \\}
    , "discard `a`",
        \\fn f(a: u32) void {
        \\    _ = a;
        \\    return;
        \\}
    );
    try expectAction(
        \\fn f() void {
        \\    const <|>x = 1;
        \\}
    , "discard `x`",
        \\fn f() void {
        \\    const x = 1;
        \\    _ = x;
        \\}
    );
    try expectAction(
        \\fn f(o: ?u32) void {
        \\    if (o) |<|>v| {
        \\        return;
        \\    }
        \\}
    , "discard `v`",
        \\fn f(o: ?u32) void {
        \\    if (o) |v| {
        \\        _ = v;
        \\        return;
        \\    }
        \\}
    );
    try expectAction(
        \\fn f(a: u32) void {
        \\    _ = <|>a;
        \\    _ = a + 1;
        \\}
    , "remove discard",
        \\fn f(a: u32) void {
        \\    _ = a + 1;
        \\}
    );
}

test "add missing switch prongs" {
    try expectAction(
        \\const E = enum { a, b, c };
        \\fn f(e: E) void {
        \\    switch (e) {
        \\        .a => {},
        \\    }<|>
        \\}
    , "add missing switch prongs",
        \\const E = enum { a, b, c };
        \\fn f(e: E) void {
        \\    switch (e) {
        \\        .a => {},
        \\        .b => {},
        \\        .c => {},
        \\    }
        \\}
    );
    // 没有结尾逗号、联合
    try expectAction(
        \\const U = union(enum) { a: u8, b };
        \\fn f(u: U) void {
        \\    sw<|>itch (u) { .a => {} }
        \\}
    , "add missing switch prongs",
        \\const U = union(enum) { a: u8, b };
        \\fn f(u: U) void {
        \\    switch (u) { .a => {},
        \\        .b => {},
        \\    }
        \\}
    );
    try testing.expectEqualStrings("no action", try applyNone(
        \\const E = enum { a, b };
        \\fn f(e: E) void {
        \\    switch (e) { .a => {}, else => {} }<|>
        \\}
    ));
}

fn applyNone(text: []const u8) ![]const u8 {
    const got = try apply(text, "add missing switch prongs");
    defer testing.allocator.free(got);
    return if (std.mem.eql(u8, got, "no action")) "no action" else "action";
}

test "add missing struct fields" {
    try expectAction(
        \\const P = struct { x: i32, y: i32, z: i32 = 0 };
        \\const p: P = .{ .x = 1<|> };
    , "add missing struct fields",
        \\const P = struct { x: i32, y: i32, z: i32 = 0 };
        \\const p: P = .{ .x = 1, .y = undefined };
    );
    try expectAction(
        \\const P = struct { x: i32, y: i32 };
        \\const p = P{
        \\    .x = 1,
        \\}<|>;
    , "add missing struct fields",
        \\const P = struct { x: i32, y: i32 };
        \\const p = P{
        \\    .x = 1,
        \\    .y = undefined,
        \\};
    );
}
