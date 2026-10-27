const std = @import("std");
const testing = std.testing;
const resolve = @import("../names/resolve.zig");
const World = @import("../names/resolve_test.zig").World;
const code_actions = @import("code_actions.zig");

/// Applies the fix titled `title` at `<|>` (or on the `«...»` selection) and returns the new text
fn apply(text: []const u8, title_prefix: []const u8) ![]const u8 {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    // Selection: strip the `«` `»` markers
    var start: ?u32 = null;
    var end: u32 = 0;
    const plain = blk: {
        const open = std.mem.indexOf(u8, text, "«") orelse break :blk text;
        const close = std.mem.indexOf(u8, text, "»").?;
        start = @intCast(open);
        end = @intCast(close - "«".len);
        break :blk try std.mem.concat(w.arena.allocator(), u8, &.{ text[0..open], text[open + "«".len .. close], text[close + "»".len ..] });
    };
    const added = try w.add("/p/main.zig", plain);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    const clean = (try ctx.get(@import("../database.zig").syntax.SourceText, added.file)).text;
    const actions = try code_actions.codeActions(&r, added.file, start orelse added.cursor, if (start != null) end else added.cursor);
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

/// AstGen (same as `zig ast-check`) reports no errors
fn expectAstCheckClean(source: []const u8) !void {
    const z = try testing.allocator.dupeSentinel(u8, source, 0);
    defer testing.allocator.free(z);
    var tree = try std.zig.Ast.parse(testing.allocator, z, .{});
    defer tree.deinit(testing.allocator);
    var zir = try std.zig.AstGen.generate(testing.allocator, tree);
    defer zir.deinit(testing.allocator);
    try testing.expect(!zir.hasCompileErrors());
}

test "use 'const' for locals that are never mutated" {
    const cases = [_]struct { []const u8, []const u8 }{
        // Only the keyword is replaced; the type annotation and the initializer stay unchanged
        .{
            "fn f() u32 {\n    var <|>x: u32 = 1 + 2;\n    return x;\n}\n",
            "fn f() u32 {\n    const x: u32 = 1 + 2;\n    return x;\n}\n",
        },
        .{
            "fn f() u32 {\n    var <|>@\"x y\" = @as(u32, 1);\n    return @\"x y\";\n}\n",
            "fn f() u32 {\n    const @\"x y\" = @as(u32, 1);\n    return @\"x y\";\n}\n",
        },
        // `comptime const` is invalid: the initializer is evaluated at compile time, so it is
        // wrapped in `comptime` instead
        .{
            "fn g() u32 {\n    return 1;\n}\nfn f() u32 {\n    comptime var <|>c = g();\n    return c;\n}\n",
            "fn g() u32 {\n    return 1;\n}\nfn f() u32 {\n    const c = comptime g();\n    return c;\n}\n",
        },
        .{
            "fn f() u32 {\n    comptime var <|>c: u32 = comptime 1;\n    return c;\n}\n",
            "fn f() u32 {\n    const c: u32 = comptime 1;\n    return c;\n}\n",
        },
        // One variable of a destructuring
        .{
            "fn f() u32 {\n    var a, var <|>b = .{ @as(u32, 1), @as(u32, 2) };\n    a += 1;\n    return a + b;\n}\n",
            "fn f() u32 {\n    var a, const b = .{ @as(u32, 1), @as(u32, 2) };\n    a += 1;\n    return a + b;\n}\n",
        },
    };
    for (cases) |c| {
        const got = try apply(c[0], "use 'const'");
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c[1], got);
        try expectAstCheckClean(got);
    }
    for ([_][]const u8{
        // A mutated variable has no diagnostic
        "fn f() u32 {\n    var <|>x: u32 = 1;\n    x += 1;\n    return x;\n}\n",
        // Destructuring with `comptime`: `comptime` applies to the whole statement
        "fn f() u32 {\n    comptime var <|>a, var b = .{ 1, 2 };\n    return a + b;\n}\n",
    }) |source| {
        const got = try apply(source, "use 'const'");
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("no action", got);
    }
}

