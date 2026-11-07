//! Arbitrary-precision integers for `comptime_int` values outside the range of i128. Fixed-width
//! integer values are stored as i128 (or as the bit pattern for u128) and never reach this module.

const std = @import("std");
const Allocator = std.mem.Allocator;
const SyntaxKind = @import("../syntax/kind.zig").SyntaxKind;

const int = std.math.big.int;

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

/// Low `bits` bits of the two's complement representation, as an integer of `bits` bits
pub fn truncate(allocator: Allocator, a: Big, signed: bool, bits: u16) Allocator.Error!?i128 {
    if (bits == 0) return 0;
    if (bits > 128) return null;
    var ma = try a.toManaged(allocator);
    const p = try fromInt(allocator, 1);
    var mp = try p.toManaged(allocator);
    try mp.shiftLeft(&mp, bits);
    var q = try int.Managed.initCapacity(allocator, a.limbs.len + 1);
    var r = try int.Managed.initCapacity(allocator, p.limbs.len + 1);
    try q.divFloor(&r, &ma, &mp);
    const u = r.toConst().toInt(u128) catch return null;
    const half: u128 = @as(u128, 1) << @intCast(bits - 1);
    if (signed and u >= half) {
        if (bits == 128) return @bitCast(u);
        return @bitCast(u -% (@as(u128, 1) << @intCast(bits)));
    }
    return @bitCast(u);
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
