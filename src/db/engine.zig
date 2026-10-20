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
//!     pub fn depthFallback(key: Key) Value { ... } // 可选：栈深度超过上限时的回退值，默认同 cycleFallback
//! };
//! ```
//!
//! derived query 可声明 `pub const fixpoint = true`：`cycleFallback` 是值的最小元，环中对自身的读取
//! 只把读到的值并入结果（如错误集）。这时环的入口算一遍即得最小不动点，入口的结果写入 memo，
//! 环内其他 query 的结果仍不写入。栈深度超过上限不是环，回退值不能取最小元，须声明 `depthFallback`
//!
//! derived query 可改为声明 `computeIncremental(ctx, key, prev: ?Value)`，重算时引擎传入上一次的值
//! （首次计算为 null）。结果必须与从零计算完全相同，prev 只用于加速；读取 prev 不记录依赖。
//!
//! query 可声明 `pub fn bytes(v: Value) usize`：值占用的字节数，只用于统计（`Db.stats`）。
//!
//! 同时声明了 `lru` 与 `bytes` 的 query 可再声明 `pub const lru_bytes: usize = N`：保留值的字节数超过 N 时
//! 同样按最近使用淘汰（值的大小差别很大时，只按个数限制不住内存）。
//!
//! derived query 可声明 `pub const lru: usize = N`：保留值的 memo 超过 N 个时，最久未使用的 memo
//! 被淘汰，只删除值，保留依赖与 changed_at。被淘汰的 memo 验证通过时重算并沿用原 changed_at
//! （compute 是确定的，依赖未变则结果相同），下游不会因此重算。淘汰在写事务开始时或 `trySweep` 中进行
//! （此时没有读事务持有值）。
//!
//! 并发模型：读事务（`beginRead`）持有共享锁，可并发；写事务（`beginWrite`）先登记到
//! `pending_write` 使进行中的读查询尽快以 `error.Canceled` 退出，再获取独占锁。
//! 读事务内拿到的 query 值在该事务结束前一直有效：被替换的旧值延迟到下一次写事务才释放。

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const tracy = @import("../util/tracy.zig");
const panic_context = @import("../util/panic_context.zig");

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
    /// 与注册的 query 一一对应
    queries: []const QueryStats,
    /// 逐个依赖检查（未被 durability 跳过）的次数
    deep_verifications: u64,
    revision: Revision,
    /// 各原因导致结果不完整的次数
    incomplete_causes: std.EnumArray(IncompleteCause, u64),
};

/// 一个 query 的累计统计
pub const QueryStats = struct {
    /// 执行 compute 的次数
    executions: u64,
    /// 读取时直接使用 memo（无需执行）的次数
    hits: u64,
    /// 重新执行后结果与旧值相同（early cutoff）的次数
    cutoffs: u64,
    /// compute 的累计耗时（含其中执行的其他 query）
    total_ns: u64,
    /// 扣除其中执行的其他 query 后的累计耗时
    self_ns: u64,
    /// 单次 compute 的最长耗时（含其他 query）
    max_ns: u64,
    /// 当前保留着值的 memo 数
    memos: usize,
    /// 驻留的 key 数（含值已被淘汰或未计算过的）
    keys: usize = 0,
    /// 保留着的值占用的字节数：query 声明了 `bytes(value)` 时统计，否则为 0
    bytes: usize = 0,
    /// memo 记录的依赖边总数（值被淘汰的 memo 仍保留依赖）
    deps: usize = 0,
    /// 结果不完整（环、栈深度或燃料用尽）而未写入 memo 的次数：这些结果每次读取都要重算
    incomplete: u64 = 0,
};

/// 结果不完整的原因
pub const IncompleteCause = enum {
    /// 参与了环（没有声明 fixpoint 的 query）
    cycle,
    /// 嵌套计算超出栈深度上限
    stack,
    /// comptime 求值的燃料耗尽
    fuel,
};

/// 一次读事务中执行过的 query（先序，按深度可还原调用树），用于慢请求日志
pub const Trace = struct {
    gpa: Allocator,
    events: std.ArrayList(Event) = .empty,

    pub const Event = struct {
        query: u16,
        /// key 驻留后的下标（`Db.keyAt` 取回 key）
        key: u32,
        depth: u16,
        /// 含其中执行的其他 query
        ns: u64 = 0,
        cutoff: bool = false,
        failed: bool = false,
        /// 结果不完整，未写入 memo
        incomplete: bool = false,
    };
};

