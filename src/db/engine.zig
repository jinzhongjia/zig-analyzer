//! 查询引擎：revision、memo、依赖追踪、early cutoff、durability、取消、环检测。
//!
//! 每个 query 用一个描述类型声明：
//!
//! ```zig
//! pub const FileText = struct {
//!     pub const kind: db.Kind = .input;
//!     pub const Key = FileId;
//!     pub const Value = []const u8;
//!     pub const default: Value = "";              // input 未设置时的值
//!     pub fn eql(a: Value, b: Value) bool { ... } // Value 含指针时必须提供
//!     pub fn deinit(v: *Value, gpa: Allocator) void { ... } // 可选
//! };
//!
//! pub const LineCount = struct {
//!     pub const kind: db.Kind = .derived;
//!     pub const Key = FileId;
//!     pub const Value = u32;
//!     pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value { ... }
//!     pub fn cycleFallback(key: Key) Value { ... } // 可选：参与环时的回退值
//! };
//! ```
//!
//! derived query 可改为声明 `computeIncremental(ctx, key, prev: ?Value)`，重算时引擎传入上一次的值
//! （首次计算为 null）。结果必须与从零计算完全相同，prev 只用于加速；读取 prev 不记录依赖。
//!
//! 并发模型：读事务（`beginRead`）持有共享锁，可并发；写事务（`beginWrite`）先置位
//! `pending_write` 使进行中的读查询尽快以 `error.Canceled` 退出，再获取独占锁。
//! 读事务内拿到的 query 值在该事务结束前一直有效：被替换的旧值延迟到下一次写事务才释放。

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Revision = u64;

pub const Kind = enum { input, derived };

/// 输入的变化频率。验证 memo 时，若其依赖的最低 durability 层自上次验证以来没有输入变化，
/// 可以跳过逐个依赖的检查。
pub const Durability = enum(u2) {
    low,
    medium,
    high,

    fn min(a: Durability, b: Durability) Durability {
        return if (@backingInt(a) < @backingInt(b)) a else b;
    }
    fn max(a: Durability, b: Durability) Durability {
        return if (@backingInt(a) > @backingInt(b)) a else b;
    }
};

pub const Error = error{ Canceled, OutOfMemory };

/// 依赖边：(query 序号, key 驻留后的下标)
pub const DepKey = struct {
    query: u16,
    index: u32,

    fn eql(a: DepKey, b: DepKey) bool {
        return a.query == b.query and a.index == b.index;
    }
};

pub const Stats = struct {
    /// 各 query 执行 compute 的次数
    executions: []const u64,
    /// 逐个依赖检查（未被 durability 跳过）的次数
    deep_verifications: u64,
    revision: Revision,
};

