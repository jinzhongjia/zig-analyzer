//! InternPool：类型与 comptime 值的唯一表示（设计 §9.1）。
//!
//! 类型本身也是值（其类型为 `type`）。相同的 Key 总是得到相同的 Index，与驻留顺序无关，
//! 因此 query 结果中的 Index 可以直接比较。只追加不删除：类型身份在整个进程内稳定。
//! 多个 query 并发驻留，以互斥锁保护（见 §19.6）。

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const FileId = @import("../base/Vfs.zig").FileId;
const AstId = @import("../syntax/ItemTree.zig").AstId;
const deepEql = @import("../util/deep_eql.zig").deepEql;

const InternPool = @This();

gpa: Allocator,
io: Io,
mutex: Io.Mutex = .init,
/// 目标的指针位宽（usize、指针的大小）；0 表示未知（项目中各模块的宽度不一致）。
/// 与 `PointerBits` input 在同一写事务中设置，读取它的 query 都先读该 input 以记录依赖
pointer_bits: std.atomic.Value(u16) = .init(@bitSizeOf(usize)),
/// Key 中切片的存储
arena: std.heap.ArenaAllocator,
items: std.ArrayList(Key) = .empty,
map: std.HashMapUnmanaged(Key, Index, KeyContext, std.hash_map.default_max_load_percentage) = .empty,

pub const Index = enum(u32) {
    /// 未知类型（吸收一切：参与运算的结果也是 unknown，不产生诊断）
    unknown,
    type_type,
    void_type,
    bool_type,
    noreturn_type,
    anyerror_type,
    anyopaque_type,
    comptime_int_type,
    comptime_float_type,
    null_type,
    undefined_type,
    enum_literal_type,
    usize_type,
    isize_type,
    u8_type,
    u1_type,
    void_value,
    true_value,
    false_value,
    null_value,
    undefined_value,
    /// 实例实参中非 comptime 参数的占位（不属于实例的身份）
    runtime,
    /// `error{}`
    empty_error_set,
    _,
};

pub const Simple = enum {
    type,
    void,
    bool,
    noreturn,
    anyerror,
    anyopaque,
    comptime_int,
    comptime_float,
    null,
    undefined,
    enum_literal,
    usize,
    isize,
    c_char,
    c_short,
    c_ushort,
    c_int,
    c_uint,
    c_long,
    c_ulong,
    c_longlong,
    c_ulonglong,
    c_longdouble,
    f16,
    f32,
    f64,
    f80,
    f128,
};

pub const SimpleValue = enum { void, true, false, null, undefined };

pub const PtrSize = enum { one, many, slice, c };

