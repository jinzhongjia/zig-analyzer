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

const Db = db.Engine(&.{ Number, Stable, Text, Tens, Plus, Upper, OnlyStable, CycleA, CycleB, Spin });

fn executions(d: *Db, comptime Q: type) u64 {
    return d.executions[Db.queryIndex(Q)].load(.monotonic);
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

test "未设置的 input 返回 default" {
    var d: Db = .init(testing.io, testing.allocator);
    defer d.deinit();
    try testing.expectEqual(1, try read(&d, Plus, 7));
}

test "memo 跨读事务复用" {
    var d: Db = .init(testing.io, testing.allocator);
    defer d.deinit();
    try setNumber(&d, Number, 1, 42, .low);

    try testing.expectEqual(5, try read(&d, Plus, 1));
    try testing.expectEqual(5, try read(&d, Plus, 1));
    try testing.expectEqual(1, executions(&d, Plus));
    try testing.expectEqual(1, executions(&d, Tens));
}

test "early cutoff：中间结果不变时上层不重算" {
    var d: Db = .init(testing.io, testing.allocator);
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

test "设置相同的 input 值不推进 revision" {
    var d: Db = .init(testing.io, testing.allocator);
    defer d.deinit();
    try setNumber(&d, Number, 1, 42, .low);
    const rev = d.revision;
    try setNumber(&d, Number, 1, 42, .low);
    try testing.expectEqual(rev, d.revision);
}

test "不相关 key 的变化不触发重算" {
    var d: Db = .init(testing.io, testing.allocator);
    defer d.deinit();
    try setNumber(&d, Number, 1, 42, .low);
    try testing.expectEqual(5, try read(&d, Plus, 1));
    try setNumber(&d, Number, 2, 99, .low);
    try testing.expectEqual(5, try read(&d, Plus, 1));
    try testing.expectEqual(1, executions(&d, Tens));
}

test "durability：低层输入变化时跳过高 durability memo 的依赖检查" {
    var d: Db = .init(testing.io, testing.allocator);
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

test "durability：输入从 high 降为 low 后仍能正确失效" {
    var d: Db = .init(testing.io, testing.allocator);
    defer d.deinit();
    try setNumber(&d, Stable, 1, 1, .high);
    try testing.expectEqual(2, try read(&d, OnlyStable, 1));
    try setNumber(&d, Stable, 1, 2, .low);
    try testing.expectEqual(4, try read(&d, OnlyStable, 1));
    try setNumber(&d, Stable, 1, 3, .low);
    try testing.expectEqual(6, try read(&d, OnlyStable, 1));
}

test "带指针的 Value：值不变时保留旧值，变化时延迟释放" {
    var d: Db = .init(testing.io, testing.allocator);
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

test "环：使用 cycleFallback 且不写入 memo" {
    var d: Db = .init(testing.io, testing.allocator);
    defer d.deinit();
    // CycleA → CycleB → CycleA(fallback = -100)，CycleB = -100，CycleA = -99
    try testing.expectEqual(-99, try read(&d, CycleA, 1));
    try testing.expectEqual(-99, try read(&d, CycleA, 1));
    try testing.expectEqual(2, executions(&d, CycleA));
}

test "取消：pending_write 置位时读查询返回 Canceled" {
    var d: Db = .init(testing.io, testing.allocator);
    defer d.deinit();
    var ctx = d.beginRead(testing.allocator);
    defer ctx.end();
    d.pending_write.store(true, .release);
    defer d.pending_write.store(false, .release);
    try testing.expectError(error.Canceled, ctx.get(Plus, 1));
}

test "取消：单个请求的取消标志" {
    var d: Db = .init(testing.io, testing.allocator);
    defer d.deinit();
    var cancel: std.atomic.Value(bool) = .init(true);
    var ctx = d.beginRead(testing.allocator);
    defer ctx.end();
    ctx.cancel = &cancel;
    try testing.expectError(error.Canceled, ctx.get(Plus, 1));
}

test "取消：写事务打断进行中的读查询" {
    var d: Db = .init(testing.io, testing.allocator);
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

test "并发读：多个读者读取同一 query 结果一致" {
    var d: Db = .init(testing.io, testing.allocator);
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
