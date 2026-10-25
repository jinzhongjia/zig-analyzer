//! 跨线程共享空闲链表的通用分配器，基于 `std.heap.SmpAllocator` 的大小档设计。
//!
//! `SmpAllocator` 按线程槽位各有一套空闲链表，释放的块挂到释放线程所在槽位的链表上，只有在同一槽位上分配
//! 同一大小档时才复用。服务器的缓存值在工作线程上分配、在清扫与写事务所在的线程上释放，释放的块积压在
//! 少数槽位中，分配方取不到，只能映射新的块；小块所在的内存不归还系统，常驻内存随会话持续增长。
//!
//! 这里各大小档只有一条空闲链表，由一把锁保护，任何线程释放的块都能被任何线程复用。锁拿不到时休眠（futex），
//! 不空转。大于 `slab_len` 的分配直接映射，释放时归还系统。

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const PageAllocator = std.heap.PageAllocator;
const Mutex = std.Io.Mutex;
const Threaded = std.Io.Threaded;

const slab_len: usize = @max(std.heap.page_size_max, 64 * 1024);
/// 空闲链表的指针存放在块中，最小的档是一个指针大小
const min_class = math.log2(@sizeOf(usize));
const size_class_count = math.log2(slab_len) - min_class;

var mutex: Mutex = .init;
/// 各档下一次从当前 slab 切出的地址；落在 slab 边界上时映射新的 slab
var next_addrs: [size_class_count]usize = @splat(0);
/// 各档空闲链表的表头
var frees: [size_class_count]usize = @splat(0);

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
        return PageAllocator.map(len, alignment);
    }
    const slot_size = slotSize(class);
    Threaded.mutexLockUncancelable(&mutex);
    defer Threaded.mutexUnlock(&mutex);
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
    // slab 按 slab_len 对齐：上面按取余判断是否切到了 slab 末尾
    const slab = PageAllocator.map(slab_len, .fromByteUnits(slab_len)) orelse return null;
    next_addrs[class] = @intFromPtr(slab) + slot_size;
    return slab;
}

fn resize(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) bool {
    const class = sizeClassIndex(memory.len, alignment);
    const new_class = sizeClassIndex(new_len, alignment);
    if (class >= size_class_count) {
        if (new_class < size_class_count) return false;
        return PageAllocator.realloc(memory, alignment, new_len, false) != null;
    }
    return new_class == class;
}

fn remap(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) ?[*]u8 {
    const class = sizeClassIndex(memory.len, alignment);
    const new_class = sizeClassIndex(new_len, alignment);
    if (class >= size_class_count) {
        if (new_class < size_class_count) return null;
        return PageAllocator.realloc(memory, alignment, new_len, true);
    }
    return if (new_class == class) memory.ptr else null;
}

fn free(_: *anyopaque, memory: []u8, alignment: Alignment, _: usize) void {
    const class = sizeClassIndex(memory.len, alignment);
    if (class >= size_class_count) {
        @branchHint(.unlikely);
        return PageAllocator.unmap(@alignCast(memory));
    }
    const node: *usize = @ptrCast(@alignCast(memory.ptr));
    Threaded.mutexLockUncancelable(&mutex);
    defer Threaded.mutexUnlock(&mutex);
    node.* = frees[class];
    frees[class] = @intFromPtr(node);
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
