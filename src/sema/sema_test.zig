//! Type inference tests: query the types of expressions and bindings in an in-memory project.

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
const infer = @import("infer.zig");
const FileId = @import("../base/Vfs.zig").FileId;

/// Type at the `nth` occurrence of `needle`: the type of the binding when the name coincides with
/// a binding, otherwise the type of the expression whose range is exactly `needle`
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
    // The member itself: its declared type
    const tv = try ctx.get(queries.DeclType, .{ .owner = owner });
    return render.typedValueAlloc(&r, tv);
}

/// Position of the `nth` occurrence of `needle` as a whole word
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

/// Same as `expectTypes`, with the given target parameters (pointer bit width, vector layout rules)
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
        .{ "n", "?u8 = null" },
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

test "the payload of an optional and @field are places that can be modified when their holder can" {
    // `&o.?` and `&@field(s, "x")` used to be `*const` even when `o` and `s` are vars
    try expectTypes(
        \\const S = struct { x: u8 };
        \\fn f() void {
        \\    var o: ?S = null;
        \\    var s: S = .{ .x = 1 };
        \\    const co: ?S = null;
        \\    const cs: S = .{ .x = 1 };
        \\    const p = &o.?;
        \\    const q = &@field(s, "x");
        \\    const cp = &co.?;
        \\    const cq = &@field(cs, "x");
        \\    _ = .{ p, q, cp, cq, &o, &s };
        \\}
    , &.{
        .{ "p", "*S" },
        .{ "q", "*u8" },
        .{ "cp", "*const S" },
        .{ "cq", "*const u8" },
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
        // Values of container-level constants are computed by the interpreter
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
        // At the generic definition (no concrete instance): abstract parameters
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
        // Infinitely recursive type construction: the value is unknown once the depth limit is
        // reached, without hanging
        .{ "R", "type" },
    });
}

test "comptime anytype parameters take the type of the argument" {
    // Expected values are the results of zig 0.17.0 and 0.17.1, which record the argument as a
    // value of its type. Prevents taking the parameter type from the value: a non-null optional
    // or error union is represented by its payload, and `null`, `undefined` and errors carry no
    // type of their own, so `@TypeOf(x)` was `u8` for `@as(?u8, 3)`.
    try expectTypes(
        \\fn TypeOfCt(comptime x: anytype) type {
        \\    return @TypeOf(x);
        \\}
        \\fn forward(comptime x: anytype) type {
        \\    return TypeOfCt(x);
        \\}
        \\fn AnyId(comptime x: anytype) type {
        \\    return struct {
        \\        pub const v = x;
        \\    };
        \\}
        \\fn isOptionalU8(comptime x: anytype) bool {
        \\    return @TypeOf(x) == ?u8;
        \\}
        \\fn echo(comptime x: anytype) @TypeOf(x) {
        \\    return x;
        \\}
        \\const E = enum { a, b };
        \\const opt = TypeOfCt(@as(?u8, 3));
        \\const opt_null = TypeOfCt(@as(?u8, null));
        \\const eu = TypeOfCt(@as(anyerror!u8, 3));
        \\const eu_err = TypeOfCt(@as(anyerror!u8, error.Foo));
        \\const err = TypeOfCt(error.Foo);
        \\const opt_opt = TypeOfCt(@as(??u8, null));
        \\const opt_type = TypeOfCt(@as(?type, u8));
        \\const opt_tag = TypeOfCt(@as(?E, .a));
        \\const opt_float = TypeOfCt(@as(?f32, 1.5));
        \\const opt_slice = TypeOfCt(@as(?[]const u8, "abc"));
        \\const eu_opt = TypeOfCt(@as(error{A}!?u8, null));
        \\const undef = TypeOfCt(@as(u8, undefined));
        \\const null_type = TypeOfCt(null);
        \\const int = TypeOfCt(3);
        \\const literal = TypeOfCt(.foo);
        \\const tag = TypeOfCt(E.a);
        \\const forwarded = forward(@as(?u8, 3));
        \\const forwarded_err = forward(@as(error{A}!u8, error.A));
        \\const v_opt = AnyId(@as(?u8, 3)).v;
        \\const v_null = AnyId(@as(?u8, null)).v;
        \\const v_eu = AnyId(@as(anyerror!u8, 3)).v;
        \\const v_err = AnyId(@as(anyerror!u8, error.Foo)).v;
        \\const v_int = AnyId(3).v;
        \\const v_literal = AnyId(.a).v;
        \\const is_optional = isOptionalU8(@as(?u8, 3));
        \\const not_optional = isOptionalU8(@as(u8, 3));
        \\const echoed = echo(@as(?u8, 3));
        \\const name = @typeName(AnyId(@as(?u8, 3)));
    , &.{
        .{ "opt", "type = ?u8" },
        .{ "opt_null", "type = ?u8" },
        .{ "eu", "type = anyerror!u8" },
        .{ "eu_err", "type = anyerror!u8" },
        .{ "err", "type = error{Foo}" },
        .{ "opt_opt", "type = ??u8" },
        .{ "opt_type", "type = ?type" },
        .{ "opt_tag", "type = ?E" },
        .{ "opt_float", "type = ?f32" },
        .{ "opt_slice", "type = ?[]const u8" },
        .{ "eu_opt", "type = error{A}!?u8" },
        .{ "undef", "type = u8" },
        .{ "null_type", "type = @TypeOf(null)" },
        .{ "int", "type = comptime_int" },
        .{ "literal", "type = @EnumLiteral()" },
        .{ "tag", "type = E" },
        // A parameter passed on to another comptime anytype parameter keeps its type
        .{ "forwarded", "type = ?u8" },
        .{ "forwarded_err", "type = error{A}!u8" },
        .{ "v_opt", "?u8 = 3" },
        .{ "v_null", "?u8 = null" },
        .{ "v_eu", "anyerror!u8 = 3" },
        .{ "v_err", "anyerror!u8 = error.Foo" },
        .{ "v_int", "comptime_int = 3" },
        .{ "v_literal", "@EnumLiteral() = .a" },
        // The interpreter binds the parameter with the recorded type
        .{ "is_optional", "bool = true" },
        .{ "not_optional", "bool = false" },
        .{ "echoed", "?u8 = 3" },
        // The name shows the value, as the compiler prints an optional by its payload
        .{ "name", "*const [13:0]u8 = \"main.AnyId(3)\"" },
    });
}

test "comptime anytype arguments of different types are different instances" {
    // Expected values are the results of zig 0.17.0 and 0.17.1, where a container in a generic
    // function is identified by its captured values with their types. Prevents arguments of
    // different types from giving the same container, whether their values have the same
    // representation (`@as(?u8, 3)` and `@as(u8, 3)`) or only compare equal (`3` and `@as(u8, 3)`).
    try expectTypes(
        \\fn AnyId(comptime x: anytype) type {
        \\    return struct {
        \\        pub const v = x;
        \\    };
        \\}
        \\fn Pair(comptime a: anytype, comptime b: anytype) type {
        \\    return struct {
        \\        pub const first = a;
        \\        pub const second = b;
        \\    };
        \\}
        \\const E = enum { a, b };
        \\const opt = AnyId(@as(?u8, 3)) == AnyId(@as(u8, 3));
        \\const opt_null = AnyId(null) == AnyId(@as(?u8, null));
        \\const null_types = AnyId(@as(?u8, null)) == AnyId(@as(?u16, null));
        \\const eu = AnyId(@as(anyerror!u8, 3)) == AnyId(@as(u8, 3));
        \\const undef = AnyId(@as(u8, undefined)) == AnyId(@as(u16, undefined));
        \\const int = AnyId(3) == AnyId(@as(u8, 3));
        \\const widths = AnyId(@as(u8, 3)) == AnyId(@as(u16, 3));
        \\const literal = AnyId(.a) == AnyId(E.a);
        \\const float = AnyId(1.5) == AnyId(@as(f32, 1.5));
        \\const pair = Pair(@as(?u8, 3), null) == Pair(@as(u8, 3), null);
        \\const same = AnyId(@as(?u8, 3)) == AnyId(@as(?u8, 3));
        \\const coerced = AnyId(@as(?u8, 3)) == AnyId(@as(?u8, @as(u8, 3)));
        \\const same_pair = Pair(@as(?u8, 3), null) == Pair(@as(?u8, 3), null);
        \\const second_null = Pair(@as(?u8, 3), @as(?u16, null)).second;
    , &.{
        .{ "opt", "bool = false" },
        .{ "opt_null", "bool = false" },
        .{ "null_types", "bool = false" },
        .{ "eu", "bool = false" },
        .{ "undef", "bool = false" },
        .{ "int", "bool = false" },
        .{ "widths", "bool = false" },
        .{ "literal", "bool = false" },
        .{ "float", "bool = false" },
        .{ "pair", "bool = false" },
        .{ "same", "bool = true" },
        .{ "coerced", "bool = true" },
        .{ "same_pair", "bool = true" },
        .{ "second_null", "?u16 = null" },
    });
}

test "functions with an inferred error set are evaluated in constants" {
    // The inferred error set of the running function must be the one in the function's type,
    // otherwise the computed value of the initializer is discarded.
    try expectTypes(
        \\fn check(c: u8) !u8 {
        \\    if (c == 0) return error.Bad;
        \\    return c;
        \\}
        \\const ok = check(1);
        \\const bad = check(0);
        \\const unwrapped = check(2) catch unreachable;
        \\const known = if (unwrapped >= 2) u16 else u8;
        \\fn g() void { _ = .{ ok, bad, known }; }
    , &.{
        .{ "ok", "error{Bad}!u8 = 1" },
        .{ "bad", "error{Bad}!u8 = error.Bad" },
        .{ "unwrapped", "u8 = 2" },
        .{ "known", "type = u16" },
    });
}

test "struct literals with an error union or optional result type" {
    // A literal whose result type is an error union was given up on, unlike an optional one.
    try expectTypes(
        \\const V = struct { minor: usize };
        \\fn inferred() !V { return .{ .minor = 1 }; }
        \\fn explicit() error{X}!V { return .{ .minor = 2 }; }
        \\fn optional() ?V { return .{ .minor = 3 }; }
        \\const a = inferred();
        \\const b = explicit();
        \\const c = optional();
        \\fn g() void { _ = .{ a, b, c }; }
    , &.{
        .{ "a", "error{}!V = .{ .minor = 1 }" },
        .{ "b", "error{X}!V = .{ .minor = 2 }" },
        .{ "c", "?V = .{ .minor = 3 }" },
    });
}

test "enums defined in a signature compare and switch by tag across instances" {
    // A tag keeping the type of another instance of the function made its comparison unknown.
    try expectTypes(
        \\fn runtime(s: enum { pos, neg }) u8 { return if (s == .pos) 1 else 2; }
        \\fn generic(comptime s: enum { pos, neg }) u8 { return if (s == .neg) 1 else 2; }
        \\fn switched(comptime s: enum { pos, neg }) u8 { return switch (s) { .pos => 1, .neg => 2 }; }
        \\const a = runtime(.pos);
        \\const b = generic(.pos);
        \\const c = switched(.neg);
        \\fn g() void { _ = .{ a, b, c }; }
    , &.{
        .{ "a", "u8 = 1" },
        .{ "b", "u8 = 2" },
        .{ "c", "u8 = 2" },
    });
}

test "a condition computed by a function selects the branch of a version check" {
    // The arm that is not taken names a field that does not exist, so the type comes from the
    // condition's value alone.
    try expectTypes(
        \\const Version = struct { minor: usize };
        \\fn parseNum(text: []const u8, comptime sign: enum { pos, neg }) !usize {
        \\    if (text.len == 0) return error.Empty;
        \\    return switch (sign) { .pos => text.len, .neg => 0 };
        \\}
        \\fn parse(text: []const u8) !Version {
        \\    return .{ .minor = try parseNum(text, .pos) };
        \\}
        \\const version = parse("ab") catch unreachable;
        \\const Build = struct { current: u32 };
        \\fn g(b: *Build) void {
        \\    const root = if (comptime version.minor >= 2) b.current else b.removed;
        \\    _ = root;
        \\}
    , &.{
        .{ "root", "u32" },
    });
}

test "a format-style length in a signature and a comptime block filling a sentinel array" {
    // The shape of std.fmt.comptimePrint: `args` is a runtime anytype parameter, but the type of
    // a tuple literal whose fields are all comptime fields has a single value.
    try expectTypes(
        \\fn width(comptime fmt: []const u8, args: anytype) usize { return fmt.len + args[0]; }
        \\inline fn print(comptime fmt: []const u8, args: anytype) *const [width(fmt, args):0]u8 {
        \\    comptime {
        \\        var buf: [width(fmt, args):0]u8 = undefined;
        \\        for (&buf) |*c| c.* = fmt[0];
        \\        buf[buf.len] = 0;
        \\        const final = buf;
        \\        return &final;
        \\    }
        \\}
        \\const a = print("ab", .{1});
        \\const nested = print("x", .{print("y", .{2}).len});
        \\fn g(n: usize) void {
        \\    const at_runtime = print("ab", .{n});
        \\    _ = .{ a, nested, at_runtime };
        \\}
    , &.{
        .{ "a", "*const [3:0]u8 = \"aaa\"" },
        .{ "nested", "*const [4:0]u8 = \"xxxx\"" },
        .{ "at_runtime", "*const [_:0]u8" },
    });
}

test "pointer casts keep the value only when the elements are unchanged" {
    // Relabeling `*const [2][1]u8` as `*const [2]u8` showed array elements as bytes.
    try expectTypes(
        \\const nested: [2][1]u8 = .{ "a".*, "b".* };
        \\const flat: *const [2]u8 = @ptrCast(&nested);
        \\const bytes: [2]u8 = "ab".*;
        \\const many: [*]const u8 = @ptrCast(&bytes);
        \\const first = many[0];
        \\const signed: *const [2]i8 = @ptrCast(&bytes);
        \\const zero: u8 = 0;
        \\const erased: ?*const anyopaque = @ptrCast(&zero);
        \\const back: ?*const u8 = @ptrCast(@alignCast(erased));
        \\const wrong: ?*const u16 = @ptrCast(@alignCast(erased));
        \\const none: ?*const anyopaque = null;
        \\const none_back: ?*const u8 = @ptrCast(none);
        \\fn g() void { _ = .{ flat, first, signed, back, wrong, none_back }; }
    , &.{
        .{ "flat", "*const [2]u8" },
        .{ "first", "u8 = 97" },
        .{ "signed", "*const [2]i8" },
        .{ "back", "?*const u8 = &0" },
        .{ "wrong", "?*const u16" },
        .{ "none_back", "?*const u8 = null" },
    });
}
test "@constCast and @volatileCast take their destination type from the operand" {
    // The casts converted to the result type themselves, so a result type such as
    // `error{Bad}!*u8` or `*const [1]u8` lost the value, and `@volatileCast` kept `volatile`.
    try expectTypes(
        \\const three: u8 = 3;
        \\const four: u8 = 4;
        \\const vp: *const volatile u8 = &four;
        \\const ovp: ?*const volatile u8 = &four;
        \\const ocp: ?*const u8 = &three;
        \\const erased: *const anyopaque = @ptrCast(&three);
        \\fn euConstCast(p: *const u8) error{Bad}!*u8 { return @constCast(p); }
        \\fn euVolatileCast(p: *const volatile u8) error{Bad}!*const u8 { return @volatileCast(p); }
        \\fn arrConstCast(p: *const u8) *const [1]u8 { return @constCast(p); }
        \\fn euOptConstCast(p: ?*const u8) error{Bad}!?*u8 { return @constCast(p); }
        \\fn fullChain(p: *const anyopaque) *u8 { return @constCast(@ptrCast(p)); }
        \\fn fullChainAlign(p: *align(1) const u8) *u8 { return @volatileCast(@constCast(@alignCast(p))); }
        \\const eu_constcast = (euConstCast(&three) catch unreachable).*;
        \\const eu_volatilecast = (euVolatileCast(&four) catch unreachable).*;
        \\const arr_constcast = arrConstCast(&three)[0];
        \\const eu_opt_constcast = (euOptConstCast(&three) catch unreachable).?.*;
        \\const eu_opt_null = euOptConstCast(null) catch unreachable;
        \\const typeof_constcast = @TypeOf(@constCast(&three));
        \\const typeof_volatilecast = @TypeOf(@volatileCast(vp));
        \\const typeof_both = @TypeOf(@constCast(@volatileCast(vp)));
        \\const typeof_opt_volatilecast = @TypeOf(@volatileCast(ovp));
        \\const typeof_opt_constcast = @TypeOf(@constCast(ocp));
        \\const full_chain = fullChain(erased).*;
        \\const full_chain_align = fullChainAlign(&three).*;
        \\fn runtime(p: *const volatile u8, op: ?*const volatile u8) void {
        \\    const r1 = @volatileCast(p);
        \\    const r2 = @constCast(@volatileCast(op));
        \\    _ = .{ r1, r2 };
        \\}
    , &.{
        .{ "eu_constcast", "u8 = 3" },
        .{ "eu_volatilecast", "u8 = 4" },
        .{ "arr_constcast", "u8 = 3" },
        .{ "eu_opt_constcast", "u8 = 3" },
        .{ "eu_opt_null", "?*u8 = null" },
        .{ "typeof_constcast", "type = *u8" },
        .{ "typeof_volatilecast", "type = *const u8" },
        .{ "typeof_both", "type = *u8" },
        // An optional pointer stays optional
        .{ "typeof_opt_volatilecast", "type = ?*const u8" },
        .{ "typeof_opt_constcast", "type = ?*u8" },
        // Merged with `@ptrCast` / `@alignCast`, the destination is the result type
        .{ "full_chain", "u8 = 3" },
        .{ "full_chain_align", "u8 = 3" },
        .{ "r1", "*const u8" },
        .{ "r2", "?*u8" },
    });
}

test "a pointer erased to *anyopaque keeps its value when cast back from a parameter or a local" {
    // A pointer coerced to `*anyopaque` in a parameter or a local had no value when cast back
    // with `@ptrCast`; only container-level constants kept it.
    try expectTypes(
        \\const c: u8 = 3;
        \\fn ptrCastPlain(p: *const anyopaque) *const u8 {
        \\    return @ptrCast(p);
        \\}
        \\const from_param = ptrCastPlain(&c).*;
        \\const erased: *const anyopaque = &c;
        \\const from_coerced_global = ptrCastPlain(erased).*;
        \\const erased_cast: *const anyopaque = @ptrCast(&c);
        \\const from_cast_global = ptrCastPlain(erased_cast).*;
        \\const from_local = blk: {
        \\    const e: *const anyopaque = &c;
        \\    const back: *const u8 = @ptrCast(e);
        \\    break :blk back.*;
        \\};
        \\const from_var = blk: {
        \\    var x: u8 = 1;
        \\    const e: *anyopaque = &x;
        \\    x = 8;
        \\    const back: *u8 = @ptrCast(e);
        \\    back.* += 1;
        \\    break :blk x;
        \\};
        \\fn optBack(p: ?*const anyopaque) ?*const u8 {
        \\    return @ptrCast(p);
        \\}
        \\const from_optional = optBack(&c).?.*;
        \\const h: u16 = 513;
        \\fn alignBack(p: *const anyopaque) *const u16 {
        \\    return @ptrCast(@alignCast(p));
        \\}
        \\const from_align_cast = alignBack(&h).*;
        \\const pc: *const u8 = &c;
        \\fn ptrBack(p: *const anyopaque) *const *const u8 {
        \\    return @ptrCast(@alignCast(p));
        \\}
        \\const from_double_pointer = ptrBack(@ptrCast(&pc)).*.*;
        \\const big: u8 = 200;
        \\fn asSigned(p: *const anyopaque) *const i8 {
        \\    return @ptrCast(p);
        \\}
        \\const big_erased: *const anyopaque = &big;
        \\const signed_param = asSigned(&big).*;
        \\const signed_global = asSigned(big_erased).*;
    , &.{
        .{ "from_param", "u8 = 3" },
        .{ "from_coerced_global", "u8 = 3" },
        .{ "from_cast_global", "u8 = 3" },
        .{ "from_local", "u8 = 3" },
        // The pointer cast back points to the variable
        .{ "from_var", "u8 = 9" },
        .{ "from_optional", "u8 = 3" },
        .{ "from_align_cast", "u16 = 513" },
        .{ "from_double_pointer", "u8 = 3" },
        // Another type: the compiler reinterprets the memory, which is not evaluated
        .{ "signed_param", "i8" },
        .{ "signed_global", "i8" },
    });
}

test "a pointer erased to *anyopaque keeps its value when cast back: arrays, ranges, strings and structs" {
    // Erased pointers represented by elements (array pointers, string literals) or to a range
    // of storage were not recognized as the pointers they were erased from.
    try expectTypes(
        \\const arr: [3]u8 = .{ 1, 2, 3 };
        \\fn arrBack(p: *const anyopaque) *const [3]u8 {
        \\    return @ptrCast(p);
        \\}
        \\fn manyBack(p: *const anyopaque) [*]const u8 {
        \\    return @ptrCast(p);
        \\}
        \\const arr_erased: *const anyopaque = &arr;
        \\const many_erased: *const anyopaque = @as([*]const u8, &arr);
        \\const elem_param = arrBack(&arr)[1];
        \\const elem_global = arrBack(arr_erased)[2];
        \\const many_param = manyBack(&arr)[1];
        \\const many_global = manyBack(arr_erased)[0];
        \\const many_many_global = manyBack(many_erased)[2];
        \\const str_erased: *const anyopaque = "abc";
        \\fn strBack(p: *const anyopaque) *const [3:0]u8 {
        \\    return @ptrCast(p);
        \\}
        \\const str_global = strBack(str_erased)[0];
        \\const str_param = strBack("xyz")[1];
        \\const range_write = blk: {
        \\    var buf: [4]u8 = .{ 1, 2, 3, 4 };
        \\    const e: *anyopaque = buf[1..3];
        \\    const q: *[2]u8 = @ptrCast(e);
        \\    q[1] = 9;
        \\    break :blk buf[2];
        \\};
        \\const range_ptr = blk: {
        \\    const sl: []const u8 = arr[1..];
        \\    const e: *const anyopaque = sl.ptr;
        \\    const m: [*]const u8 = @ptrCast(e);
        \\    break :blk m[1];
        \\};
        \\const slice_elem = blk: {
        \\    const sl: []const u8 = &arr;
        \\    const e: *const anyopaque = &sl[2];
        \\    const q: *const u8 = @ptrCast(e);
        \\    break :blk q.*;
        \\};
        \\const S = struct { a: u8, b: u16 };
        \\const s: S = .{ .a = 1, .b = 2 };
        \\fn structBack(p: *const anyopaque) *const S {
        \\    return @ptrCast(@alignCast(p));
        \\}
        \\const s_erased: *const anyopaque = &s;
        \\const field_param = structBack(&s).b;
        \\const field_global = structBack(s_erased).b;
        \\fn asFirst(p: *const anyopaque) *const u8 {
        \\    return @ptrCast(p);
        \\}
        \\const first_of_array = asFirst(&arr).*;
    , &.{
        .{ "elem_param", "u8 = 2" },
        .{ "elem_global", "u8 = 3" },
        .{ "many_param", "u8 = 2" },
        .{ "many_global", "u8 = 1" },
        .{ "many_many_global", "u8 = 3" },
        .{ "str_global", "u8 = 97" },
        .{ "str_param", "u8 = 121" },
        .{ "range_write", "u8 = 9" },
        .{ "range_ptr", "u8 = 3" },
        .{ "slice_elem", "u8 = 3" },
        .{ "field_param", "u16 = 2" },
        .{ "field_global", "u16 = 2" },
        // An element of another shape: the compiler restructures the array, which is not
        // evaluated
        .{ "first_of_array", "u8" },
    });
}

test "a pointer erased to *anyopaque keeps its value when cast back: optionals and error unions" {
    // Optionals and error unions are represented by their payloads, so an erased pointer to one
    // did not point to a value of the type cast back to.
    try expectTypes(
        \\const none: ?u8 = null;
        \\const three: ?u8 = 3;
        \\const yes: ?bool = true;
        \\fn optBack(p: *const anyopaque) *const ?u8 {
        \\    return @ptrCast(p);
        \\}
        \\fn boolBack(p: *const anyopaque) *const ?bool {
        \\    return @ptrCast(p);
        \\}
        \\const none_erased: *const anyopaque = &none;
        \\const yes_erased: *const anyopaque = &yes;
        \\const none_param = optBack(&none).*;
        \\const none_global = optBack(none_erased).*;
        \\const three_param = optBack(&three).*;
        \\const yes_param = boolBack(&yes).*;
        \\const yes_global = boolBack(yes_erased).*;
        \\const three_erased: ?*const anyopaque = &three;
        \\fn optPtrBack(p: ?*const anyopaque) ?*const ?u8 {
        \\    return @ptrCast(p);
        \\}
        \\const three_global = optPtrBack(three_erased).?.*;
        \\const E = error{Bad};
        \\const ok: E!bool = true;
        \\const bad: E!u8 = error.Bad;
        \\fn okBack(p: *const anyopaque) *const E!bool {
        \\    return @ptrCast(@alignCast(p));
        \\}
        \\fn badBack(p: *const anyopaque) *const E!u8 {
        \\    return @ptrCast(@alignCast(p));
        \\}
        \\const ok_erased: *const anyopaque = &ok;
        \\const bad_erased: *const anyopaque = &bad;
        \\const ok_param = okBack(&ok).*;
        \\const ok_global = okBack(ok_erased).*;
        \\const bad_global = badBack(bad_erased).*;
        \\const err: anyerror = error.Bad;
        \\const err_erased: *const anyopaque = &err;
        \\fn errBack(p: *const anyopaque) *const anyerror {
        \\    return @ptrCast(@alignCast(p));
        \\}
        \\const err_global = errBack(err_erased).*;
        \\const payload = blk: {
        \\    var opt: ?u8 = 4;
        \\    if (opt) |*x| {
        \\        const e: *anyopaque = x;
        \\        const q: *u8 = @ptrCast(e);
        \\        q.* += 1;
        \\    }
        \\    break :blk opt;
        \\};
        \\const eu_result = blk: {
        \\    var x: u32 = 5;
        \\    const e: *anyopaque = &x;
        \\    const r: anyerror!*u32 = @ptrCast(@alignCast(e));
        \\    const p = r catch unreachable;
        \\    break :blk p.*;
        \\};
        \\const opt_result = blk: {
        \\    var x: u32 = 6;
        \\    const e: *anyopaque = &x;
        \\    const r: ?*u32 = @ptrCast(@alignCast(e));
        \\    break :blk r.?.*;
        \\};
    , &.{
        .{ "none_param", "?u8 = null" },
        .{ "none_global", "?u8 = null" },
        .{ "three_param", "?u8 = 3" },
        .{ "yes_param", "?bool = true" },
        .{ "yes_global", "?bool = true" },
        .{ "three_global", "?u8 = 3" },
        .{ "ok_param", "error{Bad}!bool = true" },
        .{ "ok_global", "error{Bad}!bool = true" },
        .{ "bad_global", "error{Bad}!u8 = error.Bad" },
        .{ "err_global", "anyerror = error.Bad" },
        // The pointer to the payload points to the optional
        .{ "payload", "?u8 = 5" },
        // A result type that is an error union or an optional pointer: the cast back gives the
        // pointer, which is then wrapped
        .{ "eu_result", "u32 = 5" },
        .{ "opt_result", "u32 = 6" },
    });
}

test "a pointer erased to *anyopaque keeps its value when cast back: field default values" {
    // `default_value_ptr` of a field of an optional type points to the payload representation of
    // the default value, which did not have the type cast back to.
    try expectStdTypes(
        \\const E = error{Bad};
        \\const Color = enum { red, green };
        \\const D = struct { x: ?u8 = null, y: ?bool = true, z: u8 = 5, e: E!bool = true, f: E!u8 = error.Bad, g: Color = .green };
        \\const fields = @typeInfo(D).@"struct".field_attrs;
        \\const default_x = @as(*const ?u8, @ptrCast(fields[0].default_value_ptr.?)).*;
        \\const default_y = @as(*const ?bool, @ptrCast(fields[1].default_value_ptr.?)).*;
        \\const default_z = fields[2].defaultValue(u8).?;
        \\const default_e = fields[3].defaultValue(E!bool).?;
        \\const default_f = @as(*const E!u8, @ptrCast(@alignCast(fields[4].default_value_ptr.?))).*;
        \\const default_g = fields[5].defaultValue(Color).?;
    , &.{
        .{ "default_x", "?u8 = null" },
        .{ "default_y", "?bool = true" },
        .{ "default_z", "u8 = 5" },
        .{ "default_e", "error{Bad}!bool = true" },
        .{ "default_f", "error{Bad}!u8 = error.Bad" },
        .{ "default_g", "Color = .green" },
    });
}

test "a function chosen by switching on an enum defined in the signature" {
    // The tag recorded by the instance kept the type of another instance, so no prong was chosen
    // and the error set became anyerror.
    try expectTypes(
        \\fn add(comptime T: type, a: T, b: T) error{Overflow}!T { return a + b; }
        \\fn sub(comptime T: type, a: T, b: T) error{Overflow}!T { return a - b; }
        \\fn pick(comptime s: enum { pos, neg }) !u8 {
        \\    const f = switch (s) { .pos => add, .neg => sub };
        \\    return f(u8, 1, 2);
        \\}
        \\const r = pick(.pos);
        \\fn g() void { _ = r; }
    , &.{
        .{ "r", "error{Overflow}!u8 = 3" },
    });
}

test "the address of a place is const unless the place can be written" {
    // A pointer to a constant had a mutable type, so the evaluated value of the initializer was
    // discarded as having a different type than inference gave.
    try expectTypes(
        \\const S = struct { x: u8 };
        \\const of_const = blk: {
        \\    const final: [2:0]u8 = "ab".*;
        \\    break :blk &final;
        \\};
        \\const of_copy = blk: {
        \\    var buf: [2:0]u8 = "ab".*;
        \\    buf[0] = 'c';
        \\    const final = buf;
        \\    break :blk &final;
        \\};
        \\const field_of_const = blk: {
        \\    const s: S = .{ .x = 1 };
        \\    break :blk (&s.x).*;
        \\};
        \\fn g() void { _ = .{ of_const, of_copy, field_of_const }; }
    , &.{
        .{ "of_const", "*const [2:0]u8 = \"ab\"" },
        .{ "of_copy", "*const [2:0]u8 = \"cb\"" },
        .{ "field_of_const", "u8 = 1" },
    });
}

test "the sentinel element of an array" {
    try expectTypes(
        \\const read = blk: {
        \\    const buf: [2:0]u8 = "ab".*;
        \\    break :blk buf[2];
        \\};
        \\const same = blk: {
        \\    var buf: [2:0]u8 = "ab".*;
        \\    buf[2] = 0;
        \\    break :blk buf;
        \\};
        \\const other = blk: {
        \\    var buf: [2:0]u8 = "ab".*;
        \\    buf[2] = 1;
        \\    break :blk buf;
        \\};
        \\fn g() void { _ = .{ read, same, other }; }
    , &.{
        .{ "read", "u8 = 0" },
        .{ "same", "[2:0]u8 = \"ab\"" },
        // Storing a value other than the sentinel is a compile error
        .{ "other", "[2:0]u8" },
    });
}

test "the sentinel element read through pointers, slices and many-item pointers" {
    try expectTypes(
        \\const many: [*:0]const u8 = "hello";
        \\const slice: [:0]const u8 = "hello";
        \\const plain: [*]const u8 = "hello";
        \\const c_ptr: [*c]const u8 = "hey";
        \\const unterminated: [*c]const u8 = &[_]u8{ 1, 2, 3 };
        \\const no_sentinel: []const u8 = "hello";
        \\const seven: *const [2:7]u8 = &[_:7]u8{ 1, 2 };
        \\const wide: [:0]const u16 = &[_:0]u16{ 1, 2, 3 };
        \\const lit = "hello"[5];
        \\const via_many = many[5];
        \\const via_slice = slice[5];
        \\const via_plain = plain[5];
        \\const via_c = c_ptr[3];
        \\const via_unterminated = unterminated[3];
        \\const via_seven = seven[2];
        \\const via_wide = wide[3];
        \\const past_lit = "hello"[6];
        \\const past_many = many[6];
        \\const past_slice = slice[6];
        \\const past_len = no_sentinel[5];
        \\const in_range = blk: {
        \\    var buf = [_]u8{ 'a', 'b', 0, 'd' };
        \\    const s: [:0]u8 = buf[0..2 :0];
        \\    break :blk s[2];
        \\};
        \\const range_to_end = blk: {
        \\    var buf: [3:0]u8 = "abc".*;
        \\    const s: [:0]u8 = buf[1..];
        \\    break :blk s[2];
        \\};
        \\const range_written = blk: {
        \\    var buf = [_]u8{ 'a', 'b', 0, 'd' };
        \\    const s: [:0]u8 = buf[0..2 :0];
        \\    buf[2] = 'x';
        \\    break :blk s[2];
        \\};
        \\const range_many = blk: {
        \\    var buf = [_]u8{ 'a', 'b', 0, 'd' };
        \\    const s: [:0]u8 = buf[0..2 :0];
        \\    break :blk s.ptr[2];
        \\};
        \\const range_past = blk: {
        \\    var buf = [_]u8{ 'a', 'b', 0, 'd' };
        \\    const s: [:0]u8 = buf[0..2 :0];
        \\    break :blk s[3];
        \\};
        \\const range_no_sentinel = blk: {
        \\    var buf = [_]u8{ 1, 2, 3, 4 };
        \\    const s: []u8 = buf[0..2];
        \\    break :blk s[2];
        \\};
        \\fn scan(p: [*:0]const u8) usize {
        \\    var i: usize = 0;
        \\    while (p[i] != 0) i += 1;
        \\    return i;
        \\}
        \\const scanned = scan("abcd");
    , &.{
        .{ "lit", "u8 = 0" },
        .{ "via_many", "u8 = 0" },
        .{ "via_slice", "u8 = 0" },
        // A many-item pointer reads the storage it points to, whose sentinel the pointer type
        // need not have
        .{ "via_plain", "u8 = 0" },
        .{ "via_c", "u8 = 0" },
        .{ "via_unterminated", "u8" },
        .{ "via_seven", "u8 = 7" },
        .{ "via_wide", "u16 = 0" },
        // Indices past the sentinel, and index `len` of a slice without one, are compile errors
        .{ "past_lit", "u8" },
        .{ "past_many", "u8" },
        .{ "past_slice", "u8" },
        .{ "past_len", "u8" },
        // A range of local storage reads the element after it from the containing array: what
        // that array holds there, which need not be the sentinel once overwritten
        .{ "in_range", "u8 = 0" },
        .{ "range_to_end", "u8 = 0" },
        .{ "range_written", "u8 = 120" },
        .{ "range_many", "u8 = 0" },
        .{ "range_past", "u8" },
        .{ "range_no_sentinel", "u8" },
        .{ "scanned", "usize = 4" },
    });
}

