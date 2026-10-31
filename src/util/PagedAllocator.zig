//! General-purpose allocator with free lists sharded by page, shared by all threads.
//!
//! Small blocks live in 64 KiB pages; each page holds blocks of one size class and has its own
//! free list and count of blocks handed out, so the allocator knows when a page has become empty.
//! An empty page goes back to a pool shared by all size classes; beyond a retained amount, its
//! memory is returned to the system (on Linux, macOS and the BSDs). Pages are carved from 4 MiB segments aligned to their size,
//! and the page metadata sits in the first page of the segment, so a block finds its page by
//! masking its address.
//!
//! Each size class has its own lock, and the pool has one; a thread that cannot get a lock sleeps
//! (futex). Any thread can free a block into its page, so blocks freed by one thread are reused by
//! allocations on any thread. Allocations larger than the largest size class are mapped directly,
//! and returned to the system when they are freed.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const math = std.math;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const PageAllocator = std.heap.PageAllocator;
const Mutex = std.Io.Mutex;
const Threaded = std.Io.Threaded;
const alloc_stats = @import("alloc_stats.zig");

pub const ClassScheme = enum {
    /// Powers of two from 8 bytes
    pow2,
    /// Multiples of 8 up to 64 bytes, then four classes per power of two
    fine,
};

pub const Pow2 = Paged(.pow2);
pub const Fine = Paged(.fine);

