//! Diagnostic publishing: the publish queue and its workers, debouncing edits, resetting semantic
//! caches that grew too large, and sending `textDocument/publishDiagnostics`.

const std = @import("std");
const Io = std.Io;
const za = @import("../zig_analyzer.zig");
const types = za.lsp.types;
const jsonrpc = za.lsp.jsonrpc;
const transport = za.lsp.transport;
const panic_context = za.util.panic_context;
const Vfs = za.base.Vfs;
const database = @import("../database.zig");
const Db = database.Db;
const FileText = database.inputs.FileText;
const Text = database.inputs.Text;
const live = database.live;

const Server = @import("Server.zig");
const doc_sync = @import("doc_sync.zig");
const file_diagnostics = @import("file_diagnostics.zig");
const project_set = @import("project_set.zig");

const log = std.log.scoped(.server);

/// Concurrency limit for publishing each batch: large batches of changes (watcher, build errors)
/// must not create a task and a read transaction per file
pub const max_publish_workers = 8;

/// When `tracked`, the file's state is recorded in `publish_queue.files`,
/// and `clear` and `always` are taken from there when the job starts; when the state
/// cannot be recorded (allocation failure), requests are not coalesced
pub const PublishJob = struct { file: Vfs.FileId, clear: bool = false, always: bool = true, tracked: bool = true };

pub const PublishState = struct {
    /// In the queue, not started yet
    queued: bool = true,
    /// Another publish request arrived after computation started: publish once more after finishing
    again: bool = false,
    /// The next publish is sent even when there are no
    /// diagnostics (the union over coalesced requests)
    clear: bool,
    /// The next publish is sent even when it is the same as the last one sent for the file (the
    /// union over coalesced requests; see `publishDependents`)
    always: bool,
};

/// Recomputes and publishes the diagnostics of these files in the background. When `clear` is true,
/// publishes even when there are no diagnostics (to clear old ones). A request for a file that is
/// already queued is coalesced; for a file being computed, it is published once more after
/// completion: every state change (such as a build finishing) requests publishing for the open
/// files, computing the same file concurrently is just duplicate work, and the run after completion
/// reads the latest state. The number of tasks does not exceed `max_publish_workers`.
pub fn publishFiles(server: *Server, files: []const Vfs.FileId, clear: bool) void {
    enqueuePublish(server, files, clear, true);
}

/// Open files other than `changed`, whose text has just changed: their diagnostics may depend on
/// that text (notes and reference traces located in it, inactive code whose conditions read it,
/// naming hints that depend on its declarations), so they are recomputed. Most of them do not
/// depend on it: a result is sent only when it differs from the last one sent for the file.
pub fn publishDependents(server: *Server, changed: []const Vfs.FileId) void {
    var files: std.ArrayList(Vfs.FileId) = .empty;
    defer files.deinit(server.gpa);
    {
        server.docs.mutex.lockUncancelable(server.io);
        defer server.docs.mutex.unlock(server.io);
        for (server.docs.open.keys()) |file| {
            if (std.mem.indexOfScalar(Vfs.FileId, changed, file) != null) continue;
            files.append(server.gpa, file) catch return log.err("out of memory while publishing diagnostics", .{});
        }
    }
    enqueuePublish(server, files.items, false, false);
}