pub const Key = union(enum) {
    unknown,
    simple_type: Simple,
    int_type: struct { signedness: std.builtin.Signedness, bits: u16 },
    ptr_type: struct { child: Index, size: PtrSize, is_const: bool = false, sentinel: ?Index = null },
    array_type: struct { len: u64, child: Index, sentinel: ?Index = null },
    optional_type: Index,
    error_union_type: struct { err: Index, payload: Index },
    /// 名字按字典序排列、去重
    error_set_type: []const []const u8,
    /// 函数 `!T` 中由函数体推导的错误集（设计 §9.4）。签名只记录这个标记，成员由 `ErrorSetOf` 按需求出
    inferred_error_set: struct { file: FileId, decl: AstId, inst: ?Index = null },
    fn_type: struct { params: []const Index, ret: Index, varargs: bool = false },
    /// 身份 = 定义位置（文件 + 容器的 AstId）
    container_type: Container,
    /// 元组 `struct { A, B }`（`@Tuple`、元组字面量）
    tuple_type: []const Index,
    /// `@Vector(len, T)`
    vector_type: struct { len: u32, child: Index },
    /// 没有结果类型的匿名结构体字面量 `.{ .a = x }` 的类型
    anon_struct_type: struct { names: []const []const u8, types: []const Index },
    /// `@Enum` / `@Struct` / `@Union` 构造的类型
    reified_type: Reified,
    /// `union(enum)` 自动生成的标签枚举（值为 union 类型）
    union_tag_type: Index,

    simple_value: SimpleValue,
    int_value: struct { ty: Index, value: i128 },
    /// 浮点值（f128 的位表示，已按类型的精度舍入）
    float_value: struct { ty: Index, bits: u128 },
    enum_literal: []const u8,
    /// 枚举类型的某个成员
    enum_tag: struct { ty: Index, name: []const u8 },
    error_value: []const u8,
    /// 函数声明；`inst` 为函数所在的实例（泛型容器的方法）
    fn_value: struct { ty: Index, file: FileId, decl: AstId, inst: ?Index = null },

    /// 数组、向量、元组、结构体（按字段顺序）的值。类型为切片或指向数组的指针时表示所指向的元素
    aggregate: struct { ty: Index, elems: []const Index },
    /// 元素为 u8 的聚合（字符串），类型的含义同 `aggregate`
    bytes: struct { ty: Index, bytes: []const u8 },
    /// union 的值
    union_value: struct { ty: Index, tag: []const u8, payload: Index },
    /// 指向 comptime 值的单项指针
    ptr_value: struct { ty: Index, pointee: Index },

    /// 泛型函数的一次实例化：函数 + 各参数的值（comptime 参数为实参值，未知时为 unknown；
    /// anytype 参数为实参类型；非 comptime 参数为 `runtime`）。
    /// `parent` 为函数自身所在的实例（定义在另一个实例化容器中的函数）
    instance: Instance,
    /// 没有具体实例时的 comptime 类型参数（抽象实例，设计 §9.4），显示为参数名
    opaque_param: struct { file: FileId, owner: AstId, binding: u32, name: []const u8 },
    /// 实例实参中非 comptime 参数的占位
    runtime,
};

pub const Instance = struct {
    file: FileId,
    decl: AstId,
    args: []const Index,
    parent: ?Index = null,
};

/// 内置函数构造的容器类型。身份 = 构造位置（成员 + 表达式）+ 构造时的实例 + 内容
pub const Reified = struct {
    kind: Kind,
    file: FileId,
    owner: AstId,
    expr: u32,
    /// 构造所在的实例（显示为 `FieldEnum(S)`）
    inst: ?Index = null,
    layout: Layout = .auto,
    /// enum：标签的整数类型；union：标签枚举（untagged 为 null）；packed struct：backing 整数
    tag: ?Index = null,
    names: []const []const u8,
    /// struct / union 的字段类型
    types: []const Index = &.{},
    /// enum 成员的值
    values: []const i128 = &.{},
    nonexhaustive: bool = false,

    pub const Kind = enum { @"struct", @"enum", @"union" };
    pub const Layout = enum { auto, @"extern", @"packed" };
};

pub const Container = struct {
    file: FileId,
    ast_id: AstId,
    kind: Kind,
    /// 容器定义在泛型函数体内时，该函数的实例（`ArrayList(u8)` 与 `ArrayList(i32)` 是不同的类型）
    inst: ?Index = null,

    pub const Kind = enum { file, @"struct", @"enum", @"union", @"opaque" };
};

/// 类型与（若 comptime 已知）值。`ty == .unknown` 表示未知
pub const TypedValue = struct {
    ty: Index,
    val: ?Index = null,

    pub const unknown: TypedValue = .{ .ty = .unknown };

    pub fn isType(tv: TypedValue) bool {
        return tv.ty == .type_type;
    }

    /// 值为某个类型时返回该类型
    pub fn asType(tv: TypedValue) ?Index {
        return if (tv.ty == .type_type) tv.val else null;
    }

    pub fn ofType(t: Index) TypedValue {
        return .{ .ty = .type_type, .val = t };
    }
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Key) u64 {
        var h: std.hash.Wyhash = .init(0);
        // 错误集是切片的切片：要逐层跟随指针
        std.hash.autoHashStrat(&h, k, .DeepRecursive);
        return h.final();
    }
    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return deepEql(a, b);
    }
};

