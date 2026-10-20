//! 类型推导测试：在内存项目中查询表达式与绑定的类型。

const std = @import("std");
const testing = std.testing;
const database = @import("../database.zig");
const resolve = @import("../names/resolve.zig");
const World = @import("../names/resolve_test.zig").World;
const ModuleGraph = @import("../names/ModuleGraph.zig");
const queries = @import("queries.zig");
const render = @import("render.zig");
const InternPool = @import("InternPool.zig");
const value = @import("value.zig");
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
    return expectTypesTargeted(.{}, src, cases);
}

/// 同 `expectTypes`，使用给定的目标参数（指针位宽、向量的布局规则）
fn expectTypesTargeted(target: InternPool.Target, src: []const u8, cases: []const struct { []const u8, []const u8 }) !void {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.setTarget(target);
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
        .{ "x", "comptime_float = 1.5" },
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

test "pointer captures follow the constness of the captured place" {
    try expectTypes(
        \\const U = union(enum) { a: u8, b: u16 };
        \\fn probe(cs: []const u8, opt: ?u8, u: U, up: *const U, cps: *const [3]u8) void {
        \\    const arr = [_]u8{ 1, 2, 3 };
        \\    for (&arr) |*p| {
        \\        const v_for_const_arr_ptr = p;
        \\        _ = v_for_const_arr_ptr;
        \\    }
        \\    for (cs) |*p| {
        \\        const v_for_const_slice_ptr = p;
        \\        _ = v_for_const_slice_ptr;
        \\    }
        \\    for (cps) |*p| {
        \\        const v_for_constptr_arr = p;
        \\        _ = v_for_constptr_arr;
        \\    }
        \\    if (opt) |*p| {
        \\        const v_if_opt_ptr = p;
        \\        _ = v_if_opt_ptr;
        \\    }
        \\    while (opt) |*p| {
        \\        const v_while_opt_ptr = p;
        \\        _ = v_while_opt_ptr;
        \\        break;
        \\    }
        \\    switch (u) {
        \\        .a => |*p| {
        \\            const v_switch_union_ptr = p;
        \\            _ = v_switch_union_ptr;
        \\        },
        \\        else => {},
        \\    }
        \\    switch (up.*) {
        \\        .a => |*p| {
        \\            const v_switch_constptr_union_ptr = p;
        \\            _ = v_switch_constptr_union_ptr;
        \\        },
        \\        else => {},
        \\    }
        \\}
        \\fn mutable(opt: ?u8, up: *U, cs: []u8) void {
        \\    var arr = [_]u8{ 1, 2, 3 };
        \\    for (&arr) |*p| {
        \\        const m_for_var_arr_ptr = p;
        \\        _ = m_for_var_arr_ptr;
        \\    }
        \\    for (arr) |*p| {
        \\        const m_for_arr_value_ptr = p;
        \\        _ = m_for_arr_value_ptr;
        \\    }
        \\    for (cs) |*p| {
        \\        const m_for_slice_ptr = p;
        \\        _ = m_for_slice_ptr;
        \\    }
        \\    var o = opt;
        \\    if (o) |*p| {
        \\        const m_if_opt_ptr = p;
        \\        _ = m_if_opt_ptr;
        \\    }
        \\    var uu: U = .a;
        \\    switch (uu) {
        \\        .a => |*p| {
        \\            const m_switch_union_ptr = p;
        \\            _ = m_switch_union_ptr;
        \\        },
        \\        else => {},
        \\    }
        \\    switch (up.*) {
        \\        .a => |*p| {
        \\            const m_switch_mutptr_union_ptr = p;
        \\            _ = m_switch_mutptr_union_ptr;
        \\        },
        \\        else => {},
        \\    }
        \\}
        \\comptime {
        \\    _ = .{ &probe, &mutable };
        \\}
    , &.{
        .{ "v_for_const_arr_ptr", "*const u8" },
        .{ "v_for_const_slice_ptr", "*const u8" },
        .{ "v_for_constptr_arr", "*const u8" },
        .{ "v_if_opt_ptr", "*const u8" },
        .{ "v_while_opt_ptr", "*const u8" },
        .{ "v_switch_union_ptr", "*const u8" },
        .{ "v_switch_constptr_union_ptr", "*const u8" },
        .{ "m_for_var_arr_ptr", "*u8" },
        .{ "m_for_arr_value_ptr", "*u8" },
        .{ "m_for_slice_ptr", "*u8" },
        .{ "m_if_opt_ptr", "*u8" },
        .{ "m_switch_union_ptr", "*u8" },
        .{ "m_switch_mutptr_union_ptr", "*u8" },
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
        // 容器级常量的值由解释器求出
        .{ "a", "Buf = .{ .len = 0 }" },
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

test "comptime integer arithmetic follows the result type" {
    try expectTypes(
        \\fn f() void {
        \\    const a: u8 = 255;
        \\    const wrapped = a +% 1;
        \\    const b: u8 = 0;
        \\    const below = b -% 1;
        \\    const c: u8 = 250;
        \\    const sat = c +| 10;
        \\    const d: u8 = 200;
        \\    const overflow = d + 100;
        \\    const e: i8 = -128;
        \\    const shifted = @as(u8, 0x81) << 1;
        \\    const inverted = ~@as(u8, 1);
        \\    _ = .{ wrapped, below, sat, overflow, e, shifted, inverted };
        \\}
    , &.{
        .{ "wrapped", "u8 = 0" },
        .{ "below", "u8 = 255" },
        .{ "sat", "u8 = 255" },
        // 越界是编译错误：不给出值
        .{ "overflow", "u8" },
        .{ "e", "i8 = -128" },
        .{ "shifted", "u8 = 2" },
        .{ "inverted", "u8 = 254" },
    });
}

test "arithmetic operands have no result type" {
    // 预期值与编译器一致（comptime 块中以 @compileError 核对过）
    try expectTypes(
        \\const m: u8 = (0xFF << 4) >> 4;
        \\const w: u8 = (200 +% 100) / 2;
        \\const r: f32 = 1 / 3;
        \\const n: i8 = (100 * 100) / 100;
        \\const big: u64 = @as(u32, 0xFFFFFFFF) * 2;
        \\fn g(x: u8) void {
        \\    const y: u32 = x + 1;
        \\    _ = y;
        \\}
    , &.{
        // 按结果类型 u8 计算时左移丢掉了高位，得 15
        .{ "m", "u8 = 255" },
        .{ "w", "u8 = 150" },
        .{ "r", "f32 = 0" },
        .{ "n", "i8 = 100" },
        // u32 的乘法溢出（编译错误）：没有值，不能按 u64 计算
        .{ "big", "u64" },
        .{ "x + 1", "u8" },
    });
}

test "float narrowing rounds to the target type" {
    try expectTypes(
        \\fn widen(x: f32) f64 {
        \\    return x;
        \\}
        \\fn pick() u8 {
        \\    const x: f32 = 0.1;
        \\    const y: f64 = x;
        \\    return if (y == 0.1) 1 else 2;
        \\}
        \\fn diff() f64 {
        \\    const x: f32 = 0.1;
        \\    const y: f64 = x;
        \\    return y - 0.1;
        \\}
        \\const a = @as(f64, @as(f32, 0.1));
        \\const b = widen(0.1);
        \\const c = pick();
        \\const d = diff();
        \\const e = @as(f64, @as(f16, 0.1));
        \\comptime {
        \\    _ = .{ a, b, c, d, e };
        \\}
    , &.{
        .{ "a", "f64 = 0.10000000149011612" },
        .{ "b", "f64 = 0.10000000149011612" },
        // f32 的 0.1 与字面量不等：走 else
        .{ "c", "u8 = 2" },
        .{ "d", "f64 = 0.0000000014901161138336505" },
        .{ "e", "f64 = 0.0999755859375" },
    });
}

test "slice ptr keeps the sentinel" {
    try expectTypes(
        \\fn probe(s: [:0]const u8, m: [:0]u8, cs: []const u8) void {
        \\    const v_sent_ptr = s.ptr;
        \\    const v_sent_mut_ptr = m.ptr;
        \\    const v_slice_ptr = cs.ptr;
        \\    _ = .{ v_sent_ptr, v_sent_mut_ptr, v_slice_ptr };
        \\}
        \\comptime {
        \\    _ = &probe;
        \\}
    , &.{
        .{ "v_sent_ptr", "[*:0]const u8" },
        .{ "v_sent_mut_ptr", "[*:0]u8" },
        .{ "v_slice_ptr", "[*]const u8" },
    });
}

test "switch on an error set narrows the capture" {
    try expectTypes(
        \\const E = error{ A, B, C };
        \\fn probe(e: E) void {
        \\    switch (e) {
        \\        error.A => |x| {
        \\            const v_one = x;
        \\            _ = v_one;
        \\        },
        \\        error.B => |x| {
        \\            const v_two = x;
        \\            _ = v_two;
        \\        },
        \\        else => |x| {
        \\            const v_else = x;
        \\            _ = v_else;
        \\        },
        \\    }
        \\}
        \\comptime {
        \\    _ = &probe;
        \\}
    , &.{
        .{ "v_one", "error{A}" },
        .{ "v_two", "error{B}" },
        // else 分支为其余的错误
        .{ "v_else", "error{C}" },
    });
}

test "false payloads are not null or failed" {
    try expectTypes(
        \\const opt: ?bool = false;
        \\const r = @as(anyerror!bool, false);
        \\const failed = @as(anyerror!bool, error.Bad);
        \\fn g() void {
        \\    const y = if (opt) |_| @as(u8, 1) else @as(u16, 2);
        \\    const z = if (r) |_| @as(u8, 3) else @as(u16, 4);
        \\    const q = if (failed) |_| @as(u8, 5) else @as(u16, 6);
        \\    _ = .{ y, z, q };
        \\}
    , &.{
        // `?bool` 的 false 载荷与成功的 `E!bool` 仍是非 null / 成功
        .{ "y", "u8 = 1" },
        .{ "z", "u8 = 3" },
        // 失败的错误联合仍取 else 分支
        .{ "q", "u16 = 6" },
    });
}

test "comptime name builtins produce string literal types" {
    try expectTypes(
        \\const U = union(enum) { a: u8, b: u16 };
        \\const En = enum { x, yy };
        \\fn probe(u: U) void {
        \\    const v_typename = @typeName(u8);
        \\    const v_tagname = @tagName(En.yy);
        \\    const v_errname = @errorName(error.Foo);
        \\    const v_tagname_rt = @tagName(u);
        \\    _ = .{ v_typename, v_tagname, v_errname, v_tagname_rt };
        \\}
        \\comptime {
        \\    _ = &probe;
        \\}
    , &.{
        // 编译期已知的名字是字符串字面量
        .{ "v_typename", "*const [2:0]u8 = \"u8\"" },
        .{ "v_tagname", "*const [2:0]u8 = \"yy\"" },
        .{ "v_errname", "*const [3:0]u8 = \"Foo\"" },
        // 运行时操作数仍是切片
        .{ "v_tagname_rt", "[:0]const u8" },
    });
}

test "comptime slices keep their sentinel" {
    try expectTypes(
        \\fn Explicit() type {
        \\    return @TypeOf("abc"[0..3 :0]);
        \\}
        \\fn ToEnd() type {
        \\    return @TypeOf("abc"[0..3]);
        \\}
        \\fn Prefix() type {
        \\    return @TypeOf("abc"[0..2]);
        \\}
        \\const T = Explicit();
        \\const U = @TypeOf("abc"[0..3 :0]);
        \\const V = ToEnd();
        \\const W = Prefix();
    , &.{
        // 解释器与推导路径得到同一个类型
        .{ "T", "type = *const [3:0]u8" },
        .{ "U", "type = *const [3:0]u8" },
        // 切到末尾时保留源数组的哨兵
        .{ "V", "type = *const [3:0]u8" },
        .{ "W", "type = *const [2]u8" },
    });
}

test "wide integer shift by more than 255 bits does not panic" {
    try expectTypes(
        \\const E = enum(u1000) { a = 5 };
        \\const v = @intFromEnum(E.a) >> 300;
    , &.{
        // 位宽超过 128 的值不折叠
        .{ "v", "u1000" },
    });
}

test "array concatenation length overflow does not panic" {
    try expectTypes(
        \\const a: [0xFFFFFFFFFFFFFFFF]u8 = undefined;
        \\const y = a ++ [_]u8{0};
    , &.{
        .{ "y", "unknown" },
    });
}

test "comptime array concatenation length overflow does not panic" {
    try expectTypes(
        \\fn cat(comptime a: [0xFFFFFFFFFFFFFFFF]u8) type {
        \\    _ = a ++ [_]u8{0};
        \\    return u8;
        \\}
        \\const T = cat(undefined);
    , &.{
        // 拼接本身不产生结果，函数返回值不受影响
        .{ "T", "type = u8" },
    });
}

test "comptime arguments are coerced to their instantiated parameter types" {
    try expectTypes(
        \\const E = enum { a, b };
        \\fn SelInt(comptime T: type, comptime n: T) type {
        \\    return switch (n) { 3 => u16, else => u32 };
        \\}
        \\fn SelEnum(comptime T: type, comptime e: T) type {
        \\    return switch (e) { .a => u16, else => u32 };
        \\}
        \\fn Box(comptime T: type, comptime n: T) type {
        \\    return struct { pub const v = n; };
        \\}
        \\fn Implicit(T: type) type { return struct { x: T }; }
        \\fn max(T: type, a: T, b: T) T { return if (a > b) a else b; }
        \\fn Array(n: usize) type { return [n]u8; }
        \\fn g() void {
        \\    const si = SelInt(u8, 3);
        \\    const se = SelEnum(E, .a);
        \\    const same = if (Box(u8, 3) == Box(u8, @as(u8, 3))) u8 else u16;
        \\    const imp = Implicit(u8);
        \\    const m = max(u32, 1, 2);
        \\    const arr = Array(3);
        \\    _ = .{ si, se, same, imp, m, arr };
        \\}
    , &.{
        .{ "si", "type = u16" },
        .{ "se", "type = u16" },
        .{ "same", "type = u8" },
        // 类型为 `type` 的参数不写 comptime 也是 comptime 参数
        .{ "imp", "type = Implicit(u8)" },
        .{ "m", "u32" },
        // 返回 type 的函数在 comptime 执行，所有实参都参与实例
        .{ "arr", "type = [3]u8" },
    });
}

test "comparisons that depend on unknown parts stay unknown" {
    try expectTypes(
        \\fn Id(comptime n: usize) type { return struct { pub const N = n; }; }
        \\fn g(comptime T: type, x: usize) void {
        \\    const arr_eq = if ([2]T == [2]u8) @as(u8, 1) else @as(u8, 2);
        \\    const eu_eq = if ((anyerror!T) == (anyerror!u8)) @as(u8, 1) else @as(u8, 2);
        \\    const unknown_args = if (Id(x) == Id(x + 1)) @as(u8, 1) else @as(u8, 2);
        \\    const same_param = if ([2]T == [2]T) @as(u8, 1) else @as(u8, 2);
        \\    _ = .{ arr_eq, eu_eq, unknown_args, same_param };
        \\}
    , &.{
        .{ "arr_eq", "u8" },
        .{ "eu_eq", "u8" },
        // 实参未知的两个实例可能是不同的类型
        .{ "unknown_args", "u8" },
        .{ "same_param", "u8 = 1" },
    });
}

test "comptime float values" {
    try expectTypes(
        \\const pi = 3.14159;
        \\const half: f32 = 0.5;
        \\const conv = @as(u8, @intFromFloat(pi));
        \\fn Scale(comptime x: f32) type { return if (x > 1.0) u16 else u8; }
        \\fn g() void {
        \\    const area = pi * 2.0 * 2.0;
        \\    const neg = -half;
        \\    const S = Scale(2.5);
        \\    _ = .{ area, neg, S };
        \\}
    , &.{
        .{ "area", "comptime_float = 12.56636" },
        .{ "neg", "f32 = -0.5" },
        .{ "S", "type = u16" },
        .{ "conv", "u8 = 3" },
    });
}

test "instances of the same container compare by their captured values" {
    // 与编译器一致：容器的身份 = 定义位置 + 捕获的值
    try expectTypes(
        \\fn NoCapture(comptime T: type) type {
        \\    _ = T;
        \\    return struct { x: u8 };
        \\}
        \\fn Capture(comptime T: type) type { return struct { x: T }; }
        \\fn Id(comptime n: usize) type { return struct { pub const N = n; }; }
        \\fn g() void {
        \\    const nc = if (NoCapture(u8) == NoCapture(u16)) @as(u8, 1) else @as(u8, 2);
        \\    const cap = if (Capture(u8) == Capture(u16)) @as(u8, 1) else @as(u8, 2);
        \\    const id = if (Id(@sizeOf(u8)) == Id(@sizeOf(u64))) @as(u8, 1) else @as(u8, 2);
        \\    const same = if (Capture(u8) == Capture(u8)) @as(u8, 1) else @as(u8, 2);
        \\    _ = .{ nc, cap, id, same };
        \\}
    , &.{
        .{ "nc", "u8 = 1" },
        .{ "cap", "u8 = 2" },
        .{ "id", "u8 = 2" },
        .{ "same", "u8 = 1" },
    });
}

test "inferred error sets from function bodies" {
    try expectTypes(
        \\fn wrap(x: anytype) !@TypeOf(x) { return x; }
        \\const E = error{Bad};
        \\fn a() !u8 { return error.Oops; }
        \\fn b(x: bool) !u8 {
        \\    if (x) return E.Bad;
        \\    return try a();
        \\}
        \\fn c() !void {}
        \\fn rec(n: u32) !u32 {
        \\    if (n == 0) return error.Done;
        \\    if (n > 1000) return error.TooBig;
        \\    return rec(n - 1);
        \\}
        \\fn rec2(n: u32) !u32 {
        \\    if (n == 0) return error.Done;
        \\    const x = try rec2(n - 1);
        \\    return x + 1;
        \\}
        \\fn user() !void {
        \\    _ = try rec(1);
        \\    return error.Own;
        \\}
        \\fn ping(n: u32) !void {
        \\    if (n == 0) return error.Ping;
        \\    return pong(n - 1);
        \\}
        \\fn pong(n: u32) !void {
        \\    if (n == 0) return error.Pong;
        \\    return ping(n - 1);
        \\}
        \\fn inactive(x: bool) !u8 {
        \\    if (false) return error.Fake;
        \\    if (x) return error.Real;
        \\    if (true) return 1;
        \\    return error.Unreachable;
        \\}
        \\fn g() void {
        \\    const w = wrap(@as(u8, 1));
        \\    const ra = a();
        \\    const rb = b(true);
        \\    const rc = c();
        \\    const rr = rec(3);
        \\    const rr2 = rec2(3);
        \\    const ru = user();
        \\    const rp = ping(3);
        \\    const rq = pong(3);
        \\    const ri = inactive(false);
        \\    _ = .{ w, ra, rb, rc, rr, rr2, ru, rp, rq, ri };
        \\}
    , &.{
        .{ "w", "error{}!u8" },
        .{ "ra", "error{Oops}!u8" },
        // return 的错误与 try 传播的错误
        .{ "rb", "error{Bad,Oops}!u8" },
        .{ "rc", "error{}!void" },
        // 递归的函数取最小不动点（与编译器一致）
        .{ "rr", "error{Done,TooBig}!u32" },
        .{ "rr2", "error{Done}!u32" },
        .{ "ru", "error{Done,Own,TooBig}!void" },
        // 相互递归（编译器报错）：取两者的并集
        .{ "rp", "error{Ping,Pong}!void" },
        .{ "rq", "error{Ping,Pong}!void" },
        // comptime 不活跃的分支与 noreturn 之后的代码不并入
        .{ "ri", "error{Real}!u8" },
    });
}

test "comptime slices alias the sliced storage" {
    try expectTypes(
        \\fn f() u8 {
        \\    var a = [_]u8{ 1, 2 };
        \\    const s = a[0..];
        \\    s[0] = 9;
        \\    return a[0];
        \\}
        \\fn g() u8 {
        \\    var a = [_]u8{ 1, 2, 3, 4 };
        \\    const p = &a;
        \\    const s = p[1..];
        \\    const t = s[1..3];
        \\    t[1] = 7;
        \\    for (s) |*x| x.* += 1;
        \\    return a[3] + a[1];
        \\}
        \\fn h() u8 {
        \\    var a = [_]u8{ 1, 2 };
        \\    const s = a[0..];
        \\    a[1] = 5;
        \\    return s[1];
        \\}
        \\const result = f();
        \\const nested = g();
        \\const reads = h();
    , &.{
        .{ "result", "u8 = 9" },
        .{ "nested", "u8 = 11" },
        .{ "reads", "u8 = 5" },
    });
}

test "escaped identifiers name the same declaration as plain ones" {
    try expectTypes(
        \\const @"\x66oo": u8 = 7;
        \\const S = struct { @"a\"b": u16 };
        \\const result = foo;
        \\fn f(s: S) void {
        \\    const field = s.@"a\x22b";
        \\    _ = field;
        \\}
    , &.{
        .{ "result", "u8 = 7" },
        .{ "field", "u16" },
    });
}

test "oversized layouts degrade to unknown instead of overflowing" {
    // 大小无法用 u64 表示的类型：布局求不出，不能使宿主溢出崩溃
    try expectTypes(
        \\const S = extern struct {
        \\    a: [2305843009213693952]u8,
        \\    b: u8,
        \\};
        \\const T = struct { u8, [18446744073709551615]u8 };
        \\const U = union(enum) { a: [18446744073709551615]u8, b: u8 };
        \\const s_size = @sizeOf(S);
        \\const sentinel_size = @sizeOf([18446744073709551615:0]u8);
        \\const opt_size = @sizeOf(?[18446744073709551615]u8);
        \\const eu_size = @sizeOf(anyerror![18446744073709551615]u8);
        \\const t_size = @sizeOf(T);
        \\const u_size = @sizeOf(U);
    , &.{
        .{ "s_size", "comptime_int" },
        .{ "sentinel_size", "comptime_int" },
        .{ "opt_size", "comptime_int" },
        .{ "eu_size", "comptime_int" },
        .{ "t_size", "comptime_int" },
        .{ "u_size", "comptime_int" },
    });
}

test "container layouts match the compiler" {
    // 期望值为 zig 0.17.0 在 x86_64-linux 上的结果
    try expectTypesTargeted(try targetOf("x86_64-linux-musl", null),
        \\const A = struct { a: u8, b: u32, c: u16 };
        \\const B = extern struct { a: u8, b: u32, c: u16 };
        \\const C = packed struct { a: u3, b: u5, c: u16 };
        \\const D = struct { a: u8, b: u64, c: u8, d: u32, e: u16 };
        \\const M = struct { a: [0]u32, b: u8, c: ?*u8, d: ?[]u8, e: anyerror!u8, f: ?anyerror };
        \\const Big = struct { a: u8, b: u128, c: f80, d: u16 };
        \\const H = enum(u16) { a, b };
        \\const Auto = enum { a, b, c };
        \\const U = union(enum) { a: u64, b: u8 };
        \\const UE = union(H) { a: u32, b: u8 };
        \\const X = extern union { a: u32, b: [6]u8 };
        \\const P = packed union { a: u16, b: i16 };
        \\const One = union(enum) { a: u32 };
        \\const Nest = struct { a: M, b: U, c: Auto };
        \\const K = struct { comptime k: u8 = 1, a: u8, b: u16 };
        \\fn Pair(comptime T: type) type {
        \\    return struct { a: u8, b: T };
        \\}
        \\const L = struct { a: u8 align(4), b: u8 };
        \\const XL = extern struct { a: u8, b: u32 align(1) };
        \\fn Al(comptime n: u29) type {
        \\    return struct { a: u8 align(n), b: u8 };
        \\}
        \\const UA = union(enum) { a: u8 align(8), b: u16 };
        \\const top = @sizeOf(D);
        \\fn g() void {
        \\    const size_a = @sizeOf(A);
        \\    const align_a = @alignOf(A);
        \\    const a_a = @offsetOf(A, "a");
        \\    const a_b = @offsetOf(A, "b");
        \\    const a_c = @offsetOf(A, "c");
        \\    const size_b = @sizeOf(B);
        \\    const b_c = @offsetOf(B, "c");
        \\    const size_c = @sizeOf(C);
        \\    const bits_c = @bitSizeOf(C);
        \\    const c_b = @bitOffsetOf(C, "b");
        \\    const c_c = @offsetOf(C, "c");
        \\    const d_a = @offsetOf(D, "a");
        \\    const d_c = @offsetOf(D, "c");
        \\    const d_e = @offsetOf(D, "e");
        \\    const size_m = @sizeOf(M);
        \\    const m_a = @offsetOf(M, "a");
        \\    const m_b = @offsetOf(M, "b");
        \\    const m_f = @offsetOf(M, "f");
        \\    const big_a = @offsetOf(Big, "a");
        \\    const size_big = @sizeOf(Big);
        \\    const bits_h = @bitSizeOf(H);
        \\    const bits_auto = @bitSizeOf(Auto);
        \\    const size_u = @sizeOf(U);
        \\    const size_ue = @sizeOf(UE);
        \\    const size_x = @sizeOf(X);
        \\    const bits_p = @bitSizeOf(P);
        \\    const size_one = @sizeOf(One);
        \\    const size_opt_u = @sizeOf(?U);
        \\    const nest_c = @offsetOf(Nest, "c");
        \\    const size_nest = @sizeOf(Nest);
        \\    const size_k = @sizeOf(K);
        \\    const k_a = @offsetOf(K, "a");
        \\    const pair_a = @offsetOf(Pair(u32), "a");
        \\    const size_l = @sizeOf(L);
        \\    const align_l = @alignOf(L);
        \\    const l_b = @offsetOf(L, "b");
        \\    const size_xl = @sizeOf(XL);
        \\    const align_xl = @alignOf(XL);
        \\    const size_al = @sizeOf(Al(8));
        \\    const size_ua = @sizeOf(UA);
        \\    _ = .{ size_a, align_a, a_a, a_b, a_c, size_b, b_c, size_c, bits_c, c_b, c_c, d_a, d_c, d_e, size_m, m_a, m_b, m_f, big_a, size_big, bits_h, bits_auto, size_u, size_ue, size_x, bits_p, size_one, size_opt_u, nest_c, size_nest, size_k, k_a, pair_a, size_l, align_l, l_b, size_xl, align_xl, size_al, size_ua };
        \\}
    , &.{
        .{ "size_a", "comptime_int = 8" },
        .{ "align_a", "comptime_int = 4" },
        // auto 布局按对齐降序重排字段
        .{ "a_a", "comptime_int = 6" },
        .{ "a_b", "comptime_int = 0" },
        .{ "a_c", "comptime_int = 4" },
        // extern 按声明顺序
        .{ "size_b", "comptime_int = 12" },
        .{ "b_c", "comptime_int = 8" },
        .{ "size_c", "comptime_int = 4" },
        .{ "bits_c", "comptime_int = 24" },
        .{ "c_b", "comptime_int = 3" },
        .{ "c_c", "comptime_int = 1" },
        // 对齐相同的字段保持声明顺序
        .{ "d_a", "comptime_int = 14" },
        .{ "d_c", "comptime_int = 15" },
        .{ "d_e", "comptime_int = 12" },
        .{ "top", "comptime_int = 16" },
        .{ "size_m", "comptime_int = 32" },
        .{ "m_a", "comptime_int = 24" },
        .{ "m_b", "comptime_int = 30" },
        .{ "m_f", "comptime_int = 28" },
        .{ "big_a", "comptime_int = 34" },
        .{ "size_big", "comptime_int = 48" },
        .{ "bits_h", "comptime_int = 16" },
        .{ "bits_auto", "comptime_int = 2" },
        .{ "size_u", "comptime_int = 16" },
        .{ "size_ue", "comptime_int = 8" },
        .{ "size_x", "comptime_int = 8" },
        .{ "bits_p", "comptime_int = 16" },
        // 只有一个字段的 union(enum) 没有运行时的标签
        .{ "size_one", "comptime_int = 4" },
        .{ "size_opt_u", "comptime_int = 24" },
        .{ "nest_c", "comptime_int = 48" },
        .{ "size_nest", "comptime_int = 56" },
        // comptime 字段不占空间
        .{ "size_k", "comptime_int = 4" },
        .{ "k_a", "comptime_int = 2" },
        .{ "pair_a", "comptime_int = 4" },
        // 显式对齐：可以大于或小于类型的对齐，参与重排；泛型实例中按实参求值
        .{ "size_l", "comptime_int = 4" },
        .{ "align_l", "comptime_int = 4" },
        .{ "l_b", "comptime_int = 1" },
        .{ "size_xl", "comptime_int = 5" },
        .{ "align_xl", "comptime_int = 1" },
        .{ "size_al", "comptime_int = 8" },
        .{ "size_ua", "comptime_int = 8" },
    });
}

test "layouts that are invalid or depend on the build mode stay unknown" {
    try expectTypes(
        \\const Bare = union { a: u32, b: u8 };
        \\const S = struct { a: u8 };
        \\const Auto = enum { a, b, c };
        \\const Pa = packed struct { a: u4, b: Auto };
        \\fn g() void {
        \\    const size_bare = @sizeOf(Bare);
        \\    const bits_s = @bitSizeOf(S);
        \\    const bits_slice = @bitSizeOf([]u8);
        \\    const bits_opt = @bitSizeOf(?u32);
        \\    const bits_ptr = @bitSizeOf(?*u32);
        \\    const bits_arr = @bitSizeOf([3]u5);
        \\    const bits_sent = @bitSizeOf([2:0]u8);
        \\    const bits_autos = @bitSizeOf([2]Auto);
        \\    const size_pa = @sizeOf(Pa);
        \\    _ = .{ size_bare, bits_s, bits_slice, bits_opt, bits_ptr, bits_arr, bits_sent, bits_autos, size_pa };
        \\}
    , &.{
        // 不带标签的 union：没有 builtin（不知道优化模式）
        .{ "size_bare", "comptime_int" },
        // 没有位表示的类型（编译器报错）
        .{ "bits_s", "comptime_int" },
        .{ "bits_slice", "comptime_int" },
        .{ "bits_opt", "comptime_int" },
        .{ "bits_ptr", "comptime_int = 64" },
        // 数组的位宽含哨兵
        .{ "bits_arr", "comptime_int = 15" },
        .{ "bits_sent", "comptime_int = 24" },
        .{ "bits_autos", "comptime_int" },
        // packed 结构体不能包含未指定标签类型的枚举
        .{ "size_pa", "comptime_int" },
    });
}

test "float math builtins use the precision of the operand type" {
    // 期望值为 zig 0.17.0 的结果
    try expectTypes(
        \\fn g() void {
        \\    const r32 = @sqrt(@as(f32, 2));
        \\    const r64 = @sqrt(@as(f64, 2));
        \\    const r16 = @sqrt(@as(f16, 2));
        \\    const rc = @sqrt(2.0);
        \\    const sn = @sin(@as(f64, 1));
        \\    const lg = @log2(@as(f64, 8));
        \\    const fl = @floor(@as(f32, -1.5));
        \\    const rd = @round(@as(f64, 2.5));
        \\    const ab = @abs(@as(f32, -3.5));
        \\    const md = @mod(@as(f64, -7), 3);
        \\    const rm = @rem(@as(f64, -7), 3);
        \\    const ma = @mulAdd(f64, 2, 3, 4);
        \\    const mn = @min(@as(f32, 1.5), 2.5);
        \\    const dc = @divCeil(@as(f64, 7.5), 2);
        \\    const df = @divFloor(@as(f64, -7.5), 2);
        \\    const ai = @abs(@as(i8, -128));
        \\    const ic = @divCeil(@as(i32, -7), 2);
        \\    const mi = @mod(@as(i32, 7), -3);
        \\    const rn = @rem(@as(f64, -7), -3);
        \\    const mf = @mod(@as(f64, 7), -3);
        \\    const mg = @mod(@as(f32, -7.5), -2);
        \\    _ = .{ r32, r64, r16, rc, sn, lg, fl, rd, ab, md, rm, ma, mn, dc, df, ai, ic, mi, rn, mf, mg };
        \\}
    , &.{
        .{ "r32", "f32 = 1.4142135" },
        .{ "r64", "f64 = 1.4142135623730951" },
        .{ "r16", "f16 = 1.414" },
        .{ "rc", "comptime_float = 1.414213562373095048801688724209698" },
        .{ "sn", "f64 = 0.8414709848078965" },
        .{ "lg", "f64 = 3" },
        .{ "fl", "f32 = -2" },
        .{ "rd", "f64 = 3" },
        .{ "ab", "f32 = 3.5" },
        .{ "md", "f64 = 2" },
        .{ "rm", "f64 = -1" },
        .{ "ma", "f64 = 10" },
        .{ "mn", "f32 = 1.5" },
        .{ "dc", "f64 = 4" },
        .{ "df", "f64 = -4" },
        // 有符号整数的绝对值为无符号整数
        .{ "ai", "u8 = 128" },
        .{ "ic", "i32 = -3" },
        // 负除数：整数按向下取整的语义；浮点的 `@mod` 与编译器一致，只按被除数的符号调整
        .{ "mi", "i32 = -2" },
        .{ "rn", "f64 = -1" },
        .{ "mf", "f64 = 1" },
        .{ "mg", "f32 = -1.5" },
    });
}

test "@min and @max narrow the result type like the compiler" {
    // 期望值为 zig 0.17.0 的结果
    try expectTypes(
        \\fn h(x: u8, y: u16, z: i8) void {
        \\    const lo = @min(x, y);
        \\    const hi = @max(x, y);
        \\    const lim = @min(x, 10);
        \\    const mixed = @max(z, x);
        \\    const neg = @min(z, -3);
        \\    const k_lo = @min(@as(u8, 3), @as(u16, 5));
        \\    const k_hi = @max(@as(u8, 3), @as(u16, 5));
        \\    const k_neg = @min(@as(i8, -3), 4);
        \\    const k_ct = @min(3, 5);
        \\    const k_f = @max(@as(f32, 1), @as(f64, 2));
        \\    _ = .{ lo, hi, lim, mixed, neg, k_lo, k_hi, k_neg, k_ct, k_f };
        \\}
    , &.{
        // 结果类型为容纳结果范围的最小整数类型：参数的值已知时取值，否则取类型的范围
        .{ "lo", "u8" },
        .{ "hi", "u16" },
        .{ "lim", "u4" },
        .{ "mixed", "u8" },
        .{ "neg", "i8" },
        .{ "k_lo", "u2 = 3" },
        .{ "k_hi", "u3 = 5" },
        .{ "k_neg", "i3 = -3" },
        .{ "k_ct", "comptime_int = 3" },
        .{ "k_f", "f64 = 2" },
    });
}

test "peer types of different integer and float types" {
    // 期望值为 zig 0.17.0 的结果
    try expectTypes(
        \\fn h(a: usize, b: u64, c: u32, d: i64, x: f32, y: f64, u: u8, w: u16, g: bool) void {
        \\    const s1 = a + b;
        \\    const s2 = b + a;
        \\    const s3 = a + c;
        \\    const s4 = c + d;
        \\    const s5 = x + y;
        \\    const b1 = if (g) u else w;
        \\    const b2 = if (g) x else y;
        \\    const b3 = if (g) d else c;
        \\    const skip = @max(a / c, @as(usize, 1));
        \\    const next = a + skip;
        \\    _ = .{ s1, s2, s3, s4, s5, b1, b2, b3, skip, next };
        \\}
    , &.{
        // 位宽相同时取前者
        .{ "s1", "usize" },
        .{ "s2", "u64" },
        .{ "s3", "usize" },
        .{ "s4", "i64" },
        .{ "s5", "f64" },
        .{ "b1", "u16" },
        .{ "b2", "f64" },
        .{ "b3", "i64" },
        .{ "skip", "u64" },
        .{ "next", "usize" },
    });
}

test "vector layouts follow the backend and CPU features" {
    // 期望值为 zig 0.17.0 的结果：x86_64-linux 的 Debug 默认使用自研后端，`-fllvm` 为 LLVM
    const src =
        \\fn g() void {
        \\    const v2u8 = @sizeOf(@Vector(2, u8));
        \\    const v3u5 = @sizeOf(@Vector(3, u5));
        \\    const v16f32 = @alignOf(@Vector(16, f32));
        \\    const v8u32 = @alignOf(@Vector(8, u32));
        \\    const v100bool = @sizeOf(@Vector(100, bool));
        \\    const v3ptr = @sizeOf(@Vector(3, *u8));
        \\    const bits = @bitSizeOf(@Vector(3, u5));
        \\    _ = .{ v2u8, v3u5, v16f32, v8u32, v100bool, v3ptr, bits };
        \\}
    ;
    // 自研 x86_64 后端：对齐至少为 16，AVX 下超过 16 字节为 32，AVX-512 下超过 32 字节为 64
    try expectTypesTargeted(.{ .vector_abi = .x86_64_avx }, src, &.{
        .{ "v2u8", "comptime_int = 16" },
        .{ "v3u5", "comptime_int = 16" },
        .{ "v16f32", "comptime_int = 32" },
        .{ "v8u32", "comptime_int = 32" },
        .{ "v100bool", "comptime_int = 16" },
        .{ "v3ptr", "comptime_int = 32" },
        .{ "bits", "comptime_int = 15" },
    });
    try expectTypesTargeted(.{ .vector_abi = .x86_64 }, src, &.{
        .{ "v16f32", "comptime_int = 16" },
        .{ "v8u32", "comptime_int = 16" },
    });
    try expectTypesTargeted(.{ .vector_abi = .x86_64_avx512 }, src, &.{
        .{ "v16f32", "comptime_int = 64" },
        .{ "v8u32", "comptime_int = 32" },
    });
    // LLVM：对齐为不小于字节数的 2 的幂；aarch64 不超过 16
    try expectTypesTargeted(.{ .vector_abi = .llvm }, src, &.{
        .{ "v2u8", "comptime_int = 2" },
        .{ "v3u5", "comptime_int = 2" },
        .{ "v16f32", "comptime_int = 64" },
        .{ "v100bool", "comptime_int = 16" },
        .{ "v3ptr", "comptime_int = 32" },
    });
    try expectTypesTargeted(.{ .vector_abi = .llvm_aarch64 }, src, &.{
        .{ "v16f32", "comptime_int = 16" },
        .{ "v8u32", "comptime_int = 16" },
        .{ "v3ptr", "comptime_int = 32" },
    });
    // 后端未知（各模块不一致等）
    try expectTypesTargeted(.{ .vector_abi = .unknown }, src, &.{
        .{ "v2u8", "comptime_int" },
        .{ "bits", "comptime_int" },
    });
}

/// 目标 `arch_os_abi` 与 CPU（同编译器的 `-target` / `-mcpu`）的目标参数：指针位宽与标量类型的布局规则
fn targetOf(arch_os_abi: []const u8, cpu: ?[]const u8) !InternPool.Target {
    const query = try std.Target.Query.parse(.{ .arch_os_abi = arch_os_abi, .cpu_features = cpu });
    const t = try std.zig.system.resolveTargetQuery(testing.io, query);
    return .{ .pointer_bits = t.ptrBitWidth(), .scalar_abi = .of(&t) };
}

/// 布局随目标变化的类型：`s_T` / `a_T` 为 `@sizeOf(T)` / `@alignOf(T)`
const target_layout_src =
    \\const S = struct { a: u8, b: u64, c: u16, d: f80 };
    \\fn g(c: bool) void {
    \\    const s_u8 = @sizeOf(u8);
    \\    const s_u32 = @sizeOf(u32);
    \\    const a_u32 = @alignOf(u32);
    \\    const s_u24 = @sizeOf(u24);
    \\    const a_u24 = @alignOf(u24);
    \\    const s_u64 = @sizeOf(u64);
    \\    const a_u64 = @alignOf(u64);
    \\    const s_u128 = @sizeOf(u128);
    \\    const a_u128 = @alignOf(u128);
    \\    const s_f80 = @sizeOf(f80);
    \\    const a_f80 = @alignOf(f80);
    \\    const s_f128 = @sizeOf(f128);
    \\    const a_f128 = @alignOf(f128);
    \\    const s_c_int = @sizeOf(c_int);
    \\    const a_c_int = @alignOf(c_int);
    \\    const s_c_longdouble = @sizeOf(c_longdouble);
    \\    const a_c_longdouble = @alignOf(c_longdouble);
    \\    const s_S = @sizeOf(S);
    \\    const a_S = @alignOf(S);
    \\    const max_c_uint = @as(c_uint, 0) -% 1;
    \\    const peer = if (c) @as(f32, 1) else @as(f64, 2);
    \\    _ = .{ s_u8, s_u32, a_u32, s_u24, a_u24, s_u64, a_u64, s_u128, a_u128, s_f80, a_f80, s_f128, a_f128, s_c_int, a_c_int, s_c_longdouble, a_c_longdouble, s_S, a_S, max_c_uint, peer };
    \\}
;

const target_layout_types = [_][]const u8{ "u24", "u64", "u128", "f80", "f128", "c_int", "c_longdouble", "S" };

/// `target_layout_src` 在目标上的结果：`expected[i]` 为 `target_layout_types[i]` 的大小与对齐（null 为未知）
fn expectTargetLayouts(target: InternPool.Target, expected: [target_layout_types.len]?[2]u64, max_c_uint: u64) !void {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.setTarget(target);
    const src = target_layout_src;
    const f = try w.add("/p/main.zig", src);
    const a = w.arena.allocator();
    for (target_layout_types, expected) |name, e| {
        for ([_][]const u8{ "s_", "a_" }, 0..) |prefix, i| {
            const binding = try std.mem.concat(a, u8, &.{ prefix, name });
            const want = if (e) |v| try std.fmt.allocPrint(a, "comptime_int = {d}", .{v[i]}) else "comptime_int";
            testing.expectEqualStrings(want, try typeAt(&w, f.file, src, binding, 0)) catch |err| {
                std.debug.print("type of `{s}`\n", .{binding});
                return err;
            };
        }
    }
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "c_uint = {d}", .{max_c_uint}), try typeAt(&w, f.file, src, "max_c_uint", 0));
}

test "integer, float and C type layouts follow the target" {
    // 期望值为 zig 0.17.0 的结果（`zig build-obj -target <目标>` 中以 @compileError 输出）。类型顺序：
    // u24, u64, u128, f80, f128, c_int, c_longdouble, S
    try expectTargetLayouts(try targetOf("x86_64-linux-musl", null), .{ .{ 4, 4 }, .{ 8, 8 }, .{ 16, 16 }, .{ 16, 16 }, .{ 16, 16 }, .{ 4, 4 }, .{ 16, 16 }, .{ 32, 16 } }, 4294967295);
    // 整数的最大对齐为 4；long double 为 80 位、按 4 字节对齐
    try expectTargetLayouts(try targetOf("x86-linux-musl", null), .{ .{ 4, 4 }, .{ 8, 4 }, .{ 16, 4 }, .{ 12, 4 }, .{ 16, 16 }, .{ 4, 4 }, .{ 12, 4 }, .{ 24, 4 } }, 4294967295);
    // 布局也取决于操作系统：Windows 上整数的最大对齐为 8
    try expectTargetLayouts(try targetOf("x86-windows-gnu", null), .{ .{ 4, 4 }, .{ 8, 8 }, .{ 16, 8 }, .{ 12, 4 }, .{ 16, 16 }, .{ 4, 4 }, .{ 12, 4 }, .{ 24, 8 } }, 4294967295);
    // long double 为 128 位：f80 按软浮点（u64 与 u16）布局
    try expectTargetLayouts(try targetOf("aarch64-linux-musl", null), .{ .{ 4, 4 }, .{ 8, 8 }, .{ 16, 16 }, .{ 16, 8 }, .{ 16, 16 }, .{ 4, 4 }, .{ 16, 16 }, .{ 32, 8 } }, 4294967295);
    try expectTargetLayouts(try targetOf("arm-linux-musleabihf", null), .{ .{ 4, 4 }, .{ 8, 8 }, .{ 16, 8 }, .{ 16, 8 }, .{ 16, 8 }, .{ 4, 4 }, .{ 8, 8 }, .{ 32, 8 } }, 4294967295);
    try expectTargetLayouts(try targetOf("riscv32-freestanding-none", null), .{ .{ 4, 4 }, .{ 8, 8 }, .{ 16, 8 }, .{ 16, 8 }, .{ 16, 16 }, .{ 4, 4 }, .{ 16, 16 }, .{ 32, 8 } }, 4294967295);
    // AVR：整数与浮点按 1 字节对齐，c_int 为 16 位；std 没有定义 32 位 long double 的大小，为未知
    try expectTargetLayouts(try targetOf("avr-freestanding-none", "atmega328p"), .{ .{ 3, 1 }, .{ 8, 1 }, .{ 16, 1 }, .{ 10, 1 }, .{ 16, 1 }, .{ 2, 1 }, null, .{ 21, 1 } }, 65535);
    try expectTargetLayouts(try targetOf("msp430-freestanding-none", null), .{ .{ 4, 2 }, .{ 8, 2 }, .{ 16, 2 }, .{ 10, 2 }, .{ 16, 2 }, .{ 2, 2 }, .{ 8, 2 }, .{ 22, 2 } }, 65535);
}

test "type layouts with several targets keep only what the targets agree on" {
    const x86_64 = try targetOf("x86_64-linux-musl", null);
    const x86 = try targetOf("x86-linux-musl", null);
    const src = target_layout_src;
    // 整数的最大对齐为 16 与 4：不超过 4 字节的整数仍有确定的布局；f128 在两者上相同
    try expectTypesTargeted(.{ .pointer_bits = null, .scalar_abi = x86_64.scalar_abi.merge(x86.scalar_abi) }, src, &.{
        .{ "s_u32", "comptime_int = 4" },
        .{ "a_u32", "comptime_int = 4" },
        .{ "s_u24", "comptime_int = 4" },
        .{ "a_u64", "comptime_int" },
        .{ "s_S", "comptime_int" },
        .{ "a_f80", "comptime_int" },
        .{ "a_f128", "comptime_int = 16" },
        .{ "s_c_int", "comptime_int = 4" },
        .{ "max_c_uint", "c_uint = 4294967295" },
    });
    // 目标未知：只有不超过 1 字节的整数有确定的布局；浮点的位宽与目标无关
    try expectTypesTargeted(.{ .pointer_bits = null, .scalar_abi = .unknown }, src, &.{
        .{ "s_u8", "comptime_int = 1" },
        .{ "s_u32", "comptime_int" },
        .{ "s_f80", "comptime_int" },
        .{ "s_c_int", "comptime_int" },
        .{ "max_c_uint", "c_uint" },
        .{ "peer", "f64" },
    });
}

test "integer layouts match std.zig.target for every width" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    for ([_][]const u8{ "x86_64-linux-musl", "x86-linux-musl", "x86-windows-gnu", "arm-linux-musleabihf", "avr-freestanding-none", "msp430-freestanding-none", "xtensa-freestanding-none" }) |triple| {
        const t = try std.zig.system.resolveTargetQuery(testing.io, try .parse(.{ .arch_os_abi = triple }));
        try w.setTarget(.{ .scalar_abi = .of(&t) });
        for (1..129) |i| {
            const bits: u16 = @intCast(i);
            const l = value.intLayout(&w.ip, bits).?;
            try testing.expectEqual(std.zig.target.intAlignment(&t, bits), l.alignment);
            try testing.expectEqual(std.zig.target.intByteSize(&t, bits), l.size);
        }
    }
}

test "tuple and anonymous struct literals have comptime fields like the compiler" {
    // 期望值为 zig 0.17.0 的结果
    try expectTypes(
        \\fn foo() u32 {
        \\    return 7;
        \\}
        \\inline fn inl() u32 {
        \\    return 1;
        \\}
        \\fn g(p: u32, items: []const u8) void {
        \\    var x: u32 = 2;
        \\    var y: u8 = 1;
        \\    var z: u64 = 3;
        \\    _ = .{ &x, &y, &z };
        \\    const k = 5;
        \\    const t1 = .{ @as(u8, 1), x };
        \\    const t2 = .{ y, x, z };
        \\    const t3 = .{ y, {}, x };
        \\    const t4 = .{ k, "hi", x };
        \\    const t5 = .{p};
        \\    const tc = .{foo()};
        \\    const tu = .{inl()};
        \\    const a1 = .{ .a = @as(u8, 1), .b = x };
        \\    const a2 = .{ .a = y, .b = z, .c = x };
        \\    const first = t1[0];
        \\    for (items) |it| {
        \\        const tl = .{it};
        \\        _ = tl;
        \\    }
        \\    const s1 = @sizeOf(@TypeOf(t1));
        \\    const s2 = @sizeOf(@TypeOf(t2));
        \\    const o2 = @offsetOf(@TypeOf(t2), "1");
        \\    const s3 = @sizeOf(@TypeOf(t3));
        \\    const s4 = @sizeOf(@TypeOf(t4));
        \\    const su = @sizeOf(@TypeOf(tu));
        \\    const sa1 = @sizeOf(@TypeOf(a1));
        \\    const sa2 = @sizeOf(@TypeOf(a2));
        \\    const oa2 = @offsetOf(@TypeOf(a2), "a");
        \\    const empty = .{};
        \\    const s0 = @sizeOf(@TypeOf(.{ @as(u8, 1), @as(u32, 2) }));
        \\    _ = .{ t1, t2, t3, t4, t5, tc, tu, a1, a2, first, s1, s2, o2, s3, s4, su, sa1, sa2, oa2, empty, s0 };
        \\}
    , &.{
        // comptime 已知的值（含 `{}`、字符串）是 comptime 字段；var、参数、函数调用与循环的捕获是运行时的
        .{ "t1", "struct { comptime u8 = 1, u32 }" },
        .{ "t2", "struct { u8, u32, u64 }" },
        .{ "t3", "struct { u8, comptime void = {}, u32 }" },
        .{ "t4", "struct { comptime comptime_int = 5, comptime *const [2:0]u8 = \"hi\", u32 }" },
        .{ "t5", "struct { u32 }" },
        .{ "tc", "struct { u32 }" },
        .{ "tl", "struct { u8 }" },
        .{ "a1", "struct { comptime a: u8 = 1, b: u32 }" },
        // comptime 字段的值属于类型
        .{ "first", "u8 = 1" },
        // 元组按声明顺序排列，comptime 字段不占空间；匿名结构体与 auto 结构体相同，按对齐重排
        .{ "s1", "comptime_int = 4" },
        .{ "s2", "comptime_int = 16" },
        .{ "o2", "comptime_int = 4" },
        .{ "s3", "comptime_int = 8" },
        .{ "s4", "comptime_int = 4" },
        .{ "sa1", "comptime_int = 4" },
        .{ "sa2", "comptime_int = 16" },
        .{ "oa2", "comptime_int = 12" },
        // inline 函数的结果是否 comptime 已知取决于函数体：字段是否占空间未知
        .{ "su", "comptime_int" },
        .{ "empty", "@TypeOf(.{}) = .{}" },
        // 字段都是 comptime 字段
        .{ "s0", "comptime_int = 0" },
    });
}

test "union fields without a type are void, enum member names are not expressions" {
    try expectTypes(
        \\fn read() void {}
        \\const E = enum(u8) { read = 1, write };
        \\const U = union(enum) { a: u32, b };
        \\const w = @intFromEnum(E.write);
        \\fn g() void {
        \\    const ft = @FieldType(U, "b");
        \\    const size_u = @sizeOf(U);
        \\    _ = .{ ft, size_u };
        \\}
    , &.{
        .{ "ft", "type = void" },
        .{ "size_u", "comptime_int = 8" },
        .{ "w", "u8 = 2" },
    });
}

test "labeled blocks, array literals and type queries" {
    try expectTypes(
        \\fn Pick(comptime wide: bool) type {
        \\    const T = blk: {
        \\        if (wide) break :blk u64;
        \\        break :blk u8;
        \\    };
        \\    return T;
        \\}
        \\const Top = blk: {
        \\    break :blk u32;
        \\};
        \\const S = struct { a: u8, pub const k = 1; const hidden = 2; };
        \\fn g() void {
        \\    const P = Pick(true);
        \\    const Q = Top;
        \\    const arr = [_]u16{ 1, 2, 3 };
        \\    const sz = @sizeOf(?u32);
        \\    const has_hidden = if (@hasDecl(S, "hidden")) @as(u8, 1) else @as(u16, 2);
        \\    const has_a = if (@hasField(S, "a")) @as(u8, 1) else @as(u16, 2);
        \\    _ = .{ P, Q, arr, sz, has_hidden, has_a };
        \\}
    , &.{
        .{ "P", "type = u64" },
        .{ "Q", "type = u32" },
        .{ "arr", "[3]u16" },
        .{ "sz", "comptime_int = 8" },
        // @hasDecl 只计 pub 声明
        .{ "has_hidden", "u16 = 2" },
        .{ "has_a", "u8 = 1" },
    });
}

test "deep dependency chains neither overflow nor pollute shallower results" {
    // 链的顶端远超栈上限：最先查询它，链底的结果仍然正确
    const n = 3000;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "fn List(comptime T: type) type { return struct { items: []T }; }\n");
    for (0..n) |i| try src.print(testing.allocator, "const a{d} = a{d};\n", .{ n - i, n - i - 1 });
    try src.appendSlice(testing.allocator, "const a0 = List(u8);\nconst b0: u32 = 1;\nconst b1 = b0 + 1;\n");
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.add("/p/main.zig", src.items);
    _ = try typeAt(&w, f.file, src.items, "a3000", 0);
    try testing.expectEqualStrings("type = List(u8)", try typeAt(&w, f.file, src.items, "a0", 1));
    try testing.expectEqualStrings("u32 = 2", try typeAt(&w, f.file, src.items, "b1", 0));
}