test "inline calls with comptime-known arguments have comptime-known results" {
    try expectTypes(
        \\inline fn twice(x: u32) u32 { return x * 2; }
        \\var global: u32 = 1;
        \\inline fn readGlobal() u32 { return global; }
        \\fn g(y: u32) void {
        \\    const known = twice(4);
        \\    const runtime_arg = twice(y);
        \\    const runtime_body = readGlobal();
        \\    _ = .{ known, runtime_arg, runtime_body };
        \\}
    , &.{
        .{ "known", "u32 = 8" },
        .{ "runtime_arg", "u32" },
        .{ "runtime_body", "u32" },
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

test "@This() in a generic body is the abstract instance, like the written call" {
    // `@This()` was the bare function name `Pair` and counted as a concrete type
    try expectTypes(
        \\fn Pair(comptime A: type, comptime B: type) type {
        \\    return struct {
        \\        a: A,
        \\        b: B,
        \\        const Self = @This();
        \\        fn swap(p: @This(), s: Self) Pair(B, A) {
        \\            const r: Pair(B, A) = .{ .a = p.b, .b = p.a };
        \\            const me = p;
        \\            const q: Pair(A, B) = p;
        \\            const same = @This() == Pair(A, B);
        \\            const tn = @typeName(@This());
        \\            _ = .{ me, q, s, same, tn };
        \\            return r;
        \\        }
        \\    };
        \\}
    , &.{
        .{ "p", "Pair(A, B)" },
        .{ "s", "Pair(A, B)" },
        .{ "me", "Pair(A, B)" },
        .{ "q", "Pair(A, B)" },
        .{ "r", "Pair(B, A)" },
        // As in the compiler
        .{ "same", "bool = true" },
        // The name depends on the instance, but is always a comptime-known string
        .{ "tn", "*const [_:0]u8" },
    });
}

const signature_container_src =
    \\const S = struct { v: u8 };
    \\fn f(s: *S, comptime kind: enum { a, b }, data: switch (kind) { .a => u8, .b => u16 }, n: u32) struct { x: u8 } {
    \\    const own = s;
    \\    const first = data;
    \\    const size = n;
    \\    _ = .{ own, first, size };
    \\    return .{ .x = 1 };
    \\}
    \\fn g(s: *S) void {
    \\    const viaA = f(s, .a, 1, 2);
    \\    const field = viaA.x;
    \\    _ = field;
    \\}
;

test "a container in a function prototype keeps parameters and instances resolved" {
    try expectTypes(signature_container_src, &.{
        .{ "own", "*S" },
        .{ "size", "u32" },
        .{ "field", "u8" },
    });
}

test "a container in a function prototype computes its abstract instance once" {
    // The function's type and parameters are evaluated from the container, whose abstract instance
    // reads them: every read computed that cycle again
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const src = signature_container_src;
    const f = try w.add("/p/main.zig", src);
    for ([_][]const u8{ "own", "first", "size", "viaA", "field" }) |name| _ = try typeAt(&w, f.file, src, name, 0);
    try testing.expectEqual(1, w.db.executions(queries.SignatureInst));
}

test "unknown parts stay unknown" {
    try expectTypes(
        \\fn opaqueFn(x: u8) type { _ = x; return u8; }
        \\fn g(n: u8) void {
        \\    const T = opaqueFn(n);
        \\    _ = T;
        \\}
    , &.{
        // Function returning type: still evaluated per instance when the argument is not a comptime
        // value (computable when the body does not depend on the parameter)
        .{ "T", "type = u8" },
    });
}

/// Number of items the InternPool grows by while computing the value of `r`; `{d}` in the source
/// is the loop count
fn loopInternGrowth(comptime n: u32) !usize {
    const src = std.fmt.comptimePrint(
        \\fn mix(x: u64) u64 {{
        \\    return x *% 2654435761;
        \\}}
        \\fn slow() u64 {{
        \\    @setEvalBranchQuota(1_000_000);
        \\    var s: u64 = 0;
        \\    var i: u64 = 0;
        \\    while (i < {d}) : (i += 1) s +%= i *% 2654435761;
        \\    i = 0;
        \\    while (i < {d}) : (i += 1) s +%= mix(i);
        \\    return s;
        \\}}
        \\fn f() void {{
        \\    const r = comptime slow();
        \\    _ = r;
        \\}}
    , .{ n, n });
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.add("/p/main.zig", src);
    const before = w.ip.count();
    try testing.expect(std.mem.startsWith(u8, try typeAt(&w, f.file, src, "r", 0), "u64 = "));
    return w.ip.count() - before;
}

test "comptime loop intermediates are not interned" {
    // Intermediate results of integer arithmetic in loops used to be interned one by one: the
    // InternPool grew with the iteration count, and large comptime computations triggered a
    // whole-generation reclaim
    try testing.expectEqual(try loopInternGrowth(100), try loopInternGrowth(1000));
}

test "comptime recursive calls with integer arguments reuse earlier results" {
    // Calls whose integer arguments are not interned cache their results by argument: naive
    // recursion does not run an exponential number of times
    try expectTypes(
        \\fn fib(n: u64) u64 {
        \\    return if (n < 2) n else fib(n - 1) + fib(n - 2);
        \\}
        \\fn f() void {
        \\    const r = comptime fib(80);
        \\    _ = r;
        \\}
    , &.{
        .{ "r", "u64 = 23416728348467685" },
    });
}

test "comptime calls run errdefer when returning an error" {
    // Prevents skipping `errdefer` on error returns; expected values are the results of
    // zig 0.17.0
    try expectTypes(
        \\fn viaReturn(p: *u32) !void {
        \\    errdefer p.* += 100;
        \\    p.* += 1;
        \\    return error.Fail;
        \\}
        \\fn fails() !void {
        \\    return error.Fail;
        \\}
        \\fn viaTry(p: *u32) !void {
        \\    errdefer p.* += 100;
        \\    p.* += 1;
        \\    try fails();
        \\}
        \\fn nested(p: *u32) !void {
        \\    defer p.* *= 2;
        \\    errdefer p.* += 10;
        \\    {
        \\        errdefer p.* += 1000;
        \\        p.* += 1;
        \\    }
        \\    {
        \\        errdefer p.* += 3;
        \\        try fails();
        \\    }
        \\}
        \\fn succeeds(p: *u32) !void {
        \\    errdefer p.* += 100;
        \\    p.* += 1;
        \\}
        \\fn run(comptime which: u8) u32 {
        \\    var x: u32 = 0;
        \\    switch (which) {
        \\        0 => viaReturn(&x) catch {},
        \\        1 => viaTry(&x) catch {},
        \\        2 => nested(&x) catch {},
        \\        else => succeeds(&x) catch {},
        \\    }
        \\    return x;
        \\}
        \\const r = run(0);
        \\const t = run(1);
        \\const n = run(2);
        \\const ok = run(3);
    , &.{
        .{ "r", "u32 = 101" },
        .{ "t", "u32 = 101" },
        .{ "n", "u32 = 28" },
        .{ "ok", "u32 = 1" },
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
        // An out-of-range result is a compile error: no value is given
        .{ "overflow", "u8" },
        .{ "e", "i8 = -128" },
        .{ "shifted", "u8 = 2" },
        .{ "inverted", "u8 = 254" },
    });
}

test "arithmetic operands have no result type" {
    // The expected values match the compiler (verified with @compileError in a comptime block)
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
        // Computing with the result type u8 would drop the high bits in the left shift, giving 15
        .{ "m", "u8 = 255" },
        .{ "w", "u8 = 150" },
        .{ "r", "f32 = 0" },
        .{ "n", "i8 = 100" },
        // The u32 multiplication overflows (compile error): no value; must not be computed as u64
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
        // The f32 0.1 is not equal to the literal: takes the else branch
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
        // The else prong gets the remaining errors
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
        // A false payload of `?bool` and a successful `E!bool` are still non-null / success
        .{ "y", "u8 = 1" },
        .{ "z", "u8 = 3" },
        // A failed error union still takes the else branch
        .{ "q", "u16 = 6" },
    });
}

test "a non-null optional holding a null optional is not null" {
    // Expected values are the results of zig 0.17.0 and 0.17.1 (a `pub const` of each name,
    // printed with `std.fmt.comptimePrint("{any}", ...)`); a null `?u8` coerced to `??u8` must
    // not be evaluated as the null of `??u8`
    try expectTypes(
        \\fn wrap(x: ?u8) ??u8 {
        \\    return x;
        \\}
        \\fn wrapLocal(x: ?u8) ??u8 {
        \\    const r: ??u8 = x;
        \\    return r;
        \\}
        \\fn wrapT(comptime T: type, x: T) ?T {
        \\    return x;
        \\}
        \\fn isNullOuter(x: ??u8) bool {
        \\    return x == null;
        \\}
        \\fn optParam(comptime T: type, x: ?T) bool {
        \\    return x == null;
        \\}
        \\fn viaAnytype(x: anytype) bool {
        \\    const y: ??u8 = x;
        \\    return y == null;
        \\}
        \\fn loopCount(o0: ??u8) u8 {
        \\    var o = o0;
        \\    var n: u8 = 0;
        \\    while (o) |y| {
        \\        n += 1;
        \\        if (y == null) o = null else o = @as(?u8, null);
        \\    }
        \\    return n;
        \\}
        \\const inner_null: ?u8 = null;
        \\const outer_some_null: ??u8 = inner_null;
        \\const outer_null: ??u8 = null;
        \\const S = struct { a: ??u8 = inner_null, b: ??u8 = null };
        \\const S2 = struct { a: ??u8 };
        \\const ret_eq = wrap(null) == null;
        \\const ret_local_eq = wrapLocal(null) == null;
        \\const as_eq = @as(??u8, inner_null) == null;
        \\const some_eq = outer_some_null == null;
        \\const some_ne = outer_some_null != null;
        \\const outer_eq = outer_null == null;
        \\const shown = outer_some_null;
        \\const unwrapped = outer_some_null.?;
        \\const unwrapped_eq = outer_some_null.? == null;
        \\const orelse_eq = (outer_some_null orelse @as(?u8, 7)) == null;
        \\const orelse_outer = (outer_null orelse @as(?u8, 7)).?;
        \\const if_capture = if (outer_some_null) |y| y == null else false;
        \\const if_outer = if (outer_null) |_| 1 else 2;
        \\const while_capture = blk: {
        \\    var n: u8 = 0;
        \\    var it: ??u8 = inner_null;
        \\    while (it) |y| : (it = null) {
        \\        if (y == null) n += 1;
        \\    }
        \\    break :blk n;
        \\};
        \\const loop_some_null = loopCount(inner_null);
        \\const loop_five = loopCount(@as(?u8, 5));
        \\const loop_null = loopCount(null);
        \\const arg = isNullOuter(inner_null);
        \\const arg_lit = isNullOuter(null);
        \\const generic_ret = wrapT(?u8, inner_null) == null;
        \\const generic_param = optParam(?u8, inner_null);
        \\const generic_param_lit = optParam(?u8, null);
        \\const anytype_arg = viaAnytype(inner_null);
        \\const anytype_lit = viaAnytype(null);
        \\const default_a = (S{}).a == null;
        \\const default_b = (S{}).b == null;
        \\const init_a = (S2{ .a = inner_null }).a == null;
        \\const init_lit = (S2{ .a = null }).a == null;
        \\const elem0 = ([_]??u8{ inner_null, null })[0] == null;
        \\const elem1 = ([_]??u8{ inner_null, null })[1] == null;
        \\const triple_inner = blk: {
        \\    const t: ???u8 = outer_some_null;
        \\    break :blk t.?.? == null;
        \\};
        \\const triple_outer = blk: {
        \\    const t: ???u8 = outer_some_null;
        \\    break :blk t == null;
        \\};
        \\const mixed_some = outer_some_null == inner_null;
        \\const mixed_outer = outer_null == inner_null;
        \\const mixed_rev = inner_null == outer_some_null;
        \\const ptr_payload = blk: {
        \\    var o: ??u8 = @as(?u8, 5);
        \\    if (o) |*p| p.* = null;
        \\    break :blk o == null;
        \\};
        \\const ptr_payload_inner = blk: {
        \\    var o: ??u8 = @as(?u8, 5);
        \\    if (o) |*p| p.* = null;
        \\    break :blk o.? == null;
        \\};
        \\const view_payload = blk: {
        \\    var o: ??u8 = @as(?u8, null);
        \\    _ = &o;
        \\    if (o) |*p| {
        \\        const v: *[1]?u8 = p;
        \\        break :blk v[0] == null;
        \\    }
        \\    break :blk false;
        \\};
        \\const view_payload_deref = blk: {
        \\    var o: ??u8 = @as(?u8, null);
        \\    _ = &o;
        \\    if (o) |*p| {
        \\        const v: *[1]?u8 = p;
        \\        break :blk v.*[0] == null;
        \\    }
        \\    break :blk false;
        \\};
        \\const view_payload_write = blk: {
        \\    var o: ??u8 = @as(?u8, null);
        \\    if (o) |*p| {
        \\        const v: *[1]?u8 = p;
        \\        v[0] = 5;
        \\    }
        \\    break :blk o.?.?;
        \\};
        \\const assign_unwrap = blk: {
        \\    var o: ??u8 = @as(?u8, 5);
        \\    o.? = null;
        \\    break :blk o == null;
        \\};
        \\const eu_payload = blk: {
        \\    const e: anyerror!??u8 = inner_null;
        \\    const v = e catch unreachable;
        \\    break :blk v == null;
        \\};
        \\const opt_eu = blk: {
        \\    const x: anyerror!?u8 = inner_null;
        \\    const o: ?(anyerror!?u8) = x;
        \\    break :blk o == null;
        \\};
        \\const opt_eu_payload = blk: {
        \\    const x: anyerror!?u8 = inner_null;
        \\    const o: ?(anyerror!?u8) = x;
        \\    const p = o.? catch unreachable;
        \\    break :blk p == null;
        \\};
        \\const ptr_keep = blk: {
        \\    const a: ?*u8 = null;
        \\    const b: ?*const u8 = a;
        \\    break :blk b == null;
        \\};
    , &.{
        .{ "ret_eq", "bool = false" },
        .{ "ret_local_eq", "bool = false" },
        .{ "as_eq", "bool = false" },
        .{ "some_eq", "bool = false" },
        .{ "some_ne", "bool = true" },
        .{ "outer_eq", "bool = true" },
        // Printed as its payload, as the compiler does
        .{ "shown", "??u8 = null" },
        .{ "unwrapped", "?u8 = null" },
        .{ "unwrapped_eq", "bool = true" },
        .{ "orelse_eq", "bool = true" },
        .{ "orelse_outer", "u8 = 7" },
        .{ "if_capture", "bool = true" },
        .{ "if_outer", "comptime_int = 2" },
        .{ "while_capture", "u8 = 1" },
        .{ "loop_some_null", "u8 = 1" },
        .{ "loop_five", "u8 = 2" },
        .{ "loop_null", "u8 = 0" },
        .{ "arg", "bool = false" },
        .{ "arg_lit", "bool = true" },
        .{ "generic_ret", "bool = false" },
        .{ "generic_param", "bool = false" },
        .{ "generic_param_lit", "bool = true" },
        .{ "anytype_arg", "bool = false" },
        .{ "anytype_lit", "bool = true" },
        .{ "default_a", "bool = false" },
        .{ "default_b", "bool = true" },
        .{ "init_a", "bool = false" },
        .{ "init_lit", "bool = true" },
        .{ "elem0", "bool = false" },
        .{ "elem1", "bool = true" },
        .{ "triple_inner", "bool = true" },
        .{ "triple_outer", "bool = false" },
        // Compared at the peer type `??u8`
        .{ "mixed_some", "bool = true" },
        .{ "mixed_outer", "bool = false" },
        .{ "mixed_rev", "bool = true" },
        .{ "ptr_payload", "bool = false" },
        .{ "ptr_payload_inner", "bool = true" },
        // A payload pointer coerced to `*[1]?u8` reads and writes the payload through the view
        .{ "view_payload", "bool = true" },
        .{ "view_payload_deref", "bool = true" },
        .{ "view_payload_write", "u8 = 5" },
        .{ "assign_unwrap", "bool = false" },
        .{ "eu_payload", "bool = false" },
        .{ "opt_eu", "bool = false" },
        .{ "opt_eu_payload", "bool = true" },
        // An optional that coerces in memory keeps its null
        .{ "ptr_keep", "bool = true" },
    });
}

test "comptime arguments holding a null optional payload make another instance than null" {
    // Expected values are the results of zig 0.17.0 and 0.17.1; `Box(inner_null)` must not be
    // the instance of `Box(null)`
    try expectTypes(
        \\fn Box(comptime x: ??u8) type {
        \\    return struct {
        \\        pub const v = x;
        \\    };
        \\}
        \\const inner_null: ?u8 = null;
        \\const distinct = Box(inner_null) == Box(null);
        \\const some_null = Box(inner_null).v == null;
        \\const outer_null = Box(null).v == null;
    , &.{
        .{ "distinct", "bool = false" },
        .{ "some_null", "bool = false" },
        .{ "outer_null", "bool = true" },
    });
}

test "a null C pointer coerced to an optional pointer is not null" {
    // Expected values are the results of zig 0.17.0 and 0.17.1: the compiler represents a null C
    // pointer as a pointer to address 0, and coercing it to an optional pointer wraps it as the
    // payload of a non-null optional (`InternPool.getCoerced`)
    try expectTypes(
        \\const c_null: [*c]const u8 = null;
        \\fn takesOpt(o: ?[*]const u8) bool {
        \\    return o == null;
        \\}
        \\const many = blk: {
        \\    const o: ?[*]const u8 = c_null;
        \\    break :blk o == null;
        \\};
        \\const one = blk: {
        \\    const o: ?*const u8 = c_null;
        \\    break :blk o == null;
        \\};
        \\const as_many = @as(?[*]const u8, c_null) == null;
        \\const c_eq = c_null == null;
        \\const if_taken = blk: {
        \\    const o: ?[*]const u8 = c_null;
        \\    break :blk if (o) |_| 1 else 2;
        \\};
        \\const param = takesOpt(c_null);
    , &.{
        .{ "many", "bool = false" },
        .{ "one", "bool = false" },
        .{ "as_many", "bool = false" },
        .{ "c_eq", "bool = true" },
        .{ "if_taken", "comptime_int = 1" },
        .{ "param", "bool = false" },
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
        // Names known at compile time are string literals
        .{ "v_typename", "*const [2:0]u8 = \"u8\"" },
        .{ "v_tagname", "*const [2:0]u8 = \"yy\"" },
        .{ "v_errname", "*const [3:0]u8 = \"Foo\"" },
        // A runtime operand still gives a slice
        .{ "v_tagname_rt", "[:0]const u8" },
    });
}
test "@tagName and @errorName of comptime-known operands without an inferred value are string literals" {
    // Prevents typing them as the runtime `[:0]const u8`, which dropped the interpreter's value.
    // Expected values: zig 0.17.0 and 0.17.1 give the same result for each name.
    try expectTypes(
        \\const U = union(enum) { a: u8, b: struct { x: u32 = 1 } };
        \\const E = enum { x, y };
        \\fn fail() anyerror {
        \\    return error.Oops;
        \\}
        \\pub const union_name = @tagName(U{ .a = 1 });
        \\pub const default_name = @tagName(U{ .b = .{} });
        \\pub const coerced_name = @tagName(@as(U, .{ .a = 3 }));
        \\pub const from_int_name = @tagName(@as(E, @enumFromInt(1)));
        \\pub const block_name = blk: {
        \\    const u: U = .{ .a = 2 };
        \\    break :blk @tagName(u);
        \\};
        \\pub const error_name = @errorName(fail());
        \\fn probe(u: U) void {
        \\    const in_comptime = comptime @tagName(U{ .b = .{} });
        \\    const in_comptime_block = comptime blk: {
        \\        const name = @tagName(U{ .a = 1 });
        \\        break :blk name;
        \\    };
        \\    const runtime_union = @tagName(u);
        \\    _ = .{ in_comptime, in_comptime_block, runtime_union };
        \\}
        \\comptime {
        \\    _ = &probe;
        \\}
    , &.{
        .{ "union_name", "*const [1:0]u8 = \"a\"" },
        .{ "default_name", "*const [1:0]u8 = \"b\"" },
        .{ "coerced_name", "*const [1:0]u8 = \"a\"" },
        .{ "from_int_name", "*const [1:0]u8 = \"y\"" },
        .{ "block_name", "*const [1:0]u8 = \"a\"" },
        .{ "error_name", "*const [4:0]u8 = \"Oops\"" },
        .{ "in_comptime", "*const [1:0]u8 = \"b\"" },
        .{ "name", "*const [1:0]u8 = \"a\"" },
        .{ "in_comptime_block", "*const [1:0]u8 = \"a\"" },
        // A runtime operand still gives a slice
        .{ "runtime_union", "[:0]const u8" },
    });
}

test "@typeName gives the compiler's fully qualified name" {
    // Prevents giving the hover display name (`"E"` instead of `"main.E"`)
    var env = @import("../project/ZigEnv.zig").query(testing.allocator, testing.io, null) catch return error.SkipZigTest;
    defer env.deinit(testing.allocator);
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const std_root_path = try std.fs.path.join(testing.allocator, &.{ env.std_dir, "std.zig" });
    defer testing.allocator.free(std_root_path);
    const std_root = try w.vfs.intern(std_root_path);
    const src =
        \\const std = @import("std");
        \\const thing = @import("util/thing.zig");
        \\const E = enum { a, b };
        \\const S = struct {
        \\    const Inner = struct {};
        \\};
        \\fn Box(comptime T: type) type {
        \\    return struct { v: T };
        \\}
        \\fn Shared(comptime T: type) type {
        \\    _ = T;
        \\    return struct {};
        \\}
        \\fn Make() type {
        \\    return struct {};
        \\}
        \\fn Out(comptime T: type) type {
        \\    return struct {
        \\        const In = struct { t: T };
        \\        const Plain = struct {};
        \\        fn G(comptime U: type) type {
        \\            return struct { u: U, t: T };
        \\        }
        \\    };
        \\}
        \\fn Gen(comptime n: u8, comptime b: bool, comptime e: E, comptime o: ?u8, comptime l: @EnumLiteral(), comptime x: ?type) type {
        \\    return struct {
        \\        const k = .{ n, b, e, o, l, x };
        \\    };
        \\}
        \\const n_E = @typeName(E);
        \\const n_inner = @typeName(S.Inner);
        \\const n_box = @typeName(Box(u8));
        \\const n_box2 = @typeName(Box(S.Inner));
        \\const n_make = @typeName(Make());
        \\const n_in = @typeName(Out(u8).In);
        \\const n_g = @typeName(Out(u8).G(u16));
        \\const n_gen = @typeName(Gen(3, true, .b, 5, .q, null));
        \\const n_list = @typeName(std.ArrayList(u8));
        \\const n_alloc = @typeName(std.mem.Allocator);
        \\const n_std = @typeName(std);
        \\const n_thing = @typeName(thing.Thing);
        \\const n_file = @typeName(thing);
        \\const n_lit = @typeName(@TypeOf(.x));
        \\const n_null = @typeName(@TypeOf(null));
        \\const n_tuple = @typeName(struct { u8, ?*const [2:0]u8 });
        \\const n_err = @typeName(error{ B, A }!S);
        \\const n_anon = @typeName(@TypeOf(.{ .a = 1 }));
        \\const n_shared = @typeName(Shared(u8));
        \\const n_plain = @typeName(Out(u8).Plain);
        \\const is_list = std.mem.startsWith(u8, @typeName(std.ArrayList(u8)), "array_list.");
        \\const branch = if (is_list) @as(u8, 1) else @as(u16, 2);
        \\const eqname = @intFromBool(std.mem.eql(u8, @typeName(E), "main.E"));
        \\fn f() void {
        \\    const L = struct {};
        \\    const n_local = @typeName(L);
        \\    _ = n_local;
        \\}
    ;
    const main = try w.add("/p/src/main.zig", src);
    const thing = try w.add("/p/src/util/thing.zig", "pub const Thing = struct {};\n");
    try w.setGraph(std_root, &.{.{ .root = main.file, .imports = &.{} }}, &.{
        .{ .file = main.file, .module = 0, .compile = 0 },
        .{ .file = thing.file, .module = 0, .compile = 0 },
    });
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "n_E", "*const [6:0]u8 = \"main.E\"" },
        .{ "n_inner", "*const [12:0]u8 = \"main.S.Inner\"" },
        .{ "n_box", "*const [12:0]u8 = \"main.Box(u8)\"" },
        .{ "n_box2", "*const [22:0]u8 = \"main.Box(main.S.Inner)\"" },
        .{ "n_make", "*const [11:0]u8 = \"main.Make()\"" },
        .{ "n_in", "*const [15:0]u8 = \"main.Out(u8).In\"" },
        .{ "n_g", "*const [19:0]u8 = \"main.Out(u8).G(u16)\"" },
        .{ "n_gen", "*const [29:0]u8 = \"main.Gen(3,true,.b,5,.q,null)\"" },
        .{ "n_list", "*const [27:0]u8 = \"array_list.Aligned(u8,null)\"" },
        .{ "n_alloc", "*const [13:0]u8 = \"mem.Allocator\"" },
        .{ "n_std", "*const [3:0]u8 = \"std\"" },
        .{ "n_thing", "*const [16:0]u8 = \"util.thing.Thing\"" },
        .{ "n_file", "*const [10:0]u8 = \"util.thing\"" },
        .{ "n_lit", "*const [14:0]u8 = \"@EnumLiteral()\"" },
        .{ "n_null", "*const [13:0]u8 = \"@TypeOf(null)\"" },
        .{ "n_tuple", "*const [30:0]u8 = \"struct { u8, ?*const [2:0]u8 }\"" },
        .{ "n_err", "*const [17:0]u8 = \"error{A,B}!main.S\"" },
        // Named after a global counter, or after whichever instance creates the shared type
        // first: still a comptime-known string
        .{ "n_anon", "*const [_:0]u8" },
        .{ "n_shared", "*const [_:0]u8" },
        .{ "n_plain", "*const [_:0]u8" },
        .{ "is_list", "bool = true" },
        .{ "branch", "u8 = 1" },
        .{ "eqname", "u1 = 1" },
        .{ "n_local", "*const [8:0]u8 = \"main.f.L\"" },
    };
    for (cases) |c| {
        testing.expectEqualStrings(c[1], try typeAt(&w, main.file, src, c[0], 0)) catch |err| {
            std.debug.print("type of `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "@typeName names function types and inferred error sets as the compiler does" {
    // Prevents an unknown name, and an unknown type, for every function type.
    // Expected values: zig 0.17.0 and 0.17.1 (identical) `@typeName` of each type.
    var env = @import("../project/ZigEnv.zig").query(testing.allocator, testing.io, null) catch return error.SkipZigTest;
    defer env.deinit(testing.allocator);
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const std_root_path = try std.fs.path.join(testing.allocator, &.{ env.std_dir, "std.zig" });
    defer testing.allocator.free(std_root_path);
    const std_root = try w.vfs.intern(std_root_path);
    const src =
        \\const std = @import("std");
        \\fn g1(a: u32) u32 { return a; }
        \\fn g5(a: anytype, b: anytype) @TypeOf(a, b) { return a + b; }
        \\fn gct(comptime T: type, x: T) T { return x; }
        \\fn gctv(comptime n: u8, x: u32) u32 { return x + n; }
        \\fn gna(noalias p: *u8, q: *const u8) void { p.* = q.*; }
        \\fn ginl() callconv(.@"inline") u8 { return 1; }
        \\noinline fn gnoinl() void {}
        \\fn gerr() !u8 { return 1; }
        \\fn gies(comptime T: type) !T { return 1; }
        \\fn rt_dep(x: u8, y: @TypeOf(x)) u8 { return x + y; }
        \\fn ctx_struct(comptime T: type, x: struct { a: T }) void { _ = x; }
        \\fn plain_struct(comptime T: type, x: struct { a: u8 }) T { _ = x; return 0; }
        \\fn comptime_any(comptime x: anytype) void { _ = x; }
        \\fn tfn(T: type) void { _ = T; }
        \\fn Box(comptime T: type) type {
        \\    return struct {
        \\        v: T,
        \\        pub fn get(self: @This()) !T { return self.v; }
        \\    };
        \\}
        \\const n_eql = @typeName(@TypeOf(std.mem.eql));
        \\const n_alloc = @typeName(@TypeOf(std.mem.Allocator.alloc));
        \\const n_print = @typeName(@TypeOf(std.debug.print));
        \\const n_simple = @typeName(fn (u8) bool);
        \\const n_ptr = @typeName(?*const fn () void);
        \\const n_nested = @typeName(fn (*const fn () void) *const fn () void);
        \\const n_g1 = @typeName(@TypeOf(g1));
        \\const n_g5 = @typeName(@TypeOf(g5));
        \\const n_gct = @typeName(@TypeOf(gct));
        \\const n_gctv = @typeName(@TypeOf(gctv));
        \\const n_gna = @typeName(@TypeOf(gna));
        \\const n_ginl = @typeName(@TypeOf(ginl));
        \\const n_gnoinl = @typeName(@TypeOf(gnoinl));
        \\const n_naked = @typeName(fn () callconv(.naked) void);
        \\const n_varargs = @typeName(fn (c_int, ...) callconv(.c) c_int);
        \\const n_fn_comptime = @typeName(fn (comptime u8) void);
        \\const n_fn_anytype = @typeName(fn (anytype) void);
        \\const n_fn_noalias = @typeName(fn (noalias *u8) void);
        \\const n_rt_dep = @typeName(@TypeOf(rt_dep));
        \\const n_ctx_struct = @typeName(@TypeOf(ctx_struct));
        \\const n_comptime_any = @typeName(@TypeOf(comptime_any));
        \\const n_tfn = @typeName(@TypeOf(tfn));
        \\const n_reified = @typeName(@Fn(&.{c_int}, &@splat(.{}), c_int, .{ .@"callconv" = .c, .varargs = true }));
        \\const n_gerr = @typeName(@TypeOf(gerr));
        \\const n_gies = @typeName(@TypeOf(gies));
        \\const n_box_get = @typeName(@TypeOf(Box(u8).get));
        \\const n_call_box = @typeName(@TypeOf(Box(u8).get(undefined)));
        \\const n_ies = @typeName(@typeInfo(@typeInfo(@TypeOf(gerr)).@"fn".return_type.?).error_union.error_set);
        \\const n_len = @typeName(fn (u8) bool).len;
        \\const n_plain_struct = @typeName(@TypeOf(plain_struct));
        \\const n_call_gies = @typeName(@TypeOf(gies(u8)));
        \\fn generic(comptime T: type) void {
        \\    const n_generic = @typeName(T);
        \\    _ = n_generic;
        \\}
    ;
    const main = try w.add("/p/src/main.zig", src);
    try w.setGraph(std_root, &.{.{ .root = main.file, .imports = &.{} }}, &.{
        .{ .file = main.file, .module = 0, .compile = 0 },
    });
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "n_eql", "*const [41:0]u8 = \"fn (comptime type, anytype, anytype) bool\"" },
        .{ "n_alloc", "*const [48:0]u8 = \"fn (mem.Allocator, comptime type, usize) anytype\"" },
        .{ "n_print", "*const [38:0]u8 = \"fn (comptime []const u8, anytype) void\"" },
        .{ "n_simple", "*const [12:0]u8 = \"fn (u8) bool\"" },
        .{ "n_ptr", "*const [18:0]u8 = \"?*const fn () void\"" },
        .{ "n_nested", "*const [40:0]u8 = \"fn (*const fn () void) *const fn () void\"" },
        .{ "n_g1", "*const [12:0]u8 = \"fn (u32) u32\"" },
        .{ "n_g5", "*const [29:0]u8 = \"fn (anytype, anytype) anytype\"" },
        .{ "n_gct", "*const [35:0]u8 = \"fn (comptime type, anytype) anytype\"" },
        .{ "n_gctv", "*const [25:0]u8 = \"fn (comptime u8, u32) u32\"" },
        .{ "n_gna", "*const [32:0]u8 = \"fn (noalias *u8, *const u8) void\"" },
        .{ "n_ginl", "*const [29:0]u8 = \"fn () callconv(.@\\\"inline\\\") u8\"" },
        .{ "n_gnoinl", "*const [19:0]u8 = \"noinline fn () void\"" },
        .{ "n_naked", "*const [27:0]u8 = \"fn () callconv(.naked) void\"" },
        .{ "n_varargs", "*const [34:0]u8 = \"fn (c_int, ...) callconv(.c) c_int\"" },
        .{ "n_fn_comptime", "*const [21:0]u8 = \"fn (comptime u8) void\"" },
        .{ "n_fn_anytype", "*const [17:0]u8 = \"fn (anytype) void\"" },
        .{ "n_fn_noalias", "*const [21:0]u8 = \"fn (noalias *u8) void\"" },
        // A parameter type that refers to a parameter is generic
        .{ "n_rt_dep", "*const [19:0]u8 = \"fn (u8, anytype) u8\"" },
        .{ "n_ctx_struct", "*const [32:0]u8 = \"fn (comptime type, anytype) void\"" },
        .{ "n_comptime_any", "*const [26:0]u8 = \"fn (comptime anytype) void\"" },
        .{ "n_tfn", "*const [14:0]u8 = \"fn (type) void\"" },
        .{ "n_reified", "*const [34:0]u8 = \"fn (c_int, ...) callconv(.c) c_int\"" },
        // Inferred error sets are named after their function
        .{ "n_gerr", "*const [91:0]u8 = \"fn () @typeInfo(@typeInfo(@TypeOf(main.gerr)).@\\\"fn\\\".return_type.?).error_union.error_set!u8\"" },
        .{ "n_gies", "*const [109:0]u8 = \"fn (comptime type) @typeInfo(@typeInfo(@TypeOf(main.gies)).@\\\"fn\\\".return_type.?).error_union.error_set!anytype\"" },
        .{ "n_box_get", "*const [110:0]u8 = \"fn (main.Box(u8)) @typeInfo(@typeInfo(@TypeOf(main.Box(u8).get)).@\\\"fn\\\".return_type.?).error_union.error_set!u8\"" },
        .{ "n_call_box", "*const [92:0]u8 = \"@typeInfo(@typeInfo(@TypeOf(main.Box(u8).get)).@\\\"fn\\\".return_type.?).error_union.error_set!u8\"" },
        .{ "n_ies", "*const [82:0]u8 = \"@typeInfo(@typeInfo(@TypeOf(main.gerr)).@\\\"fn\\\".return_type.?).error_union.error_set\"" },
        .{ "n_len", "usize = 12" },
        // Named after a global counter (`main.plain_struct__struct_1006`, `main.gies__func_999`):
        // still a comptime-known string
        .{ "n_plain_struct", "*const [_:0]u8" },
        .{ "n_call_gies", "*const [_:0]u8" },
        .{ "n_generic", "*const [_:0]u8" },
    };
    for (cases) |c| {
        testing.expectEqualStrings(c[1], try typeAt(&w, main.file, src, c[0], 0)) catch |err| {
            std.debug.print("type of `{s}`\n", .{c[0]});
            return err;
        };
    }
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
        // The interpreter and the inference path produce the same type
        .{ "T", "type = *const [3:0]u8" },
        .{ "U", "type = *const [3:0]u8" },
        // Slicing to the end keeps the sentinel of the source array
        .{ "V", "type = *const [3:0]u8" },
        .{ "W", "type = *const [2]u8" },
    });
}

test "wide integer shift by more than 255 bits does not panic" {
    try expectTypes(
        \\const E = enum(u1000) { a = 5 };
        \\const v = @intFromEnum(E.a) >> 300;
    , &.{
        // Values wider than 128 bits are not folded
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
        // The concatenation itself produces no result; the function's return value is unaffected
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
        // A parameter of type `type` is a comptime parameter even without `comptime`
        .{ "imp", "type = Implicit(u8)" },
        .{ "m", "u32" },
        // A function returning type runs at comptime, and all arguments take part in the instance
        .{ "arr", "type = [3]u8" },
    });
}

test "@TypeOf(undefined) is the type of undefined" {
    // Expected values are the results of zig 0.17.0 (`@compileLog(tu, nm, t2, ie, at, tx)` prints
    // `@TypeOf(undefined)`, `"@TypeOf(undefined)"`, `@TypeOf(undefined)`, `u2`,
    // `@TypeOf(undefined)`, `@TypeOf(undefined)`); it must not resolve to void
    try expectTypes(
        \\const x = undefined;
        \\fn typeOfArg(v: anytype) type {
        \\    return @TypeOf(v);
        \\}
        \\const tu = @TypeOf(undefined);
        \\const nm = @typeName(@TypeOf(x));
        \\const t2 = @TypeOf(undefined, undefined);
        \\const ie = if (@TypeOf(undefined) == void) u1 else u2;
        \\const at = typeOfArg(undefined);
        \\const tx = @TypeOf(x);
    , &.{
        .{ "tu", "type = @TypeOf(undefined)" },
        .{ "nm", "*const [18:0]u8 = \"@TypeOf(undefined)\"" },
        .{ "t2", "type = @TypeOf(undefined)" },
        .{ "ie", "type = u2" },
        .{ "at", "type = @TypeOf(undefined)" },
        .{ "tx", "type = @TypeOf(undefined)" },
    });
}

