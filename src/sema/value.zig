//! comptime 值的语义（类型推导与 comptime 解释器共用）：按类型位宽的整数运算、值与类型的
//! 相等判断、值的类型转换、comptime-only 类型的判断。
//!
//! 相等判断返回 `?bool`：抽象参数、未知值，或身份取决于捕获值的泛型实例无法判断时为 null，
//! 调用方据此不选择任何分支，而不是给出可能错误的结果。
//!
//! 与目标相关的大小（usize、指针）按目标的指针位宽（`InternPool.pointerBits`）计算；
//! 位宽未知时（各模块的目标宽度不一致）这些值为未知。

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("InternPool.zig");
const Index = InternPool.Index;
const SyntaxKind = @import("../syntax/kind.zig").SyntaxKind;

// ── 整数 ─────────────────────────────────────────────────────────────

pub const IntInfo = struct { signed: bool, bits: u16 };

/// 定宽整数类型的符号与位宽；comptime_int 与位宽取决于目标的 C 类型（c_char、c_long）为 null
pub fn intInfo(ip: *InternPool, t: Index) ?IntInfo {
    return switch (ip.key(t)) {
        .int_type => |i| .{ .signed = i.signedness == .signed, .bits = i.bits },
        .simple_type => |s| switch (s) {
            .usize => .{ .signed = false, .bits = ip.pointerBits() orelse return null },
            .isize => .{ .signed = true, .bits = ip.pointerBits() orelse return null },
            .c_short => .{ .signed = true, .bits = 16 },
            .c_ushort => .{ .signed = false, .bits = 16 },
            .c_int => .{ .signed = true, .bits = 32 },
            .c_uint => .{ .signed = false, .bits = 32 },
            .c_longlong => .{ .signed = true, .bits = 64 },
            .c_ulonglong => .{ .signed = false, .bits = 64 },
            else => null,
        },
        else => null,
    };
}

/// 运算的中间结果：两个 i128 的积与移位结果都放得下
const Wide = i256;

const Bounds = struct { min: Wide, max: Wide };

/// 位宽超过 128 时为 null（值以 i128 存储，超出部分不折叠）
fn bounds(info: IntInfo) ?Bounds {
    if (info.bits > 128) return null;
    if (info.bits == 0) return .{ .min = 0, .max = 0 };
    if (info.signed) {
        const half = @as(Wide, 1) << @intCast(info.bits - 1);
        return .{ .min = -half, .max = half - 1 };
    }
    return .{ .min = 0, .max = (@as(Wide, 1) << @intCast(info.bits)) - 1 };
}

/// 按二进制补码截断到 `info` 的位宽
fn truncate(info: IntInfo, v: Wide) Wide {
    if (info.bits == 0) return 0;
    const m = @as(Wide, 1) << @intCast(info.bits);
    var r = @mod(v, m);
    if (info.signed and r >= @divExact(m, 2)) r -= m;
    return r;
}

const Overflow = enum { check, wrap, saturate };

/// 运算结果放入类型 `ty`（comptime_int 或定宽整数）。越界时：普通运算为 null（编译器会报错），
/// 回绕运算截断，饱和运算取边界
fn fit(ip: *InternPool, ty: Index, v: Wide, mode: Overflow) ?i128 {
    if (ty == .comptime_int_type) return std.math.cast(i128, v);
    const info = intInfo(ip, ty) orelse return null;
    const b = bounds(info) orelse return null;
    const r: Wide = if (v >= b.min and v <= b.max) v else switch (mode) {
        .check => return null,
        .wrap => truncate(info, v),
        .saturate => if (v < b.min) b.min else b.max,
    };
    return std.math.cast(i128, r);
}