test "comptime evaluation runs loops, mutation and calls" {
    try expectTypes(
        \\fn double(n: usize) usize { return n * 2; }
        \\fn Nest(comptime n: usize) type {
        \\    var T: type = u8;
        \\    for (0..n) |_| T = ?T;
        \\    return T;
        \\}
        \\fn First16(comptime Ts: []const type) type {
        \\    inline for (Ts) |T| {
        \\        if (T == u16) return T;
        \\    }
        \\    return void;
        \\}
        \\fn Count(comptime n: usize) type {
        \\    comptime var i = 0;
        \\    inline while (i < n) : (i += 1) {}
        \\    return [i]u8;
        \\}
        \\fn Table(comptime n: usize) [n]u8 {
        \\    var out: [n]u8 = undefined;
        \\    for (&out, 0..) |*e, i| e.* = @intCast(i * 2);
        \\    return out;
        \\}
        \\fn Strip(comptime T: type) type {
        \\    return switch (T) {
        \\        ?u8 => Strip(u8),
        \\        else => T,
        \\    };
        \\}
        \\const table = Table(4);
        \\fn g() void {
        \\    const A = [double(4)]u8;
        \\    const N = Nest(2);
        \\    const F = First16(&.{ u8, u16 });
        \\    const C = Count(3);
        \\    const third = table[2];
        \\    const S = Strip(?u8);
        \\    _ = .{ A, N, F, C, third, S };
        \\}
    , &.{
        // 数组长度是 comptime 上下文：普通函数的调用也由解释器求值
        .{ "A", "type = [8]u8" },
        .{ "N", "type = ??u8" },
        .{ "F", "type = u16" },
        .{ "C", "type = [3]u8" },
        // 经由指针捕获写入的数组
        .{ "third", "u8 = 4" },
        .{ "S", "type = u8" },
    });
}

