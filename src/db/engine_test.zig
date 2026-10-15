const std = @import("std");
const db = @import("engine.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;

// 依赖图：
//   Number(k) ─┬→ Tens(k) → Plus(k)
//              └→ Text(k) (字符串 input，验证带指针的 Value)
//   Stable(k)：high durability input → OnlyStable(k)

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

// 环：CycleA(k) = CycleB(k) + 1，CycleB(k) = CycleA(k)
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

/// 递归链：Depth(k) = Depth(k - 1) + 1
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

/// 可达集（位集）：Reach(k) = {k} ∪ 各后继的 Reach。图 0 → 1，1 → 0、2，2 → 2，3 → 0
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

/// 读到 Number 后一直等待，直到被取消
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

/// 带 LRU 容量的 query：值含指针（淘汰时须释放）
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

const CachedLen = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = usize;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        return (try ctx.get(Cached, key)).len;
    }
};

/// 消耗燃料的 query（模拟 comptime 求值）：燃料不足时结果不完整，不写入 memo
const Burn = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = i64;
    pub const lru: usize = 1;
    pub const cost = 1000;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        if (ctx.fuel < cost) {
            ctx.markIncomplete(.fuel);
            return -1;
        }
        ctx.fuel -= cost;
        return try ctx.get(Number, key);
    }
};

const Db = db.Engine(void, &.{ Number, Stable, Text, Tens, Plus, Upper, OnlyStable, CycleA, CycleB, Depth, Reach, Spin, Cached, CachedLen, Burn });

fn executions(d: *Db, comptime Q: type) u64 {
    return d.executions(Q);
}

fn setNumber(d: *Db, comptime Q: type, key: u32, value: i64, durability: db.Durability) !void {
    d.beginWrite();
    defer d.endWrite();
    try d.set(Q, key, value, durability);
}

fn read(d: *Db, comptime Q: type, key: u32) !Q.Value {
    var ctx = d.beginRead(testing.allocator);
    defer ctx.end();
    return ctx.get(Q, key);
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

    // 42 → 47：Tens 仍为 4
    try setNumber(&d, Number, 1, 47, .low);
    try testing.expectEqual(5, try read(&d, Plus, 1));
    try testing.expectEqual(2, executions(&d, Tens));
    try testing.expectEqual(1, executions(&d, Plus));

    // 47 → 51：Tens 变为 5，Plus 必须重算
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

    // 高 durability 输入变化后必须重算
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

    // 内容相同的新字符串：input 不变，Upper 不重算
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

test "cycle: uses cycleFallback without writing memo" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    // CycleA → CycleB → CycleA(fallback = -100)，CycleB = -100，CycleA = -99
    try testing.expectEqual(-99, try read(&d, CycleA, 1));
    try testing.expectEqual(-99, try read(&d, CycleA, 1));
    try testing.expectEqual(2, executions(&d, CycleA));
}

test "fixpoint: the cycle head is complete and memoized" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    // 3 → 0 ⇄ 1 → 2 ↺：环中对入口的读取取空集，入口 0 与 2 算一遍即得完整结果
    try testing.expectEqual(0b1111, try read(&d, Reach, 3));
    const before = executions(&d, Reach);
    try testing.expectEqual(0b0111, try read(&d, Reach, 0));
    try testing.expectEqual(0b0100, try read(&d, Reach, 2));
    try testing.expectEqual(before, executions(&d, Reach));
    // 1 在 0 的环内，读到的是 0 的回退值，不写入 memo：单独读取时重算
    try testing.expectEqual(0b0111, try read(&d, Reach, 1));
    try testing.expectEqual(before + 1, executions(&d, Reach));
}

test "stack limit: deep recursion stops with the fallback and is not memoized" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    // 远超栈上限的递归链不会溢出，最深处以回退值代替
    try testing.expect(try read(&d, Depth, 2_000_000) < 0);
    // 结果取决于求值时的栈深度，不写入 memo：再次读取会重算
    const before = executions(&d, Depth);
    try testing.expect(try read(&d, Depth, 2_000_000) < 0);
    try testing.expect(executions(&d, Depth) > before);
    // 从浅处开始的计算不受影响
    try testing.expectEqual(100, try read(&d, Depth, 100));
}

test "cancellation: reads return Canceled when pending_write is set" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    var ctx = d.beginRead(testing.allocator);
    defer ctx.end();
    d.pending_write.store(true, .release);
    defer d.pending_write.store(false, .release);
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

    // beginWrite 会等到读者退出后才返回
    try setNumber(&d, Number, 1, 1, .low);
    thread.join();
    try testing.expectError(error.Canceled, result.?);
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
    // 容量 2：淘汰到 1 个，最久未使用的 1、2、3 被淘汰
    try testing.expect(d.trySweep());
    try testing.expect(!d.wantsSweep());
    try testing.expectEqual(1, d.tables[comptime Db.queryIndex(Cached)].live);

    // 无关的输入变化：验证 CachedLen(1) 只需要 Cached(1) 的 changed_at，不恢复其值
    try setText(&d, 4, "abcd");
    try testing.expectEqual(3, try read(&d, CachedLen, 1));
    try testing.expectEqual(4, executions(&d, Cached));
    try testing.expectEqual(4, executions(&d, CachedLen));

    // 直接读取被淘汰的值：重算恢复，沿用原 changed_at，下游不重算
    try testing.expectEqualStrings("abc", try read(&d, Cached, 1));
    try testing.expectEqual(5, executions(&d, Cached));
    try setText(&d, 3, "x");
    try testing.expectEqual(3, try read(&d, CachedLen, 1));
    try testing.expectEqual(4, executions(&d, CachedLen));

    // 依赖变化：照常重算
    try setText(&d, 1, "abcdef");
    try testing.expectEqual(6, try read(&d, CachedLen, 1));
    try testing.expectEqual(5, executions(&d, CachedLen));
}

test "lru: restoring an evicted value does not depend on the remaining fuel" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setNumber(&d, Number, 1, 42, .low);
    try setNumber(&d, Number, 2, 7, .low);
    try testing.expectEqual(42, try read(&d, Burn, 1));
    try testing.expectEqual(7, try read(&d, Burn, 2));
    try testing.expect(d.trySweep());

    // 本次读取剩余的燃料不够重算，但恢复使用独立的燃料：结果完整且写入 memo
    var ctx = d.beginRead(testing.allocator);
    ctx.fuel = Burn.cost / 2;
    try testing.expectEqual(42, try ctx.get(Burn, 1));
    try testing.expectEqual(Burn.cost / 2, ctx.fuel);
    ctx.end();
    try testing.expectEqual(3, executions(&d, Burn));
    try testing.expectEqual(42, try read(&d, Burn, 1));
    try testing.expectEqual(3, executions(&d, Burn));
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
    // 先序：Plus 在前（深度 0），Tens 在其中（深度 1）；第二次读取是命中，不再执行
    try testing.expectEqual(2, trace.events.items.len);
    try testing.expectEqual(Db.queryIndex(Plus), trace.events.items[0].query);
    try testing.expectEqual(0, trace.events.items[0].depth);
    try testing.expectEqual(Db.queryIndex(Tens), trace.events.items[1].query);
    try testing.expectEqual(1, trace.events.items[1].depth);
    try testing.expect(trace.events.items[0].ns >= trace.events.items[1].ns);
    try testing.expectEqual(1, d.keyAt(Plus, trace.events.items[0].key));

    // 42 → 47：Tens 重算但结果不变（cutoff），Plus 不重算
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