test "signed integer types with bit width 0 are no types" {
    // zig 0.17.0 rejects `i0` and `@Int(.signed, 0)` ("signed integer cannot have bit width 0");
    // `@compileLog(Z, W, @bitSizeOf(Z))` prints `u0`, `u0`, `0`. A zero-bit signed integer type
    // must not be produced.
    try expectTypes(
        \\const T = i0;
        \\const U = @Int(.signed, 0);
        \\const Z = u0;
        \\const W = @Int(.unsigned, 0);
        \\const L = u01;
        \\const B = @bitSizeOf(T);
        \\const BZ = @bitSizeOf(Z);
    , &.{
        .{ "T", "unknown" },
        .{ "U", "type" },
        .{ "Z", "type = u0" },
        .{ "W", "type = u0" },
        .{ "L", "unknown" },
        .{ "B", "comptime_int" },
        .{ "BZ", "comptime_int = 0" },
    });
    var ip = try InternPool.init(testing.allocator, testing.io);
    defer ip.deinit();
    try testing.expect(try infer.primitive(&ip, "i0") == null);
    try testing.expect(try infer.primitive(&ip, "u01") == null);
    try testing.expect(try infer.primitive(&ip, "u0") != null);
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
        // Two instances with unknown arguments may be different types
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

test "comptime compound assignment evaluates like the binary operator" {
    // Prevents giving up on compound assignment to anything but bool and integers: `a op= b` is
    // `a = a op b` with `b` coerced to the type of `a`, so floats are computed and rounded as by
    // the binary operator; expected values are the results of zig 0.17.0 and 0.17.1
    try expectTypes(
        \\fn floatAcc() f64 {
        \\    var x: f64 = 1.0;
        \\    x += 0.5;
        \\    x *= 4;
        \\    x -= 1;
        \\    x /= 2;
        \\    return x;
        \\}
        \\fn floatLoop() f32 {
        \\    var s: f32 = 0;
        \\    for (0..4) |i| s += @floatFromInt(i);
        \\    return s;
        \\}
        \\fn ctFloatAcc() comptime_float {
        \\    var x: comptime_float = 1.0;
        \\    x += 0.25;
        \\    return x;
        \\}
        \\fn opsF16() f16 {
        \\    var x: f16 = 1.5;
        \\    x += 0.25;
        \\    x -= 0.5;
        \\    x *= 3;
        \\    x /= 2;
        \\    return x;
        \\}
        \\fn opsF80() f80 {
        \\    var x: f80 = 1;
        \\    x /= 3;
        \\    x *= 3;
        \\    return x;
        \\}
        \\fn opsF128() f128 {
        \\    var x: f128 = 1;
        \\    x /= 3;
        \\    x += 1;
        \\    return x;
        \\}
        \\fn roundF32() f32 {
        \\    var x: f32 = 0.1;
        \\    x += 0.2;
        \\    return x;
        \\}
        \\fn roundF16() f16 {
        \\    var x: f16 = 0;
        \\    for (0..10) |_| x += 0.1;
        \\    return x;
        \\}
        \\fn ctPrec() comptime_float {
        \\    var x: comptime_float = 0.1;
        \\    x += 0.2;
        \\    return x;
        \\}
        \\fn intToFloat() f32 {
        \\    const i: usize = 3;
        \\    var x: f32 = 0.5;
        \\    x += i;
        \\    return x;
        \\}
        \\fn places() f64 {
        \\    var x: f64 = 1;
        \\    const p = &x;
        \\    p.* += 0.5;
        \\    var o: ?f64 = 2;
        \\    o.? *= 1.5;
        \\    var s: struct { v: f64 } = .{ .v = 1 };
        \\    s.v -= 0.25;
        \\    var a = [_]f64{ 1, 2, 3 };
        \\    a[1] /= 4;
        \\    for (&a) |*e| e.* *= 2;
        \\    return x + o.? + s.v + a[0] + a[1] + a[2];
        \\}
        \\fn others() i32 {
        \\    var b = true;
        \\    b &= false;
        \\    b |= true;
        \\    b ^= true;
        \\    var w: u16 = 1;
        \\    const y: u8 = 200;
        \\    w += y;
        \\    var x: i32 = -5;
        \\    x += 3;
        \\    x *= -4;
        \\    x -= 100;
        \\    return x + w + @intFromBool(b);
        \\}
        \\const float_acc = floatAcc();
        \\const float_loop = floatLoop();
        \\const ct_float_acc = ctFloatAcc();
        \\const ops_f16 = opsF16();
        \\const ops_f80 = opsF80();
        \\const ops_f128 = opsF128();
        \\const round_f32 = roundF32();
        \\const round_f16 = roundF16();
        \\const ct_prec = ctPrec();
        \\const int_to_float = intToFloat();
        \\const in_places = places();
        \\const other_types = others();
    , &.{
        .{ "float_acc", "f64 = 2.5" },
        .{ "float_loop", "f32 = 6" },
        .{ "ct_float_acc", "comptime_float = 1.25" },
        .{ "ops_f16", "f16 = 1.875" },
        .{ "ops_f80", "f80 = 1" },
        .{ "ops_f128", "f128 = 1.3333333333333333333333333333333333" },
        .{ "round_f32", "f32 = 0.3" },
        // Each `+=` rounds to f16
        .{ "round_f16", "f16 = 1" },
        .{ "ct_prec", "comptime_float = 0.30000000000000000000000000000000004" },
        .{ "int_to_float", "f32 = 3.5" },
        .{ "in_places", "f64 = 14.25" },
        .{ "other_types", "i32 = 109" },
    });
}

test "comptime compound assignment gives no value where the compiler reports an error" {
    try expectTypes(
        \\fn ctDivZero() comptime_float {
        \\    var x: comptime_float = 1;
        \\    x /= 0;
        \\    return x;
        \\}
        \\fn fraction() comptime_int {
        \\    var x: comptime_int = 7;
        \\    x += 0.5;
        \\    return x;
        \\}
        \\fn overflow() u8 {
        \\    var x: u8 = 255;
        \\    x += 1;
        \\    return x;
        \\}
        \\fn boolAdd() bool {
        \\    var x = true;
        \\    x += true;
        \\    return x;
        \\}
        \\const ct_div_zero = ctDivZero();
        \\const fractional = fraction();
        \\const overflowed = overflow();
        \\const bool_add = boolAdd();
    , &.{
        .{ "ct_div_zero", "comptime_float" },
        .{ "fractional", "comptime_int" },
        .{ "overflowed", "u8" },
        .{ "bool_add", "bool" },
    });
}

test "comptime float remainder" {
    // `%` on floats is `@rem` when no operand is negative, or when the remainder is zero; with a
    // negative operand and a nonzero remainder the compiler reports an error; expected values
    // are the results of zig 0.17.0 and 0.17.1
    try expectTypes(
        \\fn modAssign() f64 {
        \\    var x: f64 = 7.5;
        \\    x %= 2;
        \\    return x;
        \\}
        \\fn modFrac() f32 {
        \\    var x: f32 = 5.75;
        \\    x %= 1.5;
        \\    return x;
        \\}
        \\fn modCt() comptime_float {
        \\    var x: comptime_float = 7.5;
        \\    x %= 2;
        \\    return x;
        \\}
        \\fn modNegZero() f64 {
        \\    var x: f64 = -4.0;
        \\    x %= 2;
        \\    return x;
        \\}
        \\fn modNegRhs() f64 {
        \\    var x: f64 = 5.5;
        \\    x %= -2;
        \\    return x;
        \\}
        \\const mod_f64 = @as(f64, 7.5) % 2;
        \\const mod_ct = 7.5 % 2.0;
        \\const mod_neg = @as(f64, -5.5) % 2;
        \\const mod_assign = modAssign();
        \\const mod_frac = modFrac();
        \\const mod_ct_assign = modCt();
        \\const mod_neg_zero = modNegZero();
        \\const mod_neg_rhs = modNegRhs();
    , &.{
        .{ "mod_f64", "f64 = 1.5" },
        .{ "mod_ct", "comptime_float = 1.5" },
        .{ "mod_neg", "f64" },
        .{ "mod_assign", "f64 = 1.5" },
        .{ "mod_frac", "f32 = 1.25" },
        .{ "mod_ct_assign", "comptime_float = 1.5" },
        .{ "mod_neg_zero", "f64 = -0" },
        .{ "mod_neg_rhs", "f64" },
    });
}

test "instances of the same container compare by their captured values" {
    // Matches the compiler: the identity of a container = definition position + captured values
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

test "containers in a type function capture the values its body computed" {
    // Prevents members from seeing only a re-inference of a captured constant's initializer,
    // which has no value for local arrays and for values derived from local variables
    try expectTypes(
        \\fn LocalArray(comptime n: comptime_int) type {
        \\    const arr = [_]comptime_int{ n, 2 };
        \\    const min = arr[0];
        \\    return struct { pub const v: comptime_int = min; };
        \\}
        \\fn ArrayDirect(comptime n: comptime_int) type {
        \\    const arr = [_]comptime_int{ n, 2 };
        \\    return struct { pub const v: comptime_int = arr[0]; };
        \\}
        \\fn VarOnly(comptime n: comptime_int) type {
        \\    var x = n;
        \\    _ = &x;
        \\    const y = x;
        \\    return struct { pub const v: comptime_int = y; };
        \\}
        \\fn VarModified(comptime n: comptime_int) type {
        \\    var x = n;
        \\    x += 1;
        \\    const y = x;
        \\    return struct { pub const v: comptime_int = y; };
        \\}
        \\fn Branch(comptime b: bool) type {
        \\    var x: u32 = 1;
        \\    if (b) x = 10;
        \\    const y = x;
        \\    return struct { pub const v = y; };
        \\}
        \\fn Loop(comptime n: u32) type {
        \\    var sum: u32 = 0;
        \\    var i: u32 = 0;
        \\    while (i < n) : (i += 1) sum += i;
        \\    const total = sum;
        \\    return struct { pub const v = total; };
        \\}
        \\fn Destructure(comptime n: comptime_int) type {
        \\    var x = n;
        \\    x += 1;
        \\    const a, const b = .{ x, x * 2 };
        \\    return struct { pub const v: comptime_int = a + b; };
        \\}
        \\fn Nested(comptime n: comptime_int) type {
        \\    var x = n;
        \\    x *= 3;
        \\    const y = x;
        \\    return struct {
        \\        pub fn Inner() type {
        \\            return struct { pub const w: comptime_int = y; };
        \\        }
        \\    };
        \\}
        \\fn ReadBeforeReturn(comptime n: comptime_int) type {
        \\    var x = n;
        \\    x += 1;
        \\    const y = x;
        \\    const S = struct { pub const v: comptime_int = y; };
        \\    if (S.v != n + 1) @compileError("unreachable");
        \\    return S;
        \\}
        \\fn OutsideLoop(comptime n: comptime_int) type {
        \\    var x = n;
        \\    x += 1;
        \\    const y = x;
        \\    var T: type = void;
        \\    inline for (0..2) |_| T = struct { pub const v: comptime_int = y; };
        \\    return T;
        \\}
        \\fn PerIteration(comptime n: comptime_int) type {
        \\    var T: type = void;
        \\    for (0..n) |i| {
        \\        const k = i * 2;
        \\        T = struct { pub const v = k; };
        \\    }
        \\    return T;
        \\}
        \\fn AnyCapture(x: anytype) type {
        \\    const y = x;
        \\    return struct { pub const v = y; };
        \\}
        \\fn g() void {
        \\    const local_array = LocalArray(7).v;
        \\    const array_direct = ArrayDirect(9).v;
        \\    const var_only = VarOnly(4).v;
        \\    const var_modified = VarModified(4).v;
        \\    const branch_true = Branch(true).v;
        \\    const branch_false = Branch(false).v;
        \\    const loop = Loop(5).v;
        \\    const destructure = Destructure(1).v;
        \\    const nested = Nested(2).Inner().w;
        \\    const read_before_return = ReadBeforeReturn(6).v;
        \\    const outside_loop = OutsideLoop(1).v;
        \\    const per_iteration = PerIteration(3).v;
        \\    const any_capture = AnyCapture(@as(u8, 3)).v;
        \\    _ = .{ local_array, array_direct, var_only, var_modified, branch_true, branch_false, loop, destructure, nested, read_before_return, outside_loop, per_iteration, any_capture };
        \\}
    , &.{
        .{ "local_array", "comptime_int = 7" },
        .{ "array_direct", "comptime_int = 9" },
        .{ "var_only", "comptime_int = 4" },
        .{ "var_modified", "comptime_int = 5" },
        .{ "branch_true", "u32 = 10" },
        .{ "branch_false", "u32 = 1" },
        .{ "loop", "u32 = 10" },
        .{ "destructure", "comptime_int = 6" },
        .{ "nested", "comptime_int = 6" },
        .{ "read_before_return", "comptime_int = 7" },
        .{ "outside_loop", "comptime_int = 2" },
        // A constant in a loop body has a value per iteration, while the containers of all
        // iterations share one instance (the compiler gives 4)
        .{ "per_iteration", "usize" },
        // The instance records only the type of an anytype argument (the compiler gives 3)
        .{ "any_capture", "u8" },
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
        // Errors from return and errors propagated by try
        .{ "rb", "error{Bad,Oops}!u8" },
        .{ "rc", "error{}!void" },
        // Recursive functions take the least fixpoint (matches the compiler)
        .{ "rr", "error{Done,TooBig}!u32" },
        .{ "rr2", "error{Done}!u32" },
        .{ "ru", "error{Done,Own,TooBig}!void" },
        // Mutual recursion (a compiler error): take the union of both
        .{ "rp", "error{Ping,Pong}!void" },
        .{ "rq", "error{Ping,Pong}!void" },
        // Branches that are inactive at comptime and code after noreturn are not included
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
    // Types whose size cannot be represented in a u64: the layout cannot be computed, and the host
    // must not crash on overflow
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

test "error code layouts follow the error limit" {
    // Prevents assuming 16-bit error codes when the compilation sets an error limit; expected
    // values are the results of zig 0.17.0 with `--error-limit 255`
    var target = try targetOf("x86_64-linux-musl", null);
    target.error_bits = 8;
    try expectTypesTargeted(target,
        \\const Slot = struct { r: anyerror!u8, tag: u8 };
        \\const E = error{ A, B };
        \\const size_anyerror = @sizeOf(anyerror);
        \\const bits_anyerror = @bitSizeOf(anyerror);
        \\const align_anyerror = @alignOf(anyerror);
        \\const size_eu_u8 = @sizeOf(anyerror!u8);
        \\const size_eu_u32 = @sizeOf(anyerror!u32);
        \\const size_slot = @sizeOf(Slot);
        \\const size_set = @sizeOf(E);
        \\const size_opt = @sizeOf(?anyerror);
        \\fn code(e: anyerror) void {
        \\    const int = @intFromError(e);
        \\    _ = int;
        \\}
    , &.{
        .{ "size_anyerror", "comptime_int = 1" },
        .{ "bits_anyerror", "comptime_int = 8" },
        .{ "align_anyerror", "comptime_int = 1" },
        .{ "size_eu_u8", "comptime_int = 2" },
        .{ "size_eu_u32", "comptime_int = 8" },
        .{ "size_slot", "comptime_int = 3" },
        .{ "size_set", "comptime_int = 1" },
        .{ "size_opt", "comptime_int = 1" },
        .{ "int", "u8" },
    });
    // Error limits that differ between the compilations sharing the parameters
    target.error_bits = null;
    try expectTypesTargeted(target,
        \\const size_anyerror = @sizeOf(anyerror);
        \\const size_eu_u8 = @sizeOf(anyerror!u8);
    , &.{
        .{ "size_anyerror", "comptime_int" },
        .{ "size_eu_u8", "comptime_int" },
    });
}

test "container layouts match the compiler" {
    // Expected values are the results of zig 0.17.0 on x86_64-linux
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
        // Auto layout reorders fields by descending alignment
        .{ "a_a", "comptime_int = 6" },
        .{ "a_b", "comptime_int = 0" },
        .{ "a_c", "comptime_int = 4" },
        // extern keeps declaration order
        .{ "size_b", "comptime_int = 12" },
        .{ "b_c", "comptime_int = 8" },
        .{ "size_c", "comptime_int = 4" },
        .{ "bits_c", "comptime_int = 24" },
        .{ "c_b", "comptime_int = 3" },
        .{ "c_c", "comptime_int = 1" },
        // Fields with the same alignment keep their declaration order
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
        // A union(enum) with a single field has no runtime tag
        .{ "size_one", "comptime_int = 4" },
        .{ "size_opt_u", "comptime_int = 24" },
        .{ "nest_c", "comptime_int = 48" },
        .{ "size_nest", "comptime_int = 56" },
        // comptime fields take no space
        .{ "size_k", "comptime_int = 4" },
        .{ "k_a", "comptime_int = 2" },
        .{ "pair_a", "comptime_int = 4" },
        // Explicit alignment: can be larger or smaller than the type's alignment, takes part in the
        // reordering, and is evaluated from the arguments in generic instances
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
        // Untagged union: no builtin (the optimize mode is unknown)
        .{ "size_bare", "comptime_int" },
        // Types without a bit representation (a compiler error)
        .{ "bits_s", "comptime_int" },
        .{ "bits_slice", "comptime_int" },
        .{ "bits_opt", "comptime_int" },
        .{ "bits_ptr", "comptime_int = 64" },
        // The bit size of an array includes the sentinel
        .{ "bits_arr", "comptime_int = 15" },
        .{ "bits_sent", "comptime_int = 24" },
        .{ "bits_autos", "comptime_int" },
        // A packed struct cannot contain an enum without an explicit tag type
        .{ "size_pa", "comptime_int" },
    });
}

test "float math builtins use the precision of the operand type" {
    // Expected values are the results of zig 0.17.0
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
        // The absolute value of a signed integer is an unsigned integer
        .{ "ai", "u8 = 128" },
        .{ "ic", "i32 = -3" },
        // Negative divisor: integers use floored semantics; float `@mod` matches the compiler and
        // adjusts only by the sign of the dividend
        .{ "mi", "i32 = -2" },
        .{ "rn", "f64 = -1" },
        .{ "mf", "f64 = 1" },
        .{ "mg", "f32 = -1.5" },
    });
}

test "rounding builtins have their result type" {
    // Expected values are the results of zig 0.17.0 and 0.17.1 (`Sema.zirRoundCast`): with a
    // result type, the call has that type without error unions and optionals. An integer result
    // type takes the rounded operand converted to it; a float result type takes the operand
    // coerced to it before rounding (0.4999999 as an f16 is 0.5, which rounds to 1).
    try expectTypes(
        \\fn ret(r: f32) u32 {
        \\    return @floor(r);
        \\}
        \\fn f(x: f32, y: f32, z: f32, v: @Vector(2, f32), comptime T: type) void {
        \\    const i: u32 = @round(x);
        \\    const k: u8 = @round(@as(f32, 2.5));
        \\    const w: f64 = @floor(@as(f32, 1.5));
        \\    const half: f16 = @round(0.4999999);
        \\    const t: i8 = @trunc(-1.5);
        \\    const c: comptime_int = @ceil(2.25);
        \\    const o: ?u8 = @ceil(@as(f64, 2.25));
        \\    const e: anyerror!u8 = @floor(@as(f64, 7.75));
        \\    const a = @as(u16, @round(@as(f32, 9.5)));
        \\    const vi: @Vector(2, i32) = @trunc(v);
        \\    const g: T = @round(y);
        \\    const n = @round(z);
        \\    _ = .{ i, k, w, half, t, c, o, e, a, vi, g, n };
        \\}
    , &.{
        .{ "@floor(r)", "u32" },
        .{ "@round(x)", "u32" },
        .{ "@round(@as(f32, 2.5))", "u8 = 3" },
        .{ "k", "u8 = 3" },
        .{ "@floor(@as(f32, 1.5))", "f64 = 1" },
        .{ "@round(0.4999999)", "f16 = 1" },
        .{ "half", "f16 = 1" },
        .{ "@trunc(-1.5)", "i8 = -1" },
        .{ "@ceil(2.25)", "comptime_int = 3" },
        // The call gives the payload, which is then coerced to the optional or error union
        .{ "@ceil(@as(f64, 2.25))", "?u8 = 3" },
        .{ "@floor(@as(f64, 7.75))", "anyerror!u8 = 7" },
        .{ "@round(@as(f32, 9.5))", "u16 = 10" },
        .{ "@trunc(v)", "@Vector(2, i32)" },
        .{ "@round(y)", "T" },
        // Without a result type, the result has the type of the operand
        .{ "@round(z)", "f32" },
    });
}

test "@abs maps signed integer types to their unsigned counterparts" {
    // Expected values are the results of zig 0.17.0 (`@compileLog(@TypeOf(@abs(v)), ...)` prints
    // `@Vector(4, u32)`, `usize`, `c_uint`, `c_ulong`, `c_ushort`, `c_ulonglong`, `u32`,
    // `@Vector(4, u32)`, `@Vector(2, f32)`, `u8`)
    try expectTypes(
        \\fn probe(v: @Vector(4, i32), d: isize, c: c_int, l: c_long, s: c_short, ll: c_longlong, u: i32, vu: @Vector(4, u32), vf: @Vector(2, f32)) void {
        \\    const a_vec = @abs(v);
        \\    const a_isize = @abs(d);
        \\    const a_cint = @abs(c);
        \\    const a_clong = @abs(l);
        \\    const a_cshort = @abs(s);
        \\    const a_cll = @abs(ll);
        \\    const a_i32 = @abs(u);
        \\    const a_vu = @abs(vu);
        \\    const a_vf = @abs(vf);
        \\    const k_cint = @abs(@as(c_int, -3));
        \\    _ = .{ a_vec, a_isize, a_cint, a_clong, a_cshort, a_cll, a_i32, a_vu, a_vf, k_cint };
        \\}
    , &.{
        .{ "a_vec", "@Vector(4, u32)" },
        .{ "a_isize", "usize" },
        .{ "a_cint", "c_uint" },
        .{ "a_clong", "c_ulong" },
        .{ "a_cshort", "c_ushort" },
        .{ "a_cll", "c_ulonglong" },
        .{ "a_i32", "u32" },
        .{ "a_vu", "@Vector(4, u32)" },
        .{ "a_vf", "@Vector(2, f32)" },
        .{ "k_cint", "c_uint = 3" },
    });
}

test "orelse and catch on comptime-known operands take only the evaluated side" {
    // Expected values are the results of zig 0.17.0 (`@compileLog(@TypeOf(cfg_port), @TypeOf(z1),
    // @TypeOf(z2), nn, ok, @TypeOf(rt), @TypeOf(rte), @TypeOf(ann))` prints `comptime_int`,
    // `comptime_int`, `comptime_int`, `@as(i32, 7)`, `@as(u8, 9)`, `u8`, `u8`, `u32`); a taken
    // right-hand side must not be coerced to the payload type
    try expectTypes(
        \\const Opts = struct { port: ?u16 = null };
        \\const opts: Opts = .{};
        \\fn probe(r: ?u8, re: anyerror!u8) void {
        \\    const cfg_port = opts.port orelse 8080;
        \\    const n: ?i32 = null;
        \\    const z1 = n orelse 1234;
        \\    const e: anyerror!u8 = error.Bad;
        \\    const z2 = e catch 5;
        \\    const m: ?i32 = 7;
        \\    const nn = m orelse 1;
        \\    const g: anyerror!u8 = 9;
        \\    const ok = g catch 5;
        \\    const rt = r orelse 3;
        \\    const rte = re catch 4;
        \\    const ann: u32 = n orelse 2;
        \\    _ = .{ cfg_port, z1, z2, nn, ok, rt, rte, ann };
        \\}
    , &.{
        .{ "cfg_port", "comptime_int = 8080" },
        .{ "z1", "comptime_int = 1234" },
        .{ "z2", "comptime_int = 5" },
        .{ "nn", "i32 = 7" },
        .{ "ok", "u8 = 9" },
        .{ "rt", "u8" },
        .{ "rte", "u8" },
        .{ "ann", "u32 = 2" },
    });
}

test "catch and orelse on operands evaluated at comptime take the type of the side that is taken" {
    // Expected values are the results of zig 0.17.0 and 0.17.1 (`@TypeOf` and `{any}` of each
    // declaration, printed by a `zig test` runner). The handler gets the result type of the whole
    // expression, not the payload type; operands of `@TypeOf` are runtime, so their peer type
    // stays. Typing the result as the peer of the payload and the handler gave `u32 = "s"`.
    try expectTypes(
        \\const Err = error{ Foo, Bar };
        \\fn mayFail(x: u32) Err!u32 {
        \\    if (x == 0) return error.Foo;
        \\    return x;
        \\}
        \\fn fails() error{Oops}!u32 {
        \\    return error.Oops;
        \\}
        \\fn ok() error{Oops}!u32 {
        \\    return 5;
        \\}
        \\fn maybe(x: u32) ?u32 {
        \\    return if (x == 0) null else x;
        \\}
        \\fn catchInCall() bool {
        \\    const x = fails() catch 9;
        \\    return @TypeOf(x) == comptime_int;
        \\}
        \\fn orelseInCall() bool {
        \\    const x = maybe(0) orelse "s";
        \\    return @TypeOf(x) == *const [1:0]u8;
        \\}
        \\pub const catch_int = fails() catch 9;
        \\pub const catch_typed = fails() catch @as(u64, 9);
        \\pub const catch_str = fails() catch "s";
        \\pub const catch_capture = fails() catch |e| @errorName(e);
        \\pub const catch_capture_arg = mayFail(0) catch |e| @errorName(e);
        \\pub const catch_block = fails() catch blk: {
        \\    break :blk "blk";
        \\};
        \\pub const catch_ok_str = ok() catch "s";
        \\pub const catch_ok_typed = ok() catch @as(u64, 9);
        \\pub const catch_annotated: u64 = fails() catch 9;
        \\pub const orelse_null_str = @as(?u32, null) orelse "s";
        \\pub const orelse_call_str = maybe(0) orelse "s";
        \\pub const orelse_call_typed = maybe(0) orelse @as(u64, 1);
        \\pub const orelse_call_int = maybe(0) orelse 1;
        \\pub const orelse_call_some = maybe(3) orelse "s";
        \\pub const catch_then_orelse = (fails() catch @as(?u8, null)) orelse "n";
        \\pub const local_type = blk: {
        \\    const x = fails() catch 9;
        \\    break :blk @TypeOf(x);
        \\};
        \\pub const typeof_catch = @TypeOf(fails() catch 0);
        \\pub const typeof_orelse = @TypeOf(maybe(0) orelse 1);
        \\pub const catch_in_call = catchInCall();
        \\pub const orelse_in_call = orelseInCall();
    , &.{
        .{ "catch_int", "comptime_int = 9" },
        .{ "catch_typed", "u64 = 9" },
        .{ "catch_str", "*const [1:0]u8 = \"s\"" },
        .{ "catch_capture", "*const [4:0]u8 = \"Oops\"" },
        .{ "catch_capture_arg", "*const [3:0]u8 = \"Foo\"" },
        .{ "catch_block", "*const [3:0]u8 = \"blk\"" },
        .{ "catch_ok_str", "u32 = 5" },
        .{ "catch_ok_typed", "u32 = 5" },
        .{ "catch_annotated", "u64 = 9" },
        .{ "orelse_null_str", "*const [1:0]u8 = \"s\"" },
        .{ "orelse_call_str", "*const [1:0]u8 = \"s\"" },
        .{ "orelse_call_typed", "u64 = 1" },
        .{ "orelse_call_int", "comptime_int = 1" },
        .{ "orelse_call_some", "u32 = 3" },
        .{ "catch_then_orelse", "*const [1:0]u8 = \"n\"" },
        .{ "local_type", "type = comptime_int" },
        .{ "typeof_catch", "type = u32" },
        .{ "typeof_orelse", "type = u32" },
        .{ "catch_in_call", "bool = true" },
        .{ "orelse_in_call", "bool = true" },
    });
}

test "peer types of error sets, error unions, arrays, vectors, floats and C pointers" {
    // Expected values are the results of zig 0.17.0 (`@compileLog(@TypeOf(p1), ..., @TypeOf(p14))`
    // prints `error{Foo}!u8`, `error{A,B}`, `anyerror!u32`, `[2]u32`, `@Vector(2, u16)`,
    // `error{Empty}!u32`, `f32`, `[*c]u8`, `comptime_float`, `[2:0]u8`, `@Vector(2, u16)`,
    // `[*c]u8`, `error{A}!@TypeOf(null)`, `f32`); these peers must not resolve to unknown
    try expectTypes(
        \\const E = error{Empty};
        \\fn parse(s: []const u8) E!u32 {
        \\    if (s.len == 0) return error.Empty;
        \\    return 1;
        \\}
        \\fn probe(c: bool, k: u8, eu: anyerror!u32, a: [2]u32, v: @Vector(2, u16), w: @Vector(2, u8), s: []const u8, cp: [*c]u8, p: *u8, x: f32, sa: [2:0]u8, sb: [2:0]u8, op: ?*u8, ar: [2]u16) void {
        \\    const p1 = if (c) @as(u8, 1) else error.Foo;
        \\    const p2 = switch (k) { 0 => error.A, else => error.B };
        \\    const p3 = if (c) eu else error.Bar;
        \\    const p4 = if (c) a else .{ 1, 2 };
        \\    const p5 = if (c) v else w;
        \\    const p6 = parse(s) catch |err| err;
        \\    const kb: u8 = 3;
        \\    const p7 = if (c) kb else x;
        \\    const p8 = if (c) cp else p;
        \\    const p9 = @TypeOf(1, 2.5);
        \\    const p10 = if (c) sa else sb;
        \\    const p11 = if (c) v else ar;
        \\    const p12 = if (c) cp else op;
        \\    const p13 = @TypeOf(error.A, null);
        \\    const p14 = if (c) k else x;
        \\    const c1 = if (c) @as(u8, 1) else @as(u16, 2);
        \\    const c2 = if (c) @as(u8, 1) else null;
        \\    _ = .{ p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12, p13, p14, c1, c2 };
        \\}
    , &.{
        .{ "p1", "error{Foo}!u8" },
        .{ "p2", "error{A,B}" },
        .{ "p3", "anyerror!u32" },
        .{ "p4", "[2]u32" },
        .{ "p5", "@Vector(2, u16)" },
        .{ "p6", "error{Empty}!u32" },
        .{ "p7", "f32" },
        .{ "p8", "[*c]u8" },
        .{ "p9", "type = comptime_float" },
        .{ "p10", "[2:0]u8" },
        .{ "p11", "@Vector(2, u16)" },
        .{ "p12", "[*c]u8" },
        .{ "p13", "type = error{A}!@TypeOf(null)" },
        .{ "p14", "f32" },
        .{ "c1", "u16" },
        .{ "c2", "?u8" },
    });
}

test "the peer type of a C pointer and null is the C pointer" {
    // Expected values are the results of zig 0.17.0 (`@compileLog(@TypeOf(a1), @TypeOf(a2), T1,
    // @TypeOf(o), @TypeOf(p))` prints `[*c]u8`, `[*c]u8`, `[*c]u8`, `?u8`, `?*u8`); a C pointer
    // must not be wrapped into an optional
    try expectTypes(
        \\fn probe(c: bool, cp: [*c]u8) void {
        \\    const a1 = if (c) cp else null;
        \\    const a2 = if (c) null else cp;
        \\    const T1 = @TypeOf(cp, null);
        \\    const o = if (c) @as(?u8, 1) else null;
        \\    const p = if (c) @as(*u8, undefined) else null;
        \\    _ = .{ a1, a2, T1, o, p };
        \\}
    , &.{
        .{ "a1", "[*c]u8" },
        .{ "a2", "[*c]u8" },
        .{ "T1", "type = [*c]u8" },
        .{ "o", "?u8" },
        .{ "p", "?*u8" },
    });
}

test "@min and @max narrow the result type like the compiler" {
    // Expected values are the results of zig 0.17.0
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
        // The result type is the smallest integer type that holds the range of the result: the
        // value of an argument when it is known, otherwise the range of its type
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

test "!, @intFromBool, @min and @max work element-wise on vectors" {
    // Expected values are the results of zig 0.17.0 (`@compileLog(@TypeOf(not_v), ...,
    // @TypeOf(lim))` prints `@Vector(4, bool)`, `@Vector(4, u1)`, `@Vector(4, u8)`,
    // `@Vector(4, u2)`, `@Vector(4, u31)`, `@Vector(4, bool)`, `bool`, `u1`, `u2`); vector operands
    // must not give scalar types or skip the narrowing
    try expectTypes(
        \\fn probe(m: @Vector(4, bool), v: @Vector(4, u32), a: @Vector(4, i32), b: @Vector(4, i32), c: bool, x: u8) void {
        \\    const not_v = !m;
        \\    const ifb_v = @intFromBool(m);
        \\    const clamp_v = @min(v, @as(@Vector(4, u32), @splat(255)));
        \\    const clamp3 = @min(v, @as(@Vector(4, u32), @splat(3)));
        \\    const zero: @Vector(4, i32) = @splat(0);
        \\    const relu = @max(a, zero);
        \\    const ne = !(a == b);
        \\    const not_c = !c;
        \\    const ifb_c = @intFromBool(c);
        \\    const lim = @min(x, 3);
        \\    _ = .{ not_v, ifb_v, clamp_v, clamp3, relu, ne, not_c, ifb_c, lim };
        \\}
    , &.{
        .{ "not_v", "@Vector(4, bool)" },
        .{ "ifb_v", "@Vector(4, u1)" },
        .{ "clamp_v", "@Vector(4, u8)" },
        .{ "clamp3", "@Vector(4, u2)" },
        .{ "relu", "@Vector(4, u31)" },
        .{ "ne", "@Vector(4, bool)" },
        .{ "not_c", "bool" },
        .{ "ifb_c", "u1" },
        .{ "lim", "u2" },
    });
}

test "peer types of different integer and float types" {
    // Expected values are the results of zig 0.17.0
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
        // With equal bit widths, the first one is taken
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
    // Expected values are the results of zig 0.17.0: Debug on x86_64-linux uses the self-hosted
    // backend by default, and `-fllvm` uses LLVM
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
    // Self-hosted x86_64 backend: the alignment is at least 16; it is 32 above 16 bytes with AVX,
    // and 64 above 32 bytes with AVX-512
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
    // LLVM: the alignment is the byte size rounded up to a power of two; at most 16 on aarch64
    try expectTypesTargeted(.{ .vector_abi = .llvm }, src, &.{
        .{ "v2u8", "comptime_int = 2" },
        .{ "v3u5", "comptime_int = 2" },
        .{ "v16f32", "comptime_int = 64" },
        .{ "v100bool", "comptime_int = 16" },
        .{ "v3ptr", "comptime_int = 32" },
    });
    try expectTypesTargeted(.{ .vector_abi = .llvm_stack_align_16 }, src, &.{
        .{ "v16f32", "comptime_int = 16" },
        .{ "v8u32", "comptime_int = 16" },
        .{ "v3ptr", "comptime_int = 32" },
    });
    // Unknown backend (e.g. inconsistent across modules)
    try expectTypesTargeted(.{ .vector_abi = .unknown }, src, &.{
        .{ "v2u8", "comptime_int" },
        .{ "bits", "comptime_int" },
    });
}

test "LLVM vector sizes are powers of two even where the alignment is capped" {
    // Expected values are the results of zig 0.17.1 on aarch64-linux and x86_64-linux with
    // -OReleaseFast; a size of 48 was reported for `s33`, aligned to 16 from 33 bytes
    const src =
        \\const s3 = @sizeOf(@Vector(3, u8));
        \\const s17 = @sizeOf(@Vector(17, u8));
        \\const s33 = @sizeOf(@Vector(33, u8));
        \\const s65 = @sizeOf(@Vector(65, u8));
        \\const a33 = @alignOf(@Vector(33, u8));
        \\const s5u64 = @sizeOf(@Vector(5, u64));
        \\const s0 = @sizeOf(@Vector(0, u8));
    ;
    try expectTypesTargeted(.{ .vector_abi = .llvm_stack_align_16 }, src, &.{
        .{ "s3", "comptime_int = 4" },
        .{ "s17", "comptime_int = 32" },
        .{ "s33", "comptime_int = 64" },
        .{ "s65", "comptime_int = 128" },
        .{ "a33", "comptime_int = 16" },
        .{ "s5u64", "comptime_int = 64" },
        .{ "s0", "comptime_int = 0" },
    });
    try expectTypesTargeted(.{ .vector_abi = .llvm }, src, &.{
        .{ "s33", "comptime_int = 64" },
        .{ "a33", "comptime_int = 64" },
        .{ "s0", "comptime_int = 0" },
    });
}

test "vector sizes follow the user's zig where the alignment is capped" {
    // Expected values are the results of `zig build-obj -OReleaseFast` of each version
    const src =
        \\const S = struct { v: @Vector(33, u8), b: u8 };
        \\const s3 = @sizeOf(@Vector(3, u8));
        \\const s17 = @sizeOf(@Vector(17, u8));
        \\const s32 = @sizeOf(@Vector(32, u8));
        \\const s33 = @sizeOf(@Vector(33, u8));
        \\const s65 = @sizeOf(@Vector(65, u8));
        \\const a33 = @alignOf(@Vector(33, u8));
        \\const s5u64 = @sizeOf(@Vector(5, u64));
        \\const s0 = @sizeOf(@Vector(0, u8));
        \\const s_struct = @sizeOf(S);
    ;
    try expectTypesTargeted(.{ .vector_abi = .llvm_stack_align_16, .dialect = .zig_0_17_0 }, src, &.{
        .{ "s3", "comptime_int = 4" },
        .{ "s17", "comptime_int = 32" },
        .{ "s32", "comptime_int = 32" },
        .{ "s33", "comptime_int = 48" },
        .{ "s65", "comptime_int = 80" },
        .{ "a33", "comptime_int = 16" },
        .{ "s5u64", "comptime_int = 48" },
        .{ "s0", "comptime_int = 0" },
        .{ "s_struct", "comptime_int = 64" },
    });
    try expectTypesTargeted(.{ .vector_abi = .llvm_stack_align_16, .dialect = .zig_0_17_1 }, src, &.{
        .{ "s3", "comptime_int = 4" },
        .{ "s17", "comptime_int = 32" },
        .{ "s32", "comptime_int = 32" },
        .{ "s33", "comptime_int = 64" },
        .{ "s65", "comptime_int = 128" },
        .{ "a33", "comptime_int = 16" },
        .{ "s5u64", "comptime_int = 64" },
        .{ "s0", "comptime_int = 0" },
        .{ "s_struct", "comptime_int = 80" },
    });
    // Without a capped alignment the versions agree
    for ([_]@import("../syntax/Parse.zig").Dialect{ .zig_0_17_0, .zig_0_17_1 }) |dialect| {
        try expectTypesTargeted(.{ .vector_abi = .llvm, .dialect = dialect }, src, &.{
            .{ "s33", "comptime_int = 64" },
            .{ "s65", "comptime_int = 128" },
            .{ "a33", "comptime_int = 64" },
            .{ "s5u64", "comptime_int = 64" },
            .{ "s_struct", "comptime_int = 128" },
        });
    }
}

test "vector alignment is capped at the stack alignment of 8 on 32-bit ARM and s390x" {
    // Expected values are the results of `zig build-obj` of each version for arm-linux-gnueabihf
    // and s390x-linux-gnu, which agree; the layout of these vectors was unknown
    const src =
        \\const S = struct { v: @Vector(5, u64), x: u8 };
        \\const U = union(enum) { v: @Vector(3, u64), x: u8 };
        \\const s4f32 = @sizeOf(@Vector(4, f32));
        \\const a4f32 = @alignOf(@Vector(4, f32));
        \\const a8f32 = @alignOf(@Vector(8, f32));
        \\const s3u8 = @sizeOf(@Vector(3, u8));
        \\const a3u8 = @alignOf(@Vector(3, u8));
        \\const s9u8 = @sizeOf(@Vector(9, u8));
        \\const s17u8 = @sizeOf(@Vector(17, u8));
        \\const s5u64 = @sizeOf(@Vector(5, u64));
        \\const a5u64 = @alignOf(@Vector(5, u64));
        \\const s16u64 = @sizeOf(@Vector(16, u64));
        \\const s0 = @sizeOf(@Vector(0, u8));
        \\const a0 = @alignOf(@Vector(0, u8));
        \\const s_struct = @sizeOf(S);
        \\const a_struct = @alignOf(S);
        \\const s_union = @sizeOf(U);
        \\const s_array = @sizeOf([2]@Vector(10, u32));
        \\const s_opt = @sizeOf(?@Vector(4, f32));
        \\const bits = @bitSizeOf(@Vector(3, u5));
    ;
    const Dialect = @import("../syntax/Parse.zig").Dialect;
    // The same in both versions: sizes that are powers of 2 or multiples of the alignment
    for ([_]Dialect{ .zig_0_17_0, .zig_0_17_1 }) |dialect| {
        try expectTypesTargeted(.{ .vector_abi = .llvm_stack_align_8, .dialect = dialect }, src, &.{
            .{ "s4f32", "comptime_int = 16" },
            .{ "a4f32", "comptime_int = 8" },
            .{ "a8f32", "comptime_int = 8" },
            .{ "s3u8", "comptime_int = 4" },
            .{ "a3u8", "comptime_int = 4" },
            .{ "s9u8", "comptime_int = 16" },
            .{ "a5u64", "comptime_int = 8" },
            .{ "s16u64", "comptime_int = 128" },
            .{ "s0", "comptime_int = 0" },
            .{ "a0", "comptime_int = 1" },
            .{ "a_struct", "comptime_int = 8" },
            .{ "s_opt", "comptime_int = 24" },
            .{ "bits", "comptime_int = 15" },
        });
    }
    // Zig 0.17.0 pads the byte size to the alignment, 0.17.1 rounds it up to a power of 2
    try expectTypesTargeted(.{ .vector_abi = .llvm_stack_align_8, .dialect = .zig_0_17_0 }, src, &.{
        .{ "s17u8", "comptime_int = 24" },
        .{ "s5u64", "comptime_int = 40" },
        .{ "s_struct", "comptime_int = 48" },
        .{ "s_union", "comptime_int = 32" },
        .{ "s_array", "comptime_int = 80" },
    });
    try expectTypesTargeted(.{ .vector_abi = .llvm_stack_align_8, .dialect = .zig_0_17_1 }, src, &.{
        .{ "s17u8", "comptime_int = 32" },
        .{ "s5u64", "comptime_int = 64" },
        .{ "s_struct", "comptime_int = 72" },
        .{ "s_union", "comptime_int = 40" },
        .{ "s_array", "comptime_int = 128" },
    });
}

test "pointer layouts follow the target and the user's zig" {
    // Expected values are the results of `zig build-obj` of each version; only AVR differs, where
    // the maximum integer alignment is below the size of a pointer
    const src =
        \\const S = struct { a: u8, p: *u8 };
        \\const E = struct { a: u8, s: []u8 };
        \\const a_ptr = @alignOf(*u8);
        \\const s_ptr = @sizeOf(*u8);
        \\const a_slice = @alignOf([]u8);
        \\const s_slice = @sizeOf([]u8);
        \\const a_opt = @alignOf(?*u8);
        \\const s_s = @sizeOf(S);
        \\const a_s = @alignOf(S);
        \\const s_e = @sizeOf(E);
    ;
    const Dialect = @import("../syntax/Parse.zig").Dialect;
    for ([_]struct { []const u8, Dialect, u64, u64, u64, u64 }{
        .{ "avr-freestanding-none", .zig_0_17_0, 2, 2, 4, 6 },
        .{ "avr-freestanding-none", .zig_0_17_1, 1, 2, 3, 5 },
        .{ "msp430-freestanding-none", .zig_0_17_0, 2, 2, 4, 6 },
        .{ "msp430-freestanding-none", .zig_0_17_1, 2, 2, 4, 6 },
        .{ "m68k-linux-musl", .zig_0_17_0, 4, 4, 8, 12 },
        .{ "m68k-linux-musl", .zig_0_17_1, 4, 4, 8, 12 },
        .{ "wasm32-freestanding-none", .zig_0_17_0, 4, 4, 8, 12 },
        .{ "wasm32-freestanding-none", .zig_0_17_1, 4, 4, 8, 12 },
        .{ "x86_64-linux-musl", .zig_0_17_0, 8, 8, 16, 24 },
        .{ "x86_64-linux-musl", .zig_0_17_1, 8, 8, 16, 24 },
    }) |case| {
        const triple, const dialect, const alignment, const size, const s_size, const e_size = case;
        var target = try targetOf(triple, null);
        target.dialect = dialect;
        var buf: [5][32]u8 = undefined;
        const a = try std.fmt.bufPrint(&buf[0], "comptime_int = {d}", .{alignment});
        try expectTypesTargeted(target, src, &.{
            .{ "a_ptr", a },
            .{ "s_ptr", try std.fmt.bufPrint(&buf[1], "comptime_int = {d}", .{size}) },
            .{ "a_slice", a },
            .{ "s_slice", try std.fmt.bufPrint(&buf[2], "comptime_int = {d}", .{2 * size}) },
            .{ "a_opt", a },
            .{ "s_s", try std.fmt.bufPrint(&buf[3], "comptime_int = {d}", .{s_size}) },
            .{ "a_s", a },
            .{ "s_e", try std.fmt.bufPrint(&buf[4], "comptime_int = {d}", .{e_size}) },
        });
    }
}

/// Target parameters for `arch_os_abi` and the CPU (as with the compiler's `-target` / `-mcpu`):
/// pointer bit width and layout rules of scalar types
fn targetOf(arch_os_abi: []const u8, cpu: ?[]const u8) !InternPool.Target {
    const query = try std.Target.Query.parse(.{ .arch_os_abi = arch_os_abi, .cpu_features = cpu });
    const t = try std.zig.system.resolveTargetQuery(testing.io, query);
    return .{ .pointer_bits = t.ptrBitWidth(), .scalar_abi = .of(&t) };
}

/// Types whose layout varies by target: `s_T` / `a_T` is `@sizeOf(T)` / `@alignOf(T)`
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

/// Results of `target_layout_src` on the target: `expected[i]` is the size and alignment of
/// `target_layout_types[i]` (null when unknown)
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
    // Expected values are the results of zig 0.17.0 (printed with @compileError in
    // `zig build-obj -target <target>`). Type order:
    // u24, u64, u128, f80, f128, c_int, c_longdouble, S
    try expectTargetLayouts(try targetOf("x86_64-linux-musl", null), .{ .{ 4, 4 }, .{ 8, 8 }, .{ 16, 16 }, .{ 16, 16 }, .{ 16, 16 }, .{ 4, 4 }, .{ 16, 16 }, .{ 32, 16 } }, 4294967295);
    // The maximum alignment of integers is 4; long double is 80 bits with 4-byte alignment
    try expectTargetLayouts(try targetOf("x86-linux-musl", null), .{ .{ 4, 4 }, .{ 8, 4 }, .{ 16, 4 }, .{ 12, 4 }, .{ 16, 16 }, .{ 4, 4 }, .{ 12, 4 }, .{ 24, 4 } }, 4294967295);
    // The layout also depends on the OS: on Windows the maximum alignment of integers is 8
    try expectTargetLayouts(try targetOf("x86-windows-gnu", null), .{ .{ 4, 4 }, .{ 8, 8 }, .{ 16, 8 }, .{ 12, 4 }, .{ 16, 16 }, .{ 4, 4 }, .{ 12, 4 }, .{ 24, 8 } }, 4294967295);
    // long double is 128 bits: f80 uses the soft-float layout (u64 and u16)
    try expectTargetLayouts(try targetOf("aarch64-linux-musl", null), .{ .{ 4, 4 }, .{ 8, 8 }, .{ 16, 16 }, .{ 16, 8 }, .{ 16, 16 }, .{ 4, 4 }, .{ 16, 16 }, .{ 32, 8 } }, 4294967295);
    try expectTargetLayouts(try targetOf("arm-linux-musleabihf", null), .{ .{ 4, 4 }, .{ 8, 8 }, .{ 16, 8 }, .{ 16, 8 }, .{ 16, 8 }, .{ 4, 4 }, .{ 8, 8 }, .{ 32, 8 } }, 4294967295);
    try expectTargetLayouts(try targetOf("riscv32-freestanding-none", null), .{ .{ 4, 4 }, .{ 8, 8 }, .{ 16, 8 }, .{ 16, 8 }, .{ 16, 16 }, .{ 4, 4 }, .{ 16, 16 }, .{ 32, 8 } }, 4294967295);
    // AVR: integers and floats are 1-byte aligned, c_int is 16 bits;
    // std does not define the size of a 32-bit long double, so it is unknown
    try expectTargetLayouts(try targetOf("avr-freestanding-none", "atmega328p"), .{ .{ 3, 1 }, .{ 8, 1 }, .{ 16, 1 }, .{ 10, 1 }, .{ 16, 1 }, .{ 2, 1 }, null, .{ 21, 1 } }, 65535);
    try expectTargetLayouts(try targetOf("msp430-freestanding-none", null), .{ .{ 4, 2 }, .{ 8, 2 }, .{ 16, 2 }, .{ 10, 2 }, .{ 16, 2 }, .{ 2, 2 }, .{ 8, 2 }, .{ 22, 2 } }, 65535);
}

test "type layouts with several targets keep only what the targets agree on" {
    const x86_64 = try targetOf("x86_64-linux-musl", null);
    const x86 = try targetOf("x86-linux-musl", null);
    const src = target_layout_src;
    // The maximum alignments of integers are 16 and 4: integers of at most 4 bytes still have a
    // definite layout; f128 is the same on both
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
    // Unknown target: only integers of at most 1 byte have a definite layout;
    // the bit widths of floats do not depend on the target
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
    // Expected values are the results of zig 0.17.0
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
        // Comptime-known values (including `{}` and strings) are comptime fields;
        // vars, parameters, function calls and loop captures are runtime
        .{ "t1", "struct { comptime u8 = 1, u32 }" },
        .{ "t2", "struct { u8, u32, u64 }" },
        .{ "t3", "struct { u8, comptime void = {}, u32 }" },
        .{ "t4", "struct { comptime comptime_int = 5, comptime *const [2:0]u8 = \"hi\", u32 }" },
        .{ "t5", "struct { u32 }" },
        .{ "tc", "struct { u32 }" },
        .{ "tl", "struct { u8 }" },
        .{ "a1", "struct { comptime a: u8 = 1, b: u32 }" },
        // The value of a comptime field belongs to the type
        .{ "first", "u8 = 1" },
        // Tuples are laid out in declaration order and comptime fields take no space;
        // anonymous structs are like auto structs and are reordered by alignment
        .{ "s1", "comptime_int = 4" },
        .{ "s2", "comptime_int = 16" },
        .{ "o2", "comptime_int = 4" },
        .{ "s3", "comptime_int = 8" },
        .{ "s4", "comptime_int = 4" },
        .{ "sa1", "comptime_int = 4" },
        .{ "sa2", "comptime_int = 16" },
        .{ "oa2", "comptime_int = 12" },
        // The result of an inline call computed from comptime-known values is comptime-known
        .{ "tu", "struct { comptime u32 = 1 } = .{ 1 }" },
        .{ "su", "comptime_int = 0" },
        .{ "empty", "@TypeOf(.{}) = .{}" },
        // All fields are comptime fields
        .{ "s0", "comptime_int = 0" },
    });
}

