//! Width of the byte scans that compare or search a block of bytes at a time.

const std = @import("std");
const builtin = @import("builtin");

/// Bytes compared at once by the scans for line breaks, ASCII text, and common prefixes and
/// suffixes: the vector length the target prefers (16 with NEON or SSE2, 32 with AVX2), or 0 for
/// a byte-by-byte scan. Vectors are used on the backends `std.mem` uses them on; the others do not
/// support them.
pub const width: usize = switch (builtin.zig_backend) {
    .stage2_aarch64, .stage2_loongarch, .stage2_powerpc, .stage2_riscv64, .stage2_spirv => 0,
    else => std.simd.suggestVectorLength(u8) orelse 0,
};