test "anytype arguments do not expand large arrays" {
    // 曾经：anytype 实参被当作 comptime 上下文求值，巨大数组的切片在解释器中逐个展开元素
    try expectTypes(
        \\var memory: [1 << 30]u8 = undefined;
        \\fn Wrapper(comptime T: type) type { return struct { inner: T }; }
        \\fn wrap(a: anytype) Wrapper(@TypeOf(a)) { return .{ .inner = a }; }
        \\fn id(buf: []u8) []u8 { return buf; }
        \\fn g() void {
        \\    const w = wrap(id(memory[0..]));
        \\    _ = w;
        \\}
    , &.{.{ "w", "Wrapper([]u8)" }});
}

test "concatenation in comptime keeps a sentinel that only one side has" {
    try expectTypes(
        \\const cat = [2]u8{ 1, 2 } ++ "cd";
    , &.{
        .{ "cat", "*const [4:0]u8 = \"\\x01\\x02cd\"" },
    });
}

test "unnamed parameters of extern functions are inferred" {
    try expectTypes(
        \\extern fn ext(*const u32, n: u32) bool;
        \\fn f() void {
        \\    var w: u32 = 0;
        \\    const r = ext(&w, 74);
        \\    _ = r;
        \\}
    , &.{
        .{ "ext", "fn (*const u32, u32) bool" },
        .{ "*const u32", "type = *const u32" },
        .{ "74", "u32 = 74" },
        .{ "r", "bool" },
    });
}

