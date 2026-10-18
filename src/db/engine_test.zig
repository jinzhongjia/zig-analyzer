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

/// 由 input 描述的图上的可达集：Graph(k) = Label(k) ∪ 各后继的 Graph，后继由 Succ(k) 的位给出。
/// 编号为奇数的后继经由非 fixpoint 的 GraphVia 读取，环可以穿过不同的 query
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

/// 逐层读取的链或环：Layer(k) = Label(k) ∪ Label(k + 1000) ∪ 下一层。`len` 为 0 时下一层是 k - 1（到 0 为止），
/// 否则是 (k + 1) % len。每层消耗 1 步燃料。结果不完整或在环中时，读完下一层后把本帧记下的依赖数记入
/// `layer_max_deps`
const Layer = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = struct { k: u32, len: u32 = 0 };
    pub const Value = u32;
    pub const fixpoint = true;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        if (ctx.fuel == 0) {
            ctx.markIncomplete(.fuel);
            return depthFallback(key);
        }
        ctx.fuel -= 1;
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

/// 计算途中出现写事务，并以回退值吞掉内层读取的 `Canceled`
const Swallow = struct {
    pub const kind: db.Kind = .derived;
    pub const Key = u32;
    pub const Value = i64;
    pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value {
        if (swallow_cancel) ctx.db.pending_write.store(true, .release);
        return ctx.get(Number, key) catch -1;
    }
};
var swallow_cancel = false;

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

/// 按字节数淘汰的 query：个数上限很大，字节数上限只容得下一个值
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

const Db = db.Engine(void, &.{ Number, Stable, Text, Tens, Plus, Upper, OnlyStable, StableTens, StablePlus, CycleA, CycleB, Depth, Reach, Succ, Label, Graph, GraphVia, Layer, Spin, Swallow, Cached, Sized, CachedLen, Burn });

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

test "durability: memo verified through an early cutoff takes the lowered durability" {
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setNumber(&d, Stable, 1, 21, .high);
    try testing.expectEqual(3, try read(&d, StablePlus, 1));
    // 降为 low：StableTens 重算出相同的值，StablePlus 只被验证
    try setNumber(&d, Stable, 1, 29, .low);
    try testing.expectEqual(3, try read(&d, StablePlus, 1));
    try testing.expectEqual(1, executions(&d, StablePlus));
    // StablePlus 仍按 high 跳过依赖检查时，这里得到的是旧值 3
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

test "out of memory while committing a memo keeps the old memo intact and leaks nothing" {
    // 依次让重算 Upper 过程中的第 i 次分配失败：旧 memo 的依赖与值不能被提前移交，新值不能泄漏
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
        // 写事务释放垃圾列表：旧的依赖与值各只释放一次
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

test "fixpoint: an older memo of a cycle member does not hide changes seen by the cycle head" {
    // 防止环的入口把环内成员记为依赖：成员的旧 memo 重算出相同的值（early cutoff）时，入口被误判为未变
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    try setNumber(&d, Label, 0, 0b1, .low);
    try setNumber(&d, Label, 2, 0b10, .low);
    try testing.expectEqual(0b10, try read(&d, Graph, 2));
    // 0 ⇄ 2：入口 0 计算时 2 在环中算出 0b100，2 的 memo 仍是之前的 0b10
    {
        d.beginWrite();
        defer d.endWrite();
        try d.set(Succ, 0, 0b100, .low);
        try d.set(Succ, 2, 0b1, .low);
        try d.set(Label, 2, 0b100, .low);
    }
    try testing.expectEqual(0b101, try read(&d, Graph, 0));
    // 2 重算出与旧 memo 相同的值（early cutoff）时，入口仍须看到变化
    {
        d.beginWrite();
        defer d.endWrite();
        try d.set(Succ, 2, 0, .low);
        try d.set(Label, 2, 0b10, .low);
    }
    try testing.expectEqual(0b11, try read(&d, Graph, 0));
}

/// 环 k → k + 1（mod n），`dense` 时还有 k → k + 2；Label(k) = {k}
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
    // 防止环的入口与单独读取过的成员的 memo 互相依赖：之后每次验证都沿 memo 环递归到栈上限，
    // 重算次数随环的规模指数增长
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
            // 每个 memo 只验证一次
            try testing.expect(d.deep_verifications.load(.monotonic) - deep <= 2 * c.n);
        }
    }
    // 只读入口：验证不会逐个重算成员并写入 memo
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
    // 防止环中反复验证、重算成员的旧 memo（重算的结果在环中，不写入 memo）：成员都单独读取过时，
    // 改其中一个成员，读入口要重算的次数随环的规模指数增长
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

