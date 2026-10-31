//! General-purpose allocator whose free lists are shared across threads, based on the size-class
//! design of `std.heap.SmpAllocator`.
//!
//! `SmpAllocator` keeps a set of free lists per thread slot: a freed block goes onto the list of
//! the freeing thread's slot and is reused only by allocations of the same size class on the same
//! slot. The server's cached values are allocated on worker threads and freed on the threads that
//! run sweeps and write transactions, so freed blocks pile up in a few slots out of reach of the
//! allocating threads, which have to map new blocks; the memory holding small blocks is not
//! returned to the system, so resident memory keeps growing over a session.
//!
//! Here each size class has a single free list protected by one lock, so a block freed by any
//! thread can be reused by any thread. A thread that cannot get the lock sleeps (futex) instead of
//! spinning. Allocations larger than `slab_len` are mapped directly, and returned to the system
//! when they are freed.

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const PageAllocator = std.heap.PageAllocator;
const Mutex = std.Io.Mutex;
const Threaded = std.Io.Threaded;
const alloc_stats = @import("alloc_stats.zig");

const slab_len: usize = @max(std.heap.page_size_max, 64 * 1024);
/// The free-list pointer is stored in the block, so the smallest class is one pointer in size
const min_class = math.log2(@sizeOf(usize));
const size_class_count = math.log2(slab_len) - min_class;

var mutex: Mutex = .init;
/// Per class, the address of the next slot to carve from the current slab; a new slab is mapped
/// when it falls on a slab boundary
var next_addrs: [size_class_count]usize = @splat(0);
/// Head of the free list of each class
var frees: [size_class_count]usize = @splat(0);
var slabs: [size_class_count]std.atomic.Value(usize) = @splat(.init(0));
var live: [size_class_count]std.atomic.Value(usize) = @splat(.init(0));
var allocs: [size_class_count]std.atomic.Value(u64) = @splat(.init(0));
var large_bytes: std.atomic.Value(usize) = .init(0);

pub fn stats(arena: Allocator) !alloc_stats.Stats {
    const out = try arena.alloc(alloc_stats.Class, size_class_count);
    var s: alloc_stats.Stats = .{ .classes = out };
    for (out, 0..) |*o, class| {
        o.* = .{
            .size = slotSize(class),
            .bytes = slabs[class].load(.monotonic) * slab_len,
            .live = live[class].load(.monotonic),
            .allocs = allocs[class].load(.monotonic),
        };
        s.small_bytes += o.bytes;
        s.slot_bytes += o.live * o.size;
    }
    s.large_bytes = large_bytes.load(.monotonic);
    return s;
}

pub const allocator: Allocator = .{ .ptr = undefined, .vtable = &vtable };

const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

fn alloc(_: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const class = sizeClassIndex(len, alignment);
    if (class >= size_class_count) {
        @branchHint(.unlikely);
        const p = PageAllocator.map(len, alignment) orelse return null;
        _ = large_bytes.fetchAdd(len, .monotonic);
        return p;
    }
    const slot_size = slotSize(class);
    Threaded.mutexLockUncancelable(&mutex);
    defer Threaded.mutexUnlock(&mutex);
    _ = live[class].fetchAdd(1, .monotonic);
    _ = allocs[class].fetchAdd(1, .monotonic);
    const top = frees[class];
    if (top != 0) {
        @branchHint(.likely);
        frees[class] = @as(*usize, @ptrFromInt(top)).*;
        return @ptrFromInt(top);
    }
    const next = next_addrs[class];
    if (next % slab_len != 0) {
        @branchHint(.likely);
        next_addrs[class] = next + slot_size;
        return @ptrFromInt(next);
    }
    // Slabs are aligned to slab_len: the remainder check above tells whether carving has reached
    // the end of the slab
    const slab = PageAllocator.map(slab_len, .fromByteUnits(slab_len)) orelse {
        _ = live[class].fetchSub(1, .monotonic);
        return null;
    };
    _ = slabs[class].fetchAdd(1, .monotonic);
    next_addrs[class] = @intFromPtr(slab) + slot_size;
    return slab;
}

fn resize(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) bool {
    const class = sizeClassIndex(memory.len, alignment);
    const new_class = sizeClassIndex(new_len, alignment);
    if (class >= size_class_count) {
        if (new_class < size_class_count) return false;
        if (PageAllocator.realloc(memory, alignment, new_len, false) == null) return false;
        adjustLarge(memory.len, new_len);
        return true;
    }
    return new_class == class;
}

fn remap(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) ?[*]u8 {
    const class = sizeClassIndex(memory.len, alignment);
    const new_class = sizeClassIndex(new_len, alignment);
    if (class >= size_class_count) {
        if (new_class < size_class_count) return null;
        const p = PageAllocator.realloc(memory, alignment, new_len, true) orelse return null;
        adjustLarge(memory.len, new_len);
        return p;
    }
    return if (new_class == class) memory.ptr else null;
}

fn free(_: *anyopaque, memory: []u8, alignment: Alignment, _: usize) void {
    const class = sizeClassIndex(memory.len, alignment);
    if (class >= size_class_count) {
        @branchHint(.unlikely);
        _ = large_bytes.fetchSub(memory.len, .monotonic);
        return PageAllocator.unmap(@alignCast(memory));
    }
    const node: *usize = @ptrCast(@alignCast(memory.ptr));
    Threaded.mutexLockUncancelable(&mutex);
    defer Threaded.mutexUnlock(&mutex);
    _ = live[class].fetchSub(1, .monotonic);
    node.* = frees[class];
    frees[class] = @intFromPtr(node);
}

fn adjustLarge(old: usize, new: usize) void {
    if (new > old) _ = large_bytes.fetchAdd(new - old, .monotonic) else _ = large_bytes.fetchSub(old - new, .monotonic);
}

fn sizeClassIndex(len: usize, alignment: Alignment) usize {
    return @max(@bitSizeOf(usize) - @clz(len - 1), @backingInt(alignment), min_class) - min_class;
}

fn slotSize(class: usize) usize {
    return @as(usize, 1) << @intCast(class + min_class);
}

test "blocks freed on one thread are reused by allocations on another" {
    const a = allocator;
    const first = try a.alloc(u8, 100);
    const addr = @intFromPtr(first.ptr);
    const T = struct {
        fn run(mem: []u8) void {
            allocator.free(mem);
        }
    };
    const t = try std.Thread.spawn(.{}, T.run, .{first});
    t.join();
    const again = try a.alloc(u8, 100);
    defer a.free(again);
    try std.testing.expectEqual(addr, @intFromPtr(again.ptr));
}

test "concurrent allocation and free keep blocks intact" {
    const T = struct {
        fn run(seed: u8) void {
            var held: [256][]u8 = undefined;
            for (&held, 0..) |*h, i| {
                const len = 1 + (i * 37 + seed) % 4000;
                h.* = allocator.alloc(u8, len) catch unreachable;
                @memset(h.*, seed);
            }
            for (held) |h| {
                for (h) |b| assert(b == seed);
                allocator.free(h);
            }
        }
    };
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, T.run, .{@as(u8, @intCast(i + 1))});
    for (threads) |t| t.join();
}

test "large allocations bypass size classes" {
    const big = try allocator.alloc(u8, slab_len + 1);
    defer allocator.free(big);
    big[slab_len] = 1;
    try std.testing.expect(std.mem.isAligned(@intFromPtr(big.ptr), std.heap.page_size_min));
}