const Counters = struct {
    executions: std.atomic.Value(u64) = .init(0),
    hits: std.atomic.Value(u64) = .init(0),
    cutoffs: std.atomic.Value(u64) = .init(0),
    total_ns: std.atomic.Value(u64) = .init(0),
    self_ns: std.atomic.Value(u64) = .init(0),
    max_ns: std.atomic.Value(u64) = .init(0),
    incomplete: std.atomic.Value(u64) = .init(0),
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
        /// 等待独占锁的写事务数，非零时读查询以 `error.Canceled` 退出。写事务拿到锁后才减一：
        /// 多个写事务排队时，先拿到锁的不会清掉后面的登记，排在它们之间拿到共享锁的读事务同样被取消
        pending_write: std.atomic.Value(u32) = .init(0),
        /// 进行中的读事务数。释放 memo 的值（淘汰、垃圾回收、`resetQueries`）时必须为 0，以断言检查
        active_readers: std.atomic.Value(u32) = .init(0),
        writing: bool = false,
        bumped_in_write: bool = false,

        revision: Revision = 1,
        /// 每个 durability 层最近一次有输入变化的 revision
        last_changed: [3]Revision = @splat(1),

        tables: Tables = tables_init,
        garbage: std.ArrayList(Garbage) = .empty,

        counters: [queries.len]Counters = @splat(.{}),
        incomplete_causes: [@typeInfo(IncompleteCause).@"enum".field_names.len]std.atomic.Value(u64) = @splat(.init(0)),
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
                /// 保留着的值的字节数（只对声明了 `lru_bytes` 的 query 统计）
                live_bytes: usize = 0,

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

        /// query `Q` 的 key 个数（含值已被淘汰的）。在事务之外调用：key 的增删由写事务的独占锁保护
        pub fn keyCount(db: *Db, comptime Q: type) usize {
            db.rw.lockSharedUncancelable(db.io);
            defer db.rw.unlockShared(db.io);
            return db.keyCountLocked(Q);
        }

        /// 同 `keyCount`；调用者已持有读事务或写事务（rw 共享/独占锁）
        pub fn keyCountLocked(db: *Db, comptime Q: type) usize {
            db.mutex.lockUncancelable(db.io);
            defer db.mutex.unlock(db.io);
            return db.tables[comptime queryIndex(Q)].keys.count();
        }

        pub fn queryIndex(comptime Q: type) u16 {
            inline for (queries, 0..) |Candidate, i| {
                if (Candidate == Q) return i;
            }
            @compileError("query not registered: " ++ @typeName(Q));
        }

        pub fn stats(db: *Db, buf: *[queries.len]QueryStats) Stats {
            db.mutex.lockUncancelable(db.io);
            defer db.mutex.unlock(db.io);
            inline for (queries, 0..) |Q, qi| {
                const c = &db.counters[qi];
                var memos: usize = 0;
                var bytes: usize = 0;
                var deps: usize = 0;
                for (db.tables[qi].slots.items) |slot| switch (Q.kind) {
                    .input => if (slot.is_set) {
                        memos += 1;
                        if (@hasDecl(Q, "bytes")) bytes += Q.bytes(slot.value);
                    },
                    .derived => if (slot.memo) |m| {
                        deps += m.deps.len;
                        if (!m.evicted) {
                            memos += 1;
                            if (@hasDecl(Q, "bytes")) bytes += Q.bytes(m.value);
                        }
                    },
                };
                buf[qi] = .{
                    .executions = c.executions.load(.monotonic),
                    .hits = c.hits.load(.monotonic),
                    .cutoffs = c.cutoffs.load(.monotonic),
                    .total_ns = c.total_ns.load(.monotonic),
                    .self_ns = c.self_ns.load(.monotonic),
                    .max_ns = c.max_ns.load(.monotonic),
                    .memos = memos,
                    .keys = db.tables[qi].keys.count(),
                    .bytes = bytes,
                    .deps = deps,
                    .incomplete = c.incomplete.load(.monotonic),
                };
            }
            var causes: std.EnumArray(IncompleteCause, u64) = .initFill(0);
            for (&db.incomplete_causes, 0..) |*n, i| causes.set(@fromBackingInt(@intCast(i)), n.load(.monotonic));
            return .{
                .queries = buf,
                .deep_verifications = db.deep_verifications.load(.monotonic),
                .revision = db.revision,
                .incomplete_causes = causes,
            };
        }

        /// 执行次数（测试与工具用）
        pub fn executions(db: *Db, comptime Q: type) u64 {
            return db.counters[comptime queryIndex(Q)].executions.load(.monotonic);
        }

        /// 第 `query` 个 query 中下标为 `index` 的 key（`Trace.Event` 的 key）
        pub fn keyAt(db: *Db, comptime Q: type, index: u32) Q.Key {
            db.mutex.lockUncancelable(db.io);
            defer db.mutex.unlock(db.io);
            return db.tables[comptime queryIndex(Q)].keys.keys()[index];
        }

        // ── 写事务 ─────────────────────────────────────────────────────────

        /// 开始写事务：取消进行中的读查询，等待所有读事务结束。
        pub fn beginWrite(db: *Db) void {
            _ = db.pending_write.fetchAdd(1, .release);
            db.rw.lockUncancelable(db.io);
            _ = db.pending_write.fetchSub(1, .release);
            db.writing = true;
            db.bumped_in_write = false;
            db.collectGarbage();
            db.evictLocked();
        }

        /// 是否有 query 超出 `lru` 容量（调用方可在空闲时调用 `trySweep`）
        pub fn wantsSweep(db: *Db) bool {
            return db.sweep_wanted.load(.monotonic);
        }

        /// 淘汰超出 `lru` 容量的 memo 值。只在没有读事务时进行：读写锁写者优先，排队等待的
        /// 清扫会挡住之后的所有读事务，直到最慢的那个读事务结束。拿不到锁时返回 false，
        /// 留到下一次写事务或下一次清扫
        pub fn trySweep(db: *Db) bool {
            if (!db.rw.tryLock(db.io)) return false;
            defer db.rw.unlock(db.io);
            db.collectGarbage();
            db.evictLocked();
            return true;
        }

        /// 每个超出容量的 query 淘汰最久未使用的 memo，降到容量的 3/4（留出余量，避免频繁清扫）。
        /// 调用方须独占数据库（没有读事务持有值）
        fn evictLocked(db: *Db) void {
            if (!db.sweep_wanted.swap(false, .monotonic)) return;
            db.assertNoReaders();
            inline for (queries, 0..) |Q, qi| {
                if (comptime Q.kind == .derived and @hasDecl(Q, "lru")) {
                    const table = &db.tables[qi];
                    const over_bytes = if (@hasDecl(Q, "lru_bytes")) table.live_bytes > Q.lru_bytes else false;
                    if (table.live > Q.lru or over_bytes) evictTable(Q, table, db.gpa);
                }
            }
        }

        /// 按最近使用时间从旧到新淘汰，直到个数与字节数都降到上限的 3/4（留出余量，避免频繁清扫）
        fn evictTable(comptime Q: type, table: *Table(Q), gpa: Allocator) void {
            const target_count = Q.lru * 3 / 4;
            const target_bytes: usize = if (@hasDecl(Q, "lru_bytes")) Q.lru_bytes * 3 / 4 else std.math.maxInt(usize);
            const Entry = struct { tick: u64, slot: u32 };
            // 内存不足时退而淘汰全部
            const entries = gpa.alloc(Entry, table.live) catch {
                for (table.slots.items) |*slot| if (slot.memo) |*m| if (!m.evicted) evictMemo(Q, table, m, gpa);
                return;
            };
            defer gpa.free(entries);
            var n: usize = 0;
            for (table.slots.items, 0..) |slot, i| if (slot.memo) |m| if (!m.evicted) {
                entries[n] = .{ .tick = m.last_used, .slot = @intCast(i) };
                n += 1;
            };
            std.mem.sort(Entry, entries[0..n], {}, struct {
                fn lt(_: void, a: Entry, b: Entry) bool {
                    return a.tick < b.tick;
                }
            }.lt);
            for (entries[0..n]) |e| {
                if (table.live <= target_count and table.live_bytes <= target_bytes) break;
                evictMemo(Q, table, &table.slots.items[e.slot].memo.?, gpa);
            }
        }

        fn evictMemo(comptime Q: type, table: *Table(Q), m: *Table(Q).Memo, gpa: Allocator) void {
            if (@hasDecl(Q, "lru_bytes")) table.live_bytes -= Q.bytes(m.value);
            deinitValue(Q, &m.value, gpa);
            m.value = undefined;
            m.evicted = true;
            table.live -= 1;
        }

        /// 清空这些 derived query 的全部 key 与 memo，供回收它们的 key 或值所引用的外部状态（如 InternPool）。
        /// 依赖边以 key 的下标记录，清空后下标失效：其他 query 中依赖它们的 memo 一并丢弃（重新读取时重算）。
        /// 推进 revision 并标记所有 durability 层已变化，剩下的 memo 都重新验证。只能在写事务中调用
        pub fn resetQueries(db: *Db, comptime reset: []const type) void {
            assert(db.writing);
            db.collectGarbage();
            const cleared = comptime blk: {
                var c: [queries.len]bool = @splat(false);
                for (reset) |Q| {
                    assert(Q.kind == .derived);
                    c[queryIndex(Q)] = true;
                }
                break :blk c;
            };
            inline for (queries, 0..) |Q, qi| {
                if (comptime Q.kind == .derived and !cleared[qi]) {
                    const table = &db.tables[qi];
                    for (table.slots.items) |*slot| if (slot.memo) |*memo| {
                        const stale = for (memo.deps) |d| {
                            if (cleared[d.query]) break true;
                        } else false;
                        if (!stale) continue;
                        if (!memo.evicted) {
                            if (@hasDecl(Q, "lru_bytes")) table.live_bytes -= Q.bytes(memo.value);
                            deinitValue(Q, &memo.value, db.gpa);
                            if (@hasDecl(Q, "lru")) table.live -= 1;
                        }
                        db.gpa.free(memo.deps);
                        slot.memo = null;
                    };
                }
            }
            inline for (queries, 0..) |Q, qi| {
                if (comptime cleared[qi]) {
                    const table = &db.tables[qi];
                    for (table.slots.items) |*slot| if (slot.memo) |*memo| {
                        if (!memo.evicted) deinitValue(Q, &memo.value, db.gpa);
                        db.gpa.free(memo.deps);
                    };
                    table.slots.clearAndFree(db.gpa);
                    table.keys.clearAndFree(db.gpa);
                    table.live = 0;
                    table.live_bytes = 0;
                }
            }
            if (!db.bumped_in_write) {
                db.revision += 1;
                db.bumped_in_write = true;
            }
            db.last_changed = @splat(db.revision);
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

        fn assertNoReaders(db: *Db) void {
            const n = db.active_readers.load(.acquire);
            if (n != 0) std.debug.panic("freeing memo values with {d} read transactions in progress", .{n});
        }

        fn collectGarbage(db: *Db) void {
            db.assertNoReaders();
            for (db.garbage.items) |g| switch (g) {
                .deps => |deps| db.gpa.free(deps),
                .value => |v| v.free(v.ptr, db.gpa),
            };
            db.garbage.clearRetainingCapacity();
        }

        // ── 读事务 ─────────────────────────────────────────────────────────

        pub fn beginRead(db: *Db, gpa: Allocator) Ctx {
            db.rw.lockSharedUncancelable(db.io);
            _ = db.active_readers.fetchAdd(1, .acq_rel);
            return .{ .db = db, .gpa = gpa, .stack_base = @frameAddress() };
        }

        pub const Ctx = struct {
            db: *Db,
            gpa: Allocator,
            /// 单个请求的取消标志（对应 `$/cancelRequest`）
            cancel: ?*const std.atomic.Value(bool) = null,
            /// 记录执行过的 query（慢请求日志）；null 时不记录
            trace: ?*Trace = null,
            stack: std.ArrayList(Frame) = .empty,
            /// 读事务开始处的栈位置（栈向低地址增长）
            stack_base: usize,
            /// 剩余的 comptime 求值步数，由解释器扣减
            fuel: u64 = default_fuel,
            /// 本次顶层读取中第一次因栈深度上限中断的 query
            frontier: ?DepKey = null,
            /// 已经从栈底计算过的中断处个数
            deepening: u32 = 0,
            /// 在当前栈上无法验证的 memo，按 key 去重
            unverifiable: std.ArrayList(Unverifiable) = .empty,

            /// memo 的依赖经由环回到了栈上下标为 `depth` 的 query（验证时遇到它，或重算时在环中）。
            /// 这个 query 出栈前，memo 视为无法验证：读取时直接重算（结果在环中时不写入 memo），验证其他 memo 时
            /// 视为已变化且不重算。否则环中每读一次都要重新验证、重算它的整条依赖链，而重算的结果又不保留，
            /// 代价随链长指数增长
            const Unverifiable = struct { key: DepKey, depth: u32 };

            /// 帧中记下的依赖，按记录顺序去重。依赖少时线性查找，多时建立散列索引：接过环中结果的依赖后，
            /// 一帧可能有很多依赖
            const DepSet = std.array_hash_map.Custom(DepKey, void, std.array_hash_map.AutoContext(DepKey), false);

            /// `deps` 使用 `db.gpa` 分配，因为它最终归 memo 所有
            const Frame = struct {
                key: DepKey,
                deps: DepSet = .empty,
                durability: Durability = .high,
                /// 本帧参与了环，结果不写入 memo
                in_cycle: bool = false,
                /// 本帧被 `markIncomplete` 标记：它与它下面的各帧都不写入 memo
                incomplete: bool = false,
                /// 本帧所在的环中位于栈最底层的 query 的下标（`markIncomplete` 不设置）
                cycle_head: ?u32 = null,
                /// 本帧中执行的其他 query 的耗时（用于自身耗时）
                child_ns: u64 = 0,
            };

            pub fn end(ctx: *Ctx) void {
                assert(ctx.stack.items.len == 0 and ctx.unverifiable.items.len == 0);
                ctx.stack.deinit(ctx.gpa);
                ctx.unverifiable.deinit(ctx.gpa);
                _ = ctx.db.active_readers.fetchSub(1, .acq_rel);
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
            pub fn markIncomplete(ctx: *Ctx, cause: IncompleteCause) void {
                _ = ctx.db.incomplete_causes[@backingInt(cause)].fetchAdd(1, .monotonic);
                for (ctx.stack.items) |*frame| {
                    frame.in_cycle = true;
                    frame.incomplete = true;
                }
            }

            /// compute 内部因栈深度上限中断：除 `markIncomplete` 外，记下正在计算的 query，
            /// 顶层读取会先从栈底计算它
            pub fn exhausted(ctx: *Ctx) void {
                ctx.markIncomplete(.stack);
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
                if (ctx.db.pending_write.load(.acquire) != 0) return error.Canceled;
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
                // panic 时写出正在计算的 query
                var entry: panic_context.Entry = .{ .data = ctx, .write = writeStack };
                panic_context.push(&entry);
                defer panic_context.pop(&entry);
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

            /// 正在计算的 query（`名字#key 下标`，栈底在前；很深时只写栈顶的若干个）
            fn writeStack(data: *const anyopaque, w: *Io.Writer) Io.Writer.Error!void {
                const ctx: *const Ctx = @ptrCast(@alignCast(data));
                const frames = ctx.stack.items;
                const shown = 24;
                try w.writeAll("queries:");
                if (frames.len > shown) try w.print(" ({d} more)", .{frames.len - shown});
                for (frames[frames.len -| shown..], 0..) |frame, i| {
                    try w.print("{s} {s}#{d}", .{ if (i == 0) "" else " >", query_names[frame.key.query], frame.key.index });
                }
            }

            const query_names = blk: {
                var names: [queries.len][]const u8 = undefined;
                for (queries, &names) |Q, *n| n.* = @typeName(Q);
                break :blk names;
            };

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
                            if (frame.key.eql(dep)) return ctx.onCycle(Q, @intCast(i), key);
                        }
                        if (@hasDecl(Q, "cycleFallback") and ctx.stackExhausted()) {
                            // 本 revision 已验证的结果可以直接使用，不会再深入
                            if (ctx.verifiedMemo(Q, index)) |fresh| break :blk fresh;
                            ctx.markIncomplete(.stack);
                            if (ctx.frontier == null) ctx.frontier = dep;
                            return if (@hasDecl(Q, "depthFallback")) Q.depthFallback(key) else Q.cycleFallback(key);
                        }
                        break :blk try ctx.ensureFresh(Q, index, key, true);
                    },
                };
                if (Q.kind == .derived and !fresh.executed) _ = db.counters[qi].hits.fetchAdd(1, .monotonic);
                if (Q.kind == .derived and fresh.in_cycle) return fresh.value;
                try ctx.recordDep(dep, fresh.durability);
                return fresh.value;
            }

            fn recordDep(ctx: *Ctx, dep: DepKey, durability: Durability) Allocator.Error!void {
                if (ctx.stack.items.len == 0) return;
                const top = &ctx.stack.items[ctx.stack.items.len - 1];
                top.durability = top.durability.min(durability);
                _ = try top.deps.getOrPut(ctx.db.gpa, dep);
            }

            /// 环中的结果不写入 memo，读取它的 query 不把它记为依赖，改为接过它读到的依赖（环中对栈上
            /// query 的读取不记为依赖，读到的是回退值）。环中的 query 可能另有单独计算出的 memo，值与环中算出的
            /// 不同：若记为依赖，它之后重算出与旧 memo 相同的值（early cutoff）时，依赖它的 memo 会被误判为未变；
            /// 环的入口也会与环内成员的 memo 互相依赖，验证时沿 memo 环反复递归
            fn inheritDeps(ctx: *Ctx, frame: *const Frame) Allocator.Error!void {
                const target = ctx.inheritTarget() orelse return;
                target.durability = target.durability.min(frame.durability);
                for (frame.deps.keys()) |dep| _ = try target.deps.getOrPut(ctx.db.gpa, dep);
            }

            /// 接过环中结果的依赖的帧：栈上最近的不在环中的帧。跳过的帧都在环中、不写入 memo，依赖不必
            /// 经过它们逐层传递（否则环中每一层都要合并上面各层的依赖）。`markIncomplete` 标记的帧及其下方
            /// 都不写入 memo，没有这样的帧
            fn inheritTarget(ctx: *Ctx) ?*Frame {
                var i = ctx.stack.items.len;
                while (i > 0) {
                    i -= 1;
                    const frame = &ctx.stack.items[i];
                    if (frame.incomplete) return null;
                    if (!frame.in_cycle) return frame;
                    // 环中位于栈最底层的 query 之上的各帧都在环中
                    if (frame.cycle_head) |head| i = @min(i, head + 1);
                }
                return null;
            }

            fn onCycle(ctx: *Ctx, comptime Q: type, head: u32, key: Q.Key) Q.Value {
                if (!@hasDecl(Q, "cycleFallback")) {
                    std.debug.panic("query cycle without cycleFallback: {s}", .{@typeName(Q)});
                }
                // 不动点的入口算一遍即得完整结果，只有环内的其他 query 依赖回退值
                const first = if (@hasDecl(Q, "fixpoint") and Q.fixpoint) head + 1 else head;
                _ = ctx.db.incomplete_causes[@backingInt(IncompleteCause.cycle)].fetchAdd(1, .monotonic);
                for (ctx.stack.items[first..]) |*frame| {
                    frame.in_cycle = true;
                    frame.cycle_head = @min(frame.cycle_head orelse head, head);
                }
                return Q.cycleFallback(key);
            }

            fn Fresh(comptime Q: type) type {
                return struct {
                    value: Q.Value,
                    changed_at: Revision,
                    durability: Durability,
                    executed: bool = false,
                    /// 环中的结果：它读到的依赖已交给栈上的帧（见 `inheritDeps`），读取方不再把它记为依赖
                    in_cycle: bool = false,
                    /// 结果在环中，或（只验证依赖时）因环无法验证而没有重算：栈上这个下标的 query 出栈前都是如此
                    cycle: ?u32 = null,
                };
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
            /// （只验证依赖）不恢复被淘汰的值、不重算因环无法验证的 memo，返回的 `value` 无效
            fn ensureFresh(ctx: *Ctx, comptime Q: type, index: u32, key: Q.Key, need_value: bool) Error!Fresh(Q) {
                const db = ctx.db;
                const table = &db.tables[comptime queryIndex(Q)];
                const dep: DepKey = .{ .query = comptime queryIndex(Q), .index = index };

                db.mutex.lockUncancelable(db.io);
                const existing = table.slots.items[index].memo;
                if (existing) |_| table.slots.items[index].memo.?.last_used = db.access_tick.fetchAdd(1, .monotonic);
                db.mutex.unlock(db.io);

                if (existing) |memo| verify: {
                    const verdict: Verdict = if (memo.verified_at == db.revision)
                        .{ .unchanged = memo.durability }
                    else if (ctx.unverifiableDepth(dep)) |depth|
                        .{ .cycle = depth }
                    else
                        try ctx.deepVerify(memo.verified_at, memo.durability, memo.deps);
                    const durability = switch (verdict) {
                        .unchanged => |d| d,
                        .changed => break :verify,
                        .cycle => |depth| {
                            try ctx.markUnverifiable(dep, depth);
                            if (need_value) break :verify;
                            return .{ .value = undefined, .changed_at = db.revision, .durability = .low, .cycle = depth };
                        },
                    };
                    // 值已被淘汰：依赖未变，重算出的值必然相同，沿用原 changed_at
                    if (memo.evicted) {
                        if (need_value) return ctx.execute(Q, index, key, true);
                        db.mutex.lockUncancelable(db.io);
                        defer db.mutex.unlock(db.io);
                        const m = &table.slots.items[index].memo.?;
                        markVerified(m, db.revision, durability);
                        return .{ .value = undefined, .changed_at = m.changed_at, .durability = m.durability };
                    }
                    db.mutex.lockUncancelable(db.io);
                    defer db.mutex.unlock(db.io);
                    // 可能已被并发读者重算替换，以表中当前值为准
                    const m = &table.slots.items[index].memo.?;
                    if (!m.evicted) {
                        markVerified(m, db.revision, durability);
                        return .{ .value = m.value, .changed_at = m.changed_at, .durability = m.durability };
                    }
                }
                return ctx.execute(Q, index, key, false);
            }

            fn unverifiableDepth(ctx: *const Ctx, dep: DepKey) ?u32 {
                for (ctx.unverifiable.items) |u| if (u.key.eql(dep)) return u.depth;
                return null;
            }

            fn markUnverifiable(ctx: *Ctx, dep: DepKey, depth: u32) Allocator.Error!void {
                for (ctx.unverifiable.items) |*u| if (u.key.eql(dep)) {
                    // 下标越小的 query 出栈越晚
                    u.depth = @min(u.depth, depth);
                    return;
                };
                try ctx.unverifiable.append(ctx.gpa, .{ .key = dep, .depth = depth });
            }

            /// 弹出栈顶帧：依赖经由环回到这一帧的 memo 不再无法验证
            fn popFrame(ctx: *Ctx) Frame {
                const frame = ctx.stack.pop().?;
                const depth = ctx.stack.items.len;
                var i: usize = 0;
                while (i < ctx.unverifiable.items.len) {
                    if (ctx.unverifiable.items[i].depth >= depth) {
                        _ = ctx.unverifiable.swapRemove(i);
                    } else i += 1;
                }
                return frame;
            }

            /// 验证通过的 memo 取依赖当前的最低 durability：依赖的输入降低 durability 而值经 early cutoff
            /// 未变时，memo 不能仍按旧的高 durability 在之后的验证中跳过依赖检查
            fn markVerified(m: anytype, revision: Revision, durability: Durability) void {
                if (m.verified_at < revision) m.durability = durability;
                m.verified_at = @max(m.verified_at, revision);
            }

            /// memo 依赖的验证结果
            const Verdict = union(enum) {
                /// 依赖的 changed_at 都不晚于 memo 的 `verified_at`，带依赖当前的最低 durability
                unchanged: Durability,
                /// 有依赖在 memo 验证之后变化
                changed,
                /// 依赖经由环回到栈上这个下标的 query，它出栈前无法验证（见 `Unverifiable`）
                cycle: u32,
            };

            fn deepVerify(ctx: *Ctx, verified_at: Revision, durability: Durability, deps: []const DepKey) Error!Verdict {
                const db = ctx.db;
                // 不低于 `durability` 的输入都未变化：依赖的 durability 也不会降低
                if (db.last_changed[@backingInt(durability)] <= verified_at) return .{ .unchanged = durability };
                _ = db.deep_verifications.fetchAdd(1, .monotonic);
                var lowest: Durability = .high;
                for (deps) |dep| {
                    const state = try ctx.depState(dep);
                    if (state.cycle) |depth| return .{ .cycle = depth };
                    if (state.changed_at > verified_at) return .changed;
                    lowest = lowest.min(state.durability);
                }
                return .{ .unchanged = lowest };
            }

            /// 把依赖带到最新状态并返回它的 changed_at 与 durability（不记录依赖）。`cycle` 见 `Fresh`
            fn depState(ctx: *Ctx, dep: DepKey) Error!struct { changed_at: Revision, durability: Durability, cycle: ?u32 = null } {
                const db = ctx.db;
                inline for (queries, 0..) |Q, qi| {
                    if (dep.query == qi) switch (Q.kind) {
                        .input => {
                            const input = db.readInput(Q, dep.index);
                            return .{ .changed_at = input.changed_at, .durability = input.durability };
                        },
                        .derived => {
                            db.mutex.lockUncancelable(db.io);
                            const key = db.tables[qi].keys.keys()[dep.index];
                            db.mutex.unlock(db.io);
                            for (ctx.stack.items, 0..) |frame, i| {
                                // 验证路径上回到了栈上的 query：它出栈前无法验证，强制上层重算
                                if (frame.key.eql(dep)) return .{ .changed_at = db.revision, .durability = .low, .cycle = @intCast(i) };
                            }
                            // 栈深度超过上限：同样视为已变化，由重算处理（重算时以回退值代替）
                            if (ctx.stackExhausted()) return .{ .changed_at = db.revision, .durability = .low };
                            const fresh = try ctx.ensureFresh(Q, dep.index, key, false);
                            return .{ .changed_at = fresh.changed_at, .durability = fresh.durability, .cycle = fresh.cycle };
                        },
                    };
                }
                unreachable;
            }

            /// `restore`：memo 的值已被淘汰而依赖未变，重算只为恢复值，沿用原 changed_at
            fn execute(ctx: *Ctx, comptime Q: type, index: u32, key: Q.Key, restore: bool) Error!Fresh(Q) {
                const db = ctx.db;
                const qi = comptime queryIndex(Q);
                _ = db.counters[qi].executions.fetchAdd(1, .monotonic);
                const zone = tracy.zone(@src(), @typeName(Q));
                defer zone.end();

                const t0 = Io.Clock.awake.now(db.io);
                const trace_index: ?usize = if (ctx.trace) |t| blk: {
                    t.events.append(t.gpa, .{ .query = qi, .key = index, .depth = @intCast(ctx.stack.items.len) }) catch break :blk null;
                    break :blk t.events.items.len - 1;
                } else null;
                try ctx.stack.append(ctx.gpa, .{ .key = .{ .query = qi, .index = index } });
                // 恢复被淘汰的值：此前已完整算出过，给它一份独立的燃料，不受本次请求剩余燃料的影响，
                // 否则恢复出的结果可能不完整（如 hover 偶尔显示 unknown）
                const saved_fuel = ctx.fuel;
                if (restore) ctx.fuel = default_fuel;
                defer if (restore) {
                    ctx.fuel = saved_fuel;
                };
                const computed = if (@hasDecl(Q, "computeIncremental")) blk: {
                    // 上一次的值在下一次写事务前不会被释放，可安全地作为增量计算的基础
                    db.mutex.lockUncancelable(db.io);
                    const prev: ?Q.Value = if (db.tables[qi].slots.items[index].memo) |m| (if (m.evicted) null else m.value) else null;
                    db.mutex.unlock(db.io);
                    break :blk Q.computeIncremental(ctx, key, prev);
                } else Q.compute(ctx, key);
                var value = computed catch |err| {
                    var frame = ctx.popFrame();
                    ctx.finishTiming(qi, &frame, t0, trace_index, true);
                    frame.deps.deinit(ctx.db.gpa);
                    return err;
                };
                // compute 可能吞掉了内层读取的 `Canceled`（`catch null` 之类的回退），结果不完整，
                // 不能写入 memo。取消标志在读事务结束前不会复位（写事务要等读者退出、拿到独占锁后
                // 才把 `pending_write` 减一），所以在这里检查一次即可发现
                if (ctx.checkCanceled()) |_| {} else |err| {
                    var frame = ctx.popFrame();
                    ctx.finishTiming(qi, &frame, t0, trace_index, true);
                    frame.deps.deinit(db.gpa);
                    // 新值没有发布过，没有其他引用：直接释放
                    deinitValue(Q, &value, db.gpa);
                    return err;
                }
                var frame = ctx.popFrame();
                ctx.finishTiming(qi, &frame, t0, trace_index, false);

                db.mutex.lockUncancelable(db.io);
                defer db.mutex.unlock(db.io);

                const slot = &db.tables[qi].slots.items[index];
                // 并发读者已在本 revision 发布结果，以它为准；新值没有发布过，直接释放
                if (slot.memo) |old| if (old.verified_at == db.revision and !old.evicted) {
                    frame.deps.deinit(db.gpa);
                    deinitValue(Q, &value, db.gpa);
                    return .{ .value = old.value, .changed_at = old.changed_at, .durability = old.durability, .executed = true };
                };
                // 环中的结果依赖于入口，不写入 memo。值返回给调用方使用，放入垃圾列表待读事务结束后释放
                if (frame.in_cycle) {
                    defer frame.deps.deinit(db.gpa);
                    db.discardLocked(Q, &value) catch |err| {
                        deinitValue(Q, &value, db.gpa);
                        return err;
                    };
                    try ctx.inheritDeps(&frame);
                    // 环中位于栈最底层的 query 仍在栈上：它出栈前本 query 都只能在环中计算
                    const cycle: ?u32 = if (frame.cycle_head) |head| (if (head < ctx.stack.items.len) head else null) else null;
                    if (cycle) |depth| try ctx.markUnverifiable(.{ .query = qi, .index = index }, depth);
                    return .{ .value = value, .changed_at = db.revision, .durability = .low, .executed = true, .in_cycle = true, .cycle = cycle };
                }

                // 提交 memo 之前失败：新值没有发布过，直接释放
                errdefer deinitValue(Q, &value, db.gpa);
                defer frame.deps.deinit(db.gpa);
                const deps = try db.gpa.dupe(DepKey, frame.deps.keys());
                errdefer db.gpa.free(deps);

                var changed_at = db.revision;
                const table = &db.tables[qi];
                if (slot.memo) |*old| {
                    const same = !old.evicted and valueEql(Q, old.value, value);
                    // 先完成全部可能失败的分配，再转移旧 memo 的资源：失败时旧 memo 保持完整（deps 仍归它所有）
                    try db.garbage.ensureUnusedCapacity(db.gpa, 2);
                    const box = if (old.evicted or same) null else try db.allocBox(Q);
                    // 此后不再失败
                    db.garbage.appendAssumeCapacity(.{ .deps = old.deps });
                    if (old.evicted) {
                        if (restore) changed_at = old.changed_at;
                        if (@hasDecl(Q, "lru")) table.live += 1;
                        if (@hasDecl(Q, "lru_bytes")) table.live_bytes += Q.bytes(value);
                    } else if (same) {
                        // early cutoff：保留旧值与旧 changed_at
                        changed_at = old.changed_at;
                        _ = db.counters[qi].cutoffs.fetchAdd(1, .monotonic);
                        if (ctx.trace) |t| if (trace_index) |ti| {
                            t.events.items[ti].cutoff = true;
                        };
                        deinitValue(Q, &value, db.gpa);
                        value = old.value;
                    } else {
                        if (@hasDecl(Q, "lru_bytes")) table.live_bytes = table.live_bytes - Q.bytes(old.value) + Q.bytes(value);
                        db.discardBoxed(Q, box, &old.value);
                    }
                } else {
                    if (@hasDecl(Q, "lru")) table.live += 1;
                    if (@hasDecl(Q, "lru_bytes")) table.live_bytes += Q.bytes(value);
                }
                if (@hasDecl(Q, "lru") and table.live > Q.lru) db.sweep_wanted.store(true, .monotonic);
                if (@hasDecl(Q, "lru_bytes") and table.live_bytes > Q.lru_bytes) db.sweep_wanted.store(true, .monotonic);
                slot.memo = .{
                    .value = value,
                    .verified_at = db.revision,
                    .changed_at = changed_at,
                    .durability = frame.durability,
                    .deps = deps,
                    .last_used = db.access_tick.fetchAdd(1, .monotonic),
                };
                return .{ .value = value, .changed_at = changed_at, .durability = frame.durability, .executed = true };
            }

            /// 记录一次 compute 的耗时：累计、自身（扣除其中执行的其他 query）与最长；计入外层帧的子耗时
            fn finishTiming(ctx: *Ctx, comptime qi: usize, frame: *const Frame, t0: Io.Timestamp, trace_index: ?usize, failed: bool) void {
                const db = ctx.db;
                const ns: u64 = @intCast(@max(0, t0.durationTo(Io.Clock.awake.now(db.io)).nanoseconds));
                const c = &db.counters[qi];
                _ = c.total_ns.fetchAdd(ns, .monotonic);
                _ = c.self_ns.fetchAdd(ns -| frame.child_ns, .monotonic);
                _ = c.max_ns.fetchMax(ns, .monotonic);
                if (ctx.stack.items.len > 0) ctx.stack.items[ctx.stack.items.len - 1].child_ns += ns;
                if (frame.in_cycle) _ = c.incomplete.fetchAdd(1, .monotonic);
                if (ctx.trace) |t| if (trace_index) |ti| {
                    t.events.items[ti].ns = ns;
                    t.events.items[ti].failed = failed;
                    t.events.items[ti].incomplete = frame.in_cycle;
                };
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

        /// 把值放入垃圾列表，下一次写事务时释放。调用方须持有 mutex。失败时值的所有权仍归调用方
        fn discardLocked(db: *Db, comptime Q: type, value: *Q.Value) Allocator.Error!void {
            try db.garbage.ensureUnusedCapacity(db.gpa, 1);
            db.discardBoxed(Q, try db.allocBox(Q), value);
        }

        /// 放入垃圾列表的值的存储；值不需要释放时为 null
        fn allocBox(db: *Db, comptime Q: type) Allocator.Error!?*Q.Value {
            return if (@hasDecl(Q, "deinit")) try db.gpa.create(Q.Value) else null;
        }

        /// 同 `discardLocked`，不会失败：调用方已预留垃圾列表的容量并分配好 `box`（`allocBox`）
        fn discardBoxed(db: *Db, comptime Q: type, box: ?*Q.Value, value: *Q.Value) void {
            if (!@hasDecl(Q, "deinit")) return;
            box.?.* = value.*;
            db.garbage.appendAssumeCapacity(.{ .value = .{ .ptr = @ptrCast(box.?), .free = struct {
                fn free(ptr: *anyopaque, gpa: Allocator) void {
                    const v: *Q.Value = @ptrCast(@alignCast(ptr));
                    Q.deinit(v, gpa);
                    gpa.destroy(v);
                }
            }.free } });
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
    if (@hasDecl(Q, "fixpoint") and !(@hasDecl(Q, "cycleFallback") and @hasDecl(Q, "depthFallback"))) {
        @compileError(@typeName(Q) ++ " declares fixpoint and must declare cycleFallback and depthFallback");
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