/// 整数二元运算的 comptime 结果（`ty` 为结果类型）；结果不确定或编译器会报错时为 null
pub fn binaryInt(ip: *InternPool, op: SyntaxKind, ty: Index, a: i128, b: i128) ?i128 {
    const x: Wide = a;
    const y: Wide = b;
    return switch (op) {
        .plus => fit(ip, ty, x + y, .check),
        .plus_percent => fit(ip, ty, x + y, .wrap),
        .plus_pipe => fit(ip, ty, x + y, .saturate),
        .minus => fit(ip, ty, x - y, .check),
        .minus_percent => fit(ip, ty, x - y, .wrap),
        .minus_pipe => fit(ip, ty, x - y, .saturate),
        .asterisk => fit(ip, ty, x * y, .check),
        .asterisk_percent => fit(ip, ty, x * y, .wrap),
        .asterisk_pipe => fit(ip, ty, x * y, .saturate),
        // 有符号的 `/` 与 `%` 要求使用 @divTrunc 等，只折叠非负操作数
        .slash => if (y <= 0 or x < 0) null else fit(ip, ty, @divTrunc(x, y), .check),
        .percent => if (y <= 0 or x < 0) null else fit(ip, ty, @rem(x, y), .check),
        .ampersand => fit(ip, ty, x & y, .check),
        .pipe => fit(ip, ty, x | y, .check),
        .caret => fit(ip, ty, x ^ y, .check),
        .angle_bracket_angle_bracket_left => shl(ip, ty, x, y, false),
        .angle_bracket_angle_bracket_left_pipe => shl(ip, ty, x, y, true),
        .angle_bracket_angle_bracket_right => shr(ip, ty, x, y),
        else => null,
    };
}

/// `<<`：定宽整数移出的位被丢弃（移位量须小于位宽）；`<<|` 饱和
fn shl(ip: *InternPool, ty: Index, x: Wide, y: Wide, saturate: bool) ?i128 {
    if (y < 0) return null;
    if (ty == .comptime_int_type) {
        if (y > 127) return if (x == 0) 0 else null;
        return fit(ip, ty, x << @intCast(y), .check);
    }
    const info = intInfo(ip, ty) orelse return null;
    if (info.bits > 128) return null;
    if (y >= info.bits) {
        if (!saturate) return null;
        if (x == 0) return 0;
        const b = bounds(info).?;
        return std.math.cast(i128, if (x < 0) b.min else b.max);
    }
    return fit(ip, ty, x << @intCast(y), if (saturate) .saturate else .wrap);
}

fn shr(ip: *InternPool, ty: Index, x: Wide, y: Wide) ?i128 {
    if (y < 0) return null;
    if (ty == .comptime_int_type) return fit(ip, ty, x >> @intCast(@min(y, 255)), .check);
    const info = intInfo(ip, ty) orelse return null;
    if (y >= info.bits) return null;
    return fit(ip, ty, x >> @intCast(y), .check);
}

/// `-x` / `-%x`
pub fn negate(ip: *InternPool, ty: Index, a: i128, wrapping: bool) ?i128 {
    return fit(ip, ty, -@as(Wide, a), if (wrapping) .wrap else .check);
}

/// `~x`：只对定宽整数有定义
pub fn bitNot(ip: *InternPool, ty: Index, a: i128) ?i128 {
    const info = intInfo(ip, ty) orelse return null;
    return fit(ip, ty, truncate(info, ~@as(Wide, a)), .check);
}

/// comptime 值自身的类型（值驻留时不带类型的场合，如 comptime 调用的实参）
pub fn typeOfValue(ip: *InternPool, v: Index) Index {
    return switch (ip.key(v)) {
        .int_value => |i| i.ty,
        .enum_literal => .enum_literal_type,
        .enum_tag => |t| t.ty,
        .simple_value => |s| switch (s) {
            .true, .false => .bool_type,
            .void => .void_type,
            .null => .null_type,
            .undefined => .undefined_type,
        },
        .fn_value => |f| f.ty,
        .float_value => |f| f.ty,
        .aggregate => |a| a.ty,
        .bytes => |b| b.ty,
        .union_value => |u| u.ty,
        .ptr_value => |p| p.ty,
        else => |k| if (isTypeKey(k)) .type_type else .unknown,
    };
}

/// 两个整数类型的 peer 类型：comptime_int 取另一侧；同符号取较宽者；无符号且较窄时可放入有符号；
/// 其他组合（编译错误）为 null
pub fn peerIntType(ip: *InternPool, a: Index, b: Index) ?Index {
    if (a == b) return a;
    if (a == .comptime_int_type and ip.isInt(b)) return b;
    if (b == .comptime_int_type and ip.isInt(a)) return a;
    const x = intInfo(ip, a) orelse return null;
    const y = intInfo(ip, b) orelse return null;
    if (x.signed == y.signed) return if (x.bits >= y.bits) a else b;
    const s = if (x.signed) x else y;
    const u = if (x.signed) y else x;
    if (u.bits < s.bits) return if (x.signed) a else b;
    return null;
}