pub fn Paged(comptime scheme: ClassScheme) type {
    return struct {
        pub const allocator: Allocator = .{ .ptr = undefined, .vtable = &vtable };

        const page_len = 64 * 1024;
        const segment_len = 4 * 1024 * 1024;
        const pages_per_segment = segment_len / page_len;
        /// Empty pages kept committed for reuse before memory is returned to the system
        const retain_pages = 256;

        const sizes: []const u32 = classSizes(scheme);
        const class_count = sizes.len;
        const max_small = sizes[class_count - 1];

        const Page = struct {
            /// Free list of blocks freed in this page; the link is stored in the block
            free: usize = 0,
            /// Links in the class's list of pages with room, or in a pool list (`next` only)
            prev: ?*Page = null,
            next: ?*Page = null,
            /// Blocks handed out
            used: u32 = 0,
            /// Blocks carved from the start of the page so far; the rest has not been touched
            carved: u32 = 0,
            size: u32 = 0,
            capacity: u32 = 0,
            /// Bytes from the start of the page that have been touched, in whole system pages;
            /// kept while the page is reused, cleared when its memory is returned to the system
            touched: u32 = 0,
            /// In the class's list of pages with room
            listed: bool = false,
        };

        /// Header in the first page of each segment, which is not used for blocks
        const Segment = struct { pages: [pages_per_segment]Page };
        comptime {
            assert(@sizeOf(Segment) <= page_len);
        }

        const Class = struct {
            _: void align(std.atomic.cache_line) = {},
            mutex: Mutex = .init,
            /// Pages with room; allocation takes from the head
            head: ?*Page = null,
            pages: std.atomic.Value(usize) = .init(0),
            live: std.atomic.Value(usize) = .init(0),
            allocs: std.atomic.Value(u64) = .init(0),
        };

        var classes: [class_count]Class = @splat(.{});

        var pool_mutex: Mutex = .init;
        /// Empty pages whose memory is still committed (linked through `next`)
        var empty: ?*Page = null;
        var empty_count: std.atomic.Value(usize) = .init(0);
        /// Empty pages whose memory was returned to the system
        var decommitted: ?*Page = null;
        var decommitted_count: std.atomic.Value(usize) = .init(0);
        /// Next page never handed out; 0 or a segment boundary means a new segment is needed
        var fresh: usize = 0;
        var large_bytes: std.atomic.Value(usize) = .init(0);
        /// Bytes of segment headers and of the touched parts of pages
        var touched_bytes: std.atomic.Value(usize) = .init(0);

        const vtable: Allocator.VTable = .{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };

        fn alloc(_: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
            const class = classOf(len, alignment);
            if (class >= class_count) {
                @branchHint(.unlikely);
                const p = PageAllocator.map(len, alignment) orelse return null;
                _ = large_bytes.fetchAdd(len, .monotonic);
                return p;
            }
            const c = &classes[class];
            Threaded.mutexLockUncancelable(&c.mutex);
            defer Threaded.mutexUnlock(&c.mutex);
            const page = c.head orelse newPage(c, class) orelse return null;
            var addr = page.free;
            if (addr != 0) {
                page.free = @as(*usize, @ptrFromInt(addr)).*;
            } else {
                addr = pageBase(page) + @as(usize, page.carved) * page.size;
                page.carved += 1;
                const end = std.mem.alignForward(u32, page.carved * page.size, std.heap.page_size_min);
                if (end > page.touched) {
                    _ = touched_bytes.fetchAdd(end - page.touched, .monotonic);
                    page.touched = end;
                }
            }
            page.used += 1;
            if (page.free == 0 and page.carved == page.capacity) unlist(c, page);
            _ = c.live.fetchAdd(1, .monotonic);
            _ = c.allocs.fetchAdd(1, .monotonic);
            return @ptrFromInt(addr);
        }

        fn resize(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) bool {
            const class = classOf(memory.len, alignment);
            const new_class = classOf(new_len, alignment);
            if (class >= class_count) {
                if (new_class < class_count) return false;
                if (PageAllocator.realloc(memory, alignment, new_len, false) == null) return false;
                adjustLarge(memory.len, new_len);
                return true;
            }
            return new_class == class;
        }

        fn remap(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) ?[*]u8 {
            const class = classOf(memory.len, alignment);
            const new_class = classOf(new_len, alignment);
            if (class >= class_count) {
                if (new_class < class_count) return null;
                const p = PageAllocator.realloc(memory, alignment, new_len, true) orelse return null;
                adjustLarge(memory.len, new_len);
                return p;
            }
            return if (new_class == class) memory.ptr else null;
        }

        fn free(_: *anyopaque, memory: []u8, alignment: Alignment, _: usize) void {
            const class = classOf(memory.len, alignment);
            if (class >= class_count) {
                @branchHint(.unlikely);
                _ = large_bytes.fetchSub(memory.len, .monotonic);
                return PageAllocator.unmap(@alignCast(memory));
            }
            const addr = @intFromPtr(memory.ptr);
            const page = pageOf(addr);
            assert(page.size == sizes[class]);
            const c = &classes[class];
            Threaded.mutexLockUncancelable(&c.mutex);
            @as(*usize, @ptrFromInt(addr)).* = page.free;
            page.free = addr;
            page.used -= 1;
            _ = c.live.fetchSub(1, .monotonic);
            if (!page.listed) {
                list(c, page);
            } else if (page.used == 0 and !(c.head == page and page.next == null)) {
                // The class keeps its last page with room, so that a class whose blocks are all
                // freed does not get and return a page on every allocation
                unlist(c, page);
                _ = c.pages.fetchSub(1, .monotonic);
                Threaded.mutexUnlock(&c.mutex);
                return releasePage(page);
            }
            Threaded.mutexUnlock(&c.mutex);
        }

        fn newPage(c: *Class, class: usize) ?*Page {
            const page = acquirePage() orelse return null;
            const size = sizes[class];
            page.* = .{ .size = size, .capacity = page_len / size, .touched = page.touched };
            list(c, page);
            _ = c.pages.fetchAdd(1, .monotonic);
            return page;
        }

        fn list(c: *Class, page: *Page) void {
            assert(!page.listed);
            page.prev = null;
            page.next = c.head;
            if (c.head) |h| h.prev = page;
            c.head = page;
            page.listed = true;
        }

        fn unlist(c: *Class, page: *Page) void {
            assert(page.listed);
            if (page.prev) |p| p.next = page.next else c.head = page.next;
            if (page.next) |n| n.prev = page.prev;
            page.prev = null;
            page.next = null;
            page.listed = false;
        }

        fn acquirePage() ?*Page {
            Threaded.mutexLockUncancelable(&pool_mutex);
            defer Threaded.mutexUnlock(&pool_mutex);
            if (empty) |p| {
                empty = p.next;
                _ = empty_count.fetchSub(1, .monotonic);
                return p;
            }
            if (decommitted) |p| {
                decommitted = p.next;
                _ = decommitted_count.fetchSub(1, .monotonic);
                return p;
            }
            if (fresh % segment_len == 0) {
                const segment = PageAllocator.map(segment_len, .fromByteUnits(segment_len)) orelse return null;
                fresh = @intFromPtr(segment) + page_len;
                _ = touched_bytes.fetchAdd(std.mem.alignForward(usize, @sizeOf(Segment), std.heap.page_size_min), .monotonic);
            }
            const p = pageOf(fresh);
            fresh += page_len;
            return p;
        }

        fn releasePage(page: *Page) void {
            Threaded.mutexLockUncancelable(&pool_mutex);
            if (empty_count.load(.monotonic) < retain_pages) {
                page.next = empty;
                empty = page;
                _ = empty_count.fetchAdd(1, .monotonic);
                return Threaded.mutexUnlock(&pool_mutex);
            }
            Threaded.mutexUnlock(&pool_mutex);
            decommit(pageBase(page));
            _ = touched_bytes.fetchSub(page.touched, .monotonic);
            page.touched = 0;
            Threaded.mutexLockUncancelable(&pool_mutex);
            defer Threaded.mutexUnlock(&pool_mutex);
            page.next = decommitted;
            decommitted = page;
            _ = decommitted_count.fetchAdd(1, .monotonic);
        }

        /// Returns the memory of a page to the system; it reads as zeros when touched again
        fn decommit(base: usize) void {
            const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(base);
            switch (builtin.os.tag) {
                .linux => posix.madvise(ptr, page_len, posix.MADV.DONTNEED) catch {},
                // On macOS, pages released with `madvise` (`DONTNEED`, `FREE`, `FREE_REUSABLE`)
                // still count in the resident size; replacing the mapping releases them at once
                .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => _ = posix.mmap(
                    ptr,
                    page_len,
                    .{ .READ = true, .WRITE = true },
                    .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true },
                    -1,
                    0,
                ) catch {},
                else => {},
            }
        }

        fn adjustLarge(old: usize, new: usize) void {
            if (new > old) _ = large_bytes.fetchAdd(new - old, .monotonic) else _ = large_bytes.fetchSub(old - new, .monotonic);
        }

        fn pageOf(addr: usize) *Page {
            const segment = addr & ~@as(usize, segment_len - 1);
            const s: *Segment = @ptrFromInt(segment);
            return &s.pages[(addr - segment) / page_len];
        }

        fn pageBase(page: *Page) usize {
            const segment = @intFromPtr(page) & ~@as(usize, segment_len - 1);
            const index = (@intFromPtr(page) - segment - @offsetOf(Segment, "pages")) / @sizeOf(Page);
            return segment + index * page_len;
        }

        /// The smallest class whose size is at least `len` and a multiple of the alignment;
        /// `class_count` for allocations that are mapped directly
        fn classOf(len: usize, alignment: Alignment) usize {
            const a = alignment.toByteUnits();
            const n = @max(len, a);
            if (n > max_small) return class_count;
            var class = sizeClass(n);
            while (sizes[class] % a != 0) class += 1;
            return class;
        }

        fn sizeClass(n: usize) usize {
            assert(n >= 1 and n <= max_small);
            switch (scheme) {
                .pow2 => return @max(@bitSizeOf(usize) - @clz(n - 1), 3) - 3,
                .fine => {
                    if (n <= 64) return (n + 7) / 8 - 1;
                    const b: usize = math.log2_int(usize, n - 1);
                    return 8 + (b - 6) * 4 + ((n - 1 - (@as(usize, 1) << @intCast(b))) >> @intCast(b - 2));
                },
            }
        }

        pub fn stats(arena: Allocator) !alloc_stats.Stats {
            const out = try arena.alloc(alloc_stats.Class, class_count);
            var s: alloc_stats.Stats = .{ .classes = out };
            for (&classes, sizes, out) |*c, size, *o| {
                o.* = .{
                    .size = size,
                    .bytes = c.pages.load(.monotonic) * page_len,
                    .live = c.live.load(.monotonic),
                    .allocs = c.allocs.load(.monotonic),
                };
                s.small_bytes += o.bytes;
                s.slot_bytes += o.live * size;
            }
            s.empty_bytes = empty_count.load(.monotonic) * page_len;
            s.decommitted_bytes = decommitted_count.load(.monotonic) * page_len;
            s.large_bytes = large_bytes.load(.monotonic);
            s.touched_bytes = touched_bytes.load(.monotonic);
            return s;
        }
    };
}