/// `Env`：query 可通过 `ctx.db.env` 访问的只读环境（必须在 Db 生命周期内不变）。
pub fn Engine(comptime Env: type, comptime queries: []const type) type {
    comptime for (queries) |Q| validate(Q);

    return struct {
        const Db = @This();

        pub const query_types = queries;

        io: Io,
        gpa: Allocator,
        env: Env,

        /// 读事务共享、写事务独占
        rw: Io.RwLock = .init,
        /// 保护所有表的元数据（key 驻留、slot、memo、垃圾列表）
        mutex: Io.Mutex = .init,
        pending_write: std.atomic.Value(bool) = .init(false),
        writing: bool = false,
        bumped_in_write: bool = false,

        revision: Revision = 1,
        /// 每个 durability 层最近一次有输入变化的 revision
        last_changed: [3]Revision = @splat(1),

        tables: Tables = tables_init,
        garbage: std.ArrayList(Garbage) = .empty,

        executions: [queries.len]std.atomic.Value(u64) = @splat(.init(0)),
        deep_verifications: std.atomic.Value(u64) = .init(0),

        const Tables = @Tuple(&table_types);
        const table_types = blk: {
            var types: [queries.len]type = undefined;
            for (queries, 0..) |Q, i| types[i] = Table(Q);
            break :blk types;
        };
        const tables_init: Tables = blk: {
            var t: Tables = undefined;
            for (0..queries.len) |i| t[i] = .{};
            break :blk t;
        };

        fn Table(comptime Q: type) type {
            return struct {
                keys: std.AutoArrayHashMapUnmanaged(Q.Key, void) = .empty,
                slots: std.ArrayList(Slot) = .empty,

                const Slot = switch (Q.kind) {
                    .input => struct {
                        value: Q.Value = Q.default,
                        is_set: bool = false,
                        changed_at: Revision = 0,
                        durability: Durability = .low,
                    },
                    .derived => struct {
                        memo: ?Memo = null,
                    },
                };

                const Memo = struct {
                    value: Q.Value,
                    verified_at: Revision,
                    changed_at: Revision,
                    durability: Durability,
                    deps: []const DepKey,
                };
            };
        }

        /// 延迟释放的旧值（读事务可能仍持有其指针）
        const Garbage = union(enum) {
            deps: []const DepKey,
            value: struct { ptr: *anyopaque, free: *const fn (*anyopaque, Allocator) void },
        };

        pub fn init(io: Io, gpa: Allocator, env: Env) Db {
            return .{ .io = io, .gpa = gpa, .env = env };
        }

        pub fn deinit(db: *Db) void {
            db.collectGarbage();
            db.garbage.deinit(db.gpa);
            inline for (queries, 0..) |Q, qi| {
                const table = &db.tables[qi];
                for (table.slots.items) |*slot| switch (Q.kind) {
                    .input => if (slot.is_set) deinitValue(Q, &slot.value, db.gpa),
                    .derived => if (slot.memo) |*memo| {
                        deinitValue(Q, &memo.value, db.gpa);
                        db.gpa.free(memo.deps);
                    },
                };
                table.slots.deinit(db.gpa);
                table.keys.deinit(db.gpa);
            }
            db.* = undefined;
        }

        pub fn queryIndex(comptime Q: type) u16 {
            inline for (queries, 0..) |Candidate, i| {
                if (Candidate == Q) return i;
            }
            @compileError("query 未注册: " ++ @typeName(Q));
        }

        pub fn stats(db: *Db, buf: *[queries.len]u64) Stats {
            for (buf, &db.executions) |*out, *count| out.* = count.load(.monotonic);
            return .{
                .executions = buf,
                .deep_verifications = db.deep_verifications.load(.monotonic),
                .revision = db.revision,
            };
        }

        // ── 写事务 ─────────────────────────────────────────────────────────

        /// 开始写事务：取消进行中的读查询，等待所有读事务结束。
        pub fn beginWrite(db: *Db) void {
            db.pending_write.store(true, .release);
            db.rw.lockUncancelable(db.io);
            db.pending_write.store(false, .release);
            db.writing = true;
            db.bumped_in_write = false;
            db.collectGarbage();
        }

        pub fn endWrite(db: *Db) void {
            assert(db.writing);
            db.writing = false;
            db.rw.unlock(db.io);
        }

        /// 设置 input，引擎接管 `value` 的所有权。值与旧值相等时不推进 revision。
        pub fn set(db: *Db, comptime Q: type, key: Q.Key, value: Q.Value, durability: Durability) Allocator.Error!void {
            comptime assert(Q.kind == .input);
            assert(db.writing);
            const table = &db.tables[comptime queryIndex(Q)];
            const index = db.internLocked(Q, key) catch |err| {
                var v = value;
                deinitValue(Q, &v, db.gpa);
                return err;
            };
            const slot = &table.slots.items[index];

            if (slot.is_set and valueEql(Q, slot.value, value)) {
                var v = value;
                deinitValue(Q, &v, db.gpa);
                return;
            }

            if (!db.bumped_in_write) {
                db.revision += 1;
                db.bumped_in_write = true;
            }
            // 取新旧 durability 的较大者，保证依赖旧值的高 durability memo 也会被重新验证
            const effective = durability.max(slot.durability);
            for (0..@as(usize, @backingInt(effective)) + 1) |d| db.last_changed[d] = db.revision;

            if (slot.is_set) deinitValue(Q, &slot.value, db.gpa);
            slot.* = .{ .value = value, .is_set = true, .changed_at = db.revision, .durability = durability };
        }

        /// 写事务中读取 input 的当前值（不记录依赖）。
        pub fn peek(db: *Db, comptime Q: type, key: Q.Key) Q.Value {
            comptime assert(Q.kind == .input);
            assert(db.writing);
            const table = &db.tables[comptime queryIndex(Q)];
            const index = table.keys.getIndex(key) orelse return Q.default;
            return table.slots.items[index].value;
        }

        fn collectGarbage(db: *Db) void {
            for (db.garbage.items) |g| switch (g) {
                .deps => |deps| db.gpa.free(deps),
                .value => |v| v.free(v.ptr, db.gpa),
            };
            db.garbage.clearRetainingCapacity();
        }

        // ── 读事务 ─────────────────────────────────────────────────────────

        pub fn beginRead(db: *Db, gpa: Allocator) Ctx {
            db.rw.lockSharedUncancelable(db.io);
            return .{ .db = db, .gpa = gpa };
        }

        pub const Ctx = struct {
            db: *Db,
            gpa: Allocator,
            /// 单个请求的取消标志（对应 `$/cancelRequest`）
            cancel: ?*const std.atomic.Value(bool) = null,
            stack: std.ArrayList(Frame) = .empty,

            /// `deps` 使用 `db.gpa` 分配，因为它最终归 memo 所有
            const Frame = struct {
                key: DepKey,
                deps: std.ArrayList(DepKey) = .empty,
                durability: Durability = .high,
                /// 本帧参与了环，结果不写入 memo
                in_cycle: bool = false,
            };

            pub fn end(ctx: *Ctx) void {
                assert(ctx.stack.items.len == 0);
                ctx.stack.deinit(ctx.gpa);
                ctx.db.rw.unlockShared(ctx.db.io);
                ctx.* = undefined;
            }

            /// 长时间运行的 compute 应周期性调用。
            pub fn checkCanceled(ctx: *const Ctx) error{Canceled}!void {
                if (ctx.db.pending_write.load(.acquire)) return error.Canceled;
                if (ctx.cancel) |c| if (c.load(.acquire)) return error.Canceled;
            }

            /// 读取 query 的值，并把它记为当前正在计算的 query 的依赖。
            /// 返回值在本读事务结束前有效。
            pub fn get(ctx: *Ctx, comptime Q: type, key: Q.Key) Error!Q.Value {
                try ctx.checkCanceled();
                const qi = comptime queryIndex(Q);
                const db = ctx.db;

                db.mutex.lockUncancelable(db.io);
                const index = db.internLocked(Q, key) catch |err| {
                    db.mutex.unlock(db.io);
                    return err;
                };
                db.mutex.unlock(db.io);
                const dep: DepKey = .{ .query = qi, .index = index };

                const fresh = switch (Q.kind) {
                    .input => db.readInput(Q, index),
                    .derived => blk: {
                        for (ctx.stack.items, 0..) |frame, i| {
                            if (frame.key.eql(dep)) return ctx.onCycle(Q, i, key);
                        }
                        break :blk try ctx.ensureFresh(Q, index, key);
                    },
                };
                try ctx.recordDep(dep, fresh.durability);
                return fresh.value;
            }

            fn recordDep(ctx: *Ctx, dep: DepKey, durability: Durability) Allocator.Error!void {
                if (ctx.stack.items.len == 0) return;
                const top = &ctx.stack.items[ctx.stack.items.len - 1];
                top.durability = top.durability.min(durability);
                for (top.deps.items) |d| if (d.eql(dep)) return;
                try top.deps.append(ctx.db.gpa, dep);
            }

            fn onCycle(ctx: *Ctx, comptime Q: type, head: usize, key: Q.Key) Q.Value {
                if (!@hasDecl(Q, "cycleFallback")) {
                    std.debug.panic("query 环且未声明 cycleFallback: {s}", .{@typeName(Q)});
                }
                for (ctx.stack.items[head..]) |*frame| frame.in_cycle = true;
                return Q.cycleFallback(key);
            }

            fn Fresh(comptime Q: type) type {
                return struct { value: Q.Value, changed_at: Revision, durability: Durability };
            }

            /// 确保 derived memo 在当前 revision 有效，必要时验证或重算。
            fn ensureFresh(ctx: *Ctx, comptime Q: type, index: u32, key: Q.Key) Error!Fresh(Q) {
                const db = ctx.db;
                const table = &db.tables[comptime queryIndex(Q)];

                db.mutex.lockUncancelable(db.io);
                const existing = table.slots.items[index].memo;
                db.mutex.unlock(db.io);

                if (existing) |memo| {
                    if (memo.verified_at == db.revision) return .{ .value = memo.value, .changed_at = memo.changed_at, .durability = memo.durability };
                    if (try ctx.deepVerify(memo.verified_at, memo.durability, memo.deps)) {
                        db.mutex.lockUncancelable(db.io);
                        defer db.mutex.unlock(db.io);
                        // 可能已被并发读者重算替换，以表中当前值为准
                        const m = &table.slots.items[index].memo.?;
                        m.verified_at = @max(m.verified_at, db.revision);
                        return .{ .value = m.value, .changed_at = m.changed_at, .durability = m.durability };
                    }
                }
                return ctx.execute(Q, index, key);
            }

            /// 所有依赖的 changed_at 都不晚于 `verified_at` 时返回 true。
            fn deepVerify(ctx: *Ctx, verified_at: Revision, durability: Durability, deps: []const DepKey) Error!bool {
                const db = ctx.db;
                if (db.last_changed[@backingInt(durability)] <= verified_at) return true;
                _ = db.deep_verifications.fetchAdd(1, .monotonic);
                for (deps) |dep| {
                    if (try ctx.changedAt(dep) > verified_at) return false;
                }
                return true;
            }

            /// 把依赖带到最新状态并返回它的 changed_at（不记录依赖）。
            fn changedAt(ctx: *Ctx, dep: DepKey) Error!Revision {
                const db = ctx.db;
                inline for (queries, 0..) |Q, qi| {
                    if (dep.query == qi) switch (Q.kind) {
                        .input => return db.readInput(Q, dep.index).changed_at,
                        .derived => {
                            db.mutex.lockUncancelable(db.io);
                            const key = db.tables[qi].keys.keys()[dep.index];
                            db.mutex.unlock(db.io);
                            for (ctx.stack.items) |frame| {
                                // 验证路径上遇到环：视为已变化，强制上层重算
                                if (frame.key.eql(dep)) return db.revision;
                            }
                            return (try ctx.ensureFresh(Q, dep.index, key)).changed_at;
                        },
                    };
                }
                unreachable;
            }

            fn execute(ctx: *Ctx, comptime Q: type, index: u32, key: Q.Key) Error!Fresh(Q) {
                const db = ctx.db;
                const qi = comptime queryIndex(Q);
                _ = db.executions[qi].fetchAdd(1, .monotonic);

                try ctx.stack.append(ctx.gpa, .{ .key = .{ .query = qi, .index = index } });
                const computed = if (@hasDecl(Q, "computeIncremental")) blk: {
                    // 上一次的值在下一次写事务前不会被释放，可安全地作为增量计算的基础
                    db.mutex.lockUncancelable(db.io);
                    const prev: ?Q.Value = if (db.tables[qi].slots.items[index].memo) |m| m.value else null;
                    db.mutex.unlock(db.io);
                    break :blk Q.computeIncremental(ctx, key, prev);
                } else Q.compute(ctx, key);
                var value = computed catch |err| {
                    var frame = ctx.stack.pop().?;
                    frame.deps.deinit(ctx.db.gpa);
                    return err;
                };
                var frame = ctx.stack.pop().?;

                db.mutex.lockUncancelable(db.io);
                defer db.mutex.unlock(db.io);

                const slot = &db.tables[qi].slots.items[index];
                const published = if (slot.memo) |old| old.verified_at == db.revision else false;
                if (frame.in_cycle or published) {
                    frame.deps.deinit(db.gpa);
                    try db.discardLocked(Q, &value);
                    // 并发读者已在本 revision 发布结果，以它为准
                    if (published) {
                        const old = slot.memo.?;
                        return .{ .value = old.value, .changed_at = old.changed_at, .durability = old.durability };
                    }
                    // 环中的结果依赖于入口，不写入 memo
                    return .{ .value = value, .changed_at = db.revision, .durability = .low };
                }

                const deps = frame.deps.toOwnedSlice(db.gpa) catch |err| {
                    frame.deps.deinit(db.gpa);
                    return err;
                };
                errdefer db.gpa.free(deps);

                var changed_at = db.revision;
                if (slot.memo) |*old| {
                    try db.garbage.ensureUnusedCapacity(db.gpa, 2);
                    db.garbage.appendAssumeCapacity(.{ .deps = old.deps });
                    if (valueEql(Q, old.value, value)) {
                        // early cutoff：保留旧值与旧 changed_at
                        changed_at = old.changed_at;
                        deinitValue(Q, &value, db.gpa);
                        value = old.value;
                    } else {
                        try db.discardLocked(Q, &old.value);
                    }
                }
                slot.memo = .{
                    .value = value,
                    .verified_at = db.revision,
                    .changed_at = changed_at,
                    .durability = frame.durability,
                    .deps = deps,
                };
                return .{ .value = value, .changed_at = changed_at, .durability = frame.durability };
            }
        };

        // ── 内部工具 ───────────────────────────────────────────────────────

        /// 调用方须持有 mutex（或处于写事务中）。
        fn internLocked(db: *Db, comptime Q: type, key: Q.Key) Allocator.Error!u32 {
            const table = &db.tables[comptime queryIndex(Q)];
            try table.slots.ensureUnusedCapacity(db.gpa, 1);
            const gop = try table.keys.getOrPut(db.gpa, key);
            if (!gop.found_existing) table.slots.appendAssumeCapacity(.{});
            return @intCast(gop.index);
        }

        fn readInput(db: *Db, comptime Q: type, index: u32) struct { value: Q.Value, changed_at: Revision, durability: Durability } {
            db.mutex.lockUncancelable(db.io);
            defer db.mutex.unlock(db.io);
            const slot = db.tables[comptime queryIndex(Q)].slots.items[index];
            return .{ .value = slot.value, .changed_at = slot.changed_at, .durability = slot.durability };
        }

        /// 把值放入垃圾列表，下一次写事务时释放。调用方须持有 mutex。
        fn discardLocked(db: *Db, comptime Q: type, value: *Q.Value) Allocator.Error!void {
            if (!@hasDecl(Q, "deinit")) return;
            const box = try db.gpa.create(Q.Value);
            box.* = value.*;
            db.garbage.append(db.gpa, .{ .value = .{ .ptr = @ptrCast(box), .free = struct {
                fn free(ptr: *anyopaque, gpa: Allocator) void {
                    const v: *Q.Value = @ptrCast(@alignCast(ptr));
                    Q.deinit(v, gpa);
                    gpa.destroy(v);
                }
            }.free } }) catch |err| {
                db.gpa.destroy(box);
                return err;
            };
        }
    };
}