/// 值是否在整数类型的范围内（comptime_int 总是）
pub fn intFits(ip: *InternPool, ty: Index, v: i128) bool {
    return fit(ip, ty, v, .check) != null;
}

// ── 浮点 ─────────────────────────────────────────────────────────────

pub fn floatOf(ip: *InternPool, v: ?Index) ?f128 {
    return switch (ip.key(v orelse return null)) {
        .float_value => |f| @bitCast(f.bits),
        .int_value => |i| @floatFromInt(i.value),
        else => null,
    };
}

/// 按浮点类型的精度舍入；不是浮点类型时为 null
fn roundTo(ip: *InternPool, ty: Index, x: f128) ?f128 {
    return switch (ip.key(ty)) {
        .simple_type => |s| switch (s) {
            .f16 => @as(f16, @floatCast(x)),
            .f32 => @as(f32, @floatCast(x)),
            .f64 => @as(f64, @floatCast(x)),
            .f80 => @as(f80, @floatCast(x)),
            .f128, .comptime_float => x,
            else => null,
        },
        else => null,
    };
}

/// 浮点类型 `ty` 的值
pub fn floatValue(ip: *InternPool, ty: Index, x: f128) Allocator.Error!?Index {
    const r = roundTo(ip, ty, x) orelse return null;
    return try ip.get(.{ .float_value = .{ .ty = ty, .bits = @bitCast(r) } });
}

/// 浮点二元运算（`ty` 为结果的浮点类型）；结果不确定时为 null
pub fn binaryFloat(ip: *InternPool, op: SyntaxKind, ty: Index, a: f128, b: f128) Allocator.Error!?Index {
    const r: f128 = switch (op) {
        .plus => a + b,
        .minus => a - b,
        .asterisk => a * b,
        .slash => if (b == 0) return null else a / b,
        else => return null,
    };
    return floatValue(ip, ty, r);
}

pub fn intOf(ip: *InternPool, v: ?Index) ?i128 {
    return switch (ip.key(v orelse return null)) {
        .int_value => |i| i.value,
        else => null,
    };
}

// ── 大小与对齐 ───────────────────────────────────────────────────────

pub const Layout = struct { size: u64, alignment: u64, bits: u64 };

/// 类型的大小、对齐与位宽（`@sizeOf` / `@alignOf` / `@bitSizeOf`）。按 x86_64 / aarch64 的 ABI，
/// 只处理不依赖容器布局的类型；auto 布局的容器等为 null
pub fn typeLayout(ip: *InternPool, t: Index) ?Layout {
    const pointer_bits: u64 = ip.pointerBits() orelse 0;
    const ptr_bytes: u64 = pointer_bits / 8;
    return switch (ip.key(t)) {
        .int_type => |i| intLayout(i.bits),
        .simple_type => |s| switch (s) {
            .bool => .{ .size = 1, .alignment = 1, .bits = 1 },
            .void => .{ .size = 0, .alignment = 1, .bits = 0 },
            .usize, .isize => if (pointer_bits == 0) null else intLayout(@intCast(pointer_bits)),
            .c_short, .c_ushort => intLayout(16),
            .c_int, .c_uint => intLayout(32),
            .c_longlong, .c_ulonglong => intLayout(64),
            .f16 => .{ .size = 2, .alignment = 2, .bits = 16 },
            .f32 => .{ .size = 4, .alignment = 4, .bits = 32 },
            .f64 => .{ .size = 8, .alignment = 8, .bits = 64 },
            .f80 => .{ .size = 16, .alignment = 16, .bits = 80 },
            .f128 => .{ .size = 16, .alignment = 16, .bits = 128 },
            .anyerror => .{ .size = 2, .alignment = 2, .bits = 16 },
            else => null,
        },
        .error_set_type, .inferred_error_set => .{ .size = 2, .alignment = 2, .bits = 16 },
        .ptr_type => |p| if (pointer_bits == 0)
            null
        else if (p.size == .slice)
            .{ .size = 2 * ptr_bytes, .alignment = ptr_bytes, .bits = 2 * pointer_bits }
        else
            .{ .size = ptr_bytes, .alignment = ptr_bytes, .bits = pointer_bits },
        .optional_type => |c| switch (ip.key(c)) {
            // 非 C 指针的 optional 以空指针表示 null，与指针同大小
            .ptr_type => |p| if (p.size == .c) null else typeLayout(ip, c),
            else => blk: {
                const l = typeLayout(ip, c) orelse break :blk null;
                // 载荷之后一个字节的标记，按载荷的对齐补齐
                const size = std.mem.alignForward(u64, l.size + 1, l.alignment);
                break :blk .{ .size = size, .alignment = l.alignment, .bits = size * 8 };
            },
        },
        .array_type => |a| blk: {
            const l = typeLayout(ip, a.child) orelse break :blk null;
            const size = std.math.mul(u64, l.size, a.len + @intFromBool(a.sentinel != null)) catch break :blk null;
            break :blk .{ .size = size, .alignment = l.alignment, .bits = size * 8 };
        },
        else => null,
    };
}

