//! Semantics of comptime values (shared by type inference and the comptime interpreter): integer
//! arithmetic at the bit width of the type, equality of values and types, coercion of values to
//! types, and detection of comptime-only types.
//!
//! Equality returns `?bool`: it is null when it cannot be decided for abstract parameters, unknown
//! values, or generic instances whose identity depends on captured values, so the caller selects
//! no branch instead of giving a possibly wrong result.
//!
//! Target-dependent sizes and bit widths (usize, pointers, integer alignment, floats and C types)
//! are computed from the target parameters (`InternPool.Target`); when the parameters are unknown
//! (the targets of the modules disagree) these values are unknown.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("InternPool.zig");
const Index = InternPool.Index;
const SyntaxKind = @import("../syntax/kind.zig").SyntaxKind;

// ── Integers ─────────────────────────────────────────────────────────

pub const IntInfo = struct { signed: bool, bits: u16 };

/// Signedness and bit width of a fixed-width integer type (usize and C integer types per the
/// target); null for comptime_int and when the bit width or signedness is unknown
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

/// Result type of `@abs` (matches the compiler's `zirAbs` and `Type.toUnsigned`): signed integer
/// types map to their unsigned counterparts (`isize` to `usize`, `c_int` to `c_uint`, other
/// widths to `uN`), vectors element-wise; every other type is its own result. Null when the
/// signedness or bit width needed for the mapping is unknown.
pub fn absType(ip: *InternPool, t: Index) Allocator.Error!?Index {
    return switch (ip.key(t)) {
        .simple_type => |s| switch (s) {
            .isize => try ip.get(.{ .simple_type = .usize }),
            .c_short => try ip.get(.{ .simple_type = .c_ushort }),
            .c_int => try ip.get(.{ .simple_type = .c_uint }),
            .c_long => try ip.get(.{ .simple_type = .c_ulong }),
            .c_longlong => try ip.get(.{ .simple_type = .c_ulonglong }),
            .c_char => {
                const info = intInfo(ip, t) orelse return null;
                return if (info.signed) try ip.intType(.unsigned, info.bits) else t;
            },
            else => t,
        },
        .int_type => |i| if (i.signedness == .signed) try ip.intType(.unsigned, i.bits) else t,
        .vector_type => |v| {
            const child = try absType(ip, v.child) orelse return null;
            return if (child == v.child) t else try ip.get(.{ .vector_type = .{ .len = v.len, .child = child } });
        },
        else => t,
    };
}

/// Intermediate result of arithmetic: holds both the product of two i128 values and shift results
const Wide = i256;

const Bounds = struct { min: Wide, max: Wide };

/// Null when the bit width exceeds 128 (values are stored as i128; anything wider is not folded)
fn bounds(info: IntInfo) ?Bounds {
    if (info.bits > 128) return null;
    if (info.bits == 0) return .{ .min = 0, .max = 0 };
    if (info.signed) {
        const half = @as(Wide, 1) << @intCast(info.bits - 1);
        return .{ .min = -half, .max = half - 1 };
    }
    return .{ .min = 0, .max = (@as(Wide, 1) << @intCast(info.bits)) - 1 };
}

/// Truncates to the bit width of `info` in two's complement
fn truncate(info: IntInfo, v: Wide) Wide {
    if (info.bits == 0) return 0;
    const m = @as(Wide, 1) << @intCast(info.bits);
    var r = @mod(v, m);
    if (info.signed and r >= @divExact(m, 2)) r -= m;
    return r;
}

const Overflow = enum { check, wrap, saturate };

/// Fits an arithmetic result into type `ty` (comptime_int or a fixed-width integer). When it is
/// out of range: plain operations give null (the compiler reports an error), wrapping operations
/// truncate, and saturating operations clamp to the bound.
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

/// Result of a binary integer operation at comptime (`ty` is the result type); null when the
/// result is not determined or the compiler would report an error
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
        // Signed `/` and `%` require @divTrunc etc., so only nonnegative operands are folded
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

/// `<<`: bits shifted out of a fixed-width integer are discarded (the shift amount must be less
/// than the bit width); `<<|` saturates
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
    // Values are stored as i128, so results wider than 128 bits cannot be represented; return
    // null early so that the @intCast of the shift amount to u8 cannot overflow
    if (info.bits > 128) return null;
    if (y >= info.bits) return null;
    return fit(ip, ty, x >> @intCast(y), .check);
}