test "comptime-known slices in tuple literals are comptime fields that anytype callees can read" {
    // A field holding a slice of a string was neither a comptime nor a runtime field, so the
    // instance of a callee receiving the tuple through anytype had no value for it.
    try expectTypes(
        \\fn lenOfArg(args: anytype) usize {
        \\    return args[0].len;
        \\}
        \\fn RetArr(args: anytype) type {
        \\    return [lenOfArg(args)]u8;
        \\}
        \\fn retTypeUsesArg(args: anytype) [lenOfArg(args)]u8 {
        \\    return @splat(1);
        \\}
        \\inline fn retTypeInline(args: anytype) [lenOfArg(args)]u8 {
        \\    return @splat(1);
        \\}
        \\const slice_t = @TypeOf(.{@as([]const u8, "abc")});
        \\const mixed_t = @TypeOf(.{ @as([]const u8, "abc"), @as(u8, 1) });
        \\const anon_t = @TypeOf(.{ .a = @as([]const u8, "abc") });
        \\const ret_type_arg = @TypeOf(retTypeUsesArg(.{@as([]const u8, "abc")}));
        \\const ret_type_direct = RetArr(.{@as([]const u8, "abc")});
        \\const ret_type_inline = @TypeOf(retTypeInline(.{@as([]const u8, "abc")}));
        \\const var_field_t = blk: {
        \\    var buf: [2]u8 = "ab".*;
        \\    const t = .{@as([]u8, &buf)};
        \\    break :blk @TypeOf(t);
        \\};
        \\fn g(p: []const u8) void {
        \\    const with_runtime = .{ @as([]const u8, "xy"), p };
        \\    const in_fn = retTypeUsesArg(.{@as([]const u8, "ab")});
        \\    comptime var buf: [2]u8 = "ab".*;
        \\    const with_var = .{@as([]u8, &buf)};
        \\    _ = .{ with_runtime, in_fn, with_var };
        \\}
    , &.{
        .{ "slice_t", "type = struct { comptime []const u8 = \"abc\" }" },
        .{ "mixed_t", "type = struct { comptime []const u8 = \"abc\", comptime u8 = 1 }" },
        .{ "anon_t", "type = struct { comptime a: []const u8 = \"abc\" }" },
        .{ "ret_type_arg", "type = [3]u8" },
        .{ "ret_type_direct", "type = [3]u8" },
        .{ "ret_type_inline", "type = [3]u8" },
        .{ "with_runtime", "struct { comptime []const u8 = \"xy\", []const u8 }" },
        .{ "in_fn", "[2]u8" },
        // A field that refers to a comptime var is not a comptime field (zig 0.17.0 and 0.17.1)
        .{ "var_field_t", "type = struct { []u8 }" },
        .{ "with_var", "struct { []u8 }" },
    });
}

test "a comptime call evaluates its anytype arguments at comptime" {
    // A function returning `type` executes at comptime, but its anytype arguments were inferred
    // as runtime values: a slice argument had no value and `[s.len]u8` was `[_]u8`.
    try expectTypes(
        \\fn RetArrAny(s: anytype) type {
        \\    return [s.len]u8;
        \\}
        \\fn RetArrSlice(s: []const u8) type {
        \\    return [s.len]u8;
        \\}
        \\fn writeAndLen(s: anytype) type {
        \\    s[0] = 'z';
        \\    return [s.len]u8;
        \\}
        \\const name: []const u8 = "abc";
        \\const any_slice = RetArrAny(@as([]const u8, "abcd"));
        \\const any_decl = RetArrAny(name);
        \\const any_lit = RetArrAny("abcd");
        \\const slice_param = RetArrSlice("abcd");
        \\const write_len = blk: {
        \\    var buf: [3]u8 = "abc".*;
        \\    const T = writeAndLen(@as([]u8, &buf));
        \\    break :blk @sizeOf(T);
        \\};
        \\const write_byte = blk: {
        \\    var buf: [3]u8 = "abc".*;
        \\    _ = writeAndLen(@as([]u8, &buf));
        \\    break :blk buf[0];
        \\};
        \\fn g() void {
        \\    const in_fn = RetArrAny(@as([]const u8, "abcde"));
        \\    const in_fn_decl = RetArrAny(name);
        \\    _ = .{ in_fn, in_fn_decl };
        \\}
    , &.{
        .{ "any_slice", "type = [4]u8" },
        .{ "any_decl", "type = [3]u8" },
        .{ "any_lit", "type = [4]u8" },
        .{ "slice_param", "type = [4]u8" },
        .{ "in_fn", "type = [5]u8" },
        .{ "in_fn_decl", "type = [3]u8" },
        // The callee both reads the slice's length and writes through it into the caller's var
        .{ "write_len", "comptime_int = 3" },
        .{ "write_byte", "u8 = 122" },
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
        // @hasDecl counts only pub declarations
        .{ "has_hidden", "u16 = 2" },
        .{ "has_a", "u8 = 1" },
    });
}

test "deep dependency chains neither overflow nor pollute shallower results" {
    // The top of the chain is far beyond the stack limit: it is queried first,
    // and the result at the bottom of the chain is still correct
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

test "comptime vars modified through pointers, methods, fields and elements are not stale" {
    // Prevents keeping the initial value of a `comptime var` after writes other than `v = x`
    try expectTypes(
        \\fn bump(comptime p: *comptime_int) void {
        \\    p.* += 1;
        \\}
        \\fn advance(p: *u32, n: u32) void {
        \\    p.* += n;
        \\}
        \\const A = struct { a_field: u8 };
        \\const B = struct { b_field: u16 };
        \\const State = struct {
        \\    s: enum { a, b } = .a,
        \\    fn step(self: *State) void {
        \\        self.s = .b;
        \\    }
        \\};
        \\const S = struct { n: u32 = 0 };
        \\const c_s: S = .{};
        \\const c_a: [2]u32 = .{ 0, 0 };
        \\export fn entry() u32 {
        \\    comptime var m = 0;
        \\    comptime bump(&m);
        \\    const m_v = m;
        \\    const T = if (m == 0) A else B;
        \\    comptime var k = 10;
        \\    const p = comptime &k;
        \\    p.* = 20;
        \\    const k_v = k;
        \\    comptime var st: State = .{};
        \\    comptime st.step();
        \\    const st_v = st.s;
        \\    comptime var s = c_s;
        \\    s.n = 5;
        \\    const s_v = s.n;
        \\    comptime var a = c_a;
        \\    a[1] = 5;
        \\    const a_v = a[1];
        \\    comptime var params = [_]u8{ 1, 2 };
        \\    inline for (&params) |*q| q.* ^= 0xff;
        \\    const params_v = params[0];
        \\    comptime var i: u32 = 0;
        \\    inline while (i < 3) {
        \\        comptime advance(&i, 1);
        \\    }
        \\    const i_v = i;
        \\    comptime var d = 1;
        \\    d += 1;
        \\    const d_v = d;
        \\    _ = .{ m_v, T, k_v, st_v, s_v, a_v, params_v, i_v, d_v };
        \\    return 0;
        \\}
    , &.{
        .{ "m_v", "comptime_int" },
        .{ "T", "type" },
        .{ "k_v", "comptime_int" },
        .{ "st_v", "enum { a, b }" },
        .{ "s_v", "u32" },
        .{ "a_v", "u32" },
        .{ "params_v", "u8" },
        .{ "i_v", "u32" },
        // Direct modifications are still tracked
        .{ "d_v", "comptime_int = 2" },
    });
}

/// Type of the binding `needle` when the loop variable `seed` takes the value of iteration `index`
fn iterationTypeAt(w: *World, file: FileId, text: []const u8, needle: []const u8, seed: []const u8, index: u32) ![]const u8 {
    const offset = try wordAt(text, needle, 0);
    const seed_offset = try wordAt(text, seed, 0);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    const item = try r.ownerAt(file, offset, false) orelse return "no owner";
    const node = (try r.itemNode(file, item)).?;
    const owner = try r.ownerKey(file, item);
    const body = try ctx.get(database.hir.ItemBody, owner);
    const binding = for (body.bindings, 0..) |b, i| {
        if (b.range.start == seed_offset - node.offset) break i;
    } else return "no loop variable";
    const res = try ctx.get(queries.Infer, .{ .owner = owner, .mode = .full, .loop = .{ .binding = @intCast(binding), .index = index } });
    for (body.bindings, 0..) |b, i| if (b.range.start == offset - node.offset) return render.typedValueAlloc(&r, res.bindings[i]);
    return "no binding";
}

test "later loop iterations see edits that change only the comptime vars an iteration leaves" {
    // Prevents keeping a stale iteration through early cutoff when an edit changes only the value
    // an iteration leaves in an outer comptime var (the start of the next iteration); expected
    // types are the results of zig 0.17.0
    const head =
        \\pub fn main() void {
        \\    comptime var acc: u32 = 1;
        \\    inline for (.{ u8, u16 }) |T| {
        \\        if (T == u16) {
        \\            const x: [acc]T = undefined;
        \\            _ = x;
        \\        }
        \\
    ;
    const before = head ++ "        acc *= 2;\n    }\n}\n";
    const after = head ++ "        acc += 2;\n    }\n}\n";
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const f = try w.add("/p/main.zig", before);
    try testing.expectEqualStrings("[2]u16 = undefined", try iterationTypeAt(&w, f.file, before, "x", "T", 1));
    _ = try w.add("/p/main.zig", after);
    try testing.expectEqualStrings("[3]u16 = undefined", try iterationTypeAt(&w, f.file, after, "x", "T", 1));
}

test "containers in an inline loop body read the loop variables without a value" {
    // Prevents a container in the loop body from reading the loop variables of iteration
    // 4294967295, the index of an undetermined iteration. Expected values: zig 0.17.0 and 0.17.1
    // give each unrolled iteration its own value (`range_v` is 0, 1 and 2, `index_v` 5 and 6,
    // `counted_v` 0, 1 and 2, `len_a` `[1]u8` and `[2]u8`, `len_n` 1 and 2, `elem_p`
    // `*align(4) const u8`, `*align(1) const u8` and `*align(2) const u8`), so the loop as a whole has
    // none; `prong_t` is `u8` in both prongs.
    try expectTypes(
        \\const arr align(4) = [_]u8{ 1, 2, 3 };
        \\const U = union(enum) { a: u8, b: u8 };
        \\fn range() void {
        \\    inline for (0..3) |i| {
        \\        const S = struct { const v = i; };
        \\        const range_v = S.v;
        \\        _ = range_v;
        \\    }
        \\}
        \\fn indexed() void {
        \\    inline for (.{ 'a', 'b' }, 5..) |c, idx| {
        \\        const S = struct { const v = idx; const ch = c; };
        \\        const index_v = S.v;
        \\        const index_c = S.ch;
        \\        _ = .{ index_v, index_c };
        \\    }
        \\}
        \\fn counted() void {
        \\    comptime var sum: usize = 0;
        \\    inline for (0..3) |i| {
        \\        sum += i;
        \\        const S = struct { const v = i; };
        \\        const counted_v = S.v;
        \\        _ = counted_v;
        \\    }
        \\}
        \\fn lengths() void {
        \\    inline for (1..3) |i| {
        \\        const S = struct { const A = [i]u8; const n = @sizeOf([i]u8); };
        \\        const len_a = S.A;
        \\        const len_n = S.n;
        \\        _ = .{ len_a, len_n };
        \\    }
        \\}
        \\fn aligned() void {
        \\    inline for (&arr) |*p| {
        \\        const S = struct { const q = p; };
        \\        const elem_p = S.q;
        \\        _ = elem_p;
        \\    }
        \\}
        \\fn prong(u: U) void {
        \\    switch (u) {
        \\        inline else => |payload| {
        \\            const S = struct { const T = @TypeOf(payload); };
        \\            const prong_t = S.T;
        \\            _ = prong_t;
        \\        },
        \\    }
        \\}
    , &.{
        .{ "range_v", "usize" },
        .{ "index_v", "usize" },
        .{ "index_c", "comptime_int" },
        .{ "counted_v", "usize" },
        .{ "len_a", "type = [i]u8" },
        .{ "len_n", "comptime_int" },
        .{ "elem_p", "*align(unknown) const u8" },
        .{ "prong_t", "type = u8" },
    });
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
        // Array length is a comptime context:
        // calls to ordinary functions are also evaluated by the interpreter
        .{ "A", "type = [8]u8" },
        .{ "N", "type = ??u8" },
        .{ "F", "type = u16" },
        .{ "C", "type = [3]u8" },
        // Array written through a pointer capture
        .{ "third", "u8 = 4" },
        .{ "S", "type = u8" },
    });
}

test "anytype arguments do not expand large arrays" {
    // Previously: anytype arguments were evaluated as a comptime context,
    // and slicing a huge array expanded its elements one by one in the interpreter
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
        .{ "ext", "fn (*const u32, u32) callconv(.c) bool" },
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
        .{ "FT", "type = fn (u8, ...) callconv(.c) void" },
        .{ "f", "fn (u8, ...) callconv(.c) void" },
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
        // The two declarations are the same type: the comparison is comptime-known,
        // so only the then branch is taken
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
        // Comptime fields of a tuple literal: the value belongs to the type
        .{ "k0", "comptime_int = 5" },
        .{ "k1", "bool = true" },
    });
}

test "peer types of tuples, also when destructuring" {
    try expectTypes(
        \\fn f(rest: []const u8) !void {
        \\    const a, const b = if (rest.len > 3) blk: {
        \\        break :blk .{ rest[2..4], rest[4..] };
        \\    } else if (rest.len > 1) .{ "", rest } else return error.X;
        \\    const c, const d = if (rest.len > 2) .{ rest[0..1], @as(u8, 1) } else .{ rest[1..], @as(u16, 2) };
        \\    const t = if (rest.len > 2) .{ rest[0..1], @as(u8, 1) } else .{ rest[1..], @as(u16, 2) };
        \\    const u = if (rest.len > 2) .{ @as(u8, 1), true } else .{ @as(u8, 1), true };
        \\    const v = if (rest.len > 2) .{ @as(u8, 1), rest } else .{ @as(u8, 2), rest };
        \\    _ = .{ a, b, c, d, t, u, v };
        \\}
    , &.{
        .{ "a", "[]const u8" },
        .{ "b", "[]const u8" },
        .{ "c", "[]const u8" },
        .{ "d", "u16" },
        .{ "t", "struct { []const u8, u16 }" },
        .{ "u", "struct { comptime u8 = 1, comptime bool = true }" },
        .{ "v", "struct { u8, []const u8 }" },
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
        // Slicing to the end (including an end equal to the length) keeps the array's sentinel
        .{ "t10", "*[6:0]u8" },
        .{ "t11", "*[8:0]u8" },
        .{ "t12", "[*]u8" },
        .{ "t13", "[:0]const u8" },
        .{ "t14", "[*:0]const u8" },
        .{ "t15", "[:0]u8" },
        .{ "t16", "*[2]u8" },
        .{ "t17", "*[2:1]u8" },
        // A pointer to a single element is sliced as an array of length 1
        .{ "t18", "*[1]u8" },
    });
}

test "dereferencing a comptime-known slice gives an array" {
    // Prevents typing `slice.*` as the element type (`u16` for `[]const u16`)
    try expectTypes(
        \\const slice: []const u16 = &.{ 1, 2, 3 };
        \\const arr = slice.*;
        \\const n = arr.len;
        \\const ap = &slice.*;
        \\const zs: [:0]const u8 = "hello";
        \\const zarr = zs.*;
        \\const sz = @sizeOf(@TypeOf(arr));
        \\const cat = arr ++ arr;
        \\fn get() []const u8 {
        \\    return "abc";
        \\}
        \\fn probe() void {
        \\    const cp = comptime get().*;
        \\    const s2: []const u16 = &.{ 4, 5 };
        \\    const a2 = s2.*;
        \\    _ = .{ cp, a2 };
        \\}
    , &.{
        .{ "arr", "[3]u16 = .{ 1, 2, 3 }" },
        .{ "n", "usize = 3" },
        .{ "ap", "*const [3]u16 = &.{ 1, 2, 3 }" },
        .{ "zarr", "[5:0]u8 = \"hello\"" },
        .{ "sz", "comptime_int = 6" },
        .{ "cat", "[6]u16 = .{ 1, 2, 3, 1, 2, 3 }" },
        .{ "cp", "[3]u8 = \"abc\"" },
        .{ "a2", "[2]u16 = .{ 4, 5 }" },
    });
}