/// 与 `Index` 的预置成员一一对应
const preset = [_]Key{
    .unknown,
    .{ .simple_type = .type },
    .{ .simple_type = .void },
    .{ .simple_type = .bool },
    .{ .simple_type = .noreturn },
    .{ .simple_type = .anyerror },
    .{ .simple_type = .anyopaque },
    .{ .simple_type = .comptime_int },
    .{ .simple_type = .comptime_float },
    .{ .simple_type = .null },
    .{ .simple_type = .undefined },
    .{ .simple_type = .enum_literal },
    .{ .simple_type = .usize },
    .{ .simple_type = .isize },
    .{ .int_type = .{ .signedness = .unsigned, .bits = 8 } },
    .{ .int_type = .{ .signedness = .unsigned, .bits = 1 } },
    .{ .simple_value = .void },
    .{ .simple_value = .true },
    .{ .simple_value = .false },
    .{ .simple_value = .null },
    .{ .simple_value = .undefined },
    .runtime,
    .{ .error_set_type = &.{} },
};

pub fn init(gpa: Allocator, io: Io) Allocator.Error!InternPool {
    var ip: InternPool = .{ .gpa = gpa, .io = io, .arena = .init(gpa) };
    errdefer ip.deinit();
    for (preset, 0..) |k, i| std.debug.assert(@backingInt(try ip.get(k)) == i);
    return ip;
}

pub fn deinit(ip: *InternPool) void {
    ip.items.deinit(ip.gpa);
    ip.map.deinit(ip.gpa);
    ip.arena.deinit();
    ip.* = undefined;
}

pub fn pointerBits(ip: *const InternPool) ?u16 {
    const bits = ip.pointer_bits.load(.monotonic);
    return if (bits == 0) null else bits;
}

/// 只能在写事务中调用
pub fn setPointerBits(ip: *InternPool, bits: ?u16) void {
    ip.pointer_bits.store(bits orelse 0, .monotonic);
}

/// 驻留：相同的 Key 返回相同的 Index
pub fn get(ip: *InternPool, k: Key) Allocator.Error!Index {
    ip.mutex.lockUncancelable(ip.io);
    defer ip.mutex.unlock(ip.io);
    if (ip.map.get(k)) |i| return i;
    const owned = try ip.own(k);
    const index: Index = @fromBackingInt(@as(u32, @intCast(ip.items.items.len)));
    try ip.items.append(ip.gpa, owned);
    errdefer _ = ip.items.pop();
    try ip.map.put(ip.gpa, owned, index);
    return index;
}

/// Key 中的切片复制到 arena
fn own(ip: *InternPool, k: Key) Allocator.Error!Key {
    const a = ip.arena.allocator();
    return switch (k) {
        .error_set_type => |names| blk: {
            const out = try a.alloc([]const u8, names.len);
            for (names, out) |n, *o| o.* = try a.dupe(u8, n);
            break :blk .{ .error_set_type = out };
        },
        .fn_type => |f| .{ .fn_type = .{ .params = try a.dupe(Index, f.params), .ret = f.ret, .varargs = f.varargs } },
        .enum_literal => |n| .{ .enum_literal = try a.dupe(u8, n) },
        .enum_tag => |t| .{ .enum_tag = .{ .ty = t.ty, .name = try a.dupe(u8, t.name) } },
        .error_value => |n| .{ .error_value = try a.dupe(u8, n) },
        .instance => |i| .{ .instance = .{ .file = i.file, .decl = i.decl, .args = try a.dupe(Index, i.args), .parent = i.parent } },
        .tuple_type => |t| .{ .tuple_type = try a.dupe(Index, t) },
        .anon_struct_type => |t| .{ .anon_struct_type = .{ .names = try dupeNames(a, t.names), .types = try a.dupe(Index, t.types) } },
        .reified_type => |t| blk: {
            var out = t;
            out.names = try dupeNames(a, t.names);
            out.types = try a.dupe(Index, t.types);
            out.values = try a.dupe(i128, t.values);
            break :blk .{ .reified_type = out };
        },
        .aggregate => |v| .{ .aggregate = .{ .ty = v.ty, .elems = try a.dupe(Index, v.elems) } },
        .bytes => |v| .{ .bytes = .{ .ty = v.ty, .bytes = try a.dupe(u8, v.bytes) } },
        .union_value => |v| .{ .union_value = .{ .ty = v.ty, .tag = try a.dupe(u8, v.tag), .payload = v.payload } },
        .opaque_param => |o| .{ .opaque_param = .{ .file = o.file, .owner = o.owner, .binding = o.binding, .name = try a.dupe(u8, o.name) } },
        else => k,
    };
}