pub const OverflowOp = enum { add, sub, mul, shl };

/// Integer arithmetic with an overflow bit (`@addWithOverflow` etc.): the result wrapped to `ty`
/// and whether it overflowed. `ty` must be a fixed-width integer; the shift amount must be less
/// than the bit width (in the compiler the right operand has type `Log2Int(T)`); null when it
/// cannot be computed.
pub fn overflowInt(ip: *InternPool, op: OverflowOp, ty: Index, a: i128, b: i128) ?struct { i128, bool } {
    const info = intInfo(ip, ty) orelse return null;
    if (ty == .comptime_int_type or info.bits > 128) return null;
    const x: Wide = a;
    const y: Wide = b;
    const r: Wide = switch (op) {
        .add => x + y,
        .sub => x - y,
        .mul => x * y,
        .shl => if (y < 0 or y >= info.bits) return null else x << @intCast(y),
    };
    const wrapped = fit(ip, ty, r, .wrap) orelse return null;
    return .{ wrapped, fit(ip, ty, r, .check) == null };
}

/// `@shlExact` / `@shrExact`: null when the compiler reports an error, i.e. when a left shift
/// overflows or a right shift shifts out a 1 bit
pub fn exactShift(ip: *InternPool, left: bool, ty: Index, a: i128, b: i128) ?i128 {
    if (b < 0) return null;
    const x: Wide = a;
    if (ty == .comptime_int_type) {
        if (b > 127) return if (a == 0) 0 else null;
    } else {
        const info = intInfo(ip, ty) orelse return null;
        if (info.bits > 128 or b >= info.bits) return null;
    }
    const n: u8 = @intCast(b);
    if (left) return fit(ip, ty, x << n, .check);
    if (x & ((@as(Wide, 1) << n) - 1) != 0) return null;
    return fit(ip, ty, x >> n, .check);
}

/// `@byteSwap` (`bytes`) / `@bitReverse`: takes the two's complement representation at the bit
/// width of `ty`, then swaps the bytes or reverses the bits. The bit width for `@byteSwap` must
/// be a multiple of 8.
pub fn reverseBits(ip: *InternPool, bytes: bool, ty: Index, a: i128) ?i128 {
    if (ty == .comptime_int_type) return null;
    const info = intInfo(ip, ty) orelse return null;
    if (info.bits > 128 or (bytes and info.bits % 8 != 0)) return null;
    if (info.bits == 0) return 0;
    const mask: u128 = if (info.bits == 128) std.math.maxInt(u128) else (@as(u128, 1) << @intCast(info.bits)) - 1;
    const src: u128 = @as(u128, @bitCast(a)) & mask;
    var out: u128 = 0;
    if (bytes) {
        const n = info.bits / 8;
        for (0..n) |i| out |= ((src >> @intCast(8 * i)) & 0xff) << @intCast(8 * (n - 1 - i));
    } else {
        for (0..info.bits) |i| out |= ((src >> @intCast(i)) & 1) << @intCast(info.bits - 1 - i);
    }
    return std.math.cast(i128, truncate(info, out));
}

/// `-x` / `-%x`
pub fn negate(ip: *InternPool, ty: Index, a: i128, wrapping: bool) ?i128 {
    return fit(ip, ty, -@as(Wide, a), if (wrapping) .wrap else .check);
}

/// `~x`: defined only for fixed-width integers
pub fn bitNot(ip: *InternPool, ty: Index, a: i128) ?i128 {
    const info = intInfo(ip, ty) orelse return null;
    return fit(ip, ty, truncate(info, ~@as(Wide, a)), .check);
}

/// Type of a comptime value itself (for values interned without a type, such as the arguments of
/// a comptime call)
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

/// Peer type of two integer types: with comptime_int, the other side; with the same signedness,
/// the wider one; an unsigned type fits into a wider signed one; null for other combinations
/// (compile errors)
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

/// Whether the value is in the range of the integer type (always true for comptime_int)
pub fn intFits(ip: *InternPool, ty: Index, v: i128) bool {
    return fit(ip, ty, v, .check) != null;
}

