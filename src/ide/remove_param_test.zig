const std = @import("std");
const testing = std.testing;
const database = @import("../database.zig");
const resolve = @import("../names/resolve.zig");
const World = @import("../names/resolve_test.zig").World;
const FileId = @import("../base/Vfs.zig").FileId;
const remove_param = @import("remove_param.zig");

/// 删除 `<|>`（参数名上）处的未使用参数：返回编辑后的文本（fixture 有多个文件时为改动的各个文件，每个以
/// `//- <路径>` 开始），不能删除时为「<路径>:<行>:<列> <原因>」，不提供删除时为 "no target"。
/// 不以 `//- ` 开始的文本是单个文件 `/p/main.zig`
fn remove(text: []const u8) ![]const u8 {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const a = w.arena.allocator();
    const multi = std.mem.startsWith(u8, text, "//- ");
    const fx = try w.fixture(if (multi) text else try std.mem.concat(a, u8, &.{ "//- /p/main.zig\n", text }));
    var ctx = w.db.beginRead(a);
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = a };
    const cursor = fx.cursor orelse return error.NoCursor;
    const found = try remove_param.targets(&r, cursor.file, cursor.offset, cursor.offset);
    if (found.len == 0) return testing.allocator.dupe(u8, "no target");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    switch (try remove_param.edits(&r, found[0], fx.files)) {
        .failed => |p| {
            const path = pathOf(fx, p.file);
            const offset = p.offset orelse {
                try out.print(testing.allocator, "{s} {s}", .{ path, p.message });
                return out.toOwnedSlice(testing.allocator);
            };
            const src = (try ctx.get(database.syntax.SourceText, p.file)).text;
            const line = std.mem.count(u8, src[0..offset], "\n") + 1;
            const line_start = if (std.mem.lastIndexOfScalar(u8, src[0..offset], '\n')) |i| i + 1 else 0;
            try out.print(testing.allocator, "{s}:{d}:{d} {s}", .{ path, line, offset - line_start + 1, p.message });
        },
        .ok => |files| {
            for (files) |fe| {
                const src = (try ctx.get(database.syntax.SourceText, fe.file)).text;
                if (multi) try out.print(testing.allocator, "//- {s}\n", .{pathOf(fx, fe.file)});
                var pos: u32 = 0;
                for (fe.edits) |e| {
                    try out.appendSlice(testing.allocator, src[pos..e.start]);
                    try out.appendSlice(testing.allocator, e.text);
                    pos = e.end;
                }
                try out.appendSlice(testing.allocator, src[pos..]);
            }
            // fixture 中每个文件以换行结束
            if (std.mem.endsWith(u8, out.items, "\n")) out.items.len -= 1;
        },
    }
    return out.toOwnedSlice(testing.allocator);
}

fn pathOf(fx: World.Fixture, file: FileId) []const u8 {
    for (fx.paths, fx.files) |p, f| if (f == file) return p;
    return "?";
}