fn intLayout(bits: u16) ?Layout {
    if (bits == 0) return .{ .size = 0, .alignment = 1, .bits = 0 };
    if (bits > 128) return null;
    const bytes: u64 = (bits + 7) / 8;
    // 不超过 8 字节时对齐为不小于字节数的 2 的幂，更宽的为 16
    const alignment: u64 = if (bytes <= 1) 1 else if (bytes <= 2) 2 else if (bytes <= 4) 4 else if (bytes <= 8) 8 else 16;
    return .{ .size = std.mem.alignForward(u64, bytes, alignment), .alignment = alignment, .bits = bits };
}

// ── 类型分类 ─────────────────────────────────────────────────────────

pub fn isTypeKey(k: InternPool.Key) bool {
    return switch (k) {
        .simple_type, .int_type, .ptr_type, .array_type, .optional_type, .error_union_type, .error_set_type, .fn_type, .container_type, .opaque_param => true,
        .tuple_type, .vector_type, .anon_struct_type, .reified_type, .union_tag_type, .inferred_error_set => true,
        else => false,
    };
}

/// 枚举类型（源码中的 enum、构造的 enum、union(enum) 的标签枚举）
pub fn isEnumType(ip: *InternPool, t: Index) bool {
    return switch (ip.key(t)) {
        .container_type => |c| c.kind == .@"enum",
        .reified_type => |r| r.kind == .@"enum",
        .union_tag_type => true,
        else => false,
    };
}

/// 只能在 comptime 存在的类型：这类参数即使不写 `comptime` 也是 comptime 参数
pub fn isComptimeOnly(ip: *InternPool, t: Index) bool {
    return switch (ip.key(t)) {
        .simple_type => |s| switch (s) {
            .type, .comptime_int, .comptime_float, .enum_literal, .null, .undefined => true,
            else => false,
        },
        .fn_type => true,
        .ptr_type => |p| isComptimeOnly(ip, p.child),
        .array_type => |a| isComptimeOnly(ip, a.child),
        .optional_type => |c| isComptimeOnly(ip, c),
        .error_union_type => |e| isComptimeOnly(ip, e.payload),
        .tuple_type => |types| anyComptimeOnly(ip, types),
        .anon_struct_type => |a| anyComptimeOnly(ip, a.types),
        .reified_type => |r| r.kind != .@"enum" and anyComptimeOnly(ip, r.types),
        else => false,
    };
}

fn anyComptimeOnly(ip: *InternPool, types: []const Index) bool {
    for (types) |t| if (isComptimeOnly(ip, t)) return true;
    return false;
}

// ── 相等 ─────────────────────────────────────────────────────────────