test "extern varargs function type keeps the varargs flag" {
    try expectTypes(
        \\extern fn ext(a: u8, ...) void;
        \\const FT = @TypeOf(ext);
        \\fn g() void {
        \\    const f = ext;
        \\    _ = f;
        \\}
    , &.{
        .{ "FT", "type = fn (u8, ...) void" },
        .{ "f", "fn (u8, ...) void" },
    });
}

test "extern varargs is reported by @typeInfo" {
    try expectStdTypes(
        \\extern fn ext(a: u8, ...) void;
        \\const FT = @TypeOf(ext);
        \\fn Flag(comptime T: type) type {
        \\    return if (@typeInfo(T).@"fn".attrs.varargs) u8 else u16;
        \\}
        \\const FV = Flag(FT);
    , &.{
        .{ "FV", "type = u8" },
    });
}

test "tuple declarations are structural" {
    try expectTypes(
        \\const A = struct { u8, bool };
        \\const B = struct { u8, bool };
        \\fn pair() struct { u32, bool } { return .{ 1, true }; }
        \\fn f() void {
        \\    const same = if (A == B) @as(u8, 1) else @as(u16, 2);
        \\    const p = pair();
        \\    const first = p[0];
        \\    _ = .{ same, first };
        \\}
    , &.{
        .{ "A", "type = struct { u8, bool }" },
        // 两个声明是同一个类型：比较 comptime 已知，只取 then 分支
        .{ "same", "u8 = 1" },
        .{ "p", "struct { u32, bool }" },
        .{ "first", "u32" },
    });
}