fn classSizes(comptime scheme: ClassScheme) []const u32 {
    comptime {
        var out: []const u32 = &.{};
        switch (scheme) {
            .pow2 => {
                var s: u32 = 8;
                while (s <= 32 * 1024) : (s *= 2) out = out ++ [_]u32{s};
            },
            .fine => {
                var s: u32 = 8;
                while (s <= 64) : (s += 8) out = out ++ [_]u32{s};
                var p: u32 = 64;
                while (p < 32 * 1024) : (p *= 2) {
                    for (5..9) |k| out = out ++ [_]u32{p / 4 * k};
                }
            },
        }
        const final = out[0..out.len].*;
        return &final;
    }
}

fn testClasses(comptime P: type) !void {
    // Every request maps to the smallest class that fits it and is a multiple of the alignment
    for ([_]usize{ 1, 2, 4, 8, 16, 32, 64, 4096 }) |a| {
        const alignment: Alignment = .fromByteUnits(a);
        var n: usize = 1;
        while (n <= P.max_small) : (n += 1) {
            const class = P.classOf(n, alignment);
            if (@max(n, a) > P.max_small) {
                try std.testing.expectEqual(P.class_count, class);
                continue;
            }
            const size = P.sizes[class];
            try std.testing.expect(size >= n and size % a == 0);
            if (class > 0 and P.sizes[class - 1] >= n) try std.testing.expect(P.sizes[class - 1] % a != 0);
        }
    }
    try std.testing.expectEqual(P.class_count, P.classOf(P.max_small + 1, .@"1"));
}

