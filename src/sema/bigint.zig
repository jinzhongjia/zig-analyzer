//! Arbitrary-precision integers: `comptime_int` values outside the range of i128, and arithmetic
//! on fixed-width integer types wider than 128 bits (as in the compiler, which computes every
//! integer with `std.math.big`). Integer types of at most 128 bits are computed with machine
//! integers in value.zig and never reach this module.

const std = @import("std");
const Allocator = std.mem.Allocator;
const SyntaxKind = @import("../syntax/kind.zig").SyntaxKind;

const int = std.math.big.int;
const Limb = std.math.big.Limb;

/// A value: little-endian limbs with a sign, as in `std.math.big.int`; zero is positive
pub const Big = int.Const;

/// Largest bit length of a computed value. Real code does not come close; a result beyond it
/// (such as `1 << 1_000_000_000`) is treated as unknown instead of exhausting memory.
pub const max_bits = 1 << 20;

pub fn fromInt(allocator: Allocator, x: i128) Allocator.Error!Big {
    var m = try int.Managed.initCapacity(allocator, 2);
    m.set(x) catch return error.OutOfMemory;
    return m.toConst();
}

/// The value of an unsigned 128-bit integer (above i128's range for the bit patterns of
/// negative i128 values)
pub fn fromUnsigned128(allocator: Allocator, x: u128) Allocator.Error!Big {
    var m = try int.Managed.initCapacity(allocator, 2);
    m.set(x) catch return error.OutOfMemory;
    return m.toConst();
}

/// The value as an i128, or null when it does not fit
pub fn toInt(b: Big) ?i128 {
    return b.toInt(i128) catch null;
}

pub fn toFloat(b: Big) f128 {
    return b.toFloat(f128, .nearest_even)[0];
}

pub fn eql(a: Big, b: Big) bool {
    return a.eql(b);
}

pub fn order(a: Big, b: Big) std.math.Order {
    return a.order(b);
}

/// `-x`
pub fn negate(a: Big) Big {
    if (a.eqlZero()) return a;
    return .{ .limbs = a.limbs, .positive = !a.positive };
}

/// Result of a binary operation between two `comptime_int` values; null when the compiler would
/// report an error or the result is beyond `max_bits`. `<<|` is `<<`: a comptime_int has no bound
/// to saturate at.
pub fn binary(allocator: Allocator, op: SyntaxKind, a: Big, b: Big) Allocator.Error!?Big {
    switch (op) {
        .plus, .minus, .asterisk, .slash, .percent, .angle_bracket_angle_bracket_left, .angle_bracket_angle_bracket_left_pipe, .angle_bracket_angle_bracket_right => {},
        // Two's complement of unbounded width: the bits of a width that holds both operands and a
        // sign bit, sign-extended
        .ampersand, .pipe, .caret => return try bitwiseBits(allocator, op, .signed, @max(a.bitCountTwosComp(), b.bitCountTwosComp()) + 1, a, b),
        else => return null,
    }
    var ma = try a.toManaged(allocator);
    var mb = try b.toManaged(allocator);
    var out = try int.Managed.initCapacity(allocator, @max(a.limbs.len, b.limbs.len) + 1);
    switch (op) {
        .plus => try out.add(&ma, &mb),
        .minus => try out.sub(&ma, &mb),
        .asterisk => try out.mul(&ma, &mb),
        .slash, .percent => {
            if (mb.eqlZero()) return null;
            // `@divTrunc`: the quotient or the remainder (with the sign of the dividend)
            if (op == .slash) {
                var r = try int.Managed.initCapacity(allocator, a.limbs.len + 1);
                try out.divTrunc(&r, &ma, &mb);
            } else {
                var q = try int.Managed.initCapacity(allocator, a.limbs.len + 1);
                try q.divTrunc(&out, &ma, &mb);
            }
        },
        .angle_bracket_angle_bracket_left, .angle_bracket_angle_bracket_left_pipe, .angle_bracket_angle_bracket_right => {
            const x = toInt(b) orelse return null;
            if (x < 0) return null;
            const shift: usize = if (x > max_bits) max_bits else @intCast(x);
            if (op != .angle_bracket_angle_bracket_right) {
                if (a.bitCountAbs() + shift > max_bits) return null;
                try out.shiftLeft(&ma, shift);
            } else try out.shiftRight(&ma, shift);
        },
        else => unreachable,
    }
    if (out.bitCountAbs() > max_bits) return null;
    return out.toConst();
}