test "destructuring infers each element" {
    try expectTypes(
        \\fn pair() struct { u32, bool } { return .{ 1, true }; }
        \\fn f(arr: [3]u16, v: @Vector(2, f32)) void {
        \\    const x, const y = pair();
        \\    const a0, _, const a2 = arr;
        \\    const v0, const v1 = v;
        \\    const k0, const k1 = .{ 5, true };
        \\    _ = .{ x, y, a0, a2, v0, v1, k0, k1 };
        \\}
    , &.{
        .{ "x", "u32" },
        .{ "y", "bool" },
        .{ "a0", "u16" },
        .{ "a2", "u16" },
        .{ "v0", "f32" },
        .{ "v1", "f32" },
        // 元组字面量的 comptime 字段：值属于类型
        .{ "k0", "comptime_int = 5" },
        .{ "k1", "bool" },
    });
}

test "slices with comptime-known bounds are pointers to arrays" {
    try expectTypes(
        \\fn f(n: usize, sl: []u8, mp: [*]u8, s0: [:0]const u8, p0: [*:0]const u8) void {
        \\    var arr: [8]u8 = @splat(1);
        \\    const carr: [8]u8 = @splat(2);
        \\    var sarr: [8:0]u8 = @splat(3);
        \\    const t1 = arr[0..4];
        \\    const t2 = carr[1..4];
        \\    const t3 = sl[0..4];
        \\    const t4 = mp[0..4];
        \\    const t5 = arr[2..];
        \\    const t6 = sl[2..];
        \\    const t7 = arr[0..n];
        \\    const t8 = "hello"[1..3];
        \\    const t9 = arr[0..4 :1];
        \\    const t10 = sarr[2..];
        \\    const t11 = sarr[0..8];
        \\    const t12 = mp[2..];
        \\    const t13 = s0[1..];
        \\    const t14 = p0[1..];
        \\    const t15 = sarr[n..];
        \\    const t16 = (&arr)[1..3];
        \\    const t17 = sl[1..3 :1];
        \\    const t18 = (&arr[0])[0..1];
        \\    _ = .{ &arr, &sarr, t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11, t12, t13, t14, t15, t16, t17, t18 };
        \\}
    , &.{
        .{ "t1", "*[4]u8" },
        .{ "t2", "*const [3]u8" },
        .{ "t3", "*[4]u8" },
        .{ "t4", "*[4]u8" },
        .{ "t5", "*[6]u8" },
        .{ "t6", "[]u8" },
        .{ "t7", "[]u8" },
        .{ "t8", "*const [2]u8" },
        .{ "t9", "*[4:1]u8" },
        // 切到末尾（含结束位置等于长度）时保留数组的哨兵
        .{ "t10", "*[6:0]u8" },
        .{ "t11", "*[8:0]u8" },
        .{ "t12", "[*]u8" },
        .{ "t13", "[:0]const u8" },
        .{ "t14", "[*:0]const u8" },
        .{ "t15", "[:0]u8" },
        .{ "t16", "*[2]u8" },
        .{ "t17", "*[2:1]u8" },
        // 指向单个元素的指针按长度为 1 的数组切片
        .{ "t18", "*[1]u8" },
    });
}

test "concatenation follows the compiler" {
    try expectTypes(
        \\fn f() void {
        \\    const c1 = "ab" ++ "cd";
        \\    const c2 = [2]u8{ 1, 2 } ++ "cd";
        \\    const c3 = "ab" ++ [2]u8{ 3, 4 };
        \\    const c4 = [2]u8{ 1, 2 } ++ [_]u8{3};
        \\    const c5 = .{ 1, true } ++ .{"x"};
        \\    const c6 = [_:0]u8{1} ++ [_:1]u8{2};
        \\    const c7 = "ab" ++ [_:1]u8{2};
        \\    const c8 = .{ 1, 2 } ++ [_]u8{3};
        \\    const c9 = [_]u16{1} ++ [_]u8{2};
        \\    _ = .{ c1, c2, c3, c4, c5, c6, c7, c8, c9 };
        \\}
    , &.{
        .{ "c1", "*const [4:0]u8" },
        // 只有一侧有哨兵时保留它，两侧的哨兵不同时没有哨兵
        .{ "c2", "*const [4:0]u8" },
        .{ "c3", "*const [4:0]u8" },
        .{ "c4", "[3]u8" },
        .{ "c5", "struct { comptime comptime_int = 1, comptime bool = true, comptime *const [1:0]u8 = \"x\" }" },
        .{ "c6", "[2]u8" },
        .{ "c7", "*const [3]u8" },
        .{ "c8", "[3]u8" },
        .{ "c9", "[2]u16" },
    });
}

test "pointer arithmetic and vector operations" {
    try expectTypes(
        \\fn f(p: [*]const u8, q: [*]const u8, v: @Vector(4, u32)) void {
        \\    const p1 = p + 1;
        \\    const d = p - q;
        \\    const h = v[1];
        \\    const vc = v == v;
        \\    _ = .{ p1, d, h, vc };
        \\}
    , &.{
        .{ "p1", "[*]const u8" },
        .{ "d", "usize" },
        .{ "h", "u32" },
        // 向量逐元素比较
        .{ "vc", "@Vector(4, bool)" },
    });
}

test "calls through function pointers" {
    try expectTypes(
        \\fn f(fp: *const fn (u32) u64) void {
        \\    const k = fp(4);
        \\    _ = k;
        \\}
    , &.{
        .{ "k", "u64" },
    });
}

test "builtin result types follow the compiler" {
    try expectTypes(
        \\const Tag = enum { a, b, c };
        \\const U = union(Tag) { a: u8, b: u16, c: bool };
        \\const E = enum(u4) { x, y, z };
        \\const P = packed struct(u12) { lo: u4, hi: u8 };
        \\fn ret7() u32 { return 7; }
        \\fn f(e: E, u: U, pk: P, x: u32, y: u32, v: @Vector(4, u32), cp: *const u8, op: ?*const u8) void {
        \\    var w: u32 = 0;
        \\    const q1 = @intFromEnum(e);
        \\    const q2 = @backingInt(pk);
        \\    const q3 = @intFromEnum(u);
        \\    const q4 = @backingInt(u);
        \\    const q5 = @intFromEnum(E.z);
        \\    const b1 = @clz(x);
        \\    const b2 = @addWithOverflow(x, y);
        \\    const b3 = @shlWithOverflow(x, 3);
        \\    const b4 = @call(.auto, ret7, .{});
        \\    const b5 = @divTrunc(100, x);
        \\    const b6 = @returnAddress();
        \\    const b7 = @atomicLoad(u32, &w, .seq_cst);
        \\    const b8 = @cmpxchgWeak(u32, &w, 1, 2, .seq_cst, .seq_cst);
        \\    const b9 = @atomicRmw(u32, &w, .Add, 1, .seq_cst);
        \\    const v1 = @reduce(.Add, v);
        \\    const v2 = @select(u32, @as(@Vector(4, bool), @splat(true)), v, v);
        \\    const v3 = @shuffle(u32, v, v, [_]i32{ 0, 1 });
        \\    const v4 = @clz(v);
        \\    const k1 = @constCast(cp);
        \\    const k2 = @constCast(op);
        \\    const ui = @unionInit(U, "b", 4);
        \\    _ = .{ q1, q2, q3, q4, q5, b1, b2, b3, b4, b5, b6, b7, b8, b9, v1, v2, v3, v4, k1, k2, ui };
        \\}
    , &.{
        .{ "q1", "u4" },
        .{ "q2", "u12" },
        // 带标签的 union：标签的整数
        .{ "q3", "u2" },
        .{ "q4", "u2" },
        .{ "q5", "u4 = 2" },
        .{ "b1", "u6" },
        .{ "b2", "struct { u32, u1 }" },
        .{ "b3", "struct { u32, u1 }" },
        .{ "b4", "u32" },
        .{ "b5", "u32" },
        .{ "b6", "usize" },
        .{ "b7", "u32" },
        .{ "b8", "?u32" },
        .{ "b9", "u32" },
        .{ "v1", "u32" },
        .{ "v2", "@Vector(4, u32)" },
        .{ "v3", "@Vector(2, u32)" },
        .{ "v4", "@Vector(4, u6)" },
        .{ "k1", "*u8" },
        .{ "k2", "?*u8" },
        .{ "ui", "U" },
    });
}

test "builtin arguments get their result types" {
    try expectTypes(
        \\const E = enum(u4) { x, y, z };
        \\const P = packed struct(u12) { lo: u4, hi: u8 };
        \\const Outer = struct { x: u32, inner: u16 };
        \\fn f(n: u4, buf: []u16, p: *u16) void {
        \\    var w: u32 = 0;
        \\    const ee: anyerror!E = @enumFromInt(n);
        \\    const pk: P = @fromBackingInt(61);
        \\    const sp: @Vector(4, u8) = @splat(62);
        \\    @memset(buf, 63);
        \\    _ = @atomicRmw(u32, &w, .Add, 48, .seq_cst);
        \\    const outer: *Outer = @alignCast(@fieldParentPtr("inner", p));
        \\    _ = .{ ee, pk, sp, outer };
        \\}
    , &.{
        // 转换的目标类型去掉 error union 与 optional
        .{ "@enumFromInt(n)", "E" },
        .{ "pk", "P" },
        // 参数的结果类型：backing 整数、向量与切片的元素类型、原子操作的类型参数
        .{ "61", "u12 = 61" },
        .{ "62", "u8 = 62" },
        .{ "63", "u16 = 63" },
        .{ "48", "u32 = 48" },
        // `@alignCast(@fieldParentPtr(...))` 合并为一次转换：内层取外层的结果类型
        .{ "@fieldParentPtr(\"inner\", p)", "*Outer" },
    });
}

test "result types reach operands like the compiler" {
    try expectTypes(
        \\const Tag = enum { a, b, c };
        \\const U = union(Tag) { a: u8, b: u16, c: bool };
        \\const Buf = struct {
        \\    len: usize,
        \\    var global: Buf = .{ .len = 9 };
        \\    pub fn current() *Buf { return &global; }
        \\    pub fn init(n: usize) !Buf { return .{ .len = n }; }
        \\};
        \\const Pair = struct { a: u8, b: u16 };
        \\const Code = enum(u8) { ok = 1, bad = 71 };
        \\fn f(u: U, x: u32, c: bool) !void {
        \\    const d: Buf = try .init(2);
        \\    const cur: *Buf = .current();
        \\    const sh = x << 31;
        \\    const g = switch (u) { .a, .b => |pay| pay, .c => 0 };
        \\    const h = switch (u) { inline .a, .b => |_, tag| tag, .c => Tag.c };
        \\    const vec: @Vector(2, f32) = .{ 41, 42 };
        \\    const tup: struct { u8, bool } = .{ 43, true };
        \\    const op: ?Pair = .{ .a = 44, .b = 45 };
        \\    const sl: []const u16 = &.{ 46, 47 };
        \\    var w: u32 = 0;
        \\    const st: u8 = sw: switch (@as(u8, 1)) {
        \\        1 => continue :sw 49,
        \\        else => |k| break :sw k,
        \\    };
        \\    w <<= 29;
        \\    const lp: u8 = while (c) { break 72; } else 73;
        \\    _ = .{ d, cur, sh, g, h, vec, tup, op, sl, st, lp };
        \\}
    , &.{
        .{ "d", "Buf" },
        .{ "cur", "*Buf" },
        // 移位的右侧为 `Log2Int(T)`
        .{ "31", "u5 = 31" },
        .{ "29", "u5 = 29" },
        // 多个分支项的捕获为各字段类型的 peer，第二个捕获为标签
        .{ "pay", "u16" },
        .{ "tag", "Tag" },
        .{ "41", "f32 = 41" },
        .{ "43", "u8 = 43" },
        .{ "45", "u16 = 45" },
        .{ ".{ 46, 47 }", "[2]u16" },
        // labeled switch 的 `continue` 的值按操作数的类型推导
        .{ "49", "u8 = 49" },
        // 循环的 break 与 else 取循环的结果类型
        .{ "72", "u8 = 72" },
        .{ "73", "u8 = 73" },
        // 枚举成员的值按标签类型推导
        .{ "71", "u8 = 71" },
    });
}

