//! General-purpose allocator of release builds: small blocks live in pages shared by all threads,
//! and pages that become empty are returned to the system.
//!
//! Memory for small blocks is mapped in segments of `segment_len` bytes, aligned to their size and
//! split into pages of `page_len` bytes; the first page of a segment holds the descriptors of the
//! others, so a block finds its page by masking its address. A page holds the blocks of one size
//! class and has its own free list and count of blocks in use, so the allocator knows when it
//! becomes empty: it then goes to a pool shared by all size classes, which keeps up to `pool_keep`
//! empty pages committed and returns the others to the system. Blocks carry no header: the size
//! class follows from the length and alignment passed to every `Allocator` call.
//!
//! The server's cached values are allocated on worker threads and freed on the threads that run
//! sweeps and write transactions. A heap split by thread (`std.heap.SmpAllocator`) leaves the freed
//! blocks out of reach of the allocating threads, so here a block freed by any thread can be reused
//! by any thread: each size class has a lock and lists of its pages with room (see `Class`), and
//! the pool has its own lock, taken after a class lock. Pages are returned to the system and backed again
//! without the pool lock, so that these system calls do not hold up the classes that need a page.
//! A thread that cannot get a lock sleeps (futex). Allocations larger than `max_small` are mapped
//! directly and unmapped when they are freed.
//!
//! Returning a page to the system: `madvise(MADV_DONTNEED)` on Linux; on macOS and the BSDs a new
//! mapping replaces the page, since `madvise` does not lower the resident memory at once on macOS;
//! on Windows a segment is only reserved, and its pages are committed when the pool hands them out
//! and decommitted when it returns them.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const math = std.math;
const posix = std.posix;
const windows = std.os.windows;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const PageAllocator = std.heap.PageAllocator;
const Mutex = std.Io.Mutex;
const Threaded = std.Io.Threaded;

const native_os = builtin.os.tag;
const segment_len = 4 * 1024 * 1024;
const page_len = 64 * 1024;
const pages_per_segment = segment_len / page_len;
/// Largest block served from pages, so that every page holds at least two blocks
const max_small = page_len / 2;
/// Empty pages the pool keeps committed for reuse; it returns the others to the system
const pool_keep = 256;

/// How empty pages are returned to the system; on other systems the pool keeps them all
const decommit_kind: enum { madvise, remap, windows, none } = switch (native_os) {
    .linux => .madvise,
    .windows => .windows,
    .freebsd, .openbsd, .netbsd, .dragonfly => .remap,
    else => if (native_os.isDarwin()) .remap else .none,
};

/// Multiples of 8 up to 64 B, then four classes per power of two up to `max_small`: rounding a
/// length up to its class wastes at most 20% of the block
const sizes = blk: {
    var s: [44]u32 = undefined;
    for (0..8) |i| s[i] = 8 * (i + 1);
    for (0..9) |e| {
        const base = 64 << e;
        for (0..4) |k| s[8 + e * 4 + k] = base + (k + 1) * (base / 4);
    }
    assert(s[s.len - 1] == max_small);
    break :blk s;
};
const class_count = sizes.len;

/// Pages are grouped by occupancy: bin `i` holds the pages whose blocks in use are at least
/// `i / bins` and less than `(i + 1) / bins` of the blocks they can hold, so bin `bins` holds the
/// full pages
const bins = 8;

/// `ceil(2^32 * bins / blocks per page)` of each class, so that `binOf` needs no division; the
/// product is exact because the fraction `live * bins / blocks` stays at least `1 / blocks` away
/// from the next integer, which is more than the rounding adds
const bin_factors = blk: {
    var f: [class_count]u64 = undefined;
    for (sizes, &f) |size, *x| x.* = ((@as(u64, bins) << 32) + page_len / size - 1) / (page_len / size);
    break :blk f;
};

fn binOf(live: u32, ci: usize) u8 {
    return @intCast((live * bin_factors[ci]) >> 32);
}

