const std = @import("std");
const db = @import("engine.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;

// Dependency graph:
//   Number(k) ─┬→ Tens(k) → Plus(k)
//              └→ Text(k) (string input, tests a Value with pointers)
//   Stable(k): high durability input → OnlyStable(k)

const Number = struct {
    pub const kind: db.Kind = .input;
    pub const Key = u32;
    pub const Value = i64;
    pub const default: Value = 0;
};

const Stable = struct {
    pub const kind: db.Kind = .input;
    pub const Key = u32;
    pub const Value = i64;
    pub const default: Value = 0;
};

const Text = struct {
    pub const kind: db.Kind = .input;
    pub const Key = u32;
    pub const Value = []const u8;
    pub const default: Value = "";
    pub fn eql(a: Value, b: Value) bool {
        return std.mem.eql(u8, a, b);
    }
    pub fn deinit(v: *Value, gpa: Allocator) void {
        gpa.free(v.*);
    }
};

const Tens = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = i64;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        return @divFloor(try ctx.get(Number, key), 10);
    }
};

const Plus = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = i64;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        return try ctx.get(Tens, key) + 1;
    }
};

const Upper = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = []const u8;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        const text = try ctx.get(Text, key);
        const out = try ctx.db.gpa.alloc(u8, text.len);
        _ = std.ascii.upperString(out, text);
        return out;
    }
    pub fn eql(a: Value, b: Value) bool {
        return std.mem.eql(u8, a, b);
    }
    pub fn deinit(v: *Value, gpa: Allocator) void {
        gpa.free(v.*);
    }
};

const OnlyStable = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = i64;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        return try ctx.get(Stable, key) * 2;
    }
};

const StableTens = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = i64;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        return @divFloor(try ctx.get(Stable, key), 10);
    }
};

const StablePlus = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = i64;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        return try ctx.get(StableTens, key) + 1;
    }
};

// Cycle: CycleA(k) = CycleB(k) + 1, CycleB(k) = CycleA(k)
const CycleA = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = i64;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        return try ctx.get(CycleB, key) + 1;
    }
    pub fn cycleFallback(_: Key) Value {
        return -100;
    }
};

const CycleB = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = i64;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        return try ctx.get(CycleA, key);
    }
};

/// Recursive chain: Depth(k) = Depth(k - 1) + 1
const Depth = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = i64;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        if (key == 0) return 0;
        return try ctx.get(Depth, key - 1) + 1;
    }
    pub fn cycleFallback(_: Key) Value {
        return -1_000_000_000;
    }
};

/// Reachable set (bit set): Reach(k) = {k} ∪ the Reach of each successor.
/// Graph: 0 → 1; 1 → 0, 2; 2 → 2; 3 → 0.
const Reach = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = u8;
    pub const fixpoint = true;
    const next = [_][]const u32{ &.{1}, &.{ 0, 2 }, &.{2}, &.{0} };
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        var set: Value = @as(Value, 1) << @intCast(key);
        for (next[key]) |n| set |= try ctx.get(Reach, n);
        return set;
    }
    pub fn cycleFallback(_: Key) Value {
        return 0;
    }
    pub fn depthFallback(_: Key) Value {
        return 0xff;
    }
};

/// Reachable set on a graph described by inputs: Graph(k) = Label(k) ∪ the Graph of each successor,
/// with the successors given by the bits of Succ(k). Odd-numbered successors are read through
/// GraphVia, which is not a fixpoint query, so cycles can pass through different queries.
const Succ = struct {
    pub const kind: db.Kind = .input;
    pub const Key = u32;
    pub const Value = u32;
    pub const default: Value = 0;
};

const Label = struct {
    pub const kind: db.Kind = .input;
    pub const Key = u32;
    pub const Value = u32;
    pub const default: Value = 0;
};

const Graph = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = u32;
    pub const fixpoint = true;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        var reach = try ctx.get(Label, key);
        const succ = try ctx.get(Succ, key);
        for (0..32) |s| {
            if (succ & (@as(u32, 1) << @intCast(s)) == 0) continue;
            reach |= if (s % 2 == 1) try ctx.get(GraphVia, @intCast(s)) else try ctx.get(Graph, @intCast(s));
        }
        return reach;
    }
    pub fn cycleFallback(_: Key) Value {
        return 0;
    }
    pub fn depthFallback(_: Key) Value {
        return std.math.maxInt(Value);
    }
};

const GraphVia = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = u32;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        return ctx.get(Graph, key);
    }
    pub fn cycleFallback(_: Key) Value {
        return 0;
    }
};

/// A chain or cycle read layer by layer: Layer(k) = Label(k) ∪ Label(k + 1000) ∪ the next layer.
/// When `len` is 0, the next layer is k - 1 (down to 0), otherwise (k + 1) % len. When the result
/// is incomplete or in a cycle, after reading the next layer, the number of dependencies this frame
/// has recorded is noted in `layer_max_deps`.
const Layer = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = struct { k: u32, len: u32 = 0 };
    pub const Value = u32;
    pub const fixpoint = true;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        var reach = try ctx.get(Label, key.k) | try ctx.get(Label, key.k + 1000);
        if (key.len == 0 and key.k == 0) return reach;
        const next: Key = if (key.len == 0) .{ .k = key.k - 1 } else .{ .k = (key.k + 1) % key.len, .len = key.len };
        reach |= try ctx.get(Layer, next);
        if (ctx.incomplete()) {
            const stack = ctx.stack.items;
            layer_max_deps = @max(layer_max_deps, stack[stack.len - 1].deps.count());
        }
        return reach;
    }
    pub fn cycleFallback(_: Key) Value {
        return 0;
    }
    pub fn depthFallback(_: Key) Value {
        return std.math.maxInt(Value);
    }
};
var layer_max_deps: usize = 0;

