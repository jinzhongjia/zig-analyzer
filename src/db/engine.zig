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
//! derived query 可声明 `pub const lru: usize = N`：保留值的 memo 超过 N 个时，最久未使用的 memo
//! 被淘汰，只删除值，保留依赖与 changed_at。被淘汰的 memo 验证通过时重算并沿用原 changed_at
//! （compute 是确定的，依赖未变则结果相同），下游不会因此重算。淘汰在写事务开始时或 `sweep` 中进行
//! （此时没有读事务持有值）。
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

/// 一个读事务中嵌套计算可占用的原生栈。超过后有 `cycleFallback` 的 query 不再深入：返回回退值，
/// 当前栈上的 query 都不写入 memo（结果取决于求值时的栈深度，不能缓存）。上限须明显小于最小的
/// 线程栈（Linux 主线程 8 MB），为两次检查之间的栈占用留出余量
pub const max_stack_bytes = 4 * 1024 * 1024;

/// 一个读事务中 comptime 求值可用的步数（燃料）。耗尽后的结果同样不写入 memo
pub const default_fuel = 20_000_000;

/// 一个读事务中「先从栈底计算中断处」的次数上限（见 `Ctx.get`），使无限递归也能结束
pub const max_deepening = 16;

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
        /// memo 最近使用时间的计数器（LRU）
        access_tick: std.atomic.Value(u64) = .init(0),
        /// 有声明了 `lru` 的 query 超出容量，等待 `sweep`
        sweep_wanted: std.atomic.Value(bool) = .init(false),

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
                /// 保留着值的 memo 数（只对声明了 `lru` 的 query 统计）
                live: usize = 0,

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
                    /// `evicted` 时无效
                    value: Q.Value,
                    verified_at: Revision,
                    changed_at: Revision,
                    durability: Durability,
                    deps: []const DepKey,
                    evicted: bool = false,
                    last_used: u64 = 0,
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
                        if (!memo.evicted) deinitValue(Q, &memo.value, db.gpa);
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
            @compileError("query not registered: " ++ @typeName(Q));
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
            db.evictLocked();
        }

        /// 是否有 query 超出 `lru` 容量（调用方可在空闲时调用 `sweep`）
        pub fn wantsSweep(db: *Db) bool {
            return db.sweep_wanted.load(.monotonic);
        }

        /// 淘汰超出 `lru` 容量的 memo 值：等待进行中的读事务结束（不取消它们）
        pub fn sweep(db: *Db) void {
            db.rw.lockUncancelable(db.io);
            defer db.rw.unlock(db.io);
            db.collectGarbage();
            db.evictLocked();
        }

        /// 每个超出容量的 query 淘汰最久未使用的 memo，降到容量的 3/4（留出余量，避免频繁清扫）。
        /// 调用方须独占数据库（没有读事务持有值）
        fn evictLocked(db: *Db) void {
            if (!db.sweep_wanted.swap(false, .monotonic)) return;
            inline for (queries, 0..) |Q, qi| {
                if (comptime Q.kind == .derived and @hasDecl(Q, "lru")) {
                    const table = &db.tables[qi];
                    if (table.live > Q.lru) evictTable(Q, table, db.gpa, table.live - Q.lru * 3 / 4);
                }
            }
        }

        fn evictTable(comptime Q: type, table: *Table(Q), gpa: Allocator, count: usize) void {
            // 第 count 小的最近使用时间之前（含）的都淘汰；内存不足时退而淘汰全部
            const ticks = gpa.alloc(u64, table.live) catch {
                for (table.slots.items) |*slot| if (slot.memo) |*m| if (!m.evicted) evictMemo(Q, table, m, gpa);
                return;
            };
            defer gpa.free(ticks);
            var n: usize = 0;
            for (table.slots.items) |slot| if (slot.memo) |m| if (!m.evicted) {
                ticks[n] = m.last_used;
                n += 1;
            };
            std.mem.sort(u64, ticks[0..n], {}, std.sort.asc(u64));
            const limit = ticks[@min(count, n) - 1];
            var evicted: usize = 0;
            for (table.slots.items) |*slot| if (slot.memo) |*m| if (!m.evicted and m.last_used <= limit and evicted < count) {
                evictMemo(Q, table, m, gpa);
                evicted += 1;
            };
        }

        fn evictMemo(comptime Q: type, table: *Table(Q), m: *Table(Q).Memo, gpa: Allocator) void {
            deinitValue(Q, &m.value, gpa);
            m.value = undefined;
            m.evicted = true;
            table.live -= 1;
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
            return .{ .db = db, .gpa = gpa, .stack_base = @frameAddress() };
        }

        pub const Ctx = struct {
            db: *Db,
            gpa: Allocator,
            /// 单个请求的取消标志（对应 `$/cancelRequest`）
            cancel: ?*const std.atomic.Value(bool) = null,
            stack: std.ArrayList(Frame) = .empty,
            /// 读事务开始处的栈位置（栈向低地址增长）
            stack_base: usize,
            /// 剩余的 comptime 求值步数，由解释器扣减
            fuel: u64 = default_fuel,
            /// 本次顶层读取中第一次因栈深度上限中断的 query
            frontier: ?DepKey = null,
            /// 已经从栈底计算过的中断处个数
            deepening: u32 = 0,

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

            /// 本读事务的嵌套计算占用的原生栈超过 `max_stack_bytes`。递归的 compute 应在深入前检查，
            /// 超过时以未知结果返回并调用 `markIncomplete`
            pub fn stackExhausted(ctx: *const Ctx) bool {
                const here = @frameAddress();
                return ctx.stack_base > here and ctx.stack_base - here > max_stack_bytes;
            }

            /// 当前结果不完整（燃料耗尽等）：栈上的 query 都不写入 memo
            pub fn markIncomplete(ctx: *Ctx) void {
                for (ctx.stack.items) |*frame| frame.in_cycle = true;
            }

            /// compute 内部因栈深度上限中断：除 `markIncomplete` 外，记下正在计算的 query，
            /// 顶层读取会先从栈底计算它
            pub fn exhausted(ctx: *Ctx) void {
                ctx.markIncomplete();
                if (ctx.frontier == null and ctx.stack.items.len > 0) ctx.frontier = ctx.stack.items[ctx.stack.items.len - 1].key;
            }

            /// 当前计算的结果已经不完整（环、深度上限或燃料耗尽）：不应再为改进结果而深入计算，
            /// 否则不写入 memo 的结果在每一层都会被重新计算
            pub fn incomplete(ctx: *const Ctx) bool {
                const n = ctx.stack.items.len;
                return n > 0 and ctx.stack.items[n - 1].in_cycle;
            }

            /// 长时间运行的 compute 应周期性调用。
            pub fn checkCanceled(ctx: *const Ctx) error{Canceled}!void {
                if (ctx.db.pending_write.load(.acquire)) return error.Canceled;
                if (ctx.cancel) |c| if (c.load(.acquire)) return error.Canceled;
            }

            /// 读取 query 的值，并把它记为当前正在计算的 query 的依赖。
            /// 返回值在本读事务结束前有效。
            ///
            /// 顶层读取（不在其他 query 的计算中）的嵌套计算因栈深度上限中断时，先从栈底计算
            /// 中断处的 query（结果完整时写入 memo），再重新计算，直到结果完整或没有进展。
            /// 很深的依赖链因此分段计算，总代价与链长成正比，结果也是完整的
            pub fn get(ctx: *Ctx, comptime Q: type, key: Q.Key) Error!Q.Value {
                if (Q.kind == .input or ctx.stack.items.len != 0) return ctx.getInner(Q, key);
                while (true) {
                    ctx.frontier = null;
                    const v = try ctx.getInner(Q, key);
                    const frontier = ctx.frontier orelse return v;
                    if (ctx.deepening >= max_deepening) return v;
                    ctx.deepening += 1;
                    // 中断处仍然不完整时没有进展
                    if (!try ctx.precompute(frontier)) return v;
                }
            }

            /// 从栈底计算 `dep`；返回它的结果是否已写入 memo
            fn precompute(ctx: *Ctx, dep: DepKey) Error!bool {
                const db = ctx.db;
                inline for (queries, 0..) |Q, qi| {
                    if (Q.kind == .derived and dep.query == qi) {
                        db.mutex.lockUncancelable(db.io);
                        const key = db.tables[qi].keys.keys()[dep.index];
                        db.mutex.unlock(db.io);
                        _ = try ctx.get(Q, key);
                        return ctx.verifiedMemo(Q, dep.index) != null;
                    }
                }
                return false;
            }

            fn getInner(ctx: *Ctx, comptime Q: type, key: Q.Key) Error!Q.Value {
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
                        if (@hasDecl(Q, "cycleFallback") and ctx.stackExhausted()) {
                            // 本 revision 已验证的结果可以直接使用，不会再深入
                            if (ctx.verifiedMemo(Q, index)) |fresh| break :blk fresh;
                            ctx.markIncomplete();
                            if (ctx.frontier == null) ctx.frontier = dep;
                            return Q.cycleFallback(key);
                        }
                        break :blk try ctx.ensureFresh(Q, index, key, true);
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
                    std.debug.panic("query cycle without cycleFallback: {s}", .{@typeName(Q)});
                }
                for (ctx.stack.items[head..]) |*frame| frame.in_cycle = true;
                return Q.cycleFallback(key);
            }

            fn Fresh(comptime Q: type) type {
                return struct { value: Q.Value, changed_at: Revision, durability: Durability };
            }

            fn verifiedMemo(ctx: *Ctx, comptime Q: type, index: u32) ?Fresh(Q) {
                const db = ctx.db;
                db.mutex.lockUncancelable(db.io);
                defer db.mutex.unlock(db.io);
                const memo = &(db.tables[comptime queryIndex(Q)].slots.items[index].memo orelse return null);
                if (memo.verified_at != db.revision or memo.evicted) return null;
                memo.last_used = db.access_tick.fetchAdd(1, .monotonic);
                return .{ .value = memo.value, .changed_at = memo.changed_at, .durability = memo.durability };
            }

            /// 确保 derived memo 在当前 revision 有效，必要时验证或重算。`need_value` 为 false 时
            /// （只验证依赖）不恢复被淘汰的值，返回的 `value` 无效
            fn ensureFresh(ctx: *Ctx, comptime Q: type, index: u32, key: Q.Key, need_value: bool) Error!Fresh(Q) {
                const db = ctx.db;
                const table = &db.tables[comptime queryIndex(Q)];

                db.mutex.lockUncancelable(db.io);
                const existing = table.slots.items[index].memo;
                if (existing) |_| table.slots.items[index].memo.?.last_used = db.access_tick.fetchAdd(1, .monotonic);
                db.mutex.unlock(db.io);

                if (existing) |memo| {
                    const valid = memo.verified_at == db.revision or try ctx.deepVerify(memo.verified_at, memo.durability, memo.deps);
                    // 值已被淘汰：依赖未变，重算出的值必然相同，沿用原 changed_at
                    if (valid and memo.evicted) {
                        if (need_value) return ctx.execute(Q, index, key, true);
                        db.mutex.lockUncancelable(db.io);
                        defer db.mutex.unlock(db.io);
                        const m = &table.slots.items[index].memo.?;
                        m.verified_at = @max(m.verified_at, db.revision);
                        return .{ .value = undefined, .changed_at = m.changed_at, .durability = m.durability };
                    }
                    if (valid) {
                        db.mutex.lockUncancelable(db.io);
                        defer db.mutex.unlock(db.io);
                        // 可能已被并发读者重算替换，以表中当前值为准
                        const m = &table.slots.items[index].memo.?;
                        if (!m.evicted) {
                            m.verified_at = @max(m.verified_at, db.revision);
                            return .{ .value = m.value, .changed_at = m.changed_at, .durability = m.durability };
                        }
                    }
                }
                return ctx.execute(Q, index, key, false);
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
                            // 栈深度超过上限：同样视为已变化，由重算处理（重算时以回退值代替）
                            if (ctx.stackExhausted()) return db.revision;
                            return (try ctx.ensureFresh(Q, dep.index, key, false)).changed_at;
                        },
                    };
                }
                unreachable;
            }

            /// `restore`：memo 的值已被淘汰而依赖未变，重算只为恢复值，沿用原 changed_at
            fn execute(ctx: *Ctx, comptime Q: type, index: u32, key: Q.Key, restore: bool) Error!Fresh(Q) {
                const db = ctx.db;
                const qi = comptime queryIndex(Q);
                _ = db.executions[qi].fetchAdd(1, .monotonic);

                try ctx.stack.append(ctx.gpa, .{ .key = .{ .query = qi, .index = index } });
                const computed = if (@hasDecl(Q, "computeIncremental")) blk: {
                    // 上一次的值在下一次写事务前不会被释放，可安全地作为增量计算的基础
                    db.mutex.lockUncancelable(db.io);
                    const prev: ?Q.Value = if (db.tables[qi].slots.items[index].memo) |m| (if (m.evicted) null else m.value) else null;
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
                const published = if (slot.memo) |old| old.verified_at == db.revision and !old.evicted else false;
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
                const table = &db.tables[qi];
                if (slot.memo) |*old| {
                    try db.garbage.ensureUnusedCapacity(db.gpa, 2);
                    db.garbage.appendAssumeCapacity(.{ .deps = old.deps });
                    if (old.evicted) {
                        if (restore) changed_at = old.changed_at;
                        if (@hasDecl(Q, "lru")) table.live += 1;
                    } else if (valueEql(Q, old.value, value)) {
                        // early cutoff：保留旧值与旧 changed_at
                        changed_at = old.changed_at;
                        deinitValue(Q, &value, db.gpa);
                        value = old.value;
                    } else {
                        try db.discardLocked(Q, &old.value);
                    }
                } else if (@hasDecl(Q, "lru")) table.live += 1;
                if (@hasDecl(Q, "lru") and table.live > Q.lru) db.sweep_wanted.store(true, .monotonic);
                slot.memo = .{
                    .value = value,
                    .verified_at = db.revision,
                    .changed_at = changed_at,
                    .durability = frame.durability,
                    .deps = deps,
                    .last_used = db.access_tick.fetchAdd(1, .monotonic),
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
        if (!@hasDecl(Q, name)) @compileError(@typeName(Q) ++ " is missing declaration: " ++ name);
    }
    switch (Q.kind) {
        .input => if (!@hasDecl(Q, "default")) @compileError(@typeName(Q) ++ " is an input and must declare default"),
        .derived => if (!@hasDecl(Q, "compute") and !@hasDecl(Q, "computeIncremental")) @compileError(@typeName(Q) ++ " is derived and must declare compute or computeIncremental"),
    }
    if (!@hasDecl(Q, "eql") and containsPointer(Q.Value)) {
        @compileError(@typeName(Q) ++ " has a Value containing pointers and must declare eql");
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