/// The smallest class whose size is at least `len` and a multiple of the alignment, so that the
/// blocks carved from the start of a page are aligned; `class_count` for allocations that are
/// mapped directly
fn classIndex(len: usize, alignment: Alignment) usize {
    const a = alignment.toByteUnits();
    const n = @max(len, a);
    if (n > max_small) return class_count;
    var i: usize = if (n <= 64) (n + 7) / 8 - 1 else blk: {
        // 2^e < n <= 2^(e+1), and the four classes above 2^e are 2^(e-2) apart
        const e: usize = math.log2_int(usize, n - 1);
        break :blk 8 + (e - 6) * 4 + ((n - 1 - (@as(usize, 1) << @intCast(e))) >> @intCast(e - 2));
    };
    // Powers of two up to `max_small` are classes, so this ends within four steps
    while (sizes[i] % a != 0) i += 1;
    return i;
}

const Page = struct {
    /// Address of the first freed block (0 when there is none); each freed block stores the
    /// address of the next one
    free: usize,
    /// Bytes carved from the start of the page since it was assigned to its class
    carved: u32,
    /// Bytes from the start of the page that have been touched, in whole system pages; kept while
    /// the page stays committed, cleared when it is returned to the system
    touched: u32,
    /// Blocks handed out and not freed yet
    live: u32,
    class: u8,
    /// Occupancy bin (see `bins`)
    bin: u8,
    state: enum(u8) { with_room, full, pooled },
    /// Links in the list of the class's pages with room, or in a pool list (`next` only)
    prev: ?*Page,
    next: ?*Page,
};

/// The first page of a segment; its own descriptor is unused
const Segment = struct { pages: [pages_per_segment]Page };

comptime {
    assert(@sizeOf(Segment) <= page_len);
}

fn pageOf(addr: usize) *Page {
    const segment: *Segment = @ptrFromInt(addr & ~@as(usize, segment_len - 1));
    return &segment.pages[(addr & (segment_len - 1)) / page_len];
}

fn pageAddress(page: *const Page) usize {
    const segment = @intFromPtr(page) & ~@as(usize, segment_len - 1);
    return segment + (@intFromPtr(page) - segment) / @sizeOf(Page) * page_len;
}

/// Bytes of the segment header that are committed and touched
fn headerLen() usize {
    return std.mem.alignForward(usize, @sizeOf(Segment), std.heap.pageSize());
}

/// Maps a segment aligned to its size; on Windows only its header is committed
fn mapSegment() ?usize {
    if (native_os != .windows) {
        const segment = PageAllocator.map(segment_len, .fromByteUnits(segment_len)) orelse return null;
        // With transparent huge pages set to `always`, the first touch of a page would back the
        // whole 2 MiB around it: pages are handed out one by one, so resident memory would stay
        // far above what they use, and returning a page would split the huge page first
        if (native_os == .linux) posix.madvise(@alignCast(segment), segment_len, posix.MADV.NOHUGEPAGE) catch {};
        return @intFromPtr(segment);
    }
    // The segment is reserved rather than committed as `PageAllocator` would do: its pages are
    // committed one by one when the pool hands them out. To find a range aligned to the segment
    // size, reserve twice the size, release it and reserve the aligned part; another thread may
    // take that range in between
    const process = windows.GetCurrentProcess();
    while (true) {
        var base: ?*anyopaque = null;
        var size: windows.SIZE_T = 2 * segment_len;
        if (windows.ntdll.NtAllocateVirtualMemory(process, @ptrCast(&base), 0, &size, .{ .RESERVE = true }, .{ .NOACCESS = true }) != .SUCCESS) return null;
        const aligned = std.mem.alignForward(usize, @intFromPtr(base), segment_len);
        size = 0;
        _ = windows.ntdll.NtFreeVirtualMemory(process, @ptrCast(&base), &size, .{ .RELEASE = true });
        base = @ptrFromInt(aligned);
        size = segment_len;
        if (windows.ntdll.NtAllocateVirtualMemory(process, @ptrCast(&base), 0, &size, .{ .RESERVE = true }, .{ .NOACCESS = true }) != .SUCCESS) continue;
        if (commit(aligned, headerLen())) return aligned;
        size = 0;
        _ = windows.ntdll.NtFreeVirtualMemory(process, @ptrCast(&base), &size, .{ .RELEASE = true });
        return null;
    }
}