/// A chain leading into a cycle: Lasso(k) = Label(k) ∪ the next one. For k > 10 the next one is
/// k - 1, and the cycle is 10 → 9 → ... → 0 → 10.
const Lasso = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = u32;
    pub const fixpoint = true;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        return try ctx.get(Label, key) | try ctx.get(Lasso, if (key == 0) 10 else key - 1);
    }
    pub fn cycleFallback(_: Key) Value {
        return 0;
    }
    pub fn depthFallback(_: Key) Value {
        return std.math.maxInt(Value);
    }
};

/// After reading Number, waits until canceled
const Spin = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = i64;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        const n = try ctx.get(Number, key);
        spin_started.store(true, .release);
        while (true) {
            try ctx.checkCanceled();
            std.atomic.spinLoopHint();
        }
        return n;
    }
};
var spin_started: std.atomic.Value(bool) = .init(false);

/// A write transaction arrives mid-computation, and the `Canceled` of the inner read is swallowed
/// with a fallback value
const Swallow = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = i64;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        if (swallow_cancel) ctx.db.pending_write.store(1, .release);
        return ctx.get(Number, key) catch -1;
    }
};
var swallow_cancel = false;

/// A query with an LRU capacity: the value contains pointers (must be freed on eviction)
const Cached = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = []const u8;
    pub const lru: usize = 2;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        return ctx.db.gpa.dupe(u8, try ctx.get(Text, key));
    }
    pub fn eql(a: Value, b: Value) bool {
        return std.mem.eql(u8, a, b);
    }
    pub fn deinit(v: *Value, gpa: Allocator) void {
        gpa.free(v.*);
    }
};

/// A query evicted by bytes: the count limit is large, while the byte limit fits only one value
const Sized = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = []const u8;
    pub const lru: usize = 100;
    pub const lru_bytes: usize = 10;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        return ctx.db.gpa.dupe(u8, try ctx.get(Text, key));
    }
    pub fn bytes(v: Value) usize {
        return v.len;
    }
    pub fn eql(a: Value, b: Value) bool {
        return std.mem.eql(u8, a, b);
    }
    pub fn deinit(v: *Value, gpa: Allocator) void {
        gpa.free(v.*);
    }
};

const CachedLen = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = usize;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        return (try ctx.get(Cached, key)).len;
    }
};

const Db = db.Engine(void, &.{ Number, Stable, Text, Tens, Plus, Upper, OnlyStable, StableTens, StablePlus, CycleA, CycleB, Depth, Reach, Succ, Label, Graph, GraphVia, Layer, Lasso, Spin, Swallow, Cached, Sized, CachedLen });

fn executions(d: *Db, comptime Q: type) u64 {
    return d.executions(Q);
}

fn setNumber(d: *Db, comptime Q: type, key: u32, value: Q.Value, durability: db.Durability) !void {
    d.beginWrite();
    defer d.endWrite();
    try d.set(Q, key, value, durability);
}

fn read(d: *Db, comptime Q: type, key: Q.Key) !Q.Value {
    var ctx = d.beginRead(testing.allocator);
    defer ctx.end();
    return ctx.get(Q, key);
}

test "keyCount outside and inside a transaction agree" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setNumber(&d, Number, 1, 5, .low);
    try setNumber(&d, Number, 2, 6, .low);
    // Outside of a transaction: takes the shared lock
    try testing.expectEqual(2, d.keyCount(Number));
    // Inside a write transaction: the caller already holds the exclusive lock
    d.beginWrite();
    defer d.endWrite();
    try testing.expectEqual(2, d.keyCountLocked(Number));
}

test "unset input returns default" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try testing.expectEqual(1, try read(&d, Plus, 7));
}

test "memo reused across read transactions" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setNumber(&d, Number, 1, 42, .low);

    try testing.expectEqual(5, try read(&d, Plus, 1));
    try testing.expectEqual(5, try read(&d, Plus, 1));
    try testing.expectEqual(1, executions(&d, Plus));
    try testing.expectEqual(1, executions(&d, Tens));
}

test "early cutoff: upstream not recomputed when intermediate result is unchanged" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setNumber(&d, Number, 1, 42, .low);
    try testing.expectEqual(5, try read(&d, Plus, 1));

    // 42 → 47: Tens is still 4
    try setNumber(&d, Number, 1, 47, .low);
    try testing.expectEqual(5, try read(&d, Plus, 1));
    try testing.expectEqual(2, executions(&d, Tens));
    try testing.expectEqual(1, executions(&d, Plus));

    // 47 → 51: Tens becomes 5, so Plus must be recomputed
    try setNumber(&d, Number, 1, 51, .low);
    try testing.expectEqual(6, try read(&d, Plus, 1));
    try testing.expectEqual(3, executions(&d, Tens));
    try testing.expectEqual(2, executions(&d, Plus));
}

test "setting the same input value does not bump revision" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setNumber(&d, Number, 1, 42, .low);
    const rev = d.revision;
    try setNumber(&d, Number, 1, 42, .low);
    try testing.expectEqual(rev, d.revision);
    // A write transaction that changes no value still cancels read queries and counts as a write
    var buf: [Db.query_types.len]db.QueryStats = undefined;
    try testing.expectEqual(2, d.stats(&buf).writes);
}

test "changes to unrelated keys do not trigger recomputation" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setNumber(&d, Number, 1, 42, .low);
    try testing.expectEqual(5, try read(&d, Plus, 1));
    try setNumber(&d, Number, 2, 99, .low);
    try testing.expectEqual(5, try read(&d, Plus, 1));
    try testing.expectEqual(1, executions(&d, Tens));
}