/// Result type of `@min` / `@max` with integer operands (matches the compiler's `analyzeMinMax`):
/// the ranges of the operands (the value when it is known, otherwise the range of the type) are
/// combined by `@min` / `@max`, and the result is the smallest integer type that holds the
/// combined range; comptime_int when all operands are comptime_int. Vector operands (all of the
/// same length) give a vector of that type, the range of a known vector value spanning its
/// elements. Null when an operand is not an integer (or a vector of integers) or a range cannot
/// be computed.
pub fn minMaxIntType(ip: *InternPool, is_min: bool, operands: []const InternPool.TypedValue) Allocator.Error!?Index {
    const vector_len: ?u32 = switch (ip.key(operands[0].ty)) {
        .vector_type => |v| v.len,
        else => null,
    };
    var result: Bounds = undefined;
    var all_comptime = true;
    for (operands, 0..) |o, i| {
        const scalar = switch (ip.key(o.ty)) {
            .vector_type => |v| if (v.len == vector_len) v.child else return null,
            else => if (vector_len == null) o.ty else return null,
        };
        const r: Bounds = if (vector_len != null) (elemBounds(ip, o.val) orelse
            bounds(intInfo(ip, scalar) orelse return null) orelse return null) else if (intOf(ip, o.val)) |x| .{ .min = x, .max = x } else if (scalar == .comptime_int_type)
            return null
        else
            bounds(intInfo(ip, scalar) orelse return null) orelse return null;
        if (scalar != .comptime_int_type) all_comptime = false;
        result = if (i == 0) r else if (is_min)
            .{ .min = @min(result.min, r.min), .max = @min(result.max, r.max) }
        else
            .{ .min = @max(result.min, r.min), .max = @max(result.max, r.max) };
    }
    // Same as the compiler's `intFittingRange`
    const signed = result.min < 0;
    const scalar = if (all_comptime) .comptime_int_type else try ip.intType(if (signed) .signed else .unsigned, @max(bitsFor(result.min, signed), bitsFor(result.max, signed)));
    return if (vector_len) |len| try ip.get(.{ .vector_type = .{ .len = len, .child = scalar } }) else scalar;
}

/// Smallest and largest element of a known vector value of integers
fn elemBounds(ip: *InternPool, v: ?Index) ?Bounds {
    var r: Bounds = .{ .min = std.math.maxInt(Wide), .max = std.math.minInt(Wide) };
    const elems = switch (ip.key(v orelse return null)) {
        .aggregate => |a| a.elems,
        .bytes => |b| {
            if (b.bytes.len == 0) return null;
            for (b.bytes) |x| r = .{ .min = @min(r.min, x), .max = @max(r.max, x) };
            return r;
        },
        else => return null,
    };
    if (elems.len == 0) return null;
    for (elems) |e| {
        const x = intOf(ip, e) orelse return null;
        r = .{ .min = @min(r.min, x), .max = @max(r.max, x) };
    }
    return r;
}

/// Bit width needed to hold `x`, including the sign bit when `signed` (`signed` is true when `x`
/// is negative)
fn bitsFor(x: Wide, signed: bool) u16 {
    const magnitude: u256 = @intCast(if (x >= 0) x else -(x + 1));
    return @as(u16, @intCast(256 - @clz(magnitude))) + @intFromBool(signed);
}

/// Result type of `@min` / `@max` with float operands: the float type with the largest bit width,
/// or comptime_float when all operands are comptime numbers
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

// ── Floating point ───────────────────────────────────────────────────

pub fn floatOf(ip: *InternPool, v: ?Index) ?f128 {
    return switch (ip.key(v orelse return null)) {
        .float_value => |f| @bitCast(f.bits),
        .int_value => |i| @floatFromInt(i.value),
        else => null,
    };
}

/// Rounds to the precision of the float type; null when it is not a float type
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

/// A value of the float type `ty`
pub fn floatValue(ip: *InternPool, ty: Index, x: f128) Allocator.Error!?Index {
    const r = roundTo(ip, ty, x) orelse return null;
    return try ip.get(.{ .float_value = .{ .ty = ty, .bits = @bitCast(r) } });
}

/// Binary float operation (`ty` is the float type of the result); null when the result is not
/// determined
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

/// The Zig type corresponding to a float type (comptime_float is computed as f128, matching the
/// compiler)
fn FloatOf(comptime k: InternPool.Simple) type {
    return switch (k) {
        .f16 => f16,
        .f32 => f32,
        .f64 => f64,
        .f80 => f80,
        else => f128,
    };
}