/// See `publishFiles`; when `always` is false, the result is not sent when it is the same as the
/// last one sent for the file
fn enqueuePublish(server: *Server, files: []const Vfs.FileId, clear: bool, always: bool) void {
    if (files.len == 0) return;
    var spawn_count: usize = 0;
    {
        server.publish_queue.mutex.lockUncancelable(server.io);
        defer server.publish_queue.mutex.unlock(server.io);
        for (files) |file| {
            const gop = server.publish_queue.files.getOrPut(server.gpa, file) catch {
                server.publish_queue.jobs.append(server.gpa, .{ .file = file, .clear = clear, .always = always, .tracked = false }) catch {};
                continue;
            };
            if (gop.found_existing) {
                gop.value_ptr.clear = gop.value_ptr.clear or clear;
                gop.value_ptr.always = gop.value_ptr.always or always;
                if (!gop.value_ptr.queued) gop.value_ptr.again = true;
                continue;
            }
            gop.value_ptr.* = .{ .clear = clear, .always = always };
            server.publish_queue.jobs.append(server.gpa, .{ .file = file }) catch {
                _ = server.publish_queue.files.remove(file);
            };
        }
        if (server.publish_queue.workers < max_publish_workers and server.publish_queue.jobs.items.len != 0) {
            spawn_count = @min(max_publish_workers - server.publish_queue.workers, server.publish_queue.jobs.items.len);
            server.publish_queue.workers += spawn_count;
        }
    }
    for (0..spawn_count) |_| {
        server.busyBegin();
        Server.spawn(server.io, &server.bg_group, publishWorker, .{server});
    }
}

fn publishWorker(server: *Server) Io.Cancelable!void {
    defer server.busyEnd();
    var counted = true;
    defer if (counted) {
        server.publish_queue.mutex.lockUncancelable(server.io);
        server.publish_queue.workers -= 1;
        server.publish_queue.mutex.unlock(server.io);
    };
    while (true) {
        const job = blk: {
            server.publish_queue.mutex.lockUncancelable(server.io);
            defer server.publish_queue.mutex.unlock(server.io);
            if (server.publish_queue.jobs.items.len == 0) {
                // Under the same lock as enqueuing: decrement the count before exiting, so that an
                // enqueuer does not see the worker still present and skip spawning a new task
                server.publish_queue.workers -= 1;
                counted = false;
                return;
            }
            var job = server.publish_queue.jobs.swapRemove(0);
            if (job.tracked) {
                const state = server.publish_queue.files.getPtr(job.file).?;
                state.queued = false;
                job.clear = state.clear;
                state.clear = false;
                job.always = state.always;
                state.always = false;
            }
            break :blk job;
        };
        const start = semaUsage(server);
        publishNow(server, job.file, job.clear, job.always, null);
        if (job.tracked) publishDone(server, job.file);
        maybeResetSema(server, start);
    }
}

/// A publish finished: requeues the file if requests arrived during the computation (handled by a
/// worker that is still running)
fn publishDone(server: *Server, file: Vfs.FileId) void {
    server.publish_queue.mutex.lockUncancelable(server.io);
    defer server.publish_queue.mutex.unlock(server.io);
    const state = server.publish_queue.files.getPtr(file).?;
    if (!state.again) {
        _ = server.publish_queue.files.remove(file);
        return;
    }
    state.again = false;
    state.queued = true;
    server.publish_queue.jobs.append(server.gpa, .{ .file = file }) catch {
        _ = server.publish_queue.files.remove(file);
    };
}

pub fn publishOpenFiles(server: *Server) void {
    server.docs.mutex.lockUncancelable(server.io);
    const files = server.gpa.dupe(Vfs.FileId, server.docs.open.keys()) catch {
        server.docs.mutex.unlock(server.io);
        return;
    };
    server.docs.mutex.unlock(server.io);
    defer server.gpa.free(files);
    publishFiles(server, files, false);
}

/// Edit generation of a file, and whether a publish task is already waiting
pub const Edit = struct { generation: u64 = 0, scheduled: bool = false };

/// Publishing triggered by edits: at most one waiting task per file, which computes only when there
/// has been no new edit for `diagnostics.debounce_ms`. While typing, diagnostics (AstGen and
/// inference of inactive code) are not computed for every keystroke, and tasks repeatedly
/// interrupted by write transactions do not pile up.
pub fn publishDebounced(server: *Server, file: Vfs.FileId) void {
    {
        server.edits_mutex.lockUncancelable(server.io);
        defer server.edits_mutex.unlock(server.io);
        const gop = server.edits.getOrPut(server.gpa, file) catch return publishFiles(server, &.{file}, false);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.generation += 1;
        if (gop.value_ptr.scheduled) return;
        gop.value_ptr.scheduled = true;
    }
    // Spawned outside the lock: when falling back to `async`, the task runs synchronously here and
    // acquires `edits_mutex` again
    server.busyBegin();
    Server.spawn(server.io, &server.bg_group, debounceTask, .{ server, file });
}