/// 不含未知部分：同一个 Index 一定表示同一个值。抽象参数可以与自身比较（`T == T`），
/// 未知的 comptime 实参（`List(_)`）不行：不同调用处的 `_` 可能是不同的值
pub fn isPrecise(ip: *InternPool, v: Index) bool {
    if (v == .unknown) return false;
    return switch (ip.key(v)) {
        .unknown => false,
        .ptr_type => |p| isPrecise(ip, p.child) and (p.sentinel == null or isPrecise(ip, p.sentinel.?)),
        .array_type => |a| isPrecise(ip, a.child) and (a.sentinel == null or isPrecise(ip, a.sentinel.?)),
        .optional_type => |c| isPrecise(ip, c),
        .error_union_type => |e| isPrecise(ip, e.err) and isPrecise(ip, e.payload),
        .fn_type => |f| blk: {
            for (f.params) |p| if (!isPrecise(ip, p)) break :blk false;
            break :blk isPrecise(ip, f.ret);
        },
        .container_type => |c| c.inst == null or isPrecise(ip, c.inst.?),
        .tuple_type => |types| allPrecise(ip, types),
        .vector_type => |vec| isPrecise(ip, vec.child),
        .anon_struct_type => |a| allPrecise(ip, a.types),
        .reified_type => |r| allPrecise(ip, r.types) and (r.tag == null or isPrecise(ip, r.tag.?)) and (r.inst == null or isPrecise(ip, r.inst.?)),
        .union_tag_type => |u| isPrecise(ip, u),
        .aggregate => |agg| allPrecise(ip, agg.elems),
        .union_value => |u| isPrecise(ip, u.payload),
        .ptr_value => |p| isPrecise(ip, p.pointee),
        .fn_value => |f| f.inst == null or isPrecise(ip, f.inst.?),
        .enum_tag => |t| isPrecise(ip, t.ty),
        .instance => |i| blk: {
            for (i.args) |a| if (!isPrecise(ip, a)) break :blk false;
            break :blk i.parent == null or isPrecise(ip, i.parent.?);
        },
        else => true,
    };
}

fn allPrecise(ip: *InternPool, items: []const Index) bool {
    for (items) |x| if (!isPrecise(ip, x)) return false;
    return true;
}

/// 不含抽象参数与未知部分的类型：可以脱离定义它的实例使用（如作为调用方的期望类型）
pub fn isConcrete(ip: *InternPool, t: Index) bool {
    if (t == .unknown) return false;
    return switch (ip.key(t)) {
        .unknown, .opaque_param => false,
        .ptr_type => |p| isConcrete(ip, p.child),
        .array_type => |a| isConcrete(ip, a.child),
        .optional_type => |c| isConcrete(ip, c),
        .error_union_type => |e| isConcrete(ip, e.err) and isConcrete(ip, e.payload),
        .fn_type => |f| blk: {
            for (f.params) |p| if (!isConcrete(ip, p)) break :blk false;
            break :blk isConcrete(ip, f.ret);
        },
        .container_type => |c| c.inst == null or isConcrete(ip, c.inst.?),
        .tuple_type => |types| allConcrete(ip, types),
        .vector_type => |v| isConcrete(ip, v.child),
        .anon_struct_type => |a| allConcrete(ip, a.types),
        .reified_type => |r| allConcrete(ip, r.types) and (r.inst == null or isConcrete(ip, r.inst.?)),
        .union_tag_type => |u| isConcrete(ip, u),
        .instance => |i| blk: {
            for (i.args) |a| if (a != .runtime and !isConcrete(ip, a)) break :blk false;
            break :blk i.parent == null or isConcrete(ip, i.parent.?);
        },
        else => true,
    };
}

fn allConcrete(ip: *InternPool, items: []const Index) bool {
    for (items) |x| if (!isConcrete(ip, x)) return false;
    return true;
}

/// 三值合取：有 false 为 false，否则有未知为 null
fn all(results: []const ?bool) ?bool {
    var unknown = false;
    for (results) |r| {
        const v = r orelse {
            unknown = true;
            continue;
        };
        if (!v) return false;
    }
    return if (unknown) null else true;
}

