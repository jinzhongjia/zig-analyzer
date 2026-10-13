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
    const tv = try ctx.get(queries.DeclType, owner);
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

test "generic calls and unknown parts stay unknown" {
    try expectTypes(
        \\fn List(comptime T: type) type { return struct { items: []T }; }
        \\fn max(comptime T: type, a: T, b: T) T { return if (a > b) a else b; }
        \\fn g() void {
        \\    const L = List(u8);
        \\    const m = max(u32, 1, 2);
        \\    _ = .{ L, m };
        \\}
    , &.{
        // 返回类型声明为 type：类型已知、值未知（需要 comptime 求值，M5）
        .{ "L", "type" },
        .{ "m", "unknown" },
    });
}