fn debounceTask(server: *Server, file: Vfs.FileId) Io.Cancelable!void {
    defer server.busyEnd();
    var seen: ?u64 = null;
    while (true) {
        {
            server.edits_mutex.lockUncancelable(server.io);
            defer server.edits_mutex.unlock(server.io);
            const edit = server.edits.getPtr(file).?;
            if (seen == edit.generation) {
                edit.scheduled = false;
                break;
            }
            seen = edit.generation;
        }
        const ms = server.config.load(.acquire).debounce_ms;
        if (ms > 0) try (Io.Clock.Duration{ .raw = .fromMilliseconds(ms), .clock = .awake }).sleep(server.io);
    }
    const start = semaUsage(server);
    publishNow(server, file, false, true, seen);
    publishDependents(server, &.{file});
    if (server.openDocumentCount() > 1) server.requestRefresh();
    refreshCompileSets(server, &.{file});
    maybeResetSema(server, start);
}

/// The text of these files has changed: each project whose compile set read their imports
/// recomputes it if the imports differ (see `Workspace.refreshImports`)
fn refreshCompileSets(server: *Server, files: []const Vfs.FileId) void {
    const list = project_set.workspaceList(server, server.gpa) catch return log.err("out of memory while updating compile sets", .{});
    defer project_set.releaseList(server, server.gpa, list);
    for (list) |ws| ws.refreshImports(files) catch log.err("{s}: out of memory while updating the compile set", .{ws.root});
}

/// `refreshCompileSets` in a background task: a recompute can take a while in a large project
pub fn scheduleCompileSetRefresh(server: *Server, files: []const Vfs.FileId) void {
    const owned = server.gpa.dupe(Vfs.FileId, files) catch return log.err("out of memory while updating compile sets", .{});
    server.busyBegin();
    Server.spawn(server.io, &server.bg_group, compileSetRefreshTask, .{ server, owned });
}

fn compileSetRefreshTask(server: *Server, files: []const Vfs.FileId) Io.Cancelable!void {
    defer server.busyEnd();
    defer server.gpa.free(files);
    refreshCompileSets(server, files);
}

fn editGeneration(server: *Server, file: Vfs.FileId) u64 {
    server.edits_mutex.lockUncancelable(server.io);
    defer server.edits_mutex.unlock(server.io);
    return if (server.edits.get(file)) |e| e.generation else 0;
}

/// Size of the type information: the InternPool's bytes and the keys of the type-information
/// queries (see `sema_queries`)
pub const SemaUsage = struct { bytes: usize = 0, keys: usize = 0 };

pub fn semaUsage(server: *Server) SemaUsage {
    return .{ .bytes = server.ip.bytes(), .keys = semaKeys(server) };
}

/// Reclaims type information (see `resetSema`) when the InternPool exceeds
/// `sema.max_intern_pool_mb` or the type-information queries have more than `sema_reset_keys`
/// keys, and in both cases twice the most that one request or publish has added (see
/// `sema_peak_growth`). Called when a request or a diagnostics publish that started at `start`
/// finishes, outside read transactions.
pub fn maybeResetSema(server: *Server, start: SemaUsage) void {
    const limit = server.config.load(.acquire).max_intern_pool_mb;
    if (limit == 0) return;
    const now = semaUsage(server);
    // A reclaim in the meantime counts as no growth
    const peak_bytes = server.sema_peak_growth.bytes.fetchMax(now.bytes -| start.bytes, .monotonic);
    const peak_keys = server.sema_peak_growth.keys.fetchMax(now.keys -| start.keys, .monotonic);
    const limit_bytes = @max(@as(usize, limit) * 1024 * 1024, 2 * @max(peak_bytes, now.bytes -| start.bytes));
    const limit_keys = @max(sema_reset_keys, 2 * @max(peak_keys, now.keys -| start.keys));
    if (now.bytes < limit_bytes and now.keys < limit_keys) return;
    if (!server.db.tryBeginWrite()) return;
    defer server.db.endWrite();
    // Another thread may have reclaimed since the check above
    if (server.ip.bytes() < limit_bytes and semaKeysLocked(server) < limit_keys) return;
    resetSemaLocked(server);
}