test "durability: skip dependency check of high-durability memos when low inputs change" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setNumber(&d, Stable, 1, 21, .high);
    try testing.expectEqual(42, try read(&d, OnlyStable, 1));

    try setNumber(&d, Number, 1, 5, .low);
    const before = d.deep_verifications.load(.monotonic);
    try testing.expectEqual(42, try read(&d, OnlyStable, 1));
    try testing.expectEqual(before, d.deep_verifications.load(.monotonic));
    try testing.expectEqual(1, executions(&d, OnlyStable));

    // Must be recomputed after a high-durability input changes
    try setNumber(&d, Stable, 1, 50, .high);
    try testing.expectEqual(100, try read(&d, OnlyStable, 1));
    try testing.expectEqual(2, executions(&d, OnlyStable));
}

test "durability: still invalidated after input drops from high to low" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setNumber(&d, Stable, 1, 1, .high);
    try testing.expectEqual(2, try read(&d, OnlyStable, 1));
    try setNumber(&d, Stable, 1, 2, .low);
    try testing.expectEqual(4, try read(&d, OnlyStable, 1));
    try setNumber(&d, Stable, 1, 3, .low);
    try testing.expectEqual(6, try read(&d, OnlyStable, 1));
}

test "durability: memo verified through an early cutoff takes the lowered durability" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setNumber(&d, Stable, 1, 21, .high);
    try testing.expectEqual(3, try read(&d, StablePlus, 1));
    // Lowered to low: StableTens recomputes the same value, and StablePlus is only verified
    try setNumber(&d, Stable, 1, 29, .low);
    try testing.expectEqual(3, try read(&d, StablePlus, 1));
    try testing.expectEqual(1, executions(&d, StablePlus));
    // If StablePlus still skipped the dependency check based on high durability, this would read
    // the old value 3
    try setNumber(&d, Stable, 1, 35, .low);
    try testing.expectEqual(4, try read(&d, StablePlus, 1));
}

test "Value with pointers: keep old value when equal, deferred free when changed" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    const gpa = testing.allocator;

    d.beginWrite();
    try d.set(Text, 1, try gpa.dupe(u8, "abc"), .low);
    d.endWrite();

    var ctx = d.beginRead(gpa);
    const first = try ctx.get(Upper, 1);
    try testing.expectEqualStrings("ABC", first);
    ctx.end();

    // A new string with the same content: the input is unchanged and Upper is not recomputed
    d.beginWrite();
    try d.set(Text, 1, try gpa.dupe(u8, "abc"), .low);
    d.endWrite();
    ctx = d.beginRead(gpa);
    try testing.expectEqual(first.ptr, (try ctx.get(Upper, 1)).ptr);
    ctx.end();
    try testing.expectEqual(1, executions(&d, Upper));

    d.beginWrite();
    try d.set(Text, 1, try gpa.dupe(u8, "xyz"), .low);
    d.endWrite();
    ctx = d.beginRead(gpa);
    try testing.expectEqualStrings("XYZ", try ctx.get(Upper, 1));
    ctx.end();
}

test "out of memory while committing a memo keeps the old memo intact and leaks nothing" {
    // Make the i-th allocation while recomputing Upper fail, for each i in turn: the old memo's
    // dependencies and value must not be handed over early, and the new value must not leak
    var i: usize = 0;
    while (true) : (i += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
        const gpa = failing.allocator();
        var d: Db = .init(testing.io, gpa, {});
        defer d.deinit();
        d.beginWrite();
        try d.set(Text, 1, try gpa.dupe(u8, "abc"), .low);
        d.endWrite();
        try testing.expectEqualStrings("ABC", try read(&d, Upper, 1));
        d.beginWrite();
        try d.set(Text, 1, try gpa.dupe(u8, "xyz"), .low);
        d.endWrite();

        failing.fail_index = failing.alloc_index + i;
        _ = read(&d, Upper, 1) catch |err| try testing.expectEqual(error.OutOfMemory, err);
        const induced = failing.has_induced_failure;
        failing.fail_index = std.math.maxInt(usize);

        try testing.expectEqualStrings("XYZ", try read(&d, Upper, 1));
        // The write transaction frees the garbage list: the old dependencies and value are each
        // freed only once
        d.beginWrite();
        try d.set(Text, 1, try gpa.dupe(u8, "q"), .low);
        d.endWrite();
        try testing.expectEqualStrings("Q", try read(&d, Upper, 1));
        if (!induced) break;
    }
}

test "cycle: uses cycleFallback without writing memo" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    // CycleA → CycleB → CycleA(fallback = -100), CycleB = -100, CycleA = -99
    try testing.expectEqual(-99, try read(&d, CycleA, 1));
    try testing.expectEqual(-99, try read(&d, CycleA, 1));
    try testing.expectEqual(2, executions(&d, CycleA));
}

test "fixpoint: the cycle head is complete and memoized" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    // 3 → 0 ⇄ 1 → 2 ↺: reads of the cycle head from within the cycle get the empty set, and
    // computing the cycle heads 0 and 2 once gives the complete result
    try testing.expectEqual(0b1111, try read(&d, Reach, 3));
    const before = executions(&d, Reach);
    try testing.expectEqual(0b0111, try read(&d, Reach, 0));
    try testing.expectEqual(0b0100, try read(&d, Reach, 2));
    try testing.expectEqual(before, executions(&d, Reach));
    // 1 is in the cycle of 0 and read the fallback value of 0, so it is not written to a memo:
    // reading it on its own recomputes it
    try testing.expectEqual(0b0111, try read(&d, Reach, 1));
    try testing.expectEqual(before + 1, executions(&d, Reach));
}