/// Backs a range of a segment with memory: needed only on Windows, where segments are reserved;
/// elsewhere a page is backed when it is first touched
fn commit(addr: usize, len: usize) bool {
    if (native_os != .windows) return true;
    var base: ?*anyopaque = @ptrFromInt(addr);
    var size: windows.SIZE_T = len;
    return windows.ntdll.NtAllocateVirtualMemory(windows.GetCurrentProcess(), @ptrCast(&base), 0, &size, .{ .COMMIT = true }, .{ .READWRITE = true }) == .SUCCESS;
}

/// Returns the memory of a page to the system; the page reads as zeros when it is committed and
/// touched again
fn decommit(addr: usize) void {
    switch (decommit_kind) {
        .madvise => posix.madvise(@ptrFromInt(addr), page_len, posix.MADV.DONTNEED) catch {},
        .remap => _ = posix.mmap(@ptrFromInt(addr), page_len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true }, -1, 0) catch {},
        .windows => {
            var base: ?*anyopaque = @ptrFromInt(addr);
            var size: windows.SIZE_T = page_len;
            _ = windows.ntdll.NtFreeVirtualMemory(windows.GetCurrentProcess(), @ptrCast(&base), &size, .{ .DECOMMIT = true });
        },
        .none => unreachable,
    }
}

const Class = struct {
    mutex: Mutex align(std.atomic.cache_line) = .init,
    /// Pages with room, the one to allocate from first: the page that most recently got room, so
    /// that the blocks freed last, which are likely still cached, are reused first
    head: ?*Page = null,
    /// Pages with room that are in bin 0 (less than an eighth of their blocks in use), used only
    /// when `head` is empty. After a transient peak, most pages keep only a few long-lived
    /// blocks; allocating into them would keep them from becoming empty when those blocks are
    /// freed, while sparing them lets them go back to the pool
    sparse: ?*Page = null,
    /// Length of the `head` and `sparse` lists
    with_room: u32 = 0,
    /// Pages assigned to the class, with room or full
    pages: usize = 0,
    /// Blocks handed out and not freed yet
    live: usize = 0,
    /// Allocations served so far
    allocs: u64 = 0,
    /// Pages assigned to the class by occupancy bin
    occupancy: [bins + 1]u32 = @splat(0),

    /// The list a page with room belongs to
    fn listOf(c: *Class, page: *const Page) *?*Page {
        return if (page.bin == 0) &c.sparse else &c.head;
    }

    fn push(c: *Class, page: *Page) void {
        const head = c.listOf(page);
        page.prev = null;
        page.next = head.*;
        if (head.*) |h| h.prev = page;
        head.* = page;
        c.with_room += 1;
    }

    fn remove(c: *Class, page: *Page) void {
        if (page.prev) |p| p.next = page.next else c.listOf(page).* = page.next;
        if (page.next) |n| n.prev = page.prev;
        c.with_room -= 1;
    }

    /// Moves a page to the bin of its count of blocks in use, and a page with room to the list
    /// of that bin
    fn rebin(c: *Class, page: *Page) void {
        const bin = binOf(page.live, page.class);
        if (bin == page.bin) return;
        c.occupancy[page.bin] -= 1;
        c.occupancy[bin] += 1;
        const moves = page.state == .with_room and (bin == 0) != (page.bin == 0);
        if (moves) c.remove(page);
        page.bin = bin;
        if (moves) c.push(page);
    }
};

var classes: [class_count]Class = @splat(.{});

const Pool = struct {
    mutex: Mutex = .init,
    /// Empty pages kept committed, the most recently emptied first
    kept: ?*Page = null,
    kept_count: usize = 0,
    /// Empty pages returned to the system
    returned: ?*Page = null,
    returned_count: usize = 0,
    /// Next page of the newest segment that was never handed out; a multiple of `segment_len`
    /// once that segment is used up
    fresh: usize = 0,
    segments: usize = 0,
    /// Pages assigned to classes, and the most there have been
    in_use: usize = 0,
    peak: usize = 0,
};