/// When the total number of keys of the type-information queries exceeds this value, the whole
/// generation is reclaimed as well: keys and dependency edges are not freed by eviction and keep
/// growing in long sessions with the members and instances visited (about 250,000 after 40 rounds
/// over the Zig compiler source, tens of MB including the dependency edges)
const sema_reset_keys = 200_000;

/// Queries cleared by a whole-generation reclaim
const sema_queries = .{ database.sema.Infer, database.sema.LocalValue, database.sema.LocalEval, database.sema.CapturedVar, database.sema.SignatureInst, database.sema.DeclType, database.sema.CallEval, database.sema.ComptimeOnly, database.sema.ErrorSetOf, database.sema.InactiveRanges, database.sema.ZonValue, database.sema.ZonImports, database.sema.ZonResultType, database.ide_db.seed.Query, database.ide_db.seed.Instances, database.ide_db.seed.AllInstances, database.ide_db.seed.GenericCallers, database.ide_db.seed.RootCallers, database.ide_db.seed.CallsIn };

fn semaKeys(server: *Server) usize {
    var n: usize = 0;
    inline for (sema_queries) |Q| n += server.db.keyCount(Q);
    return n;
}

/// Same as `semaKeys`; the caller holds a write transaction
fn semaKeysLocked(server: *Server) usize {
    var n: usize = 0;
    inline for (sema_queries) |Q| n += server.db.keyCountLocked(Q);
    return n;
}

/// Reclaims type information as a whole generation: clears the non-predefined items in the
/// InternPool and the queries whose keys or values refer to them (memos of other queries that
/// depend on them are dropped too). The InternPool and the keys and dependency edges of these
/// queries never shrink and keep growing in long sessions with the generic instances visited; after
/// the reclaim, later requests infer again on demand, with the same results.
///
/// Runs only when no read transaction is in progress, and returns whether it ran: it sets no
/// input and invalidates no result, so canceling in-flight requests for it would fail them for
/// nothing, and a request whose own inference exceeds the limit would never complete. When a
/// read transaction is in progress, the reclaim is left to a request or publish that finishes
/// later (`maybeResetSema`).
pub fn resetSema(server: *Server) bool {
    if (!server.db.tryBeginWrite()) return false;
    defer server.db.endWrite();
    resetSemaLocked(server);
    return true;
}

/// `resetSema` in a write transaction the caller holds
fn resetSemaLocked(server: *Server) void {
    const before = server.ip.bytes();
    const keys = semaKeysLocked(server);
    server.db.resetQueries(&sema_queries);
    server.ip.reset() catch return log.err("out of memory while resetting the intern pool", .{});
    log.info("reclaimed type information ({d} MB in the intern pool, {d} keys)", .{ before / (1024 * 1024), keys });
}