/// Graph(start) 的期望值：从 start 可达的结点（含自身）的 Label 之并
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

/// Graph 与 GraphVia 的 memo 沿依赖不成环
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
                        // 删边的概率高于加边，图保持稀疏：稠密的环中各路径都要算一遍
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
            // 按随机顺序读取，有时在同一个读事务中读取多个
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
    // 防止环中每一层都把上面各层的依赖逐个并入自己的依赖表：大环的计算代价随规模按立方增长
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
    // 入口的 memo 直接依赖各成员读到的 input，包括离入口最远的成员
    const entry = d.tables[comptime Db.queryIndex(Layer)].keys.getIndex(.{ .k = 0, .len = n }).?;
    try testing.expectEqual(2 * n, memoDeps(&d, Layer, @intCast(entry)).len);
    try setNumber(&d, Label, 1000 + n - 1, 1 << 31, .low);
    try testing.expectEqual(0xffff_ffff, try read(&d, Layer, .{ .k = 0, .len = n }));
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

test "stack limit: unwinding an incomplete deep recursion does not collect dependencies" {
    // 防止结果不完整（燃料耗尽、栈深度上限）时各层把上面各层的依赖逐个并入自己的依赖表：这些帧都不写入
    // memo，合并却使代价随深度按立方增长
    var d: Db = .init(testing.io, testing.allocator, {});
    defer d.deinit();
    layer_max_deps = 0;
    {
        var ctx = d.beginRead(testing.allocator);
        defer ctx.end();
        ctx.fuel = 300;
        try testing.expectEqual(std.math.maxInt(u32), try ctx.get(Layer, .{ .k = 1000 }));
    }
    try testing.expectEqual(2, layer_max_deps);
    // 远超栈上限的链
    try testing.expectEqual(std.math.maxInt(u32), try read(&d, Layer, .{ .k = 100_000 }));
    try testing.expectEqual(2, layer_max_deps);
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
    d.pending_write.store(false, .release);
    swallow_cancel = false;

    // 被吞掉的取消没有留下回退值 -1：再次读取重新计算出正确结果
    const before = executions(&d, Swallow);
    try testing.expectEqual(7, try read(&d, Swallow, 1));
    try testing.expectEqual(before + 1, executions(&d, Swallow));
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
    // Plus 依赖 Tens：memo 被丢弃，重新读取时两者都重算
    try testing.expectEqual(0, stats.queries[comptime Db.queryIndex(Plus)].memos);
    const tens = executions(&d, Tens);
    const plus = executions(&d, Plus);
    try testing.expectEqual(3, try read(&d, Plus, 1));
    try testing.expectEqual(tens + 1, executions(&d, Tens));
    try testing.expectEqual(plus + 1, executions(&d, Plus));
    // 与它们无关的 memo 保留（high durability 的依赖也重新验证，但不重算）
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
    // 3 × 6 字节超过 10：淘汰到不超过 7.5 字节，只留下最近使用的一个
    try testing.expectEqual(1, q.memos);
    const before = executions(&d, Sized);
    try testing.expectEqualStrings("abcdef", try read(&d, Sized, 3));
    try testing.expectEqual(before, executions(&d, Sized));
    // 被淘汰的值按需恢复
    try testing.expectEqualStrings("abcdef", try read(&d, Sized, 1));
    try testing.expectEqual(before + 1, executions(&d, Sized));
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