fn dupeNames(a: Allocator, names: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, names.len);
    for (names, out) |n, *o| o.* = try a.dupe(u8, n);
    return out;
}

/// 返回的 Key 中的切片在 InternPool 生命周期内有效
pub fn key(ip: *InternPool, index: Index) Key {
    ip.mutex.lockUncancelable(ip.io);
    defer ip.mutex.unlock(ip.io);
    return ip.items.items[@backingInt(index)];
}

// ── 常用构造 ─────────────────────────────────────────────────────────

pub fn intType(ip: *InternPool, signedness: std.builtin.Signedness, bits: u16) Allocator.Error!Index {
    return ip.get(.{ .int_type = .{ .signedness = signedness, .bits = bits } });
}

pub fn optionalOf(ip: *InternPool, child: Index) Allocator.Error!Index {
    if (child == .unknown) return .unknown;
    return ip.get(.{ .optional_type = child });
}

pub fn ptrTo(ip: *InternPool, child: Index, size: PtrSize, is_const: bool) Allocator.Error!Index {
    if (child == .unknown) return .unknown;
    return ip.get(.{ .ptr_type = .{ .child = child, .size = size, .is_const = is_const } });
}

/// 错误集：名字排序去重
pub fn errorSet(ip: *InternPool, gpa: Allocator, names: []const []const u8) Allocator.Error!Index {
    const sorted = try gpa.dupe([]const u8, names);
    defer gpa.free(sorted);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var n: usize = 0;
    for (sorted) |s| {
        if (n > 0 and std.mem.eql(u8, sorted[n - 1], s)) continue;
        sorted[n] = s;
        n += 1;
    }
    return ip.get(.{ .error_set_type = sorted[0..n] });
}

/// 字符串字面量的类型 `*const [len:0]u8`
pub fn stringLiteralType(ip: *InternPool, len: u64) Allocator.Error!Index {
    const zero = try ip.get(.{ .int_value = .{ .ty = .u8_type, .value = 0 } });
    const array = try ip.get(.{ .array_type = .{ .len = len, .child = .u8_type, .sentinel = zero } });
    return ip.ptrTo(array, .one, true);
}

pub fn isInt(ip: *InternPool, t: Index) bool {
    return switch (ip.key(t)) {
        .int_type => true,
        .simple_type => |s| switch (s) {
            .usize, .isize, .comptime_int, .c_char, .c_short, .c_ushort, .c_int, .c_uint, .c_long, .c_ulong, .c_longlong, .c_ulonglong => true,
            else => false,
        },
        else => false,
    };
}

pub fn isFloat(ip: *InternPool, t: Index) bool {
    return switch (ip.key(t)) {
        .simple_type => |s| switch (s) {
            .f16, .f32, .f64, .f80, .f128, .comptime_float, .c_longdouble => true,
            else => false,
        },
        else => false,
    };
}