test "remove unused captures or rename them to _" {
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        // Optional if / while: the condition is compared with null
        .{
            \\fn f(o: ?u32) u32 {
            \\    if (o) |<|>v| {
            \\        return 1;
            \\    }
            \\    return 0;
            \\}
            ,
            "remove capture `v`",
            \\fn f(o: ?u32) u32 {
            \\    if (o != null) {
            \\        return 1;
            \\    }
            \\    return 0;
            \\}
        },
        .{
            \\fn f(o: ?u32) u32 {
            \\    return if (o) |<|>v| 1 else 0;
            \\}
            ,
            "remove capture `v`",
            \\fn f(o: ?u32) u32 {
            \\    return if (o != null) 1 else 0;
            \\}
        },
        .{
            \\fn f(o: *?u32) u32 {
            \\    if (o.*) |*<|>v| {
            \\        return 1;
            \\    }
            \\    return 0;
            \\}
            ,
            "remove capture `v`",
            \\fn f(o: *?u32) u32 {
            \\    if (o.* != null) {
            \\        return 1;
            \\    }
            \\    return 0;
            \\}
        },
        // The comparison must not be taken into an operation of lower precedence or into a
        // condition that ends with an expression
        .{
            \\fn f(a: ?u32, b: ?u32) u32 {
            \\    if (a orelse b) |<|>v| {
            \\        return 1;
            \\    }
            \\    return 0;
            \\}
            ,
            "remove capture `v`",
            \\fn f(a: ?u32, b: ?u32) u32 {
            \\    if ((a orelse b) != null) {
            \\        return 1;
            \\    }
            \\    return 0;
            \\}
        },
        .{
            \\fn g() !?u32 {
            \\    return null;
            \\}
            \\fn f() !u32 {
            \\    if (try g()) |<|>v| {
            \\        return 1;
            \\    }
            \\    return 0;
            \\}
            ,
            "remove capture `v`",
            \\fn g() !?u32 {
            \\    return null;
            \\}
            \\fn f() !u32 {
            \\    if ((try g()) != null) {
            \\        return 1;
            \\    }
            \\    return 0;
            \\}
        },
        .{
            \\fn next(i: *u32) ?u32 {
            \\    i.* += 1;
            \\    return if (i.* < 3) i.* else null;
            \\}
            \\fn f() u32 {
            \\    var i: u32 = 0;
            \\    var n: u32 = 0;
            \\    while (next(&i)) |<|>v| : (n += 1) {}
            \\    return n;
            \\}
            ,
            "remove capture `v`",
            \\fn next(i: *u32) ?u32 {
            \\    i.* += 1;
            \\    return if (i.* < 3) i.* else null;
            \\}
            \\fn f() u32 {
            \\    var i: u32 = 0;
            \\    var n: u32 = 0;
            \\    while (next(&i) != null) : (n += 1) {}
            \\    return n;
            \\}
        },
        // Error union if / while: both captures are renamed to `_`, a pointer capture together
        // with its `*`
        .{
            \\fn g() !u32 {
            \\    return 1;
            \\}
            \\fn f() u32 {
            \\    if (g()) |<|>v| {
            \\        return 1;
            \\    } else |err| {
            \\        return @intFromError(err);
            \\    }
            \\}
            ,
            "rename `v` to `_`",
            \\fn g() !u32 {
            \\    return 1;
            \\}
            \\fn f() u32 {
            \\    if (g()) |_| {
            \\        return 1;
            \\    } else |err| {
            \\        return @intFromError(err);
            \\    }
            \\}
        },
        .{
            \\fn f(e: *anyerror!u32) u32 {
            \\    if (e.*) |*<|>v| {
            \\        return 1;
            \\    } else |err| {
            \\        return @intFromError(err);
            \\    }
            \\}
            ,
            "rename `v` to `_`",
            \\fn f(e: *anyerror!u32) u32 {
            \\    if (e.*) |_| {
            \\        return 1;
            \\    } else |err| {
            \\        return @intFromError(err);
            \\    }
            \\}
        },
        .{
            \\fn g() !u32 {
            \\    return 1;
            \\}
            \\fn f() u32 {
            \\    if (g()) |v| {
            \\        return v;
            \\    } else |<|>err| {
            \\        return 0;
            \\    }
            \\}
            ,
            "rename `err` to `_`",
            \\fn g() !u32 {
            \\    return 1;
            \\}
            \\fn f() u32 {
            \\    if (g()) |v| {
            \\        return v;
            \\    } else |_| {
            \\        return 0;
            \\    }
            \\}
        },
        .{
            \\fn next(i: *u32) !u32 {
            \\    i.* += 1;
            \\    if (i.* > 3) return error.Done;
            \\    return i.*;
            \\}
            \\fn f() u32 {
            \\    var i: u32 = 0;
            \\    var n: u32 = 0;
            \\    while (next(&i)) |<|>v| {
            \\        n += 1;
            \\    } else |err| {
            \\        n += @intFromError(err);
            \\    }
            \\    return n;
            \\}
            ,
            "rename `v` to `_`",
            \\fn next(i: *u32) !u32 {
            \\    i.* += 1;
            \\    if (i.* > 3) return error.Done;
            \\    return i.*;
            \\}
            \\fn f() u32 {
            \\    var i: u32 = 0;
            \\    var n: u32 = 0;
            \\    while (next(&i)) |_| {
            \\        n += 1;
            \\    } else |err| {
            \\        n += @intFromError(err);
            \\    }
            \\    return n;
            \\}
        },
        .{
            \\fn next(i: *u32) !u32 {
            \\    i.* += 1;
            \\    if (i.* > 3) return error.Done;
            \\    return i.*;
            \\}
            \\fn f() u32 {
            \\    var i: u32 = 0;
            \\    var n: u32 = 0;
            \\    while (next(&i)) |v| {
            \\        n += v;
            \\    } else |<|>err| {}
            \\    return n;
            \\}
            ,
            "rename `err` to `_`",
            \\fn next(i: *u32) !u32 {
            \\    i.* += 1;
            \\    if (i.* > 3) return error.Done;
            \\    return i.*;
            \\}
            \\fn f() u32 {
            \\    var i: u32 = 0;
            \\    var n: u32 = 0;
            \\    while (next(&i)) |v| {
            \\        n += v;
            \\    } else |_| {}
            \\    return n;
            \\}
        },
        // catch: the capture is removed
        .{
            \\fn g() !u32 {
            \\    return 1;
            \\}
            \\fn f() u32 {
            \\    return g() catch |<|>err| 0;
            \\}
            ,
            "remove capture `err`",
            \\fn g() !u32 {
            \\    return 1;
            \\}
            \\fn f() u32 {
            \\    return g() catch 0;
            \\}
        },
        .{
            \\fn g() !u32 {
            \\    return 1;
            \\}
            \\fn f() u32 {
            \\    const x = g() catch |<|>err| {
            \\        return 0;
            \\    };
            \\    return x;
            \\}
            ,
            "remove capture `err`",
            \\fn g() !u32 {
            \\    return 1;
            \\}
            \\fn f() u32 {
            \\    const x = g() catch {
            \\        return 0;
            \\    };
            \\    return x;
            \\}
        },
        // for: elements and bounded counters are renamed to `_`
        .{
            \\fn f(xs: []const u32) u32 {
            \\    var n: u32 = 0;
            \\    for (xs) |<|>x| {
            \\        n += 1;
            \\    }
            \\    return n;
            \\}
            ,
            "rename `x` to `_`",
            \\fn f(xs: []const u32) u32 {
            \\    var n: u32 = 0;
            \\    for (xs) |_| {
            \\        n += 1;
            \\    }
            \\    return n;
            \\}
        },
        .{
            \\fn f(xs: []u32) u32 {
            \\    var n: u32 = 0;
            \\    for (xs) |*<|>x| {
            \\        n += 1;
            \\    }
            \\    return n;
            \\}
            ,
            "rename `x` to `_`",
            \\fn f(xs: []u32) u32 {
            \\    var n: u32 = 0;
            \\    for (xs) |_| {
            \\        n += 1;
            \\    }
            \\    return n;
            \\}
        },
        .{
            \\fn f(xs: []const u32, ys: []const u32) u32 {
            \\    var n: u32 = 0;
            \\    for (xs, ys) |<|>x, y| {
            \\        n += y;
            \\    }
            \\    return n;
            \\}
            ,
            "rename `x` to `_`",
            \\fn f(xs: []const u32, ys: []const u32) u32 {
            \\    var n: u32 = 0;
            \\    for (xs, ys) |_, y| {
            \\        n += y;
            \\    }
            \\    return n;
            \\}
        },
        .{
            \\fn f(xs: []const u32) u32 {
            \\    var n: u32 = 0;
            \\    for (xs, 0..xs.len) |x, <|>i| {
            \\        n += x;
            \\    }
            \\    return n;
            \\}
            ,
            "rename `i` to `_`",
            \\fn f(xs: []const u32) u32 {
            \\    var n: u32 = 0;
            \\    for (xs, 0..xs.len) |x, _| {
            \\        n += x;
            \\    }
            \\    return n;
            \\}
        },
        .{
            \\fn f(n: usize) usize {
            \\    var s: usize = 0;
            \\    for (0..n) |<|>i| {
            \\        s += 1;
            \\    }
            \\    return s;
            \\}
            ,
            "rename `i` to `_`",
            \\fn f(n: usize) usize {
            \\    var s: usize = 0;
            \\    for (0..n) |_| {
            \\        s += 1;
            \\    }
            \\    return s;
            \\}
        },
        // An unbounded for counter: removed together with its input
        .{
            \\fn f(xs: []const u32) u32 {
            \\    var n: u32 = 0;
            \\    for (xs, 0..) |x, <|>i| {
            \\        n += x;
            \\    }
            \\    return n;
            \\}
            ,
            "remove capture `i`",
            \\fn f(xs: []const u32) u32 {
            \\    var n: u32 = 0;
            \\    for (xs) |x| {
            \\        n += x;
            \\    }
            \\    return n;
            \\}
        },
        .{
            \\fn f(xs: []const u32) u32 {
            \\    var n: u32 = 0;
            \\    for (0.., xs) |<|>i, x| {
            \\        n += x;
            \\    }
            \\    return n;
            \\}
            ,
            "remove capture `i`",
            \\fn f(xs: []const u32) u32 {
            \\    var n: u32 = 0;
            \\    for (xs) |x| {
            \\        n += x;
            \\    }
            \\    return n;
            \\}
        },
        .{
            \\fn f(xs: []const u32, ys: []const u32) u32 {
            \\    var n: u32 = 0;
            \\    for (xs, 1.., ys) |x, <|>i, y| {
            \\        n += x + y;
            \\    }
            \\    return n;
            \\}
            ,
            "remove capture `i`",
            \\fn f(xs: []const u32, ys: []const u32) u32 {
            \\    var n: u32 = 0;
            \\    for (xs, ys) |x, y| {
            \\        n += x + y;
            \\    }
            \\    return n;
            \\}
        },
        .{
            \\fn f(xs: []const u32) u32 {
            \\    var n: u32 = 0;
            \\    for (
            \\        xs,
            \\        0..,
            \\    ) |x, <|>i| {
            \\        n += x;
            \\    }
            \\    return n;
            \\}
            ,
            "remove capture `i`",
            \\fn f(xs: []const u32) u32 {
            \\    var n: u32 = 0;
            \\    for (
            \\        xs,
            \\    ) |x| {
            \\        n += x;
            \\    }
            \\    return n;
            \\}
        },
        // The name in the start is still used elsewhere
        .{
            \\fn f(xs: []const u32, base: usize) usize {
            \\    var n: usize = base;
            \\    for (xs, base..) |x, <|>i| {
            \\        n += x;
            \\    }
            \\    return n;
            \\}
            ,
            "remove capture `i`",
            \\fn f(xs: []const u32, base: usize) usize {
            \\    var n: usize = base;
            \\    for (xs) |x| {
            \\        n += x;
            \\    }
            \\    return n;
            \\}
        },
        // switch: with only the payload capture, the whole capture is removed
        .{
            \\const U = union(enum) { a: u32, b: void };
            \\fn f(u: U) u32 {
            \\    switch (u) {
            \\        .a => |<|>p| {
            \\            return 1;
            \\        },
            \\        .b => return 0,
            \\    }
            \\}
            ,
            "remove capture `p`",
            \\const U = union(enum) { a: u32, b: void };
            \\fn f(u: U) u32 {
            \\    switch (u) {
            \\        .a => {
            \\            return 1;
            \\        },
            \\        .b => return 0,
            \\    }
            \\}
        },
        .{
            \\const U = union(enum) { a: u32, b: void };
            \\fn f(u: *U) u32 {
            \\    return switch (u.*) {
            \\        .a => |*<|>p| 1,
            \\        .b => 0,
            \\    };
            \\}
            ,
            "remove capture `p`",
            \\const U = union(enum) { a: u32, b: void };
            \\fn f(u: *U) u32 {
            \\    return switch (u.*) {
            \\        .a => 1,
            \\        .b => 0,
            \\    };
            \\}
        },
        // The tag capture of a switch prong: removed together with the comma, or the whole capture
        // when the payload capture is `_`
        .{
            \\const U = union(enum) { a: u32, b: u64 };
            \\fn f(u: U) usize {
            \\    switch (u) {
            \\        inline else => |p, <|>tag| {
            \\            return @sizeOf(@TypeOf(p));
            \\        },
            \\    }
            \\}
            ,
            "remove capture `tag`",
            \\const U = union(enum) { a: u32, b: u64 };
            \\fn f(u: U) usize {
            \\    switch (u) {
            \\        inline else => |p| {
            \\            return @sizeOf(@TypeOf(p));
            \\        },
            \\    }
            \\}
        },
        .{
            \\const U = union(enum) { a: u32, b: u64 };
            \\fn f(u: *U) usize {
            \\    switch (u.*) {
            \\        inline else => |*p, <|>tag| {
            \\            return @sizeOf(@TypeOf(p.*));
            \\        },
            \\    }
            \\}
            ,
            "remove capture `tag`",
            \\const U = union(enum) { a: u32, b: u64 };
            \\fn f(u: *U) usize {
            \\    switch (u.*) {
            \\        inline else => |*p| {
            \\            return @sizeOf(@TypeOf(p.*));
            \\        },
            \\    }
            \\}
        },
        .{
            \\const U = union(enum) { a: u32, b: u64 };
            \\fn f(u: U) usize {
            \\    switch (u) {
            \\        inline else => |_, <|>tag| {
            \\            return 1;
            \\        },
            \\    }
            \\}
            ,
            "remove capture `tag`",
            \\const U = union(enum) { a: u32, b: u64 };
            \\fn f(u: U) usize {
            \\    switch (u) {
            \\        inline else => {
            \\            return 1;
            \\        },
            \\    }
            \\}
        },
        // With a tag capture, the payload capture of a switch prong is renamed to `_`
        .{
            \\const U = union(enum) { a: u32, b: u64 };
            \\fn f(u: U) usize {
            \\    switch (u) {
            \\        inline else => |<|>p, tag| {
            \\            return @intFromEnum(tag);
            \\        },
            \\    }
            \\}
            ,
            "rename `p` to `_`",
            \\const U = union(enum) { a: u32, b: u64 };
            \\fn f(u: U) usize {
            \\    switch (u) {
            \\        inline else => |_, tag| {
            \\            return @intFromEnum(tag);
            \\        },
            \\    }
            \\}
        },
        .{
            \\const U = union(enum) { a: u32, b: u64 };
            \\fn f(u: *U) usize {
            \\    switch (u.*) {
            \\        inline else => |*<|>p, tag| {
            \\            return @intFromEnum(tag);
            \\        },
            \\    }
            \\}
            ,
            "rename `p` to `_`",
            \\const U = union(enum) { a: u32, b: u64 };
            \\fn f(u: *U) usize {
            \\    switch (u.*) {
            \\        inline else => |_, tag| {
            \\            return @intFromEnum(tag);
            \\        },
            \\    }
            \\}
        },
    };
    for (cases) |c| {
        const got = try apply(c[0], c[1]);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c[2], got);
        try expectAstCheckClean(got);
    }
    for ([_][]const u8{
        // Removing the input would remove the evaluation of its start (a call)
        \\fn g() usize {
        \\    return 0;
        \\}
        \\fn f(xs: []const u32) u32 {
        \\    var n: u32 = 0;
        \\    for (xs, g()..) |x, <|>i| {
        \\        n += x;
        \\    }
        \\    return n;
        \\}
        ,
        // The name in the start is used only here: removing the input would leave an unused
        // local constant
        \\fn f(xs: []const u32) u32 {
        \\    const base: usize = 1;
        \\    var n: u32 = 0;
        \\    for (xs, base..) |x, <|>i| {
        \\        n += x;
        \\    }
        \\    return n;
        \\}
        ,
    }) |source| {
        for ([_][]const u8{ "remove capture", "rename" }) |title| {
            const got = try apply(source, title);
            defer testing.allocator.free(got);
            try testing.expectEqualStrings("no action", got);
        }
        // The discard is still offered
        const got = try apply(source, "discard `i`");
        defer testing.allocator.free(got);
        try testing.expect(!std.mem.eql(u8, got, "no action"));
    }
}