test "dereferencing a comptime-known slice in a function body" {
    // Prevents inferring `slice.*` and `&slice.*` as unknown
    try expectTypes(
        \\fn probe(rt: []const u16) void {
        \\    const slice: []const u16 = &.{ 1, 2, 3 };
        \\    const array = slice.*;
        \\    const array_ptr = &slice.*;
        \\    const z: [:0]const u16 = &.{ 1, 2, 3 };
        \\    const za = z.*;
        \\    var v: []const u16 = &.{ 1, 2 };
        \\    v = rt;
        \\    const r1 = rt.*;
        \\    const r2 = v.*;
        \\    _ = .{ array, array_ptr, za, r1, r2 };
        \\}
    , &.{
        .{ "array", "[3]u16 = .{ 1, 2, 3 }" },
        .{ "array_ptr", "*const [3]u16 = &.{ 1, 2, 3 }" },
        .{ "za", "[3:0]u16 = .{ 1, 2, 3 }" },
        // Runtime-known slices cannot be dereferenced
        .{ "r1", "unknown" },
        .{ "r2", "unknown" },
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
        // When only one side has a sentinel, it is kept; when the sentinels differ, there is none
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
        // Vectors compare element-wise
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
        // Tagged union: the integer value of the tag
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

test "GPU, wasm, SPIR-V and C variadic builtins have the compiler's result types" {
    // Expected values are the results of zig 0.17.0: `@compileLog` prints `type` for
    // `@TypeOf(@SpirvType(.sampler))`, `u32` for `@workItemId(0)`, `@workGroupId(0)` and
    // `@workGroupSize(0)` (spirv64-opencl), `usize` and `isize` for `@wasmMemorySize(0)` and
    // `@wasmMemoryGrow(0, 1)` (wasm32-freestanding), `lang.VaListX86_64` for `@cVaStart()` and
    // `@cVaCopy(&va)`, `c_int` for `@cVaArg(&va, c_int)` and `void` for `@cVaEnd(&cp)`
    // (x86_64-linux; hover shows the container name without its namespace); none of these
    // results may be unknown
    try expectStdTypesBuiltin(
        \\const std = @import("std");
        \\pub const cpu: std.Target.Cpu = .{ .arch = .x86_64, .model = undefined, .features = undefined };
        \\pub const os: std.Target.Os = .{ .tag = .linux, .version_range = undefined };
    ,
        \\pub const Sampler = @SpirvType(.sampler);
        \\fn shader() void {
        \\    const L = @SpirvType(.sampler);
        \\    const c = @workItemId(0);
        \\    const g = @workGroupId(0);
        \\    const s = @workGroupSize(0);
        \\    _ = .{ L, c, g, s };
        \\}
        \\fn wasm() isize {
        \\    const a = @wasmMemorySize(0);
        \\    const b = @wasmMemoryGrow(0, 1);
        \\    _ = a;
        \\    return b;
        \\}
        \\fn sum(n: c_int, ...) callconv(.c) c_int {
        \\    var va = @cVaStart();
        \\    const x = @cVaArg(&va, c_int);
        \\    var cp = @cVaCopy(&va);
        \\    const e = @cVaEnd(&cp);
        \\    _ = e;
        \\    return n + x;
        \\}
    , &.{
        .{ "Sampler", "type" },
        .{ "L", "type" },
        .{ "c", "u32" },
        .{ "g", "u32" },
        .{ "s", "u32" },
        .{ "a", "usize" },
        .{ "b", "isize" },
        .{ "va", "VaListX86_64" },
        .{ "x", "c_int" },
        .{ "cp", "VaListX86_64" },
        .{ "e", "void" },
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
        // The destination type of the conversion drops the error union and optional
        .{ "@enumFromInt(n)", "E" },
        .{ "pk", "P" },
        // Result types of arguments: the backing integer, the element types of vectors and slices,
        // the type argument of atomic operations
        .{ "61", "u12 = 61" },
        .{ "62", "u8 = 62" },
        .{ "63", "u16 = 63" },
        .{ "48", "u32 = 48" },
        // `@alignCast(@fieldParentPtr(...))` is merged into one conversion:
        // the inner call takes the result type of the outer one
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
        // The right-hand side of a shift is `Log2Int(T)`
        .{ "31", "u5 = 31" },
        .{ "29", "u5 = 29" },
        // The capture of a prong with several items is the peer type of the field types;
        // the second capture is the tag
        .{ "pay", "u16" },
        .{ "tag", "Tag" },
        .{ "41", "f32 = 41" },
        .{ "43", "u8 = 43" },
        .{ "45", "u16 = 45" },
        .{ ".{ 46, 47 }", "[2]u16" },
        // The value of `continue` in a labeled switch is inferred from the operand's type
        .{ "49", "u8 = 49" },
        // The break and else of a loop take the loop's result type
        .{ "72", "u8 = 72" },
        .{ "73", "u8 = 73" },
        // Values of enum members are inferred from the tag type
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
        // Pointers to arrays of different lengths unify to a slice;
        // the sentinel is kept only when both sides have the same one
        .{ "s1", "[:0]const u8" },
        .{ "s2", "[]const u8" },
        .{ "s3", "[]const u8" },
        .{ "s4", "[]u8" },
        .{ "s5", "[*:0]const u8" },
        .{ "s6", "[]const u8" },
        .{ "s7", "*const [3]u8" },
        .{ "s8", "[:0]const u8" },
        // An optional and the other side: the peer type of the payloads, wrapped in an optional
        .{ "s9", "?[]const u8" },
    });
}

test "pointer attributes are part of the pointer type" {
    // Prevents `*align(1) u32`, `*volatile T` and `*allowzero T` from being the plain pointer type
    try expectTypes(
        \\const Reg = packed struct(u32) { en: bool, _pad: u31 };
        \\const P = *align(1) u32;
        \\const t_eq = if (P == *u32) @as(u8, 1) else @as(u16, 2);
        \\const t_nat = if (*align(4) u32 == *u32) @as(u8, 1) else @as(u16, 2);
        \\const t_same = if (*align(1) u32 == P) @as(u8, 1) else @as(u16, 2);
        \\const t_vol = if (*volatile u8 == *u8) @as(u8, 1) else @as(u16, 2);
        \\const t_bit = if (*align(1:0:1) u8 == *align(1) u8) @as(u8, 1) else @as(u16, 2);
        \\fn f(addr: usize, reg: *volatile u32, buf: []align(16) u8) void {
        \\    const a4 = @as(*volatile Reg, @ptrFromInt(addr));
        \\    const a5 = @as(*allowzero u8, @ptrFromInt(addr));
        \\    const bp = @as(*align(4:8:4) u8, @ptrFromInt(addr));
        \\    const all: [:0]allowzero align(2) const volatile u16 = @ptrCast(buf);
        \\    _ = .{ reg, buf, a4, a5, bp, all };
        \\}
    , &.{
        .{ "t_eq", "u16 = 2" },
        .{ "t_nat", "u16 = 2" },
        .{ "t_same", "u8 = 1" },
        .{ "t_vol", "u16 = 2" },
        .{ "t_bit", "u8 = 1" },
        .{ "P", "type = *align(1) u32" },
        .{ "reg", "*volatile u32" },
        .{ "buf", "[]align(16) u8" },
        .{ "a4", "*volatile Reg" },
        .{ "a5", "*allowzero u8" },
        .{ "bp", "*align(4:8:4) u8" },
        .{ "all", "[:0]allowzero align(2) const volatile u16" },
    });
}

test "pointers to fields, elements and aligned variables carry their attributes" {
    // Prevents `&reg.en` of a packed field and `&p.x` through an attributed pointer from being
    // plain pointers
    try expectTypes(
        \\const Reg = packed struct(u32) { en: bool, _pad: u31 };
        \\const S = extern struct { a: u8, b: u32 };
        \\const A = struct { x: u8 align(4), y: u32 };
        \\var global: u32 align(8) = 0;
        \\fn f(reg: *Reg, s: *S, ua: *align(1) A, v: *volatile A, arr: *align(8) [4]u8, n: usize) void {
        \\    var local: [4]u8 align(16) = undefined;
        \\    const a7 = &reg.en;
        \\    const sa = &s.a;
        \\    const sb = &s.b;
        \\    const ax = &ua.x;
        \\    const ay = &ua.y;
        \\    const vy = &v.y;
        \\    const e0 = &arr[0];
        \\    const e1 = &arr[1];
        \\    const er = &arr[n];
        \\    const g = &global;
        \\    const l = &local;
        \\    _ = .{ a7, sa, sb, ax, ay, vy, e0, e1, er, g, l };
        \\}
    , &.{
        .{ "a7", "*align(4:0:4) bool" },
        .{ "sa", "*align(4) u8" },
        .{ "sb", "*u32" },
        .{ "ax", "*align(1) u8" },
        .{ "ay", "*align(1) u32" },
        .{ "vy", "*volatile u32" },
        .{ "e0", "*align(8) u8" },
        .{ "e1", "*align(1) u8" },
        .{ "er", "*align(1) u8" },
        .{ "g", "*align(8) u32" },
        .{ "l", "*align(16) [4]u8" },
    });
}

test "slices, pointer arithmetic, captures and peers keep pointer attributes" {
    // Prevents derived pointers from dropping the attributes of the pointer they come from.
    // Expected values: zig 0.17.0 `@compileLog(@TypeOf(...))` of each name.
    try expectTypes(
        \\const U = union(enum) { a: u32, b: u8 };
        \\const E = error{X};
        \\fn f(s: []align(16) u32, m: [*]align(16) u32, pa: *align(16) [8]u32, sv: []volatile u8, za: [*]allowzero u8, cp: [*c]align(16) u32, n: usize, sa: []allowzero u8, pv: *volatile u32) void {
        \\    var arr: [8]u32 align(16) = undefined;
        \\    const s1 = s[1..n];
        \\    const s2 = s[2..];
        \\    const s4 = s[4..8];
        \\    const sp = s.ptr;
        \\    const pp = pa.ptr;
        \\    const m1 = m[1..];
        \\    const m2 = m[2..n];
        \\    const mo = m + 1;
        \\    const mn = m - n;
        \\    const mz = m + 0;
        \\    const p1 = pa[1..];
        \\    const p4 = pa[4..n];
        \\    const a1 = arr[1..3];
        \\    const a0 = arr[0..];
        \\    const v1 = sv[1..];
        \\    const z0 = za[0..n];
        \\    const z1 = za[1..n];
        \\    const za1 = za + 1;
        \\    const c1 = cp[1..n];
        \\    const c2 = cp + 2;
        \\    const sk = s[n..][0..4];
        \\    const pv1 = pv[0..1];
        \\    _ = .{ s1, s2, s4, sp, pp, m1, m2, mo, mn, mz, p1, p4, a1, a0, v1, z0, z1, za1, c1, c2, sk, pv1, sa };
        \\}
        \\fn g(s: []align(16) u32, sv: []volatile u8, sa: []allowzero u8, opt: *align(16) ?u32, eu: *align(16) (E!u32), u: *align(1) U, pv: *volatile u32) void {
        \\    var arr: [8]u32 align(16) = undefined;
        \\    for (s) |*fs| _ = fs;
        \\    for (&arr) |*fa| _ = fa;
        \\    for (sv) |*fv| _ = fv;
        \\    for (sa) |*fz| _ = fz;
        \\    if (opt.*) |*io| _ = io;
        \\    while (opt.*) |*wo| _ = wo;
        \\    if (eu.*) |*ie| _ = ie else |_| {}
        \\    switch (u.*) {
        \\        .a => |*ua| _ = ua,
        \\        .b => |*ub| _ = ub,
        \\    }
        \\    switch (pv.*) {
        \\        else => |*se| _ = se,
        \\    }
        \\}
        \\fn h(c: bool, a: *align(16) u32, b: *u32, v: *volatile u32, z: *allowzero u32, ma: [*]align(8) u32, mb: [*]u32, sa: []align(2) u16, sb: []u16, ac: *align(4) [4]u16, cp: [*c]align(2) u16, cq: [*c]u16, cv: [*c]volatile u16, pq: *align(8) u16) void {
        \\    const ab = if (c) a else b;
        \\    const bv = if (c) b else v;
        \\    const bz = if (c) b else z;
        \\    const mab = if (c) ma else mb;
        \\    const sac = if (c) sa else ac;
        \\    const acb = if (c) ac else sb;
        \\    const cpq = if (c) cp else cq;
        \\    const cqv = if (c) cq else cv;
        \\    const cqp = if (c) cq else pq;
        \\    _ = .{ ab, bv, bz, mab, sac, acb, cpq, cqv, cqp };
        \\}
    , &.{
        .{ "s1", "[]align(4) u32" },
        .{ "s2", "[]align(8) u32" },
        .{ "s4", "*align(16) [4]u32" },
        .{ "sp", "[*]align(16) u32" },
        .{ "pp", "[*]align(16) u32" },
        .{ "m1", "[*]align(4) u32" },
        .{ "m2", "[]align(8) u32" },
        .{ "mo", "[*]align(4) u32" },
        .{ "mn", "[*]align(4) u32" },
        .{ "mz", "[*]align(16) u32" },
        .{ "p1", "*align(4) [7]u32" },
        .{ "p4", "[]align(16) u32" },
        .{ "a1", "*align(4) [2]u32" },
        .{ "a0", "*align(16) [8]u32" },
        .{ "v1", "[]volatile u8" },
        .{ "z0", "[]allowzero u8" },
        .{ "z1", "[]u8" },
        .{ "za1", "[*]u8" },
        .{ "c1", "[]align(4) u32" },
        .{ "c2", "[*c]align(8) u32" },
        .{ "sk", "*align(4) [4]u32" },
        .{ "pv1", "*volatile [1]u32" },
        .{ "fs", "*align(4) u32" },
        .{ "fa", "*align(4) u32" },
        .{ "fv", "*volatile u8" },
        .{ "fz", "*allowzero u8" },
        .{ "io", "*align(16) u32" },
        .{ "wo", "*align(16) u32" },
        .{ "ie", "*u32" },
        .{ "ua", "*align(1) u32" },
        .{ "ub", "*u8" },
        .{ "se", "*volatile u32" },
        .{ "ab", "*align(4) u32" },
        .{ "bv", "*volatile u32" },
        .{ "bz", "*allowzero u32" },
        .{ "mab", "[*]align(4) u32" },
        .{ "sac", "[]align(2) u16" },
        .{ "acb", "[]align(2) u16" },
        .{ "cpq", "[*c]align(2) u16" },
        .{ "cqv", "[*c]volatile u16" },
        .{ "cqp", "[*c]align(2) u16" },
    });
}

test "inline for pointer captures take the alignment of each element" {
    // Prevents the capture of an inline for from taking the alignment of every iteration.
    // Expected values: zig 0.17.0 gives `*align(16) u32` for the first element and
    // `*align(4) u32` for the second one.
    try expectTypes(
        \\fn f() u32 {
        \\    var arr: [2]u32 align(16) = .{ 1, 2 };
        \\    var sum: u32 = 0;
        \\    inline for (&arr) |*x| sum += x.*;
        \\    return sum;
        \\}
    , &.{
        .{ "x", "*align(unknown) u32" },
    });
}

test "function types keep their calling convention" {
    // Prevents `fn (u8) callconv(.c) void` from being the Zig-callconv function type.
    // Expected values: zig 0.17.0 `@compileLog` of each name.
    try expectTypes(
        \\fn cfn(a: u8) callconv(.c) void { _ = a; }
        \\inline fn inl(a: u8) u8 { return a; }
        \\export fn exp(a: u8) u8 { return a; }
        \\extern fn ext(a: u8) u8;
        \\fn nak() callconv(.naked) void {}
        \\fn plain(a: u8) void { _ = a; }
        \\const FT = fn (u8) callconv(.c) void;
        \\const VT = fn (u8, ...) callconv(.c) void;
        \\const T_cfn = @TypeOf(cfn);
        \\const T_inl = @TypeOf(inl);
        \\const T_exp = @TypeOf(exp);
        \\const T_ext = @TypeOf(ext);
        \\const T_nak = @TypeOf(nak);
        \\const T_plain = @TypeOf(plain);
        \\const t_fn_eq = if (@TypeOf(cfn) == fn (u8) void) @as(u8, 1) else @as(u16, 2);
        \\const t_ft_eq = if (@TypeOf(cfn) == FT) @as(u8, 1) else @as(u16, 2);
        \\fn f() void {
        \\    const a6 = &cfn;
        \\    _ = a6;
        \\}
    , &.{
        .{ "FT", "type = fn (u8) callconv(.c) void" },
        .{ "VT", "type = fn (u8, ...) callconv(.c) void" },
        .{ "T_cfn", "type = fn (u8) callconv(.c) void" },
        .{ "T_inl", "type = fn (u8) callconv(.@\"inline\") u8" },
        .{ "T_exp", "type = fn (u8) callconv(.c) u8" },
        .{ "T_ext", "type = fn (u8) callconv(.c) u8" },
        .{ "T_nak", "type = fn () callconv(.naked) void" },
        .{ "T_plain", "type = fn (u8) void" },
        .{ "t_fn_eq", "u16 = 2" },
        .{ "t_ft_eq", "u8 = 1" },
        .{ "a6", "*const fn (u8) callconv(.c) void = &fn (u8) callconv(.c) void" },
    });
}

test "@typeInfo and @Fn keep the calling convention and genericity of functions" {
    // Prevents `@typeInfo` from reporting `.auto` and `is_generic = false` for every function.
    // Expected values: zig 0.17.0 `@compileLog` of each name on x86_64-linux-gnu, where
    // `@TypeOf(sysv)` is `fn (u8) callconv(.c) void` and `@TypeOf(win)` is
    // `fn (u8) callconv(.{ .x86_64_win = .{ .incoming_stack_alignment = null } }) void`.
    const src =
        \\fn cfn(a: u8) callconv(.c) void { _ = a; }
        \\fn gen(comptime T: type, x: T) T { return x; }
        \\fn gct(comptime x: u8) u8 { return x; }
        \\fn gany(x: anytype) void { _ = x; }
        \\inline fn inl(a: u8) u8 { return a; }
        \\fn nak() callconv(.naked) void {}
        \\fn sysv(a: u8) callconv(.{ .x86_64_sysv = .{} }) void { _ = a; }
        \\fn win(a: u8) callconv(.{ .x86_64_win = .{} }) void { _ = a; }
        \\const cc_auto = @intFromBool(@typeInfo(@TypeOf(cfn)).@"fn".attrs.@"callconv" == .auto);
        \\const cc_inl = @intFromBool(@typeInfo(@TypeOf(inl)).@"fn".attrs.@"callconv" == .@"inline");
        \\const cc_nak = @intFromBool(@typeInfo(@TypeOf(nak)).@"fn".attrs.@"callconv" == .naked);
        \\const isgen = @intFromBool(@typeInfo(@TypeOf(gen)).@"fn".is_generic);
        \\const isgen_ct = @intFromBool(@typeInfo(@TypeOf(gct)).@"fn".is_generic);
        \\const isgen_any = @intFromBool(@typeInfo(@TypeOf(gany)).@"fn".is_generic);
        \\const isgen_c = @intFromBool(@typeInfo(@TypeOf(cfn)).@"fn".is_generic);
        \\const R = @Fn(&.{u8}, &.{.{}}, void, .{ .@"callconv" = .c });
        \\const N = @Fn(&.{}, &.{}, void, .{ .@"callconv" = .naked });
        \\const r_eq = @intFromBool(R == @TypeOf(cfn));
        \\const T_sysv = @TypeOf(sysv);
        \\const T_win = @TypeOf(win);
        \\const sysv_eq = @intFromBool(@TypeOf(sysv) == @TypeOf(cfn));
    ;
    try expectStdTypesBuiltin(
        \\const std = @import("std");
        \\pub const target: std.Target = .{
        \\    .cpu = .{ .arch = .x86_64, .model = undefined, .features = undefined },
        \\    .os = .{ .tag = .linux, .version_range = undefined },
        \\    .abi = .gnu,
        \\    .ofmt = .elf,
        \\};
    , src, &.{
        .{ "cc_auto", "u1 = 0" },
        .{ "cc_inl", "u1 = 1" },
        .{ "cc_nak", "u1 = 1" },
        .{ "isgen", "u1 = 1" },
        .{ "isgen_ct", "u1 = 1" },
        .{ "isgen_any", "u1 = 1" },
        .{ "isgen_c", "u1 = 0" },
        .{ "R", "type = fn (u8) callconv(.c) void" },
        .{ "N", "type = fn () callconv(.naked) void" },
        .{ "r_eq", "u1 = 1" },
        .{ "T_sysv", "type = fn (u8) callconv(.c) void" },
        .{ "T_win", "type = fn (u8) callconv(.{ .x86_64_win = .{ .incoming_stack_alignment = null } }) void" },
        .{ "sysv_eq", "u1 = 1" },
    });
    // Without a target, the C calling convention has no value
    try expectStdTypes(src, &.{
        .{ "cc_auto", "u1" },
        .{ "cc_inl", "u1 = 1" },
        .{ "T_win", "type = fn (u8) callconv(unknown) void" },
        .{ "r_eq", "u1 = 1" },
    });
}
test "@tagName of the C calling convention follows the target" {
    // Expected values: `@compileLog` of each name with `zig build-obj -target <arch>-<os>-<abi>`;
    // zig 0.17.0 and 0.17.1 agree except for m68k-netbsd, where the 0.17.1 standard library
    // selects `m68k_sysv` and the 0.17.0 one `m68k_gnu`
    var env = @import("../project/ZigEnv.zig").query(testing.allocator, testing.io, null) catch return error.SkipZigTest;
    defer env.deinit(testing.allocator);
    const netbsd_m68k: []const u8 = if (std.mem.eql(u8, env.version, "0.17.0")) "m68k_gnu" else "m68k_sysv";
    const src =
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\pub const cc = @tagName(builtin.target.cCallingConvention().?);
        \\pub const cc_tag = @tagName(std.meta.activeTag(builtin.target.cCallingConvention().?));
    ;
    const targets = [_]struct { []const u8, []const u8, []const u8, []const u8, []const u8 }{
        .{ "x86_64", "windows", "gnu", "coff", "x86_64_win" },
        .{ "x86_64", "linux", "gnu", "elf", "x86_64_sysv" },
        .{ "x86", "windows", "gnu", "coff", "x86_mingw" },
        .{ "aarch64", "macos", "none", "macho", "aarch64_aapcs_darwin" },
        .{ "aarch64", "windows", "msvc", "coff", "aarch64_aapcs_win" },
        .{ "arm", "linux", "gnueabihf", "elf", "arm_aapcs_vfp" },
        .{ "wasm32", "wasi", "musl", "wasm", "wasm_mvp" },
        .{ "m68k", "linux", "gnu", "elf", "m68k_gnu" },
        .{ "m68k", "netbsd", "none", "elf", netbsd_m68k },
    };
    for (targets) |t| {
        var builtin_buf: [512]u8 = undefined;
        const builtin_text = try std.fmt.bufPrint(&builtin_buf,
            \\const std = @import("std");
            \\pub const target: std.Target = .{{
            \\    .cpu = .{{ .arch = .{s}, .model = undefined, .features = undefined }},
            \\    .os = .{{ .tag = .{s}, .version_range = undefined }},
            \\    .abi = .{s},
            \\    .ofmt = .{s},
            \\}};
        , .{ t[0], t[1], t[2], t[3] });
        var expected_buf: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, "*const [{d}:0]u8 = \"{s}\"", .{ t[4].len, t[4] });
        expectStdTypesBuiltin(builtin_text, src, &.{ .{ "cc", expected }, .{ "cc_tag", expected } }) catch |err| {
            std.debug.print("target {s}-{s}-{s}\n", .{ t[0], t[1], t[2] });
            return err;
        };
    }
}

test "@Fn coerces its arguments and gives the written function types" {
    // Prevents `@Fn(&.{}, &.{}, void, .{})` from being `fn () callconv(unknown) void` and
    // `&@splat(.{})` from having no result type.
    // Expected values: zig 0.17.0 and 0.17.1 (identical) `@compileLog` of each name.
    try expectStdTypes(
        \\const std = @import("std");
        \\const PA = std.builtin.Type.Fn.ParamAttributes;
        \\fn gna(noalias p: *u8, q: *const u8) void { p.* = q.*; }
        \\noinline fn gnoinl() void {}
        \\fn gct(comptime T: type, x: T) T { return x; }
        \\fn gerr() !u8 { return 1; }
        \\fn rt_dep(x: u8, y: @TypeOf(x)) u8 { return x + y; }
        \\fn tfn(T: type) void { _ = T; }
        \\const R = @Fn(&.{ u8, u16 }, &@splat(.{}), bool, .{});
        \\const R_cc = @Fn(&.{u8}, &@splat(.{}), void, .{ .@"callconv" = .c });
        \\const R_ret = @typeInfo(@Fn(&.{u8}, &@splat(.{}), bool, .{})).@"fn".return_type;
        \\const R_explicit = @Fn(&.{u8}, &[_]PA{.{}}, bool, .{});
        \\const R_typed = @Fn(&.{u8}, &@as([1]PA, @splat(.{})), bool, .{});
        \\const R_zero = @Fn(&.{}, &.{}, void, .{});
        \\const R_auto = @Fn(&.{}, &.{}, void, .{ .@"callconv" = .auto });
        \\const R_noalias = @Fn(&.{ *u8, *u8 }, &.{ .{ .@"noalias" = true }, .{} }, void, .{});
        \\const R_varargs = @Fn(&.{c_int}, &@splat(.{}), c_int, .{ .@"callconv" = .c, .varargs = true });
        \\const eq_zero = @Fn(&.{}, &.{}, void, .{}) == fn () void;
        \\const eq_splat = @Fn(&.{ u8, u16 }, &@splat(.{}), bool, .{}) == fn (u8, u16) bool;
        \\const eq_cc = @Fn(&.{u8}, &@splat(.{}), void, .{ .@"callconv" = .c }) == fn (u8) callconv(.c) void;
        \\const eq_noalias = @Fn(&.{ *u8, *const u8 }, &.{ .{ .@"noalias" = true }, .{} }, void, .{}) == @TypeOf(gna);
        \\const ne_noalias = @Fn(&.{ *u8, *const u8 }, &@splat(.{}), void, .{}) == @TypeOf(gna);
        \\const ne_comptime = (fn (comptime u8) void) == fn (u8) void;
        \\const ne_noinline = @TypeOf(gnoinl) == fn () void;
        \\const ne_anytype = (fn (anytype) void) == fn (comptime anytype) void;
        \\const eq_generic = @TypeOf(gct) == @TypeOf(gct);
        \\const isgen_tfn = @typeInfo(@TypeOf(tfn)).@"fn".is_generic;
        \\const isgen_ct = @typeInfo(fn (comptime u8) void).@"fn".is_generic;
        \\const isgen_rt_dep = @typeInfo(@TypeOf(rt_dep)).@"fn".is_generic;
        \\const rt_dep_param = @typeInfo(@TypeOf(rt_dep)).@"fn".param_types[1] == null;
        \\const gct_ret = @typeInfo(@TypeOf(gct)).@"fn".return_type == null;
        \\const any_param = @typeInfo(fn (anytype) void).@"fn".param_types[0] == null;
        \\const noalias_info = @typeInfo(@TypeOf(gna)).@"fn".param_attrs[0].@"noalias";
        \\const T_gna = @TypeOf(gna);
        \\const T_gnoinl = @TypeOf(gnoinl);
        \\const T_gct = @TypeOf(gct);
        \\const T_gerr = @TypeOf(gerr);
    , &.{
        .{ "R", "type = fn (u8, u16) bool" },
        .{ "R_cc", "type = fn (u8) callconv(.c) void" },
        .{ "R_ret", "?type = bool" },
        .{ "R_explicit", "type = fn (u8) bool" },
        .{ "R_typed", "type = fn (u8) bool" },
        .{ "R_zero", "type = fn () void" },
        .{ "R_auto", "type = fn () void" },
        .{ "R_noalias", "type = fn (noalias *u8, *u8) void" },
        .{ "R_varargs", "type = fn (c_int, ...) callconv(.c) c_int" },
        .{ "eq_zero", "bool = true" },
        .{ "eq_splat", "bool = true" },
        .{ "eq_cc", "bool = true" },
        .{ "eq_noalias", "bool = true" },
        .{ "ne_noalias", "bool = false" },
        .{ "ne_comptime", "bool = false" },
        .{ "ne_noinline", "bool = false" },
        .{ "ne_anytype", "bool = false" },
        .{ "eq_generic", "bool = true" },
        // A comptime-only parameter type makes the function generic
        .{ "isgen_tfn", "bool = true" },
        .{ "isgen_ct", "bool = true" },
        .{ "isgen_rt_dep", "bool = true" },
        .{ "rt_dep_param", "bool = true" },
        .{ "gct_ret", "bool = true" },
        .{ "any_param", "bool = true" },
        .{ "noalias_info", "bool = true" },
        .{ "T_gna", "type = fn (noalias *u8, *const u8) void" },
        .{ "T_gnoinl", "type = noinline fn () void" },
        .{ "T_gct", "type = fn (comptime type, anytype) anytype" },
        .{ "T_gerr", "type = fn () error{}!u8" },
    });
}

test "@typeInfo, @Pointer and std results keep pointer attributes" {
    // Prevents default attributes in `@typeInfo` and std results losing their alignment
    try expectStdTypes(
        \\const std = @import("std");
        \\const P = *align(1) u32;
        \\const malign = std.meta.alignment(P);
        \\const pvol = @intFromBool(@typeInfo(*volatile u8).pointer.attrs.@"volatile");
        \\const as_null = @intFromBool(@typeInfo(*u8).pointer.attrs.@"addrspace" == null);
        \\const nat_null = @intFromBool(@typeInfo(*u8).pointer.attrs.@"align" == null);
        \\const c_zero = @intFromBool(@typeInfo([*c]u8).pointer.attrs.@"allowzero");
        \\const t_as = if (*addrspace(.generic) u32 == *u32) @as(u8, 1) else @as(u16, 2);
        \\const R = @Pointer(.slice, .{ .@"volatile" = true, .@"addrspace" = .gs, .@"align" = 4 }, u8, null);
        \\const Q = @Pointer(.one, .{ .@"const" = true }, u8, null);
        \\pub fn probe(gpa: std.mem.Allocator, bytes: []u8, x: u32) !void {
        \\    const a1 = std.mem.asBytes(&x);
        \\    const a2 = std.mem.bytesAsValue(u32, bytes[0..4]);
        \\    const a3 = try gpa.alignedAlloc(u8, .@"16", 64);
        \\    const a8 = try gpa.alignedAlloc(u8, null, 64);
        \\    _ = .{ a1, a2, a3, a8 };
        \\}
    , &.{
        .{ "malign", "comptime_int = 1" },
        .{ "pvol", "u1 = 1" },
        .{ "as_null", "u1 = 0" },
        .{ "nat_null", "u1 = 1" },
        .{ "c_zero", "u1 = 1" },
        .{ "t_as", "u8 = 1" },
        .{ "R", "type = []align(4) addrspace(.gs) volatile u8" },
        .{ "Q", "type = *const u8" },
        .{ "a1", "*align(4) const [4]u8" },
        .{ "a2", "*align(1) u32" },
        .{ "a3", "[]align(16) u8" },
        .{ "a8", "[]align(1) u8" },
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
        // The condition depends on abstract parameters: the branches are slices of T whose
        // alignment depends on the parameter
        .{ "head", "[]align(unknown) T" },
        // Self-recursive type function: the container in this instance is taken
        .{ "S", "type = []align(unknown) T" },
        // Runtime condition: the value is not comptime-known
        .{ "x", "u32" },
    });
}

test "@hasDecl and @hasField on abstract parameters are unknown" {
    // Guards against the interpreter treating abstract parameters as not having the member:
    // in type annotations and comptime calls, the false branch would be selected
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
        // Container in an abstract instance: its members depend only on the source
        .{ "P", "type = u8" },
        .{ "real", "type = u32" },
    });
}