fn testCrossThread(comptime P: type) !void {
    const a = P.allocator;
    const first = try a.alloc(u8, 100);
    const addr = @intFromPtr(first.ptr);
    const T = struct {
        fn run(mem: []u8) void {
            P.allocator.free(mem);
        }
    };
    const t = try std.Thread.spawn(.{}, T.run, .{first});
    t.join();
    const again = try a.alloc(u8, 100);
    defer a.free(again);
    try std.testing.expectEqual(addr, @intFromPtr(again.ptr));
}

fn testConcurrent(comptime P: type) !void {
    const T = struct {
        fn run(seed: u8) void {
            var held: [256][]u8 = undefined;
            for (0..20) |_| {
                for (&held, 0..) |*h, i| {
                    const len = 1 + (i * 37 + seed) % 40000;
                    h.* = P.allocator.alloc(u8, len) catch unreachable;
                    @memset(h.*, seed);
                }
                for (held) |h| {
                    for (h) |b| assert(b == seed);
                    P.allocator.free(h);
                }
            }
        }
    };
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, T.run, .{@as(u8, @intCast(i + 1))});
    for (threads) |t| t.join();
}

fn testRelease(comptime P: type) !void {
    // Freeing many pages' worth of blocks returns pages beyond the retained amount to the system,
    // and the memory is usable again afterwards
    const a = P.allocator;
    const n = (P.retain_pages + 64) * (P.page_len / 1024);
    const blocks = try std.testing.allocator.alloc([]u8, n);
    defer std.testing.allocator.free(blocks);
    for (blocks) |*b| {
        b.* = try a.alloc(u8, 1024);
        @memset(b.*, 0xaa);
    }
    const before = P.decommitted_count.load(.monotonic);
    for (blocks) |b| a.free(b);
    try std.testing.expect(P.decommitted_count.load(.monotonic) >= before + 63);
    for (blocks) |*b| {
        b.* = try a.alloc(u8, 1024);
        @memset(b.*, 0x55);
    }
    for (blocks) |b| {
        for (b) |x| try std.testing.expectEqual(0x55, x);
        a.free(b);
    }
}

test "pow2: size classes" {
    try testClasses(Pow2);
}
test "fine: size classes" {
    try testClasses(Fine);
}
test "pow2: blocks freed on one thread are reused by allocations on another" {
    try testCrossThread(Pow2);
}
test "fine: blocks freed on one thread are reused by allocations on another" {
    try testCrossThread(Fine);
}
test "pow2: concurrent allocation and free keep blocks intact" {
    try testConcurrent(Pow2);
}
test "fine: concurrent allocation and free keep blocks intact" {
    try testConcurrent(Fine);
}
test "pow2: empty pages return to the system" {
    try testRelease(Pow2);
}
test "fine: empty pages return to the system" {
    try testRelease(Fine);
}
test "large allocations bypass size classes" {
    const big = try Fine.allocator.alloc(u8, Fine.max_small + 1);
    defer Fine.allocator.free(big);
    big[Fine.max_small] = 1;
    try std.testing.expect(std.mem.isAligned(@intFromPtr(big.ptr), std.heap.page_size_min));
}
