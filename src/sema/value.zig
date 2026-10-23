//! comptime 值的语义（类型推导与 comptime 解释器共用）：按类型位宽的整数运算、值与类型的
//! 相等判断、值的类型转换、comptime-only 类型的判断。
//!
//! 相等判断返回 `?bool`：抽象参数、未知值，或身份取决于捕获值的泛型实例无法判断时为 null，
//! 调用方据此不选择任何分支，而不是给出可能错误的结果。
//!
//! 与目标相关的大小与位宽（usize、指针、整数的对齐、浮点与 C 类型）按目标的参数（`InternPool.Target`）
//! 计算；参数未知时（各模块的目标不一致）这些值为未知。

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("InternPool.zig");
const Index = InternPool.Index;
const SyntaxKind = @import("../syntax/kind.zig").SyntaxKind;

// ── 整数 ─────────────────────────────────────────────────────────────

pub const IntInfo = struct { signed: bool, bits: u16 };

/// 定宽整数类型的符号与位宽（usize 与 C 整数类型按目标）；comptime_int 与位宽或符号未知的为 null
pub fn intInfo(ip: *InternPool, t: Index) ?IntInfo {
    return switch (ip.key(t)) {
        .int_type => |i| .{ .signed = i.signedness == .signed, .bits = i.bits },
        .simple_type => |s| switch (s) {
            .usize => .{ .signed = false, .bits = ip.pointerBits() orelse return null },
            .isize => .{ .signed = true, .bits = ip.pointerBits() orelse return null },
            .c_char => .{ .signed = (ip.scalarAbi().c_char_signedness orelse return null) == .signed, .bits = (scalarAbiOf(ip, s) orelse return null).bits },
            .c_short, .c_int, .c_long, .c_longlong => .{ .signed = true, .bits = (scalarAbiOf(ip, s) orelse return null).bits },
            .c_ushort, .c_uint, .c_ulong, .c_ulonglong => .{ .signed = false, .bits = (scalarAbiOf(ip, s) orelse return null).bits },
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
    // 值以 i128 存储，位宽超过 128 的结果无法表示；先返回 null，避免移位量 @intCast 到 u8 溢出
    if (info.bits > 128) return null;
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

/// 整数参数的 `@min` / `@max` 的结果类型（与编译器的 `analyzeMinMax` 一致）：各参数的范围（值已知时
/// 为该值，否则为类型的范围）按 `@min` / `@max` 合并，取容纳结果范围的最小整数类型；参数都是
/// comptime_int 时为 comptime_int。有参数不是整数或范围求不出时为 null
pub fn minMaxIntType(ip: *InternPool, is_min: bool, operands: []const InternPool.TypedValue) Allocator.Error!?Index {
    var result: Bounds = undefined;
    var all_comptime = true;
    for (operands, 0..) |o, i| {
        const r: Bounds = if (intOf(ip, o.val)) |x| .{ .min = x, .max = x } else if (o.ty == .comptime_int_type)
            return null
        else
            bounds(intInfo(ip, o.ty) orelse return null) orelse return null;
        if (o.ty != .comptime_int_type) all_comptime = false;
        result = if (i == 0) r else if (is_min)
            .{ .min = @min(result.min, r.min), .max = @min(result.max, r.max) }
        else
            .{ .min = @max(result.min, r.min), .max = @max(result.max, r.max) };
    }
    if (all_comptime) return .comptime_int_type;
    // 与编译器的 `intFittingRange` 相同
    const signed = result.min < 0;
    return try ip.intType(if (signed) .signed else .unsigned, @max(bitsFor(result.min, signed), bitsFor(result.max, signed)));
}

/// 容纳 `x` 的位宽，`signed` 时含符号位（`x` 为负时 `signed` 为 true）
fn bitsFor(x: Wide, signed: bool) u16 {
    const magnitude: u256 = @intCast(if (x >= 0) x else -(x + 1));
    return @as(u16, @intCast(256 - @clz(magnitude))) + @intFromBool(signed);
}

/// 有浮点参数的 `@min` / `@max` 的结果类型：位宽最大的浮点类型，只有 comptime 数值时为 comptime_float
pub fn minMaxFloatType(ip: *InternPool, types: []const Index) ?Index {
    var best: ?Index = null;
    var best_bits: u16 = 0;
    for (types) |t| {
        if (t == .comptime_float_type or ip.isInt(t)) continue;
        if (!ip.isFloat(t)) return null;
        const bits = floatBits(ip, t) orelse return null;
        if (bits > best_bits) {
            best = t;
            best_bits = @intCast(bits);
        }
    }
    return best orelse .comptime_float_type;
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

/// 浮点类型对应的 Zig 类型（comptime_float 按 f128 计算，与编译器一致）
fn FloatOf(comptime k: InternPool.Simple) type {
    return switch (k) {
        .f16 => f16,
        .f32 => f32,
        .f64 => f64,
        .f80 => f80,
        else => f128,
    };
}

/// 浮点类型的位宽（与布局无关）；c_longdouble 按目标，目标未知时为 null
pub fn floatBits(ip: *InternPool, t: Index) ?u16 {
    return switch (ip.key(t)) {
        .simple_type => |s| switch (s) {
            .f16 => 16,
            .f32 => 32,
            .f64 => 64,
            .f80 => 80,
            .f128 => 128,
            .c_longdouble => (scalarAbiOf(ip, s) orelse return null).bits,
            else => null,
        },
        else => null,
    };
}

fn floatKind(ip: *InternPool, ty: Index) ?InternPool.Simple {
    return switch (ip.key(ty)) {
        .simple_type => |s| switch (s) {
            .f16, .f32, .f64, .f80, .f128, .comptime_float => s,
            else => null,
        },
        else => null,
    };
}

/// 浮点的一元内置函数
pub const FloatFn = enum { sqrt, sin, cos, tan, exp, exp2, log, log2, log10, abs, floor, ceil, trunc, round };

/// 浮点一元内置函数（`@sqrt` 等）的值，按类型的精度计算；不是浮点类型时为 null
pub fn floatUnary(ip: *InternPool, f: FloatFn, ty: Index, x: f128) Allocator.Error!?Index {
    const r: f128 = switch (floatKind(ip, ty) orelse return null) {
        inline .f16, .f32, .f64, .f80, .f128, .comptime_float => |k| unary(FloatOf(k), f, @floatCast(x)),
        else => unreachable,
    };
    return floatValue(ip, ty, r);
}

fn unary(comptime T: type, f: FloatFn, x: T) T {
    return switch (f) {
        .sqrt => @sqrt(x),
        .sin => @sin(x),
        .cos => @cos(x),
        .tan => @tan(x),
        .exp => @exp(x),
        .exp2 => @exp2(x),
        .log => @log(x),
        .log2 => @log2(x),
        .log10 => @log10(x),
        .abs => @abs(x),
        .floor => @floor(x),
        .ceil => @ceil(x),
        .trunc => @trunc(x),
        .round => @round(x),
    };
}

/// 浮点的二元内置函数
pub const FloatBinFn = enum { min, max, mod, rem, div_trunc, div_floor, div_ceil, div_exact };

/// 浮点二元内置函数（`@mod`、`@min` 等）的值，按类型的精度计算；除数为零、不能整除等求不出时为 null
pub fn floatBinary(ip: *InternPool, f: FloatBinFn, ty: Index, a: f128, b: f128) Allocator.Error!?Index {
    const r: f128 = switch (floatKind(ip, ty) orelse return null) {
        inline .f16, .f32, .f64, .f80, .f128, .comptime_float => |k| binary(FloatOf(k), f, @floatCast(a), @floatCast(b)) orelse return null,
        else => unreachable,
    };
    return floatValue(ip, ty, r);
}

fn binary(comptime T: type, f: FloatBinFn, a: T, b: T) ?T {
    switch (f) {
        .min => return @min(a, b),
        .max => return @max(a, b),
        else => {},
    }
    if (b == 0) return null;
    // 编译器在 comptime 调用自身的同名内置函数，发行版的编译器经 LLVM 编译，展开为以下形式。按同样的
    // 展开式计算，结果不随 zig-analyzer 自身的编译后端变化。`@mod` 只按被除数的符号调整，除数为负时
    // 与数学定义不同（f64 的 7 mod -3 得 1 而不是 -2）
    return switch (f) {
        .mod => if (a < 0) @rem(@rem(a, b) + b, b) else @rem(a, b),
        .rem => @rem(a, b),
        .div_trunc => @trunc(a / b),
        .div_floor => @floor(a / b),
        .div_ceil => @ceil(a / b),
        .div_exact => if (@rem(a, b) != 0) null else a / b,
        .min, .max => unreachable,
    };
}

/// `@mulAdd(T, a, b, c)`：只舍入一次的 `a * b + c`
pub fn floatMulAdd(ip: *InternPool, ty: Index, a: f128, b: f128, c: f128) Allocator.Error!?Index {
    const r: f128 = switch (floatKind(ip, ty) orelse return null) {
        inline .f16, .f32, .f64, .f80, .f128, .comptime_float => |k| @mulAdd(FloatOf(k), @floatCast(a), @floatCast(b), @floatCast(c)),
        else => unreachable,
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

pub const Layout = struct {
    size: u64,
    alignment: u64,
    /// `@bitSizeOf`；没有位表示的类型（切片、非指针的 optional、error union、非 packed 的容器等）为 null
    bits: ?u64,
};

/// 错误码：按 u16 的整数布局
fn errorLayout(ip: *InternPool) ?Layout {
    return intLayout(ip, 16);
}

/// 类型的大小、对齐与位宽（`@sizeOf` / `@alignOf` / `@bitSizeOf`），按目标的规则（`InternPool.Target`）。
/// 只处理不含容器的类型（容器由 `eval.typeLayout` 处理），其余为 null
pub fn typeLayout(ip: *InternPool, t: Index) ?Layout {
    const pointer_bits: u64 = ip.pointerBits() orelse 0;
    const ptr_bytes: u64 = pointer_bits / 8;
    return switch (ip.key(t)) {
        .int_type => |i| intLayout(ip, i.bits),
        .simple_type => |s| switch (s) {
            .bool => .{ .size = 1, .alignment = 1, .bits = 1 },
            .void => .{ .size = 0, .alignment = 1, .bits = 0 },
            .usize, .isize => if (pointer_bits == 0) null else intLayout(ip, @intCast(pointer_bits)),
            // 表示为 u16
            .f16 => intLayout(ip, 16),
            .anyerror => errorLayout(ip),
            else => if (scalarAbiOf(ip, s)) |l| .{ .size = l.size, .alignment = l.alignment, .bits = l.bits } else null,
        },
        .error_set_type, .inferred_error_set => errorLayout(ip),
        .ptr_type => |p| if (pointer_bits == 0)
            null
        else if (p.size == .slice)
            .{ .size = 2 * ptr_bytes, .alignment = ptr_bytes, .bits = null }
        else
            .{ .size = ptr_bytes, .alignment = ptr_bytes, .bits = pointer_bits },
        .optional_type => |c| optionalLayout(ip, c, typeLayout(ip, c) orelse return null),
        .array_type => |a| arrayLayout(typeLayout(ip, a.child) orelse return null, a, hasBitRepr(ip, a.child)),
        .error_union_type => |eu| errorUnionLayout(ip, typeLayout(ip, eu.payload) orelse return null),
        .vector_type => |v| vectorLayout(ip, v.len, v.child),
        else => null,
    };
}

/// C 类型与 f32、f64、f80、f128 的布局（`InternPool.ScalarAbi`）；其余类型与目标未定义时为 null
fn scalarAbiOf(ip: *InternPool, s: InternPool.Simple) ?InternPool.ScalarAbi.Scalar {
    const k: InternPool.ScalarAbi.Type = switch (s) {
        .c_char => .c_char,
        .c_short, .c_ushort => .c_short,
        .c_int, .c_uint => .c_int,
        .c_long, .c_ulong => .c_long,
        .c_longlong, .c_ulonglong => .c_longlong,
        .c_longdouble => .c_longdouble,
        .f32 => .f32,
        .f64 => .f64,
        .f80 => .f80,
        .f128 => .f128,
        else => return null,
    };
    return ip.scalarAbi().types.get(k);
}

/// `@Vector(len, T)`（`Type.abiAlignment` / `abiSize` 的 vector 分支）：规则取决于编译后端与 CPU 特性
/// （`InternPool.VectorAbi`）。f80、f128 元素是否走软浮点取决于目标的 long double，为 null
fn vectorLayout(ip: *InternPool, len: u32, child: Index) ?Layout {
    const abi = ip.vectorAbi();
    if (abi == .unknown) return null;
    switch (ip.key(child)) {
        .simple_type => |s| switch (s) {
            .f80, .f128, .c_longdouble => return null,
            else => {},
        },
        else => {},
    }
    const elem = typeLayout(ip, child) orelse return null;
    const elem_bits = elem.bits orelse return null;
    const bits = std.math.mul(u64, elem_bits, len) catch return null;
    if (len == 0) return .{ .size = 0, .alignment = 1, .bits = 0 };
    const alignment: u64, const bytes: u64 = switch (abi) {
        .unknown => unreachable,
        .llvm, .llvm_aarch64 => blk: {
            const bytes = (bits + 7) / 8;
            if (elem_bits == 0) break :blk .{ 1, bytes };
            // aarch64：不超过栈对齐
            const capped = if (abi == .llvm_aarch64) @min(bytes, 16) else bytes;
            break :blk .{ std.math.ceilPowerOfTwo(u64, capped) catch return null, bytes };
        },
        .x86_64, .x86_64_avx, .x86_64_avx512 => blk: {
            const avx = abi != .x86_64;
            const avx512 = abi == .x86_64_avx512;
            if (child == .bool_type) {
                const bytes = (@as(u64, len) + 7) / 8;
                const alignment: u64 = if (len > 256 and avx512) 64 else if (len > 128 and avx) 32 else if (len > 64) 16 else std.math.ceilPowerOfTwo(u64, bytes) catch return null;
                break :blk .{ alignment, bytes };
            }
            const bytes = std.math.mul(u64, elem.size, len) catch return null;
            if (elem.size == 0) break :blk .{ 1, bytes };
            break :blk .{ if (bytes > 32 and avx512) 64 else if (bytes > 16 and avx) 32 else 16, bytes };
        },
        .elem => .{ elem.alignment, std.math.mul(u64, elem.size, len) catch return null },
    };
    return .{ .size = alignForward(bytes, alignment) orelse return null, .alignment = alignment, .bits = if (hasBitRepr(ip, child)) bits else null };
}

/// 向上对齐到 `alignment`（2 的幂）；溢出时为 null，源码中的超大类型不应使宿主崩溃
pub fn alignForward(x: u64, alignment: u64) ?u64 {
    const sum = std.math.add(u64, x, alignment - 1) catch return null;
    return sum & ~(alignment - 1);
}

/// 字节偏移换算为位偏移；溢出时为 null
pub fn bitsOf(bytes: u64) ?u64 {
    return std.math.mul(u64, bytes, 8) catch null;
}

/// 定宽整数类型（含 packed 容器的 backing 整数、枚举的标签）的布局（`std.zig.target.intAlignment` /
/// `intByteSize`）：对齐为不小于字节数的 2 的幂，且不超过目标的最大整数对齐。最大对齐在各模块中不一致、
/// 且影响该位宽的对齐时为 null
pub fn intLayout(ip: *InternPool, bits: u16) ?Layout {
    if (bits == 0) return .{ .size = 0, .alignment = 1, .bits = 0 };
    if (bits > 128) return null;
    const bytes: u64 = (bits + 7) / 8;
    const natural = std.math.ceilPowerOfTwoAssert(u64, bytes);
    const max_align = ip.scalarAbi().max_int_align;
    const alignment = @min(natural, max_align.min);
    if (@min(natural, max_align.max) != alignment) return null;
    return .{ .size = std.mem.alignForward(u64, bytes, alignment), .alignment = alignment, .bits = bits };
}

/// `?T`：非 C 指针（含切片）与错误集以零值表示 null，与载荷同大小；其余在载荷之后加一个标记，
/// 按载荷的对齐补齐。只有单项与多项指针的 optional 有位表示
pub fn optionalLayout(ip: *InternPool, child: Index, payload: Layout) ?Layout {
    switch (ip.key(child)) {
        .ptr_type => |p| if (p.size != .c) return .{ .size = payload.size, .alignment = payload.alignment, .bits = if (p.size == .slice) null else payload.bits },
        .error_set_type, .inferred_error_set => return .{ .size = payload.size, .alignment = payload.alignment, .bits = null },
        .simple_type => |s| if (s == .anyerror) return .{ .size = payload.size, .alignment = payload.alignment, .bits = null },
        else => {},
    }
    return .{ .size = std.math.add(u64, payload.size, payload.alignment) catch return null, .alignment = payload.alignment, .bits = null };
}

/// 数组（长度含哨兵）。`elem_bit_repr`：元素有位表示时数组才有位宽（错误集与未指定标签类型的枚举
/// 虽可求 `@bitSizeOf`，却没有位表示）
pub fn arrayLayout(elem: Layout, a: @FieldType(InternPool.Key, "array_type"), elem_bit_repr: bool) ?Layout {
    const n = std.math.add(u64, a.len, @intFromBool(a.sentinel != null)) catch return null;
    const size = std.math.mul(u64, elem.size, n) catch return null;
    const bits: ?u64 = if (elem_bit_repr) (if (elem.bits) |b| std.math.mul(u64, b, n) catch null else null) else null;
    return .{ .size = size, .alignment = elem.alignment, .bits = bits };
}

/// `E!T`：错误码与载荷，按两者中较大的对齐补齐
pub fn errorUnionLayout(ip: *InternPool, payload: Layout) ?Layout {
    const err = errorLayout(ip) orelse return null;
    const alignment = @max(err.alignment, payload.alignment);
    const size = std.math.add(u64, err.size, payload.size) catch return null;
    return .{ .size = alignForward(size, alignment) orelse return null, .alignment = alignment, .bits = null };
}

/// 不含容器的类型是否有位表示（错误集没有）
fn hasBitRepr(ip: *InternPool, t: Index) bool {
    return switch (ip.key(t)) {
        .error_set_type, .inferred_error_set => false,
        .simple_type => |s| s != .anyerror,
        .array_type => |a| hasBitRepr(ip, a.child),
        else => true,
    };
}

// ── 类型分类 ─────────────────────────────────────────────────────────

pub fn isTypeKey(k: InternPool.Key) bool {
    return switch (k) {
        .simple_type, .int_type, .ptr_type, .array_type, .optional_type, .error_union_type, .error_set_type, .fn_type, .container_type, .opaque_param => true,
        .tuple_type, .vector_type, .anon_struct_type, .reified_type, .union_tag_type, .inferred_error_set, .abstract_array_type => true,
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
        // 函数指针是运行时的值；指向其他 comptime-only 类型的指针才是
        .ptr_type => |p| ip.key(p.child) != .fn_type and isComptimeOnly(ip, p.child),
        .array_type => |a| isComptimeOnly(ip, a.child),
        .abstract_array_type => |a| isComptimeOnly(ip, a.child),
        .optional_type => |c| isComptimeOnly(ip, c),
        .error_union_type => |e| isComptimeOnly(ip, e.payload),
        .tuple_type => |tt| anyRuntimeComptimeOnly(ip, tt.types, tt.values),
        .anon_struct_type => |a| anyRuntimeComptimeOnly(ip, a.types, a.values),
        .reified_type => |r| r.kind != .@"enum" and for (r.types, 0..) |field_ty, i| {
            const is_comptime = i < r.comptime_fields.len and r.comptime_fields[i];
            if (!is_comptime and isComptimeOnly(ip, field_ty)) break true;
        } else false,
        else => false,
    };
}

fn anyComptimeOnly(ip: *InternPool, types: []const Index) bool {
    for (types) |t| if (isComptimeOnly(ip, t)) return true;
    return false;
}

/// 元组与匿名结构体：comptime 字段（如 `comptime comptime_int = 5`）不使类型成为 comptime-only
fn anyRuntimeComptimeOnly(ip: *InternPool, types: []const Index, values: []const Index) bool {
    for (types, 0..) |t, i| {
        const v = InternPool.fieldValue(values, i);
        if ((v == .runtime or v == .unknown) and isComptimeOnly(ip, t)) return true;
    }
    return false;
}

// ── 相等 ─────────────────────────────────────────────────────────────

/// 不含未知部分：同一个 Index 一定表示同一个值。抽象参数可以与自身比较（`T == T`），
/// 未知的 comptime 实参（`List(_)`）不行：不同调用处的 `_` 可能是不同的值
pub fn isPrecise(ip: *InternPool, v: Index) bool {
    if (v == .unknown) return false;
    return switch (ip.key(v)) {
        .unknown, .abstract_array_type => false,
        .ptr_type => |p| isPrecise(ip, p.child) and (p.sentinel == null or isPrecise(ip, p.sentinel.?)),
        .array_type => |a| isPrecise(ip, a.child) and (a.sentinel == null or isPrecise(ip, a.sentinel.?)),
        .optional_type => |c| isPrecise(ip, c),
        .error_union_type => |e| isPrecise(ip, e.err) and isPrecise(ip, e.payload),
        .fn_type => |f| blk: {
            for (f.params) |p| if (!isPrecise(ip, p)) break :blk false;
            break :blk isPrecise(ip, f.ret);
        },
        .container_type => |c| c.inst == null or isPrecise(ip, c.inst.?),
        .tuple_type => |t| allPrecise(ip, t.types) and allPrecise(ip, t.values),
        .vector_type => |vec| isPrecise(ip, vec.child),
        .anon_struct_type => |a| allPrecise(ip, a.types) and allPrecise(ip, a.values),
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
        .unknown, .opaque_param, .abstract_array_type => false,
        .ptr_type => |p| isConcrete(ip, p.child),
        .array_type => |a| isConcrete(ip, a.child),
        .optional_type => |c| isConcrete(ip, c),
        .error_union_type => |e| isConcrete(ip, e.err) and isConcrete(ip, e.payload),
        .fn_type => |f| blk: {
            for (f.params) |p| if (!isConcrete(ip, p)) break :blk false;
            break :blk isConcrete(ip, f.ret);
        },
        .container_type => |c| c.inst == null or isConcrete(ip, c.inst.?),
        .tuple_type => |tt| allConcrete(ip, tt.types) and allConcrete(ip, tt.values),
        .vector_type => |v| isConcrete(ip, v.child),
        .anon_struct_type => |a| allConcrete(ip, a.types) and allConcrete(ip, a.values),
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
    // 抽象的类型（参数、长度未知的数组）与其他类型是否相同取决于实例
    if (ka == .opaque_param or kb == .opaque_param or ka == .unknown or kb == .unknown) return null;
    if (ka == .abstract_array_type or kb == .abstract_array_type) return null;
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
        .tuple_type => |x| all(&.{ eqlTypeLists(ip, x.types, kb.tuple_type.types), eqlFieldValues(ip, x.values, kb.tuple_type.values, x.types.len) }),
        .vector_type => |v| if (v.len != kb.vector_type.len) false else eqlTypes(ip, v.child, kb.vector_type.child),
        .anon_struct_type => |x| blk: {
            const y = kb.anon_struct_type;
            if (!eqlNames(x.names, y.names)) break :blk false;
            break :blk all(&.{ eqlTypeLists(ip, x.types, y.types), eqlFieldValues(ip, x.values, y.values, x.types.len) });
        },
        // 同一位置以相同内容构造的类型相同（构造时的实例只影响显示）
        .reified_type => |x| blk: {
            const y = kb.reified_type;
            if (x.file != y.file or x.owner != y.owner or x.expr != y.expr or x.kind != y.kind or x.layout != y.layout) break :blk false;
            if (x.nonexhaustive != y.nonexhaustive or !eqlNames(x.names, y.names) or !std.mem.eql(i128, x.values, y.values)) break :blk false;
            if (x.attrs_unknown != y.attrs_unknown or !std.mem.eql(u64, x.field_aligns, y.field_aligns) or !std.mem.eql(bool, x.comptime_fields, y.comptime_fields)) break :blk false;
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

/// 元组与匿名结构体各字段的 comptime 值：运行时字段与 comptime 字段不同，comptime 字段按值比较
fn eqlFieldValues(ip: *InternPool, a: []const Index, b: []const Index, n: usize) ?bool {
    var unknown = false;
    for (0..n) |i| {
        const x = InternPool.fieldValue(a, i);
        const y = InternPool.fieldValue(b, i);
        if (x == .unknown or y == .unknown) {
            unknown = true;
            continue;
        }
        if ((x == .runtime) != (y == .runtime)) return false;
        if (x == .runtime) continue;
        const eq = eqlValues(ip, x, y) orelse {
            unknown = true;
            continue;
        };
        if (!eq) return false;
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
    // 位宽超过 128 的类型不折叠：移位量超过 255 时不能 @intCast 到 u8
    const u1000_t = try ip.intType(.unsigned, 1000);
    try testing.expectEqual(@as(?i128, null), binaryInt(&ip, .angle_bracket_angle_bracket_right, u1000_t, 5, 300));
    try testing.expectEqual(@as(?i128, null), binaryInt(&ip, .slash, i8_t, -4, 2));
    try testing.expectEqual(@as(?i128, null), negate(&ip, i8_t, -128, false));
    try testing.expectEqual(@as(?i128, -128), negate(&ip, i8_t, -128, true));
    try testing.expectEqual(@as(?i128, 0xfe), bitNot(&ip, u8_t, 1));
    try testing.expectEqual(@as(?i128, null), bitNot(&ip, .comptime_int_type, 1));
}

test "reified types compare field attributes" {
    var ip: InternPool = try .init(testing.allocator, testing.io);
    defer ip.deinit();
    const base: InternPool.Reified = .{
        .kind = .@"struct",
        .file = @fromBackingInt(0),
        .owner = @fromBackingInt(0),
        .expr = 0,
        .names = &.{"x"},
        .types = &.{.u8_type},
    };
    const plain = try ip.get(.{ .reified_type = base });
    var aligned = base;
    aligned.field_aligns = &.{16};
    const aligned_t = try ip.get(.{ .reified_type = aligned });
    var comptime_field = base;
    comptime_field.comptime_fields = &.{true};
    const comptime_t = try ip.get(.{ .reified_type = comptime_field });
    var unknown = base;
    unknown.attrs_unknown = true;
    const unknown_t = try ip.get(.{ .reified_type = unknown });

    try testing.expectEqual(@as(?bool, true), eqlTypes(&ip, plain, plain));
    try testing.expectEqual(@as(?bool, false), eqlTypes(&ip, plain, aligned_t));
    try testing.expectEqual(@as(?bool, false), eqlTypes(&ip, plain, comptime_t));
    try testing.expectEqual(@as(?bool, false), eqlTypes(&ip, plain, unknown_t));
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