test "@hasField on slices, arrays and non-exhaustive enums" {
    // Prevents `@hasField` from being false for slice `ptr`/`len` and array `len`, and true
    // for the `_` of a non-exhaustive enum; expected values are the results of zig 0.17.0
    try expectStdTypes(
        \\const Point = struct { x: i32, y: i32 };
        \\fn Elem(comptime T: type) type {
        \\    return if (@hasField(T, "ptr")) @typeInfo(T).pointer.child else T;
        \\}
        \\fn hasLen(comptime T: type) bool {
        \\    return @hasField(T, "len");
        \\}
        \\fn hasUnder(comptime T: type) bool {
        \\    return @hasField(T, "_");
        \\}
        \\const E = Elem([]const Point);
        \\const A = Elem([3]Point);
        \\const al = @hasField([3]u8, "len");
        \\const ap = @hasField([3]u8, "ptr");
        \\const sx = @hasField([]u8, "x");
        \\const t = if (@hasField([]const u8, "len")) u1 else u2;
        \\const NE = enum(u8) { a, b, _ };
        \\const v = if (@hasField(NE, "_")) u1 else u2;
        \\const ve = @hasField(NE, "_");
        \\const ca = hasLen([2]u8);
        \\const cs = hasLen([]u8);
        \\const cn = hasUnder(NE);
    , &.{
        .{ "E", "type = Point" },
        .{ "A", "type = [3]Point" },
        .{ "al", "bool = true" },
        .{ "ap", "bool = false" },
        .{ "sx", "bool = false" },
        .{ "t", "type = u1" },
        .{ "v", "type = u2" },
        .{ "ve", "bool = false" },
        .{ "ca", "bool = true" },
        .{ "cs", "bool = true" },
        .{ "cn", "bool = false" },
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
        // The length is shown as in the source
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

test "an array length that a call instance cannot evaluate is unknown, not the callee's text" {
    // `print` returned `*const [measure(fmt):0]u8` at concrete call sites
    try expectTypes(
        \\extern fn external(n: usize) usize;
        \\fn measure(comptime fmt: []const u8) usize { return external(fmt.len); }
        \\fn print(comptime fmt: []const u8) *const [measure(fmt):0]u8 { return undefined; }
        \\fn mk(comptime n: usize) *const [n:0]u8 { return "abcdefgh"[0..n]; }
        \\fn abstract(comptime fmt: []const u8) void {
        \\    const inner = print(fmt);
        \\    _ = inner;
        \\}
        \\fn probe() void {
        \\    const s = print("{d}");
        \\    const m = mk(3);
        \\    const n = s.len;
        \\    const c = s[0];
        \\    const p = s.ptr;
        \\    const sl: []const u8 = s;
        \\    const z: [:0]const u8 = s;
        \\    const part = s[0..1];
        \\    const same = @TypeOf(s) == *const [3:0]u8;
        \\    const self = @TypeOf(s) == @TypeOf(s);
        \\    _ = .{ m, n, c, p, sl, z, part, same, self };
        \\}
    , &.{
        .{ "s", "*const [_:0]u8" },
        .{ "m", "*const [3:0]u8" },
        .{ "inner", "*const [measure(fmt):0]u8" },
        .{ "n", "usize" },
        .{ "c", "u8" },
        .{ "p", "[*:0]const u8" },
        .{ "sl", "[]const u8" },
        .{ "z", "[:0]const u8" },
        .{ "part", "*const [1]u8" },
        // A type with an unknown length is never known to equal another type, itself included
        .{ "same", "bool" },
        .{ "self", "bool" },
    });
}

/// A builtin with the target and optimize mode of the local machine: the standard library
/// selects its float tables by the optimize mode (`std.fmt.float`) and whether to use vectors by
/// the backend (`std.mem`)
const target_builtin =
    \\const std = @import("std");
    \\pub const mode: std.lang.Optimize = .debug;
    \\pub const cpu: std.Target.Cpu = .{ .arch = .x86_64, .model = undefined, .features = undefined };
    \\pub const os: std.Target.Os = .{ .tag = .linux, .version_range = undefined };
    \\pub const abi: std.Target.Abi = .gnu;
    \\pub const object_format: std.Target.ObjectFormat = .elf;
    \\pub const link_libc = false;
    \\pub const single_threaded = false;
    \\pub const zig_backend: std.lang.CompilerBackend = .stage2_llvm;
    \\pub const fuzz = false;
;

test "std.fmt.comptimePrint results keep their pointer, element and sentinel types" {
    // The results were shown with the callee's length text `count(fmt, args)`
    try expectStdTypesBuiltin(target_builtin,
        \\const std = @import("std");
        \\pub const version = std.fmt.comptimePrint("{d}.{d}.{d}", .{ 1, 22, 3 });
        \\fn probe() void {
        \\    const s = std.fmt.comptimePrint("{d}", .{3});
        \\    const n = s.len;
        \\    const named = std.fmt.comptimePrint("{s}!", .{@as([]const u8, "xyz")});
        \\    _ = .{ n, named };
        \\}
        \\pub const one_slice = std.fmt.comptimePrint("{s}", .{@as([]const u8, "bc")});
        \\pub const two_args = std.fmt.comptimePrint("{s}|{s}", .{ "a", @as([]const u8, "bc") });
    , &.{
        .{ "s", "*const [1:0]u8 = \"3\"" },
        .{ "version", "*const [6:0]u8 = \"1.22.3\"" },
        .{ "n", "usize = 1" },
        // Slice arguments: the tuple's comptime fields carry their values
        .{ "one_slice", "*const [2:0]u8 = \"bc\"" },
        .{ "two_args", "*const [4:0]u8 = \"a|bc\"" },
        .{ "named", "*const [4:0]u8 = \"xyz!\"" },
    });
}

test "std.fmt formats a character at comptime" {
    // `{c}` writes `@as(*const [1]u8, &c)`: the result used to have no value
    try expectStdTypesBuiltin(target_builtin,
        \\const std = @import("std");
        \\pub const char = std.fmt.comptimePrint("{c}", .{'z'});
        \\pub const mixed = std.fmt.comptimePrint("<{c}{c}|{d}>", .{ 'a', 'b', 42 });
        \\pub const padded = std.fmt.comptimePrint("[{c:>3}]", .{'q'});
        \\pub const counted = std.fmt.count("{c}", .{'z'});
        \\pub const printed = blk: {
        \\    var buf: [8]u8 = undefined;
        \\    break :blk (std.fmt.bufPrint(&buf, "{c}", .{'z'}) catch unreachable).len;
        \\};
    , &.{
        .{ "char", "*const [1:0]u8 = \"z\"" },
        .{ "mixed", "*const [7:0]u8 = \"<ab|42>\"" },
        .{ "padded", "*const [5:0]u8 = \"[  q]\"" },
        .{ "counted", "usize = 1" },
        .{ "printed", "usize = 1" },
    });
}

test "float formatting in std.fmt at comptime" {
    // Formatting an f128 reads the parts of the value as u128, which the interpreter stored as
    // i128: all operations on such values gave up.
    try expectStdTypesBuiltin(target_builtin,
        \\const std = @import("std");
        \\pub const decimal = std.fmt.comptimePrint("{d:3.1}", .{30.0});
        \\pub const precise = std.fmt.comptimePrint("{d:.3}", .{@as(f64, 1.0 / 3.0)});
        \\pub const scientific = std.fmt.comptimePrint("{e}", .{@as(f64, 0.05)});
        \\pub const wide = std.fmt.comptimePrint("{d}", .{@as(f128, 30.0)});
        \\pub const negative = std.fmt.comptimePrint("{d}", .{@as(f128, -1.25)});
    , &.{
        .{ "decimal", "*const [4:0]u8 = \"30.0\"" },
        .{ "precise", "*const [5:0]u8 = \"0.333\"" },
        .{ "scientific", "*const [4:0]u8 = \"5e-2\"" },
        .{ "wide", "*const [2:0]u8 = \"30\"" },
        .{ "negative", "*const [5:0]u8 = \"-1.25\"" },
    });
}

test "std.math.gcd and std.math.lcm at comptime" {
    // std.math.gcd shifts by `@intCast(@ctz(x))`: without the shift amount's result type the
    // calls had no value
    try expectStdTypes(
        \\const std = @import("std");
        \\const gcd_u32 = std.math.gcd(@as(u32, 48), 18);
        \\const gcd_ct = std.math.gcd(48, 18);
        \\const gcd_u8 = std.math.gcd(@as(u8, 48), @as(u8, 18));
        \\const gcd_u64 = std.math.gcd(@as(u64, 1 << 40), 3 << 20);
        \\const lcm_u32 = std.math.lcm(@as(u32, 4), 6);
    , &.{
        .{ "gcd_u32", "u32 = 6" },
        .{ "gcd_ct", "comptime_int = 6" },
        .{ "gcd_u8", "u8 = 6" },
        .{ "gcd_u64", "u64 = 1048576" },
        .{ "lcm_u32", "u32 = 12" },
    });
}

test "unsigned 128-bit integers above i128's range" {
    // The bit pattern of a u128 value at or above 2^127 was read back as a negative number.
    try expectStdTypes(
        \\const std = @import("std");
        \\const high: u128 = @as(u128, 1) << 127;
        \\const max: u128 = std.math.maxInt(u128);
        \\const shr: u128 = high >> 126;
        \\const sum: u128 = high +% high;
        \\const product: u128 = high *% 2;
        \\const cmp: bool = high > 1;
        \\const truncated: u64 = @truncate(high);
        \\const cast: u128 = @intCast(high);
    , &.{
        .{ "high", "u128 = 170141183460469231731687303715884105728" },
        .{ "max", "u128 = 340282366920938463463374607431768211455" },
        .{ "shr", "u128 = 2" },
        .{ "sum", "u128 = 0" },
        .{ "product", "u128 = 0" },
        .{ "cmp", "bool = true" },
        .{ "truncated", "u64 = 0" },
        .{ "cast", "u128 = 170141183460469231731687303715884105728" },
    });
}

test "comptime_int values outside i128" {
    // `comptime_int` is arbitrary precision: a value beyond i128 was unknown, and so was the
    // arithmetic on it
    try expectTypes(
        \\const a = 0x1_0000_0000_0000_0000_0000_0000_0000_0000;
        \\const b = 1 << 200;
        \\const c = b / 3;
        \\const n = -(1 << 200);
        \\const folded = blk: {
        \\    var x = 1 << 200;
        \\    x += 1;
        \\    x *= 2;
        \\    break :blk x;
        \\};
        \\const cmp = (1 << 200) > (1 << 199);
        \\const trunc: i8 = @truncate(-(1 << 200) + 5);
        \\const cast: u128 = @intCast((1 << 128) - 1);
        \\const floor = @divFloor(-(1 << 200), 3);
        \\const mod = @mod(-(1 << 200), 7);
        \\const rem = @rem(-(1 << 200), 7);
        \\const min = @min(1 << 200, 1 << 201);
        \\const max = @max(-(1 << 200), 3);
        \\const abs = @abs(-(1 << 200));
        \\const shl = @shlExact(3, 100);
        \\const shr = @shrExact(1 << 100, 50);
        \\const mul = (1 << 200) * (1 << 200);
        \\fn g() void {
        \\    _ = .{ a, b, c, n, folded, cmp, trunc, cast, floor, mod, rem, min, max, abs, shl, shr, mul };
        \\}
    , &.{
        .{ "a", "comptime_int = 340282366920938463463374607431768211456" },
        .{ "b", "comptime_int = 1606938044258990275541962092341162602522202993782792835301376" },
        .{ "c", "comptime_int = 535646014752996758513987364113720867507400997927597611767125" },
        .{ "n", "comptime_int = -1606938044258990275541962092341162602522202993782792835301376" },
        .{ "folded", "comptime_int = 3213876088517980551083924184682325205044405987565585670602754" },
        .{ "cmp", "bool = true" },
        .{ "trunc", "i8 = 5" },
        .{ "cast", "u128 = 340282366920938463463374607431768211455" },
        .{ "floor", "comptime_int = -535646014752996758513987364113720867507400997927597611767126" },
        .{ "mod", "comptime_int = 3" },
        .{ "rem", "comptime_int = -4" },
        .{ "min", "comptime_int = 1606938044258990275541962092341162602522202993782792835301376" },
        .{ "max", "comptime_int = 3" },
        .{ "abs", "comptime_int = 1606938044258990275541962092341162602522202993782792835301376" },
        .{ "shl", "comptime_int = 3802951800684688204490109616128" },
        .{ "shr", "comptime_int = 1125899906842624" },
        .{ "mul", "comptime_int = 2582249878086908589655919172003011874329705792829223512830659356540647622016841194629645353280137831435903171972747493376" },
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
        // Each iteration has a different type:
        // abstract, like the type parameter of a generic function
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
        // Missing from the namespace of the current target:
        // the definition is taken from the container that another branch selects
        .{ "elsewhere", "u16 = 2" },
    });
}

/// Uses the real standard library of the local zig (skipped when zig is not in PATH)
fn expectStdTypes(src: []const u8, cases: []const struct { []const u8, []const u8 }) !void {
    return expectStdTypesOptimized(null, src, cases);
}

/// Same as `expectStdTypes`; when `optimize` is not null, provides a builtin with that
/// optimize mode (a member name of `std.lang.Optimize`)
fn expectStdTypesOptimized(optimize: ?[]const u8, src: []const u8, cases: []const struct { []const u8, []const u8 }) !void {
    var buf: [256]u8 = undefined;
    const text = if (optimize) |o| try std.fmt.bufPrint(&buf, "const std = @import(\"std\");\npub const mode = optimize;\npub const optimize: std.lang.Optimize = .{s};\n", .{o}) else null;
    return expectStdTypesBuiltin(text, src, cases);
}

/// Same as `expectStdTypes`; when `builtin_text` is not null, it is the source of the builtin
/// module
fn expectStdTypesBuiltin(builtin_text: ?[]const u8, src: []const u8, cases: []const struct { []const u8, []const u8 }) !void {
    var env = @import("../project/ZigEnv.zig").query(testing.allocator, testing.io, null) catch return error.SkipZigTest;
    defer env.deinit(testing.allocator);
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const std_root_path = try std.fs.path.join(testing.allocator, &.{ env.std_dir, "std.zig" });
    defer testing.allocator.free(std_root_path);
    const std_root = try w.vfs.intern(std_root_path);
    const f = try w.add("/p/main.zig", src);
    if (builtin_text) |text| w.default_builtin = (try w.add("/zig-cache/builtin.zig", text)).file;
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
        // A type constructed by @Enum is named after the function instance that constructs it
        // (the compiler shows it as meta.FieldEnum(main.S))
        .{ "FE", "type = FieldEnum(S)" },
        .{ "fe", "FieldEnum(S) = .y" },
        .{ "DE", "type = DeclEnum(S)" },
        .{ "args", "type = struct { u32, f16 }" },
        .{ "backing", "type = u8" },
        .{ "slice", "type = []i32" },
        .{ "tags", "*const [3]E" },
        .{ "field_ty", "type = i32" },
        // A type function whose body calls itself recursively (std.meta.Elem) terminates normally
        .{ "sliced", "type = [:0]const u8" },
    });
}
test "@tagName of values only the interpreter computes in container-level constants" {
    // Prevents typing the names of a call result and of reified enum values as the runtime
    // `[:0]const u8`. Expected values: zig 0.17.0 and 0.17.1 give the same result for each name.
    try expectStdTypesBuiltin(target_builtin,
        \\const std = @import("std");
        \\const U = union(enum) { a: u8, b: u16 };
        \\pub const active = @tagName(std.meta.activeTag(U{ .b = 2 }));
        \\pub const reified = blk: {
        \\    const E = @Enum(u16, .exhaustive, &.{ "x", "y" }, &.{ 0, 1 });
        \\    break :blk @tagName(@as(E, @enumFromInt(1)));
        \\};
        \\pub const generated = blk: {
        \\    @setEvalBranchQuota(1_000_000);
        \\    var names: [3][]const u8 = undefined;
        \\    var values: [3]u16 = undefined;
        \\    for (0..3) |i| {
        \\        names[i] = std.fmt.comptimePrint("f{d}", .{i});
        \\        values[i] = @intCast(i);
        \\    }
        \\    const E = @Enum(u16, .exhaustive, &names, &values);
        \\    break :blk @tagName(@as(E, @enumFromInt(2)));
        \\};
    , &.{
        .{ "active", "*const [1:0]u8 = \"b\"" },
        .{ "reified", "*const [1:0]u8 = \"y\"" },
        .{ "generated", "*const [2:0]u8 = \"f2\"" },
    });
}

test "@Int in function bodies takes any known signedness and u16 bit counts" {
    try expectStdTypes(
        \\const std = @import("std");
        \\fn f() void {
        \\    const L256 = @Int(.unsigned, 256);
        \\    const W = @Int(.unsigned, 2 * @bitSizeOf(u128));
        \\    var w: W = 0;
        \\    const s: std.lang.Signedness = .signed;
        \\    const N = @Int(s, 16);
        \\    const G = @Int(@typeInfo(i32).int.signedness, @typeInfo(i32).int.bits * 2);
        \\    const y: G = 3;
        \\    const cb = 256;
        \\    const C = @Int(.unsigned, cb);
        \\    const T300 = @Int(.unsigned, 300);
        \\    _ = .{ L256, &w, N, y, C, T300 };
        \\}
    , &.{
        .{ "L256", "type = u256" },
        .{ "W", "type = u256" },
        .{ "w", "u256" },
        .{ "N", "type = i16" },
        .{ "G", "type = i64" },
        .{ "y", "i64 = 3" },
        .{ "C", "type = u256" },
        .{ "T300", "type = u300" },
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
        // Matches the compiler: comptime-known fields in a literal are comptime fields
        .{ "tuple", "struct { comptime u8 = 1, comptime bool = true } = .{ 1, true }" },
        .{ "first", "u8 = 1" },
    });
}

test "containers in a type function capture locals derived from @typeInfo arrays" {
    // The shapes of std.enums.EnumIndexer without its sort: a local copy of the field values
    // and constants indexed out of it
    try expectStdTypes(
        \\const Color = enum { red, green, blue };
        \\fn ConstCapture(comptime E: type) type {
        \\    const fields_len = @typeInfo(E).@"enum".field_names.len;
        \\    const field_values = @typeInfo(E).@"enum".field_values[0..fields_len].*;
        \\    const min = field_values[0];
        \\    return struct {
        \\        pub const count: comptime_int = min + fields_len;
        \\        pub fn indexOf(e: E) usize {
        \\            return @as(usize, @intCast(@backingInt(e) - min));
        \\        }
        \\    };
        \\}
        \\fn SliceIndex(comptime E: type) type {
        \\    const fv = @typeInfo(E).@"enum".field_values;
        \\    const second = fv[1];
        \\    return struct { pub const v: comptime_int = second; };
        \\}
        \\fn g() void {
        \\    const indexer_count = ConstCapture(Color).count;
        \\    const index = comptime ConstCapture(Color).indexOf(.blue);
        \\    const slice_index = SliceIndex(Color).v;
        \\    _ = .{ indexer_count, index, slice_index };
        \\}
    , &.{
        .{ "indexer_count", "comptime_int = 3" },
        .{ "index", "usize = 2" },
        .{ "slice_index", "comptime_int = 1" },
    });
}

test "the _ of a non-exhaustive enum is not a field" {
    try expectStdTypes(
        \\const NE = enum(u8) { a, b, _ };
        \\const Q = enum(u8) { a, @"_" };
        \\fn g() void {
        \\    const ne_len = @typeInfo(NE).@"enum".field_names.len;
        \\    const ne_open = @typeInfo(NE).@"enum".mode == .nonexhaustive;
        \\    const q_len = @typeInfo(Q).@"enum".field_names.len;
        \\    const q_open = @typeInfo(Q).@"enum".mode == .nonexhaustive;
        \\    _ = .{ ne_len, ne_open, q_len, q_open };
        \\}
    , &.{
        .{ "ne_len", "usize = 2" },
        .{ "ne_open", "bool = true" },
        // `@"_"` is an ordinary field
        .{ "q_len", "usize = 2" },
        .{ "q_open", "bool = false" },
    });
}

test "values of non-exhaustive enums that no member has are comptime values" {
    // Prevents `@enumFromInt` / `@fromBackingInt` giving up on them; expected values are the
    // results of zig 0.17.0 and 0.17.1, which agree
    try expectTypes(
        \\const E = enum(u8) { a = 10, b, c = 20, _ };
        \\const Neg = enum(i8) { m = -1, _ };
        \\fn pick(e: E) u8 {
        \\    return switch (e) {
        \\        .a => 1,
        \\        else => 2,
        \\        _ => 3,
        \\    };
        \\}
        \\fn Gen(comptime e: E) type {
        \\    return struct {
        \\        pub const v = e;
        \\    };
        \\}
        \\const unnamed: E = @enumFromInt(15);
        \\const backed: E = @fromBackingInt(@as(u8, 15));
        \\const named: E = @fromBackingInt(@as(u8, 11));
        \\const negative: Neg = @enumFromInt(-100);
        \\const out_of_range: E = @enumFromInt(300);
        \\const backing = @backingInt(@as(E, @enumFromInt(15)));
        \\const from_enum = @intFromEnum(@as(E, @enumFromInt(200)));
        \\const negative_int = @intFromEnum(@as(Neg, @enumFromInt(-100)));
        \\const eq = @as(E, @enumFromInt(15)) == @as(E, @enumFromInt(15));
        \\const ne = @as(E, @enumFromInt(15)) == @as(E, @enumFromInt(16));
        \\const eq_named = @as(E, @enumFromInt(11)) == E.b;
        \\const eq_literal = @as(E, @enumFromInt(15)) == .a;
        \\const list = [_]E{ @enumFromInt(15), .a, @enumFromInt(255) };
        \\const ptr: *const E = &@as(E, @enumFromInt(15));
        \\const under = switch (@as(E, @enumFromInt(15))) {
        \\    .a => 1,
        \\    .b => 2,
        \\    .c => 3,
        \\    _ => 4,
        \\};
        \\const under_first = switch (@as(E, @enumFromInt(20))) {
        \\    _ => 4,
        \\    .a => 1,
        \\    .b => 2,
        \\    .c => 3,
        \\};
        \\const under_item = switch (@as(E, @enumFromInt(99))) {
        \\    .a, .b => 1,
        \\    .c, _ => 2,
        \\};
        \\const else_only = switch (@as(E, @enumFromInt(15))) {
        \\    .a => 1,
        \\    else => 2,
        \\};
        \\const else_and_under_unnamed = pick(@enumFromInt(15));
        \\const else_and_under_named = pick(.b);
        \\const arg = Gen(@enumFromInt(15)).v;
        \\const name = @typeName(Gen(@enumFromInt(15)));
    , &.{
        .{ "unnamed", "E = @fromBackingInt(15)" },
        .{ "backed", "E = @fromBackingInt(15)" },
        // A value a member has is that member
        .{ "named", "E = .b" },
        .{ "negative", "Neg = @fromBackingInt(-100)" },
        // A compile error: 300 does not fit the tag type
        .{ "out_of_range", "E" },
        .{ "backing", "u8 = 15" },
        .{ "from_enum", "u8 = 200" },
        .{ "negative_int", "i8 = -100" },
        .{ "eq", "bool = true" },
        .{ "ne", "bool = false" },
        .{ "eq_named", "bool = true" },
        .{ "eq_literal", "bool = false" },
        .{ "list", "[3]E = .{ @fromBackingInt(15), .a, @fromBackingInt(255) }" },
        .{ "ptr", "*const E = &@fromBackingInt(15)" },
        // `_` takes the values no member has, wherever it is among the prongs
        .{ "under", "comptime_int = 4" },
        .{ "under_first", "comptime_int = 3" },
        .{ "under_item", "comptime_int = 2" },
        // Without `_`, `else` takes them
        .{ "else_only", "comptime_int = 2" },
        // With both, `else` takes the members not listed and `_` the values no member has
        .{ "else_and_under_unnamed", "u8 = 3" },
        .{ "else_and_under_named", "u8 = 2" },
        .{ "arg", "E = @fromBackingInt(15)" },
        .{ "name", "*const [29:0]u8 = \"main.Gen(@fromBackingInt(15))\"" },
    });
}

test "anonymous enums display their tag type, the values written for members and _" {
    // Prevents displaying them by member names only (`enum { a }` for `enum(u8) { a, _ }`);
    // values are as zig 0.17.0 and 0.17.1 evaluate them
    try expectTypes(
        \\const exhaustive: enum(u4) { a = 3, b = 5 } = .b;
        \\const plain: enum { x, y } = .y;
        \\const open: enum(u8) { a, _ } = .a;
        \\const open_unnamed: enum(u8) { a, _ } = @enumFromInt(7);
        \\const partial: enum(u8) { a = 1, b, c = 7 } = .c;
        \\const evaluated: enum(u8) { a = 1 << 3, b, c = 0x20 } = .b;
        \\const empty: enum(u8) { _ } = @enumFromInt(3);
        \\const signed: enum(i8) { a = -1, b, _ } = @enumFromInt(-5);
        \\const optional: ?enum(u2) { a, b } = .b;
        \\const reified: @Enum(u8, .nonexhaustive, &.{ "x", "y" }, &.{ 1, 4 }) = .y;
        \\const reified_unnamed: @Enum(u8, .nonexhaustive, &.{"x"}, &.{1}) = @enumFromInt(9);
        \\const reified_exhaustive: @Enum(u2, .exhaustive, &.{ "x", "y" }, &.{ 0, 1 }) = .x;
    , &.{
        .{ "exhaustive", "enum(u4) { a = 3, b = 5 } = .b" },
        .{ "plain", "enum { x, y } = .y" },
        .{ "open", "enum(u8) { a, _ } = .a" },
        .{ "open_unnamed", "enum(u8) { a, _ } = @fromBackingInt(7)" },
        // Only the values written are shown, as evaluated
        .{ "partial", "enum(u8) { a = 1, b, c = 7 } = .c" },
        .{ "evaluated", "enum(u8) { a = 8, b, c = 32 } = .b" },
        .{ "empty", "enum(u8) { _ } = @fromBackingInt(3)" },
        .{ "signed", "enum(i8) { a = -1, b, _ } = @fromBackingInt(-5)" },
        .{ "optional", "?enum(u2) { a, b } = .b" },
        // `@Enum` gives every member its value
        .{ "reified", "enum(u8) { x = 1, y = 4, _ } = .y" },
        .{ "reified_unnamed", "enum(u8) { x = 1, _ } = @fromBackingInt(9)" },
        .{ "reified_exhaustive", "enum(u2) { x = 0, y = 1 } = .x" },
    });
}

test "@typeInfo lists error names in declaration order" {
    // Prevents listing `error_names` sorted by their bytes; expected values are the results of
    // zig 0.17.0, which sorts only the names in `@typeName`
    try expectStdTypes(
        \\const std = @import("std");
        \\const Err = error{ Zeta, Alpha, Mid };
        \\const v0 = @typeInfo(Err).error_set.error_names.?[0];
        \\const v1 = @backingInt(std.meta.FieldEnum(Err).Zeta);
        \\const v2 = @typeInfo(error{ Kilo, Bravo } || error{Echo}).error_set.error_names.?[1];
        \\const same = Err == error{ Mid, Zeta, Alpha };
        \\const name = @typeName(Err);
        \\fn f() Err!void {
        \\    return error.Zeta;
        \\}
        \\const v3 = @typeInfo(@typeInfo(@TypeOf(f)).@"fn".return_type.?).error_union.error_set;
    , &.{
        .{ "v0", "[:0]const u8 = \"Zeta\"" },
        .{ "v1", "u2 = 0" },
        .{ "v2", "[:0]const u8 = \"Bravo\"" },
        .{ "same", "bool = true" },
        .{ "name", "*const [21:0]u8 = \"error{Alpha,Mid,Zeta}\"" },
        .{ "v3", "type = error{Alpha,Mid,Zeta}" },
    });
}

test "empty exhaustive enums have the tag type noreturn" {
    // Prevents giving `enum {}` and the tag of `union(enum) {}` the tag type `u0`; expected
    // values are the results of zig 0.17.0
    try expectStdTypes(
        \\const std = @import("std");
        \\const Empty = enum {};
        \\const U = union(enum) {};
        \\const a = @typeInfo(Empty).@"enum".tag_type;
        \\const b = std.meta.Tag(Empty);
        \\const c = std.meta.BackingInt(Empty);
        \\const d = @typeInfo(std.meta.Tag(U)).@"enum".tag_type;
        \\const e = @typeInfo(enum { x }).@"enum".tag_type;
        \\const f = if (@typeInfo(Empty).@"enum".tag_type == noreturn) 1 else 2;
    , &.{
        .{ "a", "type = noreturn" },
        .{ "b", "type = noreturn" },
        .{ "c", "type = noreturn" },
        .{ "d", "type = noreturn" },
        .{ "e", "type = u0" },
        .{ "f", "comptime_int = 1" },
    });
}

test "packed unions have a backing integer and no tag type" {
    // Prevents treating the backing integer of `packed union(T)` as its tag type
    try expectStdTypes(
        \\const std = @import("std");
        \\const PU = packed union(u8) { a: u8, b: i8 };
        \\const PI = packed union { a: u8, b: i8 };
        \\const PR = @Union(.@"packed", u16, &.{ "a", "b" }, &.{ u16, i16 }, &@splat(.{}));
        \\fn tagBits(comptime T: type) comptime_int {
        \\    if (@typeInfo(T).@"union".tag_type) |Tag| return @bitSizeOf(Tag);
        \\    return -1;
        \\}
        \\fn backBits(comptime T: type) comptime_int {
        \\    if (@typeInfo(T).@"union".backing_integer) |B| return @bitSizeOf(B);
        \\    return -1;
        \\}
        \\const tag_pu = tagBits(PU);
        \\const back_pu = backBits(PU);
        \\const tag_pi = tagBits(PI);
        \\const back_pi = backBits(PI);
        \\const tag_pr = tagBits(PR);
        \\const back_pr = backBits(PR);
        \\const BI = std.meta.BackingInt(PU);
        \\const Tag = std.meta.Tag(PU);
        \\fn f() void {
        \\    const x = PU.a;
        \\    _ = x;
        \\}
    , &.{
        .{ "tag_pu", "comptime_int = -1" },
        .{ "back_pu", "comptime_int = 8" },
        .{ "tag_pi", "comptime_int = -1" },
        .{ "back_pi", "comptime_int = 8" },
        .{ "tag_pr", "comptime_int = -1" },
        .{ "back_pr", "comptime_int = 16" },
        .{ "BI", "type = u8" },
        // Compile errors in the compiler
        .{ "Tag", "type" },
        .{ "x", "unknown" },
    });
}

test "layouts of reified containers" {
    // Expected values are the results of zig 0.17.0
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
        // Explicit alignment and comptime fields in the field attributes
        .{ "size_ra", "comptime_int = 16" },
        .{ "align_ra", "comptime_int = 16" },
        .{ "ra_x", "comptime_int = 8" },
        .{ "size_rc", "comptime_int = 4" },
        // @typeInfo reports the explicit alignment of fields
        .{ "la", "?usize = 4" },
        .{ "lb", "comptime_int = 0" },
        .{ "size_ru", "comptime_int = 8" },
        .{ "size_efs", "comptime_int = 6" },
        .{ "efs_c", "comptime_int = 4" },
    });
}

test "bare unions have a safety tag in safe build modes" {
    // Expected values are the results of zig 0.17.0
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
        // No tag when there is only one field
        .{ "size_one", "comptime_int = 4" },
        .{ "size_rb", "comptime_int = 8" },
        // The effect of `@setRuntimeSafety` depends on where it is called and its argument
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
        .{ ".naked", "CallingConvention = .{ .naked = {} }" },
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

test "containers named inside a generic instance are qualified by it" {
    // Prevents displaying `Outer(u8).Inner` as `Inner(u8)`, which reads like a call of `Inner`
    try expectTypes(
        \\fn Outer(comptime T: type) type {
        \\    return struct {
        \\        pub const Inner = struct { v: T };
        \\        pub const Deep = struct { pub const Leaf = struct { t: T }; };
        \\        pub fn Gen(comptime U: type) type {
        \\            return struct { pub const X = struct { u: U, t: T }; };
        \\        }
        \\        pub fn make() type {
        \\            return struct { t: T };
        \\        }
        \\    };
        \\}
        \\fn Local(comptime T: type) type {
        \\    const S = struct { t: T };
        \\    return struct { s: S };
        \\}
        \\fn Returned(comptime T: type) type {
        \\    const S = struct { v: T };
        \\    return S;
        \\}
        \\fn f() void {
        \\    const x: Outer(u8).Inner = .{ .v = 1 };
        \\    const leaf: Outer(u8).Deep.Leaf = .{ .t = 1 };
        \\    const g: Outer(u8).Gen(u16).X = .{ .u = 1, .t = 2 };
        \\    const gen: Outer(u8).Gen(u16) = .{};
        \\    const m: Outer(u8).make() = .{ .t = 1 };
        \\    const o: Outer(u8) = .{};
        \\    var lv: Local(i8) = undefined;
        \\    const ls = lv.s;
        \\    var rv: Returned(i8) = undefined;
        \\    const rs = rv;
        \\    _ = .{ x, leaf, g, gen, m, o, ls, &lv, rs, &rv };
        \\}
    , &.{
        .{ "x", "Outer(u8).Inner" },
        .{ "leaf", "Outer(u8).Deep.Leaf" },
        .{ "g", "Outer(u8).Gen(u16).X" },
        .{ "gen", "Outer(u8).Gen(u16)" },
        .{ "m", "Outer(u8).make()" },
        .{ "o", "Outer(u8)" },
        // A local constant of a function is named after the function without arguments
        .{ "ls", "Local.S" },
        .{ "rs", "Returned.S" },
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
        // FieldEnum-constructed enums, @FieldType and @tagName
        .{ "xs", "[]i32" },
        .{ "flag", "?bool" },
        .{ "entry", "Custom(u32, []const u8, AutoContext(u32), 80).GetOrPutResult" },
        // The result of @typeInfo is comptime-known and shown in full
        .{ "fs", "[]const [:0]const u8 = &.{ \"x\", \"y\" }" },
        .{ "info", "Type = .{ .@\"struct\" = .{ .is_tuple = false, .layout = .auto, .backing_integer = null, .field_names = &.{ \"x\", \"y\" }, .field_types = &.{ i32, i32 }, .field_attrs = &.{ .{ .@\"comptime\" = false, .@\"align\" = null, .default_value_ptr = null }, .{ .@\"comptime\" = false, .@\"align\" = null, .default_value_ptr = null } }, .decl_names = &.{} } }" },
        .{ "FT", "type = i32" },
        .{ "num", "u32" },
        .{ "it", "SplitIterator(u8, .scalar)" },
        .{ "part", "?[]const u8" },
        .{ "buf", "[]u32" },
        .{ "loc", "SourceLocation" },
    });
}

test "std.enums.values, std.enums.fromInt, std.meta.stringToEnum and StaticStringMap.initEnum at comptime" {
    try expectStdTypes(
        \\const std = @import("std");
        \\const Color = enum { red, green, blue };
        \\const Small = enum(u4) { a = 3, b = 5 };
        \\const Open = enum(u8) { x = 1, y = 2, _ };
        \\const from_fields = std.enums.valuesFromFields(Color, &.{ 0, 2 }).len;
        \\const values_len = std.enums.values(Color).len;
        \\const values_2 = std.enums.values(Color)[2];
        \\const backing_cmp = blk: {
        \\    for (std.enums.values(Color)) |v| {
        \\        if (@backingInt(v) == 2) break :blk v;
        \\    }
        \\    break :blk Color.red;
        \\};
        \\const from_int = std.enums.fromInt(Color, 1);
        \\const from_int_none = std.enums.fromInt(Color, 7);
        \\const from_int_explicit = std.enums.fromInt(Small, 5);
        \\const from_int_open = std.enums.fromInt(Open, @as(u32, 2));
        \\const string_red = std.meta.stringToEnum(Color, "red");
        \\const string_green = std.meta.stringToEnum(Color, "green");
        \\const string_none = std.meta.stringToEnum(Color, "pink");
        \\const map_get = std.StaticStringMap(Color).initEnum().get("green");
    , &.{
        .{ "from_fields", "usize = 2" },
        .{ "values_len", "usize = 3" },
        .{ "values_2", "Color = .blue" },
        .{ "backing_cmp", "Color = .blue" },
        .{ "from_int", "?Color = .green" },
        .{ "from_int_none", "?Color = null" },
        .{ "from_int_explicit", "?Small = .b" },
        // A non-exhaustive enum: `return @fromBackingInt(@intCast(tag))` with the result type `?E`
        .{ "from_int_open", "?Open = .y" },
        .{ "string_red", "?Color = .red" },
        .{ "string_green", "?Color = .green" },
        .{ "string_none", "?Color = null" },
        .{ "map_get", "?Color = .green" },
    });
}

test "local types used by containers in the body: no cycle through the whole function" {
    // A method of a container in the body uses a local type of the outer function, and the outer
    // function body references that method; the body has an `enum(u32)`.
    // Previously the inference result of the whole outer function was used, forming a cycle:
    // the result was incomplete and was not written to the memo
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
    // The result is complete and written to the memo: the second read does not execute again
    try testing.expectEqual(executions[0], executions[1]);
    var stats: [database.Db.query_types.len]@import("../db/engine.zig").QueryStats = undefined;
    try testing.expectEqual(0, w.db.stats(&stats).incomplete_causes.get(.cycle));
    try testing.expectEqualStrings("u32", try typeAt(&w, file, text, "v", 1));
    try testing.expectEqualStrings("u32", try typeAt(&w, file, text, "p.a", 0));
}

test "container arguments that refer to locals of an outer function" {
    // Only this one expression, the argument of `enum(T)`, is inferred; the `T` in it is a local
    // constant of an enclosing outer function.
    // The index of `T` in the outer function exceeds the number of bindings of the inner function
    // (the outer binding used to be fetched with the inner function's Body, going out of bounds)
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
    // The constness of a local of an outer function is determined by the Body of the member
    // containing it (the binding used to be looked up in the inner member's Body, out of bounds)
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
    // `union(enum) { unneeded, ... }` has no expression in the parentheses; previously the first
    // member was taken, so `unneeded` was resolved as a name reference to the outer declaration of
    // the same name, forming a cycle with that declaration's initializer (`LazySrcLoc.Offset` in
    // the Zig compiler source)
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
        // The argument of `union(enum(u8))` is still found
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
    // The source of a is unchanged: the same Body is reused; b changed: it is lowered again
    try testing.expectEqual(before.a, after.a);
    try testing.expect(before.b != after.b);
}

test "editing a callee body does not invalidate the inference of its callers" {
    // If deciding whether a call is generic depended on the callee's whole Body, editing its
    // function body would make all callers re-infer
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
        // The callee itself (its signature part) is re-inferred, with an unchanged value;
        // callers are not recomputed
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
        .{ "bytes", "[]align(2) const u8" },
        .{ "fs", "[]const F" },
        .{ "zb", "[]const u8" },
    });
}

test "std.mem functions that scan a many-item pointer up to its sentinel at comptime" {
    try expectStdTypesBuiltin(target_builtin,
        \\const std = @import("std");
        \\const spanned = std.mem.span(@as([*:0]const u8, "abc")).len;
        \\const measured = std.mem.len(@as([*:0]const u8, "abcd"));
        \\const measured_c = std.mem.len(@as([*c]const u8, "hey"));
        \\const sliced = std.mem.sliceTo(@as([*:0]const u8, "abc"), 0).len;
        \\const printed = std.mem.span(@as([*:0]const u8, std.fmt.comptimePrint("{d}", .{1234}))).len;
        \\const wide = std.mem.span(@as([*:0]const u16, &[_:0]u16{ 1, 2, 3 })).len;
        \\const local = blk: {
        \\    var buf = [_]u8{ 'a', 'b', 0, 'd' };
        \\    const s: [:0]u8 = buf[0..2 :0];
        \\    break :blk std.mem.len(s.ptr);
        \\};
        \\const ordered = std.mem.orderZ(u8, "ab", "abc");
    , &.{
        .{ "spanned", "usize = 3" },
        .{ "measured", "usize = 4" },
        .{ "measured_c", "usize = 3" },
        .{ "sliced", "usize = 3" },
        .{ "printed", "usize = 4" },
        .{ "wide", "usize = 3" },
        .{ "local", "usize = 2" },
        // Compares the sentinel of the shorter string with a byte of the longer one
        .{ "ordered", "Order = .lt" },
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
        // The prong items have distinct values:
        // when `u16` matches, the unevaluable `Vec` cannot match as well
        .{ "hit", "u32 = 0" },
        // None matches and some prong items cannot be evaluated: must not fall back to else
        .{ "miss", "unknown" },
    });
}

test "a switch on a comptime-known integer takes the prong whose range contains it" {
    // A range item has no single value: no prong was chosen, and the switch took the peer type of
    // all prongs (`[:0]const u8`) without a value.
    try expectTypes(
        \\const inside = switch (@as(u8, 42)) {
        \\    0...9 => "a",
        \\    10...99 => "bb",
        \\    else => "ccc",
        \\};
        \\const at_low = switch (@as(u8, 10)) { 0...9 => "a", 10...99 => "bb", else => "ccc" };
        \\const at_high = switch (@as(u8, 99)) { 0...9 => "a", 10...99 => "bb", else => "ccc" };
        \\const past = switch (@as(u8, 200)) { 0...9 => "a", 10...99 => "bb", else => "ccc" };
        \\const mixed_range = switch (@as(u8, 50)) { 1, 40...60, 99 => "mixed", else => "e" };
        \\const mixed_scalar = switch (@as(u8, 99)) { 1, 40...60, 99 => "mixed", else => "e" };
        \\const scalar_after = switch (@as(u8, 42)) { 0...9 => "a", 42 => "bb", else => "ccc" };
        \\const char = switch (@as(u8, 'x')) { 'a'...'z' => "lower", 'A'...'Z' => "upper!", else => "?" };
        \\const negative = switch (@as(i8, -5)) { -128...-1 => "neg", 0...127 => "nonneg" };
        \\const untyped = switch (42) { 0...9 => "a", 10...99 => "bb", else => "ccc" };
        \\const big = switch (1 << 100) { 0...(1 << 99) => "a", (1 << 99) + 1...(1 << 101) => "bb", else => "ccc" };
        \\const high: u128 = 0xF000_0000_0000_0000_0000_0000_0000_0000;
        \\const half = 0x8000_0000_0000_0000_0000_0000_0000_0000;
        \\const max = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
        \\const wide = switch (high) { 0...9 => "a", half...max => "bb", else => "ccc" };
        \\const lo: u8 = 30;
        \\const hi = 50;
        \\const named = switch (@as(u8, 42)) { lo...hi => "bb", else => "ccc" };
    , &.{
        .{ "inside", "*const [2:0]u8 = \"bb\"" },
        // Both bounds are inclusive
        .{ "at_low", "*const [2:0]u8 = \"bb\"" },
        .{ "at_high", "*const [2:0]u8 = \"bb\"" },
        .{ "past", "*const [3:0]u8 = \"ccc\"" },
        .{ "mixed_range", "*const [5:0]u8 = \"mixed\"" },
        .{ "mixed_scalar", "*const [5:0]u8 = \"mixed\"" },
        .{ "scalar_after", "*const [2:0]u8 = \"bb\"" },
        .{ "char", "*const [5:0]u8 = \"lower\"" },
        .{ "negative", "*const [3:0]u8 = \"neg\"" },
        .{ "untyped", "*const [2:0]u8 = \"bb\"" },
        .{ "big", "*const [2:0]u8 = \"bb\"" },
        // The `comptime_int` bounds are coerced to `u128`, so those above the range of i128 are
        // compared as u128
        .{ "wide", "*const [2:0]u8 = \"bb\"" },
        .{ "named", "*const [2:0]u8 = \"bb\"" },
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
        // A declaration that is used cannot be a compile error: the other branch is taken
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
        // `features` cannot be evaluated, so the whole `cpu` has no value;
        // `arch` still gets its value from the initializer, which selects the branch
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
        // Lines are joined with newlines after removing `\\`
        .{ "text", "*const [13:0]u8 = \"-a, --aa\\n  -b\"" },
        .{ "lines", "usize = 2" },
        // A string literal as a comptime argument has a value
        .{ "FromLiteral", "type = [3]u8" },
        .{ "FromMultiline", "type = [4]u8" },
        // A `comptime` expression in a function body is evaluated at comptime
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
        // `E!void` when the function runs to its end,
        // and a payload in `catch` pointing into local storage
        .{ "r_eu", "usize = 7" },
        // Modifying the `len` of a slice
        .{ "r_grow", "usize = 206" },
        // Arithmetic operands are not converted to the optional result type
        .{ "r_opt", "usize = 5" },
        // Comparing the `ptr` of slices (the fast path in `std.mem.eql`)
        .{ "r_ptr", "usize = 1" },
        // Pointer capture of an optional, and `*const T` to `*const [1]T`
        .{ "r_short", "usize = 104" },
        .{ "r_bump", "usize = 3" },
    });
}