/// `generation`: the edit generation that an edit-triggered publish is for. When interrupted, it
/// gives up if a newer edit exists; the publish triggered by that edit takes over. `clear` and
/// `always`: see `sendDiagnostics`.
fn publishNow(server: *Server, file: Vfs.FileId, clear: bool, always: bool, generation: ?u64) void {
    var pc: panic_context.Text = .{};
    pc.enter("publish diagnostics {s}", .{server.vfs.path(file)});
    defer pc.leave();
    var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_state.deinit();
    // Virtual documents have no file on disk: after one is closed and its diagnostics cleared,
    // nothing more is published for its internal path
    if (doc_sync.isVirtual(server.vfs.path(file))) {
        server.docs.mutex.lockUncancelable(server.io);
        const wanted = server.docs.open.contains(file) or server.docs.last_uris.contains(file);
        server.docs.mutex.unlock(server.io);
        if (!wanted) return;
    }
    // Retry when canceled by a write transaction, however often: a publish triggered by a build
    // result or a file deleted on disk must not be lost because of unrelated edits. Before
    // retrying, wait for the write transaction to take the lock (see `Db.waitPendingWrites`);
    // retrying at once could keep it waiting.
    while (true) {
        if (generation) |g| if (editGeneration(server, file) != g) return;
        const prepared = prepareLive(server, file);
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        var ctx = server.db.beginRead(arena);
        // Another edit came in after preparing: prepare again outside the lock instead of running
        // AstGen inside the read transaction (while typing, AstGen may be slower than keystrokes).
        // When preparing failed, the query runs AstGen itself.
        const ready = !prepared or (liveReady(server, &ctx, file) catch |err| switch (err) {
            error.Canceled => {
                ctx.end();
                server.db.waitPendingWrites();
                continue;
            },
            error.OutOfMemory => true,
        });
        if (!ready) {
            ctx.end();
            continue;
        }
        // Take the sequence number before reading state
        // such as compile results (see `sendDiagnostics`)
        const seq = server.publish_seq.fetchAdd(1, .acq_rel);
        const params = file_diagnostics.computeDiagnostics(server, &ctx, arena, file) catch |err| {
            ctx.end();
            switch (err) {
                error.Canceled => {
                    server.db.waitPendingWrites();
                    continue;
                },
                error.OutOfMemory => return log.err("out of memory while computing diagnostics", .{}),
            }
        };
        // If the computation swallowed `Canceled`, the result is incomplete: retry as well
        const canceled = if (ctx.checkCanceled()) |_| false else |_| true;
        ctx.end();
        if (canceled) {
            server.db.waitPendingWrites();
            continue;
        }
        sendDiagnostics(server, file, params, clear, always, seq);
        return;
    }
}

/// Runs AstGen on the file's current text outside any read transaction (see `live.Prepared`):
/// AstGen does not check for cancellation, so if it ran inside a read transaction, write
/// transactions would have to wait for it to finish. A read transaction is held briefly, only to
/// read the text and claim its preparation. Used by diagnostics publishing and by code action
/// requests (see `Server.requireLivePrepared`). Returns false when preparing failed: the query then
/// computes the live diagnostics itself (a publish waiting for a preparation that keeps failing
/// would never finish). A read canceled by a write transaction is not a failure: it returns true
/// once the write transaction has the lock, and the caller reads again.
pub fn prepareLive(server: *Server, file: Vfs.FileId) bool {
    if (!liveEligible(server, file)) return true;
    var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Read = struct { text: []const u8, backend: live.Backend, mode: live.Mode };
    const Outcome = union(enum) { canceled, prepared, ready: Read };
    const outcome: Outcome = blk: {
        var ctx = server.db.beginRead(a);
        defer ctx.end();
        const backend: live.Backend = switch (ctx.get(live.LiveBackend, {}) catch |err| switch (err) {
            error.Canceled => break :blk .canceled,
            error.OutOfMemory => return false,
        }) {
            .in_process => .in_process,
            .subprocess => |exe| .{ .subprocess = a.dupe(u8, exe) catch return false },
        };
        const t = (ctx.get(FileText, file) catch |err| switch (err) {
            error.Canceled => break :blk .canceled,
            error.OutOfMemory => return false,
        }) orelse return true;
        const text = t.bytes();
        // The claim is checked on the borrowed text, so that a text that is already prepared is
        // not copied
        const mode = live.modeOf(server.vfs.path(file));
        if (!server.live_prepared.claim(server.io, file, live.Prepared.hash(text, mode, backend))) break :blk .prepared;
        break :blk .{ .ready = .{ .text = a.dupe(u8, text) catch return false, .backend = backend, .mode = mode } };
    };
    const r = switch (outcome) {
        .canceled => {
            server.db.waitPendingWrites();
            return true;
        },
        .prepared => return true,
        .ready => |ready| ready,
    };
    const result = live.checkWith(server.gpa, server.io, r.backend, server.zig_environ.load(.acquire), r.text, r.mode) catch return false;
    if (!result.complete) {
        result.destroy(server.gpa);
        return false;
    }
    server.live_prepared.put(server.io, file, r.text, r.mode, r.backend, result) catch return false;
    return true;
}

