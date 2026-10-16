const std = @import("std");
const testing = std.testing;
const database = @import("../database.zig");
const resolve = @import("../names/resolve.zig");
const definition = @import("../ide/definition.zig");
const search = @import("search.zig");
const World = @import("../names/resolve_test.zig").World;
const FileId = @import("../base/Vfs.zig").FileId;

const main_src =
    \\const lib = @import("lib.zig");
    \\const Color = lib.Color;
    \\pub fn main() void {
    \\    var p: lib.Point = .{ .x = 1, .y = 2 };
    \\    p.x += lib.add(p.x, 1);
    \\    const c: Color = .red;
    \\    switch (c) {
    \\        .red => {},
    \\        else => {},
    \\    }
    \\    const local = 3;
    \\    _ = local + local;
    \\}
;
const lib_src =
    \\pub const Point = struct { x: i32, y: i32 };
    \\pub const Color = enum { red, green };
    \\pub fn add(a: i32, b: i32) i32 {
    \\    return a + b;
    \\}
    \\test {
    \\    _ = add(1, 2);
    \\    const q = Point{ .x = 0, .y = 0 };
    \\    _ = q.x;
    \\}
;
// 不导入 lib.zig：其中的同名声明不是引用
const other_src =
    \\fn add() void {}
    \\test {
    \\    add();
    \\}
;

const Files = struct { main: FileId, lib: FileId, other: FileId };

fn setup(w: *World) !Files {
    try w.init();
    return .{
        .main = (try w.add("/p/main.zig", main_src)).file,
        .lib = (try w.add("/p/lib.zig", lib_src)).file,
        .other = (try w.add("/p/other.zig", other_src)).file,
    };
}

/// `src` 中第 `nth` 个 `needle` 的位置
fn at(src: []const u8, needle: []const u8, nth: usize) u32 {
    var start: usize = 0;
    for (0..nth) |_| start = std.mem.indexOfPos(u8, src, start, needle).? + 1;
    return @intCast(std.mem.indexOfPos(u8, src, start, needle).?);
}

/// 引用列表：「文件名:行」以空格连接（定义处带 `*`）
fn refs(w: *World, fs: Files, file: FileId, offset: u32, only_file: ?FileId) ![]const u8 {
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    const def = try definition.defAt(&r, file, offset) orelse return "null";
    const list = try search.findReferences(&r, def, .{ .scope = &.{ fs.main, fs.lib, fs.other }, .only_file = only_file });
    var out: std.ArrayList(u8) = .empty;
    for (list, 0..) |ref, i| {
        const text = (try ctx.get(database.syntax.SourceText, ref.file)).text;
        const line = std.mem.count(u8, text[0..ref.start], "\n") + 1;
        if (i > 0) try out.append(w.arena.allocator(), ' ');
        try out.print(w.arena.allocator(), "{s}:{d}:{s}{s}", .{ std.fs.path.stem(w.vfs.path(ref.file)), line, text[ref.start..ref.end], if (ref.is_decl) "*" else "" });
    }
    return out.items;
}

test "find references" {
    var w: World = undefined;
    const fs = try setup(&w);
    defer w.deinit();
    const cases = [_]struct { FileId, []const u8, []const u8, usize, []const u8 }{
        // 跨文件的函数；other.zig 中的同名函数不算
        .{ fs.lib, lib_src, "add(a", 0, "main:5:add lib:3:add* lib:7:add" },
        .{ fs.main, main_src, "add(p", 0, "main:5:add lib:3:add* lib:7:add" },
        // 字段：类型推导得到的访问与初始化
        .{ fs.lib, lib_src, "x: i32", 0, "main:4:x main:5:x main:5:x lib:1:x* lib:8:x lib:9:x" },
        // 枚举成员：枚举字面量
        .{ fs.lib, lib_src, "red", 0, "main:6:red main:8:red lib:2:red*" },
        // 经由别名引用的声明
        .{ fs.lib, lib_src, "Color", 0, "main:2:Color lib:2:Color*" },
        // 局部变量
        .{ fs.main, main_src, "local", 1, "main:11:local* main:12:local main:12:local" },
        .{ fs.other, other_src, "add", 1, "other:1:add* other:3:add" },
    };
    for (cases) |c| {
        const got = try refs(&w, fs, c[0], at(c[1], c[2], c[3]), null);
        testing.expectEqualStrings(c[4], got) catch |err| {
            std.debug.print("references of `{s}`\n", .{c[2]});
            return err;
        };
    }
    // 只在一个文件中查找（document highlight）
    try testing.expectEqualStrings("lib:3:add* lib:7:add", try refs(&w, fs, fs.lib, at(lib_src, "add", 0), fs.lib));
}