test "comptime evaluation: anytype and comptime parameters write through pointers into the caller's storage" {
    // Prevents running the callee on interned copies of such arguments, which lost its writes;
    // expected values are the results of zig 0.17.0 and 0.17.1
    try expectTypes(
        \\const Ctx = struct {
        \\    items: []u32,
        \\    fn swap(ctx: Ctx, a: usize, b: usize) void {
        \\        const t = ctx.items[a];
        \\        ctx.items[a] = ctx.items[b];
        \\        ctx.items[b] = t;
        \\    }
        \\};
        \\fn viaAny(ctx: anytype) void {
        \\    ctx.swap(0, 1);
        \\}
        \\fn anySlice(s: anytype) void {
        \\    s[0] = 9;
        \\}
        \\fn anyPtr(p: anytype) void {
        \\    p.* = 9;
        \\}
        \\fn anyArrPtr(p: anytype) void {
        \\    p[1] = 9;
        \\}
        \\fn anyTuple(t: anytype) void {
        \\    t[0].* = 9;
        \\}
        \\fn anyStruct(c: anytype) void {
        \\    c.p.* = 9;
        \\}
        \\fn anyNested(t: anytype) void {
        \\    t[0][0].* = 9;
        \\}
        \\fn idAny(p: anytype) @TypeOf(p) {
        \\    return p;
        \\}
        \\fn readAny(s: anytype) u32 {
        \\    return s[0] + s[1];
        \\}
        \\fn setCt(s: []comptime_int) void {
        \\    s[0] = 9;
        \\}
        \\fn setType(p: *type) void {
        \\    p.* = u8;
        \\}
        \\fn setCtPtr(comptime p: *u32) void {
        \\    p.* = 9;
        \\}
        \\fn setCtAny(comptime p: anytype) void {
        \\    p.* = 9;
        \\}
        \\fn lenCt(comptime s: []const u8) usize {
        \\    return s.len;
        \\}
        \\fn setPtrPtr(pp: anytype) void {
        \\    pp.*.* = 9;
        \\}
        \\const Field = struct { x: u32 };
        \\const w_swap = blk: {
        \\    var a = [_]u32{ 1, 2 };
        \\    viaAny(Ctx{ .items = &a });
        \\    break :blk a[0];
        \\};
        \\const w_slice = blk: {
        \\    var a = [_]u32{ 1, 2 };
        \\    anySlice(@as([]u32, &a));
        \\    break :blk a[0];
        \\};
        \\const w_ptr = blk: {
        \\    var x: u32 = 1;
        \\    anyPtr(&x);
        \\    break :blk x;
        \\};
        \\const w_arr_ptr = blk: {
        \\    var a = [_]u32{ 1, 2 };
        \\    anyArrPtr(&a);
        \\    break :blk a[1];
        \\};
        \\const w_tuple = blk: {
        \\    var x: u32 = 1;
        \\    anyTuple(.{&x});
        \\    break :blk x;
        \\};
        \\const w_struct = blk: {
        \\    var x: u32 = 1;
        \\    anyStruct(.{ .p = &x });
        \\    break :blk x;
        \\};
        \\const w_nested = blk: {
        \\    var x: u32 = 1;
        \\    anyNested(.{.{&x}});
        \\    break :blk x;
        \\};
        \\const w_builtin_call = blk: {
        \\    var x: u32 = 1;
        \\    @call(.auto, anyPtr, .{&x});
        \\    break :blk x;
        \\};
        \\const w_alias = blk: {
        \\    var a = [_]u32{ 1, 2 };
        \\    const q = idAny(&a);
        \\    a[0] = 7;
        \\    break :blk q[0];
        \\};
        \\const w_read = blk: {
        \\    var a = [_]u32{ 4, 5 };
        \\    break :blk readAny(&a);
        \\};
        \\const w_twice = blk: {
        \\    var a = [_]u32{ 1, 2 };
        \\    anySlice(@as([]u32, &a));
        \\    a[0] += 1;
        \\    anyArrPtr(&a);
        \\    break :blk a[0] * 100 + a[1];
        \\};
        \\const w_ct_slice = blk: {
        \\    var a = [_]comptime_int{ 1, 2 };
        \\    setCt(&a);
        \\    break :blk a[0];
        \\};
        \\const w_ct_type = blk: {
        \\    var T: type = u32;
        \\    setType(&T);
        \\    break :blk T;
        \\};
        \\const w_ct_ptr = blk: {
        \\    var x: u32 = 1;
        \\    setCtPtr(&x);
        \\    break :blk x;
        \\};
        \\const w_ct_any = blk: {
        \\    var x: u32 = 1;
        \\    setCtAny(&x);
        \\    break :blk x;
        \\};
        \\const w_const_local = blk: {
        \\    const arr = "abc".*;
        \\    break :blk lenCt(&arr);
        \\};
        \\const w_ptr_ptr = blk: {
        \\    var x: u32 = 1;
        \\    const p = &x;
        \\    setPtrPtr(&p);
        \\    break :blk x;
        \\};
        \\const w_alias_const = blk: {
        \\    var a = [_]u32{ 1, 2 };
        \\    const q = idAny(@as(*const [2]u32, &a));
        \\    a[0] = 7;
        \\    break :blk q[0];
        \\};
        \\const w_alias_field = blk: {
        \\    var s: Field = .{ .x = 1 };
        \\    const p: *const Field = &s;
        \\    const q = idAny(&p.x);
        \\    s.x = 7;
        \\    break :blk q.*;
        \\};
    , &.{
        // anytype parameters: a struct holding a slice, a slice, single-item and array
        // pointers, and pointers inside tuples and anonymous structs
        .{ "w_swap", "u32 = 2" },
        .{ "w_slice", "u32 = 9" },
        .{ "w_ptr", "u32 = 9" },
        .{ "w_arr_ptr", "u32 = 9" },
        .{ "w_tuple", "u32 = 9" },
        .{ "w_struct", "u32 = 9" },
        .{ "w_nested", "u32 = 9" },
        .{ "w_builtin_call", "u32 = 9" },
        // A returned pointer still points into the caller's storage
        .{ "w_alias", "u32 = 7" },
        .{ "w_read", "u32 = 9" },
        .{ "w_twice", "u32 = 1009" },
        // Parameters that are comptime because of their comptime-only type, and explicit
        // comptime parameters
        .{ "w_ct_slice", "comptime_int = 9" },
        .{ "w_ct_type", "type = u8" },
        .{ "w_ct_ptr", "u32 = 9" },
        .{ "w_ct_any", "u32 = 9" },
        // A pointer to a constant local is passed as an interned value; a constant holding a
        // pointer to a variable, and `*const` pointers to a variable, still reach the variable
        .{ "w_const_local", "usize = 3" },
        .{ "w_ptr_ptr", "u32 = 9" },
        .{ "w_alias_const", "u32 = 7" },
        .{ "w_alias_field", "u32 = 7" },
    });
}

test "comptime evaluation: std.sort and std.mem.sortUnstable sort in place" {
    // Prevents leaving the array unsorted when the sort passes its context through anytype;
    // expected values are the results of zig 0.17.0 and 0.17.1
    try expectStdTypes(
        \\const std = @import("std");
        \\fn lessThan(_: void, x: u32, y: u32) bool {
        \\    return x < y;
        \\}
        \\fn lessThanCt(_: void, x: comptime_int, y: comptime_int) bool {
        \\    return x < y;
        \\}
        \\fn gen(comptime n: usize) [n]u32 {
        \\    var a: [n]u32 = undefined;
        \\    var x: u32 = 12345;
        \\    for (&a) |*e| {
        \\        x = x *% 1103515245 +% 12345;
        \\        e.* = x >> 16;
        \\    }
        \\    return a;
        \\}
        \\const s_insertion = blk: {
        \\    var a = [_]u32{ 5, 3, 9, 1, 7, 2, 8 };
        \\    std.sort.insertion(u32, &a, {}, lessThan);
        \\    break :blk a[0] * 100 + a[3] * 10 + a[6];
        \\};
        \\const s_pdq = blk: {
        \\    var a = [_]u32{ 5, 3, 9, 1, 7, 2, 8 };
        \\    std.sort.pdq(u32, &a, {}, lessThan);
        \\    break :blk a[0] * 100 + a[3] * 10 + a[6];
        \\};
        \\const s_heap = blk: {
        \\    var a = [_]u32{ 5, 3, 9, 1, 7, 2, 8 };
        \\    std.sort.heap(u32, &a, {}, lessThan);
        \\    break :blk a[0] * 100 + a[3] * 10 + a[6];
        \\};
        \\const s_unstable = blk: {
        \\    var a = [_]u32{ 5, 3, 9, 1, 7, 2, 8 };
        \\    std.mem.sortUnstable(u32, &a, {}, lessThan);
        \\    break :blk a[0] * 100 + a[3] * 10 + a[6];
        \\};
        \\const s_unstable_ct = blk: {
        \\    var a = [_]comptime_int{ 3, 1, 2 };
        \\    std.mem.sortUnstable(comptime_int, &a, {}, lessThanCt);
        \\    break :blk a[0] * 100 + a[1] * 10 + a[2];
        \\};
        \\const s_pdq_sorted = blk: {
        \\    @setEvalBranchQuota(100_000);
        \\    var a = gen(100);
        \\    std.sort.pdq(u32, &a, {}, lessThan);
        \\    break :blk std.sort.isSorted(u32, &a, {}, lessThan);
        \\};
        \\const s_pdq_median = blk: {
        \\    @setEvalBranchQuota(100_000);
        \\    var a = gen(100);
        \\    std.sort.pdq(u32, &a, {}, lessThan);
        \\    break :blk a[50];
        \\};
    , &.{
        .{ "s_insertion", "u32 = 159" },
        .{ "s_pdq", "u32 = 159" },
        .{ "s_heap", "u32 = 159" },
        .{ "s_unstable", "u32 = 159" },
        .{ "s_unstable_ct", "comptime_int = 123" },
        // 100 elements take the partitioning path of pdqsort rather than insertion sort
        .{ "s_pdq_sorted", "bool = true" },
        .{ "s_pdq_median", "u32 = 32588" },
    });
}
test "comptime evaluation: pointer identity of declarations, functions and temporaries" {
    try expectTypes(
        \\const arr = [_]u8{ 1, 2, 3, 4 };
        \\const arr2 = [_]u8{ 1, 2, 3, 4 };
        \\const gp: [*]const u8 = &arr;
        \\const word = [_]u8{ 'a', 'b', 'c' };
        \\const word_z = [_:0]u8{ 'a', 'b', 'c' };
        \\const S = struct {
        \\    a: u32,
        \\    b: u32,
        \\    const table = [_]u8{ 7, 8 };
        \\    const Self = @This();
        \\    fn get(self: *const S) u32 {
        \\        return self.a;
        \\    }
        \\};
        \\const s = S{ .a = 1, .b = 1 };
        \\const s2 = S{ .a = 1, .b = 1 };
        \\var gv: u32 = 0;
        \\fn foo() void {}
        \\fn bar() void {}
        \\const foo_alias = foo;
        \\const fp: *const fn () void = &foo;
        \\const ch: u8 = 'a';
        \\const gview: *const [1][4]u8 = &arr;
        \\fn eql(a: []const u8, b: []const u8) bool {
        \\    if (a.len != b.len) return false;
        \\    if (a.len == 0 or a.ptr == b.ptr) return true;
        \\    for (a, b) |x, y| if (x != y) return false;
        \\    return true;
        \\}
        \\fn gpAddr() bool {
        \\    return gp == @as([*]const u8, &arr);
        \\}
        \\fn addrAddr() bool {
        \\    return @as([*]const u8, &arr) == @as([*]const u8, &arr);
        \\}
        \\fn twoDecls() bool {
        \\    return &arr == &arr2;
        \\}
        \\fn field() bool {
        \\    return &s.a == &s.a;
        \\}
        \\fn fieldOther() bool {
        \\    return &s.a == &s.b;
        \\}
        \\fn fieldOtherDecl() bool {
        \\    return &s.a == &s2.a;
        \\}
        \\fn elem() bool {
        \\    return &arr[1] == &arr[1];
        \\}
        \\fn elemOther() bool {
        \\    return &arr[1] == &arr[2];
        \\}
        \\fn member() bool {
        \\    return &S.table == &S.table;
        \\}
        \\fn memberThis() bool {
        \\    return &S.Self.table == &S.table;
        \\}
        \\fn memberOther() bool {
        \\    return @as([*]const u8, &S.table) == @as([*]const u8, &arr);
        \\}
        \\fn variable() bool {
        \\    return &gv == &gv;
        \\}
        \\fn method() u32 {
        \\    return s.get();
        \\}
        \\fn func() bool {
        \\    return &foo == &foo;
        \\}
        \\fn funcAlias() bool {
        \\    return &foo == &foo_alias;
        \\}
        \\fn funcStored() bool {
        \\    return fp == &foo;
        \\}
        \\fn funcOther() bool {
        \\    return &foo == &bar;
        \\}
        \\fn temp() bool {
        \\    return &[_]u8{ 1, 2, 3 } == &[_]u8{ 1, 2, 3 };
        \\}
        \\fn tempOther() bool {
        \\    return &[_]u8{ 1, 2, 3 } == &[_]u8{ 1, 2, 4 };
        \\}
        \\fn tempDecl() bool {
        \\    return &[_]u8{ 1, 2, 3, 4 } == &arr;
        \\}
        \\fn tempInt() bool {
        \\    return &@as(u32, 5) == &@as(u32, 5);
        \\}
        \\fn eqlWord() bool {
        \\    return eql(&word, "abc");
        \\}
        \\fn eqlWordOther() bool {
        \\    return eql(&word, "abd");
        \\}
        \\fn eqlDecls() bool {
        \\    return eql(&arr, &arr2);
        \\}
        \\fn eqlSlice() bool {
        \\    return eql(&arr, gp[0..4]);
        \\}
        \\fn wordLit() bool {
        \\    return @as([*]const u8, &word) == @as([*]const u8, "abc");
        \\}
        \\fn wordzLit() bool {
        \\    return @as([*]const u8, &word_z) == @as([*]const u8, "abc");
        \\}
        \\fn localDecl() bool {
        \\    var a = [_]u8{ 1, 2, 3, 4 };
        \\    _ = &a;
        \\    return &a == &arr;
        \\}
        \\fn localTemp() bool {
        \\    const a = [_]u8{ 1, 2, 3 };
        \\    return &a == &[_]u8{ 1, 2, 3 };
        \\}
        \\fn localTempOther() bool {
        \\    const a = [_]u8{ 1, 2, 3 };
        \\    return &a == &[_]u8{ 1, 2, 4 };
        \\}
        \\fn derefAddr() bool {
        \\    const p = &arr;
        \\    return &p.* == p;
        \\}
        \\fn viewSame() bool {
        \\    return @as(*const [1]u8, &ch) == @as(*const [1]u8, &ch);
        \\}
        \\fn viewElem() bool {
        \\    const v: *const [1]u8 = &ch;
        \\    return &v[0] == &ch;
        \\}
        \\fn viewInterned() bool {
        \\    return @as(*const [1][4]u8, &arr) == gview;
        \\}
        \\fn viewLit() bool {
        \\    return @as([*]const u8, @as(*const [1]u8, &ch)) == @as([*]const u8, "a");
        \\}
        \\fn eqlView() bool {
        \\    return eql(@as(*const [1]u8, &ch), "a");
        \\}
        \\fn eqlViewOther() bool {
        \\    return eql(@as(*const [1]u8, &ch), "b");
        \\}
        \\const p_gp_addr = gp == @as([*]const u8, &arr);
        \\const p_addr_addr = @as([*]const u8, &arr) == @as([*]const u8, &arr);
        \\const p_eql_addr = eql(&word, "abc");
        \\const p_eql_other = eql(&word, "abd");
        \\const r_gp_addr = gpAddr();
        \\const r_addr_addr = addrAddr();
        \\const r_two_decls = twoDecls();
        \\const r_field = field();
        \\const r_field_other = fieldOther();
        \\const r_field_decl = fieldOtherDecl();
        \\const r_elem = elem();
        \\const r_elem_other = elemOther();
        \\const r_member = member();
        \\const r_member_this = memberThis();
        \\const r_member_other = memberOther();
        \\const r_var = variable();
        \\const r_method = method();
        \\const r_fn = func();
        \\const r_fn_alias = funcAlias();
        \\const r_fn_stored = funcStored();
        \\const r_fn_other = funcOther();
        \\const r_temp = temp();
        \\const r_temp_other = tempOther();
        \\const r_temp_decl = tempDecl();
        \\const r_temp_int = tempInt();
        \\const r_eql_word = eqlWord();
        \\const r_eql_word_other = eqlWordOther();
        \\const r_eql_decls = eqlDecls();
        \\const r_eql_slice = eqlSlice();
        \\const r_word_lit = wordLit();
        \\const r_wordz_lit = wordzLit();
        \\const r_local_decl = localDecl();
        \\const r_local_temp = localTemp();
        \\const r_local_temp_other = localTempOther();
        \\const r_deref = derefAddr();
        \\const r_view_same = viewSame();
        \\const r_view_elem = viewElem();
        \\const r_view_interned = viewInterned();
        \\const r_view_lit = viewLit();
        \\const r_eql_view = eqlView();
        \\const r_eql_view_other = eqlViewOther();
    , &.{
        // `&` of a declaration points to the declaration, as the pointer stored in `gp` does;
        // an interned pointer keeps no identity, so equal data gives no value instead of `false`
        .{ "p_gp_addr", "bool" },
        .{ "p_addr_addr", "bool = true" },
        .{ "p_eql_addr", "bool = true" },
        .{ "p_eql_other", "bool = false" },
        .{ "r_gp_addr", "bool" },
        .{ "r_addr_addr", "bool = true" },
        // Distinct declarations with equal values
        .{ "r_two_decls", "bool = false" },
        // Fields and elements of a declaration, and declarations reached through a type
        .{ "r_field", "bool = true" },
        .{ "r_field_other", "bool = false" },
        .{ "r_field_decl", "bool = false" },
        .{ "r_elem", "bool = true" },
        .{ "r_elem_other", "bool = false" },
        .{ "r_member", "bool = true" },
        .{ "r_member_this", "bool = true" },
        .{ "r_member_other", "bool = false" },
        .{ "r_var", "bool = true" },
        // A method receives the address of the declaration it is called on
        .{ "r_method", "u32 = 1" },
        // A function is the identity of pointers to it, whichever constant names it
        .{ "r_fn", "bool = true" },
        .{ "r_fn_alias", "bool = true" },
        .{ "r_fn_stored", "bool = true" },
        .{ "r_fn_other", "bool = false" },
        // Temporaries are the same constant for equal values of the same type
        .{ "r_temp", "bool = true" },
        .{ "r_temp_other", "bool = false" },
        .{ "r_temp_decl", "bool = false" },
        .{ "r_temp_int", "bool = true" },
        // The fast path of `std.mem.eql` compares the pointers of equal data
        .{ "r_eql_word", "bool = true" },
        .{ "r_eql_word_other", "bool = false" },
        .{ "r_eql_decls", "bool = true" },
        .{ "r_eql_slice", "bool = true" },
        // A string literal carries its sentinel, for which `word` has no room
        .{ "r_word_lit", "bool = false" },
        .{ "r_wordz_lit", "bool" },
        // A local variable is storage of its own; a constant local may be the same constant
        // as an equal temporary
        .{ "r_local_decl", "bool = false" },
        .{ "r_local_temp", "bool" },
        .{ "r_local_temp_other", "bool = false" },
        // `&p.*` is `p`
        .{ "r_deref", "bool = true" },
        // A `*T` → `*[1]T` view of a declaration points to the declaration, its only element
        // being the place: an interned pointer is compared with that one element (equal data
        // gives no value, as for `gp`; a literal's sentinel has no room after it)
        .{ "r_view_same", "bool = true" },
        .{ "r_view_elem", "bool = true" },
        .{ "r_view_interned", "bool" },
        .{ "r_view_lit", "bool = false" },
        .{ "r_eql_view", "bool = true" },
        .{ "r_eql_view_other", "bool = false" },
    });
}

test "comptime evaluation: slices of interpreter storage read elements in place" {
    // Guards against copying the whole range when taking an element or the length of a slice:
    // a loop that slices repeatedly (a common pattern in comptime tokenizers) would allocate in
    // proportion to the square of the length, and the result would be unknown once the memory
    // limit is exceeded
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
        // Reading, copying, concatenating and writing through ranges
        .{ "copied", "usize = 12344" },
    });
}

test "comptime evaluation: a *T coerced to *[1]T views the same place" {
    try expectTypes(
        \\fn param(c: u8) u8 {
        \\    const p: *const [1]u8 = &c;
        \\    return p[0];
        \\}
        \\fn paramSlice(c: u8) usize {
        \\    const s: []const u8 = @as(*const [1]u8, &c);
        \\    return s.len + s[0];
        \\}
        \\fn local(c: u8) u8 {
        \\    const x = c;
        \\    const p: *const [1]u8 = &x;
        \\    return p[0];
        \\}
        \\const glob: u8 = 11;
        \\const glob_ptr: *const u8 = &glob;
        \\fn global() u8 {
        \\    const p: *const [1]u8 = &glob;
        \\    const q: *const [1]u8 = glob_ptr;
        \\    return p[0] + q[0];
        \\}
        \\fn writeThrough() u8 {
        \\    var x: u8 = 1;
        \\    const p: *[1]u8 = &x;
        \\    p[0] = 5;
        \\    return x;
        \\}
        \\fn writeOriginal() u8 {
        \\    var x: u8 = 1;
        \\    const p: *const [1]u8 = &x;
        \\    x = 9;
        \\    return p[0];
        \\}
        \\fn writeDeref() u8 {
        \\    var x: u8 = 1;
        \\    const p: *[1]u8 = &x;
        \\    p.* = .{4};
        \\    return x;
        \\}
        \\fn elemAndField() usize {
        \\    var a = [_]u8{ 1, 2, 3 };
        \\    var s: struct { a: u8, b: u8 } = .{ .a = 1, .b = 2 };
        \\    const p: *[1]u8 = &a[1];
        \\    const q: *[1]u8 = &s.b;
        \\    p[0] = 7;
        \\    q[0] += 10;
        \\    return @as(usize, a[1]) * 100 + s.b + p.len;
        \\}
        \\fn viaPointer() u8 {
        \\    var x: u8 = 2;
        \\    const q: *u8 = &x;
        \\    const p: *[1]u8 = q;
        \\    p[0] *= 3;
        \\    return q.*;
        \\}
        \\fn slices() usize {
        \\    var x: u8 = 3;
        \\    const s: []u8 = @as(*[1]u8, &x);
        \\    s[0] = 6;
        \\    for (s) |*e| e.* += 1;
        \\    var t: []const u8 = s;
        \\    t.len = 0;
        \\    const same = &s[0] == &x;
        \\    return @as(usize, x) * 1000 + s.len * 100 + s[1..].len * 10 + t.len + @intFromBool(same);
        \\}
        \\fn concat(c: u8) usize {
        \\    const s: []const u8 = @as(*const [1]u8, &c);
        \\    const t = s[0..s.len] ++ "!";
        \\    return t.len * 1000 + t[0];
        \\}
        \\fn nested() u8 {
        \\    const a = [2]u8{ 1, 2 };
        \\    const p: *const [1][2]u8 = &a;
        \\    return p[0][1];
        \\}
        \\fn derefValue(c: u8) [1]u8 {
        \\    const p: *const [1]u8 = &c;
        \\    return p.*;
        \\}
        \\const Names = struct { short: ?u8 };
        \\fn payload() u8 {
        \\    var n: Names = .{ .short = 1 };
        \\    if (n.short) |*s| {
        \\        const p: *[1]u8 = s;
        \\        p[0] = 8;
        \\    }
        \\    return n.short.?;
        \\}
        \\const r_param = param(7);
        \\const r_param_slice = paramSlice(7);
        \\const r_local = local(7);
        \\const r_global = global();
        \\const r_write_through = writeThrough();
        \\const r_write_original = writeOriginal();
        \\const r_write_deref = writeDeref();
        \\const r_elem_field = elemAndField();
        \\const r_via_pointer = viaPointer();
        \\const r_slices = slices();
        \\const r_concat = concat('a');
        \\const r_nested = nested();
        \\const r_deref = derefValue(7);
        \\const r_payload = payload();
    , &.{
        // `&c` with a `*[1]T` result type takes the address of `c` itself
        .{ "r_param", "u8 = 7" },
        .{ "r_param_slice", "usize = 8" },
        .{ "r_local", "u8 = 7" },
        .{ "r_global", "u8 = 22" },
        // Writes through the view reach the place, and the view sees writes to the place
        .{ "r_write_through", "u8 = 5" },
        .{ "r_write_original", "u8 = 9" },
        .{ "r_write_deref", "u8 = 4" },
        .{ "r_elem_field", "usize = 713" },
        .{ "r_via_pointer", "u8 = 6" },
        // Slicing, iterating, shortening and comparing addresses of the view
        .{ "r_slices", "usize = 7101" },
        .{ "r_concat", "usize = 2097" },
        .{ "r_nested", "u8 = 2" },
        .{ "r_deref", "[1]u8 = \"\\x07\"" },
        // A pointer to the payload of an optional, viewed as an array
        .{ "r_payload", "u8 = 8" },
    });
}
test "comptime evaluation: @fieldParentPtr goes back from a field pointer to its parent" {
    try expectTypes(
        \\const S = struct { a: u8, b: u8 };
        \\const s_val: S = .{ .a = 1, .b = 2 };
        \\fn parentOf(p: *const u8) *const S {
        \\    return @fieldParentPtr("b", p);
        \\}
        \\fn parentEu(p: *const u8) error{Bad}!*const S {
        \\    return @fieldParentPtr("b", p);
        \\}
        \\fn sumViaParent(p: *const u8) u8 {
        \\    const parent: *const S = @fieldParentPtr("b", p);
        \\    return parent.a + parent.b;
        \\}
        \\const U = union { x: u32, y: u8 };
        \\const u_val: U = .{ .y = 7 };
        \\const Inner = struct { x: u16, y: u16 };
        \\const Outer = struct { tag: u8, inner: Inner };
        \\const o_val: Outer = .{ .tag = 5, .inner = .{ .x = 10, .y = 20 } };
        \\const T = struct { u8, u16 };
        \\const t_val: T = .{ 1, 2 };
        \\const arr: [2]S = .{ .{ .a = 1, .b = 2 }, .{ .a = 3, .b = 4 } };
        \\const via_call = parentOf(&s_val.b).a;
        \\const via_block = blk: {
        \\    const parent: *const S = @fieldParentPtr("b", &s_val.b);
        \\    break :blk parent.a;
        \\};
        \\const via_union = blk: {
        \\    const parent: *const U = @alignCast(@fieldParentPtr("y", &u_val.y));
        \\    break :blk parent.y;
        \\};
        \\const via_var = blk: {
        \\    var s: S = .{ .a = 3, .b = 4 };
        \\    const parent: *S = @fieldParentPtr("b", &s.b);
        \\    parent.a = 9;
        \\    break :blk s.a;
        \\};
        \\const const_cast = blk: {
        \\    const parent: *S = @constCast(@fieldParentPtr("b", &s_val.b));
        \\    break :blk parent.a;
        \\};
        \\const const_cast_write = blk: {
        \\    var s: S = .{ .a = 3, .b = 4 };
        \\    const fp: *const u8 = &s.b;
        \\    const parent: *S = @constCast(@fieldParentPtr("b", fp));
        \\    parent.a = 9;
        \\    break :blk s.a;
        \\};
        \\const volatile_const_cast = blk: {
        \\    var s: S = .{ .a = 3, .b = 4 };
        \\    const fp: *const u8 = &s.b;
        \\    const parent: *S = @volatileCast(@constCast(@fieldParentPtr("b", fp)));
        \\    parent.a = 7;
        \\    break :blk s.a;
        \\};
        \\const nested = blk: {
        \\    const inner: *const Inner = @alignCast(@fieldParentPtr("y", &o_val.inner.y));
        \\    const outer: *const Outer = @alignCast(@fieldParentPtr("inner", inner));
        \\    break :blk outer.tag + inner.x;
        \\};
        \\const optional = blk: {
        \\    const parent: ?*const S = @fieldParentPtr("b", &s_val.b);
        \\    break :blk parent.?.a;
        \\};
        \\const error_union = (parentEu(&s_val.b) catch unreachable).a;
        \\const tuple = blk: {
        \\    const parent: *const T = @alignCast(@fieldParentPtr("1", &t_val[1]));
        \\    break :blk parent[0];
        \\};
        \\const array_elem = blk: {
        \\    const parent: *const S = @fieldParentPtr("b", &arr[1].b);
        \\    break :blk parent.a;
        \\};
        \\const whole = blk: {
        \\    const parent: *const S = @fieldParentPtr("a", &s_val.a);
        \\    break :blk parent.*;
        \\};
        \\const in_fn = sumViaParent(&s_val.b);
        \\const same_parent = blk: {
        \\    const parent: *const S = @fieldParentPtr("b", &s_val.b);
        \\    break :blk parent == &s_val;
        \\};
        \\const same_decl = &s_val == &s_val;
        \\const union_field = (&u_val.y).*;
        \\const wrong_field = blk: {
        \\    const parent: *const S = @fieldParentPtr("a", &s_val.b);
        \\    break :blk parent.a;
        \\};
        \\const lone: u8 = 9;
        \\const not_a_field = blk: {
        \\    const parent: *const S = @fieldParentPtr("b", &lone);
        \\    break :blk parent.a;
        \\};
        \\const CF = struct { a: u8, comptime b: u8 = 2 };
        \\const cf_val: CF = .{ .a = 1 };
        \\const comptime_field = blk: {
        \\    const parent: *const CF = @fieldParentPtr("b", &cf_val.b);
        \\    break :blk parent.a;
        \\};
        \\const array_view = blk: {
        \\    const v: *const [1]u8 = &s_val.b;
        \\    const parent: *const S = @fieldParentPtr("b", v);
        \\    break :blk parent.a;
        \\};
    , &.{
        .{ "via_call", "u8 = 1" },
        .{ "via_block", "u8 = 1" },
        // `@alignCast` is merged with `@fieldParentPtr` and gives it its result type
        .{ "via_union", "u8 = 7" },
        // Writes through the parent pointer reach the variable
        .{ "via_var", "u8 = 9" },
        // `@constCast` / `@volatileCast` are merged with `@fieldParentPtr` too: the parent
        // pointer of a `*const` field pointer can be written through
        .{ "const_cast", "u8 = 1" },
        .{ "const_cast_write", "u8 = 9" },
        .{ "volatile_const_cast", "u8 = 7" },
        .{ "nested", "u16 = 15" },
        // The destination type may be an optional pointer; the result type's error union is dropped
        .{ "optional", "u8 = 1" },
        .{ "error_union", "u8 = 1" },
        .{ "tuple", "u8 = 1" },
        .{ "array_elem", "u8 = 3" },
        .{ "whole", "S = .{ .a = 1, .b = 2 }" },
        .{ "in_fn", "u8 = 3" },
        // The parent pointer is the address of the declaration
        .{ "same_parent", "bool = true" },
        .{ "same_decl", "bool = true" },
        .{ "union_field", "u8 = 7" },
        // Compile errors: a field pointer that is not that field of a value of the parent type,
        // a comptime field, and a `*T` → `*[1]T` view of the field, whose element type is not
        // the field's
        .{ "wrong_field", "u8" },
        .{ "not_a_field", "u8" },
        .{ "comptime_field", "u8" },
        .{ "array_view", "u8" },
    });
}

test "comptime evaluation: @fieldParentPtr in extern and packed containers" {
    try expectTypes(
        \\const E = extern struct { a: u32, b: u16, c: u8 };
        \\const e_val: E = .{ .a = 100, .b = 200, .c = 30 };
        \\const P = packed struct { a: u4, b: u4, c: u8 };
        \\const p_val: P = .{ .a = 1, .b = 2, .c = 3 };
        \\const EU = extern union { x: u8, y: u8 };
        \\const eu_val: EU = .{ .y = 4 };
        \\const PU = packed union { x: u8, y: u8 };
        \\const pu_val: PU = .{ .y = 4 };
        \\const extern_struct = blk: {
        \\    const parent: *const E = @alignCast(@fieldParentPtr("c", &e_val.c));
        \\    break :blk parent.a;
        \\};
        \\const packed_struct = blk: {
        \\    const parent: *const P = @fieldParentPtr("c", &p_val.c);
        \\    break :blk parent.a;
        \\};
        \\const extern_union = blk: {
        \\    const parent: *const EU = @fieldParentPtr("y", &eu_val.y);
        \\    break :blk parent.y;
        \\};
        \\const extern_union_other = blk: {
        \\    const parent: *const EU = @fieldParentPtr("x", &eu_val.y);
        \\    break :blk parent.y;
        \\};
        \\const packed_union_other = blk: {
        \\    const parent: *const PU = @fieldParentPtr("x", &pu_val.y);
        \\    break :blk parent.y;
        \\};
    , &.{
        .{ "extern_struct", "u32 = 100" },
        .{ "packed_struct", "u4 = 1" },
        .{ "extern_union", "u8 = 4" },
        // Every field of an extern or packed union starts at the union's address
        .{ "extern_union_other", "u8 = 4" },
        .{ "packed_union_other", "u8 = 4" },
    });
}

test "comptime evaluation: element-wise work is not limited by steps, but large copies hit the memory limit" {
    // The compiler counts only backward branches: a `@memcpy` writing hundreds of thousands of
    // elements one by one is not limited. Evaluation gives up when a large array exceeding the
    // memory limit is copied between two memory checks: `copyLarge` copies 2^20 elements each
    // time, and the 48 copies total more than 1 GB.
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
        \\    const buf: [1 << 20]u8 = @splat(1);
        \\    var sum: u8 = 0;
        \\    for (0..48) |_| {
        \\        const c = buf;
        \\        sum +%= c[0];
        \\    }
        \\    return sum;
        \\}
        \\const many = copyMany();
        \\const few = copyFew();
        \\const large = copyLarge();
    , &.{
        .{ "many", "u8 = 1" },
        .{ "few", "u8 = 1" },
        .{ "large", "u8" },
    });
}

test "comptime evaluation: aggregates with more than 65536 elements are evaluated" {
    // Evaluation used to give up beyond 65536 elements: only the memory limit should apply
    try expectTypes(
        \\const big: [100000]u8 = @splat(2);
        \\fn last() u8 {
        \\    const s = big[0..];
        \\    const copy = s.*;
        \\    return copy[99999];
        \\}
        \\const v = last();
    , &.{
        .{ "v", "u8 = 2" },
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
        // Converting the right-hand side to the payload type would treat `null` as `u8`
        .{ "a", "?u8" },
        .{ "b", "u8" },
        .{ "c", "?u16" },
        .{ "d", "Color" },
        .{ "e", "?u8" },
        .{ "f", "u8" },
        // Without collecting the values of `break :sw`, every prong is noreturn
        .{ "k", "u8" },
        .{ "k2", "u16" },
        // With a comptime-known operand, only the matching prong is executed;
        // with `continue :sw4`, control may move to another prong
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
        // Expanding a self-referential value along pointers never terminates
        // (the native stack is exhausted and the process crashes)
        .{ "loop", "Node" },
        .{ "both", "[2]Node" },
        // The result of a call is interned as a whole;
        // when it contains a cycle, its fields are unknown too
        .{ "v", "u32" },
        .{ "short", "u32 = 1" },
        .{ "long", "Node" },
    });
}

test "calls returning types with comptime-only fields nested at any depth are evaluated at comptime" {
    // Guards against checking only two levels of nesting:
    // a `type` field at the third level also makes the return type comptime-only
    try expectTypes(
        \\const Inner = struct { t: type };
        \\const Mid = struct { b: Inner };
        \\const Outer = struct { a: Mid };
        \\fn make(comptime X: type) Outer {
        \\    return .{ .a = .{ .b = .{ .t = X } } };
        \\}
        \\const Node = struct { next: ?*const Node, t: type };
        \\fn list(comptime X: type) []const Node {
        \\    return &.{.{ .next = null, .t = X }};
        \\}
        \\fn f() void {
        \\    const r = make(u16);
        \\    const deep = r.a.b.t;
        \\    const l = list(u32);
        \\    const first = l[0].t;
        \\    _ = .{ deep, first };
        \\}
    , &.{
        .{ "deep", "type = u16" },
        .{ "first", "type = u32" },
    });
}

test "calls returning a file whose fields are comptime-only are evaluated at comptime" {
    // Guards against taking a file, which is a struct, as never comptime-only
    try expectTypes(
        \\t: type,
        \\fn make(comptime X: type) @This() {
        \\    return .{ .t = X };
        \\}
        \\fn f() void {
        \\    const r = make(u16);
        \\    const deep = r.t;
        \\    _ = deep;
        \\}
    , &.{
        .{ "deep", "type = u16" },
    });
}