/// Bit width of a float type (independent of the layout); c_longdouble depends on the target and
/// is null when the target is unknown
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

/// Unary float builtins
pub const FloatFn = enum { sqrt, sin, cos, tan, exp, exp2, log, log2, log10, abs, floor, ceil, trunc, round };

/// Value of a unary float builtin (`@sqrt` etc.), computed at the precision of the type; null
/// when it is not a float type
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

/// Binary float builtins
pub const FloatBinFn = enum { min, max, mod, rem, div_trunc, div_floor, div_ceil, div_exact };

/// Value of a binary float builtin (`@mod`, `@min` etc.), computed at the precision of the type;
/// null when it cannot be computed (division by zero, inexact division, and so on)
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
    // At comptime the compiler calls its own builtin of the same name; a release build of the
    // compiler is compiled by LLVM, which expands it into the forms below. Computing with the same
    // expansion keeps the result independent of the backend zig-analyzer itself is compiled with.
    // `@mod` adjusts only by the sign of the dividend, so with a negative divisor it differs from
    // the mathematical definition (7 mod -3 in f64 gives 1 rather than -2).
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

/// `@mulAdd(T, a, b, c)`: `a * b + c` rounded only once
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

// ── Size and alignment ───────────────────────────────────────────────

pub const Layout = struct {
    size: u64,
    alignment: u64,
    /// `@bitSizeOf`; null for types without a bit representation (slices, optionals of
    /// non-pointers, error unions, non-packed containers, etc.)
    bits: ?u64,
};

/// Error codes: the integer layout of their bit width (set by the error limit)
fn errorLayout(ip: *InternPool) ?Layout {
    return intLayout(ip, ip.errorBits() orelse return null);
}

