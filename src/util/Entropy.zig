//! Entropy source shared by fuzz tests and randomized property tests: interprets a byte string as
//! various choices on demand, and yields 0 forever once the bytes run out. The same input can come
//! either from `std.testing.Smith` (coverage-guided) or from a fixed-seed pseudo-random generator.

const Entropy = @This();

/// Iteration count of randomized property tests: one tenth under Debug (with allocation checks, an
/// order of magnitude slower), the full count in optimized builds (the ReleaseSafe tests on CI)
pub fn iterations(comptime full: usize) usize {
    return if (@import("builtin").mode == .debug) full / 10 else full;
}

bytes: []const u8,
pos: usize = 0,

pub fn byte(e: *Entropy) u8 {
    if (e.pos >= e.bytes.len) return 0;
    defer e.pos += 1;
    return e.bytes[e.pos];
}

pub fn below(e: *Entropy, n: usize) usize {
    if (n <= 1) return 0;
    const v = @as(usize, e.byte()) << 8 | e.byte();
    return v % n;
}

pub fn pick(e: *Entropy, comptime T: type, items: []const T) T {
    return items[e.below(items.len)];
}