/// The titles of all fixes at `<|>`, one per line, with `(preferred)` after the preferred ones
fn titles(text: []const u8) ![]const u8 {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", text);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    for (try code_actions.codeActions(&r, added.file, added.cursor, added.cursor)) |a| {
        try out.print(testing.allocator, "{s}{s}\n", .{ a.title, if (a.preferred) " (preferred)" else "" });
    }
    return out.toOwnedSlice(testing.allocator);
}

test "unused capture fixes are preferred only without a discard" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{
            \\fn f(o: ?u32) u32 {
            \\    if (o) |<|>v| {
            \\        return 1;
            \\    }
            \\    return 0;
            \\}
            ,
            \\discard `v` (preferred)
            \\remove capture `v`
            \\
        },
        // The body is not a block, so no discard can be inserted
        .{
            \\fn f(o: ?u32) u32 {
            \\    return if (o) |<|>v| 1 else 0;
            \\}
            ,
            \\remove capture `v` (preferred)
            \\
        },
        .{
            \\fn g() !u32 {
            \\    return 1;
            \\}
            \\fn f() u32 {
            \\    return g() catch |<|>err| 0;
            \\}
            ,
            \\remove capture `err` (preferred)
            \\
        },
    };
    for (cases) |c| {
        const got = try titles(c[0]);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
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
    // No trailing comma, and a union
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

test "add missing fields and prongs with names that need quoting" {
    try expectAction(
        \\const S = struct { @"x y": u32, @"type": u8 };
        \\const s: S = .{<|>};
    , "add missing struct fields",
        \\const S = struct { @"x y": u32, @"type": u8 };
        \\const s: S = .{ .@"x y" = undefined, .type = undefined };
    );
    try expectAction(
        \\const E = enum { @"a b", c };
        \\fn f(e: E) void {
        \\    switch (e) {
        \\        .c => {},<|>
        \\    }
        \\}
    , "add missing switch prongs",
        \\const E = enum { @"a b", c };
        \\fn f(e: E) void {
        \\    switch (e) {
        \\        .c => {},
        \\        .@"a b" => {},
        \\    }
        \\}
    );
}

test "extract to local constant" {
    try expectAction(
        \\fn f(a: u32, b: u32) u32 {
        \\    const c = «a * b» + 1;
        \\    return c;
        \\}
    , "extract",
        \\fn f(a: u32, b: u32) u32 {
        \\    const value = a * b;
        \\    const c = value + 1;
        \\    return c;
        \\}
    );
    // The expression is at the start of a statement; when the name is taken, another one is chosen
    try expectAction(
        \\fn g(x: u32) u32 {
        \\    return x;
        \\}
        \\fn f(value: u32) void {
        \\    if (value > 0) {
        \\        _ = «g(value)»;
        \\    }
        \\}
    , "extract",
        \\fn g(x: u32) u32 {
        \\    return x;
        \\}
        \\fn f(value: u32) void {
        \\    if (value > 0) {
        \\        const value1 = g(value);
        \\        _ = value1;
        \\    }
        \\}
    );
    // The type depends on the result location: the type at the original position is annotated
    try expectAction(
        \\pub fn f(x: u64) u8 {
        \\    return «@intCast(x)»;
        \\}
    , "extract",
        \\pub fn f(x: u64) u8 {
        \\    const value: u8 = @intCast(x);
        \\    return value;
        \\}
    );
    // The left-hand side of a short circuit is always evaluated
    try expectAction(
        \\fn g() bool {
        \\    return true;
        \\}
        \\fn f(flag: bool) bool {
        \\    return «g()» and flag;
        \\}
    , "extract",
        \\fn g() bool {
        \\    return true;
        \\}
        \\fn f(flag: bool) bool {
        \\    const value = g();
        \\    return value and flag;
        \\}
    );
    // The selection is pure: it can be moved ahead of an earlier call
    try expectAction(
        \\fn g(x: u32) u32 {
        \\    return x;
        \\}
        \\fn f(a: u32, b: u32) u32 {
        \\    return g(1) + «a * b»;
        \\}
    , "extract",
        \\fn g(x: u32) u32 {
        \\    return x;
        \\}
        \\fn f(a: u32, b: u32) u32 {
        \\    const value = a * b;
        \\    return g(1) + value;
        \\}
    );
    // The preceding parts are pure (parameters, constants): a selection with side effects
    // can be moved ahead of them
    try expectAction(
        \\const k: u32 = 2;
        \\fn g() u32 {
        \\    return 1;
        \\}
        \\fn h(a: u32, b: u32, c: u32) u32 {
        \\    return a + b + c;
        \\}
        \\fn f(n: u32) u32 {
        \\    return h(n, k * 2, «g()»);
        \\}
    , "extract",
        \\const k: u32 = 2;
        \\fn g() u32 {
        \\    return 1;
        \\}
        \\fn h(a: u32, b: u32, c: u32) u32 {
        \\    return a + b + c;
        \\}
        \\fn f(n: u32) u32 {
        \\    const value = g();
        \\    return h(n, k * 2, value);
        \\}
    );
    // Not extracted: the left-hand side of an assignment, the operand of address-of, the
    // condition of a while, a selection that is not a complete expression
    for ([_][]const u8{
        "fn f() void {\n    var x: u32 = 0;\n    «x» = 1;\n}",
        "fn f() void {\n    var x: u32 = 0;\n    const p = &«x»;\n    _ = p;\n}",
        "fn f(n: u32) void {\n    var i: u32 = 0;\n    while («i < n») : (i += 1) {}\n}",
        "fn f(a: u32) u32 {\n    return «a +» 1;\n}",
        // Conditionally evaluated: the right-hand side of a short circuit, if branches, the
        // right-hand side of catch / orelse, loop bodies
        "var hits: u32 = 0;\nfn hit() bool {\n    hits += 1;\n    return true;\n}\npub fn f(flag: bool) bool {\n    return flag and «hit()»;\n}",
        "fn g() u32 {\n    return 1;\n}\nfn f(c: bool) u32 {\n    return if (c) «g()» else 0;\n}",
        "fn g() u32 {\n    return 1;\n}\nfn f(x: ?u32) u32 {\n    return x orelse «g()»;\n}",
        "fn g() u32 {\n    return 1;\n}\nfn f(x: anyerror!u32) u32 {\n    return x catch «g()»;\n}",
        "fn g(x: u32) void {\n    _ = x;\n}\nfn f(xs: []const u32) void {\n    for (xs) |x| g(«x + 1»);\n}",
        // Ordering: both the selection and the preceding parts have side effects
        "fn g(x: u32) u32 {\n    return x;\n}\nfn f() u32 {\n    return g(1) + «g(2)»;\n}",
        // Ordering: a var read earlier may be modified by a call in the selection
        "fn g() u32 {\n    return 1;\n}\nfn f() u32 {\n    var i: u32 = 0;\n    i += 1;\n    return i + «g()»;\n}",
        // Ordering: an earlier try may return early
        "fn h() !u32 {\n    return 1;\n}\nfn g() u32 {\n    return 1;\n}\nfn f(x: anyerror!u32) !u32 {\n    return (try x) + «g()»;\n}",
        // A pure expression is not hoisted out of a short-circuit guard either (division by zero)
        "fn f(x: u32, y: u32) bool {\n    return x != 0 and «y / x» > 1;\n}",
        // Expressions in a defer are evaluated when leaving the scope
        "fn g(x: u32) void {\n    _ = x;\n}\nfn f(a: u32) void {\n    defer g(«a + 1»);\n}",
        // The result type cannot be annotated
        "const E = enum { a, b };\nfn f() E {\n    return «.a»;\n}",
    }) |text| {
        const got = try apply(text, "extract");
        defer testing.allocator.free(got);
        testing.expectEqualStrings("no action", got) catch |err| {
            std.debug.print("{s}\n", .{text});
            return err;
        };
    }
}

/// Verifies the edit result with the compiler's syntax tree and reads the byte value from the
/// string token.
fn stringValue(source: []const u8) ![]u8 {
    const z = try testing.allocator.allocSentinel(u8, source.len, 0);
    @memcpy(z, source);
    defer testing.allocator.free(z);
    var tree = try std.zig.Ast.parse(testing.allocator, z, .{});
    defer tree.deinit(testing.allocator);
    try testing.expectEqual(0, tree.errors.len);
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(testing.allocator);
    var lines: usize = 0;
    for (tree.tokens.items(.tag), 0..) |tag, i| switch (tag) {
        .string_literal => return std.zig.string_literal.parseAlloc(testing.allocator, tree.tokenSlice(@intCast(i))),
        .multiline_string_literal_line => {
            if (lines != 0) try value.append(testing.allocator, '\n');
            const token = tree.tokenSlice(@intCast(i));
            var end = token.len;
            if (end > 0 and token[end - 1] == '\n') end -= 1;
            if (end > 0 and token[end - 1] == '\r') end -= 1;
            try value.appendSlice(testing.allocator, token[2..end]);
            lines += 1;
        },
        else => {},
    };
    try testing.expect(lines != 0);
    return value.toOwnedSlice(testing.allocator);
}

test "string conversion preserves bytes and surrounding syntax" {
    const cases = .{
        .{ "\"\"", "" },
        .{ "\"abc\"", "abc" },
        .{ "\"a\\nb\"", "a\nb" },
        .{ "\"\\n\\na\\n\\n\"", "\n\na\n\n" },
        .{ "\"\\\"\\\\\\x41\\u{20ac}  \"", "\"\\A€  " },
    };
    const contexts = .{
        .{ "const text = ", ";" },
        .{ "fn f() void {\n    const text = ", ";\n    _ = text;\n}" },
        .{ "const text = .{ ", ", 42 };" },
        .{ "const text = call(", ");" },
        .{ "const text =\n    ", ";" },
        .{ "const text = ", "; // comment\r\n" },
        // Files already formatted by zig fmt: the result is laid out the way zig fmt does
        .{ "const text = ", ";\n" },
        .{ "fn f() void {\n    const text = ", ";\n    _ = text;\n}\n" },
        .{ "test {\n    try call(", ", 42);\n}\n" },
    };
    inline for (cases) |case| {
        inline for (contexts) |context| {
            const source = try std.mem.concat(testing.allocator, u8, &.{ context[0], "<|>", case[0], context[1] });
            defer testing.allocator.free(source);
            const multi = try apply(source, "convert to a multiline");
            defer testing.allocator.free(multi);
            const value = try stringValue(multi);
            defer testing.allocator.free(value);
            try testing.expectEqualStrings(case[1], value);
            const marker = std.mem.indexOf(u8, multi, "\\\\").?;
            const marked = try std.mem.concat(testing.allocator, u8, &.{ multi[0..marker], "<|>", multi[marker..] });
            defer testing.allocator.free(marked);
            const ordinary = try apply(marked, "convert to a string");
            defer testing.allocator.free(ordinary);
            const roundtrip = try stringValue(ordinary);
            defer testing.allocator.free(roundtrip);
            try testing.expectEqualStrings(case[1], roundtrip);
        }
    }
}

test "string conversion in a file formatted by zig fmt keeps it formatted" {
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        // No whitespace after `=`, and `;` at the indentation of the statement
        .{ "const text = <|>\"a\\nb\";\n", "convert to a multiline", "const text =\n    \\\\a\n    \\\\b\n;\n" },
        .{ "fn f() void {\n    const text =\n        <|>\"a\\n\";\n    _ = text;\n}\n", "convert to a multiline", "fn f() void {\n    const text =\n        \\\\a\n        \\\\\n    ;\n    _ = text;\n}\n" },
        // The initializer list becomes one element per line
        .{ "const text = .{ <|>\"a\", 42 };\n", "convert to a multiline", "const text = .{\n    \\\\a\n    ,\n    42,\n};\n" },
        // Converting back to an ordinary string joins the lines
        .{ "const text =\n    \\\\<|>a\n    \\\\b\n;\n", "convert to a string", "const text =\n    \"a\\nb\";\n" },
        .{ "fn f() void {\n    call(\n        \\\\<|>a\n    , 42);\n}\n", "convert to a string", "fn f() void {\n    call(\"a\", 42);\n}\n" },
    };
    for (cases) |c| {
        const got = try apply(c[0], c[1]);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c[2], got);
    }
}