// ── 显示 ─────────────────────────────────────────────────────────────

/// 以 Zig 语法输出类型或值。`container_name` 给出容器类型的名字（如 `mem.Allocator`）
pub fn print(ip: *InternPool, index: Index, w: *Io.Writer, container_name: anytype) Io.Writer.Error!void {
    switch (ip.key(index)) {
        .unknown => try w.writeAll("unknown"),
        .simple_type => |s| try w.writeAll(@tagName(s)),
        .int_type => |i| try w.print("{c}{d}", .{ @as(u8, if (i.signedness == .signed) 'i' else 'u'), i.bits }),
        .ptr_type => |p| {
            switch (p.size) {
                .one => try w.writeAll("*"),
                .many, .slice, .c => {
                    try w.writeAll(switch (p.size) {
                        .many => "[*",
                        .slice => "[",
                        else => "[*c",
                    });
                    if (p.sentinel) |s| {
                        try w.writeAll(":");
                        try ip.print(s, w, container_name);
                    }
                    try w.writeAll("]");
                },
            }
            if (p.is_const) try w.writeAll("const ");
            try ip.print(p.child, w, container_name);
        },
        .array_type => |a| {
            try w.print("[{d}", .{a.len});
            if (a.sentinel) |s| {
                try w.writeAll(":");
                try ip.print(s, w, container_name);
            }
            try w.writeAll("]");
            try ip.print(a.child, w, container_name);
        },
        .optional_type => |c| {
            try w.writeAll("?");
            try ip.print(c, w, container_name);
        },
        .error_union_type => |e| {
            try ip.print(e.err, w, container_name);
            try w.writeAll("!");
            try ip.print(e.payload, w, container_name);
        },
        .inferred_error_set => if (@hasDecl(@TypeOf(container_name), "writeInferredErrorSet")) try container_name.writeInferredErrorSet(index, w) else try w.writeAll("anyerror"),
        .error_set_type => |names| {
            try w.writeAll("error{");
            for (names, 0..) |n, i| {
                if (i != 0) try w.writeAll(",");
                try w.writeAll(n);
            }
            try w.writeAll("}");
        },
        .fn_type => |f| {
            try w.writeAll("fn (");
            for (f.params, 0..) |p, i| {
                if (i != 0) try w.writeAll(", ");
                try ip.print(p, w, container_name);
            }
            if (f.varargs) try w.writeAll(if (f.params.len != 0) ", ..." else "...");
            try w.writeAll(") ");
            try ip.print(f.ret, w, container_name);
        },
        .container_type => |c| try container_name.write(c, w),
        .tuple_type => |types| {
            try w.writeAll("struct {");
            for (types, 0..) |t, i| {
                try w.writeAll(if (i == 0) " " else ", ");
                try ip.print(t, w, container_name);
            }
            try w.writeAll(if (types.len == 0) "}" else " }");
        },
        .vector_type => |v| {
            try w.print("@Vector({d}, ", .{v.len});
            try ip.print(v.child, w, container_name);
            try w.writeAll(")");
        },
        .anon_struct_type => |t| {
            try w.writeAll("struct {");
            for (t.names, t.types, 0..) |n, ty, i| {
                try w.print("{s}{s}: ", .{ if (i == 0) " " else ", ", n });
                try ip.print(ty, w, container_name);
            }
            try w.writeAll(if (t.names.len == 0) "}" else " }");
        },
        .reified_type => |t| if (@hasDecl(@TypeOf(container_name), "writeReified")) try container_name.writeReified(t, w) else try ip.printReified(t, w, container_name),
        .union_tag_type => |u| {
            try w.writeAll("@typeInfo(");
            try ip.print(u, w, container_name);
            try w.writeAll(").@\"union\".tag_type.?");
        },
        .simple_value => |v| try w.writeAll(@tagName(v)),
        .int_value => |v| try w.print("{d}", .{v.value}),
        .float_value => |v| try w.print("{d}", .{@as(f128, @bitCast(v.bits))}),
        .enum_literal => |n| try w.print(".{f}", .{std.zig.fmtId(n)}),
        .enum_tag => |t| try w.print(".{f}", .{std.zig.fmtId(t.name)}),
        .error_value => |n| try w.print("error.{s}", .{n}),
        .fn_value => |f| try ip.print(f.ty, w, container_name),
        .aggregate => |v| {
            if (ip.key(v.ty) == .ptr_type) try w.writeAll("&");
            // 结构体的值带字段名
            const names: ?[]const []const u8 = if (@hasDecl(@TypeOf(container_name), "fieldNames")) container_name.fieldNames(v.ty) else null;
            try w.writeAll(".{");
            for (v.elems, 0..) |e, i| {
                if (i == max_printed_elems) {
                    try w.writeAll(", ...");
                    break;
                }
                try w.writeAll(if (i == 0) " " else ", ");
                if (names) |n| if (i < n.len) try w.print(".{f} = ", .{std.zig.fmtId(n[i])});
                try ip.print(e, w, container_name);
            }
            try w.writeAll(if (v.elems.len == 0) "}" else " }");
        },
        .bytes => |v| try w.print("\"{f}\"", .{std.zig.fmtString(v.bytes[0..@min(v.bytes.len, 64)])}),
        .union_value => |v| {
            try w.print(".{{ .{f} = ", .{std.zig.fmtId(v.tag)});
            try ip.print(v.payload, w, container_name);
            try w.writeAll(" }");
        },
        .ptr_value => |v| {
            try w.writeAll("&");
            try ip.print(v.pointee, w, container_name);
        },
        .instance => try w.writeAll("instance"),
        .opaque_param => |o| try w.writeAll(o.name),
        .runtime => try w.writeAll("_"),
    }
}