test "fixpoint: an older memo of a cycle member does not hide changes seen by the cycle head" {
    // Guards against the cycle head recording members of its cycle as dependencies: when a member's
    // old memo is recomputed to the same value (early cutoff), the cycle head would be wrongly
    // judged unchanged
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setNumber(&d, Label, 0, 0b1, .low);
    try setNumber(&d, Label, 2, 0b10, .low);
    try testing.expectEqual(0b10, try read(&d, Graph, 2));
    // 0 ⇄ 2: while the cycle head 0 is computed, 2 computes 0b100 within the cycle, but the memo of
    // 2 is still the earlier 0b10
    {
        d.beginWrite();
        defer d.endWrite();
        try d.set(Succ, 0, 0b100, .low);
        try d.set(Succ, 2, 0b1, .low);
        try d.set(Label, 2, 0b100, .low);
    }
    try testing.expectEqual(0b101, try read(&d, Graph, 0));
    // When 2 is recomputed to the same value as its old memo (early cutoff), the cycle head must
    // still see the change
    {
        d.beginWrite();
        defer d.endWrite();
        try d.set(Succ, 2, 0, .low);
        try d.set(Label, 2, 0b10, .low);
    }
    try testing.expectEqual(0b11, try read(&d, Graph, 0));
}

/// Cycle k → k + 1 (mod n), plus k → k + 2 when `dense`; Label(k) = {k}
fn setRing(d: *Db, n: u32, dense: bool) !void {
    d.beginWrite();
    defer d.endWrite();
    for (0..n) |k| {
        var succ: u32 = @as(u32, 1) << @intCast((k + 1) % n);
        if (dense) succ |= @as(u32, 1) << @intCast((k + 2) % n);
        try d.set(Succ, @intCast(k), succ, .low);
        try d.set(Label, @intCast(k), @as(u32, 1) << @intCast(k), .low);
    }
}

fn graphExecutions(d: *Db) u64 {
    return executions(d, Graph) + executions(d, GraphVia);
}

test "fixpoint: an unrelated change does not recompute a cycle whose members are memoized" {
    // Guards against the cycle head and the memos of separately read members depending on each
    // other: every later verification would then recurse around the memo cycle up to the stack
    // limit, and the number of recomputations would grow exponentially with the size of the cycle
    for ([_]struct { n: u32, dense: bool }{ .{ .n = 16, .dense = false }, .{ .n = 8, .dense = true } }) |c| {
        var d: Db = .init(testing.io, testing.allocator, {});
        defer d.deinit();
        try setRing(&d, c.n, c.dense);
        const all = (@as(u32, 1) << @intCast(c.n)) - 1;
        for (0..c.n) |k| try testing.expectEqual(all, try read(&d, Graph, @intCast(k)));
        for (0..3) |i| {
            try setNumber(&d, Number, 99, @intCast(i), .low);
            const execs = graphExecutions(&d);
            const deep = d.deep_verifications.load(.monotonic);
            for (0..c.n) |k| try testing.expectEqual(all, try read(&d, Graph, @intCast(k)));
            try testing.expectEqual(execs, graphExecutions(&d));
            // Each memo is verified only once
            try testing.expect(d.deep_verifications.load(.monotonic) - deep <= 2 * c.n);
        }
    }
    // Reading only the cycle head: verification does not recompute the members one by one and write
    // them to memos
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setRing(&d, 12, false);
    try testing.expectEqual(0xfff, try read(&d, Graph, 0));
    const execs = graphExecutions(&d);
    for (0..14) |i| {
        try setNumber(&d, Number, 99, @intCast(i), .low);
        try testing.expectEqual(0xfff, try read(&d, Graph, 0));
    }
    try testing.expectEqual(execs, graphExecutions(&d));
}

test "fixpoint: an edit inside a cycle recomputes it at the cost of a first computation" {
    // Guards against repeatedly verifying and recomputing the old memos of members within a cycle
    // (the recomputed results are in the cycle and are not written to memos): when all members have
    // been read separately and one of them is changed, the number of recomputations needed to read
    // the cycle head would grow exponentially with the size of the cycle
    for ([_]struct { n: u32, dense: bool }{ .{ .n = 16, .dense = false }, .{ .n = 8, .dense = true } }) |c| {
        var d: Db = .init(testing.io, testing.allocator, {});
        defer d.deinit();
        try setRing(&d, c.n, c.dense);
        const all = (@as(u32, 1) << @intCast(c.n)) - 1;
        var execs = graphExecutions(&d);
        for (0..c.n) |k| try testing.expectEqual(all, try read(&d, Graph, @intCast(k)));
        const first = graphExecutions(&d) - execs;
        const mid = c.n / 2;
        for (0..2) |i| {
            const label: u32 = if (i == 0) 0 else @as(u32, 1) << @intCast(mid);
            try setNumber(&d, Label, mid, label, .low);
            const reach = all & ~(@as(u32, 1) << @intCast(mid)) | label;
            execs = graphExecutions(&d);
            for (0..c.n) |k| try testing.expectEqual(reach, try read(&d, Graph, @intCast(k)));
            try testing.expect(graphExecutions(&d) - execs <= 2 * first);
        }
    }
}

/// Expected value of Graph(start): the union of the Labels of the nodes reachable from start
/// (including itself)
fn expectedGraph(succ: []const u32, label: []const u32, start: u32) u32 {
    var seen: u32 = @as(u32, 1) << @intCast(start);
    var grew = true;
    while (grew) {
        grew = false;
        for (succ, 0..) |s, k| {
            if (seen & (@as(u32, 1) << @intCast(k)) == 0 or seen | s == seen) continue;
            seen |= s;
            grew = true;
        }
    }
    var reach: u32 = 0;
    for (label, 0..) |l, k| {
        if (seen & (@as(u32, 1) << @intCast(k)) != 0) reach |= l;
    }
    return reach;
}