var pool: Pool = .{};
/// Segment headers, plus the touched parts of the pages that are committed (see `Page.touched`)
var resident: std.atomic.Value(usize) = .init(0);
/// Pages returned to the system so far, and pages taken back after being returned
var decommits: std.atomic.Value(u64) = .init(0);
var recommits: std.atomic.Value(u64) = .init(0);
/// Bytes mapped for large allocations
var large: std.atomic.Value(usize) = .init(0);

pub const allocator: Allocator = .{ .ptr = undefined, .vtable = &vtable };

const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

fn alloc(_: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const ci = classIndex(len, alignment);
    if (ci == class_count) {
        @branchHint(.unlikely);
        const p = PageAllocator.map(len, alignment) orelse return null;
        _ = large.fetchAdd(mappedLen(len), .monotonic);
        return p;
    }
    const size = sizes[ci];
    const c = &classes[ci];
    Threaded.mutexLockUncancelable(&c.mutex);
    defer Threaded.mutexUnlock(&c.mutex);
    const page = c.head orelse c.sparse orelse page: {
        const p = takePage() orelse return null;
        p.* = .{ .free = 0, .carved = 0, .touched = p.touched, .live = 0, .class = @intCast(ci), .bin = 0, .state = .with_room, .prev = null, .next = null };
        c.push(p);
        c.pages += 1;
        c.occupancy[0] += 1;
        break :page p;
    };
    var block = page.free;
    if (block != 0) {
        page.free = @as(*const usize, @ptrFromInt(block)).*;
    } else {
        // Blocks are carved on demand, so the untouched tail of a page is never backed
        block = pageAddress(page) + page.carved;
        page.carved += size;
        if (page.carved > page.touched) {
            const end: u32 = @intCast(@min(std.mem.alignForward(usize, page.carved, std.heap.pageSize()), page_len));
            _ = resident.fetchAdd(end - page.touched, .monotonic);
            page.touched = end;
        }
    }
    page.live += 1;
    c.live += 1;
    c.allocs += 1;
    c.rebin(page);
    if (page.free == 0 and page.carved + size > page_len) {
        c.remove(page);
        page.state = .full;
    }
    return @ptrFromInt(block);
}

const Source = enum { kept, returned, fresh };

/// An empty page from the pool, or a page never handed out; called with a class lock held
fn takePage() ?*Page {
    const page: *Page, const source: Source = taken: {
        Threaded.mutexLockUncancelable(&pool.mutex);
        defer Threaded.mutexUnlock(&pool.mutex);
        const taken: struct { *Page, Source } = if (pool.kept) |p| kept: {
            pool.kept = p.next;
            pool.kept_count -= 1;
            break :kept .{ p, .kept };
        } else if (pool.returned) |p| returned: {
            pool.returned = p.next;
            pool.returned_count -= 1;
            break :returned .{ p, .returned };
        } else fresh: {
            if (pool.fresh % segment_len == 0) {
                // The first page holds the header
                pool.fresh = (mapSegment() orelse return null) + page_len;
                pool.segments += 1;
                _ = resident.fetchAdd(headerLen(), .monotonic);
            }
            defer pool.fresh += page_len;
            break :fresh .{ pageOf(pool.fresh), .fresh };
        };
        pool.in_use += 1;
        pool.peak = @max(pool.peak, pool.in_use);
        break :taken taken;
    };
    if (source == .kept) return page;
    if (commit(pageAddress(page), page_len)) {
        if (source == .returned) _ = recommits.fetchAdd(1, .monotonic);
        return page;
    }
    // Not backed: the page waits in the pool with the returned ones
    Threaded.mutexLockUncancelable(&pool.mutex);
    defer Threaded.mutexUnlock(&pool.mutex);
    page.next = pool.returned;
    pool.returned = page;
    pool.returned_count += 1;
    pool.in_use -= 1;
    return null;
}

/// Hands an empty page to the pool; called with no lock held
fn releasePage(page: *Page) void {
    page.state = .pooled;
    {
        Threaded.mutexLockUncancelable(&pool.mutex);
        defer Threaded.mutexUnlock(&pool.mutex);
        pool.in_use -= 1;
        if (decommit_kind == .none or pool.kept_count < pool_keep) {
            page.next = pool.kept;
            pool.kept = page;
            pool.kept_count += 1;
            return;
        }
    }
    decommit(pageAddress(page));
    _ = resident.fetchSub(page.touched, .monotonic);
    page.touched = 0;
    _ = decommits.fetchAdd(1, .monotonic);
    Threaded.mutexLockUncancelable(&pool.mutex);
    defer Threaded.mutexUnlock(&pool.mutex);
    page.next = pool.returned;
    pool.returned = page;
    pool.returned_count += 1;
}

