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

test "references to standard library declarations from project files" {
    // 项目文件只导入 std.zig：std.zig → mem.zig 这条边来自搜索范围外的文件，没有它时只在 mem.zig 中查找
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const ModuleGraph = database.ModuleGraph;
    const std_root = try w.add("/zig/std/std.zig", "pub const mem = @import(\"mem.zig\");\nconst x = mem.eql;\n");
    const mem_src = "pub fn eql() bool {\n    return true;\n}\nconst y = eql;\n";
    const mem = try w.add("/zig/std/mem.zig", mem_src);
    const app_src = "const std = @import(\"std\");\npub fn main() void {\n    _ = std.mem.eql();\n}\n";
    const app = try w.add("/p/main.zig", app_src);
    const unrelated = try w.add("/p/other.zig", "fn eql() void {}\ntest {\n    eql();\n}\n");
    try w.setGraph(std_root.file, &.{.{ .root = app.file, .imports = &.{} }}, &.{
        .{ .file = app.file, .module = 0, .root_module = 0 },
        .{ .file = unrelated.file, .module = 0, .root_module = 0 },
        .{ .file = std_root.file, .module = ModuleGraph.std_module, .root_module = 0 },
        .{ .file = mem.file, .module = ModuleGraph.std_module, .root_module = 0 },
    });
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    const def = try definition.defAt(&r, app.file, @intCast(std.mem.indexOf(u8, app_src, "eql").?)) orelse return error.NoDefinition;
    const list = try search.findReferences(&r, def, .{ .scope = &.{ app.file, unrelated.file } });
    var out: std.ArrayList(u8) = .empty;
    for (list) |ref| {
        const text = (try ctx.get(database.syntax.SourceText, ref.file)).text;
        try out.print(w.arena.allocator(), "{s}:{d}{s} ", .{ std.fs.path.stem(w.vfs.path(ref.file)), std.mem.count(u8, text[0..ref.start], "\n") + 1, if (ref.is_decl) "*" else "" });
    }
    // 范围外的其他文件（std.zig）不查找
    try testing.expectEqualStrings("mem:1* mem:4 main:3 ", out.items);
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

test "references in generic bodies use a call site instance" {
    const src =
        \\const Real = struct {
        \\    pub fn getenv(_: *Real) ?[]const u8 {
        \\        return null;
        \\    }
        \\};
        \\fn lookup(comptime System: type, system: *System) ?[]const u8 {
        \\    return system.getenv();
        \\}
        \\pub fn main() void {
        \\    var s: Real = .{};
        \\    _ = lookup(Real, &s);
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = (try w.add("/p/x.zig", src)).file;
    const fs: Files = .{ .main = f, .lib = f, .other = f };
    // `system` 在抽象的推导中未知：与跳转一样取调用点（`lookup(Real, ..)`）的实例
    try testing.expectEqualStrings("x:2:getenv* x:7:getenv", try refs(&w, fs, f, at(src, "getenv", 0), null));
}

test "references in generic bodies use the instance a comptime type argument dispatches to" {
    // 分派处（`Q.compute(ctx)`）所在的文件不 import 被调函数所在的文件：曾只有跳转找到这个实例，引用与重命名遗漏
    const queries_src =
        \\pub const Cache = struct {
        \\    pub fn take(c: *Cache) u32 {
        \\        _ = c;
        \\        return 1;
        \\    }
        \\};
        \\pub const Item = struct {
        \\    pub fn compute(ctx: anytype) u32 {
        \\        return ctx.cache.take();
        \\    }
        \\};
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const engine_file = (try w.add("/p/engine.zig",
        \\pub fn Engine(comptime Ctx: type) type {
        \\    return struct {
        \\        pub fn get(ctx: *Ctx, comptime Q: type) u32 {
        \\            return Q.compute(ctx);
        \\        }
        \\    };
        \\}
    )).file;
    const queries_file = (try w.add("/p/queries.zig", queries_src)).file;
    const main_file = (try w.add("/p/main.zig",
        \\const Engine = @import("engine.zig").Engine;
        \\const queries = @import("queries.zig");
        \\const Ctx = struct { cache: queries.Cache };
        \\fn run(ctx: *Ctx) u32 {
        \\    return Engine(Ctx).get(ctx, queries.Item);
        \\}
    )).file;
    try w.setGraph(null, &.{.{ .root = main_file, .imports = &.{} }}, &.{
        .{ .file = engine_file, .module = 0, .root_module = 0 },
        .{ .file = queries_file, .module = 0, .root_module = 0 },
        .{ .file = main_file, .module = 0, .root_module = 0 },
    });
    const fs: Files = .{ .main = main_file, .lib = queries_file, .other = engine_file };
    try testing.expectEqualStrings("queries:2:take* queries:9:take", try refs(&w, fs, queries_file, at(queries_src, "take", 0), null));
}

test "references to tagged union fields through the type and error union results" {
    const src =
        \\const Value = union(enum) { null_val: void, int: i64 };
        \\fn parse(n: u8) error{Bad}!Value {
        \\    if (n == 0) return .null_val;
        \\    return .{ .int = n };
        \\}
        \\test {
        \\    _ = Value.null_val;
        \\}
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = (try w.add("/p/x.zig", src)).file;
    const fs: Files = .{ .main = f, .lib = f, .other = f };
    try testing.expectEqualStrings("x:1:null_val* x:3:null_val x:7:null_val", try refs(&w, fs, f, at(src, "null_val", 0), null));
}