const Mark = enum { new, open, done };

/// The memos of Graph and GraphVia form no cycle along their dependencies
fn expectAcyclicMemos(d: *Db) !void {
    var marks: [2][32]Mark = @splat(@splat(.new));
    inline for (.{ Graph, GraphVia }) |Q| {
        for (0..d.keyCount(Q)) |i| try visitMemo(d, &marks, .{ .query = Db.queryIndex(Q), .index = @intCast(i) });
    }
}

fn visitMemo(d: *Db, marks: *[2][32]Mark, dep: db.DepKey) !void {
    const q: usize = if (dep.query == Db.queryIndex(Graph)) 0 else if (dep.query == Db.queryIndex(GraphVia)) 1 else return;
    switch (marks[q][dep.index]) {
        .open => return error.MemoCycle,
        .done => return,
        .new => {},
    }
    marks[q][dep.index] = .open;
    const memo_deps = if (q == 0) memoDeps(d, Graph, dep.index) else memoDeps(d, GraphVia, dep.index);
    for (memo_deps) |next| try visitMemo(d, marks, next);
    marks[q][dep.index] = .done;
}

fn memoDeps(d: *Db, comptime Q: type, index: u32) []const db.DepKey {
    const memo = d.tables[comptime Db.queryIndex(Q)].slots.items[index].memo orelse return &.{};
    return memo.deps;
}

test "fixpoint: values stay correct under random edits to a graph with cycles" {
    for (0..40) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        const rand = prng.random();
        const n = 4 + rand.uintLessThan(u32, 5);
        var d: Db = .init(testing.io, testing.allocator, {});
        defer d.deinit();
        var succ: [8]u32 = @splat(0);
        var label: [8]u32 = undefined;
        for (&label, 0..) |*l, k| l.* = @as(u32, 1) << @intCast(k);
        {
            d.beginWrite();
            defer d.endWrite();
            for (label[0..n], 0..) |l, k| try d.set(Label, @intCast(k), l, .low);
        }
        for (0..200) |_| {
            {
                d.beginWrite();
                defer d.endWrite();
                const k = rand.uintLessThan(u32, n);
                switch (rand.uintLessThan(u8, 4)) {
                    0, 1 => {
                        // Removing an edge is more likely than adding one, which keeps the graph
                        // sparse: in a dense cycle every path has to be computed once
                        const bit = @as(u32, 1) << rand.uintLessThan(u5, @intCast(n));
                        if (succ[k] & bit != 0 or rand.uintLessThan(u8, 3) == 0) succ[k] ^= bit;
                        try d.set(Succ, k, succ[k], .low);
                    },
                    2 => {
                        label[k] ^= @as(u32, 1) << rand.int(u5);
                        try d.set(Label, k, label[k], .low);
                    },
                    else => try d.set(Number, 99, rand.int(i64), .low),
                }
            }
            // Read in random order, sometimes several in the same read transaction
            var ctx = d.beginRead(testing.allocator);
            defer ctx.end();
            for (0..rand.uintLessThan(u32, 2 * n)) |_| {
                if (rand.boolean()) {
                    ctx.end();
                    ctx = d.beginRead(testing.allocator);
                }
                const k = rand.uintLessThan(u32, n);
                const got = if (rand.boolean()) try ctx.get(Graph, k) else try ctx.get(GraphVia, k);
                try testing.expectEqual(expectedGraph(succ[0..n], label[0..n], k), got);
            }
            try expectAcyclicMemos(&d);
        }
    }
}

test "fixpoint: dependencies of cycle members are handed straight to the cycle head" {
    // Guards against every level of a cycle merging the dependencies of all the levels above it
    // into its own dependency table one by one: the cost of computing a large cycle would grow
    // cubically with its size
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    const n = 200;
    {
        d.beginWrite();
        defer d.endWrite();
        for (0..31) |k| try d.set(Label, @intCast(k), @as(u32, 1) << @intCast(k), .low);
    }
    layer_max_deps = 0;
    try testing.expectEqual(0x7fff_ffff, try read(&d, Layer, .{ .k = 0, .len = n }));
    try testing.expectEqual(2, layer_max_deps);
    // The memo of the cycle head depends directly on the inputs read by each member, including the
    // member farthest from the cycle head
    const entry = d.tables[comptime Db.queryIndex(Layer)].keys.getIndex(.{ .k = 0, .len = n }).?;
    try testing.expectEqual(2 * n, memoDeps(&d, Layer, @intCast(entry)).len);
    try setNumber(&d, Label, 1000 + n - 1, 1 << 31, .low);
    try testing.expectEqual(0xffff_ffff, try read(&d, Layer, .{ .k = 0, .len = n }));
}

test "stack limit: deep recursion stops with the fallback and is not memoized" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    // A recursive chain far beyond the stack limit does not overflow; the deepest part is replaced
    // by the fallback value
    try testing.expect(try read(&d, Depth, 2_000_000) < 0);
    // The result depends on the stack depth during evaluation, so it is not written to a memo:
    // reading again recomputes it
    const before = executions(&d, Depth);
    try testing.expect(try read(&d, Depth, 2_000_000) < 0);
    try testing.expect(executions(&d, Depth) > before);
    // A computation starting from a shallow point is unaffected
    try testing.expectEqual(100, try read(&d, Depth, 100));
}