fn validate(comptime Q: type) void {
    for (.{ "kind", "Key", "Value" }) |name| {
        if (!@hasDecl(Q, name)) @compileError(@typeName(Q) ++ " 缺少声明: " ++ name);
    }
    switch (Q.kind) {
        .input => if (!@hasDecl(Q, "default")) @compileError(@typeName(Q) ++ " 是 input，必须声明 default"),
        .derived => if (!@hasDecl(Q, "compute") and !@hasDecl(Q, "computeIncremental")) @compileError(@typeName(Q) ++ " 是 derived，必须声明 compute 或 computeIncremental"),
    }
    if (!@hasDecl(Q, "eql") and containsPointer(Q.Value)) {
        @compileError(@typeName(Q) ++ " 的 Value 含指针，必须声明 eql");
    }
}

fn containsPointer(comptime T: type) bool {
    return comptime switch (@typeInfo(T)) {
        .pointer => true,
        .optional => |o| containsPointer(o.child),
        .array => |a| containsPointer(a.child),
        inline .@"struct", .@"union" => |info| for (info.field_types) |F| {
            if (containsPointer(F)) break true;
        } else false,
        else => false,
    };
}

test containsPointer {
    try std.testing.expect(!containsPointer(struct { a: u32, b: ?struct { c: [2]i8 } }));
    try std.testing.expect(containsPointer(struct { a: u32, b: union(enum) { c: void, d: []const u8 } }));
}

fn valueEql(comptime Q: type, a: Q.Value, b: Q.Value) bool {
    return if (@hasDecl(Q, "eql")) Q.eql(a, b) else std.meta.eql(a, b);
}

fn deinitValue(comptime Q: type, value: *Q.Value, gpa: Allocator) void {
    if (@hasDecl(Q, "deinit")) Q.deinit(value, gpa);
}

test {
    _ = @import("engine_test.zig");
}