fn free(_: *anyopaque, memory: []u8, alignment: Alignment, _: usize) void {
    const ci = classIndex(memory.len, alignment);
    if (ci == class_count) {
        @branchHint(.unlikely);
        _ = large.fetchSub(mappedLen(memory.len), .monotonic);
        return PageAllocator.unmap(@alignCast(memory));
    }
    const page = pageOf(@intFromPtr(memory.ptr));
    const c = &classes[ci];
    {
        Threaded.mutexLockUncancelable(&c.mutex);
        defer Threaded.mutexUnlock(&c.mutex);
        assert(page.class == ci and page.state != .pooled);
        const node: *usize = @ptrCast(@alignCast(memory.ptr));
        node.* = page.free;
        page.free = @intFromPtr(node);
        page.live -= 1;
        c.live -= 1;
        c.rebin(page);
        if (page.state == .full) {
            page.state = .with_room;
            c.push(page);
        }
        // The class keeps its last page with room, so that a class whose blocks are all freed
        // does not move a page through the pool on every allocation
        if (page.live != 0 or c.with_room == 1) return;
        c.remove(page);
        c.pages -= 1;
        c.occupancy[0] -= 1;
    }
    releasePage(page);
}

fn resize(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) bool {
    return realloc(memory, alignment, new_len, false) != null;
}

fn remap(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) ?[*]u8 {
    return realloc(memory, alignment, new_len, true);
}

/// A small block keeps its place while the length stays in its class; a large one is remapped
fn realloc(memory: []u8, alignment: Alignment, new_len: usize, may_move: bool) ?[*]u8 {
    const ci = classIndex(memory.len, alignment);
    const new_ci = classIndex(new_len, alignment);
    if (ci < class_count) return if (new_ci == ci) memory.ptr else null;
    if (new_ci < class_count) return null;
    const p = PageAllocator.realloc(memory, alignment, new_len, may_move) orelse return null;
    const old = mappedLen(memory.len);
    const new = mappedLen(new_len);
    if (new > old) _ = large.fetchAdd(new - old, .monotonic) else _ = large.fetchSub(old - new, .monotonic);
    return p;
}

fn mappedLen(len: usize) usize {
    return std.mem.alignForward(usize, len, std.heap.pageSize());
}

/// Memory held by the allocator (`zig-analyzer/status`; bytes, except the counts)
pub const Stats = struct {
    /// Pages assigned to size classes
    small: usize,
    /// The most memory assigned to size classes at once
    peak_small: usize,
    /// Memory of the small blocks that is backed: segment headers, and the touched parts of the
    /// assigned and retained pages
    resident: usize,
    /// Live small blocks, counted by the size of their class
    live_slots: usize,
    /// Empty pages kept committed for reuse
    retained: usize,
    /// Empty pages returned to the system; their address range stays reserved
    returned: usize,
    /// Segments mapped
    segments: usize,
    /// Pages returned to the system so far, and pages taken back after being returned (counts)
    decommits: u64,
    recommits: u64,
    /// Live large allocations, mapped directly (rounded up to whole system pages)
    large: usize,
    /// Pages assigned to size classes by occupancy (see `bins`): element `i` counts the pages
    /// whose blocks in use are at least `i / 8` of the blocks they can hold and less than
    /// `(i + 1) / 8`, the last one the full pages
    occupancy: [bins + 1]usize,
    classes: []const SizeClass,

    pub const SizeClass = struct {
        size: u32,
        /// Pages assigned to the class
        pages: usize,
        /// Blocks handed out and not freed yet
        live: usize,
        /// Allocations served so far
        allocs: u64,
        /// Pages of the class by occupancy, as `Stats.occupancy`
        occupancy: [bins + 1]u32,
    };
};