/// 两个类型是否相同
pub fn eqlTypes(ip: *InternPool, a: Index, b: Index) ?bool {
    if (a == b) return if (isPrecise(ip, a)) true else null;
    if (a == .unknown or b == .unknown) return null;
    const ka = ip.key(a);
    const kb = ip.key(b);
    if (ka == .opaque_param or kb == .opaque_param or ka == .unknown or kb == .unknown) return null;
    if (std.meta.activeTag(ka) != std.meta.activeTag(kb)) return false;
    return switch (ka) {
        .ptr_type => |p| blk: {
            const q = kb.ptr_type;
            if (p.size != q.size or p.is_const != q.is_const) break :blk false;
            break :blk all(&.{ eqlTypes(ip, p.child, q.child), eqlSentinel(ip, p.sentinel, q.sentinel) });
        },
        .array_type => |x| blk: {
            const y = kb.array_type;
            if (x.len != y.len) break :blk false;
            break :blk all(&.{ eqlTypes(ip, x.child, y.child), eqlSentinel(ip, x.sentinel, y.sentinel) });
        },
        .optional_type => |c| eqlTypes(ip, c, kb.optional_type),
        .error_union_type => |e| all(&.{ eqlTypes(ip, e.err, kb.error_union_type.err), eqlTypes(ip, e.payload, kb.error_union_type.payload) }),
        .fn_type => |f| blk: {
            const g = kb.fn_type;
            if (f.params.len != g.params.len or f.varargs != g.varargs) break :blk false;
            var unknown = false;
            for (f.params, g.params) |x, y| {
                const r = eqlTypes(ip, x, y) orelse {
                    unknown = true;
                    continue;
                };
                if (!r) break :blk false;
            }
            const r = eqlTypes(ip, f.ret, g.ret) orelse break :blk null;
            break :blk if (!r) false else if (unknown) null else true;
        },
        // 不同位置定义的容器一定不同；同一位置、不同实例的容器是否相同取决于它捕获的值
        .container_type => |c| if (c.file != kb.container_type.file or c.ast_id != kb.container_type.ast_id) false else null,
        .tuple_type => |x| eqlTypeLists(ip, x, kb.tuple_type),
        .vector_type => |v| if (v.len != kb.vector_type.len) false else eqlTypes(ip, v.child, kb.vector_type.child),
        .anon_struct_type => |x| blk: {
            const y = kb.anon_struct_type;
            if (!eqlNames(x.names, y.names)) break :blk false;
            break :blk eqlTypeLists(ip, x.types, y.types);
        },
        // 同一位置以相同内容构造的类型相同（构造时的实例只影响显示）
        .reified_type => |x| blk: {
            const y = kb.reified_type;
            if (x.file != y.file or x.owner != y.owner or x.expr != y.expr or x.kind != y.kind or x.layout != y.layout) break :blk false;
            if (x.nonexhaustive != y.nonexhaustive or !eqlNames(x.names, y.names) or !std.mem.eql(i128, x.values, y.values)) break :blk false;
            const tag: ?bool = if (x.tag == null or y.tag == null) x.tag == null and y.tag == null else eqlTypes(ip, x.tag.?, y.tag.?);
            break :blk all(&.{ tag, eqlTypeLists(ip, x.types, y.types) });
        },
        .union_tag_type => |u| eqlTypes(ip, u, kb.union_tag_type),
        // 不同函数推导的错误集可能恰好相同
        .inferred_error_set => null,
        // 驻留保证了简单类型、整数类型与错误集相同即同一个 Index
        else => false,
    };
}

fn eqlTypeLists(ip: *InternPool, a: []const Index, b: []const Index) ?bool {
    if (a.len != b.len) return false;
    var unknown = false;
    for (a, b) |x, y| {
        const r = eqlTypes(ip, x, y) orelse {
            unknown = true;
            continue;
        };
        if (!r) return false;
    }
    return if (unknown) null else true;
}

