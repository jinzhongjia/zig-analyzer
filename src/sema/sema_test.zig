//! 类型推导测试：在内存项目中查询表达式与绑定的类型。

const std = @import("std");
const testing = std.testing;
const database = @import("../database.zig");
const resolve = @import("../names/resolve.zig");
const World = @import("../names/resolve_test.zig").World;
const ModuleGraph = @import("../names/ModuleGraph.zig");
const queries = @import("queries.zig");
const render = @import("render.zig");
const FileId = @import("../base/Vfs.zig").FileId;

/// `needle` 第 `nth` 次出现处：名字与绑定重合时取绑定的类型，否则取区间恰好为 `needle` 的表达式的类型
fn typeAt(w: *World, file: FileId, text: []const u8, needle: []const u8, nth: usize) ![]const u8 {
    const offset = try wordAt(text, needle, nth);
    const end: u32 = offset + @as(u32, @intCast(needle.len));

    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    const item = try r.ownerAt(file, offset, false) orelse return "no owner";
    const node = (try r.itemNode(file, item)).?;
    const owner = try r.ownerKey(file, item);
    const body = try ctx.get(database.hir.ItemBody, owner);
    const res = try ctx.get(queries.Infer, .{ .owner = owner, .mode = .full });
    const rel_start = offset - node.offset;
    const rel_end = end - node.offset;
    for (body.bindings, 0..) |b, i| if (b.range.start == rel_start and b.range.end == rel_end) {
        return render.typedValueAlloc(&r, res.bindings[i]);
    };
    for (body.expr_ranges, 0..) |range, i| if (range.start == rel_start and range.end == rel_end) {
        return render.typedValueAlloc(&r, res.exprs[i]);
    };
    // 成员自身：声明类型
    const tv = try ctx.get(queries.DeclType, .{ .owner = owner });
    return render.typedValueAlloc(&r, tv);
}