test "comptime evaluation: backward branches follow the compiler's quota" {
    // Guards against giving up by the number of expressions or by the fuel of the whole request:
    // the compiler only counts backward branches (loop iterations, calls), `@setEvalBranchQuota`
    // raises the quota, and a quota raised by a caller also applies to callees; when the quota is
    // exceeded, the compiler reports an error and the result is unknown
    try expectTypes(
        \\fn sum(n: usize) usize {
        \\    var total: usize = 0;
        \\    var i: usize = 0;
        \\    while (i < n) : (i += 1) total += i % 7;
        \\    return total;
        \\}
        \\fn raised() usize {
        \\    @setEvalBranchQuota(200_000);
        \\    var total: usize = 0;
        \\    for (0..100_000) |i| total += i % 3;
        \\    return total;
        \\}
        \\fn caller() usize {
        \\    @setEvalBranchQuota(10_000);
        \\    return sum(5000);
        \\}
        \\fn lowered() usize {
        \\    @setEvalBranchQuota(10);
        \\    return sum(500);
        \\}
        \\const big = raised();
        \\const via_caller = caller();
        \\const default_ok = sum(500);
        \\const kept = lowered();
        \\const over = sum(5000);
        \\fn f() void {
        \\    @setEvalBranchQuota(10_000);
        \\    const in_body = comptime sum(5000);
        \\    _ = in_body;
        \\}
    , &.{
        .{ "big", "usize = 99999" },
        .{ "via_caller", "usize = 14995" },
        .{ "default_ok", "usize = 1494" },
        .{ "kept", "usize = 1494" },
        .{ "over", "usize" },
        .{ "in_body", "usize = 14995" },
    });
}

test "comptime while loops count one backward branch per iteration" {
    // Prevents counting a backward branch for the first condition check of each `while` loop,
    // which gave up below the compiler's quota; expected values are the results of zig 0.17.0
    try expectTypes(
        \\const w1000 = blk: { var s: usize = 0; var i: usize = 0; while (i < 1000) : (i += 1) s += 1; break :blk s; };
        \\const q2000 = blk: { @setEvalBranchQuota(2000); var s: usize = 0; var i: usize = 0; while (i < 2000) : (i += 1) s += 1; break :blk s; };
        \\const n500x0 = blk: { var s: usize = 0; var i: usize = 0; while (i < 500) : (i += 1) { var j: usize = 0; while (j < 0) : (j += 1) s += 1; s += 1; } break :blk s; };
        \\const c1000 = blk: { var s: usize = 0; var i: usize = 0; while (i < 1000) : (i += 1) { if (i % 2 == 0) continue; s += 1; } break :blk s; };
        \\const w1001 = blk: { var s: usize = 0; var i: usize = 0; while (i < 1001) : (i += 1) s += 1; break :blk s; };
    , &.{
        .{ "w1000", "usize = 1000" },
        .{ "q2000", "usize = 2000" },
        .{ "n500x0", "usize = 500" },
        .{ "c1000", "usize = 500" },
        // The compiler reports that the quota is exceeded
        .{ "w1001", "usize" },
    });
}

test "function pointers are runtime values, not comptime-only" {
    // Guards against treating function pointers as comptime-only: a struct containing a function
    // pointer field (such as the vtable of `std.mem.Allocator`) is not comptime-only, calls
    // returning it are not evaluated at comptime, and functions taking a function pointer
    // are not generic either
    try expectTypes(
        \\fn hello() void {}
        \\const VTable = struct { call: *const fn () void };
        \\const Iface = struct { vtable: *const VTable };
        \\const Outer = struct { iface: Iface };
        \\fn make() Outer {
        \\    return .{ .iface = .{ .vtable = &.{ .call = &hello } } };
        \\}
        \\fn apply(cb: *const fn () void) u8 {
        \\    cb();
        \\    return 1;
        \\}
        \\fn f() void {
        \\    const o = make();
        \\    const n = apply(&hello);
        \\    _ = .{ o, n };
        \\}
    , &.{
        .{ "o", "Outer" },
        .{ "n", "u8" },
    });
}

test "cast destination types at comptime: the result type without its error union and optional" {
    // A cast converted to a result type such as `?u8` itself (`return @intCast(x);` in a function
    // returning `?u8`) and had no value.
    try expectTypes(
        \\const Color = enum { red, green, blue };
        \\fn optIntCast(x: u32) ?u8 { return @intCast(x); }
        \\fn optTruncate(x: u32) ?u8 { return @truncate(x); }
        \\fn optEnumFromInt(x: u32) ?Color { return @enumFromInt(x); }
        \\fn euFloatFromInt(x: u32) error{Bad}!f32 { return @floatFromInt(x); }
        \\fn optBitCast(x: i8) ?u8 { return @bitCast(x); }
        \\fn euOptIntCast(x: u32) error{Bad}!?u8 { return @intCast(x); }
        \\fn optFloatCast(x: f64) ?f32 { return @floatCast(x); }
        \\fn euIntFromFloat(x: f32) error{Bad}!i32 { return @intFromFloat(x); }
        \\fn optBitCastFloat(x: u32) ?f32 { return @bitCast(x); }
        \\fn optEuIntCast(x: u32) ?(error{Bad}!u8) { return @intCast(x); }
        \\const opt_intcast = optIntCast(7);
        \\const opt_truncate = optTruncate(0x105);
        \\const opt_enumfromint = optEnumFromInt(2);
        \\const eu_floatfromint = euFloatFromInt(3) catch unreachable;
        \\const opt_bitcast = optBitCast(-1);
        \\const eu_opt_intcast = euOptIntCast(9) catch unreachable;
        \\const opt_floatcast = optFloatCast(1.5);
        \\const eu_intfromfloat = euIntFromFloat(-2.75) catch unreachable;
        \\const opt_bitcast_float = optBitCastFloat(0x3f800000);
        \\const opt_eu_intcast = optEuIntCast(6);
        \\const local_opt: ?u8 = @intCast(@as(u32, 200));
        \\const local_eu: error{X}!u16 = @truncate(@as(u32, 0x10002));
    , &.{
        .{ "opt_intcast", "?u8 = 7" },
        .{ "opt_truncate", "?u8 = 5" },
        .{ "opt_enumfromint", "?Color = .blue" },
        .{ "eu_floatfromint", "f32 = 3" },
        .{ "opt_bitcast", "?u8 = 255" },
        // The error union is stripped first, then the optional
        .{ "eu_opt_intcast", "?u8 = 9" },
        .{ "opt_floatcast", "?f32 = 1.5" },
        .{ "eu_intfromfloat", "i32 = -2" },
        .{ "opt_bitcast_float", "?f32 = 1" },
        // Only the optional around the error union is stripped: casting to `error{Bad}!u8` is a
        // compile error
        .{ "opt_eu_intcast", "?error{Bad}!u8" },
        .{ "local_opt", "?u8 = 200" },
        .{ "local_eu", "error{X}!u16 = 2" },
    });
}

test "cast destination types at comptime: pointer casts strip only the error union, @errorCast only the optional, @splat both" {
    try expectTypes(
        \\const zero: u8 = 0;
        \\const erased: *const anyopaque = @ptrCast(&zero);
        \\fn euPtrCast() error{Bad}!*const u8 { return @ptrCast(erased); }
        \\fn euOptPtrCast(p: ?*const anyopaque) error{Bad}!?*const u8 { return @ptrCast(@alignCast(p)); }
        \\fn euAlignCast(p: *align(1) const u8) error{Bad}!*const u8 { return @alignCast(p); }
        \\const E = error{ A, B };
        \\fn optErrorCast(e: anyerror) ?E { return @errorCast(e); }
        \\fn narrow(x: anyerror!u8) error{A}!u8 { return @errorCast(x); }
        \\fn optSplat(x: u8) ?@Vector(2, u8) { return @splat(x); }
        \\fn euSplat(x: u8) error{Bad}![3]u8 { return @splat(x); }
        \\const eu_ptr = euPtrCast();
        \\const eu_ptr_load = (euPtrCast() catch unreachable).*;
        \\const eu_opt_ptr = euOptPtrCast(erased);
        \\const eu_opt_ptr_null = euOptPtrCast(null);
        \\const eu_align = (euAlignCast(&zero) catch unreachable).*;
        \\const opt_error = optErrorCast(error.A);
        \\const eu_error = narrow(5);
        \\const eu_error_err = narrow(error.A);
        \\const opt_splat = optSplat(4);
        \\const eu_splat = euSplat(5);
    , &.{
        .{ "eu_ptr", "error{Bad}!*const u8 = &0" },
        .{ "eu_ptr_load", "u8 = 0" },
        // The optional pointer stays the destination type
        .{ "eu_opt_ptr", "error{Bad}!?*const u8 = &0" },
        .{ "eu_opt_ptr_null", "error{Bad}!?*const u8 = null" },
        .{ "eu_align", "u8 = 0" },
        .{ "opt_error", "?error{A,B} = error.A" },
        // The error union stays the destination type
        .{ "eu_error", "error{A}!u8 = 5" },
        .{ "eu_error_err", "error{A}!u8 = error.A" },
        // `@splat` strips the error union and the optional
        .{ "opt_splat", "?@Vector(2, u8) = .{ 4, 4 }" },
        .{ "eu_splat", "error{Bad}![3]u8 = .{ 5, 5, 5 }" },
    });
}

test "comptime evaluation gives builtin operands the compiler's result types" {
    // Without these result types, a result-type builtin in the operand (`@intCast(n)`,
    // `@floatFromInt(n)`) could not be evaluated, and the call had no value
    try expectTypes(
        \\const U = union(enum) { a: u8, s: struct { x: u8, y: u8 = 4 } };
        \\fn fill(n: u32) u8 {
        \\    var buf: [4]u8 = undefined;
        \\    @memset(&buf, @intCast(n));
        \\    return buf[3];
        \\}
        \\fn fillSlice(n: u32) u16 {
        \\    var buf: [4]u16 = undefined;
        \\    const s: []u16 = &buf;
        \\    @memset(s, @truncate(n));
        \\    return buf[1];
        \\}
        \\fn splatLast(n: u32) u8 {
        \\    const v: [3]u8 = @splat(@intCast(n));
        \\    return v[2];
        \\}
        \\fn root(n: u32) f64 {
        \\    return @sqrt(@floatFromInt(n));
        \\}
        \\fn ceilInt() f32 {
        \\    return @ceil(3);
        \\}
        \\fn halfRet() f16 {
        \\    return @round(0.4999999);
        \\}
        \\fn halfInt() u8 {
        \\    return @round(0.4999999);
        \\}
        \\const union_init_cast = @unionInit(U, "a", @intCast(@as(u32, 5))).a;
        \\const union_init_struct = @unionInit(U, "s", .{ .x = 1 }).s.y;
        \\const memset_cast = fill(9);
        \\const memset_slice_truncate = fillSlice(0x10007);
        \\const splat_cast = splatLast(6);
        \\const sqrt_int: f32 = @sqrt(16);
        \\const sqrt_cast = root(9);
        \\const sqrt_optional: ?f64 = @sqrt(@floatFromInt(@as(u32, 25)));
        \\const exp2_int: f32 = @exp2(3);
        \\const log2_cast: f64 = @log2(@floatFromInt(@as(u32, 8)));
        \\const floor_cast: f64 = @floor(@floatFromInt(@as(u32, 9)));
        \\const ceil_branch: f32 = @ceil(if (true) 3 else 4);
        \\const ceil_int = ceilInt();
        \\const ceil_int_top: f32 = @ceil(3);
        \\const half_ret = halfRet();
        \\const half_int = halfInt();
        \\const round_to_int: u32 = @round(@as(f32, 2.5));
        \\const floor_int_dest: u32 = @floor(@floatFromInt(@as(u8, 3)));
        \\const muladd_cast = @mulAdd(f64, @floatFromInt(@as(u32, 2)), 3.0, 1.0);
        \\const muladd_addend_cast = @mulAdd(f32, 2, 3, @floatFromInt(@as(u8, 5)));
        \\const int_cast = @Int(.unsigned, @intCast(@as(usize, 12)));
        \\const vector_cast = @Vector(@intCast(@as(usize, 3)), u8);
    , &.{
        .{ "union_init_cast", "u8 = 5" },
        .{ "union_init_struct", "u8 = 4" },
        .{ "memset_cast", "u8 = 9" },
        .{ "memset_slice_truncate", "u16 = 7" },
        .{ "splat_cast", "u8 = 6" },
        .{ "sqrt_int", "f32 = 4" },
        .{ "sqrt_cast", "f64 = 3" },
        // The operand's result type is the call's without the optional
        .{ "sqrt_optional", "?f64 = 5" },
        .{ "exp2_int", "f32 = 8" },
        .{ "log2_cast", "f64 = 3" },
        .{ "floor_cast", "f64 = 9" },
        // The branches of the operand are coerced to the result type; an integer operand itself
        // is not, and a rounding builtin rejects it: a compile error, no value
        .{ "ceil_branch", "f32 = 3" },
        .{ "ceil_int", "f32" },
        .{ "ceil_int_top", "f32" },
        // A float operand is coerced to a float result type before rounding (0.4999999 is 0.5 in
        // f16); with an integer result type it is rounded in its own type
        .{ "half_ret", "f16 = 1" },
        .{ "half_int", "u8 = 0" },
        // With an integer result type, the rounding builtin converts its float operand, which
        // has no result type: `@floatFromInt` without one is a compile error, no value
        .{ "round_to_int", "u32 = 3" },
        .{ "floor_int_dest", "u32" },
        .{ "muladd_cast", "f64 = 7" },
        .{ "muladd_addend_cast", "f32 = 11" },
        .{ "int_cast", "type = u12" },
        .{ "vector_cast", "type = @Vector(3, u8)" },
    });
}

test "operands of float math builtins and @Vector get their result types" {
    try expectTypes(
        \\fn f(n: u32) void {
        \\    const s: f64 = @sqrt(@floatFromInt(n));
        \\    const r: ?f32 = @floor(@floatFromInt(n + 1));
        \\    const v: @Vector(2, f32) = @sqrt(@splat(4));
        \\    const V = @Vector(@intCast(@as(usize, 2)), u8);
        \\    const c: f32 = @ceil(7);
        \\    _ = .{ s, r, v, V, c };
        \\}
    , &.{
        .{ "@floatFromInt(n)", "f64" },
        // The result type without the optional
        .{ "@floatFromInt(n + 1)", "f32" },
        .{ "@splat(4)", "@Vector(2, f32) = .{ 4, 4 }" },
        .{ "@intCast(@as(usize, 2))", "u32" },
        .{ "V", "type = @Vector(2, u8)" },
        // The operand of a rounding builtin is not coerced to its result type: an integer operand
        // is a compile error, and the call has no value
        .{ "7", "comptime_int = 7" },
        .{ "@ceil(7)", "f32" },
    });
}

test "comptime evaluation of integer builtins, @memset, @memmove and @call" {
    try expectTypes(
        \\const ov = @addWithOverflow(@as(u8, 250), 10);
        \\const ov_sum = ov[0];
        \\const ov_bit = ov[1];
        \\const no_ov = @subWithOverflow(@as(u8, 5), 3)[1];
        \\const mul_ov = @mulWithOverflow(@as(i8, 64), 2)[0];
        \\const shl_ov = @shlWithOverflow(@as(u8, 0b1100_0000), 1);
        \\const swapped = @byteSwap(@as(u16, 0x1234));
        \\const swapped_signed = @byteSwap(@as(i16, 0x00ff));
        \\const reversed = @bitReverse(@as(u8, 1));
        \\const shl_exact = @shlExact(@as(u8, 1), 3);
        \\const shr_exact = @shrExact(@as(u8, 8), 3);
        \\const filled = blk: {
        \\    var b: [3]u8 = undefined;
        \\    @memset(&b, 7);
        \\    break :blk b[1];
        \\};
        \\const moved = blk: {
        \\    var b = [_]u8{ 1, 2, 3, 4 };
        \\    @memmove(b[1..4], b[0..3]);
        \\    break :blk b[3];
        \\};
        \\fn add(a: u8, b: u8) u8 {
        \\    return a + b;
        \\}
        \\const called = @call(.auto, add, .{ 1, 2 });
    , &.{
        .{ "ov_sum", "u8 = 4" },
        .{ "ov_bit", "u1 = 1" },
        .{ "no_ov", "u1 = 0" },
        .{ "mul_ov", "i8 = -128" },
        .{ "shl_ov", "struct { u8, u1 } = .{ 128, 1 }" },
        .{ "swapped", "u16 = 13330" },
        .{ "swapped_signed", "i16 = -256" },
        .{ "reversed", "u8 = 128" },
        .{ "shl_exact", "u8 = 8" },
        .{ "shr_exact", "u8 = 1" },
        .{ "filled", "u8 = 7" },
        .{ "moved", "u8 = 3" },
        .{ "called", "u8 = 3" },
    });
}

test "comptime @fromBackingInt coerces its operand to the backing integer of the destination type" {
    try expectTypes(
        \\const Color = enum { red, green, blue };
        \\const E8 = enum(u8) { a = 10, b, c = 20 };
        \\const Es = enum(i8) { neg = -3, zero = 0, pos = 5 };
        \\const cast: Color = @fromBackingInt(@intCast(@as(comptime_int, 2)));
        \\const cast_u: Color = @fromBackingInt(@intCast(@as(u32, 1)));
        \\const truncated: Color = @fromBackingInt(@truncate(@as(u32, 0x102)));
        \\const bit_cast: Es = @fromBackingInt(@bitCast(@as(u8, 0xfd)));
        \\const explicit: E8 = @fromBackingInt(@intCast(@as(usize, 11)));
        \\const signed: Es = @fromBackingInt(@intCast(@as(i64, 5)));
        \\const as_dest = @as(Color, @fromBackingInt(@intCast(@as(u64, 2))));
        \\fn optional(x: u32) ?Color {
        \\    return @fromBackingInt(@intCast(x));
        \\}
        \\const from_opt = optional(2);
        \\fn errorUnion(x: u32) error{Bad}!Color {
        \\    if (x > 2) return error.Bad;
        \\    return @fromBackingInt(@intCast(x));
        \\}
        \\const from_eu = errorUnion(1) catch unreachable;
        \\const stored = blk: {
        \\    var result: [2]Color = undefined;
        \\    result[0] = @fromBackingInt(1);
        \\    result[1] = @fromBackingInt(@intCast(2));
        \\    const final = result;
        \\    break :blk final;
        \\};
        \\const stored_by_ptr = blk: {
        \\    var result: [3]Color = undefined;
        \\    for (&result, [_]comptime_int{ 0, 1, 2 }) |*r, v| {
        \\        r.* = @fromBackingInt(@intCast(v));
        \\    }
        \\    const final = result;
        \\    break :blk final;
        \\};
    , &.{
        // The operand's result type is the tag type: `u2` for `Color`, the explicit one otherwise
        .{ "cast", "Color = .blue" },
        .{ "cast_u", "Color = .green" },
        .{ "truncated", "Color = .blue" },
        .{ "bit_cast", "Es = .neg" },
        .{ "explicit", "E8 = .b" },
        .{ "signed", "Es = .pos" },
        .{ "as_dest", "Color = .blue" },
        // The destination type drops the optional and the error union of the result type
        .{ "from_opt", "?Color = .blue" },
        .{ "from_eu", "Color = .green" },
        // Stores through element places and pointer captures (the shape of std.enums.valuesFromFields)
        .{ "stored", "[2]Color = .{ .green, .blue }" },
        .{ "stored_by_ptr", "[3]Color = .{ .red, .green, .blue }" },
    });
}

test "comptime evaluation gives the right operand of a shift the result type Log2Int(T)" {
    // Without a result type, a result-type builtin in the shift amount (`x >> @intCast(n)`) could
    // not be evaluated, and the whole computation had no value
    try expectTypes(
        \\fn shrCast(a: u32, n: u64) u32 {
        \\    return a >> @intCast(n);
        \\}
        \\fn shlTruncate(a: u32, n: u64) u32 {
        \\    return a << @truncate(n);
        \\}
        \\fn shrAssignCast(a: u32, n: u64) u32 {
        \\    var x = a;
        \\    x >>= @intCast(n);
        \\    return x;
        \\}
        \\fn shlAssignCast(a: u32, n: u64) u32 {
        \\    var x = a;
        \\    x <<= @intCast(n);
        \\    return x;
        \\}
        \\fn shlExactCast(a: u32, n: u64) u32 {
        \\    return @shlExact(a, @intCast(n));
        \\}
        \\fn shrExactCast(a: u32, n: u64) u32 {
        \\    return @shrExact(a, @intCast(n));
        \\}
        \\fn oddPart(a: u32) u32 {
        \\    var x = a;
        \\    x >>= @intCast(@ctz(x));
        \\    return x;
        \\}
        \\const shr_cast = shrCast(256, 4);
        \\const shl_truncate = shlTruncate(1, 64 + 4);
        \\const shr_assign_cast = shrAssignCast(256, 4);
        \\const shl_assign_cast = shlAssignCast(1, 4);
        \\const shl_exact_cast = shlExactCast(1, 4);
        \\const shr_exact_cast = shrExactCast(256, 4);
        \\const odd_part = oddPart(48);
        \\const direct = @as(u32, 1) << @intCast(@as(u64, 3));
        \\const wide_lhs = @as(i64, -1) << @truncate(@as(u64, 64 + 63));
        \\const big_lhs = (1 << 100) >> @intCast(@as(u64, 98));
        \\const zero_width = @as(u0, 0) << @intCast(@as(u64, 0));
        \\const zero_width_exact = @shrExact(@as(u0, 0), 0);
        \\const too_far = shrCast(256, 32);
    , &.{
        .{ "shr_cast", "u32 = 16" },
        .{ "shl_truncate", "u32 = 16" },
        .{ "shr_assign_cast", "u32 = 16" },
        .{ "shl_assign_cast", "u32 = 16" },
        .{ "shl_exact_cast", "u32 = 16" },
        .{ "shr_exact_cast", "u32 = 16" },
        .{ "odd_part", "u32 = 3" },
        .{ "direct", "u32 = 8" },
        .{ "wide_lhs", "i64 = -9223372036854775808" },
        // `Log2Int(comptime_int)` is comptime_int
        .{ "big_lhs", "comptime_int = 4" },
        // `Log2Int(u0)` is u0, and a shift by zero is the left operand
        .{ "zero_width", "u0 = 0" },
        .{ "zero_width_exact", "u0 = 0" },
        // 32 does not fit the shift amount type u5: a compile error, no value
        .{ "too_far", "u32" },
    });
}

test "comptime saturating shift assignment" {
    // `<<|=` was missing from the compound assignment operators: the evaluation gave up, and a
    // `comptime var` lost its value
    try expectTypes(
        \\fn shlSat(a: u8, n: u8) u8 {
        \\    var x = a;
        \\    x <<|= n;
        \\    return x;
        \\}
        \\fn shlSatSigned(a: i8, n: u64) i8 {
        \\    var x = a;
        \\    x <<|= n;
        \\    return x;
        \\}
        \\fn shlSatComptime() comptime_int {
        \\    var x: comptime_int = 3;
        \\    x <<|= 200;
        \\    return x;
        \\}
        \\const saturated = shlSat(3, 7);
        \\const in_range = shlSat(3, 2);
        \\const signed_saturated = shlSatSigned(-3, 100);
        \\const comptime_shifted = shlSatComptime();
        \\const big_shifted = 3 <<| 200;
        \\export fn entry() u8 {
        \\    comptime var s: u8 = 3;
        \\    s <<|= 7;
        \\    const s_v = s;
        \\    return s_v;
        \\}
    , &.{
        .{ "saturated", "u8 = 255" },
        .{ "in_range", "u8 = 12" },
        .{ "signed_saturated", "i8 = -128" },
        // A comptime_int has no bound: `<<|` is `<<`
        .{ "comptime_shifted", "comptime_int = 4820814132776970826625886277023487807566608981348378505904128" },
        .{ "big_shifted", "comptime_int = 4820814132776970826625886277023487807566608981348378505904128" },
        .{ "s_v", "u8 = 255" },
    });
}

test "@embedFile reads the file next to the source; missing files are unknown" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    _ = try w.add("/p/data/hello.txt", "hello");
    _ = try w.add("/p/empty.txt", "");
    const src =
        \\const text = @embedFile("data/hello.txt");
        \\const first = text[0];
        \\const empty = @embedFile("empty.txt");
        \\const missing = @embedFile("missing.txt");
        \\const count = blk: {
        \\    var n: usize = 0;
        \\    for (@embedFile("data/hello.txt")) |c| {
        \\        if (c == 'l') n += 1;
        \\    }
        \\    break :blk n;
        \\};
    ;
    const f = try w.add("/p/main.zig", src);
    try testing.expectEqualStrings("*const [5:0]u8 = \"hello\"", try typeAt(&w, f.file, src, "text", 0));
    try testing.expectEqualStrings("u8 = 104", try typeAt(&w, f.file, src, "first", 0));
    try testing.expectEqualStrings("*const [0:0]u8 = \"\"", try typeAt(&w, f.file, src, "empty", 0));
    try testing.expectEqualStrings("unknown", try typeAt(&w, f.file, src, "missing", 0));
    try testing.expectEqualStrings("usize = 2", try typeAt(&w, f.file, src, "count", 0));
}

test "@import of a zon file is its value in inference and comptime evaluation" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    _ = try w.add("/p/pos.zon", ".{ .x = 3, .y = 4, .list = .{ 1, 2, 3 } }");
    _ = try w.add("/p/cfg.zon", ".{ .port = 8080 }");
    _ = try w.add("/p/n.zon", "5");
    // An integer beyond i128 has an arbitrary-precision value
    _ = try w.add("/p/big.zon", "0x1_0000_0000_0000_0000_0000_0000_0000_0000");
    const src =
        \\const pos = @import("pos.zon");
        \\const sum = pos.x + pos.y;
        \\fn lengthSquared() comptime_int {
        \\    const p = @import("pos.zon");
        \\    return p.x * p.x + p.y * p.y;
        \\}
        \\const len2 = lengthSquared();
        \\fn second() comptime_int {
        \\    return @import("pos.zon").list[1];
        \\}
        \\const second_value = second();
        \\fn five() u32 {
        \\    return @import("n.zon");
        \\}
        \\const five_value = five();
        \\const Cfg = struct { port: u16 };
        \\fn port() u16 {
        \\    const c: Cfg = @import("cfg.zon");
        \\    return c.port;
        \\}
        \\const port_value = port();
        \\const big = @import("big.zon");
    ;
    const f = try w.add("/p/main.zig", src);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "pos", "struct { comptime x: comptime_int = 3, comptime y: comptime_int = 4, comptime list: struct { comptime comptime_int = 1, comptime comptime_int = 2, comptime comptime_int = 3 } = .{ 1, 2, 3 } } = .{ .x = 3, .y = 4, .list = .{ 1, 2, 3 } }" },
        .{ "sum", "comptime_int = 7" },
        .{ "len2", "comptime_int = 25" },
        .{ "second_value", "comptime_int = 2" },
        // Scalars are converted to the result type
        .{ "five_value", "u32 = 5" },
        // Structs are parsed according to the result type, not converted from the anonymous
        // value: the value cannot be evaluated
        .{ "port_value", "u16" },
        .{ "big", "comptime_int = 340282366920938463463374607431768211456" },
    };
    for (cases) |c| {
        testing.expectEqualStrings(c[1], try typeAt(&w, f.file, src, c[0], 0)) catch |err| {
            std.debug.print("type of `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "types of zon values are the same only for the same literal of the same file" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    _ = try w.add("/p/a.zon", ".{ .x = 1, .l = .{ .y = 1 }, .m = .{ .y = 1 } }");
    _ = try w.add("/p/b.zon", ".{ .x = 1, .l = .{ .y = 1 }, .m = .{ .y = 1 } }");
    const src =
        \\const a = @import("a.zon");
        \\const again = @import("a.zon");
        \\const b = @import("b.zon");
        \\const lit = .{ .y = 1 };
        \\const same_file = @TypeOf(a) == @TypeOf(again);
        \\const same_field = @TypeOf(a.l) == @TypeOf(again.l);
        \\const other_file = @TypeOf(a) == @TypeOf(b);
        \\const other_field = @TypeOf(a.l) == @TypeOf(a.m);
        \\const literal = @TypeOf(a.l) == @TypeOf(lit);
    ;
    const file = (try w.add("/p/main.zig", src)).file;
    for ([_]struct { []const u8, []const u8 }{
        .{ "same_file", "bool = true" },
        .{ "same_field", "bool = true" },
        .{ "other_file", "bool = false" },
        .{ "other_field", "bool = false" },
        .{ "literal", "bool = false" },
    }) |c| {
        testing.expectEqualStrings(c[1], try typeAt(&w, file, src, c[0], 0)) catch |err| {
            std.debug.print("type of `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "the root expression of a zon file is inferred and inf and nan are floats" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const src = ".{ .a = inf, .b = -inf, .c = nan, .d = 1 }";
    const f = try w.add("/p/cfg.zon", src);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "inf", "comptime_float = inf" },
        .{ "-inf", "comptime_float = -inf" },
        .{ "nan", "comptime_float = nan" },
        .{ "1", "comptime_int = 1" },
    };
    for (cases) |c| {
        testing.expectEqualStrings(c[1], try typeAt(&w, f.file, src, c[0], 0)) catch |err| {
            std.debug.print("type of `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "@src has the type std.builtin.SourceLocation" {
    try expectStdTypes(
        \\fn f() void {
        \\    const here = @src();
        \\    _ = here;
        \\}
    , &.{.{ "here", "SourceLocation" }});
}

test "values of structs whose fields are all u8 keep the declared field types and display as structs" {
    // Such values are represented as bytes: a `?u8` field used to be read as u8
    // (`if (p.short) |s|` could not be evaluated), and the value was displayed as a string
    try expectTypes(
        \\const Names = struct {
        \\    short: ?u8 = null,
        \\};
        \\const n0: Names = .{ .short = 'h' };
        \\const arr = [_]Names{n0};
        \\fn short(p: Names) u8 {
        \\    if (p.short) |s| return s;
        \\    return 0;
        \\}
        \\const v = short(n0);
        \\const P = struct { a: u8, b: u8 };
        \\const pp: P = .{ .a = 1, .b = 2 };
    , &.{
        .{ "n0", "Names = .{ .short = 104 }" },
        .{ "arr", "[1]Names = .{ .{ .short = 104 } }" },
        .{ "v", "u8 = 104" },
        .{ "pp", "P = .{ .a = 1, .b = 2 }" },
    });
}

test "the address of a function declaration is a const pointer with a comptime value" {
    // A function declaration is not a `var`: `&handler` used to be a mutable `*fn` without a value
    try expectTypes(
        \\fn handler(x: u8) void {
        \\    _ = x;
        \\}
        \\const S = struct {
        \\    fn m(x: u8) void {
        \\        _ = x;
        \\    }
        \\};
        \\const T1 = if (@TypeOf(&handler) == *const fn (u8) void) u8 else u16;
        \\var g: u32 = 0;
        \\fn f() void {
        \\    const cb = &handler;
        \\    var cb2 = &handler;
        \\    _ = &cb2;
        \\    const table = .{ .on_event = &handler };
        \\    const via_s = &S.m;
        \\    const pg = &g;
        \\    _ = .{ cb, table, via_s, pg };
        \\}
    , &.{
        .{ "cb", "*const fn (u8) void = &fn (u8) void" },
        .{ "cb2", "*const fn (u8) void" },
        .{ "table", "struct { comptime on_event: *const fn (u8) void = &fn (u8) void } = .{ .on_event = &fn (u8) void }" },
        .{ "via_s", "*const fn (u8) void = &fn (u8) void" },
        .{ "pg", "*u32" },
        .{ "T1", "type = u8" },
    });
}

test "variables reached through namespaces and payloads of noreturn orelse are mutable places" {
    // The constness of a namespace member is its own: `&State.counter` used to follow the `const`
    // that names the namespace and be `*const u32`
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    _ = try w.add("/p/other.zig",
        \\pub var global: i64 = 0;
        \\pub const fixed: i64 = 0;
    );
    const src =
        \\const other = @import("other.zig");
        \\const State = struct {
        \\    pub var counter: u32 = 0;
        \\    pub const fixed: u32 = 0;
        \\    pub var buf: [8]u8 = undefined;
        \\};
        \\const Self = @This();
        \\var instance: u16 = 0;
        \\const Sym = struct { file: ?u32 = null };
        \\const Obj = struct {
        \\    d_sym: ?Sym = null,
        \\    res: anyerror!Sym = .{},
        \\    fn close(self: *Obj) bool {
        \\        const ds = &(self.d_sym orelse return false);
        \\        const r_sym = &(self.res catch return false);
        \\        _ = .{ ds, r_sym };
        \\        return true;
        \\    }
        \\};
        \\fn probe(n: usize, opt: ?Sym) void {
        \\    const p1 = &State.counter;
        \\    const p2 = &State.fixed;
        \\    const p3 = &Self.instance;
        \\    const p10 = &other.global;
        \\    const p11 = &other.fixed;
        \\    const s1 = State.buf[0..n];
        \\    const o1 = &(opt orelse return);
        \\    for (&State.buf) |*c| {
        \\        const pc = c;
        \\        _ = pc;
        \\    }
        \\    _ = .{ p1, p2, p3, p10, p11, s1, o1 };
        \\}
    ;
    const f = try w.add("/p/main.zig", src);
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "p1", "*u32" },
        .{ "p2", "*const u32 = &0" },
        .{ "p3", "*u16" },
        .{ "p10", "*i64" },
        .{ "p11", "*const i64 = &0" },
        .{ "s1", "[]u8" },
        .{ "pc", "*u8" },
        .{ "ds", "*Sym" },
        .{ "r_sym", "*Sym" },
        .{ "o1", "*const Sym" },
    };
    for (cases) |c| {
        const actual = try typeAt(&w, f.file, src, c[0], 0);
        testing.expectEqualStrings(c[1], actual) catch |err| {
            std.debug.print("type of `{s}`\n", .{c[0]});
            return err;
        };
    }
}

test "a while loop whose condition always holds takes the type of its breaks" {
    // The implicit `void` else branch used to be a peer of the breaks, which made these unknown
    try expectTypes(
        \\const Point = struct { x: i32 };
        \\const forever = true;
        \\fn probe(c: bool, items: []const Point) void {
        \\    var i: usize = 0;
        \\    const found = while (true) : (i += 1) {
        \\        if (items[i].x == 0) break items[i];
        \\    };
        \\    const n = while (true) {
        \\        if (c) break @as(u32, 1);
        \\    };
        \\    const m = while (forever) {
        \\        if (c) break @as(u16, 1);
        \\    };
        \\    const lab = outer: while (true) {
        \\        for (items) |_| {
        \\            if (c) break :outer @as(u8, 1);
        \\        }
        \\    };
        \\    const rt = while (c) {
        \\        if (c) break @as(u32, 1);
        \\    };
        \\    const with_else = while (c) {
        \\        if (c) break @as(u32, 1);
        \\    } else @as(u32, 2);
        \\    _ = .{ found, n, m, lab, rt, with_else };
        \\}
    , &.{
        .{ "found", "Point" },
        .{ "n", "u32" },
        .{ "m", "u16" },
        .{ "lab", "u8" },
        .{ "rt", "unknown" },
        .{ "with_else", "u32" },
    });
}

test "operands of comparisons and arithmetic have no result type" {
    // The other operand's type used to be the result type: `mode == .Debug` resolved the decl
    // literal `Debug`, and `b + @intCast(y)` cast to u8
    try expectTypes(
        \\const Optimize = enum {
        \\    debug,
        \\    safe,
        \\    pub const Debug: Optimize = .debug;
        \\};
        \\const mode: Optimize = .debug;
        \\const t = if (mode == .Debug) 1 else 0;
        \\const t2 = if (mode == .debug) 1 else 0;
        \\const t3 = if (.safe != mode) 1 else 0;
        \\var b: u8 = 1;
        \\var y: u64 = 2;
        \\fn f(o: ?Optimize) void {
        \\    const v28 = b + @intCast(y);
        \\    const v29 = b + 1;
        \\    const eq = o == .safe;
        \\    _ = .{ v28, v29, eq };
        \\}
    , &.{
        .{ "t", "comptime_int" },
        .{ "t2", "comptime_int = 1" },
        .{ "t3", "comptime_int = 1" },
        .{ "v28", "unknown" },
        .{ "v29", "u8" },
        .{ "eq", "bool" },
        .{ ".Debug", "@EnumLiteral() = .Debug" },
        .{ ".safe", "Optimize = .safe" },
    });
}