test "stack limit: unwinding an incomplete deep recursion does not collect dependencies" {
    // Guards against each level merging the dependencies of all the levels above it into its own
    // dependency table one by one when the result is incomplete (stack depth limit): none of these
    // frames are written to memos, but the merging makes the cost grow cubically with depth
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    layer_max_deps = 0;
    // A chain far beyond the stack limit
    try testing.expectEqual(std.math.maxInt(u32), try read(&d, Layer, .{ .k = 100_000 }));
    try testing.expectEqual(2, layer_max_deps);
}

test "stack limit: each top-level read in a transaction gets its own deepenings" {
    // Guards against earlier reads in the same read transaction using up the segmented
    // computations, so that later reads that need segmenting get truncated
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    var ctx = d.beginRead(testing.allocator);
    defer ctx.end();
    try testing.expect(try ctx.get(Depth, 2_000_000) < 0);
    try testing.expectEqual(5000, try ctx.get(Depth, 5000));
}

test "stack limit: threads other than the configured main thread use the worker budget" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    d.stack_budget = .{ .main = std.Thread.getCurrentId(), .worker_bytes = 48 * 1024 * 1024 };
    // The main thread computes in segments under the default limit and cannot finish; a thread with
    // a larger stack can
    try testing.expect(try read(&d, Depth, 100_000) < 0);
    const Worker = struct {
        fn run(dd: *Db, out: *?db.Error!i64) void {
            out.* = read(dd, Depth, 100_000);
        }
    };
    var result: ?db.Error!i64 = null;
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, Worker.run, .{ &d, &result });
    thread.join();
    try testing.expectEqual(100_000, try result.?);
}

test "cycles entered deep in the stack are detected at the right frame" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    {
        d.beginWrite();
        defer d.endWrite();
        for (0..201) |k| try d.set(Label, @intCast(k), @as(u32, 1) << @intCast(k % 32), .low);
    }
    // The cycle head 10 is frame 190 on the stack
    try testing.expectEqual(0xffff_ffff, try read(&d, Lasso, 200));
    // The frames calling into the cycle head are not in the cycle and were written to memos
    const before = executions(&d, Lasso);
    try testing.expectEqual(0xfff, try read(&d, Lasso, 11));
    try testing.expectEqual(before, executions(&d, Lasso));
}

test "cancellation: reads return Canceled when pending_write is set" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    var ctx = d.beginRead(testing.allocator);
    defer ctx.end();
    d.pending_write.store(1, .release);
    defer d.pending_write.store(0, .release);
    try testing.expectError(error.Canceled, ctx.get(Plus, 1));
}

test "cancellation: per-request cancel flag" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    var cancel: std.atomic.Value(bool) = .init(true);
    var ctx = d.beginRead(testing.allocator);
    defer ctx.end();
    ctx.cancel = &cancel;
    try testing.expectError(error.Canceled, ctx.get(Plus, 1));
}

test "cancellation: write interrupts in-flight read" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    spin_started.store(false, .release);

    const Reader = struct {
        fn run(dd: *Db, result: *?db.Error!i64) void {
            var ctx = dd.beginRead(testing.allocator);
            defer ctx.end();
            result.* = ctx.get(Spin, 1);
        }
    };
    var result: ?db.Error!i64 = null;
    const thread = try std.Thread.spawn(.{}, Reader.run, .{ &d, &result });
    while (!spin_started.load(.acquire)) std.atomic.spinLoopHint();

    // beginWrite returns only after the reader exits
    try setNumber(&d, Number, 1, 1, .low);
    thread.join();
    try testing.expectError(error.Canceled, result.?);
}

test "cancellation: a writer taking the lock keeps the request of the writer queued behind it" {
    // Guards against the writer that gets the lock first clearing the registration of a queued
    // writer: a read transaction that gets the shared lock between the two would not be canceled,
    // and the queued writer would have to wait for it to run to completion
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    const Writer = struct {
        order: *std.atomic.Value(u32),
        seen: *[2]u32,
        fn run(w: @This(), dd: *Db) void {
            dd.beginWrite();
            w.seen[w.order.fetchAdd(1, .monotonic)] = dd.pending_write.load(.acquire);
            dd.endWrite();
        }
    };
    var order: std.atomic.Value(u32) = .init(0);
    var seen: [2]u32 = undefined;
    const writer: Writer = .{ .order = &order, .seen = &seen };
    // A read transaction is in progress and both write transactions are waiting. If spawning a
    // thread fails, end the read transaction first so that the writers already started can finish.
    var ctx = d.beginRead(testing.allocator);
    const first = std.Thread.spawn(.{}, Writer.run, .{ writer, &d }) catch |err| {
        ctx.end();
        return err;
    };
    const second = std.Thread.spawn(.{}, Writer.run, .{ writer, &d }) catch |err| {
        ctx.end();
        first.join();
        return err;
    };
    while (d.pending_write.load(.acquire) != 2) std.Thread.yield() catch {};
    ctx.end();
    first.join();
    second.join();
    // The writer that got the lock first sees the other one still registered
    try testing.expectEqual([2]u32{ 1, 0 }, seen);
    try testing.expectEqual(0, d.pending_write.load(.acquire));
}

test "cancellation: result of a compute that swallowed Canceled is not memoized" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setNumber(&d, Number, 1, 7, .low);

    swallow_cancel = true;
    {
        var ctx = d.beginRead(testing.allocator);
        defer ctx.end();
        try testing.expectError(error.Canceled, ctx.get(Swallow, 1));
    }
    d.pending_write.store(0, .release);
    swallow_cancel = false;

    // The swallowed cancellation left no fallback value -1 behind: reading again recomputes the
    // correct result
    const before = executions(&d, Swallow);
    try testing.expectEqual(7, try read(&d, Swallow, 1));
    try testing.expectEqual(before + 1, executions(&d, Swallow));
}