pub fn stats(arena: Allocator) Allocator.Error!Stats {
    const out = try arena.alloc(Stats.SizeClass, class_count);
    var small: usize = 0;
    var live_slots: usize = 0;
    var occupancy: [bins + 1]usize = @splat(0);
    for (&classes, sizes, out) |*c, size, *o| {
        Threaded.mutexLockUncancelable(&c.mutex);
        defer Threaded.mutexUnlock(&c.mutex);
        o.* = .{ .size = size, .pages = c.pages * page_len, .live = c.live, .allocs = c.allocs, .occupancy = c.occupancy };
        small += c.pages * page_len;
        live_slots += c.live * size;
        for (&occupancy, c.occupancy) |*t, n| t.* += n;
    }
    Threaded.mutexLockUncancelable(&pool.mutex);
    defer Threaded.mutexUnlock(&pool.mutex);
    return .{
        .small = small,
        .peak_small = pool.peak * page_len,
        .resident = resident.load(.monotonic),
        .live_slots = live_slots,
        .retained = pool.kept_count * page_len,
        .returned = pool.returned_count * page_len,
        .segments = pool.segments,
        .decommits = decommits.load(.monotonic),
        .recommits = recommits.load(.monotonic),
        .large = large.load(.monotonic),
        .occupancy = occupancy,
        .classes = out,
    };
}

const testing = std.testing;

test "the size class is the smallest that fits the length and is a multiple of the alignment" {
    for ([_]usize{ 1, 2, 4, 8, 16, 32, 64, 4096, 8192, 1 << 16 }) |a| {
        for (1..max_small + 2) |len| {
            const expected = for (sizes, 0..) |size, i| {
                if (size >= len and size % a == 0) break i;
            } else class_count;
            try testing.expectEqual(expected, classIndex(len, .fromByteUnits(a)));
        }
    }
}

test "blocks freed on one thread are reused by allocations on another" {
    const first = try allocator.alloc(u8, 100);
    const addr = @intFromPtr(first.ptr);
    const t = try std.Thread.spawn(.{}, struct {
        fn run(memory: []u8) void {
            allocator.free(memory);
        }
    }.run, .{first});
    t.join();
    const again = try allocator.alloc(u8, 100);
    defer allocator.free(again);
    try testing.expectEqual(addr, @intFromPtr(again.ptr));
}

test "concurrent allocation and free keep blocks intact" {
    const T = struct {
        fn run(seed: u8) void {
            var held: [256][]u8 = undefined;
            for (0..20) |round| {
                for (&held, 0..) |*h, i| {
                    // Up to 40000 bytes: large allocations too
                    const len = 1 + (i * 37 + seed + round * 101) % 40000;
                    h.* = allocator.alloc(u8, len) catch @panic("out of memory");
                    @memset(h.*, seed);
                }
                for (held) |h| {
                    for (h) |b| if (b != seed) @panic("a block was overwritten");
                    allocator.free(h);
                }
            }
        }
    };
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, T.run, .{@as(u8, @intCast(i + 1))});
    for (threads) |t| t.join();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try stats(arena.allocator());
    try testing.expectEqual(0, s.live_slots);
    // Each class keeps at most its last page with room; the pool holds the others
    try testing.expect(s.small <= class_count * page_len);
}

test "the occupancy bin of a page is the share of its blocks in use, in eighths" {
    for (sizes, 0..) |size, ci| {
        const blocks = page_len / size;
        for (0..blocks + 1) |live| {
            try testing.expectEqual(live * bins / blocks, binOf(@intCast(live), ci));
        }
    }
    // Three blocks of 20 KiB fill a page
    const ci = classIndex(20 * 1024, .@"1");
    const c = &classes[ci];
    const before = c.occupancy;
    var b: [3]*[20 * 1024]u8 = undefined;
    for (&b) |*x| x.* = try allocator.create([20 * 1024]u8);
    try testing.expectEqual(before[bins] + 1, c.occupancy[bins]);
    allocator.destroy(b[0]);
    try testing.expectEqual(before[bins], c.occupancy[bins]);
    try testing.expectEqual(before[5] + 1, c.occupancy[5]);
    for (b[1..]) |x| allocator.destroy(x);
}

