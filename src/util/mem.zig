//! Memory statistics (`zig-analyzer/status`, the benchmark and corpus tools).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Number of bytes the arena currently occupies (excluding internal bookkeeping)
pub fn arenaBytes(state: std.heap.ArenaAllocator.State) usize {
    return state.promote(std.mem.Allocator.failing).queryCapacity();
}

/// Counts the bytes allocated through it and not yet freed. It is thread-safe whenever the child
/// allocator is.
pub const Counting = struct {
    child: Allocator,
    live: std.atomic.Value(usize) = .init(0),

    pub fn allocator(c: *Counting) Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    pub fn liveBytes(c: *const Counting) usize {
        return c.live.load(.monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        const p = c.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        _ = c.live.fetchAdd(len, .monotonic);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        if (!c.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        c.adjust(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        const p = c.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        c.adjust(memory.len, new_len);
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        c.child.rawFree(memory, alignment, ret_addr);
        _ = c.live.fetchSub(memory.len, .monotonic);
    }

    fn adjust(c: *Counting, old: usize, new: usize) void {
        if (new > old) _ = c.live.fetchAdd(new - old, .monotonic) else _ = c.live.fetchSub(old - new, .monotonic);
    }
};

test "counting allocator tracks live bytes" {
    var c: Counting = .{ .child = std.testing.allocator };
    const a = c.allocator();
    const buf = try a.alloc(u8, 100);
    try std.testing.expectEqual(100, c.liveBytes());
    const grown = try a.realloc(buf, 300);
    try std.testing.expectEqual(300, c.liveBytes());
    a.free(grown);
    try std.testing.expectEqual(0, c.liveBytes());
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    _ = try arena.allocator().alloc(u8, 1000);
    try std.testing.expect(arenaBytes(arena.state) >= 1000);
}