/// `needle` 第 `nth` 次作为完整单词出现的位置
fn wordAt(text: []const u8, needle: []const u8, nth: usize) !u32 {
    var start: usize = 0;
    var seen: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, needle)) |i| : (start = i + 1) {
        const before_ok = i == 0 or !isIdent(text[i - 1]);
        const after = i + needle.len;
        const after_ok = after >= text.len or !isIdent(text[after]) or !isIdent(needle[needle.len - 1]);
        if (!before_ok or !after_ok) continue;
        if (seen == nth) return @intCast(i);
        seen += 1;
    }
    return error.NeedleNotFound;
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn expectTypes(src: []const u8, cases: []const struct { []const u8, []const u8 }) !void {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.add("/p/main.zig", src);
    for (cases) |c| {
        const actual = try typeAt(&w, f.file, src, c[0], 0);
        testing.expectEqualStrings(c[1], actual) catch |err| {
            std.debug.print("type of `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "literals, annotations and primitives" {
    try expectTypes(
        \\fn f() void {
        \\    const a: u32 = 5;
        \\    const b = 5;
        \\    const s = "hi";
        \\    const x = 1.5;
        \\    var flag = true;
        \\    const n: ?u8 = null;
        \\    _ = .{ a, b, s, x, flag, n };
        \\}
    , &.{
        .{ "a", "u32 = 5" },
        .{ "b", "comptime_int = 5" },
        .{ "s", "*const [2:0]u8" },
        .{ "x", "comptime_float" },
        .{ "flag", "bool" },
        .{ "n", "?u8" },
    });
}

test "struct fields, methods and pointers" {
    try expectTypes(
        \\const Point = struct {
        \\    x: i32,
        \\    y: i32 = 0,
        \\    pub fn len(self: Point) u32 { _ = self; return 0; }
        \\};
        \\fn g(p: Point, ptr: *Point, buf: []u8, arr: [4]u8) void {
        \\    const px = p.x;
        \\    const qx = ptr.x;
        \\    const l = p.len();
        \\    const tail = buf[1..];
        \\    const first = arr[0];
        \\    const ap = &arr;
        \\    const n = buf.len;
        \\    const made = Point{ .x = 1 };
        \\    _ = .{ px, qx, l, tail, first, ap, n, made };
        \\}
    , &.{
        .{ "px", "i32" },
        .{ "qx", "i32" },
        .{ "l", "u32" },
        .{ "tail", "[]u8" },
        .{ "first", "u8" },
        .{ "ap", "*const [4]u8" },
        .{ "n", "usize" },
        .{ "made", "Point" },
        .{ "Point", "type = Point" },
    });
}

test "optionals, error unions, captures and loops" {
    try expectTypes(
        \\fn h(o: ?u8, e: anyerror!u16, items: []const u32, cond: bool) !void {
        \\    if (o) |v| _ = v;
        \\    const w = e catch 0;
        \\    const t = try e;
        \\    const u = o orelse 7;
        \\    for (items, 0..) |item, i| _ = .{ item, i };
        \\    const z = if (cond) @as(u8, 1) else null;
        \\    const blk_v = blk: {
        \\        if (cond) break :blk @as(u64, 1);
        \\        break :blk 2;
        \\    };
        \\    if (e) |ok| _ = ok else |err| _ = err;
        \\    _ = .{ w, t, u, z, blk_v };
        \\}
    , &.{
        .{ "v", "u8" },
        .{ "w", "u16" },
        .{ "t", "u16" },
        .{ "u", "u8" },
        .{ "item", "u32" },
        .{ "i", "usize" },
        .{ "z", "?u8" },
        .{ "blk_v", "u64" },
        .{ "ok", "u16" },
        .{ "err", "anyerror" },
        .{ "h", "fn (?u8, anyerror!u16, []const u32, bool) anyerror!void" },
    });
}

test "enums, tagged unions and switch" {
    try expectTypes(
        \\const Color = enum { red, green };
        \\const Shape = union(enum) { circle: f32, square: u32 };
        \\fn k(c: Color, s: Shape) u8 {
        \\    const picked: Color = .green;
        \\    const direct = Color.red;
        \\    switch (s) {
        \\        .circle => |radius| _ = radius,
        \\        .square => |side| _ = side,
        \\    }
        \\    const code = switch (c) { .red => @as(u8, 1), .green => 2 };
        \\    _ = .{ picked, direct, code };
        \\    return 0;
        \\}
    , &.{
        .{ "picked", "Color = .green" },
        .{ "direct", "Color = .red" },
        .{ "radius", "f32" },
        .{ "side", "u32" },
        .{ "code", "u8" },
    });
}

test "types across files and through std" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const std_root = try w.add("/zig/std/std.zig", "pub const mem = @import(\"mem.zig\");\n");
    _ = try w.add("/zig/std/mem.zig", "pub const Allocator = @import(\"mem/Allocator.zig\");\npub fn eql(a: []const u8, b: []const u8) bool { _ = .{ a, b }; return true; }\n");
    _ = try w.add("/zig/std/mem/Allocator.zig", "ptr: *anyopaque,\nconst Allocator = @This();\npub fn alloc(self: Allocator, n: usize) error{OutOfMemory}![]u8 { _ = .{ self, n }; unreachable; }\n");
    const src =
        \\const std = @import("std");
        \\fn run(gpa: std.mem.Allocator) !void {
        \\    const buf = try gpa.alloc(10);
        \\    const same = std.mem.eql(buf, "x");
        \\    const p = gpa.ptr;
        \\    _ = .{ buf, same, p };
        \\}
    ;
    const main = try w.add("/p/main.zig", src);
    try w.setGraph(std_root.file, &.{}, &.{});
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "buf", "[]u8" },
        .{ "same", "bool" },
        .{ "p", "*anyopaque" },
        .{ "gpa", "Allocator" },
        .{ "std", "type = std" },
    };
    for (cases) |c| {
        testing.expectEqualStrings(c[1], try typeAt(&w, main.file, src, c[0], 0)) catch |err| {
            std.debug.print("type of `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "decl literals" {
    try expectTypes(
        \\const Buf = struct {
        \\    len: usize,
        \\    pub const empty: Buf = .{ .len = 0 };
        \\    pub fn init(n: usize) Buf { return .{ .len = n }; }
        \\};
        \\const Mode = enum { fast, slow, pub const default: Mode = .fast; };
        \\fn g() void {
        \\    const a: Buf = .empty;
        \\    const b: Buf = .init(4);
        \\    const m: Mode = .default;
        \\    const s: Mode = .slow;
        \\    const T = @Int(.unsigned, 7);
        \\    _ = .{ a, b, m, s, T };
        \\}
    , &.{
        .{ "a", "Buf" },
        .{ "b", "Buf" },
        .{ "init", "fn (usize) Buf" },
        .{ "m", "Mode = .fast" },
        .{ "s", "Mode = .slow" },
        .{ "T", "type = u7" },
    });
}

test "generic type constructors and instances" {
    try expectTypes(
        \\fn List(comptime T: type) type {
        \\    return struct {
        \\        items: []T,
        \\        const Self = @This();
        \\        pub fn get(self: Self, i: usize) T { return self.items[i]; }
        \\        pub fn first(self: *Self) ?*T { _ = self; return null; }
        \\    };
        \\}
        \\fn Wrapper(comptime T: type) type { return List(T); }
        \\fn g(l: List(u8), w: Wrapper(i32)) void {
        \\    const its = l.items;
        \\    const x = l.get(0);
        \\    const y = w.get(1);
        \\    const f = (&l).first();
        \\    _ = .{ its, x, y, f };
        \\}
    , &.{
        .{ "l", "List(u8)" },
        .{ "w", "List(i32)" },
        .{ "its", "[]u8" },
        // 泛型定义处（没有具体实例）：抽象参数
        .{ "items", "[]T" },
        .{ "x", "u8" },
        .{ "y", "i32" },
        .{ "f", "?*u8" },
    });
}

test "generic functions, anytype and comptime branches" {
    try expectTypes(
        \\fn max(comptime T: type, a: T, b: T) T { return if (a > b) a else b; }
        \\fn id(x: anytype) @TypeOf(x) { return x; }
        \\fn Pick(comptime wide: bool) type {
        \\    if (wide) return u64;
        \\    return u8;
        \\}
        \\fn Aligned(comptime T: type, comptime alignment: ?u8) type {
        \\    if (alignment) |a| {
        \\        if (a == 1) return Aligned(T, null);
        \\    }
        \\    return struct { items: []T, pub const Slice = if (alignment) |_| []const T else []T; };
        \\}
        \\fn Bits(comptime n: u16) type { return @Int(.unsigned, n * 2); }
        \\fn Rec(comptime n: u32) type { return Rec(n + 1); }
        \\fn g() void {
        \\    const m = max(u32, 1, 2);
        \\    const v = id(@as(u16, 1));
        \\    const P = Pick(true);
        \\    const Q = Pick(false);
        \\    const S = Aligned(u8, null).Slice;
        \\    const B = Bits(4);
        \\    const R = Rec(0);
        \\    _ = .{ m, v, P, Q, S, B, R };
        \\}
    , &.{
        .{ "m", "u32" },
        .{ "v", "u16" },
        .{ "P", "type = u64" },
        .{ "Q", "type = u8" },
        .{ "S", "type = []u8" },
        .{ "B", "type = u8" },
        // 无限递归的类型构造：到达深度上限后为未知值，不会卡住
        .{ "R", "type" },
    });
}

test "names of containers defined in bodies" {
    try expectTypes(
        \\fn Box(comptime T: type) type { return struct { v: T }; }
        \\fn g() void {
        \\    const E = enum { a, b };
        \\    const bx = Box(E){ .v = .a };
        \\    _ = bx;
        \\}
    , &.{
        .{ "bx", "Box(E)" },
    });
}

test "generic bodies without an instance use abstract parameters" {
    try expectTypes(
        \\fn List(comptime T: type) type {
        \\    return struct {
        \\        items: []T,
        \\        pub fn get(self: @This(), i: usize) T { const it = self.items[i]; return it; }
        \\    };
        \\}
    , &.{
        .{ "it", "T" },
    });
}

test "unknown parts stay unknown" {
    try expectTypes(
        \\fn opaqueFn(x: u8) type { _ = x; return u8; }
        \\fn g(n: u8) void {
        \\    const T = opaqueFn(n);
        \\    _ = T;
        \\}
    , &.{
        // 返回 type 的函数：实参不是 comptime 值时仍按实例求值（函数体不依赖参数时可以求出）
        .{ "T", "type = u8" },
    });
}

/// 使用本机 zig 的真实标准库（PATH 中没有 zig 时跳过）
fn expectStdTypes(src: []const u8, cases: []const struct { []const u8, []const u8 }) !void {
    var env = @import("../project/ZigEnv.zig").query(testing.allocator, testing.io, null) catch return error.SkipZigTest;
    defer env.deinit(testing.allocator);
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const std_root_path = try std.fs.path.join(testing.allocator, &.{ env.std_dir, "std.zig" });
    defer testing.allocator.free(std_root_path);
    const std_root = try w.vfs.intern(std_root_path);
    const f = try w.add("/p/main.zig", src);
    try w.setGraph(std_root, &.{}, &.{});
    for (cases) |c| {
        const actual = try typeAt(&w, f.file, src, c[0], 0);
        testing.expectEqualStrings(c[1], actual) catch |err| {
            std.debug.print("type of `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "std generic containers" {
    try expectStdTypes(
        \\const std = @import("std");
        \\const Point = struct { x: i32, y: i32 };
        \\fn g(gpa: std.mem.Allocator) !void {
        \\    var list: std.ArrayList(u8) = .empty;
        \\    try list.append(gpa, 1);
        \\    const items = list.items;
        \\    const last = list.getLast();
        \\    const popped = list.pop();
        \\    var map: std.AutoHashMap(u32, []const u8) = .init(gpa);
        \\    const got = map.get(1);
        \\    const entry = try map.getOrPut(2);
        \\    var points: std.MultiArrayList(Point) = .empty;
        \\    const n = points.len;
        \\    var sm: std.StringHashMapUnmanaged(bool) = .empty;
        \\    const flag = sm.get("a");
        \\    const fs = @typeInfo(Point).@"struct".field_names;
        \\    const info = @typeInfo(Point);
        \\    const FT = @FieldType(Point, "y");
        \\    const num = try std.fmt.parseInt(u32, "1", 10);
        \\    var it = std.mem.splitScalar(u8, "a,b", ',');
        \\    const part = it.next();
        \\    const buf = try gpa.alloc(u32, 4);
        \\    const loc = @src();
        \\    _ = .{ items, last, popped, got, entry, n, flag, fs, info, FT, num, part, buf, loc };
        \\}
    , &.{
        .{ "list", "Aligned(u8, null)" },
        .{ "items", "[]u8" },
        .{ "last", "u8" },
        .{ "popped", "?u8" },
        .{ "got", "?[]const u8" },
        .{ "n", "usize" },
        .{ "flag", "?bool" },
        .{ "entry", "GetOrPutResult(u32, []const u8, AutoContext(u32), 80)" },
        .{ "fs", "[]const [:0]const u8" },
        .{ "info", "Type" },
        .{ "FT", "type = i32" },
        .{ "num", "u32" },
        .{ "it", "SplitIterator(u8, .scalar)" },
        .{ "part", "?[]const u8" },
        .{ "buf", "[]u32" },
        .{ "loc", "SourceLocation" },
    });
}
