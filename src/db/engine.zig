//! Query engine: revisions, memos, dependency tracking, early cutoff, durability, cancellation,
//! cycle detection.
//!
//! Each query is declared by a descriptor type:
//!
//! ```zig
//! pub const FileText = struct {
//!     pub const kind: db.Kind = .input;
//!     pub const Key = FileId;
//!     pub const Value = []const u8;
//!     pub const default: Value = "";              // value of an input that is not set
//!     pub fn eql(a: Value, b: Value) bool { ... } // required when Value contains pointers
//!     pub fn deinit(v: *Value, gpa: Allocator) void { ... } // optional
//! };
//!
//! pub const LineCount = struct {
//!     pub const kind: db.Kind = .derived;
//!     pub const Key = FileId;
//!     pub const Value = u32;
//!     pub fn compute(ctx: *Db.Ctx, key: Key) db.Error!Value { ... }
//!     pub fn cycleFallback(key: Key) Value { ... } // optional: fallback value when in a cycle
//!     pub fn depthFallback(key: Key) Value { ... } // optional: fallback when the stack depth
//!                                                  // limit is exceeded; defaults to cycleFallback
//! };
//! ```
//!
//! A derived query may declare `pub const fixpoint = true`: `cycleFallback` is the least element
//! of the values, and a read of itself within a cycle only merges the value read into the result
//! (e.g. error sets). One computation of the cycle head then yields the least fixpoint; the result
//! of the cycle head is written to its memo, while the results of the other queries in the cycle
//! are still not written. Exceeding the stack depth limit is not a cycle, and its fallback value
//! cannot be the least element, so `depthFallback` must be declared.
//!
//! A derived query may instead declare `computeIncremental(ctx, key, prev: ?Value)`: when
//! recomputing, the engine passes in the previous value (null on the first computation). The
//! result must be exactly the same as computing from scratch; prev is only used for speed, and
//! reading prev records no dependency.
//!
//! A query may declare `pub fn bytes(v: Value) usize`: the number of bytes a value occupies, used
//! only for statistics (`Db.stats`).
//!
//! A query that declares both `lru` and `bytes` may also declare `pub const lru_bytes: usize = N`:
//! when the retained values exceed N bytes, memos are likewise evicted by recency of use (when
//! value sizes vary widely, a count limit alone cannot bound memory).
//!
//! A derived query may declare `pub const lru: usize = N`: when more than N memos retain values,
//! the least recently used memos are evicted; only the value is deleted, while the dependencies
//! and changed_at are kept. An evicted memo that passes verification is recomputed and keeps its
//! original changed_at (compute is deterministic, so unchanged dependencies give the same result),
//! so nothing downstream is recomputed because of it. Eviction happens at the start of a write
//! transaction or in `trySweep` (when no read transaction holds values). `lru` and `lru_bytes` are
//! the default capacities and can be changed at run time with `setLru`.
//!
//! Concurrency model: read transactions (`beginRead`) hold a shared lock and may run concurrently;
//! a write transaction (`beginWrite`) first registers in `pending_write` so that in-flight read
//! queries exit with `error.Canceled` as soon as possible, then acquires the exclusive lock. A read
//! transaction begun with `beginReadAt` must see the state at an earlier `mark` and is canceled as
//! well when a write transaction ordered after the mark (`WriteOrder`) has begun since then.
//! Query values obtained in a read transaction stay valid until that transaction ends: replaced
//! old values are freed only at the next write transaction. Concurrent read transactions that need
//! the same memo brought up to date do it once: the first one claims it, and the others wait for
//! its result (see `Ctx.claim`).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const tracy = @import("../util/tracy.zig");
const panic_context = @import("../util/panic_context.zig");
const SpinMutex = @import("../util/SpinMutex.zig");

pub const Revision = u64;

pub const Kind = enum { input, derived };

/// How often an input changes. When verifying a memo, if no input in the lowest durability
/// level among its dependencies has changed since the last verification, checking the
/// dependencies one by one can be skipped.
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

/// Default native stack that nested computations in one read transaction may use. Beyond it,
/// queries with `cycleFallback` go no deeper: they return the fallback value, and none of the
/// queries currently on the stack are written to memos (the results depend on the stack depth
/// during evaluation and cannot be cached). The limit must be well below the smallest thread
/// stack (8 MB for the Linux main thread), leaving headroom for the stack used between two
/// checks. For threads with larger stacks, see `Db.stack_budget`.
pub const max_stack_bytes = 4 * 1024 * 1024;

/// Native stack a read transaction may use: threads other than `main` (the server's worker
/// threads, whose stack size is guaranteed by whoever sets this) may use `worker_bytes`; the
/// `main` thread, and all threads when `main` is not set, get `max_stack_bytes`
pub const StackBudget = struct {
    main: ?std.Thread.Id = null,
    worker_bytes: usize = max_stack_bytes,
};

/// Limit on how many times one top-level read "first computes the interruption point from the
/// bottom of the stack" (see `Ctx.get`), so that even infinite recursion terminates
pub const max_deepening = 16;

/// Dependency edge: (query index, index of the interned key)
pub const DepKey = struct {
    query: u16,
    index: u32,

    fn eql(a: DepKey, b: DepKey) bool {
        return a.query == b.query and a.index == b.index;
    }
};

pub const Stats = struct {
    /// One per registered query, in the same order
    queries: []const QueryStats,
    /// Number of dependency-by-dependency checks (not skipped by durability)
    deep_verifications: u64,
    /// Number of write transactions. A write that changes no value does not advance the revision,
    /// but still cancels in-flight read queries.
    writes: u64,
    revision: Revision,
    /// Number of incomplete results per cause
    incomplete_causes: std.EnumArray(IncompleteCause, u64),
};

/// Cumulative statistics of one query
pub const QueryStats = struct {
    /// Number of times compute ran
    executions: u64,
    /// Number of reads that used the memo directly (no execution needed)
    hits: u64,
    /// Number of re-executions whose result equaled the old value (early cutoff)
    cutoffs: u64,
    /// Cumulative compute time (including other queries executed within it)
    total_ns: u64,
    /// Cumulative time excluding other queries executed within it
    self_ns: u64,
    /// Longest single compute time (including other queries)
    max_ns: u64,
    /// Number of memos currently retaining a value
    memos: usize,
    /// Number of interned keys (including those whose value was evicted or never computed)
    keys: usize = 0,
    /// Bytes occupied by the retained values: counted when the query declares `bytes(value)`,
    /// otherwise 0
    bytes: usize = 0,
    /// Total number of dependency edges recorded by memos (memos whose value was evicted still
    /// keep their dependencies)
    deps: usize = 0,
    /// Number of results not written to memos because they were incomplete (cycle, stack depth):
    /// these results are recomputed on every read
    incomplete: u64 = 0,
};

/// Cause of an incomplete result
pub const IncompleteCause = enum {
    /// Took part in a cycle (queries that do not declare fixpoint)
    cycle,
    /// Nested computation exceeded the stack depth limit
    stack,
};