/// The live diagnostics of the current text have already been prepared outside a read transaction
/// (or need no preparation)
pub fn liveReady(server: *Server, ctx: *Db.Ctx, file: Vfs.FileId) !bool {
    if (!liveEligible(server, file)) return true;
    const backend = try ctx.get(live.LiveBackend, {});
    const text = if (try ctx.get(FileText, file)) |t| t.bytes() else return true;
    return server.live_prepared.prepared(server.io, file, live.Prepared.hash(text, live.modeOf(server.vfs.path(file)), backend));
}

/// Sends the diagnostics computed with sequence number `seq`, dropping them if a result
/// with a larger number has already been sent. Several publish tasks for the same file
/// compute concurrently, and one that started earlier may finish later. Every state
/// change is followed by a new publish: it takes its number after the change, which is
/// larger than those of all computations that took theirs before the change, and it
/// reads the state after the change. So when only results whose number is no smaller
/// than the one already sent are sent, the last result sent has read the state after
/// the last change. Comparing and writing both happen inside `sent.mutex`, so the
/// order of writes matches the comparisons; serialization happens outside the lock.
/// `clear`: sent even when empty for a file that is not showing diagnostics; `always`: sent even
/// when it is the same as the last result sent for the file.
fn sendDiagnostics(server: *Server, file: Vfs.FileId, params: types.PublishDiagnosticsParams, clear: bool, always: bool, seq: u64) void {
    if (@import("builtin").is_test) if (server.hooks.publish) |gate| gate.pass(server.io);
    const bytes = jsonrpc.notification(server.gpa, "textDocument/publishDiagnostics", params) catch return log.err("out of memory while building notification", .{});
    var sent = false;
    defer if (!sent) server.gpa.free(bytes);
    const hash = std.hash.Wyhash.hash(0, bytes);
    server.sent.mutex.lockUncancelable(server.io);
    defer server.sent.mutex.unlock(server.io);
    if (server.sent.seq.getOrPut(server.gpa, file)) |gop| {
        if (gop.found_existing and gop.value_ptr.* > seq) return;
        gop.value_ptr.* = seq;
    } else |_| {}
    if (!always) if (server.sent.hash.get(file)) |last| if (last == hash) return;
    // The other documents of the file, when it has several or `params.uri` is no longer one of
    // them (see `OpenDoc`): they get the same diagnostics. Rare, so they are serialized here.
    var others: std.ArrayList([]u8) = .empty;
    defer {
        for (others.items) |u| server.gpa.free(u);
        others.deinit(server.gpa);
    }
    var to_params = true;
    {
        server.docs.mutex.lockUncancelable(server.io);
        defer server.docs.mutex.unlock(server.io);
        const was_published = server.published.contains(file);
        if (params.diagnostics.len == 0) {
            // A file that never had diagnostics shown needs no empty list (except open files: the
            // client may still be showing old results)
            if (!was_published and !clear and !server.docs.open.contains(file)) return;
            _ = server.published.swapRemove(file);
        } else {
            server.published.put(server.gpa, file, {}) catch {};
        }
        if (server.docs.open.getPtr(file)) |open| if (open.docs.items.len > 1 or open.find(params.uri) == null) {
            to_params = open.find(params.uri) != null;
            for (open.docs.items) |d| if (!std.mem.eql(u8, d.uri, params.uri)) {
                const u = server.gpa.dupe(u8, d.uri) catch continue;
                others.append(server.gpa, u) catch server.gpa.free(u);
            };
        };
    }
    sent = true;
    server.sent.hash.put(server.gpa, file, hash) catch {
        _ = server.sent.hash.remove(file);
    };
    if (to_params) server.send(bytes) else server.gpa.free(bytes);
    for (others.items) |u| {
        var copy = params;
        copy.uri = u;
        copy.version = null;
        server.send(jsonrpc.notification(server.gpa, "textDocument/publishDiagnostics", copy) catch {
            log.err("out of memory while building notification", .{});
            continue;
        });
    }
    // The clearing for the closed virtual document has been sent: its URI is no longer needed. A
    // result computed before the close and sent after it clears nothing, and the clearing that the
    // close requested still needs the URI
    if (params.diagnostics.len == 0 and doc_sync.isVirtual(server.vfs.path(file))) {
        server.docs.mutex.lockUncancelable(server.io);
        defer server.docs.mutex.unlock(server.io);
        if (!server.docs.open.contains(file)) if (server.docs.last_uris.fetchSwapRemove(file)) |kv| server.gpa.free(kv.value);
    }
}