fn eqlNames(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn eqlSentinel(ip: *InternPool, a: ?Index, b: ?Index) ?bool {
    if (a == null or b == null) return a == null and b == null;
    return eqlValues(ip, a.?, b.?);
}

/// 两个 comptime 值是否相等（`==` 的语义；类型按 `eqlTypes`）
pub fn eqlValues(ip: *InternPool, a: Index, b: Index) ?bool {
    if (a == .unknown or b == .unknown) return null;
    const ka = ip.key(a);
    const kb = ip.key(b);
    if (isTypeKey(ka) or isTypeKey(kb)) {
        if (!isTypeKey(ka) or !isTypeKey(kb)) return null;
        return eqlTypes(ip, a, b);
    }
    // 非 null 的 optional 值即其载荷：与 null 比较时只要另一侧是已知的非 null 值即不等
    if (a == .null_value or b == .null_value) {
        if (a == b) return true;
        const other = if (a == .null_value) kb else ka;
        return switch (other) {
            .simple_value => |s| if (s == .undefined) null else false,
            .unknown, .runtime => null,
            else => false,
        };
    }
    return switch (ka) {
        .int_value => |x| switch (kb) {
            .int_value => |y| x.value == y.value,
            .float_value => |y| @as(f128, @floatFromInt(x.value)) == @as(f128, @bitCast(y.bits)),
            else => null,
        },
        .float_value => |x| switch (kb) {
            .float_value, .int_value => @as(f128, @bitCast(x.bits)) == floatOf(ip, b).?,
            else => null,
        },
        .simple_value => |x| switch (kb) {
            .simple_value => |y| if (x == .undefined or y == .undefined) null else x == y,
            else => null,
        },
        .enum_literal => |n| switch (kb) {
            .enum_literal => |m| std.mem.eql(u8, n, m),
            .enum_tag => |t| std.mem.eql(u8, n, t.name),
            // 带标签的 union 与标签比较
            .union_value => |u| std.mem.eql(u8, n, u.tag),
            else => null,
        },
        .enum_tag => |t| switch (kb) {
            .enum_literal => |m| std.mem.eql(u8, t.name, m),
            .enum_tag => |u| if (eqlTypes(ip, t.ty, u.ty) == true) std.mem.eql(u8, t.name, u.name) else null,
            .union_value => |u| std.mem.eql(u8, t.name, u.tag),
            else => null,
        },
        .union_value => |u| switch (kb) {
            .enum_literal => |m| std.mem.eql(u8, u.tag, m),
            .enum_tag => |t| std.mem.eql(u8, u.tag, t.name),
            .union_value => |w| if (!std.mem.eql(u8, u.tag, w.tag)) false else eqlValues(ip, u.payload, w.payload),
            else => null,
        },
        .aggregate, .bytes => eqlAggregates(ip, a, b),
        .error_value => |n| switch (kb) {
            .error_value => |m| std.mem.eql(u8, n, m),
            else => null,
        },
        .fn_value => |f| switch (kb) {
            .fn_value => |g| if (f.file != g.file or f.decl != g.decl) false else if (a == b and isPrecise(ip, a)) true else null,
            else => null,
        },
        else => null,
    };
}

/// 聚合值的驻留：元素都是 u8 整数时以字符串（`bytes`）表示，保证同一个值只有一种表示
pub fn aggregate(ip: *InternPool, gpa: Allocator, ty: Index, elems: []const Index) Allocator.Error!Index {
    if (elems.len > 0) bytes: {
        const out = try gpa.alloc(u8, elems.len);
        defer gpa.free(out);
        for (elems, out) |e, *o| switch (ip.key(e)) {
            .int_value => |i| {
                if (i.ty != .u8_type) break :bytes;
                o.* = @intCast(i.value);
            },
            else => break :bytes,
        };
        return ip.get(.{ .bytes = .{ .ty = ty, .bytes = out } });
    }
    return ip.get(.{ .aggregate = .{ .ty = ty, .elems = elems } });
}

fn eqlAggregates(ip: *InternPool, a: Index, b: Index) ?bool {
    const ka = ip.key(a);
    const kb = ip.key(b);
    if (ka == .bytes and kb == .bytes) return std.mem.eql(u8, ka.bytes.bytes, kb.bytes.bytes);
    const xs = switch (ka) {
        .aggregate => |x| x.elems,
        else => return null,
    };
    const ys = switch (kb) {
        .aggregate => |y| y.elems,
        else => return null,
    };
    if (xs.len != ys.len) return false;
    var unknown = false;
    for (xs, ys) |x, y| {
        const r = eqlValues(ip, x, y) orelse {
            unknown = true;
            continue;
        };
        if (!r) return false;
    }
    return if (unknown) null else true;
}

// ── 转换 ─────────────────────────────────────────────────────────────

/// comptime 值转换为类型 `to` 的值（结果类型语义）：整数字面量取目标整数类型（越界为 null），
/// enum literal 取目标枚举的成员，optional 的目标先转换为载荷类型（非 null 的 optional 值即载荷值）。
/// 不需要或无法转换时原样返回
pub fn coerceValue(ip: *InternPool, v: Index, to: Index) Allocator.Error!?Index {
    if (to == .unknown or v == .unknown or v == .undefined_value) return v;
    switch (ip.key(to)) {
        .optional_type => |child| return if (v == .null_value) v else coerceValue(ip, v, child),
        else => if (isEnumType(ip, to)) switch (ip.key(v)) {
            .enum_literal => |name| return try ip.get(.{ .enum_tag = .{ .ty = to, .name = name } }),
            else => {},
        },
    }
    if (ip.isFloat(to)) {
        const x = floatOf(ip, v) orelse return null;
        return floatValue(ip, to, x);
    }
    // 整数值的浮点（comptime_float 的整数值可以转换为整数类型）
    if (ip.isInt(to)) switch (ip.key(v)) {
        .float_value => |f| {
            const x: f128 = @bitCast(f.bits);
            if (@trunc(x) != x or @abs(x) > 1e38) return null;
            const i: i128 = @intFromFloat(x);
            if (!intFits(ip, to, i)) return null;
            return try ip.get(.{ .int_value = .{ .ty = to, .value = i } });
        },
        else => {},
    };
    if (ip.isInt(to)) switch (ip.key(v)) {
        .int_value => |i| {
            if (i.ty == to) return v;
            if (!intFits(ip, to, i.value)) return null;
            return try ip.get(.{ .int_value = .{ .ty = to, .value = i.value } });
        },
        else => {},
    };
    return v;
}

const testing = std.testing;

test "integer folding follows the type's width" {
    var ip: InternPool = try .init(testing.allocator, testing.io);
    defer ip.deinit();
    const u8_t: Index = .u8_type;
    const i8_t = try ip.intType(.signed, 8);
    try testing.expectEqual(@as(?i128, 0), binaryInt(&ip, .plus_percent, u8_t, 255, 1));
    try testing.expectEqual(@as(?i128, 255), binaryInt(&ip, .minus_percent, u8_t, 0, 1));
    try testing.expectEqual(@as(?i128, 255), binaryInt(&ip, .plus_pipe, u8_t, 250, 10));
    try testing.expectEqual(@as(?i128, null), binaryInt(&ip, .plus, u8_t, 200, 100));
    try testing.expectEqual(@as(?i128, 0), binaryInt(&ip, .asterisk_percent, i8_t, -128, 2));
    try testing.expectEqual(@as(?i128, 2), binaryInt(&ip, .angle_bracket_angle_bracket_left, u8_t, 0x81, 1));
    try testing.expectEqual(@as(?i128, null), binaryInt(&ip, .angle_bracket_angle_bracket_left, u8_t, 1, 8));
    try testing.expectEqual(@as(?i128, 1 << 100), binaryInt(&ip, .angle_bracket_angle_bracket_left, .comptime_int_type, 1, 100));
    try testing.expectEqual(@as(?i128, null), binaryInt(&ip, .slash, i8_t, -4, 2));
    try testing.expectEqual(@as(?i128, null), negate(&ip, i8_t, -128, false));
    try testing.expectEqual(@as(?i128, -128), negate(&ip, i8_t, -128, true));
    try testing.expectEqual(@as(?i128, 0xfe), bitNot(&ip, u8_t, 1));
    try testing.expectEqual(@as(?i128, null), bitNot(&ip, .comptime_int_type, 1));
}

test "equality is unknown when identity depends on unknown parts" {
    var ip: InternPool = try .init(testing.allocator, testing.io);
    defer ip.deinit();
    const t = try ip.get(.{ .opaque_param = .{ .file = @fromBackingInt(0), .owner = @fromBackingInt(0), .binding = 0, .name = "T" } });
    const arr_t = try ip.get(.{ .array_type = .{ .len = 2, .child = t } });
    const arr_u8 = try ip.get(.{ .array_type = .{ .len = 2, .child = .u8_type } });
    try testing.expectEqual(@as(?bool, null), eqlTypes(&ip, arr_t, arr_u8));
    try testing.expectEqual(@as(?bool, true), eqlTypes(&ip, arr_t, arr_t));
    try testing.expectEqual(@as(?bool, false), eqlTypes(&ip, arr_u8, try ip.ptrTo(.u8_type, .slice, true)));
    const e = try ip.get(.{ .enum_literal = "a" });
    try testing.expectEqual(@as(?bool, true), eqlValues(&ip, e, e));
    try testing.expectEqual(@as(?bool, false), eqlValues(&ip, try ip.get(.{ .int_value = .{ .ty = .u8_type, .value = 3 } }), .null_value));
    try testing.expectEqual(@as(?bool, true), eqlValues(&ip, try ip.get(.{ .int_value = .{ .ty = .u8_type, .value = 3 } }), try ip.get(.{ .int_value = .{ .ty = .comptime_int_type, .value = 3 } })));
}