test "cancellation: a read bound to a mark is canceled by any write transaction begun since then" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setNumber(&d, Number, 1, 7, .low);
    const m = d.mark(null);
    // A write that sets no input and cancels nothing does not move the mark
    try testing.expect(d.tryBeginWrite());
    d.endWrite();
    {
        var ctx = d.beginReadAt(testing.allocator, m);
        defer ctx.end();
        try testing.expectEqual(1, try ctx.get(Plus, 1));
    }
    // Finished before the read transaction begins, the write still cancels it
    try setNumber(&d, Number, 1, 70, .low);
    {
        var ctx = d.beginReadAt(testing.allocator, m);
        defer ctx.end();
        try testing.expectError(error.Canceled, ctx.get(Plus, 1));
    }
    var ctx = d.beginReadAt(testing.allocator, d.mark(null));
    defer ctx.end();
    try testing.expectEqual(8, try ctx.get(Plus, 1));
}

test "cancellation: a write not ordered with marks is read by the reads that begin after it" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setNumber(&d, Number, 1, 7, .low);
    const m = d.mark(null);
    {
        d.beginWriteOf(Db.inputSet(&.{Number}), .unordered);
        defer d.endWrite();
        try d.set(Number, 1, 70, .low);
    }
    var ctx = d.beginReadAt(testing.allocator, m);
    defer ctx.end();
    try testing.expectEqual(8, try ctx.get(Plus, 1));
}

test "cancellation: a write transaction cancels only the reads that may depend on the inputs it changes" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setNumber(&d, Number, 1, 7, .low);
    const numbers = Db.inputSet(&.{Number});
    const before_any = d.mark(null);
    const before_numbers = d.mark(numbers);
    const Writer = struct {
        fn run(dd: *Db) void {
            dd.beginWriteOf(Db.inputSet(&.{Stable}), .after_marks);
            defer dd.endWrite();
            dd.set(Stable, 1, 5, .low) catch unreachable;
        }
    };
    {
        var ctx = d.beginReadAt(testing.allocator, d.mark(numbers));
        const writer = std.Thread.spawn(.{}, Writer.run, .{&d}) catch |err| {
            ctx.end();
            return err;
        };
        while (d.pending_write.load(.acquire) == 0) std.Thread.yield() catch {};
        // The write of another input waits for this read transaction instead of canceling it
        const value = ctx.get(Plus, 1);
        const canceled = ctx.checkCanceled();
        ctx.end();
        writer.join();
        try testing.expectEqual(1, try value);
        try canceled;
    }
    // Marks taken before the write: it moved only the one that covers all inputs
    {
        var ctx = d.beginReadAt(testing.allocator, before_numbers);
        defer ctx.end();
        try testing.expectEqual(1, try ctx.get(Plus, 1));
    }
    var ctx = d.beginReadAt(testing.allocator, before_any);
    defer ctx.end();
    try testing.expectError(error.Canceled, ctx.get(Plus, 1));
}

test "tryBeginWrite neither cancels nor waits for read transactions" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setNumber(&d, Number, 1, 7, .low);
    var ctx = d.beginRead(testing.allocator);
    try testing.expect(!d.tryBeginWrite());
    try testing.expectEqual(1, try ctx.get(Plus, 1));
    ctx.end();
    try testing.expect(d.tryBeginWrite());
    d.resetQueries(&.{Plus});
    d.endWrite();
    try testing.expectEqual(1, try read(&d, Plus, 1));
}

test "resetQueries: cleared keys and dependent memos are recomputed" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setNumber(&d, Number, 1, 25, .high);
    try testing.expectEqual(3, try read(&d, Plus, 1));
    try testing.expectEqual(0, try read(&d, OnlyStable, 1));

    d.beginWrite();
    d.resetQueries(&.{Tens});
    d.endWrite();
    var buf: [Db.query_types.len]db.QueryStats = undefined;
    const stats = d.stats(&buf);
    try testing.expectEqual(0, stats.queries[comptime Db.queryIndex(Tens)].keys);
    // Plus depends on Tens: its memo is discarded, and reading again recomputes both
    try testing.expectEqual(0, stats.queries[comptime Db.queryIndex(Plus)].memos);
    const tens = executions(&d, Tens);
    const plus = executions(&d, Plus);
    try testing.expectEqual(3, try read(&d, Plus, 1));
    try testing.expectEqual(tens + 1, executions(&d, Tens));
    try testing.expectEqual(plus + 1, executions(&d, Plus));
    // Memos unrelated to them are kept (high-durability dependencies are re-verified too, but not
    // recomputed)
    const only = executions(&d, OnlyStable);
    _ = try read(&d, OnlyStable, 1);
    try testing.expectEqual(only, executions(&d, OnlyStable));
}

test "lru_bytes: values are evicted by size, oldest first" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    {
        d.beginWrite();
        defer d.endWrite();
        for (1..4) |k| try d.set(Text, @intCast(k), try testing.allocator.dupe(u8, "abcdef"), .low);
    }
    for (1..4) |k| _ = try read(&d, Sized, @intCast(k));
    try testing.expect(d.wantsSweep());
    try testing.expect(d.trySweep());
    var buf: [Db.query_types.len]db.QueryStats = undefined;
    const q = d.stats(&buf).queries[comptime Db.queryIndex(Sized)];
    // 3 × 6 bytes exceeds 10: evict to at most 7.5 bytes, keeping only the most recently used one
    try testing.expectEqual(1, q.memos);
    const before = executions(&d, Sized);
    try testing.expectEqualStrings("abcdef", try read(&d, Sized, 3));
    try testing.expectEqual(before, executions(&d, Sized));
    // Evicted values are restored on demand
    try testing.expectEqualStrings("abcdef", try read(&d, Sized, 1));
    try testing.expectEqual(before + 1, executions(&d, Sized));
}