test "multiline conversion preserves whitespace and selects the whole literal" {
    for ([_][]const u8{
        "const text =\n    \\\\<|> a  \n    \\\\b\\\\\"\n    \\\\\n;",
        "const text =\r\n    \\\\ a  \r\n    \\\\b<|>\\\\\"\r\n    \\\\\r\n;",
        "const text = «\n    \\\\ a  \n    \\\\b\\\\\"\n    \\\\\n»;",
    }) |source| {
        const converted = try apply(source, "convert to a string");
        defer testing.allocator.free(converted);
        const value = try stringValue(converted);
        defer testing.allocator.free(value);
        try testing.expectEqualStrings(" a  \nb\\\\\"\n", value);
    }
}

test "string conversion rejects unrepresentable bytes and invalid selections" {
    for ([_][]const u8{
        "const s = <|>\"\\t\";",
        "const s = <|>\"\\r\\n\";",
        "const s = <|>\"\\x00\";",
        "const s = <|>\"\\x7f\";",
        "const s = <|>\"\\xff\";",
        "const s = <|>\"\\q\";",
        "const s = <|>\"unfinished",
        "const s = @\"<|>name\";",
        "const s = '<|>x';",
        "const s = «\"a\", \"b\"»;",
    }) |source| {
        const converted = try apply(source, "convert to");
        defer testing.allocator.free(converted);
        try testing.expectEqualStrings("no action", converted);
    }
}