test "a page with less than an eighth of its blocks in use gets new blocks only when no other page has room" {
    // 51 blocks of 1280 B fill a page: two pages, filled one after the other
    const Block = [1280]u8;
    var b: [102]*Block = undefined;
    for (&b) |*x| x.* = try allocator.create(Block);
    var by_page: [2][51]*Block = undefined;
    var counts: [2]usize = @splat(0);
    const first = pageOf(@intFromPtr(b[0]));
    for (b) |x| {
        const i: usize = if (pageOf(@intFromPtr(x)) == first) 0 else 1;
        by_page[i][counts[i]] = x;
        counts[i] += 1;
    }
    try testing.expectEqual([2]usize{ 51, 51 }, counts);
    // The second page gets room first, then the first page keeps 5 blocks: the next block goes to
    // the second page, although the first got room last
    allocator.destroy(by_page[1][0]);
    for (by_page[0][0..46]) |x| allocator.destroy(x);
    const again = try allocator.create(Block);
    try testing.expectEqual(pageOf(@intFromPtr(by_page[1][1])), pageOf(@intFromPtr(again)));
    // With the second page full, the first gets blocks again
    const next = try allocator.create(Block);
    try testing.expectEqual(first, pageOf(@intFromPtr(next)));
    allocator.destroy(again);
    allocator.destroy(next);
    for (by_page[0][46..]) |x| allocator.destroy(x);
    for (by_page[1][1..]) |x| allocator.destroy(x);
}

test "pages emptied by one size class serve another" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // 32 pages of 4 KiB blocks: once they are freed, the class keeps one page and the pool the rest
    var small: [32 * page_len / 4096]*[4096]u8 = undefined;
    for (&small) |*b| b.* = try allocator.create([4096]u8);
    for (small) |b| allocator.destroy(b);
    const segments = (try stats(arena.allocator())).segments;
    var big: [16 * page_len / 8192]*[8192]u8 = undefined;
    for (&big) |*b| b.* = try allocator.create([8192]u8);
    defer for (big) |b| allocator.destroy(b);
    try testing.expectEqual(segments, (try stats(arena.allocator())).segments);
}

test "empty pages beyond the retained ones return to the system and are used again" {
    if (decommit_kind == .none) return error.SkipZigTest;
    const n = (pool_keep + 64) * (page_len / 1024);
    const blocks = try testing.allocator.alloc([]u8, n);
    defer testing.allocator.free(blocks);
    for (blocks) |*b| {
        b.* = try allocator.alloc(u8, 1024);
        @memset(b.*, 0xaa);
    }
    const decommits_before = decommits.load(.monotonic);
    const resident_before = resident.load(.monotonic);
    for (blocks) |b| allocator.free(b);
    // The class keeps one page and the pool 256 at most: at least 63 go back to the system
    try testing.expect(decommits.load(.monotonic) >= decommits_before + 63);
    try testing.expect(resident.load(.monotonic) <= resident_before - 63 * page_len);
    for (blocks) |*b| {
        b.* = try allocator.alloc(u8, 1024);
        @memset(b.*, 0x55);
    }
    for (blocks) |b| {
        for (b) |x| try testing.expectEqual(0x55, x);
        allocator.free(b);
    }
}

test "aligned blocks" {
    const x = try allocator.alignedAlloc(u8, .@"64", 80);
    defer allocator.free(x);
    try testing.expect(std.mem.isAligned(@intFromPtr(x.ptr), 64));
    const y = try allocator.alignedAlloc(u8, .fromByteUnits(4096), 100);
    defer allocator.free(y);
    try testing.expect(std.mem.isAligned(@intFromPtr(y.ptr), 4096));
}

test "large allocations are mapped directly and keep their contents when they grow" {
    const before = large.load(.monotonic);
    var big = try allocator.alloc(u8, max_small + 1);
    try testing.expect(std.mem.isAligned(@intFromPtr(big.ptr), std.heap.page_size_min));
    big[max_small] = 1;
    big = try allocator.realloc(big, 4 * max_small);
    try testing.expectEqual(1, big[max_small]);
    allocator.free(big);
    try testing.expectEqual(before, large.load(.monotonic));
}