/// 聚合值最多显示的元素个数
const max_printed_elems = 16;

/// 没有构造位置的名字时，按内容显示构造的类型
pub fn printReified(ip: *InternPool, t: Reified, w: *Io.Writer, container_name: anytype) Io.Writer.Error!void {
    try w.print("{t} {{", .{t.kind});
    for (t.names, 0..) |n, i| {
        if (i == max_printed_elems) {
            try w.writeAll(", ...");
            break;
        }
        try w.print("{s}{s}", .{ if (i == 0) " " else ", ", n });
        if (i < t.types.len) {
            try w.writeAll(": ");
            try ip.print(t.types[i], w, container_name);
        }
    }
    try w.writeAll(if (t.names.len == 0) "}" else " }");
}

const testing = std.testing;

test "interning is idempotent and presets are stable" {
    var ip: InternPool = try .init(testing.allocator, testing.io);
    defer ip.deinit();
    try testing.expectEqual(Index.u8_type, try ip.intType(.unsigned, 8));
    const a = try ip.ptrTo(.u8_type, .slice, true);
    const b = try ip.ptrTo(.u8_type, .slice, true);
    try testing.expectEqual(a, b);
    try testing.expect(a != try ip.ptrTo(.u8_type, .slice, false));
    try testing.expectEqual(try ip.errorSet(testing.allocator, &.{ "B", "A", "B" }), try ip.errorSet(testing.allocator, &.{ "A", "B" }));

    const Names = struct {
        fn write(_: @This(), _: Container, w: *Io.Writer) Io.Writer.Error!void {
            try w.writeAll("S");
        }
    };
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try ip.print(try ip.stringLiteralType(5), &w, Names{});
    try testing.expectEqualStrings("*const [5:0]u8", w.buffered());
    w.end = 0;
    const eu = try ip.get(.{ .error_union_type = .{ .err = .anyerror_type, .payload = try ip.optionalOf(a) } });
    try ip.print(eu, &w, Names{});
    try testing.expectEqualStrings("anyerror!?[]const u8", w.buffered());
}