test "enum member names are not references to declarations of the same name" {
    const src =
        \\pub fn read() void {}
        \\pub const SYS = enum(u32) { read = 0, write = 1 };
        \\pub const Tag = enum { read, other };
        \\test {
        \\    read();
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = (try w.add("/p/x.zig", src)).file;
    const fs: Files = .{ .main = f, .lib = f, .other = f };
    try testing.expectEqualStrings("x:1:read* x:5:read", try refs(&w, fs, f, at(src, "read", 0), null));
    // 在成员名处查找：是该成员自身，不是同名的函数
    try testing.expectEqualStrings("x:2:read*", try refs(&w, fs, f, at(src, "read", 1), null));
}

test "member references inside generic functions use the call-site instance" {
    const src =
        \\const S = struct { x: u32 };
        \\fn read(p: anytype) u32 {
        \\    return p.x;
        \\}
        \\pub fn main() void {
        \\    const s: S = .{ .x = 1 };
        \\    _ = read(s);
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = (try w.add("/p/x.zig", src)).file;
    const fs: Files = .{ .main = f, .lib = f, .other = f };
    try testing.expectEqualStrings("x:1:x* x:3:x x:6:x", try refs(&w, fs, f, at(src, "x", 0), null));
    // 只有一种实例：没有歧义
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    var ambiguous: ?search.Reference = null;
    _ = try search.findReferences(&r, (try definition.defAt(&r, f, at(src, "x", 0))).?, .{ .scope = &.{f}, .ambiguous = &ambiguous });
    try testing.expectEqual(null, ambiguous);
}

test "references to quoted names with escaped quotes" {
    const src =
        \\const S = struct { @"a\"b": u32 };
        \\pub fn f(s: S) u32 {
        \\    return s.@"a\"b";
        \\}
        \\const @"\x66oo": u8 = 7;
        \\const bar = foo + @"foo";
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = (try w.add("/p/x.zig", src)).file;
    const fs: Files = .{ .main = f, .lib = f, .other = f };
    try testing.expectEqualStrings("x:1:@\"a\\\"b\"* x:3:@\"a\\\"b\"", try refs(&w, fs, f, at(src, "@\"a", 0), null));
    // 转义的名字与普通写法是同一个名字
    try testing.expectEqualStrings("x:5:@\"\\x66oo\"* x:6:foo x:6:@\"foo\"", try refs(&w, fs, f, at(src, "@\"\\x66", 0), null));
}

test "member references inside generic functions cover every call-site instance" {
    const src =
        \\const S = struct { x: u32 };
        \\const T = struct { x: u32 };
        \\fn both(p: anytype) u32 {
        \\    return p.x;
        \\}
        \\fn onlyS(p: anytype) u32 {
        \\    return p.x;
        \\}
        \\pub fn main() void {
        \\    _ = both(T{ .x = 2 });
        \\    _ = both(S{ .x = 1 });
        \\    _ = onlyS(S{ .x = 3 });
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = (try w.add("/p/x.zig", src)).file;
    // 第一个调用点的实例是 T：仍能找到 S 实例中的引用
    const fs: Files = .{ .main = f, .lib = f, .other = f };
    try testing.expectEqualStrings("x:1:x* x:4:x x:7:x x:11:x x:12:x", try refs(&w, fs, f, at(src, "x", 0), null));

    // `both` 中的 `p.x` 在 T 的实例下指向 T.x：有歧义（重命名会破坏 T 的实例）
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    var ambiguous: ?search.Reference = null;
    const def = (try definition.defAt(&r, f, at(src, "x", 0))).?;
    _ = try search.findReferences(&r, def, .{ .scope = &.{f}, .ambiguous = &ambiguous });
    try testing.expectEqual(at(src, "p.x", 0), ambiguous.?.start);
    // T.x 同样在 `both` 中有歧义
    ambiguous = null;
    const t_def = (try definition.defAt(&r, f, at(src, "x", 1))).?;
    _ = try search.findReferences(&r, t_def, .{ .scope = &.{f}, .ambiguous = &ambiguous });
    try testing.expectEqual(at(src, "p.x", 0), ambiguous.?.start);
}