/// Parses a source number literal (`0x1_0000`, `1_000_000`); `base` is the base of the digits
pub fn fromLiteral(allocator: Allocator, text: []const u8, base: u8) Allocator.Error!?Big {
    var digits: std.ArrayList(u8) = .empty;
    const prefix: usize = if (text.len > 1 and text[0] == '0') switch (text[1]) {
        'x', 'X', 'o', 'O', 'b', 'B' => 2,
        else => 0,
    } else 0;
    try digits.ensureTotalCapacity(allocator, text.len - prefix);
    for (text[prefix..]) |c| if (c != '_') try digits.append(allocator, c);
    var m = try int.Managed.initCapacity(allocator, digits.items.len / 16 + 2);
    m.setString(base, digits.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (m.bitCountAbs() > max_bits) return null;
    return m.toConst();
}

/// Decimal digits of the magnitude, without a sign
pub fn decimalAlloc(allocator: Allocator, b: Big) Allocator.Error![]const u8 {
    return b.abs().toStringAlloc(allocator, 10, .lower);
}

pub const DivMode = enum { trunc, floor, ceil, exact, mod, rem };

/// Applies one of `@divTrunc` / `@divFloor` / `@divCeil` / `@divExact` / `@mod` / `@rem`;
/// null when the compiler would report an error
pub fn divide(allocator: Allocator, mode: DivMode, a: Big, b: Big) Allocator.Error!?Big {
    var ma = try a.toManaged(allocator);
    var mb = try b.toManaged(allocator);
    if (mb.eqlZero()) return null;
    var q = try int.Managed.initCapacity(allocator, a.limbs.len + 1);
    var r = try int.Managed.initCapacity(allocator, b.limbs.len + 1);
    switch (mode) {
        .trunc, .rem, .exact => {
            try q.divTrunc(&r, &ma, &mb);
            if (mode == .exact and !r.eqlZero()) return null;
        },
        .floor, .mod, .ceil => try q.divFloor(&r, &ma, &mb),
    }
    if (mode == .ceil and !r.eqlZero()) {
        const one = try fromInt(allocator, 1);
        var m = try one.toManaged(allocator);
        try q.add(&q, &m);
    }
    const out = switch (mode) {
        .trunc, .floor, .ceil, .exact => q,
        .mod, .rem => r,
    };
    if (out.bitCountAbs() > max_bits) return null;
    return out.toConst();
}

/// `@shlExact` / `@shrExact`; a left shift of a comptime_int never overflows
pub fn exactShift(allocator: Allocator, left: bool, a: Big, shift: usize) Allocator.Error!?Big {
    // Beyond `max_bits` every nonzero value shifts out a 1 bit in one direction or overflows
    if (shift > max_bits) return if (a.eqlZero()) a else null;
    if (!left) {
        // A right shift is exact when the bits shifted out are zero
        var ma = try a.toManaged(allocator);
        const p = try fromInt(allocator, 1);
        var mp = try p.toManaged(allocator);
        try mp.shiftLeft(&mp, shift);
        var q = try int.Managed.initCapacity(allocator, a.limbs.len + 1);
        var r = try int.Managed.initCapacity(allocator, p.limbs.len + 1);
        try q.divFloor(&r, &ma, &mp);
        if (!r.eqlZero()) return null;
        return binary(allocator, .angle_bracket_angle_bracket_right, a, try fromInt(allocator, @intCast(shift)));
    }
    return binary(allocator, .angle_bracket_angle_bracket_left, a, try fromInt(allocator, @intCast(shift)));
}

// ── Fixed-width integer types ────────────────────────────────────────
//
// The operations below follow the compiler's `Sema/arith.zig`; operands that are not values of
// the type (which the compiler rejects when coercing them) give null.

/// A fixed-width integer type: signedness and bit width
pub const IntType = struct {
    signed: bool,
    bits: u16,

    fn signedness(t: IntType) std.lang.Signedness {
        return if (t.signed) .signed else .unsigned;
    }
};

/// Whether `a` is a value of type `t`
pub fn fits(a: Big, t: IntType) bool {
    return a.fitsInTwosComp(t.signedness(), t.bits);
}

/// The minimum (`max` false) or maximum value of type `t`
pub fn limit(allocator: Allocator, t: IntType, max: bool) Allocator.Error!Big {
    var m = try int.Managed.initCapacity(allocator, int.calcTwosCompLimbCount(t.bits));
    try m.setTwosCompIntLimit(if (max) .max else .min, t.signedness(), t.bits);
    return m.toConst();
}

/// The low `t.bits` bits of the two's complement representation of `a`, as a value of type `t`
pub fn wrap(allocator: Allocator, a: Big, t: IntType) Allocator.Error!Big {
    return wrapBits(allocator, a, t.signedness(), t.bits);
}

fn wrapBits(allocator: Allocator, a: Big, signedness: std.lang.Signedness, bits: usize) Allocator.Error!Big {
    const limbs = try allocator.alloc(Limb, int.calcTwosCompLimbCount(bits));
    var m: int.Mutable = .{ .limbs = limbs, .positive = undefined, .len = undefined };
    m.truncate(a, signedness, bits);
    return m.toConst();
}

pub const Overflow = enum { check, wrap, saturate };

/// Fits an exact result into type `t`. When it is out of range: plain operations give null (the
/// compiler reports an error), wrapping operations truncate, and saturating operations clamp to
/// the bound.
fn fitTo(allocator: Allocator, r: Big, t: IntType, mode: Overflow) Allocator.Error!?Big {
    if (fits(r, t)) return r;
    return switch (mode) {
        .check => null,
        .wrap => try wrap(allocator, r, t),
        .saturate => try limit(allocator, t, r.positive),
    };
}

/// The shift amount `b` when it is less than the bit width of `t`; null for negative amounts
fn shiftAmount(t: IntType, b: Big) ?usize {
    if (!b.positive or b.orderAgainstScalar(t.bits) != .lt) return null;
    return b.toInt(usize) catch null;
}

/// Result of a binary operation on values of type `t` (for shifts, `a` has type `t` and `b` is
/// the shift amount), with the rules of `value.binaryInt` for narrower types; null when the
/// compiler would report an error
pub fn binaryTyped(allocator: Allocator, op: SyntaxKind, t: IntType, a: Big, b: Big) Allocator.Error!?Big {
    const shift = switch (op) {
        .angle_bracket_angle_bracket_left, .angle_bracket_angle_bracket_left_pipe, .angle_bracket_angle_bracket_right => true,
        else => false,
    };
    if (!fits(a, t) or (!shift and !fits(b, t))) return null;
    return switch (op) {
        .plus => fitTo(allocator, try binary(allocator, .plus, a, b) orelse return null, t, .check),
        .plus_percent => fitTo(allocator, try binary(allocator, .plus, a, b) orelse return null, t, .wrap),
        .plus_pipe => fitTo(allocator, try binary(allocator, .plus, a, b) orelse return null, t, .saturate),
        .minus => fitTo(allocator, try binary(allocator, .minus, a, b) orelse return null, t, .check),
        .minus_percent => fitTo(allocator, try binary(allocator, .minus, a, b) orelse return null, t, .wrap),
        .minus_pipe => fitTo(allocator, try binary(allocator, .minus, a, b) orelse return null, t, .saturate),
        .asterisk => fitTo(allocator, try binary(allocator, .asterisk, a, b) orelse return null, t, .check),
        .asterisk_percent => fitTo(allocator, try binary(allocator, .asterisk, a, b) orelse return null, t, .wrap),
        .asterisk_pipe => fitTo(allocator, try binary(allocator, .asterisk, a, b) orelse return null, t, .saturate),
        // Signed `/` and `%` require @divTrunc etc., so only nonnegative operands are folded
        .slash, .percent => if (!a.positive or !b.positive or b.eqlZero()) null else try binary(allocator, op, a, b),
        .ampersand, .pipe, .caret => try bitwise(allocator, op, t, a, b),
        .angle_bracket_angle_bracket_left => try shl(allocator, t, a, b, false),
        .angle_bracket_angle_bracket_left_pipe => try shl(allocator, t, a, b, true),
        .angle_bracket_angle_bracket_right => {
            const n = shiftAmount(t, b) orelse return null;
            var ma = try a.toManaged(allocator);
            var out = try int.Managed.initCapacity(allocator, a.limbs.len);
            try out.shiftRight(&ma, n);
            return out.toConst();
        },
        else => null,
    };
}

/// `&` / `|` / `^` on the two's complement bit patterns. The operations run on the unsigned
/// patterns: `std.math.big` of zig 0.17.0 leaves high limbs unset in `|` of a negative and a
/// longer nonnegative operand.
fn bitwise(allocator: Allocator, op: SyntaxKind, t: IntType, a: Big, b: Big) Allocator.Error!Big {
    return bitwiseBits(allocator, op, t.signedness(), t.bits, a, b);
}

fn bitwiseBits(allocator: Allocator, op: SyntaxKind, signedness: std.lang.Signedness, bits: usize, a: Big, b: Big) Allocator.Error!Big {
    var x = try (try wrapBits(allocator, a, .unsigned, bits)).toManaged(allocator);
    var y = try (try wrapBits(allocator, b, .unsigned, bits)).toManaged(allocator);
    var out = try int.Managed.initCapacity(allocator, @max(x.len(), y.len()));
    switch (op) {
        .ampersand => try out.bitAnd(&x, &y),
        .pipe => try out.bitOr(&x, &y),
        .caret => try out.bitXor(&x, &y),
        else => unreachable,
    }
    return wrapBits(allocator, out.toConst(), signedness, bits);
}

/// `<<`: bits shifted out are discarded (the shift amount must be less than the bit width);
/// `<<|` saturates
fn shl(allocator: Allocator, t: IntType, a: Big, b: Big, saturate: bool) Allocator.Error!?Big {
    if (!b.positive) return null;
    const n = shiftAmount(t, b) orelse {
        if (!saturate) return null;
        if (a.eqlZero()) return a;
        return try limit(allocator, t, a.positive);
    };
    var ma = try a.toManaged(allocator);
    var out = try int.Managed.initCapacity(allocator, a.limbs.len + n / @bitSizeOf(Limb) + 1);
    try out.shiftLeft(&ma, n);
    return fitTo(allocator, out.toConst(), t, if (saturate) .saturate else .wrap);
}

/// `-a` / `-%a` on a value of type `t`
pub fn negateTyped(allocator: Allocator, t: IntType, a: Big, wrapping: bool) Allocator.Error!?Big {
    if (!fits(a, t)) return null;
    return fitTo(allocator, negate(a), t, if (wrapping) .wrap else .check);
}

/// `~a` on a value of type `t`
pub fn bitNotTyped(allocator: Allocator, t: IntType, a: Big) Allocator.Error!?Big {
    if (!fits(a, t)) return null;
    const limbs = try allocator.alloc(Limb, int.calcTwosCompLimbCount(t.bits));
    var m: int.Mutable = .{ .limbs = limbs, .positive = undefined, .len = undefined };
    m.bitNotWrap(a, t.signedness(), t.bits);
    return m.toConst();
}

/// `@addWithOverflow` (`.plus`), `@subWithOverflow` (`.minus`), `@mulWithOverflow`
/// (`.asterisk`) and `@shlWithOverflow` (`<<`, `b` is the shift amount, which must be less than
/// the bit width): the result wrapped to `t` and whether it overflowed
pub fn overflowTyped(allocator: Allocator, op: SyntaxKind, t: IntType, a: Big, b: Big) Allocator.Error!?struct { Big, bool } {
    if (!fits(a, t)) return null;
    const exact: Big = if (op == .angle_bracket_angle_bracket_left) blk: {
        const n = shiftAmount(t, b) orelse return null;
        var ma = try a.toManaged(allocator);
        var out = try int.Managed.initCapacity(allocator, a.limbs.len + n / @bitSizeOf(Limb) + 1);
        try out.shiftLeft(&ma, n);
        break :blk out.toConst();
    } else blk: {
        if (!fits(b, t)) return null;
        break :blk try binary(allocator, op, a, b) orelse return null;
    };
    if (fits(exact, t)) return .{ exact, false };
    return .{ try wrap(allocator, exact, t), true };
}

/// `@shlExact` / `@shrExact` on a value of type `t`: null when the shift amount is not less than
/// the bit width, a left shift overflows, or a right shift shifts out a 1 bit
pub fn exactShiftTyped(allocator: Allocator, left: bool, t: IntType, a: Big, b: Big) Allocator.Error!?Big {
    if (!fits(a, t)) return null;
    const n = shiftAmount(t, b) orelse return null;
    var ma = try a.toManaged(allocator);
    var out = try int.Managed.initCapacity(allocator, a.limbs.len + n / @bitSizeOf(Limb) + 1);
    if (left) {
        try out.shiftLeft(&ma, n);
        return fitTo(allocator, out.toConst(), t, .check);
    }
    if (a.ctz(n) < n) return null;
    try out.shiftRight(&ma, n);
    return out.toConst();
}

/// `@divTrunc` / `@divFloor` / `@divCeil` / `@divExact` / `@mod` / `@rem` on values of type `t`
pub fn divideTyped(allocator: Allocator, mode: DivMode, t: IntType, a: Big, b: Big) Allocator.Error!?Big {
    if (!fits(a, t) or !fits(b, t)) return null;
    const r = try divide(allocator, mode, a, b) orelse return null;
    return if (fits(r, t)) r else null;
}

/// `@byteSwap` (`bytes`) / `@bitReverse` on a value of type `t`; the bit width for `@byteSwap`
/// must be a multiple of 8
pub fn reverseBitsTyped(allocator: Allocator, bytes: bool, t: IntType, a: Big) Allocator.Error!?Big {
    if (!fits(a, t) or (bytes and t.bits % 8 != 0)) return null;
    const limbs = try allocator.alloc(Limb, int.calcTwosCompLimbCount(t.bits));
    var m: int.Mutable = .{ .limbs = limbs, .positive = undefined, .len = undefined };
    if (bytes) m.byteSwap(a, t.signedness(), t.bits / 8) else m.bitReverse(a, t.signedness(), t.bits);
    return m.toConst();
}

pub const BitCount = enum { clz, ctz, pop_count };

/// `@clz` / `@ctz` / `@popCount` of the two's complement representation of a value of type `t`
pub fn bitCountTyped(t: IntType, a: Big, which: BitCount) ?u16 {
    if (!fits(a, t)) return null;
    return @intCast(switch (which) {
        .clz => a.clz(t.bits),
        .ctz => a.ctz(t.bits),
        .pop_count => a.popCount(t.bits),
    });
}

/// The integer part of `x` (`@intFromFloat` truncates toward zero); null for NaN and infinities
pub fn fromFloat(allocator: Allocator, x: f128) Allocator.Error!?Big {
    if (std.math.isNan(x) or std.math.isInf(x)) return null;
    // The largest finite f128 is below 2^16384
    const limbs = try allocator.alloc(Limb, 16384 / @bitSizeOf(Limb) + 1);
    var m: int.Mutable = .{ .limbs = limbs, .positive = undefined, .len = undefined };
    _ = m.setFloat(x, .trunc);
    return m.toConst();
}
