const std = @import("std");
const testing = std.testing;
const database = @import("../database.zig");
const resolve = @import("../names/resolve.zig");
const definition = @import("definition.zig");
const search = @import("../ide_db/search.zig");
const rename = @import("rename.zig");
const World = @import("../names/resolve_test.zig").World;

const Check = enum { declaration, resolution };

/// 把 `<|>` 处的定义改名为 `new` 时的问题：「行:列 文案」（行列从 1 起）；没有问题时为 "ok"
fn problemOf(text: []const u8, new: []const u8, comptime check: Check) ![]const u8 {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", text);
    const a = w.arena.allocator();
    var ctx = w.db.beginRead(a);
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = a };
    const def = (try definition.defAt(&r, added.file, added.cursor)) orelse return error.NoDefinition;
    const problem = switch (check) {
        .declaration => try rename.declarationConflict(&r, def, new),
        .resolution => try rename.resolutionConflict(&r, def, new),
    } orelse return testing.allocator.dupe(u8, "ok");
    const clean = (try ctx.get(database.syntax.SourceText, added.file)).text;
    return format(clean, problem);
}

fn format(text: []const u8, p: rename.Problem) ![]const u8 {
    const line = std.mem.count(u8, text[0..p.offset], "\n") + 1;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..p.offset], '\n')) |i| i + 1 else 0;
    return std.fmt.allocPrint(testing.allocator, "{d}:{d} {s}", .{ line, p.offset - line_start + 1, p.message });
}

fn expectProblem(text: []const u8, new: []const u8, comptime check: Check, expected: []const u8) !void {
    const got = try problemOf(text, new, check);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "rename: conflicts at the declaration" {
    // 同一容器中的字段与声明不能重名
    try expectProblem(
        \\const S = struct {
        \\    fooBar: u32,
        \\    fn <|>other() void {}
        \\};
    , "fooBar", .declaration, "2:5 `fooBar` is already declared in the same container");
    // 局部名字不能遮蔽外层的局部名字与声明
    try expectProblem(
        \\fn f() void {
        \\    const a = 1;
        \\    {
        \\        const <|>b = 2;
        \\        _ = b;
        \\    }
        \\    _ = a;
        \\}
    , "a", .declaration, "2:11 `a` is already declared in this scope");
    try expectProblem(
        \\const top = 1;
        \\fn f() void {
        \\    const <|>x = 2;
        \\    _ = x;
        \\}
    , "top", .declaration, "1:7 the new name `top` would shadow this declaration");
    // 作用域内更深处的同名局部名字会遮蔽改名后的名字
    try expectProblem(
        \\fn f(<|>p: u32) void {
        \\    const q = p;
        \\    _ = q;
        \\}
    , "q", .declaration, "2:11 this `q` would shadow the renamed name");
    // 函数体内的容器的声明不能遮蔽函数中可见的局部名字
    try expectProblem(
        \\fn f() type {
        \\    const v = 1;
        \\    return struct {
        \\        const <|>w = v;
        \\    };
        \\}
    , "v", .declaration, "2:11 the new name `v` would shadow this local");
    // 不同分支中的同名局部名字互不可见
    try expectProblem(
        \\fn f(c: bool) void {
        \\    if (c) {
        \\        const <|>a = 1;
        \\        _ = a;
        \\    } else {
        \\        const b = 2;
        \\        _ = b;
        \\    }
        \\}
    , "b", .declaration, "ok");
}

test "rename: references that would change their target" {
    // 容器中的声明可以与外层的同名：改名后容器中原本指向外层 `x` 的引用会指向它
    try expectProblem(
        \\const x = 1;
        \\const S = struct {
        \\    const <|>y = 2;
        \\    fn f() u32 {
        \\        return x;
        \\    }
        \\};
    , "x", .resolution, "5:16 this `x` refers to another declaration, which the renamed declaration would shadow");
    // 对它的引用处有更近的同名声明：改名后引用被截获
    try expectProblem(
        \\const S = struct {
        \\    const <|>old = 1;
        \\    const T = struct {
        \\        const new = 2;
        \\        fn f() u32 {
        \\            return old;
        \\        }
        \\    };
        \\};
    , "new", .resolution, "6:20 this reference would refer to another `new` declared closer to it");
    // 外层的同名声明在容器中没有被引用
    try expectProblem(
        \\const x = 1;
        \\const S = struct {
        \\    const <|>y = 2;
        \\    fn f() u32 {
        \\        return y;
        \\    }
        \\};
        \\pub fn main() void {
        \\    _ = x;
        \\}
    , "x", .resolution, "ok");
}

test "rename: names referenced by string literals" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const text =
        \\const S = struct { fooBar: u32, other: u32 };
        \\// "other"
        \\fn f(s: S) u32 {
        \\    const @"other" = 1;
        \\    _ = @"other";
        \\    return @field(s, "fooBar");
        \\}
    ;
    const file = (try w.add("/p/main.zig", text)).file;
    const a = w.arena.allocator();
    var ctx = w.db.beginRead(a);
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = a };
    const p = (try rename.stringReference(&r, &.{file}, "fooBar")).?;
    const got = try format(text, p);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("6:22 `fooBar` appears in a string literal, which may refer to it by name (as `@field` and serialization do) and would not be updated", got);
    // 注释中的与 `@"..."` 形式的标识符不算
    try testing.expectEqual(null, try rename.stringReference(&r, &.{file}, "other"));
}

/// 把 `<|>` 处的定义的全部引用改为 `new` 之后 AstGen 多出的错误；`skip_uses` 时只改声明处（模拟漏改的引用）
fn verify(text: []const u8, new: []const u8, skip_uses: bool) ![]const u8 {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const added = try w.add("/p/main.zig", text);
    const a = w.arena.allocator();
    var ctx = w.db.beginRead(a);
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = a };
    const def = (try definition.defAt(&r, added.file, added.cursor)) orelse return error.NoDefinition;
    var edits: std.ArrayList(rename.Edit) = .empty;
    for (try search.findReferences(&r, def, .{ .scope = &.{added.file} })) |ref| {
        if (skip_uses and !ref.is_decl) continue;
        try edits.append(a, .{ .start = ref.start, .end = ref.end, .text = new });
    }
    const problem = try rename.verifyAstGen(&r, added.file, edits.items) orelse return testing.allocator.dupe(u8, "ok");
    return format((try ctx.get(database.syntax.SourceText, added.file)).text, problem);
}

fn expectVerify(text: []const u8, new: []const u8, skip_uses: bool, expected: []const u8) !void {
    const got = try verify(text, new, skip_uses);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "rename: AstGen confirms the renamed text" {
    const text =
        \\fn f() u32 {
        \\    const unused = 0;
        \\    const a = 1;
        \\    const <|>b = 2;
        \\    return a + b;
        \\}
    ;
    // 已有的错误（未使用的局部常量）不算
    try expectVerify(text, "c", false, "ok");
    try expectVerify(text, "a", false, "4:11 redeclaration of local constant 'a'");
    // 漏改的引用引用不到声明
    try expectVerify(text, "c", true, "5:16 use of undeclared identifier 'b'");
}