test "peer types of pointers and optionals" {
    try expectTypes(
        \\fn f(c: bool, sl: []const u8, opt: ?[]const u8, ms: [*:0]const u8, mut: []u8) void {
        \\    var arr: [3]u8 = .{ 1, 2, 3 };
        \\    var arr4: [4]u8 = .{ 1, 2, 3, 4 };
        \\    const s1 = if (c) "abc" else "hello";
        \\    const s2 = if (c) sl else "hello";
        \\    const s3 = opt orelse "";
        \\    const s4 = if (c) &arr else &arr4;
        \\    const s5 = if (c) "abc" else ms;
        \\    const s6 = if (c) mut else "lit";
        \\    const s7 = if (c) &arr else "abc";
        \\    const s8 = switch (arr[0]) { 1 => "one", 2 => "three", else => "x" };
        \\    const s9 = if (c) opt else "x";
        \\    _ = .{ &arr, &arr4, s1, s2, s3, s4, s5, s6, s7, s8, s9 };
        \\}
    , &.{
        // 长度不同的数组指针统一为切片，哨兵只在两侧相同时保留
        .{ "s1", "[:0]const u8" },
        .{ "s2", "[]const u8" },
        .{ "s3", "[]const u8" },
        .{ "s4", "[]u8" },
        .{ "s5", "[*:0]const u8" },
        .{ "s6", "[]const u8" },
        .{ "s7", "*const [3]u8" },
        .{ "s8", "[:0]const u8" },
        // optional 与另一侧按载荷的 peer 包为 optional
        .{ "s9", "?[]const u8" },
    });
}

test "generic bodies without an instance use values that do not depend on the parameters" {
    try expectTypes(
        \\fn List(comptime T: type, comptime alignment: ?u29) type {
        \\    if (alignment) |a| {
        \\        if (a == @alignOf(T)) return List(T, null);
        \\    }
        \\    return struct {
        \\        items: Slice,
        \\        const Self = @This();
        \\        pub const Slice = if (alignment) |a| []align(a) T else []T;
        \\        fn first(self: *Self) T {
        \\            const head = self.items;
        \\            return head[0];
        \\        }
        \\        fn other() void {
        \\            const S = List(T, alignment).Slice;
        \\            _ = S;
        \\        }
        \\    };
        \\}
        \\fn g(c: bool) void {
        \\    const x = if (c) @as(u32, 5) else @as(u32, 5);
        \\    _ = x;
        \\}
    , &.{
        // 条件取决于抽象参数，但两个分支的值相同（不区分指针的对齐）
        .{ "head", "[]T" },
        // 自递归的类型函数：取本实例中的容器
        .{ "S", "type = []T" },
        // 运行时的条件：值不是 comptime 已知的
        .{ "x", "u32" },
    });
}

test "@hasDecl and @hasField on abstract parameters are unknown" {
    // 防止解释器把抽象参数当作没有该成员：类型标注与 comptime 调用中按 false 选择分支
    try expectTypes(
        \\const HasInner = struct { pub const Inner = u32; x: u8 };
        \\fn Sel(comptime T: type) type {
        \\    return if (@hasDecl(T, "Inner")) T.Inner else T;
        \\}
        \\fn f(comptime T: type) void {
        \\    var va: if (@hasDecl(T, "Inner")) T.Inner else T = undefined;
        \\    var vb: if (@hasField(T, "x")) u8 else u16 = undefined;
        \\    const S = Sel(T);
        \\    _ = .{ &va, &vb, S };
        \\}
        \\fn Pick(comptime U: type) type {
        \\    return if (@hasDecl(U, "get")) u8 else u16;
        \\}
        \\fn Wrap(comptime T: type) type {
        \\    return struct {
        \\        x: T,
        \\        const Self = @This();
        \\        pub fn get() void {}
        \\        fn g() void {
        \\            const P = Pick(Self);
        \\            _ = P;
        \\        }
        \\    };
        \\}
        \\const real = Sel(HasInner);
    , &.{
        .{ "va", "unknown" },
        .{ "vb", "unknown" },
        .{ "S", "type" },
        // 抽象实例中的容器：成员只取决于源码
        .{ "P", "type = u8" },
        .{ "real", "type = u32" },
    });
}

test "arrays whose length depends on abstract parameters keep their element type" {
    try expectTypes(
        \\fn Hasher(comptime block_length: usize) type {
        \\    return struct {
        \\        buf: [block_length]u8,
        \\        const Self = @This();
        \\        fn f(self: *Self, i: usize) void {
        \\            const whole = self.buf;
        \\            const b = self.buf[i];
        \\            const head = self.buf[0..4];
        \\            const rest = self.buf[1..];
        \\            const n = self.buf.len;
        \\            for (self.buf) |byte| _ = byte;
        \\            _ = .{ whole, b, head, rest, n };
        \\        }
        \\    };
        \\}
        \\fn g(comptime N: usize) void {
        \\    var tmp: [N * 2]u16 = undefined;
        \\    const zeros: [N:0]u8 = @splat(0);
        \\    _ = .{ &tmp, zeros };
        \\}
    , &.{
        // 长度按源码显示
        .{ "whole", "[block_length]u8" },
        .{ "b", "u8" },
        .{ "head", "*[4]u8" },
        .{ "rest", "[]u8" },
        .{ "n", "usize" },
        .{ "byte", "u8" },
        .{ "tmp", "[N * 2]u16" },
        .{ "zeros", "[N:0]u8" },
    });
}

test "loops over types bind an abstract type" {
    try expectTypes(
        \\fn gamma(comptime T: type, x: T) T { return x; }
        \\fn f() void {
        \\    inline for (.{ f32, f64 }) |T| {
        \\        const x: T = 1.0;
        \\        const g = gamma(T, x);
        \\        _ = g;
        \\    }
        \\}
    , &.{
        // 每次迭代的类型不同：与泛型函数的类型参数一样是抽象的
        .{ "x", "T" },
        .{ "g", "T" },
    });
}

test "members missing for the current target are looked up in other targets' namespaces" {
    try expectTypes(
        \\const native = .linux;
        \\const linux = struct { pub const read: u8 = 1; };
        \\const darwin = struct { pub const kqueue: u16 = 2; };
        \\const system = switch (native) { .linux => linux, .macos => darwin, else => struct {} };
        \\fn f() void {
        \\    const here = system.read;
        \\    const elsewhere = system.kqueue;
        \\    _ = .{ here, elsewhere };
        \\}
    , &.{
        .{ "here", "u8 = 1" },
        // 当前目标的命名空间中没有：取其他分支选择的容器中的定义
        .{ "elsewhere", "u16 = 2" },
    });
}

/// 使用本机 zig 的真实标准库（PATH 中没有 zig 时跳过）
fn expectStdTypes(src: []const u8, cases: []const struct { []const u8, []const u8 }) !void {
    return expectStdTypesOptimized(null, src, cases);
}

