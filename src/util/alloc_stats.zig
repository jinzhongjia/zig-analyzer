//! Statistics of the backing allocator, reported in `zig-analyzer/status` to compare
//! `SharedAllocator` with the paged allocators.

const std = @import("std");
const SharedAllocator = @import("SharedAllocator.zig");
const PagedAllocator = @import("PagedAllocator.zig");

pub const Kind = enum { shared, paged, paged_fine };

pub const Stats = struct {
    /// Bytes of small-block memory assigned to size classes (slabs or pages)
    small_bytes: usize = 0,
    /// Bytes of the small blocks handed out, counted by slot size
    slot_bytes: usize = 0,
    /// Bytes of empty pages kept committed
    empty_bytes: usize = 0,
    /// Bytes of empty pages returned to the system
    decommitted_bytes: usize = 0,
    /// Bytes of directly mapped allocations
    large_bytes: usize = 0,
    /// Bytes of small-block memory that has been touched and not returned (segment headers,
    /// touched parts of pages, including retained empty pages); 0 when not tracked
    touched_bytes: usize = 0,
    classes: []const Class = &.{},
};

pub const Class = struct {
    size: usize,
    /// Bytes assigned to the class (slabs or pages)
    bytes: usize,
    /// Blocks handed out
    live: usize,
    /// Allocations served since startup
    allocs: u64,
};

/// Set by the executable
pub var kind: ?Kind = null;

pub fn get(arena: std.mem.Allocator) !Stats {
    const k = kind orelse return .{};
    return switch (k) {
        .shared => SharedAllocator.stats(arena),
        .paged => PagedAllocator.Pow2.stats(arena),
        .paged_fine => PagedAllocator.Fine.stats(arena),
    };
}