/// Size, alignment and bit width of a type (`@sizeOf` / `@alignOf` / `@bitSizeOf`) by the rules
/// of the target (`InternPool.Target`). Handles only types that contain no containers (containers
/// are handled by `eval.typeLayout`); null for the rest.
pub fn typeLayout(ip: *InternPool, t: Index) ?Layout {
    const pointer_bits: u64 = ip.pointerBits() orelse 0;
    const ptr_bytes: u64 = pointer_bits / 8;
    return switch (ip.key(t)) {
        .int_type => |i| intLayout(ip, i.bits),
        .simple_type => |s| switch (s) {
            .bool => .{ .size = 1, .alignment = 1, .bits = 1 },
            .void => .{ .size = 0, .alignment = 1, .bits = 0 },
            .usize, .isize => if (pointer_bits == 0) null else intLayout(ip, @intCast(pointer_bits)),
            // Represented as u16
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

/// Layout of C types and f32, f64, f80, f128 (`InternPool.ScalarAbi`); null for other types and
/// when the target leaves it undefined
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

/// `@Vector(len, T)` (the vector branch of `Type.abiAlignment` / `abiSize`): the rules depend on
/// the compiler backend and CPU features (`InternPool.VectorAbi`). Null for f80 and f128 elements,
/// since whether they use soft float depends on the target's long double.
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
            // aarch64: no larger than the stack alignment
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

/// Aligns up to `alignment` (a power of 2); null on overflow, since an oversized type in the
/// source must not crash the host
pub fn alignForward(x: u64, alignment: u64) ?u64 {
    const sum = std.math.add(u64, x, alignment - 1) catch return null;
    return sum & ~(alignment - 1);
}

/// Converts a byte offset to a bit offset; null on overflow
pub fn bitsOf(bytes: u64) ?u64 {
    return std.math.mul(u64, bytes, 8) catch null;
}

/// Layout (`std.zig.target.intAlignment` / `intByteSize`) of a fixed-width integer type,
/// including the backing integer of a packed container and the tag of an enum: the alignment is
/// the byte size rounded up to a power of 2, but no larger than the target's maximum integer
/// alignment. Null when the maximum alignment differs between modules and affects the alignment
/// of this bit width.
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

/// `?T`: non-C pointers (including slices) and error sets represent null as zero and have the
/// size of the payload; the rest add a flag after the payload, padded to the payload's alignment.
/// Only optionals of single-item and many-item pointers have a bit representation.
pub fn optionalLayout(ip: *InternPool, child: Index, payload: Layout) ?Layout {
    switch (ip.key(child)) {
        .ptr_type => |p| if (p.size != .c) return .{ .size = payload.size, .alignment = payload.alignment, .bits = if (p.size == .slice) null else payload.bits },
        .error_set_type, .inferred_error_set => return .{ .size = payload.size, .alignment = payload.alignment, .bits = null },
        .simple_type => |s| if (s == .anyerror) return .{ .size = payload.size, .alignment = payload.alignment, .bits = null },
        else => {},
    }
    return .{ .size = std.math.add(u64, payload.size, payload.alignment) catch return null, .alignment = payload.alignment, .bits = null };
}

/// Arrays (the length includes the sentinel). `elem_bit_repr`: an array has a bit width only
/// when its elements have a bit representation (error sets and enums without an explicit tag type
/// have a `@bitSizeOf` but no bit representation).
pub fn arrayLayout(elem: Layout, a: @FieldType(InternPool.Key, "array_type"), elem_bit_repr: bool) ?Layout {
    const n = std.math.add(u64, a.len, @intFromBool(a.sentinel != null)) catch return null;
    const size = std.math.mul(u64, elem.size, n) catch return null;
    const bits: ?u64 = if (elem_bit_repr) (if (elem.bits) |b| std.math.mul(u64, b, n) catch null else null) else null;
    return .{ .size = size, .alignment = elem.alignment, .bits = bits };
}

/// `E!T`: the error code and the payload, padded to the larger of their alignments
pub fn errorUnionLayout(ip: *InternPool, payload: Layout) ?Layout {
    const err = errorLayout(ip) orelse return null;
    const alignment = @max(err.alignment, payload.alignment);
    const size = std.math.add(u64, err.size, payload.size) catch return null;
    return .{ .size = alignForward(size, alignment) orelse return null, .alignment = alignment, .bits = null };
}

/// Whether a type without containers has a bit representation (error sets do not)
fn hasBitRepr(ip: *InternPool, t: Index) bool {
    return switch (ip.key(t)) {
        .error_set_type, .inferred_error_set => false,
        .simple_type => |s| s != .anyerror,
        .array_type => |a| hasBitRepr(ip, a.child),
        else => true,
    };
}

// ── Type classification ──────────────────────────────────────────────

pub fn isTypeKey(k: InternPool.Key) bool {
    return switch (k) {
        .simple_type, .int_type, .ptr_type, .array_type, .optional_type, .error_union_type, .error_set_type, .fn_type, .container_type, .opaque_param => true,
        .tuple_type, .vector_type, .anon_struct_type, .reified_type, .union_tag_type, .inferred_error_set, .abstract_array_type => true,
        else => false,
    };
}

/// Enum types (enums in the source, constructed enums, the tag enum of a union(enum))
pub fn isEnumType(ip: *InternPool, t: Index) bool {
    return switch (ip.key(t)) {
        .container_type => |c| c.kind == .@"enum",
        .reified_type => |r| r.kind == .@"enum",
        .union_tag_type => true,
        else => false,
    };
}

/// `@hasField` on slices (`ptr` and `len`) and arrays (`len`); null for other types
pub fn sliceArrayHasField(ip: *InternPool, t: Index, name: []const u8) ?bool {
    return switch (ip.key(t)) {
        .ptr_type => |p| if (p.size == .slice) std.mem.eql(u8, name, "ptr") or std.mem.eql(u8, name, "len") else null,
        .array_type, .abstract_array_type => std.mem.eql(u8, name, "len"),
        else => null,
    };
}

/// Types that can exist only at comptime: a parameter of such a type is a comptime parameter even
/// without `comptime`
pub fn isComptimeOnly(ip: *InternPool, t: Index) bool {
    return switch (ip.key(t)) {
        .simple_type => |s| switch (s) {
            .type, .comptime_int, .comptime_float, .enum_literal, .null, .undefined => true,
            else => false,
        },
        .fn_type => true,
        // Function pointers are runtime values; only pointers to other comptime-only types are
        // comptime-only
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

/// Tuples and anonymous structs: comptime fields (such as `comptime comptime_int = 5`) do not
/// make the type comptime-only
fn anyRuntimeComptimeOnly(ip: *InternPool, types: []const Index, values: []const Index) bool {
    for (types, 0..) |t, i| {
        const v = InternPool.fieldValue(values, i);
        if ((v == .runtime or v == .unknown) and isComptimeOnly(ip, t)) return true;
    }
    return false;
}

// ── Equality ─────────────────────────────────────────────────────────

/// Contains no unknown parts: the same Index always denotes the same value. An abstract
/// parameter can be compared with itself (`T == T`), but an unknown comptime argument
/// (`List(_)`) cannot: `_` at different call sites may be different values.
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

/// A type without abstract parameters or unknown parts: it can be used outside the instance that
/// defines it (e.g. as the caller's expected type)
pub fn isConcrete(ip: *InternPool, t: Index) bool {
    return concrete(ip, t, false);
}

/// A type or instance without abstract parameters: inferring it under another instance gives the
/// same result. Unlike `isConcrete`, an array whose length cannot be evaluated but depends on no
/// abstract parameter (`InternPool.Key.abstract_array_type` without `len`) counts.
pub fn isSettled(ip: *InternPool, t: Index) bool {
    return concrete(ip, t, true);
}

fn concrete(ip: *InternPool, t: Index, unknown_len: bool) bool {
    if (t == .unknown) return false;
    return switch (ip.key(t)) {
        .unknown, .opaque_param => false,
        .abstract_array_type => |a| unknown_len and a.len == null and concrete(ip, a.child, true) and (a.sentinel == null or concrete(ip, a.sentinel.?, true)),
        .ptr_type => |p| concrete(ip, p.child, unknown_len),
        .array_type => |a| concrete(ip, a.child, unknown_len),
        .optional_type => |c| concrete(ip, c, unknown_len),
        .error_union_type => |e| concrete(ip, e.err, unknown_len) and concrete(ip, e.payload, unknown_len),
        .fn_type => |f| blk: {
            for (f.params) |p| if (!concrete(ip, p, unknown_len)) break :blk false;
            break :blk concrete(ip, f.ret, unknown_len);
        },
        .container_type => |c| c.inst == null or concrete(ip, c.inst.?, unknown_len),
        .tuple_type => |tt| allConcrete(ip, tt.types, unknown_len) and allConcrete(ip, tt.values, unknown_len),
        .vector_type => |v| concrete(ip, v.child, unknown_len),
        .anon_struct_type => |a| allConcrete(ip, a.types, unknown_len) and allConcrete(ip, a.values, unknown_len),
        .reified_type => |r| allConcrete(ip, r.types, unknown_len) and (r.inst == null or concrete(ip, r.inst.?, unknown_len)),
        .union_tag_type => |u| concrete(ip, u, unknown_len),
        .instance => |i| blk: {
            if (i.iteration) |it| if (it.index == InternPool.Instance.Iteration.unknown_index) break :blk false;
            for (i.args) |a| if (a != .runtime and !concrete(ip, a, unknown_len)) break :blk false;
            break :blk i.parent == null or concrete(ip, i.parent.?, unknown_len);
        },
        else => true,
    };
}

fn allConcrete(ip: *InternPool, items: []const Index, unknown_len: bool) bool {
    for (items) |x| if (!concrete(ip, x, unknown_len)) return false;
    return true;
}

/// Three-valued conjunction: false if any is false, otherwise null if any is unknown
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

/// Whether two types are the same
pub fn eqlTypes(ip: *InternPool, a: Index, b: Index) ?bool {
    if (a == b) return if (isPrecise(ip, a)) true else null;
    if (a == .unknown or b == .unknown) return null;
    const ka = ip.key(a);
    const kb = ip.key(b);
    // Whether an abstract type (a parameter, an array of unknown length) is the same as another
    // type depends on the instance
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
        // Containers defined at different locations always differ; whether containers defined at
        // the same location in different instances are the same depends on the values they capture
        .container_type => |c| if (c.file != kb.container_type.file or c.ast_id != kb.container_type.ast_id) false else null,
        .tuple_type => |x| all(&.{ eqlTypeLists(ip, x.types, kb.tuple_type.types), eqlFieldValues(ip, x.values, kb.tuple_type.values, x.types.len) }),
        .vector_type => |v| if (v.len != kb.vector_type.len) false else eqlTypes(ip, v.child, kb.vector_type.child),
        .anon_struct_type => |x| blk: {
            const y = kb.anon_struct_type;
            if (!eqlNames(x.names, y.names)) break :blk false;
            break :blk all(&.{ eqlTypeLists(ip, x.types, y.types), eqlFieldValues(ip, x.values, y.values, x.types.len) });
        },
        // Types constructed at the same location with the same contents are the same (the instance
        // at construction only affects display)
        .reified_type => |x| blk: {
            const y = kb.reified_type;
            if (x.file != y.file or x.owner != y.owner or x.expr != y.expr or x.kind != y.kind or x.layout != y.layout) break :blk false;
            if (x.nonexhaustive != y.nonexhaustive or !eqlNames(x.names, y.names) or !std.mem.eql(i128, x.values, y.values)) break :blk false;
            if (x.attrs_unknown != y.attrs_unknown or !std.mem.eql(u64, x.field_aligns, y.field_aligns) or !std.mem.eql(bool, x.comptime_fields, y.comptime_fields)) break :blk false;
            const tag: ?bool = if (x.tag == null or y.tag == null) x.tag == null and y.tag == null else eqlTypes(ip, x.tag.?, y.tag.?);
            break :blk all(&.{ tag, eqlTypeLists(ip, x.types, y.types) });
        },
        .union_tag_type => |u| eqlTypes(ip, u, kb.union_tag_type),
        // Error sets inferred for different functions may happen to be the same
        .inferred_error_set => null,
        // Interning guarantees that equal simple types, integer types and error sets are the same
        // Index
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

/// Comptime values of the fields of tuples and anonymous structs: a runtime field differs from a
/// comptime field, and comptime fields are compared by value
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

/// Whether two comptime values are equal (the semantics of `==`; types are compared by
/// `eqlTypes`)
pub fn eqlValues(ip: *InternPool, a: Index, b: Index) ?bool {
    if (a == .unknown or b == .unknown) return null;
    const ka = ip.key(a);
    const kb = ip.key(b);
    if (isTypeKey(ka) or isTypeKey(kb)) {
        if (!isTypeKey(ka) or !isTypeKey(kb)) return null;
        return eqlTypes(ip, a, b);
    }
    // A non-null optional value is its payload: compared with null, it is unequal as soon as
    // the other side is a known non-null value
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
            // A tagged union compared with a tag
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

/// Interns an aggregate value: when all elements are u8 integers it is represented as a string
/// (`bytes`), so each value has only one representation
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

// ── Conversion ───────────────────────────────────────────────────────

/// Coerces a comptime value to a value of type `to` (result type semantics): an integer literal
/// takes the target integer type (null when out of range), an enum literal becomes the member of
/// the target enum, and an optional target first coerces to the payload type (a non-null optional
/// value is the payload value). Returns the value unchanged when no coercion is needed or
/// possible.
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
    // Floats with integer values (an integer-valued comptime_float can coerce to an integer
    // type)
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

/// The value of pointer-to-array `tv` coerced to slice type `to` (`*const [2]u16` to
/// `[]const u16`): both are represented by the elements, so only the type changes. Null when it is
/// not such a coercion (different element types, a sentinel the array lacks, dropping `const`).
pub fn arrayPtrAsSlice(ip: *InternPool, tv: InternPool.TypedValue, to: Index) Allocator.Error!?Index {
    const v = tv.val orelse return null;
    const from = switch (ip.key(tv.ty)) {
        .ptr_type => |p| if (p.size == .one) p else return null,
        else => return null,
    };
    const slice = switch (ip.key(to)) {
        .ptr_type => |p| if (p.size == .slice) p else return null,
        else => return null,
    };
    const array = switch (ip.key(from.child)) {
        .array_type => |a| a,
        else => return null,
    };
    if (array.child != slice.child or (from.is_const and !slice.is_const)) return null;
    if (slice.sentinel) |s| if (array.sentinel != s) return null;
    return switch (ip.key(v)) {
        .aggregate => |agg| try ip.get(.{ .aggregate = .{ .ty = to, .elems = agg.elems } }),
        .bytes => |b| try ip.get(.{ .bytes = .{ .ty = to, .bytes = b.bytes } }),
        else => null,
    };
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
    // Types wider than 128 bits are not folded: a shift amount above 255 cannot be @intCast
    // to u8
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