/// 同 `expectStdTypes`；`optimize` 不为 null 时提供该优化模式的 builtin（`std.lang.Optimize` 的成员名）
fn expectStdTypesOptimized(optimize: ?[]const u8, src: []const u8, cases: []const struct { []const u8, []const u8 }) !void {
    var env = @import("../project/ZigEnv.zig").query(testing.allocator, testing.io, null) catch return error.SkipZigTest;
    defer env.deinit(testing.allocator);
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const std_root_path = try std.fs.path.join(testing.allocator, &.{ env.std_dir, "std.zig" });
    defer testing.allocator.free(std_root_path);
    const std_root = try w.vfs.intern(std_root_path);
    const f = try w.add("/p/main.zig", src);
    if (optimize) |o| {
        const text = try std.fmt.allocPrint(w.arena.allocator(), "const std = @import(\"std\");\npub const mode = optimize;\npub const optimize: std.lang.Optimize = .{s};\n", .{o});
        w.default_builtin = (try w.add("/zig-cache/builtin.zig", text)).file;
    }
    try w.setGraph(std_root, &.{}, &.{});
    for (cases) |c| {
        const actual = try typeAt(&w, f.file, src, c[0], 0);
        testing.expectEqualStrings(c[1], actual) catch |err| {
            std.debug.print("type of `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "std.meta type functions" {
    try expectStdTypes(
        \\const std = @import("std");
        \\const E = enum(u8) { a, b, c };
        \\const U = union(E) { a: u8, b: u16, c: void };
        \\const S = struct { x: i32, y: []const u8, pub const k: u8 = 1; pub fn m(_: S) void {} };
        \\fn f(a: u32, b: f16) void { _ = .{ a, b }; }
        \\fn g(u: U) void {
        \\    const child = std.meta.Child(?u16);
        \\    const elem = std.meta.Elem([]const u32);
        \\    const sent = std.meta.Sentinel([]u8, 0);
        \\    const tag_e = std.meta.Tag(E);
        \\    const tag_u = std.meta.Tag(U);
        \\    const active = std.meta.activeTag(u);
        \\    const FE = std.meta.FieldEnum(S);
        \\    const fe: FE = .y;
        \\    const DE = std.meta.DeclEnum(S);
        \\    const args = std.meta.ArgsTuple(@TypeOf(f));
        \\    const backing = std.meta.BackingInt(E);
        \\    const slice = std.meta.Slice(*[10]i32);
        \\    const tags = std.meta.tags(E);
        \\    const field_ty = std.meta.fieldInfo(S, .x).type;
        \\    const sliced = std.mem.SliceTo([:0]const u8, 0);
        \\    _ = .{ child, elem, sent, tag_e, tag_u, active, FE, fe, DE, args, backing, slice, tags, field_ty, sliced };
        \\}
    , &.{
        .{ "child", "type = u16" },
        .{ "elem", "type = u32" },
        .{ "sent", "type = [:0]u8" },
        .{ "tag_e", "type = u8" },
        .{ "tag_u", "type = E" },
        .{ "active", "E" },
        // @Enum 构造的类型以构造它的函数实例命名（编译器显示为 meta.FieldEnum(main.S)）
        .{ "FE", "type = FieldEnum(S)" },
        .{ "fe", "FieldEnum(S) = .y" },
        .{ "DE", "type = DeclEnum(S)" },
        .{ "args", "type = struct { u32, f16 }" },
        .{ "backing", "type = u8" },
        .{ "slice", "type = []i32" },
        .{ "tags", "*const [3]E" },
        .{ "field_ty", "type = i32" },
        // 函数体内递归调用自身的类型函数（std.meta.Elem）能正常结束
        .{ "sliced", "type = [:0]const u8" },
    });
}

test "type reflection and reification" {
    try expectStdTypes(
        \\const std = @import("std");
        \\const S = struct { a: u8, b: bool };
        \\fn Pair(comptime A: type, comptime B: type) type { return @Tuple(&.{ A, B }); }
        \\fn Fields(comptime T: type) type {
        \\    const names = @typeInfo(T).@"struct".field_names;
        \\    return @Enum(u8, .exhaustive, names, &.{ 0, 1 });
        \\}
        \\fn g() void {
        \\    const n = @typeInfo(S).@"struct".field_names.len;
        \\    const P = Pair(u8, bool);
        \\    const F = Fields(S);
        \\    const fb: F = .b;
        \\    const Ptr = @Pointer(.slice, .{ .@"const" = true }, u8, null);
        \\    const tuple = .{ @as(u8, 1), true };
        \\    const first = tuple[0];
        \\    _ = .{ n, P, F, fb, Ptr, first };
        \\}
    , &.{
        .{ "n", "usize = 2" },
        .{ "P", "type = struct { u8, bool }" },
        .{ "F", "type = Fields(S)" },
        .{ "fb", "Fields(S) = .b" },
        .{ "Ptr", "type = []const u8" },
        // 与编译器一致：字面量中 comptime 已知的字段是 comptime 字段
        .{ "tuple", "struct { comptime u8 = 1, comptime bool = true } = .{ 1, true }" },
        .{ "first", "u8 = 1" },
    });
}

test "layouts of reified containers" {
    // 期望值为 zig 0.17.0 的结果
    try expectStdTypes(
        \\const std = @import("std");
        \\const E = enum { a, b, c };
        \\const Rf = @Struct(.auto, null, &.{ "x", "y" }, &.{ u8, u64 }, &@splat(.{}));
        \\const Ra = @Struct(.auto, null, &.{ "x", "y" }, &.{ u8, u64 }, &.{ .{}, .{ .@"align" = 16 } });
        \\const Ru = @Union(.auto, E, &.{ "a", "b", "c" }, &.{ u8, u32, void }, &@splat(.{}));
        \\const Efs = std.enums.EnumFieldStruct(E, u16, 0);
        \\const one: u8 = 1;
        \\const Rc = @Struct(.auto, null, &.{ "k", "x" }, &.{ u8, u32 }, &.{ .{ .@"comptime" = true, .default_value_ptr = &one }, .{} });
        \\const L = struct { a: u8 align(4), b: u8 };
        \\fn g() void {
        \\    const size_rf = @sizeOf(Rf);
        \\    const rf_x = @offsetOf(Rf, "x");
        \\    const size_ra = @sizeOf(Ra);
        \\    const size_ru = @sizeOf(Ru);
        \\    const size_efs = @sizeOf(Efs);
        \\    const efs_c = @offsetOf(Efs, "c");
        \\    const align_ra = @alignOf(Ra);
        \\    const ra_x = @offsetOf(Ra, "x");
        \\    const size_rc = @sizeOf(Rc);
        \\    const la = @typeInfo(L).@"struct".field_attrs[0].@"align";
        \\    const lb = @typeInfo(L).@"struct".field_attrs[1].@"align" orelse 0;
        \\    _ = .{ size_rf, rf_x, size_ra, size_ru, size_efs, efs_c, align_ra, ra_x, size_rc, la, lb };
        \\}
    , &.{
        .{ "size_rf", "comptime_int = 16" },
        .{ "rf_x", "comptime_int = 8" },
        // 字段属性中的显式对齐与 comptime 字段
        .{ "size_ra", "comptime_int = 16" },
        .{ "align_ra", "comptime_int = 16" },
        .{ "ra_x", "comptime_int = 8" },
        .{ "size_rc", "comptime_int = 4" },
        // @typeInfo 报告字段的显式对齐
        .{ "la", "?usize = 4" },
        .{ "lb", "usize = 0" },
        .{ "size_ru", "comptime_int = 8" },
        .{ "size_efs", "comptime_int = 6" },
        .{ "efs_c", "comptime_int = 4" },
    });
}

test "bare unions have a safety tag in safe build modes" {
    // 期望值为 zig 0.17.0 的结果
    const src =
        \\const Bare = union { a: u32, b: u8 };
        \\const One = union { a: u32 };
        \\const Rb = @Union(.auto, null, &.{ "a", "b" }, &.{ u32, u8 }, &@splat(.{}));
        \\fn Unsafe() type {
        \\    @setRuntimeSafety(false);
        \\    return union { a: u32, b: u8 };
        \\}
        \\fn g() void {
        \\    const size_bare = @sizeOf(Bare);
        \\    const size_one = @sizeOf(One);
        \\    const size_rb = @sizeOf(Rb);
        \\    const size_unsafe = @sizeOf(Unsafe());
        \\    _ = .{ size_bare, size_one, size_rb, size_unsafe };
        \\}
    ;
    try expectStdTypesOptimized("debug", src, &.{
        .{ "size_bare", "comptime_int = 8" },
        // 只有一个字段时没有标签
        .{ "size_one", "comptime_int = 4" },
        .{ "size_rb", "comptime_int = 8" },
        // `@setRuntimeSafety` 的作用取决于调用的位置与参数
        .{ "size_unsafe", "comptime_int" },
    });
    try expectStdTypesOptimized("fast", src, &.{
        .{ "size_bare", "comptime_int = 4" },
        .{ "size_one", "comptime_int = 4" },
        .{ "size_rb", "comptime_int = 4" },
    });
}

test "clauses get the compiler's result types" {
    try expectStdTypes(
        \\const std = @import("std");
        \\fn ext() callconv(.naked) void {}
        \\fn f() void {
        \\    const buf: []align(16) u8 = &.{};
        \\    _ = buf;
        \\}
    , &.{
        .{ "\"std\"", "*const [3:0]u8" },
        .{ ".naked", "CallingConvention" },
        .{ "16", "u29 = 16" },
    });
}

test "builtin arguments of std types get their result types" {
    try expectStdTypes(
        \\fn f(p: *u32) void {
        \\    @branchHint(.cold);
        \\    _ = @atomicLoad(u32, p, .seq_cst);
        \\}
    , &.{
        .{ ".cold", "BranchHint = .cold" },
        .{ ".seq_cst", "AtomicOrder = .seq_cst" },
    });
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
        \\    const xs = points.items(.x);
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
        \\    _ = .{ items, last, popped, got, entry, n, xs, flag, fs, info, FT, num, part, buf, loc };
        \\}
    , &.{
        .{ "list", "Aligned(u8, null)" },
        .{ "items", "[]u8" },
        .{ "last", "u8" },
        .{ "popped", "?u8" },
        .{ "got", "?[]const u8" },
        .{ "n", "usize" },
        // FieldEnum 构造的枚举、@FieldType 与 @tagName
        .{ "xs", "[]i32" },
        .{ "flag", "?bool" },
        .{ "entry", "GetOrPutResult(u32, []const u8, AutoContext(u32), 80)" },
        // @typeInfo 的结果 comptime 已知
        .{ "fs", "[]const [:0]const u8 = &.{ \"x\", \"y\" }" },
        .{ "info", "Type = .{ .@\"struct\" = .{ .is_tuple = false, .layout = .auto, .backing_integer = null, .field_names = &.{ \"x\", \"y\" }, .field_ty..." },
        .{ "FT", "type = i32" },
        .{ "num", "u32" },
        .{ "it", "SplitIterator(u8, .scalar)" },
        .{ "part", "?[]const u8" },
        .{ "buf", "[]u32" },
        .{ "loc", "SourceLocation" },
    });
}

test "local types used by containers in the body: no cycle through the whole function" {
    // 体内容器的方法用到外层函数的局部类型，外层函数体又引用这个方法；体内有 `enum(u32)`。
    // 此前取外层函数整体的推导结果，形成环，结果不完整、不写入 memo
    const text =
        \\fn f() u32 {
        \\    const P = struct { a: u32 };
        \\    const Id = enum(u32) { x, y };
        \\    const S = struct {
        \\        fn g(p: P) u32 {
        \\            return p.a;
        \\        }
        \\    };
        \\    const v = S.g(.{ .a = 1 });
        \\    _ = Id.x;
        \\    return v;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    var executions: [2]u64 = undefined;
    for (&executions) |*n| {
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
        const owner = try r.ownerKey(file, resolve.Resolver.lookupDecl(try r.itemTree(file), 0, "f").?);
        _ = try ctx.get(queries.Infer, .{ .owner = owner, .mode = .full });
        n.* = w.db.executions(queries.Infer);
    }
    // 结果完整、写入 memo：第二次读取不再执行
    try testing.expectEqual(executions[0], executions[1]);
    var stats: [database.Db.query_types.len]@import("../db/engine.zig").QueryStats = undefined;
    try testing.expectEqual(0, w.db.stats(&stats).incomplete_causes.get(.cycle));
    try testing.expectEqualStrings("u32", try typeAt(&w, file, text, "v", 1));
    try testing.expectEqualStrings("u32", try typeAt(&w, file, text, "p.a", 0));
}

test "container arguments that refer to locals of an outer function" {
    // `enum(T)` 的参数只推导这一个表达式，其中的 `T` 是更外层函数的局部常量。
    // `T` 在外层函数中的下标大于内层函数的绑定数（曾以内层函数的 Body 取外层的绑定而越界）
    const text =
        \\fn f() void {
        \\    const a = 1;
        \\    const b = 2;
        \\    const c = 3;
        \\    _ = .{ a, b, c };
        \\    const T = u16;
        \\    const S = struct {
        \\        fn h() void {
        \\            const E = enum(T) { a, b };
        \\            const x = @intFromEnum(E.b);
        \\            _ = x;
        \\        }
        \\    };
        \\    _ = S;
        \\}
        \\
    ;
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const file = (try w.add("/p/main.zig", text)).file;
    try testing.expectEqualStrings("u16 = 1", try typeAt(&w, file, text, "x", 0));
}

test "slicing an outer function's local from a container in the body" {
    // 外层函数的局部变量按其所在成员的 Body 判断常量性（此前用内层成员的 Body 查绑定，越界）
    try expectTypes(
        \\fn f() void {
        \\    const a = 1;
        \\    const b = 2;
        \\    const table = [_]u8{ 1, 2, 3 };
        \\    const S = struct {
        \\        fn g() []const u8 {
        \\            const part = table[0..];
        \\            return part;
        \\        }
        \\    };
        \\    _ = .{ a, b, S };
        \\}
    , &.{
        .{ "part", "*const [3]u8" },
    });
}

test "union(enum) without a tag expression: field names are not lowered as expressions" {
    // `union(enum) { unneeded, ... }` 的括号内没有表达式，此前取到了第一个成员，`unneeded` 被当作名字
    // 引用解析到外层的同名声明，与该声明的初始化形成环（Zig 编译器源码中 `LazySrcLoc.Offset`）
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const src =
        \\pub const L = struct {
        \\    offset: Offset,
        \\    pub const unneeded: L = .{ .offset = .unneeded };
        \\    pub const Offset = union(enum) {
        \\        unneeded,
        \\        byte: u32,
        \\    };
        \\    pub const Tagged = union(enum(u8)) { a, b: u32 };
        \\};
    ;
    const f = try w.add("/p/main.zig", src);
    var ctx = w.db.beginRead(testing.allocator);
    defer ctx.end();
    const tree = try ctx.get(database.syntax.FileItemTree, f.file);
    for (tree.items) |it| {
        const name = it.name orelse continue;
        if (std.mem.eql(u8, name, "Offset")) {
            const body = try ctx.get(database.hir.ItemBody, .{ .file = f.file, .item = it.ast_id });
            for (body.exprs) |e| try testing.expect(e != .name_ref);
            _ = try ctx.get(queries.DeclType, .{ .owner = .{ .file = f.file, .item = it.ast_id } });
        }
        // `union(enum(u8))` 的参数仍然取到
        if (std.mem.eql(u8, name, "Tagged")) {
            const body = try ctx.get(database.hir.ItemBody, .{ .file = f.file, .item = it.ast_id });
            var has_arg = false;
            for (body.exprs) |e| if (e == .container) {
                has_arg = e.container.arg != null;
            };
            try testing.expect(has_arg);
        }
    }
    var buf: [database.Db.query_types.len]@import("../db/engine.zig").QueryStats = undefined;
    try testing.expectEqual(0, w.db.stats(&buf).incomplete_causes.get(.cycle));
}

test "member bodies are reused when their source is unchanged" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const v1 = "fn a() u32 {\n    return 1;\n}\nfn b() u32 {\n    return 2;\n}\n";
    const v2 = "// edited\nfn a() u32 {\n    return 1;\n}\nfn b() u32 {\n    return 3;\n}\n";
    const Bodies = struct { a: *const @import("../hir/Body.zig"), b: *const @import("../hir/Body.zig") };
    const read = struct {
        fn bodies(w2: *World, file: FileId) !Bodies {
            var ctx = w2.db.beginRead(testing.allocator);
            defer ctx.end();
            const tree = try ctx.get(database.syntax.FileItemTree, file);
            var out: [2]*const @import("../hir/Body.zig") = undefined;
            for (tree.items) |it| {
                const i: usize = if (std.mem.eql(u8, it.name.?, "a")) 0 else 1;
                out[i] = try ctx.get(database.hir.ItemBody, .{ .file = file, .item = it.ast_id });
            }
            return .{ .a = out[0], .b = out[1] };
        }
    }.bodies;
    const f = try w.add("/p/main.zig", v1);
    const before = try read(&w, f.file);
    _ = try w.add("/p/main.zig", v2);
    const after = try read(&w, f.file);
    // a 的源码未变：沿用同一个 Body；b 改了：重新降级
    try testing.expectEqual(before.a, after.a);
    try testing.expect(before.b != after.b);
}

test "editing a callee body does not invalidate the inference of its callers" {
    // 判断是否为泛型调用时依赖被调函数的整个 Body：改它的函数体会使全部调用者重新推导
    const v1 = "fn callee(a: u32) u32 {\n    return a + 1;\n}\nfn generic(x: anytype) @TypeOf(x) {\n    return x;\n}\nfn caller(v: u32) u32 {\n    const r = callee(v);\n    return generic(r);\n}\n";
    const v2 = "fn callee(a: u32) u32 {\n    var b = a;\n    b += 2;\n    return b;\n}\nfn generic(x: anytype) @TypeOf(x) {\n    return x;\n}\nfn caller(v: u32) u32 {\n    const r = callee(v);\n    return generic(r);\n}\n";
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.add("/p/main.zig", v1);
    for ([_][]const u8{ v1, v2 }, 0..) |text, round| {
        if (round == 1) _ = try w.add("/p/main.zig", text);
        var ctx = w.db.beginRead(w.arena.allocator());
        defer ctx.end();
        var trace: @import("../db/engine.zig").Trace = .{ .gpa = w.arena.allocator() };
        ctx.trace = &trace;
        var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
        const owner = try r.ownerKey(f.file, resolve.Resolver.lookupDecl(try r.itemTree(f.file), 0, "caller").?);
        _ = try ctx.get(queries.Infer, .{ .owner = owner, .mode = .full });
        if (round == 0) continue;
        // 被调函数自身（签名部分）重新推导，值不变；调用者不重算
        const infer_index = comptime for (database.Db.query_types, 0..) |Q, qi| {
            if (Q == queries.Infer) break qi;
        } else unreachable;
        for (trace.events.items) |ev| if (ev.query == infer_index) {
            try testing.expect(w.db.keyAt(queries.Infer, ev.key).owner.item != owner.item);
        };
    }
    try testing.expectEqualStrings("u32", try typeAt(&w, f.file, v2, "r", 1));
}

test "std.mem pointer reinterpretation" {
    try expectStdTypes(
        \\const std = @import("std");
        \\const F = packed struct { a: u8 };
        \\fn g(s: []const u16, b: *const [2]u8, z: [:0]const u8) void {
        \\    const bytes = std.mem.sliceAsBytes(s);
        \\    const fs = std.mem.bytesAsSlice(F, b);
        \\    const zb = std.mem.sliceAsBytes(z);
        \\    _ = .{ bytes, fs, zb };
        \\}
    , &.{
        .{ "bytes", "[]const u8" },
        .{ "fs", "[]const F" },
        .{ "zb", "[]const u8" },
    });
}

test "switch on a type: unevaluable prong items do not hide a matching prong" {
    try expectTypes(
        \\const Vec = @import("missing.zig").Vec;
        \\fn Pick(comptime T: type) type {
        \\    return switch (T) {
        \\        Vec => u8,
        \\        u16 => u32,
        \\        else => @compileError("unsupported"),
        \\    };
        \\}
        \\fn g() void {
        \\    const hit: Pick(u16) = 0;
        \\    const miss: Pick(i8) = 0;
        \\    _ = .{ hit, miss };
        \\}
    , &.{
        // 分支项的值互不相同：`u16` 匹配时，求不出的 `Vec` 不可能也匹配
        .{ "hit", "u32 = 0" },
        // 都不匹配且有求不出的分支项：不能落到 else
        .{ "miss", "unknown" },
    });
}

test "a comptime branch that is @compileError gives way to the other branch" {
    try expectTypes(
        \\const is_test = false;
        \\const only_in_tests = if (is_test) @as(u32, 1) else @compileError("not testing");
        \\const only_outside = if (!is_test) @compileError("testing") else @as(u8, 2);
        \\const both = if (is_test) @compileError("x") else @compileError("y");
        \\const plain = if (is_test) @as(u16, 3) else @as(i16, 4);
        \\test {
        \\    const v_in = only_in_tests;
        \\    const v_out = only_outside;
        \\    const v_both = both;
        \\    const v_plain = plain;
        \\    _ = .{ v_in, v_out, v_both, v_plain };
        \\}
    , &.{
        // 被使用的声明不可能是编译错误：取另一个分支
        .{ "v_in", "u32 = 1" },
        .{ "v_out", "u8 = 2" },
        .{ "v_both", "noreturn" },
        .{ "v_plain", "i16 = 4" },
    });
}

test "a field of a literal-initialized constant is known when other fields are not" {
    try expectTypes(
        \\const Arch = enum { x86, wasm32 };
        \\const Cpu = struct { arch: Arch, features: u32 };
        \\extern fn featureSet() u32;
        \\const cpu: Cpu = .{ .arch = .wasm32, .features = featureSet() };
        \\const the_arch = cpu.arch;
        \\const Platform = if (cpu.arch == .wasm32) u8 else u16;
    , &.{
        // `features` 求不出，整个 `cpu` 没有值；`arch` 仍取初始化中的值，按它选择分支
        .{ "the_arch", "Arch = .wasm32" },
        .{ "Platform", "type = u8" },
    });
}

test "comptime evaluation: multiline strings, string arguments and comptime expressions in bodies" {
    try expectTypes(
        \\const text =
        \\    \\-a, --aa
        \\    \\  -b
        \\;
        \\const Split = struct {
        \\    buffer: []const u8,
        \\    index: ?usize = 0,
        \\    fn find(s: []const u8, start: usize) ?usize {
        \\        var i = start;
        \\        while (i < s.len) : (i += 1) if (s[i] == '\n') return i;
        \\        return null;
        \\    }
        \\    fn next(self: *Split) ?[]const u8 {
        \\        const start = self.index orelse return null;
        \\        const end = if (find(self.buffer, start)) |d| blk: {
        \\            self.index = d + 1;
        \\            break :blk d;
        \\        } else blk: {
        \\            self.index = null;
        \\            break :blk self.buffer.len;
        \\        };
        \\        return self.buffer[start..end];
        \\    }
        \\};
        \\fn count(s: []const u8) usize {
        \\    var n: usize = 0;
        \\    var it: Split = .{ .buffer = s };
        \\    while (it.next()) |_| n += 1;
        \\    return n;
        \\}
        \\fn Buf(comptime s: []const u8) type {
        \\    return [s.len]u8;
        \\}
        \\const lines = count(text);
        \\const FromLiteral = Buf("abc");
        \\const FromMultiline = Buf(
        \\    \\ab
        \\    \\c
        \\);
        \\fn f() void {
        \\    const local = comptime count("x\ny\nz");
        \\    _ = local;
        \\}
    , &.{
        // 各行去掉 `\\` 后以换行符连接
        .{ "text", "*const [13:0]u8 = \"-a, --aa\\n  -b\"" },
        .{ "lines", "usize = 2" },
        // 字符串字面量作为 comptime 实参有值
        .{ "FromLiteral", "type = [3]u8" },
        .{ "FromMultiline", "type = [4]u8" },
        // 函数体中的 `comptime` 表达式在 comptime 求值
        .{ "local", "usize = 3" },
    });
}

test "comptime evaluation: slices, pointers and error unions in interpreter storage" {
    try expectTypes(
        \\fn at(b: *[4]u8) error{X}!*u8 {
        \\    return &b[1];
        \\}
        \\fn put(b: *[4]u8, x: u8) error{X}!void {
        \\    const p = try at(b);
        \\    p.* = x;
        \\}
        \\fn viaErrorUnion() usize {
        \\    var buf: [4]u8 = .{ 0, 0, 0, 0 };
        \\    put(&buf, 7) catch return 99;
        \\    return buf[1];
        \\}
        \\const List = struct {
        \\    items: []u8,
        \\    capacity: usize,
        \\    fn addOne(self: *List) error{OutOfMemory}!*u8 {
        \\        if (self.items.len >= self.capacity) return error.OutOfMemory;
        \\        self.items.len += 1;
        \\        return &self.items[self.items.len - 1];
        \\    }
        \\    fn append(self: *List, x: u8) error{OutOfMemory}!void {
        \\        const p = try self.addOne();
        \\        p.* = x;
        \\    }
        \\};
        \\fn growSlice() usize {
        \\    var buf: [4]u8 = undefined;
        \\    var list: List = .{ .items = buf[0..0], .capacity = buf.len };
        \\    list.append(5) catch return 99;
        \\    list.append(6) catch return 99;
        \\    return list.items.len * 100 + list.items[1];
        \\}
        \\fn intoOptional(start: usize) usize {
        \\    var index: ?usize = null;
        \\    index = start + 1;
        \\    return index.?;
        \\}
        \\fn eql(a: []const u8, b: []const u8) bool {
        \\    if (a.len != b.len) return false;
        \\    if (a.ptr == b.ptr) return true;
        \\    for (a, b) |x, y| if (x != y) return false;
        \\    return true;
        \\}
        \\fn samePtr(a: []const u8) usize {
        \\    const lit: []const u8 = "ab";
        \\    return if (eql(a, "ab") and eql(a[0..1], "a") and lit.ptr == lit.ptr) 1 else 0;
        \\}
        \\const Names = struct { short: ?u8 };
        \\fn shortName(n: *const Names) usize {
        \\    if (n.short) |*s| return @as(*const [1]u8, s)[0];
        \\    return 0;
        \\}
        \\fn bump() usize {
        \\    var n: Names = .{ .short = 1 };
        \\    if (n.short) |*s| s.* += 2;
        \\    return n.short.?;
        \\}
        \\const r_eu = viaErrorUnion();
        \\const r_grow = growSlice();
        \\const r_opt = intoOptional(4);
        \\const r_ptr = samePtr("ab");
        \\const r_short = shortName(&.{ .short = 'h' });
        \\const r_bump = bump();
    , &.{
        // 函数执行到末尾时的 `E!void` 与 `catch` 中指向局部存储的载荷
        .{ "r_eu", "usize = 7" },
        // 修改切片的 `len`
        .{ "r_grow", "usize = 206" },
        // 算术的操作数不按 optional 结果类型转换
        .{ "r_opt", "usize = 5" },
        // 切片的 `ptr` 比较（`std.mem.eql` 中的快速路径）
        .{ "r_ptr", "usize = 1" },
        // optional 的指针捕获与 `*const T` 到 `*const [1]T`
        .{ "r_short", "usize = 104" },
        .{ "r_bump", "usize = 3" },
    });
}

test "comptime evaluation: slices of interpreter storage read elements in place" {
    // 防止取切片的元素或长度时复制整个区间：逐次切片的循环（comptime 分词器的常见写法）分配量与
    // 长度的平方成正比，超过内存上限后结果未知
    const text = comptime blk: {
        @setEvalBranchQuota(2000);
        var buf: [1024]u8 = undefined;
        for (&buf, 0..) |*c, i| c.* = if (i % 2 == 0) 'a' else 'b';
        const final = buf;
        break :blk &final;
    };
    try expectTypes(
        \\fn count(comptime s: []const u8) usize {
        \\    @setEvalBranchQuota(100000);
        \\    var rest: []const u8 = s;
        \\    var k: usize = 0;
        \\    while (rest.len > 0) : (rest = rest[1..]) {
        \\        if (rest[0] == 'a') k += 1;
        \\    }
        \\    return k;
        \\}
        \\fn copies(comptime s: []const u8) usize {
        \\    var buf: [s.len]u8 = undefined;
        \\    @memcpy(&buf, s);
        \\    const view = buf[1..];
        \\    var out: [s.len - 1]u8 = undefined;
        \\    @memcpy(&out, view);
        \\    const joined = view[view.len - 3 ..] ++ "c";
        \\    for (view[0..2]) |*x| x.* = 'd';
        \\    const p = view[2..4];
        \\    p.*[0] = 'e';
        \\    const digits = [_]u8{ out[0], joined[3], buf[2], buf[3], 'a' + joined.len };
        \\    var n: usize = 0;
        \\    for (digits) |d| n = n * 10 + (d - 'a');
        \\    return n;
        \\}
        \\const big = "
    ++ text ++
        \\";
        \\const counted = count(big);
        \\const copied = copies(big);
    , &.{
        .{ "counted", "usize = 512" },
        // 经由区间读取、复制、拼接与写入
        .{ "copied", "usize = 12344" },
    });
}

test "comptime evaluation: element-wise work counts toward the step and memory limits" {
    // 防止逐元素的操作绕过上限：表达式不多的求值中逐个写入数十万个元素，或在两次内存检查之间
    // 复制出超过内存上限的大数组
    try expectTypes(
        \\fn copyMany() u8 {
        \\    const buf: [60000]u8 = @splat(1);
        \\    var out: [60000]u8 = undefined;
        \\    for (0..4) |_| @memcpy(&out, &buf);
        \\    return out[0];
        \\}
        \\fn copyFew() u8 {
        \\    const buf: [60000]u8 = @splat(1);
        \\    var out: [60000]u8 = undefined;
        \\    @memcpy(&out, &buf);
        \\    return out[0];
        \\}
        \\fn copyLarge() u8 {
        \\    const buf: [65536]u8 = @splat(1);
        \\    var sum: u8 = 0;
        \\    for (0..24) |_| {
        \\        const c = buf;
        \\        sum +%= c[0];
        \\    }
        \\    return sum;
        \\}
        \\const many = copyMany();
        \\const few = copyFew();
        \\const large = copyLarge();
    , &.{
        .{ "many", "u8" },
        .{ "few", "u8 = 1" },
        .{ "large", "u8" },
    });
}

test "catch and orelse take the result type of the whole expression, labeled switch break values" {
    try expectTypes(
        \\fn parse(s: []const u8) error{Bad}!u8 {
        \\    return if (s.len == 0) error.Bad else 1;
        \\}
        \\fn find(x: u32) ?u8 {
        \\    return if (x == 0) null else 1;
        \\}
        \\const Color = enum { red, green };
        \\fn pick(x: u32) error{Bad}!Color {
        \\    return if (x == 0) error.Bad else .red;
        \\}
        \\fn g(s: []const u8, x: u32) void {
        \\    const a = parse(s) catch null;
        \\    const b = parse(s) catch 0;
        \\    const c: ?u16 = parse(s) catch null;
        \\    const d = pick(x) catch .green;
        \\    const e = find(x) orelse null;
        \\    const f = find(x) orelse 0;
        \\    const k = sw: switch (x) {
        \\        0 => break :sw @as(u8, 1),
        \\        else => break :sw 2,
        \\    };
        \\    const k2 = sw2: switch (x) {
        \\        0 => continue :sw2 1,
        \\        1 => break :sw2 @as(u16, 3),
        \\        else => @as(u16, 4),
        \\    };
        \\    const k3 = sw3: switch (1) {
        \\        1 => break :sw3 @as(u8, 1),
        \\        else => break :sw3 @as(u16, 2),
        \\    };
        \\    const k4 = sw4: switch (@as(u8, 0)) {
        \\        0 => continue :sw4 1,
        \\        1 => break :sw4 @as(u16, 7),
        \\        else => break :sw4 @as(u16, 8),
        \\    };
        \\    _ = .{ a, b, c, d, e, f, k, k2, k3, k4 };
        \\}
    , &.{
        // 右侧按载荷类型转换时 `null` 被当作 `u8`
        .{ "a", "?u8" },
        .{ "b", "u8" },
        .{ "c", "?u16" },
        .{ "d", "Color" },
        .{ "e", "?u8" },
        .{ "f", "u8" },
        // 不收集 `break :sw` 的值时各分支都是 noreturn
        .{ "k", "u8" },
        .{ "k2", "u16" },
        // comptime 已知的操作数只执行匹配的分支；有 `continue :sw4` 时可能转到其他分支
        .{ "k3", "u8 = 1" },
        .{ "k4", "u16" },
    });
}

test "comptime evaluation: self-referential and deeply nested values are unknown" {
    try expectTypes(
        \\const Node = struct { next: ?*const Node = null, v: u32 = 0 };
        \\fn selfLoop() Node {
        \\    var n: Node = .{ .v = 1 };
        \\    n.next = &n;
        \\    return n;
        \\}
        \\fn pair() [2]Node {
        \\    var ns: [2]Node = .{ .{ .v = 1 }, .{ .v = 2 } };
        \\    ns[0].next = &ns[1];
        \\    ns[1].next = &ns[0];
        \\    return ns;
        \\}
        \\fn chain(comptime n: usize) Node {
        \\    var nodes: [n]Node = undefined;
        \\    nodes[0] = .{ .v = 0 };
        \\    for (1..n) |i| nodes[i] = .{ .next = &nodes[i - 1], .v = i };
        \\    return nodes[n - 1];
        \\}
        \\const loop = selfLoop();
        \\const both = pair();
        \\const v = selfLoop().v;
        \\const short = chain(3).next.?.v;
        \\const long = chain(1000);
    , &.{
        // 自引用的值沿指针展开不会结束（原生栈耗尽，进程崩溃）
        .{ "loop", "Node" },
        .{ "both", "[2]Node" },
        // 调用的结果整体驻留，含环时其中的字段也未知
        .{ "v", "u32" },
        .{ "short", "u32 = 1" },
        .{ "long", "Node" },
    });
}