test "sendDiagnostics: a result computed earlier is not sent after a later one" {
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var writer: transport.Writer = .{ .io = std.testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(std.testing.io, gpa, &writer);
    defer server.deinit();
    const native = @import("../util/test_path.zig").native;
    const a = try server.vfs.intern(native("/a.zig"));
    const b = try server.vfs.intern(native("/b.zig"));
    const stale: types.Diagnostic = .{ .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 } }, .message = .{ .string = "stale" } };
    // The 2nd computation finishes first and is sent; the 1st is based on older state and is
    // dropped when it finishes later. Other files are not affected.
    sendDiagnostics(&server, a, .{ .uri = "file:///a.zig", .diagnostics = &.{} }, true, true, 2);
    sendDiagnostics(&server, a, .{ .uri = "file:///a.zig", .diagnostics = &.{stale} }, true, true, 1);
    sendDiagnostics(&server, b, .{ .uri = "file:///b.zig", .diagnostics = &.{stale} }, true, true, 0);
    sendDiagnostics(&server, a, .{ .uri = "file:///a.zig", .diagnostics = &.{stale} }, true, true, 3);
    // A republish of a file for a change in another file is sent only when its result differs
    sendDiagnostics(&server, a, .{ .uri = "file:///a.zig", .diagnostics = &.{stale} }, false, false, 4);
    sendDiagnostics(&server, a, .{ .uri = "file:///a.zig", .diagnostics = &.{} }, false, false, 5);
    sendDiagnostics(&server, a, .{ .uri = "file:///a.zig", .diagnostics = &.{} }, true, true, 6);

    var reader: Io.Reader = .fixed(out.written());
    var sent: std.ArrayList(u8) = .empty;
    defer sent.deinit(gpa);
    while (transport.readMessage(&reader, gpa)) |body| {
        defer gpa.free(body);
        const msg = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
        defer msg.deinit();
        const params = msg.value.object.get("params").?.object;
        const uri_text = params.get("uri").?.string;
        try sent.print(gpa, "{s}:{d} ", .{ uri_text[uri_text.len - 5 ..], params.get("diagnostics").?.array.items.len });
    } else |err| if (err != error.EndOfStream) return err;
    try std.testing.expectEqualStrings("a.zig:0 b.zig:1 a.zig:1 a.zig:0 a.zig:0 ", sent.items);
}

test "publishFiles: large batches use a bounded number of workers" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var writer: transport.Writer = .{ .io = std.testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(std.testing.io, gpa, &writer);
    defer server.deinit();
    const text = "fn f() void {\n    var x = 1;\n}\n";
    const files = try gpa.alloc(Vfs.FileId, 200);
    defer gpa.free(files);
    for (files, 0..) |*file, i| {
        const path = try std.fmt.allocPrint(gpa, "/tmp/zig-analyzer-publish-{d}.zig", .{i});
        defer gpa.free(path);
        file.* = try server.vfs.intern(path);
        server.db.beginWrite();
        defer server.db.endWrite();
        try server.db.set(FileText, file.*, try Text.init(gpa, text), .low);
    }
    publishFiles(&server, files, true);
    {
        server.publish_queue.mutex.lockUncancelable(server.io);
        defer server.publish_queue.mutex.unlock(server.io);
        try std.testing.expect(server.publish_queue.workers <= max_publish_workers);
    }
    server.waitIdle();

    var reader: Io.Reader = .fixed(out.written());
    var published: usize = 0;
    while (transport.readMessage(&reader, gpa)) |body| {
        defer gpa.free(body);
        const msg = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
        defer msg.deinit();
        const method = msg.value.object.get("method") orelse continue;
        if (std.mem.eql(u8, method.string, "textDocument/publishDiagnostics")) published += 1;
    } else |err| if (err != error.EndOfStream) return err;
    try std.testing.expectEqual(files.len, published);
}