/// Queries executed in one read transaction (in preorder; the call tree can be reconstructed from
/// the depths), used by the slow-request log
pub const Trace = struct {
    gpa: Allocator,
    events: std.ArrayList(Event) = .empty,

    pub const Event = struct {
        query: u16,
        /// Index of the interned key (`Db.keyAt` retrieves the key)
        key: u32,
        depth: u16,
        /// Includes other queries executed within it
        ns: u64 = 0,
        cutoff: bool = false,
        failed: bool = false,
        /// The result is incomplete and was not written to the memo
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

/// `Env`: a read-only environment that queries can access through `ctx.db.env` (must not change
/// during the lifetime of the Db).
pub fn Engine(comptime Env: type, comptime queries: []const type) type {
    comptime for (queries) |Q| validate(Q);

    return struct {
        const Db = @This();

        pub const query_types = queries;

        /// A set of input queries, by index in `queries`: the inputs a write transaction may change
        /// (`beginWriteOf`), or the inputs the results of a read transaction may depend on (`mark`)
        pub const Inputs = std.bit_set.Static(queries.len);

        /// All input queries
        pub const all_inputs: Inputs = blk: {
            var all: Inputs = .empty;
            for (queries, 0..) |Q, qi| if (Q.kind == .input) all.set(qi);
            break :blk all;
        };

        pub fn inputSet(comptime list: []const type) Inputs {
            const inputs = comptime blk: {
                var s: Inputs = .empty;
                for (list) |Q| {
                    assert(Q.kind == .input);
                    s.set(queryIndex(Q));
                }
                break :blk s;
            };
            return inputs;
        }

        io: Io,
        gpa: Allocator,
        env: Env,

        /// Shared by read transactions, exclusive for write transactions
        rw: Io.RwLock = .init,
        /// Number of write transactions waiting for the exclusive lock; while nonzero, the queries of
        /// read transactions that may depend on any input exit with `error.Canceled` (a read
        /// transaction restricted to some inputs checks `pending_inputs` instead, see
        /// `Ctx.inputs`). A write transaction decrements it only after acquiring the lock: when
        /// several write transactions are queued, the first one to get the lock does not clear the
        /// registrations of the ones after it, so read transactions that get the shared lock in
        /// between are canceled as well.
        pending_write: std.atomic.Value(u32) = .init(0),
        /// Like `pending_write`, per input query (indexed like `queries`): the write transactions
        /// waiting for the exclusive lock that may change it
        pending_inputs: [queries.len]std.atomic.Value(u32) = @splat(.init(0)),
        /// Per input query (indexed like `queries`): the number of write transactions begun after
        /// the marks taken before them (`WriteOrder.after_marks`) that may change it, the position
        /// of a `Mark` restricted to some inputs
        input_writes: [queries.len]std.atomic.Value(u64) = @splat(.init(0)),
        /// Number of write transactions begun after the marks taken before them, the position of a
        /// `Mark` of all inputs
        ordered_writes: std.atomic.Value(u64) = .init(0),
        /// Number of in-flight read transactions. It must be 0 when memo values are freed
        /// (eviction, garbage collection, `resetQueries`), which is checked by assertions.
        active_readers: std.atomic.Value(u32) = .init(0),
        writing: bool = false,
        /// The inputs the current write transaction may set
        write_inputs: Inputs = .empty,
        bumped_in_write: bool = false,

        revision: Revision = 1,
        /// For each durability level, the last revision in which an input changed
        last_changed: [3]Revision = @splat(1),

        tables: Tables = tables_init,
        garbage: std.ArrayList(Garbage) = .empty,
        /// Protects `garbage` in read transactions; taken after the mutex of a table, never before
        garbage_mutex: SpinMutex = .{},
        /// Protects `Ctx.waiting_for` of all read transactions (see `Ctx.claim`); taken before the
        /// mutex of a table, never after
        wait_mutex: Io.Mutex = .init,
        /// Advanced, and its waiters woken, when a memo that read transactions wait for is released
        /// and when a write transaction registers (see `Ctx.claim`)
        wake_epoch: std.atomic.Value(u32) = .init(0),
        /// Number of read transactions waiting for a memo claimed by another one
        waiting: std.atomic.Value(u32) = .init(0),

        counters: [queries.len]Counters = @splat(.{}),
        incomplete_causes: [@typeInfo(IncompleteCause).@"enum".field_names.len]std.atomic.Value(u64) = @splat(.init(0)),
        deep_verifications: std.atomic.Value(u64) = .init(0),
        /// See `Stats.writes`
        writes: std.atomic.Value(u64) = .init(0),
        /// Counter for the last-use times of memos (LRU)
        access_tick: std.atomic.Value(u64) = .init(0),
        /// Some query that declares `lru` is over capacity and waits for `sweep`
        sweep_wanted: std.atomic.Value(bool) = .init(false),
        /// Current capacities of the queries that declare `lru` (see `setLru`), indexed like
        /// `queries`
        lru_limits: [queries.len]LruLimit = lru_defaults,
        /// Native stack read transactions may use; set before starting read transactions
        stack_budget: StackBudget = .{},

        /// Upper limits on the count and bytes of memos that retain values
        const LruLimit = struct {
            count: std.atomic.Value(usize),
            bytes: std.atomic.Value(usize),
        };
        const lru_defaults = blk: {
            var limits: [queries.len]LruLimit = undefined;
            for (queries, &limits) |Q, *l| l.* = .{
                .count = .init(if (@hasDecl(Q, "lru")) Q.lru else std.math.maxInt(usize)),
                .bytes = .init(if (@hasDecl(Q, "lru_bytes")) Q.lru_bytes else std.math.maxInt(usize)),
            };
            break :blk limits;
        };

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
                /// Protects the keys, slots, and counts of this table in read transactions (a
                /// write transaction has exclusive access). One lock per table rather than one for
                /// all tables: concurrent reads keep taking these locks at a high rate, and with a
                /// single lock the threads would mostly wait for each other.
                mutex: SpinMutex = .{},
                keys: std.AutoArrayHashMapUnmanaged(Q.Key, void) = .empty,
                slots: std.ArrayList(Slot) = .empty,
                /// Number of memos retaining a value (counted only for queries that declare `lru`)
                live: usize = 0,
                /// Bytes of the retained values (counted only for queries that declare `lru_bytes`)
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
                        /// The read transaction bringing the memo up to date (see `Ctx.claim`)
                        owner: ?*Ctx = null,
                        /// Other read transactions wait for `owner` to release it
                        waited: bool = false,
                    },
                };

                const Memo = struct {
                    /// Invalid when `evicted`
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

        /// Old values whose release is deferred (read transactions may still hold pointers to them)
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

        /// Number of keys of query `Q` (including those whose value was evicted). Called outside
        /// of transactions: adding and removing keys is protected by the exclusive lock of
        /// write transactions.
        pub fn keyCount(db: *Db, comptime Q: type) usize {
            db.rw.lockSharedUncancelable(db.io);
            defer db.rw.unlockShared(db.io);
            return db.keyCountLocked(Q);
        }

        /// Same as `keyCount`; the caller already holds a read or write transaction
        /// (shared/exclusive rw lock)
        pub fn keyCountLocked(db: *Db, comptime Q: type) usize {
            const table = &db.tables[comptime queryIndex(Q)];
            table.mutex.lockUncancelable(db.io);
            defer table.mutex.unlock(db.io);
            return table.keys.count();
        }

        pub fn queryIndex(comptime Q: type) u16 {
            inline for (queries, 0..) |Candidate, i| {
                if (Candidate == Q) return i;
            }
            @compileError("query not registered: " ++ @typeName(Q));
        }

        pub fn stats(db: *Db, buf: *[queries.len]QueryStats) Stats {
            inline for (queries, 0..) |Q, qi| {
                const table = &db.tables[qi];
                table.mutex.lockUncancelable(db.io);
                defer table.mutex.unlock(db.io);
                const c = &db.counters[qi];
                var memos: usize = 0;
                var bytes: usize = 0;
                var deps: usize = 0;
                for (table.slots.items) |slot| switch (Q.kind) {
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
                    .keys = table.keys.count(),
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
                .writes = db.writes.load(.monotonic),
                .revision = db.revision,
                .incomplete_causes = causes,
            };
        }

        /// Number of executions (for tests and tools)
        pub fn executions(db: *Db, comptime Q: type) u64 {
            return db.counters[comptime queryIndex(Q)].executions.load(.monotonic);
        }

        /// Key at index `index` in the `query`-th query (the key of a `Trace.Event`)
        pub fn keyAt(db: *Db, comptime Q: type, index: u32) Q.Key {
            const table = &db.tables[comptime queryIndex(Q)];
            table.mutex.lockUncancelable(db.io);
            defer table.mutex.unlock(db.io);
            return table.keys.keys()[index];
        }

        // ── Write transactions ─────────────────────────────────────────────

        /// Begins a write transaction that may set any input, ordered after all marks taken before
        /// it: cancels in-flight read queries and waits for all read transactions to finish.
        pub fn beginWrite(db: *Db) void {
            db.beginWriteOf(all_inputs, .after_marks);
        }

        /// How a write transaction relates to the read transactions bound to marks taken before it
        /// (`beginReadAt`)
        pub const WriteOrder = enum {
            /// It comes after them: they are canceled even when they begin after it has finished
            /// (such as an edit applied after a request was received)
            after_marks,
            /// It is not ordered with them (such as the updates a server makes on its own, which
            /// happen independently of the requests): one that begins after it has finished reads
            /// its changes; one in progress is still canceled
            unordered,
        };

        /// Begins a write transaction that sets only the inputs in `changes`: cancels the in-flight
        /// queries of the read transactions that may depend on them, and waits for all read
        /// transactions to finish (those that cannot depend on them run to completion, since the
        /// write cannot change their results).
        pub fn beginWriteOf(db: *Db, changes: Inputs, order: WriteOrder) void {
            _ = db.writes.fetchAdd(1, .monotonic);
            if (order == .after_marks) _ = db.ordered_writes.fetchAdd(1, .monotonic);
            var it = changes.iterator(.{});
            while (it.next()) |qi| {
                if (order == .after_marks) _ = db.input_writes[qi].fetchAdd(1, .monotonic);
                _ = db.pending_inputs[qi].fetchAdd(1, .seq_cst);
            }
            _ = db.pending_write.fetchAdd(1, .seq_cst);
            // Read transactions waiting for a memo another one computes check for cancellation
            // when woken (see `Ctx.waitFor`)
            if (db.waiting.load(.seq_cst) != 0) db.wakeWaiters();
            db.rw.lockUncancelable(db.io);
            _ = db.pending_write.fetchSub(1, .release);
            it = changes.iterator(.{});
            while (it.next()) |qi| _ = db.pending_inputs[qi].fetchSub(1, .release);
            db.writing = true;
            db.write_inputs = changes;
            db.bumped_in_write = false;
            db.collectGarbage();
            db.evictLocked();
        }

        /// Begins a write transaction only when no read transaction is in progress, without
        /// canceling or waiting for any (`beginWrite` would cancel the in-flight reads, and a write
        /// queued for the lock would block all later read transactions until the slowest read
        /// transaction finishes, since the rw lock prefers writers). For writes that set no input,
        /// such as reclaiming caches: they invalidate no result, so they must not cost readers
        /// their work. Returns false when the lock cannot be taken.
        pub fn tryBeginWrite(db: *Db) bool {
            if (!db.rw.tryLock(db.io)) return false;
            db.writing = true;
            db.write_inputs = .empty;
            db.bumped_in_write = false;
            db.collectGarbage();
            db.evictLocked();
            return true;
        }

        /// Whether any query exceeds its `lru` capacity (the caller may call `trySweep` when idle)
        pub fn wantsSweep(db: *Db) bool {
            return db.sweep_wanted.load(.monotonic);
        }

        /// Changes the capacity of a query that declares `lru` and `lru_bytes`: the number and
        /// bytes of memos that retain values; null means the declared default, 0 means unlimited.
        /// Whatever exceeds the new capacity is evicted at the next sweep.
        pub fn setLru(db: *Db, comptime Q: type, count: ?usize, bytes: ?usize) void {
            if (comptime !@hasDecl(Q, "lru") or !@hasDecl(Q, "lru_bytes")) @compileError(@typeName(Q) ++ " does not declare lru and lru_bytes");
            const limit = &db.lru_limits[comptime queryIndex(Q)];
            limit.count.store(lruValue(count, Q.lru), .monotonic);
            limit.bytes.store(lruValue(bytes, Q.lru_bytes), .monotonic);
            db.sweep_wanted.store(true, .monotonic);
        }

        fn lruValue(configured: ?usize, default: usize) usize {
            const v = configured orelse return default;
            return if (v == 0) std.math.maxInt(usize) else v;
        }

        fn overLru(db: *Db, comptime Q: type, table: *const Table(Q)) bool {
            const limit = &db.lru_limits[comptime queryIndex(Q)];
            return table.live > limit.count.load(.monotonic) or table.live_bytes > limit.bytes.load(.monotonic);
        }

        /// Evicts memo values beyond the `lru` capacity. Runs only when there is no read
        /// transaction (see `tryBeginWrite`). Returns false when the lock cannot be taken, leaving
        /// the work to the next write transaction or the next sweep.
        pub fn trySweep(db: *Db) bool {
            if (!db.tryBeginWrite()) return false;
            db.endWrite();
            return true;
        }

        /// For each query over capacity, evicts the least recently used memos down to 3/4 of the
        /// capacity (leaving headroom to avoid frequent sweeps). The caller must have exclusive
        /// access to the database (no read transaction holds values).
        fn evictLocked(db: *Db) void {
            if (!db.sweep_wanted.swap(false, .monotonic)) return;
            db.assertNoReaders();
            inline for (queries, 0..) |Q, qi| {
                if (comptime Q.kind == .derived and @hasDecl(Q, "lru")) {
                    const table = &db.tables[qi];
                    if (db.overLru(Q, table)) {
                        const limit = &db.lru_limits[qi];
                        evictTable(Q, table, db.gpa, limit.count.load(.monotonic), limit.bytes.load(.monotonic));
                    }
                }
            }
        }

        /// Evicts from the least to the most recently used until both the count and the bytes are
        /// down to 3/4 of the limits (leaving headroom to avoid frequent sweeps)
        fn evictTable(comptime Q: type, table: *Table(Q), gpa: Allocator, count: usize, bytes: usize) void {
            const target_count = threeQuarters(count);
            const target_bytes = threeQuarters(bytes);
            const Entry = struct { tick: u64, slot: u32 };
            // On out-of-memory, fall back to evicting everything
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

        /// ⌊n × 3/4⌋, without overflow when n is the maximum value (unlimited)
        fn threeQuarters(n: usize) usize {
            return n / 4 * 3 + n % 4 * 3 / 4;
        }

        fn evictMemo(comptime Q: type, table: *Table(Q), m: *Table(Q).Memo, gpa: Allocator) void {
            if (@hasDecl(Q, "lru_bytes")) table.live_bytes -= Q.bytes(m.value);
            deinitValue(Q, &m.value, gpa);
            m.value = undefined;
            m.evicted = true;
            table.live -= 1;
        }

        /// Clears all keys and memos of these derived queries, so that external state referenced
        /// by their keys or values (e.g. the InternPool) can be reclaimed. Dependency edges are
        /// recorded by key index, and the indices become invalid after clearing: memos of other
        /// queries that depend on them are discarded too (recomputed when read again). Advances
        /// the revision and marks all durability levels as changed, so all remaining memos are
        /// re-verified. May only be called in a write transaction.
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

        /// Ensures the key and slot of an input are interned; afterwards `set` no longer allocates.
        /// Within a write transaction this avoids leaving a partial update when OOM happens between
        /// two sets.
        pub fn ensureInput(db: *Db, comptime Q: type, key: Q.Key) Allocator.Error!void {
            comptime assert(Q.kind == .input);
            assert(db.writing and db.write_inputs.isSet(comptime queryIndex(Q)));
            _ = try db.internLocked(Q, key);
        }

        /// Sets an input; the engine takes ownership of `value`. Does not advance the revision when
        /// the value equals the old value. The write transaction must have declared the input (see
        /// `beginWriteOf`).
        pub fn set(db: *Db, comptime Q: type, key: Q.Key, value: Q.Value, durability: Durability) Allocator.Error!void {
            comptime assert(Q.kind == .input);
            assert(db.writing and db.write_inputs.isSet(comptime queryIndex(Q)));
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
            // Take the higher of the old and new durability, so that high-durability memos that
            // depend on the old value are re-verified too
            const effective = durability.max(slot.durability);
            for (0..@as(usize, @backingInt(effective)) + 1) |d| db.last_changed[d] = db.revision;

            if (slot.is_set) deinitValue(Q, &slot.value, db.gpa);
            slot.* = .{ .value = value, .is_set = true, .changed_at = db.revision, .durability = durability };
        }

        /// Reads the current value of an input in a write transaction (records no dependency).
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

        /// Wakes the read transactions waiting for memos claimed by others, which then check
        /// whether they can go on (see `Ctx.claim`)
        fn wakeWaiters(db: *Db) void {
            _ = db.wake_epoch.fetchAdd(1, .seq_cst);
            db.io.futexWake(u32, &db.wake_epoch.raw, std.math.maxInt(u32));
        }

        // ── Read transactions ──────────────────────────────────────────────

        pub fn beginRead(db: *Db, gpa: Allocator) Ctx {
            return db.beginReadAt(gpa, null);
        }

        /// A point in the sequence of write transactions that may change some inputs (see
        /// `beginReadAt`)
        pub const Mark = struct {
            /// The inputs the read may depend on; null means all
            inputs: ?Inputs,
            writes: u64,
        };

        /// The current point in the sequence of write transactions that may change `inputs` (null
        /// means all inputs)
        pub fn mark(db: *Db, inputs: ?Inputs) Mark {
            return .{ .inputs = inputs, .writes = db.writesTo(inputs) };
        }

        /// Number of write transactions ordered after earlier marks (`WriteOrder.after_marks`)
        /// begun that may change any of `inputs` (null: all), counted once per input: it grows
        /// exactly when such a write transaction begins
        fn writesTo(db: *Db, inputs: ?Inputs) u64 {
            const some = inputs orelse return db.ordered_writes.load(.acquire);
            var n: u64 = 0;
            var it = some.iterator(.{});
            while (it.next()) |qi| n += db.input_writes[qi].load(.acquire);
            return n;
        }

        /// Begins a read transaction for a read that must see the inputs as they were at `since`
        /// (taken earlier with `mark`), such as a request that is answered on the state it was
        /// received in: when a write transaction ordered after the mark (`WriteOrder.after_marks`)
        /// that may change the inputs of the mark has begun since then, even one that has already
        /// finished, the read transaction is canceled (its reads return `error.Canceled`). Write
        /// transactions that cannot change those inputs do not cancel it at all (see `Ctx.inputs`).
        /// Null reads the current state of all inputs.
        pub fn beginReadAt(db: *Db, gpa: Allocator, since: ?Mark) Ctx {
            db.rw.lockSharedUncancelable(db.io);
            _ = db.active_readers.fetchAdd(1, .acq_rel);
            const main = db.stack_budget.main orelse std.Thread.getCurrentId();
            const budget = if (std.Thread.getCurrentId() == main) max_stack_bytes else db.stack_budget.worker_bytes;
            const m = since orelse return .{ .db = db, .gpa = gpa, .stack_base = @frameAddress(), .stack_budget = budget };
            const stale = db.writesTo(m.inputs) != m.writes;
            return .{ .db = db, .gpa = gpa, .stack_base = @frameAddress(), .stack_budget = budget, .inputs = m.inputs, .stale = stale };
        }

        pub const Ctx = struct {
            db: *Db,
            gpa: Allocator,
            /// Cancellation flag of a single request (corresponds to `$/cancelRequest`)
            cancel: ?*const std.atomic.Value(bool) = null,
            /// Records the executed queries (slow-request log); nothing is recorded when null
            trace: ?*Trace = null,
            /// The inputs the results of this read transaction may depend on (null: all). Write
            /// transactions that cannot change any of them do not cancel it: they wait for it to
            /// finish, as its results stay valid. Reading another input is a bug, checked in Debug
            /// builds.
            inputs: ?Inputs = null,
            /// A write transaction began after the point this read transaction must see (see
            /// `beginReadAt`): all its reads are canceled
            stale: bool = false,
            stack: std.ArrayList(Frame) = .empty,
            /// Stack position where the read transaction began (the stack grows downward)
            stack_base: usize,
            /// Native stack nested computations may use (bytes)
            stack_budget: usize,
            /// The first query interrupted by the stack depth limit in the current top-level read
            frontier: ?DepKey = null,
            /// Number of interruption points already computed from the bottom of the stack in the
            /// current top-level read
            deepening: u32 = 0,
            /// Memos that cannot be verified on the current stack, deduplicated by key
            unverifiable: std.ArrayList(Unverifiable) = .empty,
            /// Keys of the frames at stack index `linear_frames` or above, in stack order (item i
            /// is the frame at index `linear_frames + i`). To check whether a query is on the
            /// stack, the frames at the bottom of the stack are searched linearly and the rest are
            /// looked up here: comparing frame by frame on a very deep stack would make the cost of
            /// the computation grow quadratically with the depth.
            deep_frames: std.array_hash_map.Auto(DepKey, void) = .empty,
            /// The memo this read transaction waits for another one to bring up to date (see
            /// `claim`); protected by `Db.wait_mutex`
            waiting_for: ?DepKey = null,

            const linear_frames = 64;

            /// The dependencies of the memo lead through a cycle back to the query at stack index
            /// `depth` (encountered during verification, or in a cycle during recomputation). Until
            /// that query is popped, the memo is treated as unverifiable: reading it recomputes it
            /// directly (the result is not written to the memo when it is in a cycle), and
            /// verifying other memos treats it as changed without recomputing it. Otherwise every
            /// read within the cycle would re-verify and recompute its whole dependency chain, and
            /// since the recomputed results are not kept, the cost would grow exponentially with
            /// the chain length.
            const Unverifiable = struct { key: DepKey, depth: u32 };

            /// Dependencies recorded in a frame, deduplicated, in recording order. With few
            /// dependencies they are searched linearly; with many, a hash index is built: a frame
            /// that has taken over the dependencies of results in a cycle can have many.
            const DepSet = std.array_hash_map.Custom(DepKey, void, std.array_hash_map.AutoContext(DepKey), false);

            /// `deps` is allocated with `db.gpa` because the memo ends up owning it
            const Frame = struct {
                key: DepKey,
                deps: DepSet = .empty,
                durability: Durability = .high,
                /// This frame takes part in a cycle; its result is not written to a memo
                in_cycle: bool = false,
                /// Marked by `markIncomplete`: neither this frame nor the frames below it are
                /// written to memos
                incomplete: bool = false,
                /// Stack index of the bottom-most query of the cycle this frame is in (not set by
                /// `markIncomplete`)
                cycle_head: ?u32 = null,
                /// Time spent in other queries executed within this frame (for the self time)
                child_ns: u64 = 0,
            };

            pub fn end(ctx: *Ctx) void {
                assert(ctx.stack.items.len == 0 and ctx.unverifiable.items.len == 0 and ctx.deep_frames.count() == 0 and ctx.waiting_for == null);
                ctx.stack.deinit(ctx.gpa);
                ctx.unverifiable.deinit(ctx.gpa);
                ctx.deep_frames.deinit(ctx.gpa);
                _ = ctx.db.active_readers.fetchSub(1, .acq_rel);
                ctx.db.rw.unlockShared(ctx.db.io);
                ctx.* = undefined;
            }

            /// Native stack bytes already used by the nested computations of this read transaction
            pub fn stackUsed(ctx: *const Ctx) usize {
                const here = @frameAddress();
                return if (ctx.stack_base > here) ctx.stack_base - here else 0;
            }

            /// The native stack used by the nested computations of this read transaction exceeds
            /// `stack_budget`. A recursive compute should check this before going deeper and, when
            /// it is exceeded, return an unknown result and call `markIncomplete`.
            pub fn stackExhausted(ctx: *const Ctx) bool {
                const here = @frameAddress();
                return ctx.stack_base > here and ctx.stack_base - here > ctx.stack_budget;
            }

            /// Marks the current result as incomplete: no query on the stack is written to a memo
            pub fn markIncomplete(ctx: *Ctx, cause: IncompleteCause) void {
                _ = ctx.db.incomplete_causes[@backingInt(cause)].fetchAdd(1, .monotonic);
                for (ctx.stack.items) |*frame| {
                    frame.in_cycle = true;
                    frame.incomplete = true;
                }
            }

            /// compute was interrupted internally by the stack depth limit: in addition to
            /// `markIncomplete`, records the query being computed, which the top-level read will
            /// first compute from the bottom of the stack
            pub fn exhausted(ctx: *Ctx) void {
                ctx.markIncomplete(.stack);
                if (ctx.frontier == null and ctx.stack.items.len > 0) ctx.frontier = ctx.stack.items[ctx.stack.items.len - 1].key;
            }

            /// The result of the current computation is already incomplete (cycle, depth limit):
            /// computation should not go deeper to improve the result, or results that are not
            /// written to memos would be recomputed at every level
            pub fn incomplete(ctx: *const Ctx) bool {
                const n = ctx.stack.items.len;
                return n > 0 and ctx.stack.items[n - 1].in_cycle;
            }

            /// Long-running computes should call this periodically.
            pub fn checkCanceled(ctx: *const Ctx) error{Canceled}!void {
                if (ctx.stale) return error.Canceled;
                const db = ctx.db;
                if (ctx.inputs) |inputs| {
                    var it = inputs.iterator(.{});
                    while (it.next()) |qi| if (db.pending_inputs[qi].load(.acquire) != 0) return error.Canceled;
                } else if (db.pending_write.load(.acquire) != 0) return error.Canceled;
                if (ctx.cancel) |c| if (c.load(.acquire)) return error.Canceled;
            }

            /// Reads the value of a query and records it as a dependency of the query currently
            /// being computed. The returned value is valid until this read transaction ends.
            ///
            /// When the nested computation of a top-level read (one not inside the computation of
            /// another query) is interrupted by the stack depth limit, the query at the
            /// interruption point is first computed from the bottom of the stack (its result is
            /// written to the memo when complete), and then the read is recomputed, until the
            /// result is complete, no progress is made, or `max_deepening` interruption points have
            /// been computed. Very deep dependency chains are thus computed in segments, at a total
            /// cost proportional to the chain length, and the result is still complete.
            pub fn get(ctx: *Ctx, comptime Q: type, key: Q.Key) Error!Q.Value {
                if (Q.kind == .input or ctx.stack.items.len != 0) return ctx.getInner(Q, key);
                // On panic, write out the queries being computed
                var entry: panic_context.Entry = .{ .data = ctx, .write = writeStack };
                panic_context.push(&entry);
                defer panic_context.pop(&entry);
                ctx.deepening = 0;
                return ctx.getDeepening(Q, key);
            }

            /// Segmented computation of a top-level read. Computing an interruption point from the
            /// bottom of the stack calls it recursively, sharing the interruption-point count with
            /// the outer call: every segment of an infinite recursion is incomplete, and the count
            /// bounds the nesting depth.
            fn getDeepening(ctx: *Ctx, comptime Q: type, key: Q.Key) Error!Q.Value {
                while (true) {
                    ctx.frontier = null;
                    const v = try ctx.getInner(Q, key);
                    const frontier = ctx.frontier orelse return v;
                    if (ctx.deepening >= max_deepening) return v;
                    ctx.deepening += 1;
                    // No progress if the interruption point is still incomplete
                    if (!try ctx.precompute(frontier)) return v;
                }
            }

            /// Queries being computed (`<name>#<key index>`, bottom of the stack first; when very
            /// deep, only the topmost few are written)
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

            /// Computes `dep` from the bottom of the stack; returns whether its result was written
            /// to the memo
            fn precompute(ctx: *Ctx, dep: DepKey) Error!bool {
                const db = ctx.db;
                inline for (queries, 0..) |Q, qi| {
                    if (Q.kind == .derived and dep.query == qi) {
                        const table = &db.tables[qi];
                        table.mutex.lockUncancelable(db.io);
                        const key = table.keys.keys()[dep.index];
                        table.mutex.unlock(db.io);
                        _ = try ctx.getDeepening(Q, key);
                        return ctx.verifiedMemo(Q, dep.index) != null;
                    }
                }
                return false;
            }

            fn getInner(ctx: *Ctx, comptime Q: type, key: Q.Key) Error!Q.Value {
                try ctx.checkCanceled();
                const qi = comptime queryIndex(Q);
                const db = ctx.db;
                if (Q.kind == .input and builtin.mode == .debug) if (ctx.inputs) |inputs| if (!inputs.isSet(qi)) {
                    std.debug.panic("{s} read in a read transaction that does not declare it", .{@typeName(Q)});
                };

                // Interning the key and reading its slot take the table's lock once: reads of
                // values that are already up to date need no other lock
                const table = &db.tables[qi];
                table.mutex.lockUncancelable(db.io);
                const index = db.internLocked(Q, key) catch |err| {
                    table.mutex.unlock(db.io);
                    return err;
                };
                const slot = switch (Q.kind) {
                    .input => db.readInputLocked(Q, index),
                    .derived => db.useMemoLocked(Q, index),
                };
                table.mutex.unlock(db.io);
                const dep: DepKey = .{ .query = qi, .index = index };

                const fresh = switch (Q.kind) {
                    .input => slot,
                    .derived => blk: {
                        if (ctx.stackIndex(dep)) |i| return ctx.onCycle(Q, i, key);
                        if (@hasDecl(Q, "cycleFallback") and ctx.stackExhausted()) {
                            // A result already verified in this revision can be used directly,
                            // without going deeper
                            if (ctx.verifiedMemo(Q, index)) |fresh| break :blk fresh;
                            ctx.markIncomplete(.stack);
                            if (ctx.frontier == null) ctx.frontier = dep;
                            return if (@hasDecl(Q, "depthFallback")) Q.depthFallback(key) else Q.cycleFallback(key);
                        }
                        break :blk try ctx.ensureFresh(Q, index, key, true, slot);
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

            /// A result in a cycle is not written to a memo; a query that reads it does not record
            /// it as a dependency but inherits the dependencies it read instead (reads of queries
            /// on the stack within a cycle are not recorded as dependencies, and they read the
            /// fallback value). A query in a cycle may also have a separately computed memo whose
            /// value differs from the one computed in the cycle: if it were recorded as a
            /// dependency, then when it is later recomputed to the same value as its old memo
            /// (early cutoff), the memos depending on it would be wrongly judged unchanged; the
            /// cycle head and the memos of the cycle members would also depend on each other, so
            /// verification would recurse around the memo cycle again and again.
            fn inheritDeps(ctx: *Ctx, frame: *const Frame) Allocator.Error!void {
                const target = ctx.inheritTarget() orelse return;
                target.durability = target.durability.min(frame.durability);
                for (frame.deps.keys()) |dep| _ = try target.deps.getOrPut(ctx.db.gpa, dep);
            }

            /// The frame that inherits the dependencies of a result in a cycle: the nearest frame
            /// on the stack that is not in a cycle. The skipped frames are all in the cycle and are
            /// not written to memos, so the dependencies need not be passed through them level by
            /// level (otherwise every level of the cycle would have to merge the dependencies of
            /// all the levels above it). A frame marked by `markIncomplete` and the frames below it
            /// are not written to memos, so there is no such frame then.
            fn inheritTarget(ctx: *Ctx) ?*Frame {
                var i = ctx.stack.items.len;
                while (i > 0) {
                    i -= 1;
                    const frame = &ctx.stack.items[i];
                    if (frame.incomplete) return null;
                    if (!frame.in_cycle) return frame;
                    // All frames above the bottom-most query of the cycle are in the cycle
                    if (frame.cycle_head) |head| i = @min(i, head + 1);
                }
                return null;
            }

            fn onCycle(ctx: *Ctx, comptime Q: type, head: u32, key: Q.Key) Q.Value {
                if (!@hasDecl(Q, "cycleFallback")) {
                    std.debug.panic("query cycle without cycleFallback: {s}", .{@typeName(Q)});
                }
                // One computation of a fixpoint cycle head gives the complete result; only the
                // other queries in the cycle depend on the fallback value
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
                    /// A result in a cycle: its dependencies were handed to a frame on the stack
                    /// (see `inheritDeps`), so the reader no longer records it as a dependency
                    in_cycle: bool = false,
                    /// The result is in a cycle, or (when only verifying dependencies) it was not
                    /// recomputed since a cycle makes it unverifiable: this holds until the query
                    /// at this stack index is popped
                    cycle: ?u32 = null,
                };
            }

            fn verifiedMemo(ctx: *Ctx, comptime Q: type, index: u32) ?Fresh(Q) {
                const db = ctx.db;
                const table = &db.tables[comptime queryIndex(Q)];
                table.mutex.lockUncancelable(db.io);
                defer table.mutex.unlock(db.io);
                const memo = &(table.slots.items[index].memo orelse return null);
                if (memo.verified_at != db.revision or memo.evicted) return null;
                memo.last_used = db.access_tick.fetchAdd(1, .monotonic);
                return .{ .value = memo.value, .changed_at = memo.changed_at, .durability = memo.durability };
            }

            /// Whether a memo as read from the table can be used without verifying it: it was
            /// verified in this revision, and nobody replaces the value until the next write
            /// transaction (see `execute`); an evicted value is restored only when `need_value`
            fn upToDate(memo: anytype, revision: Revision, need_value: bool) bool {
                return memo.verified_at == revision and (!memo.evicted or !need_value);
            }

            /// The result of a memo that is up to date (`upToDate`); `value` is invalid when the
            /// value was evicted
            fn freshMemo(comptime Q: type, memo: Table(Q).Memo) Fresh(Q) {
                var fresh: Fresh(Q) = .{ .value = undefined, .changed_at = memo.changed_at, .durability = memo.durability };
                if (!memo.evicted) fresh.value = memo.value;
                return fresh;
            }

            /// Ensures that a derived memo is valid in the current revision, verifying or
            /// recomputing it as needed; `existing` is the memo as read from the table (see
            /// `useMemoLocked`). When `need_value` is false (only verifying dependencies), an
            /// evicted value is not restored and a memo that a cycle makes unverifiable is not
            /// recomputed; the returned `value` is then invalid.
            fn ensureFresh(ctx: *Ctx, comptime Q: type, index: u32, key: Q.Key, need_value: bool, existing: ?Table(Q).Memo) Error!Fresh(Q) {
                const db = ctx.db;
                const table = &db.tables[comptime queryIndex(Q)];
                const dep: DepKey = .{ .query = comptime queryIndex(Q), .index = index };

                if (existing) |memo| if (upToDate(memo, db.revision, need_value)) return freshMemo(Q, memo);
                var held: Claim = .{};
                defer ctx.endClaim(Q, index, &held);
                const current = switch (try ctx.claim(Q, index, need_value, &held)) {
                    .ready => |fresh| return fresh,
                    .stale => |memo| memo,
                };
                if (current) |memo| verify: {
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
                    // The value was evicted: the dependencies are unchanged, so a recomputed value
                    // is necessarily the same; keep the original changed_at
                    if (memo.evicted) {
                        if (need_value) return ctx.execute(Q, index, key, true, &held);
                        table.mutex.lockUncancelable(db.io);
                        defer table.mutex.unlock(db.io);
                        const slot = &table.slots.items[index];
                        ctx.releaseLocked(slot, &held);
                        const m = &slot.memo.?;
                        markVerified(m, db.revision, durability);
                        return .{ .value = undefined, .changed_at = m.changed_at, .durability = m.durability };
                    }
                    table.mutex.lockUncancelable(db.io);
                    defer table.mutex.unlock(db.io);
                    const slot = &table.slots.items[index];
                    // Without the claim, a concurrent reader may have recomputed and replaced it;
                    // the current value in the table wins
                    const m = &slot.memo.?;
                    if (!m.evicted) {
                        ctx.releaseLocked(slot, &held);
                        markVerified(m, db.revision, durability);
                        return .{ .value = m.value, .changed_at = m.changed_at, .durability = m.durability };
                    }
                }
                return ctx.execute(Q, index, key, false, &held);
            }

            /// A claim on a memo (see `claim`)
            const Claim = struct {
                /// This call holds the claim and must release it
                owned: bool = false,
                /// It was released while other read transactions waited for it: they must be
                /// woken
                wake: bool = false,
            };

            fn Claimed(comptime Q: type) type {
                return union(enum) {
                    /// Another read transaction brought the memo up to date meanwhile
                    ready: Fresh(Q),
                    /// The memo as it is now, for the caller to bring up to date
                    stale: ?Table(Q).Memo,
                };
            }

            /// Claims the memo at `index` for bringing it up to date (verifying or recomputing
            /// it), so that concurrent read transactions that need it do this once. When another
            /// read transaction holds the claim, waits until it releases it (having written the
            /// memo, failed, or obtained a result that is not written to a memo) and tries again;
            /// the wait is canceled like the reads of this transaction. The memo is brought up to
            /// date without the claim when this read transaction already holds it further down
            /// its stack (while verifying the memo), and when waiting would close a cycle of read
            /// transactions waiting for each other: the queries then form a cycle across their
            /// stacks, and computing the memo on this stack handles that cycle the same way as in
            /// a single read transaction. `held` records the claim taken; `endClaim` releases it.
            fn claim(ctx: *Ctx, comptime Q: type, index: u32, need_value: bool, held: *Claim) Error!Claimed(Q) {
                const db = ctx.db;
                const qi = comptime queryIndex(Q);
                const table = &db.tables[qi];
                while (true) {
                    // Read before checking the claim: a release after the check advances it, so
                    // the wait below does not miss the release
                    const epoch = db.wake_epoch.load(.seq_cst);
                    table.mutex.lockUncancelable(db.io);
                    const slot = &table.slots.items[index];
                    const memo = slot.memo;
                    if (memo) |m| if (upToDate(m, db.revision, need_value)) {
                        table.mutex.unlock(db.io);
                        return .{ .ready = freshMemo(Q, m) };
                    };
                    const owner = slot.owner orelse ctx;
                    if (owner == ctx) {
                        held.owned = slot.owner == null;
                        slot.owner = ctx;
                        table.mutex.unlock(db.io);
                        return .{ .stale = memo };
                    }
                    slot.waited = true;
                    table.mutex.unlock(db.io);
                    if (!try ctx.waitFor(.{ .query = qi, .index = index }, epoch)) return .{ .stale = memo };
                }
            }

            /// Releases the claim recorded in `held` on the memo of `slot`; the caller holds the
            /// table's mutex, and the waiters are woken by `endClaim`
            fn releaseLocked(ctx: *Ctx, slot: anytype, held: *Claim) void {
                if (!held.owned) return;
                assert(slot.owner == ctx);
                held.* = .{ .wake = slot.waited };
                slot.owner = null;
                slot.waited = false;
            }

            /// Releases the claim recorded in `held` if it is still held, and wakes the read
            /// transactions waiting for it
            fn endClaim(ctx: *Ctx, comptime Q: type, index: u32, held: *Claim) void {
                const db = ctx.db;
                if (held.owned) {
                    const table = &db.tables[comptime queryIndex(Q)];
                    table.mutex.lockUncancelable(db.io);
                    ctx.releaseLocked(&table.slots.items[index], held);
                    table.mutex.unlock(db.io);
                }
                if (held.wake) db.wakeWaiters();
            }

            /// How long a wait for a claimed memo sleeps at most before checking the cancellation
            /// flag of the request, which wakes no one when set
            const wait_poll: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } };

            /// Waits for the memo `dep`, claimed by another read transaction, to be released
            /// (`epoch` is the value of `Db.wake_epoch` read before the claim was seen), for a
            /// write transaction to register, or for `wait_poll`; then checks for cancellation.
            /// Returns false without waiting when the wait would close a cycle of read
            /// transactions waiting for each other.
            fn waitFor(ctx: *Ctx, dep: DepKey, epoch: u32) Error!bool {
                const db = ctx.db;
                {
                    db.wait_mutex.lockUncancelable(db.io);
                    defer db.wait_mutex.unlock(db.io);
                    if (ctx.closesCycle(dep)) return false;
                    ctx.waiting_for = dep;
                }
                defer {
                    db.wait_mutex.lockUncancelable(db.io);
                    ctx.waiting_for = null;
                    db.wait_mutex.unlock(db.io);
                }
                _ = db.waiting.fetchAdd(1, .seq_cst);
                defer _ = db.waiting.fetchSub(1, .monotonic);
                // Checked after counting this wait: a write transaction that registers later
                // wakes it (see `beginWriteOf`)
                try ctx.checkCanceled();
                // The wait is not an `Io` cancelation point: the request's cancellation reaches
                // the queries through `checkCanceled`, which also covers the result of a compute
                // that swallowed `error.Canceled`
                const protection = db.io.swapCancelProtection(.blocked);
                defer _ = db.io.swapCancelProtection(protection);
                db.io.futexWaitTimeout(u32, &db.wake_epoch.raw, epoch, wait_poll) catch |err| switch (err) {
                    error.Canceled => unreachable,
                };
                try ctx.checkCanceled();
                return true;
            }

            /// Whether waiting for `dep` would close a cycle of read transactions waiting for each
            /// other: follows the owner of each claim to the memo it waits for. The caller holds
            /// `wait_mutex`, so no read transaction starts or stops waiting meanwhile, and a read
            /// transaction that waits takes no claim: the waits form no cycle, and a new one can
            /// only be closed by this wait.
            fn closesCycle(ctx: *Ctx, dep: DepKey) bool {
                const db = ctx.db;
                var next = dep;
                while (true) {
                    const owner_waits: ?DepKey = inline for (queries, 0..) |Q, qi| {
                        if (comptime Q.kind == .derived) if (next.query == qi) {
                            const table = &db.tables[qi];
                            table.mutex.lockUncancelable(db.io);
                            defer table.mutex.unlock(db.io);
                            // The owner stays in its read transaction while it holds the claim
                            const owner = table.slots.items[next.index].owner orelse return false;
                            if (owner == ctx) return true;
                            break owner.waiting_for;
                        };
                    } else unreachable;
                    next = owner_waits orelse return false;
                }
            }

            fn unverifiableDepth(ctx: *const Ctx, dep: DepKey) ?u32 {
                for (ctx.unverifiable.items) |u| if (u.key.eql(dep)) return u.depth;
                return null;
            }

            fn markUnverifiable(ctx: *Ctx, dep: DepKey, depth: u32) Allocator.Error!void {
                for (ctx.unverifiable.items) |*u| if (u.key.eql(dep)) {
                    // Queries with lower indices are popped later
                    u.depth = @min(u.depth, depth);
                    return;
                };
                try ctx.unverifiable.append(ctx.gpa, .{ .key = dep, .depth = depth });
            }

            /// Stack index of `dep` when it is on the stack (a query is on the stack at most once)
            fn stackIndex(ctx: *const Ctx, dep: DepKey) ?u32 {
                const frames = ctx.stack.items;
                for (frames[0..@min(frames.len, linear_frames)], 0..) |frame, i| {
                    if (frame.key.eql(dep)) return @intCast(i);
                }
                if (frames.len <= linear_frames) return null;
                const i = ctx.deep_frames.getIndex(dep) orelse return null;
                return @intCast(linear_frames + i);
            }

            fn pushFrame(ctx: *Ctx, key: DepKey) Allocator.Error!void {
                const index: u32 = @intCast(ctx.stack.items.len);
                if (index >= linear_frames) try ctx.deep_frames.ensureUnusedCapacity(ctx.gpa, 1);
                try ctx.stack.append(ctx.gpa, .{ .key = key });
                if (index >= linear_frames) ctx.deep_frames.putAssumeCapacityNoClobber(key, {});
            }

            /// Pops the top frame: memos whose dependencies lead through a cycle back to this frame
            /// are no longer unverifiable
            fn popFrame(ctx: *Ctx) Frame {
                const frame = ctx.stack.pop().?;
                const depth = ctx.stack.items.len;
                if (depth >= linear_frames) assert(ctx.deep_frames.pop().?.key.eql(frame.key));
                var i: usize = 0;
                while (i < ctx.unverifiable.items.len) {
                    if (ctx.unverifiable.items[i].depth >= depth) {
                        _ = ctx.unverifiable.swapRemove(i);
                    } else i += 1;
                }
                return frame;
            }

            /// A memo that passes verification takes the current lowest durability of its
            /// dependencies: when an input it depends on lowers its durability while its value
            /// stays unchanged through early cutoff, the memo must not keep skipping dependency
            /// checks in later verifications based on the old high durability
            fn markVerified(m: anytype, revision: Revision, durability: Durability) void {
                if (m.verified_at < revision) m.durability = durability;
                m.verified_at = @max(m.verified_at, revision);
            }

            /// Result of verifying the dependencies of a memo
            const Verdict = union(enum) {
                /// No dependency has a changed_at later than the memo's `verified_at`; carries the
                /// current lowest durability of the dependencies
                unchanged: Durability,
                /// Some dependency changed after the memo was verified
                changed,
                /// The dependencies lead through a cycle back to the query at this stack index, so
                /// the memo cannot be verified until that query is popped (see `Unverifiable`)
                cycle: u32,
            };

            fn deepVerify(ctx: *Ctx, verified_at: Revision, durability: Durability, deps: []const DepKey) Error!Verdict {
                const db = ctx.db;
                // No input at durability `durability` or higher has changed: the durability of the
                // dependencies cannot have dropped either
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

            /// Brings a dependency up to date and returns its changed_at and durability (records no
            /// dependency). For `cycle`, see `Fresh`.
            fn depState(ctx: *Ctx, dep: DepKey) Error!struct { changed_at: Revision, durability: Durability, cycle: ?u32 = null } {
                const db = ctx.db;
                inline for (queries, 0..) |Q, qi| {
                    if (dep.query == qi) switch (Q.kind) {
                        .input => {
                            const input = db.readInput(Q, dep.index);
                            return .{ .changed_at = input.changed_at, .durability = input.durability };
                        },
                        .derived => {
                            const table = &db.tables[qi];
                            table.mutex.lockUncancelable(db.io);
                            const key = table.keys.keys()[dep.index];
                            const memo = db.useMemoLocked(Q, dep.index);
                            table.mutex.unlock(db.io);
                            // The verification path came back to a query on the stack: it cannot be
                            // verified until it is popped, so force the callers to recompute
                            if (ctx.stackIndex(dep)) |i| return .{ .changed_at = db.revision, .durability = .low, .cycle = i };
                            // The stack depth exceeds the limit: likewise treated as changed and
                            // handled by recomputation (which substitutes the fallback value)
                            if (ctx.stackExhausted()) return .{ .changed_at = db.revision, .durability = .low };
                            const fresh = try ctx.ensureFresh(Q, dep.index, key, false, memo);
                            return .{ .changed_at = fresh.changed_at, .durability = fresh.durability, .cycle = fresh.cycle };
                        },
                    };
                }
                unreachable;
            }

            /// `restore`: the memo's value was evicted but its dependencies are unchanged, so the
            /// recomputation only restores the value and keeps the original changed_at. `held`:
            /// the claim on the memo (see `claim`), released when the result is published.
            fn execute(ctx: *Ctx, comptime Q: type, index: u32, key: Q.Key, restore: bool, held: *Claim) Error!Fresh(Q) {
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
                try ctx.pushFrame(.{ .query = qi, .index = index });
                const computed = if (@hasDecl(Q, "computeIncremental")) blk: {
                    // The previous value is not freed before the next write transaction, so it can
                    // safely serve as the basis of the incremental computation
                    const table = &db.tables[qi];
                    table.mutex.lockUncancelable(db.io);
                    const prev: ?Q.Value = if (table.slots.items[index].memo) |m| (if (m.evicted) null else m.value) else null;
                    table.mutex.unlock(db.io);
                    break :blk Q.computeIncremental(ctx, key, prev);
                } else Q.compute(ctx, key);
                var value = computed catch |err| {
                    var frame = ctx.popFrame();
                    ctx.finishTiming(qi, &frame, t0, trace_index, true);
                    frame.deps.deinit(ctx.db.gpa);
                    return err;
                };
                // compute may have swallowed the `Canceled` of an inner read (a fallback such as
                // `catch null`), leaving the result incomplete, so it must not be written to the
                // memo. The cancellation flag is not reset before the read transaction ends (a
                // write transaction decrements `pending_write` only after the readers exit and it
                // acquires the exclusive lock), so a single check here is enough to detect it.
                if (ctx.checkCanceled()) |_| {} else |err| {
                    var frame = ctx.popFrame();
                    ctx.finishTiming(qi, &frame, t0, trace_index, true);
                    frame.deps.deinit(db.gpa);
                    // Never published, the new value has no other references: free it directly
                    deinitValue(Q, &value, db.gpa);
                    return err;
                }
                var frame = ctx.popFrame();
                ctx.finishTiming(qi, &frame, t0, trace_index, false);

                const table = &db.tables[qi];
                table.mutex.lockUncancelable(db.io);
                defer table.mutex.unlock(db.io);

                const slot = &table.slots.items[index];
                // The waiters see the slot only after the mutex is released, with the result
                // written to the memo or not to be written
                ctx.releaseLocked(slot, held);
                // Another read transaction computing it at the same time (one of the two without
                // the claim, see `claim`) already published a result in this revision and it wins;
                // the new value was never published, so free it directly
                if (slot.memo) |old| if (old.verified_at == db.revision and !old.evicted) {
                    frame.deps.deinit(db.gpa);
                    deinitValue(Q, &value, db.gpa);
                    return .{ .value = old.value, .changed_at = old.changed_at, .durability = old.durability, .executed = true };
                };
                // A result in a cycle depends on the cycle head and is not written to a memo. The
                // value is returned for the caller to use and put on the garbage list, to be freed
                // after the read transaction ends.
                if (frame.in_cycle) {
                    defer frame.deps.deinit(db.gpa);
                    db.discard(Q, &value) catch |err| {
                        deinitValue(Q, &value, db.gpa);
                        return err;
                    };
                    try ctx.inheritDeps(&frame);
                    // The cycle's bottom-most query is still on the stack: until it is popped, this
                    // query can only be computed within the cycle
                    const cycle: ?u32 = if (frame.cycle_head) |head| (if (head < ctx.stack.items.len) head else null) else null;
                    if (cycle) |depth| try ctx.markUnverifiable(.{ .query = qi, .index = index }, depth);
                    return .{ .value = value, .changed_at = db.revision, .durability = .low, .executed = true, .in_cycle = true, .cycle = cycle };
                }

                // Failure before committing the memo: the unpublished new value is freed directly
                errdefer deinitValue(Q, &value, db.gpa);
                defer frame.deps.deinit(db.gpa);
                const deps = try db.gpa.dupe(DepKey, frame.deps.keys());
                errdefer db.gpa.free(deps);

                var changed_at = db.revision;
                if (slot.memo) |*old| {
                    const same = !old.evicted and valueEql(Q, old.value, value);
                    db.garbage_mutex.lockUncancelable(db.io);
                    defer db.garbage_mutex.unlock(db.io);
                    // Do all allocations that can fail before transferring the old memo's
                    // resources: on failure the old memo stays intact (it still owns deps)
                    try db.garbage.ensureUnusedCapacity(db.gpa, 2);
                    const box = if (old.evicted or same) null else try db.allocBox(Q);
                    // Nothing fails from here on
                    db.garbage.appendAssumeCapacity(.{ .deps = old.deps });
                    if (old.evicted) {
                        if (restore) changed_at = old.changed_at;
                        if (@hasDecl(Q, "lru")) table.live += 1;
                        if (@hasDecl(Q, "lru_bytes")) table.live_bytes += Q.bytes(value);
                    } else if (same) {
                        // early cutoff: keep the old value and the old changed_at
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
                if (@hasDecl(Q, "lru") and db.overLru(Q, table)) db.sweep_wanted.store(true, .monotonic);
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

            /// Records the time of one compute: total, self (excluding other queries executed
            /// within it), and maximum; adds it to the child time of the enclosing frame
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

        // ── Internal helpers ───────────────────────────────────────────────

        /// The caller must hold the table's mutex (or be in a write transaction).
        fn internLocked(db: *Db, comptime Q: type, key: Q.Key) Allocator.Error!u32 {
            const table = &db.tables[comptime queryIndex(Q)];
            // An already interned key does not allocate: `set` cannot fail for an existing input
            if (table.keys.getIndex(key)) |index| return @intCast(index);
            try table.slots.ensureUnusedCapacity(db.gpa, 1);
            const gop = try table.keys.getOrPut(db.gpa, key);
            if (!gop.found_existing) table.slots.appendAssumeCapacity(.{});
            return @intCast(gop.index);
        }

        fn InputSlot(comptime Q: type) type {
            return struct { value: Q.Value, changed_at: Revision, durability: Durability };
        }

        fn readInput(db: *Db, comptime Q: type, index: u32) InputSlot(Q) {
            const table = &db.tables[comptime queryIndex(Q)];
            table.mutex.lockUncancelable(db.io);
            defer table.mutex.unlock(db.io);
            return db.readInputLocked(Q, index);
        }

        /// The caller must hold the table's mutex
        fn readInputLocked(db: *Db, comptime Q: type, index: u32) InputSlot(Q) {
            const slot = db.tables[comptime queryIndex(Q)].slots.items[index];
            return .{ .value = slot.value, .changed_at = slot.changed_at, .durability = slot.durability };
        }

        /// The memo of a derived query as it is now, marked as used (LRU). The caller must hold
        /// the table's mutex.
        fn useMemoLocked(db: *Db, comptime Q: type, index: u32) ?Table(Q).Memo {
            const memo = &(db.tables[comptime queryIndex(Q)].slots.items[index].memo orelse return null);
            memo.last_used = db.access_tick.fetchAdd(1, .monotonic);
            return memo.*;
        }

        /// Puts a value on the garbage list, to be freed at the next write transaction. On failure
        /// the caller keeps ownership of the value.
        fn discard(db: *Db, comptime Q: type, value: *Q.Value) Allocator.Error!void {
            db.garbage_mutex.lockUncancelable(db.io);
            defer db.garbage_mutex.unlock(db.io);
            try db.garbage.ensureUnusedCapacity(db.gpa, 1);
            db.discardBoxed(Q, try db.allocBox(Q), value);
        }

        /// Storage for a value put on the garbage list; null when the value needs no freeing
        fn allocBox(db: *Db, comptime Q: type) Allocator.Error!?*Q.Value {
            return if (@hasDecl(Q, "deinit")) try db.gpa.create(Q.Value) else null;
        }

        /// Same as `discard`, but cannot fail: the caller holds `garbage_mutex`, has already
        /// reserved capacity in the garbage list, and has allocated `box` (`allocBox`)
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