fn expectRemove(text: []const u8, expected: []const u8) !void {
    const got = try remove(text);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "remove parameter: plain function" {
    try expectRemove(
        \\fn f(a: u32, <|>b: u32, c: u32) u32 {
        \\    return a + c;
        \\}
        \\fn g() u32 {
        \\    return f(1, 2, 3) + f(4, 5, 6);
        \\}
    ,
        \\fn f(a: u32, c: u32) u32 {
        \\    return a + c;
        \\}
        \\fn g() u32 {
        \\    return f(1, 3) + f(4, 6);
        \\}
    );
    try expectRemove(
        \\fn f(<|>a: u32, b: u32) u32 {
        \\    return b;
        \\}
        \\fn g() u32 {
        \\    return f(1, 2);
        \\}
    ,
        \\fn f(b: u32) u32 {
        \\    return b;
        \\}
        \\fn g() u32 {
        \\    return f(2);
        \\}
    );
    try expectRemove(
        \\fn f(a: u32, <|>b: u32) u32 {
        \\    return a;
        \\}
        \\fn g() u32 {
        \\    return f(1, 2);
        \\}
    ,
        \\fn f(a: u32) u32 {
        \\    return a;
        \\}
        \\fn g() u32 {
        \\    return f(1);
        \\}
    );
    try expectRemove(
        \\fn f(<|>a: u32) void {}
        \\fn g() void {
        \\    f(1);
        \\    (f)(2);
        \\}
    ,
        \\fn f() void {}
        \\fn g() void {
        \\    f();
        \\    (f)();
        \\}
    );
    // 没有调用处
    try expectRemove(
        \\pub fn f(a: u32, <|>b: u32) u32 {
        \\    return a;
        \\}
    ,
        \\pub fn f(a: u32) u32 {
        \\    return a;
        \\}
    );
    // 递归调用、字段默认值与容器级声明中的调用
    try expectRemove(
        \\fn f(n: u32, <|>b: u32) u32 {
        \\    if (n == 0) return 0;
        \\    return f(n - 1, 7);
        \\}
        \\const S = struct {
        \\    x: u32 = f(1, 2),
        \\};
        \\const v = f(3, 4);
    ,
        \\fn f(n: u32) u32 {
        \\    if (n == 0) return 0;
        \\    return f(n - 1);
        \\}
        \\const S = struct {
        \\    x: u32 = f(1),
        \\};
        \\const v = f(3);
    );
}

test "remove parameter: methods" {
    try expectRemove(
        \\const S = struct {
        \\    x: u32,
        \\    fn get(self: S, <|>scale: u32) u32 {
        \\        return self.x;
        \\    }
        \\};
        \\fn g(s: S, p: *const S) u32 {
        \\    return s.get(2) + S.get(s, 3) + p.get(4);
        \\}
    ,
        \\const S = struct {
        \\    x: u32,
        \\    fn get(self: S) u32 {
        \\        return self.x;
        \\    }
        \\};
        \\fn g(s: S, p: *const S) u32 {
        \\    return s.get() + S.get(s) + p.get();
        \\}
    );
    // 文件作为容器，`@This()` 的别名
    try expectRemove(
        \\const Self = @This();
        \\x: u32,
        \\fn get(self: *const Self, <|>i: usize, j: usize) usize {
        \\    return self.x + j;
        \\}
        \\fn g(s: Self) usize {
        \\    return s.get(1, 2) + Self.get(&s, 3, 4) + @This().get(&s, 5, 6);
        \\}
    ,
        \\const Self = @This();
        \\x: u32,
        \\fn get(self: *const Self, j: usize) usize {
        \\    return self.x + j;
        \\}
        \\fn g(s: Self) usize {
        \\    return s.get(2) + Self.get(&s, 4) + @This().get(&s, 6);
        \\}
    );
    // 第一个参数不是接收者时可以删除
    try expectRemove(
        \\const S = struct {
        \\    fn f(<|>a: u32, b: u32) u32 {
        \\        return b;
        \\    }
        \\};
        \\fn g() u32 {
        \\    return S.f(1, 2);
        \\}
    ,
        \\const S = struct {
        \\    fn f(b: u32) u32 {
        \\        return b;
        \\    }
        \\};
        \\fn g() u32 {
        \\    return S.f(2);
        \\}
    );
    // 泛型容器的方法
    try expectRemove(
        \\fn List(comptime T: type) type {
        \\    return struct {
        \\        items: []T,
        \\        const Self = @This();
        \\        fn get(self: Self, i: usize, <|>hint: bool) T {
        \\            return self.items[i];
        \\        }
        \\    };
        \\}
        \\fn g(l: List(u8), m: List(u16)) u16 {
        \\    return l.get(0, true) + m.get(1, false);
        \\}
    ,
        \\fn List(comptime T: type) type {
        \\    return struct {
        \\        items: []T,
        \\        const Self = @This();
        \\        fn get(self: Self, i: usize) T {
        \\            return self.items[i];
        \\        }
        \\    };
        \\}
        \\fn g(l: List(u8), m: List(u16)) u16 {
        \\    return l.get(0) + m.get(1);
        \\}
    );
    // 声明字面量
    try expectRemove(
        \\const S = struct {
        \\    x: u32,
        \\    fn init(x: u32, <|>y: u32) S {
        \\        return .{ .x = x };
        \\    }
        \\};
        \\fn g() S {
        \\    const s: S = .init(1, 2);
        \\    return s;
        \\}
    ,
        \\const S = struct {
        \\    x: u32,
        \\    fn init(x: u32) S {
        \\        return .{ .x = x };
        \\    }
        \\};
        \\fn g() S {
        \\    const s: S = .init(1);
        \\    return s;
        \\}
    );
    // 泛型函数中的方法调用：按调用点的实例确认是方法调用
    try expectRemove(
        \\const S = struct {
        \\    fn get(self: S, <|>i: u32) void {
        \\        _ = self;
        \\    }
        \\};
        \\fn g(x: anytype) void {
        \\    x.get(1);
        \\}
        \\fn h() void {
        \\    g(S{});
        \\}
    ,
        \\const S = struct {
        \\    fn get(self: S) void {
        \\        _ = self;
        \\    }
        \\};
        \\fn g(x: anytype) void {
        \\    x.get();
        \\}
        \\fn h() void {
        \\    g(S{});
        \\}
    );
}

test "remove parameter: receivers are not offered" {
    try expectRemove(
        \\const S = struct {
        \\    fn f(<|>self: S) void {}
        \\};
    , "no target");
    try expectRemove(
        \\const S = struct {
        \\    fn f(<|>self: *S) void {}
        \\};
    , "no target");
    try expectRemove(
        \\const Self = @This();
        \\fn f(<|>self: *const Self) void {}
    , "no target");
    try expectRemove(
        \\fn List(comptime T: type) type {
        \\    return struct {
        \\        items: []T,
        \\        fn f(<|>self: @This()) void {}
        \\    };
        \\}
    , "no target");
}

test "remove parameter: export and variadic functions are not offered" {
    try expectRemove(
        \\export fn f(a: u32, <|>b: u32) u32 {
        \\    return a;
        \\}
    , "no target");
    try expectRemove(
        \\fn f(a: u32, <|>b: u32, ...) callconv(.c) u32 {
        \\    return a;
        \\}
    , "no target");
}

test "remove parameter: multi-line lists" {
    try expectRemove(
        \\fn f(
        \\    a: u32,
        \\    /// not used
        \\    <|>b: u32,
        \\    c: u32, // last
        \\) u32 {
        \\    return a + c;
        \\}
        \\fn g() u32 {
        \\    return f(
        \\        1,
        \\        2, // two
        \\        3,
        \\    );
        \\}
    ,
        \\fn f(
        \\    a: u32,
        \\    c: u32, // last
        \\) u32 {
        \\    return a + c;
        \\}
        \\fn g() u32 {
        \\    return f(
        \\        1,
        \\        3,
        \\    );
        \\}
    );
    try expectRemove(
        \\fn f(
        \\    a: u32,
        \\    <|>b: u32,
        \\) u32 {
        \\    return a;
        \\}
        \\fn g() u32 {
        \\    return f(1, 2) + f(
        \\        3,
        \\        4,
        \\    );
        \\}
    ,
        \\fn f(
        \\    a: u32,
        \\) u32 {
        \\    return a;
        \\}
        \\fn g() u32 {
        \\    return f(1) + f(
        \\        3,
        \\    );
        \\}
    );
    // 删除唯一的一项后括号之间为空
    try expectRemove(
        \\fn f(
        \\    <|>a: u32,
        \\) void {}
        \\fn g() void {
        \\    f(
        \\        1,
        \\    );
        \\}
    ,
        \\fn f() void {}
        \\fn g() void {
        \\    f();
        \\}
    );
}

test "remove parameter: multiline string arguments" {
    try expectRemove(
        \\fn f(<|>a: []const u8, b: u32) u32 {
        \\    return b;
        \\}
        \\fn g() u32 {
        \\    return f(
        \\        \\abc
        \\    , 1);
        \\}
    ,
        \\fn f(b: u32) u32 {
        \\    return b;
        \\}
        \\fn g() u32 {
        \\    return f(1);
        \\}
    );
    try expectRemove(
        \\fn f(a: []const u8, <|>b: u32) []const u8 {
        \\    return a;
        \\}
        \\fn g() []const u8 {
        \\    return f(
        \\        \\abc
        \\    , 1);
        \\}
    ,
        \\fn f(a: []const u8) []const u8 {
        \\    return a;
        \\}
        \\fn g() []const u8 {
        \\    return f(
        \\        \\abc
        \\    );
        \\}
    );
    try expectRemove(
        \\fn f(a: u32, <|>b: []const u8, c: u32) u32 {
        \\    return a + c;
        \\}
        \\fn g() u32 {
        \\    return f(1,
        \\        \\abc
        \\    , 2);
        \\}
    ,
        \\fn f(a: u32, c: u32) u32 {
        \\    return a + c;
        \\}
        \\fn g() u32 {
        \\    return f(1, 2);
        \\}
    );
    // 多行字符串之后的逗号须另起一行：删除它之前的一项时保留换行
    try expectRemove(
        \\fn f(<|>a: u32, b: []const u8) []const u8 {
        \\    return b;
        \\}
        \\fn g() []const u8 {
        \\    return f(1,
        \\        \\abc
        \\    );
        \\}
    ,
        \\fn f(b: []const u8) []const u8 {
        \\    return b;
        \\}
        \\fn g() []const u8 {
        \\    return f(
        \\        \\abc
        \\    );
        \\}
    );
}

test "remove parameter: calls in other files" {
    try expectRemove(
        \\//- /p/main.zig module:main deps:lib
        \\const lib = @import("lib");
        \\pub fn main() void {
        \\    _ = lib.f(1, 2);
        \\    _ = lib.S.m(3, 4);
        \\}
        \\//- /p/lib.zig module:lib
        \\pub fn f(a: u32, <|>b: u32) u32 {
        \\    return a + g();
        \\}
        \\pub fn g() u32 {
        \\    return f(3, 4);
        \\}
        \\pub const S = struct {
        \\    pub fn m(a: u32, b: u32) u32 {
        \\        return f(a, b) + b;
        \\    }
        \\};
    ,
        \\//- /p/main.zig
        \\const lib = @import("lib");
        \\pub fn main() void {
        \\    _ = lib.f(1);
        \\    _ = lib.S.m(3, 4);
        \\}
        \\//- /p/lib.zig
        \\pub fn f(a: u32) u32 {
        \\    return a + g();
        \\}
        \\pub fn g() u32 {
        \\    return f(3);
        \\}
        \\pub const S = struct {
        \\    pub fn m(a: u32, b: u32) u32 {
        \\        return f(a) + b;
        \\    }
        \\};
    );
}

test "remove parameter: test names and comptime cascades" {
    // decltest 的名字不是调用
    try expectRemove(
        \\fn f(a: u32, <|>b: u32) u32 {
        \\    return a;
        \\}
        \\test f {
        \\    _ = f(1, 2);
        \\}
    ,
        \\fn f(a: u32) u32 {
        \\    return a;
        \\}
        \\test f {
        \\    _ = f(1);
        \\}
    );
    // 删除 `x` 后 `T` 不再被使用：仍然可以删除（之后再删除 `T`）
    try expectRemove(
        \\fn f(comptime T: type, <|>x: T) void {}
        \\fn g() void {
        \\    f(u32, 1);
        \\}
    ,
        \\fn f(comptime T: type) void {}
        \\fn g() void {
        \\    f(u32);
        \\}
    );
}

test "remove parameter: type function calls in arguments" {
    try expectRemove(
        \\fn Wrap(comptime <|>A: type, comptime B: type) type {
        \\    return B;
        \\}
        \\const X = Wrap(Wrap(u8, u16), u32);
        \\const Y = Wrap(u8, Wrap(u16, u32));
    ,
        \\fn Wrap(comptime B: type) type {
        \\    return B;
        \\}
        \\const X = Wrap(u32);
        \\const Y = Wrap(Wrap(u32));
    );
}

test "remove parameter: uses that cannot be updated" {
    try expectRemove(
        \\fn f(a: u32, <|>b: u32) u32 {
        \\    return a;
        \\}
        \\fn g() u32 {
        \\    return @call(.auto, f, .{ 1, 2 });
        \\}
    , "/p/main.zig:5:25 the function is used here other than in a call, so this use cannot be updated");
    try expectRemove(
        \\fn f(a: u32, <|>b: u32) u32 {
        \\    return a;
        \\}
        \\const p: *const fn (u32, u32) u32 = &f;
    , "/p/main.zig:4:38 the function is used here other than in a call, so this use cannot be updated");
    try expectRemove(
        \\fn f(a: u32, <|>b: u32) u32 {
        \\    return a;
        \\}
        \\const T = @TypeOf(f);
    , "/p/main.zig:4:19 the function is used here other than in a call, so this use cannot be updated");
    try expectRemove(
        \\fn f(a: u32, <|>b: u32) u32 {
        \\    return a;
        \\}
        \\const name = "f";
    , "/p/main.zig:4:14 `f` appears in a string literal, which may refer to it by name (as `@field` and serialization do) and would not be updated");
}

test "remove parameter: arguments with side effects" {
    try expectRemove(
        \\fn f(a: u32, <|>b: u32) u32 {
        \\    return a;
        \\}
        \\fn h() u32 {
        \\    return 1;
        \\}
        \\fn g() u32 {
        \\    return f(1, h());
        \\}
    , "/p/main.zig:8:17 removing the argument here would drop its side effects");
    try expectRemove(
        \\fn f(a: u32, <|>b: u32) u32 {
        \\    return a;
        \\}
        \\fn h() !u32 {
        \\    return f(1, try h());
        \\}
    , "/p/main.zig:5:17 removing the argument here would drop its side effects");
    try expectRemove(
        \\fn f(a: u32, <|>b: u32) u32 {
        \\    return a;
        \\}
        \\fn g(x: *u32) u32 {
        \\    return f(1, blk: {
        \\        x.* += 1;
        \\        break :blk x.*;
        \\    });
        \\}
    , "/p/main.zig:5:17 removing the argument here would drop its side effects");
    // 没有副作用的内建函数
    try expectRemove(
        \\fn f(a: u32, <|>b: u32) u32 {
        \\    return a;
        \\}
        \\const x: u64 = 1;
        \\fn g() u32 {
        \\    return f(1, @intCast(x)) + f(2, @sizeOf(u8));
        \\}
    ,
        \\fn f(a: u32) u32 {
        \\    return a;
        \\}
        \\const x: u64 = 1;
        \\fn g() u32 {
        \\    return f(1) + f(2);
        \\}
    );
}

test "remove parameter: new errors at call sites" {
    try expectRemove(
        \\fn f(a: u32, <|>b: u32) u32 {
        \\    return a;
        \\}
        \\fn g() u32 {
        \\    const y = 2;
        \\    return f(1, y);
        \\}
    , "/p/main.zig:5:11 the edit would cause an error here: unused local constant");
    // 调用者的参数只传给了删除的实参
    try expectRemove(
        \\//- /p/main.zig module:main deps:lib
        \\const lib = @import("lib");
        \\pub fn main() void {
        \\    _ = lib.f(1, 2);
        \\}
        \\pub fn g(a: u32, b: u32) u32 {
        \\    return lib.f(a, b);
        \\}
        \\//- /p/lib.zig module:lib
        \\pub fn f(a: u32, <|>b: u32) u32 {
        \\    return a;
        \\}
    , "/p/main.zig:5:18 the edit would cause an error here: unused function parameter");
}

test "remove parameter: method calls passing the parameter" {
    try expectRemove(
        \\const S = struct {
        \\    fn f(<|>x: anytype, b: u32) u32 {
        \\        return b;
        \\    }
        \\};
        \\fn g(s: S) u32 {
        \\    return s.f(1);
        \\}
    , "/p/main.zig:7:14 this method call passes the value before `.` as the parameter");
}

test "remove parameter: files with syntax errors" {
    try expectRemove(
        \\//- /p/main.zig module:main deps:lib
        \\const lib = @import("lib");
        \\pub fn main() void {
        \\    _ = lib.f(1, 2)
        \\}
        \\//- /p/lib.zig module:lib
        \\pub fn f(a: u32, <|>b: u32) u32 {
        \\    return a;
        \\}
    , "/p/main.zig the file has syntax errors, so calls in it may be missed");
}

test "remove parameter: references whose type is unknown" {
    try expectRemove(
        \\const S = struct {
        \\    fn f(self: S, <|>b: u32) void {
        \\        _ = self;
        \\    }
        \\};
        \\fn g(x: anytype) void {
        \\    x.f(1);
        \\}
    , "/p/main.zig:7:5 the type here is unknown, so whether this refers to the function cannot be confirmed");
}