test "publishFiles: requests for a file being published coalesce into one more run" {
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var writer: transport.Writer = .{ .io = std.testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(std.testing.io, gpa, &writer);
    defer server.deinit();
    const file = try server.vfs.intern("/tmp/zig-analyzer-publish-coalesce.zig");
    {
        server.db.beginWrite();
        defer server.db.endWrite();
        try server.db.set(FileText, file, try Text.init(gpa, "fn f() void {\n    var x = 1;\n}\n"), .low);
    }
    const before = server.publish_seq.load(.monotonic);
    // During the write transaction, publish tasks stop before their read transactions: all later
    // requests arrive while the first publish is queued or computing
    server.db.beginWrite();
    for (0..10) |_| publishFiles(&server, &.{file}, true);
    server.db.endWrite();
    server.waitIdle();
    // Queued requests are coalesced, and requests that arrive after computation starts are combined
    // into one run after it finishes
    const computed = server.publish_seq.load(.monotonic) - before;
    try std.testing.expect(computed >= 1 and computed <= 2);
    try std.testing.expectEqual(0, server.publish_queue.files.count());
}

// Prevents a publish from giving up after a fixed number of attempts interrupted by write
// transactions: the clearing of a file deleted on disk and closed was lost, and its compile errors
// stayed published
test "publishFiles: a publish interrupted by write transactions again and again still sends its result" {
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var writer: transport.Writer = .{ .io = std.testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(std.testing.io, gpa, &writer);
    defer server.deinit();
    const native = @import("../util/test_path.zig").native;
    const file = try server.vfs.intern(native("/tmp/zig-analyzer-publish-interrupted.zig"));
    {
        server.db.beginWrite();
        defer server.db.endWrite();
        try server.db.set(FileText, file, try Text.init(gpa, "fn f() void {\n    var x = 1;\n}\n"), .low);
    }
    publishFiles(&server, &.{file}, true);
    // Write transactions follow each other for a while, canceling the reads the publish begins
    // meanwhile
    const t0 = Io.Clock.awake.now(server.io);
    var writes: usize = 0;
    while (writes < 1000 or t0.durationTo(Io.Clock.awake.now(server.io)).nanoseconds < 200 * std.time.ns_per_ms) : (writes += 1) {
        server.db.beginWrite();
        server.db.endWrite();
    }
    server.waitIdle();
    var reader: Io.Reader = .fixed(out.written());
    var diagnostics: std.ArrayList(usize) = .empty;
    defer diagnostics.deinit(gpa);
    while (transport.readMessage(&reader, gpa)) |body| {
        defer gpa.free(body);
        const msg = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
        defer msg.deinit();
        const method = msg.value.object.get("method") orelse continue;
        if (!std.mem.eql(u8, method.string, "textDocument/publishDiagnostics")) continue;
        try diagnostics.append(gpa, msg.value.object.get("params").?.object.get("diagnostics").?.array.items.len);
    } else |err| if (err != error.EndOfStream) return err;
    try std.testing.expectEqual(1, diagnostics.items.len);
    try std.testing.expect(diagnostics.items[0] > 0);
}

/// Whether to publish live diagnostics for the file: it belongs to no project, or one of the
/// projects it belongs to wants them (see `Workspace.liveEligible`)
pub fn liveEligible(server: *Server, file: Vfs.FileId) bool {
    // Use the projects while holding workspaces_mutex (workspaces_mutex first, then ws.mutex)
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    var owned = false;
    for (server.workspaces.items) |ws| if (ws.owns(file)) {
        if (ws.liveEligible(file)) return true;
        owned = true;
    };
    return !owned;
}