test "lru: capacities set at runtime apply at the next sweep, 0 is unlimited" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    {
        d.beginWrite();
        defer d.endWrite();
        for (1..4) |k| try d.set(Text, @intCast(k), try testing.allocator.dupe(u8, "abcdef"), .low);
    }
    const live = &d.tables[comptime Db.queryIndex(Sized)].live;
    // Unlimited bytes: the default of 10 bytes fits only one value; now all 3 are kept
    d.setLru(Sized, null, 0);
    for (1..4) |k| _ = try read(&d, Sized, @intCast(k));
    try testing.expect(d.trySweep());
    try testing.expectEqual(3, live.*);
    // Lower the count: the sweep evicts down to 3/4, keeping the most recently used
    d.setLru(Sized, 2, 0);
    try testing.expect(d.wantsSweep());
    try testing.expect(d.trySweep());
    try testing.expectEqual(1, live.*);
    const before = executions(&d, Sized);
    _ = try read(&d, Sized, 3);
    try testing.expectEqual(before, executions(&d, Sized));
}

test "concurrent reads: readers of the same query agree" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setNumber(&d, Number, 1, 42, .low);

    const Reader = struct {
        fn run(dd: *Db, out: *i64) void {
            var ctx = dd.beginRead(testing.allocator);
            defer ctx.end();
            out.* = ctx.get(Plus, 1) catch -1;
        }
    };
    var outs: [8]i64 = undefined;
    var threads: [8]std.Thread = undefined;
    for (&threads, &outs) |*t, *o| t.* = try std.Thread.spawn(.{}, Reader.run, .{ &d, o });
    for (threads) |t| t.join();
    for (outs) |o| try testing.expectEqual(5, o);
}

fn setText(d: *Db, key: u32, text: []const u8) !void {
    d.beginWrite();
    defer d.endWrite();
    try d.set(Text, key, try testing.allocator.dupe(u8, text), .low);
}

test "lru: evicted values are restored without invalidating dependents" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    for (1..5) |k| try setText(&d, @intCast(k), "abc");
    for (1..5) |k| try testing.expectEqual(3, try read(&d, CachedLen, @intCast(k)));
    try testing.expect(d.wantsSweep());
    // Capacity 2: evict down to 1; the least recently used 1, 2, 3 are evicted
    try testing.expect(d.trySweep());
    try testing.expect(!d.wantsSweep());
    try testing.expectEqual(1, d.tables[comptime Db.queryIndex(Cached)].live);

    // An unrelated input change: verifying CachedLen(1) only needs the changed_at of Cached(1) and
    // does not restore its value
    try setText(&d, 4, "abcd");
    try testing.expectEqual(3, try read(&d, CachedLen, 1));
    try testing.expectEqual(4, executions(&d, Cached));
    try testing.expectEqual(4, executions(&d, CachedLen));

    // Reading an evicted value directly: it is recomputed to restore it and keeps its original
    // changed_at, so nothing downstream is recomputed
    try testing.expectEqualStrings("abc", try read(&d, Cached, 1));
    try testing.expectEqual(5, executions(&d, Cached));
    try setText(&d, 3, "x");
    try testing.expectEqual(3, try read(&d, CachedLen, 1));
    try testing.expectEqual(4, executions(&d, CachedLen));

    // A dependency changes: recompute as usual
    try setText(&d, 1, "abcdef");
    try testing.expectEqual(6, try read(&d, CachedLen, 1));
    try testing.expectEqual(5, executions(&d, CachedLen));
}

test "stats: executions, hits, cutoffs and timing; trace records the call tree" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setNumber(&d, Number, 1, 42, .low);

    var trace: db.Trace = .{ .gpa = testing.allocator };
    defer trace.events.deinit(testing.allocator);
    {
        var ctx = d.beginRead(testing.allocator);
        defer ctx.end();
        ctx.trace = &trace;
        try testing.expectEqual(5, try ctx.get(Plus, 1));
        try testing.expectEqual(5, try ctx.get(Plus, 1));
    }
    // Preorder: Plus first (depth 0), Tens inside it (depth 1); the second read is a hit and does
    // not execute again
    try testing.expectEqual(2, trace.events.items.len);
    try testing.expectEqual(Db.queryIndex(Plus), trace.events.items[0].query);
    try testing.expectEqual(0, trace.events.items[0].depth);
    try testing.expectEqual(Db.queryIndex(Tens), trace.events.items[1].query);
    try testing.expectEqual(1, trace.events.items[1].depth);
    try testing.expect(trace.events.items[0].ns >= trace.events.items[1].ns);
    try testing.expectEqual(1, d.keyAt(Plus, trace.events.items[0].key));

    // 42 → 47: Tens is recomputed but its result is unchanged (cutoff), and Plus is not recomputed
    try setNumber(&d, Number, 1, 47, .low);
    try testing.expectEqual(5, try read(&d, Plus, 1));
    var stats: [Db.query_types.len]db.QueryStats = undefined;
    _ = d.stats(&stats);
    const plus = stats[Db.queryIndex(Plus)];
    const tens = stats[Db.queryIndex(Tens)];
    try testing.expectEqual(1, plus.executions);
    try testing.expectEqual(2, plus.hits);
    try testing.expectEqual(2, tens.executions);
    try testing.expectEqual(1, tens.cutoffs);
    try testing.expectEqual(1, plus.memos);
    try testing.expect(plus.total_ns >= plus.self_ns);
    try testing.expect(plus.max_ns <= plus.total_ns);
}
