//! Module graph updates, workspace scans, and background indexing (symbol index and auto-import
//! index).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const za = @import("../zig_analyzer.zig");
const transport = za.lsp.transport;
const panic_context = za.util.panic_context;
const Vfs = za.base.Vfs;
const database = @import("../database.zig");
const Db = database.Db;
const WorkspaceFiles = database.inputs.WorkspaceFiles;
const syntax_q = database.syntax;
const ModuleGraph = za.names.ModuleGraph;
const Resolver = za.names.resolve.Resolver;
const Progress = @import("progress.zig");
const workspace_files = @import("workspace_files.zig");

const Server = @import("Server.zig");
const project_set = @import("project_set.zig");
const Pending = Server.Pending;

const log = std.log.scoped(.server);

/// The target parsed from each builtin.zig during one module graph update: a module graph has
/// far fewer distinct builtins than modules and compilations, and reads within one update cannot
/// legitimately differ, so each file is read and parsed at most once.
const BuiltinTargets = std.AutoArrayHashMapUnmanaged(Vfs.FileId, za.sema.InternPool.Target);

/// Target-dependent parameters of value operations outside every compilation (pointer bit width,
/// layout rules of vector and scalar types): taken from the parts the builtins of all modules and
/// compilations agree on; parts that disagree are unknown (values depending on them are unknown);
/// without project modules, the default builtin (native) is used
fn targetAbi(server: *Server, graph: *const ModuleGraph, cache: *BuiltinTargets) Allocator.Error!za.sema.InternPool.Target {
    var result: za.sema.InternPool.Target = .{};
    // Modules with the same parameters share the same builtin, and merging the same target again
    // does not change the result: each one is read and parsed only once
    var seen: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty;
    defer seen.deinit(server.gpa);
    for (graph.modules) |m| if (m.builtin) |file| try seen.put(server.gpa, file, {});
    for (graph.compiles) |c| if (c.builtin) |file| try seen.put(server.gpa, file, {});
    for (seen.keys(), 0..) |file, i| {
        const t = try builtinTarget(server, cache, file);
        if (i == 0) {
            result = t;
            continue;
        }
        if (result.pointer_bits != t.pointer_bits) result.pointer_bits = null;
        if (result.vector_abi != t.vector_abi) result.vector_abi = .unknown;
        if (result.endian != t.endian) result.endian = null;
        result.scalar_abi = result.scalar_abi.merge(t.scalar_abi);
    }
    if (seen.count() == 0) result = if (graph.default_builtin) |f| try builtinTarget(server, cache, f) else .{};
    // The error limit is set per compile step (the compilation of files outside every compile
    // step uses the default)
    var bits: ?u16 = null;
    var agree = true;
    for (graph.compiles, 0..) |c, i| {
        if (graph.none) |n| if (i == n) continue;
        const b = za.sema.InternPool.errorBitsOf(c.error_limit);
        if (bits) |x| agree = agree and x == b else bits = b;
    }
    result.error_bits = if (agree) bits orelse za.sema.InternPool.errorBitsOf(null) else null;
    return result;
}

/// Target parameters of a builtin.zig; when it cannot be read, the ones last parsed from it (see
/// `builtin_targets`). The result is recorded in `cache` and reused for the rest of the update.
/// The caller holds `graph_mutex`.
fn builtinTarget(server: *Server, cache: *BuiltinTargets, file: Vfs.FileId) Allocator.Error!za.sema.InternPool.Target {
    if (cache.get(file)) |result| return result;
    if (@import("builtin").is_test) {
        if (server.hooks.builtin_target_reads) |reads| _ = reads.fetchAdd(1, .monotonic);
    }
    const text = Io.Dir.cwd().readFileAlloc(server.io, server.vfs.path(file), server.gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const result: za.sema.InternPool.Target = server.builtin_targets.get(file) orelse .{ .pointer_bits = null, .scalar_abi = .unknown, .endian = null };
            try cache.put(server.gpa, file, result);
            return result;
        },
    };
    defer server.gpa.free(text);
    const result = targetOfBuiltin(text);
    try server.builtin_targets.put(server.gpa, file, result);
    try cache.put(server.gpa, file, result);
    return result;
}

/// Target parameters given by the contents of a builtin.zig: pointer bit width and the layout rules
/// of vector and scalar types (unknown where the contents do not tell)
pub fn targetOfBuiltin(text: []const u8) za.sema.InternPool.Target {
    const backend = za.project.builtin.backend(text);
    const target = za.project.builtin.target(text);
    return .{
        .pointer_bits = za.project.builtin.pointerBits(text),
        .vector_abi = if (backend) |b| if (target) |*t| .of(b, t) else .unknown else .unknown,
        .scalar_abi = if (target) |*t| .of(t) else .unknown,
        .endian = if (target) |*t| t.cpu.arch.endian() else null,
    };
}

/// The target of files outside every compilation and of every compilation, for one module graph
/// update (`graph.compiles`). Builtins are shared between the two and read at most once each.
const Targets = struct {
    common: za.sema.InternPool.Target,
    compiles: []za.sema.InternPool.Target,

    fn deinit(t: *Targets, gpa: Allocator) void {
        gpa.free(t.compiles);
    }
};

fn computeTargets(server: *Server, graph: *const ModuleGraph, dialect: za.syntax.Parse.Dialect) Allocator.Error!Targets {
    var cache: BuiltinTargets = .empty;
    defer cache.deinit(server.gpa);
    var common = try targetAbi(server, graph, &cache);
    common.dialect = dialect;
    // Each compilation uses the target of its builtin (the root module's); when that is unknown,
    // the parameters common to all compilations. The error limit is the compilation's own.
    const compiles = try server.gpa.alloc(za.sema.InternPool.Target, graph.compiles.len);
    errdefer server.gpa.free(compiles);
    for (graph.compiles, compiles) |c, *ct| {
        ct.* = if (c.builtin) |file| try builtinTarget(server, &cache, file) else common;
        ct.error_bits = za.sema.InternPool.errorBitsOf(c.error_limit);
        ct.dialect = dialect;
    }
    return .{ .common = common, .compiles = compiles };
}

/// Combines the build graphs and compile sets of all projects and updates the module graph input
pub fn updateModuleGraph(server: *Server) void {
    updateModuleGraphInner(server) catch |err| return log.err("failed to update module graph: {t}", .{err});
    // Must come after the write transaction ends: the indexing task may run inline
    scheduleIndexing(server);
}

fn updateModuleGraphInner(server: *Server) Allocator.Error!void {
    server.graph_mutex.lockUncancelable(server.io);
    defer server.graph_mutex.unlock(server.io);
    var b: ModuleGraph.Builder = .init(server.gpa, &server.vfs);
    var builder_owned = true;
    errdefer if (builder_owned) b.deinit();
    const list = try project_set.workspaceList(server, server.gpa);
    defer project_set.releaseList(server, server.gpa, list);
    for (list) |ws| {
        ws.mutex.lockUncancelable(server.io);
        defer ws.mutex.unlock(server.io);
        if (ws.model) |*m| if (ws.compile_set) |*cs| try b.add(m, cs, if (ws.resolve_set) |*e| e else null);
        // The build.zig modules of the project and its dependency packages: after the compile
        // sets, which take priority for files in both
        if (ws.script_model) |*m| if (ws.script_set) |*s| try b.add(m, s, null);
    }
    const std_root: ?Vfs.FileId = if (project_set.zigEnv(server)) |env| blk: {
        const p = try std.fs.path.join(server.gpa, &.{ env.std_dir, "std.zig" });
        defer server.gpa.free(p);
        break :blk try server.vfs.intern(p);
    } else null;
    const default_builtin: ?Vfs.FileId = if (server.toolchain.load(.acquire).default_builtin) |p| try server.vfs.intern(p) else null;
    const graph = try server.gpa.create(ModuleGraph);
    graph.* = b.finish(std_root, default_builtin) catch |err| {
        server.gpa.destroy(graph);
        return err;
    };
    // `finish` has moved the builder's arena into graph
    builder_owned = false;
    var graph_value: ModuleGraph.Input.Value = graph;
    var graph_owned = true;
    defer if (graph_owned) ModuleGraph.Input.deinit(&graph_value, server.gpa);
    const dialect: za.syntax.Parse.Dialect = if (project_set.zigEnv(server)) |env| .of(env.version) else .latest;
    var computed = try computeTargets(server, graph, dialect);
    defer computed.deinit(server.gpa);
    const t = computed.common;
    const targets = computed.compiles;
    // Do not open a write transaction when neither the module graph nor the targets have changed:
    // every build that finishes gets here, and a write transaction cancels in-flight computations
    // and makes in-flight requests start over
    if (try moduleGraphUnchanged(server, graph, t, targets)) return;
    // Beginning a write transaction under graph_mutex is safe: no read transaction waits for it.
    // Requests that read only text cannot change with the module graph: they are not canceled.
    // The update is not ordered with the requests: one received earlier that starts reading after
    // it reads the new graph.
    server.db.beginWriteOf(comptime Db.inputSet(&.{ ModuleGraph.Input, za.sema.queries.TargetAbi, za.sema.queries.ContextTarget }), .unordered);
    defer server.db.endWrite();
    // `set` allocates only when the key is not interned yet: ensure every key first, so that the
    // set calls afterwards cannot fail and cannot leave a partial update either
    try server.db.ensureInput(ModuleGraph.Input, {});
    try server.db.ensureInput(za.sema.queries.TargetAbi, {});
    for (0..targets.len) |i| try server.db.ensureInput(za.sema.queries.ContextTarget, @intCast(i));
    try server.ip.setTargets(targets);
    server.db.set(ModuleGraph.Input, {}, graph, .medium) catch unreachable;
    graph_owned = false;
    server.db.set(za.sema.queries.TargetAbi, {}, t, .medium) catch unreachable;
    for (targets, 0..) |ct, i| server.db.set(za.sema.queries.ContextTarget, @intCast(i), ct, .medium) catch unreachable;
    server.ip.setTarget(t);
}

/// The current module graph and targets already equal `graph`, `t` and `targets`. Called with
/// graph_mutex held: the module graph is written only here, so nobody else can change it after
/// the comparison. A comparison canceled by a write transaction tells nothing about the module
/// graph: it is made again once that write has taken the lock (see `Db.waitPendingWrites`).
/// Waiting under graph_mutex is safe: no write transaction takes it.
fn moduleGraphUnchanged(server: *Server, graph: *const ModuleGraph, t: za.sema.InternPool.Target, targets: []const za.sema.InternPool.Target) Allocator.Error!bool {
    while (true) {
        return sameModuleGraph(server, graph, t, targets) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => {
                server.db.waitPendingWrites();
                continue;
            },
        };
    }
}

/// One comparison of `moduleGraphUnchanged`, in a read transaction of its own
fn sameModuleGraph(server: *Server, graph: *const ModuleGraph, t: za.sema.InternPool.Target, targets: []const za.sema.InternPool.Target) za.db.Error!bool {
    var ctx = server.db.beginRead(server.gpa);
    defer ctx.end();
    if (@import("builtin").is_test) if (server.hooks.graph) |gate| gate.pass(server.io);
    const current = try ctx.get(ModuleGraph.Input, {});
    const target = try ctx.get(za.sema.queries.TargetAbi, {});
    for (targets, 0..) |ct, i| if (!std.meta.eql(try ctx.get(za.sema.queries.ContextTarget, @intCast(i)), ct)) return false;
    return ModuleGraph.Input.eql(current, graph) and std.meta.eql(target, t);
}

const index_progress_delay_ms = 200;

/// Whether auto-import is still enabled: the indexing task checks again before each batch and
/// stops indexing once it is disabled
pub fn autoImportEnabled(server: *Server) bool {
    return server.config.load(.acquire).completion_auto_import;
}

/// Whether a Zig document is open. Virtual documents opened with languageId `zig` have a `.zig`
/// path too (see `documentPath`).
fn hasOpenZigDocument(server: *Server) bool {
    server.docs.mutex.lockUncancelable(server.io);
    defer server.docs.mutex.unlock(server.io);
    for (server.docs.open.keys()) |file| {
        if (std.mem.endsWith(u8, server.vfs.path(file), ".zig")) return true;
    }
    return false;
}

/// Starts building the auto-import index when a Zig document opens: the first completion at a
/// name then includes auto-imports instead of waiting for the index and marking the result
/// incomplete. Sessions with auto-import off do not build it before a request needs it. The index
/// waits until the first project load ends, so that one build of it covers the final module graph:
/// every place that ends it (startup, a project's first load, a restart during a first load) calls
/// this too. Until startup ends, which follows the configuration pull, it does nothing.
pub fn requestAutoImportIndex(server: *Server) void {
    if (@import("builtin").is_test and !server.hooks.eager_imports) return;
    if (!autoImportEnabled(server)) return;
    if (!hasOpenZigDocument(server)) return;
    // The module graph and the files it covers are final only after the first project load: an
    // index built earlier would be built again after the graph changes
    if (project_set.projectsPending(server)) return;
    if (server.index.imports_wanted.swap(true, .acq_rel)) return;
    scheduleIndexing(server);
}

/// Number of files per indexing batch: one read transaction per batch, so an edit (write
/// transaction) waits for at most one batch
const index_batch = 8;

/// Indexes project files in the background (file index, ItemTree, and member summaries): reference
/// search, workspace symbol, and call-site seeding only need to read the indexes, without parsing
/// every file in a request. The parse results are later evicted by LRU, while the indexes stay.
///
/// Only one task runs at a time: the module graph is updated many times while projects load and
/// build; a running task is not interrupted, and when it finds after a pass that the module graph
/// has changed, it does another pass (indexes already built hit the cache directly).
pub fn scheduleIndexing(server: *Server) void {
    if (!server.index.rerun.schedule()) return;
    server.busyBegin();
    Server.spawn(server.io, &server.bg_group, indexTask, .{server});
}

/// Like `scheduleIndexing`, for requests that hold a read transaction: the indexing task may run
/// inline, and when its read transaction runs into a waiting write transaction, it and the caller
/// still holding the read lock wait for each other. Scheduling is done by another task; if that
/// task cannot start, no index is built and it is left to later requests.
pub fn scheduleIndexingFromRead(server: *Server) void {
    server.busyBegin();
    server.bg_group.concurrent(server.io, scheduleIndexingTask, .{server}) catch server.busyEnd();
}

fn scheduleIndexingTask(server: *Server) Io.Cancelable!void {
    defer server.busyEnd();
    scheduleIndexing(server);
}

fn indexTask(server: *Server) Io.Cancelable!void {
    defer server.busyEnd();
    while (true) {
        const generation = server.index.rerun.begin();
        indexOnce(server, generation) catch |err| {
            server.index.rerun.stop();
            wakeSymbolWaiters(server);
            return err;
        };
        const next = server.index.rerun.finish(generation);
        // The task stopped running at least for a moment: wake the workspace symbol requests
        // waiting for the index (see `waitSymbolIndex`)
        if (next != .again) wakeSymbolWaiters(server);
        switch (next) {
            .again, .resumed => {},
            .done => {
                server.requestRefresh();
                return;
            },
            .taken_over => return,
        }
    }
}

pub fn wakeSymbolWaiters(server: *Server) void {
    server.index.mutex.lockUncancelable(server.io);
    defer server.index.mutex.unlock(server.io);
    server.index.cond.broadcast(server.io);
}

/// Waits until the workspace symbol index covers the module graph as it is now: returns at once
/// when no indexing is running, and also when `pending` is canceled or indexing stops without
/// finishing (shutting down, out of memory), in which case the request computes what is missing
/// itself. Returns whether it waited.
pub fn waitSymbolIndex(server: *Server, pending: *const Pending) bool {
    const target = server.index.rerun.generation.load(.monotonic);
    server.index.mutex.lockUncancelable(server.io);
    defer server.index.mutex.unlock(server.io);
    var waited = false;
    while (server.index.rerun.running.load(.acquire) and server.index.symbols < target and !pending.cancel.load(.acquire)) {
        server.index.cond.waitUncancelable(server.io, &server.index.mutex);
        waited = true;
    }
    return waited;
}

/// Scans the root directories for the user's source files in the background (see
/// `workspace_files.scan`): when the scope of find references and rename may have changed (startup,
/// root directories added or removed, source files or directories created or deleted). Like
/// indexing, a running task does another pass when this is called again meanwhile. Must not be
/// called inside a read or write transaction: the task may run inline.
pub fn scheduleScan(server: *Server) void {
    if (!server.scan.rerun.schedule()) return;
    server.busyBegin();
    Server.spawn(server.io, &server.bg_group, scanTask, .{server});
}

fn scanTask(server: *Server) Io.Cancelable!void {
    defer server.busyEnd();
    while (true) {
        const generation = server.scan.rerun.begin();
        scanOnce(server) catch |err| switch (err) {
            error.OutOfMemory => log.err("out of memory while scanning the workspace for source files", .{}),
        };
        if (@import("builtin").is_test and server.hooks.rescan.load(.acquire)) scheduleScan(server);
        server.scan.done.store(generation, .release);
        wakeScanWaiters(server);
        switch (server.scan.rerun.finish(generation)) {
            .again, .resumed => {},
            .done, .taken_over => return,
        }
    }
}

/// Waits until the scans scheduled so far have finished, or until `pending` is canceled or the
/// server shuts down, and records them in `pending.scans_awaited`: from then on the request takes
/// the search scope as of these scans (see `scopeIncomplete`). Scans scheduled during the wait are
/// for changes noticed after the request started waiting, and are not waited for: while source
/// files keep being created, a scan is always pending, and waiting for no scan to be pending would
/// not end. The wait is the rest of the walk in progress and at most one more.
pub fn waitScans(server: *Server, pending: *Pending) void {
    const target = server.scan.rerun.generation.load(.acquire);
    pending.scans_awaited = target;
    server.scan.mutex.lockUncancelable(server.io);
    defer server.scan.mutex.unlock(server.io);
    while (server.scan.done.load(.acquire) < target and !pending.cancel.load(.acquire) and !server.isShuttingDown()) {
        server.scan.cond.wait(server.io, &server.scan.mutex) catch break;
    }
}

pub fn wakeScanWaiters(server: *Server) void {
    server.scan.mutex.lockUncancelable(server.io);
    defer server.scan.mutex.unlock(server.io);
    server.scan.cond.broadcast(server.io);
}

/// One scan: updates `WorkspaceFiles` when the files found differ, and then indexes them for
/// workspace symbol. The directories entered go to the watcher (see `watch.Watcher.scanned`).
fn scanOnce(server: *Server) Allocator.Error!void {
    if (server.isShuttingDown()) return;
    var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rules = try server.originRules(a);
    const epoch = if (server.watcher) |w| w.watchEpoch() else 0;
    const found = try workspace_files.scan(server.io, a, &server.vfs, rules);
    defer if (server.watcher) |w| w.scanned(found.dirs, epoch);
    // Also when the files are the same: a build.zig.zon may have changed (see
    // `applyWatchedChanges`)
    try project_set.refreshSubProjects(server, a, found.files);
    var set: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty;
    for (found.files) |p| try set.put(a, try server.vfs.intern(p), {});
    const files = set.keys();
    std.mem.sort(Vfs.FileId, files, {}, struct {
        fn lt(_: void, x: Vfs.FileId, y: Vfs.FileId) bool {
            return @backingInt(x) < @backingInt(y);
        }
    }.lt);
    // A write transaction cancels in-flight requests: write only when the files differ. Scans run
    // one at a time, so nobody else changes the input after the comparison. A comparison canceled
    // by a write transaction (an edit) tells nothing about the files: it is made again once that
    // write has taken the lock (see `Db.waitPendingWrites`)
    const unchanged = while (true) {
        const same: ?bool = blk: {
            var ctx = server.db.beginRead(a);
            defer ctx.end();
            const current = ctx.get(WorkspaceFiles, {}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => break :blk null,
            };
            break :blk std.mem.eql(Vfs.FileId, current, files);
        };
        if (same) |s| break s;
        server.db.waitPendingWrites();
    };
    if (unchanged) return;
    {
        server.db.beginWriteOf(comptime Db.inputSet(&.{WorkspaceFiles}), .unordered);
        defer server.db.endWrite();
        // The engine takes ownership of the value, also when it fails
        try server.db.set(WorkspaceFiles, {}, try server.gpa.dupe(Vfs.FileId, files), .low);
    }
    scheduleIndexing(server);
}

/// One indexing pass over the module graph as of `generation` (see `index.rerun.generation`) or later
fn indexOnce(server: *Server, generation: u64) Io.Cancelable!void {
    var pc: panic_context.Text = .{};
    pc.enter("workspace symbol indexing", .{});
    defer pc.leave();
    var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_state.deinit();
    var basis: u64 = 0;
    const files: []const Vfs.FileId = while (true) {
        if (server.isShuttingDown()) return;
        // A canceled read begins again only once the pending writes have the lock (see
        // `Db.waitPendingWrites`)
        server.db.waitPendingWrites();
        var ctx = server.db.beginRead(arena_state.allocator());
        defer ctx.end();
        var r: Resolver = .{ .ctx = &ctx, .arena = arena_state.allocator() };
        // Interrupted by an edit: retry instead of abandoning this round
        basis = importsBasis(ctx.get(ModuleGraph.Input, {}) catch |err| switch (err) {
            error.Canceled => continue,
            error.OutOfMemory => return,
        });
        break za.ide_db.search.searchFiles(&r) catch |err| switch (err) {
            error.Canceled => continue,
            error.OutOfMemory => return,
        };
    };
    // Two steps: first the regular index of the searched files (workspace symbols), usable as soon
    // as it is built; then the auto-import index (public closures of the standard library and of
    // each module, `FileLinks` and `ImportSites` of the searched files), during which completion
    // works as usual, only without auto-import. The auto-import index covers the workspace files
    // that are in no module too: completion treats each of them as the root of its own module and
    // follows the files it reaches, which would otherwise compute their `ImportSites` in the
    // request.
    if (!try indexBatches(server, files, "Indexing", false)) return;
    {
        server.index.mutex.lockUncancelable(server.io);
        defer server.index.mutex.unlock(server.io);
        server.index.symbols = @max(server.index.symbols, generation);
        server.index.cond.broadcast(server.io);
    }
    if (!(server.index.imports_wanted.load(.acquire) and autoImportEnabled(server))) return;
    // When warming up fails (out of memory), the index is not marked usable: the next completion
    // retries, instead of the closures being expanded synchronously in a request
    if (!indexImportRoots(server)) return;
    if (!try indexBatches(server, files, "Indexing for auto-import", true)) return;
    // The project-level results completion needs are also computed before the index is marked
    // usable, rather than being left to the first completion
    while (true) {
        if (server.isShuttingDown() or !autoImportEnabled(server)) return;
        // A canceled read begins again only once the pending writes have the lock (see
        // `Db.waitPendingWrites`)
        server.db.waitPendingWrites();
        var ctx = server.db.beginRead(arena_state.allocator());
        defer ctx.end();
        _ = ctx.get(za.ide_db.imports.TestOnlyFiles, {}) catch |err| switch (err) {
            error.Canceled => continue,
            error.OutOfMemory => return,
        };
        break;
    }
    if (autoImportEnabled(server)) server.index.imports_basis.store(basis, .release);
}

/// Indexes `files` batch by batch (the auto-import index with `auto_import`, otherwise the
/// workspace symbol index), showing progress once it takes longer than a certain time. Returns
/// true when finished; false when shutting down, when auto-import has been disabled, or when out
/// of memory.
fn indexBatches(server: *Server, files: []const Vfs.FileId, title: []const u8, auto_import: bool) Io.Cancelable!bool {
    // A pass is quick when most files are already indexed: progress is shown only after a while
    const t0 = Io.Clock.awake.now(server.io);
    var progress: ?*Progress.Progress = null;
    var progress_started = false;
    var done: usize = 0;
    defer if (progress) |p| server.progress.end(server, p, if (done == files.len) "Done" else "Interrupted");
    var scratch: std.heap.ArenaAllocator = .init(server.gpa);
    defer scratch.deinit();
    while (done < files.len) {
        if (server.isShuttingDown() or (auto_import and !autoImportEnabled(server))) return false;
        const end = @min(done + index_batch, files.len);
        _ = scratch.reset(.retain_capacity);
        {
            // A canceled read begins again only once the pending writes have the lock (see
            // `Db.waitPendingWrites`)
            server.db.waitPendingWrites();
            var ctx = server.db.beginRead(scratch.allocator());
            defer ctx.end();
            indexFiles(&ctx, files[done..end], auto_import) catch |err| switch (err) {
                // Interrupted by an edit: retry this batch
                error.Canceled => continue,
                error.OutOfMemory => {
                    log.err("out of memory while indexing", .{});
                    return false;
                },
            };
        }
        done = end;
        if (server.db.wantsSweep()) _ = server.db.trySweep();
        if (!progress_started and t0.durationTo(Io.Clock.awake.now(server.io)).nanoseconds > index_progress_delay_ms * std.time.ns_per_ms) {
            progress = server.progress.begin(server, title, true);
            progress_started = true;
        }
        var buf: [32]u8 = undefined;
        if (progress) |p| server.progress.report(server, p, std.fmt.bufPrint(&buf, "{d}/{d} files", .{ done, files.len }) catch null, @intCast(done * 100 / files.len));
    }
    return true;
}

/// The composition of the module graph that determines the auto-import index: the standard
/// library, the default builtin, and each module's root, builtin, and imports, but not files
pub fn importsBasis(graph: ?*const ModuleGraph) u64 {
    const g = graph orelse return 0;
    var h: std.hash.Wyhash = .init(0);
    hashFile(&h, g.std_root);
    hashFile(&h, g.default_builtin);
    for (g.modules) |module| {
        hashFile(&h, module.root);
        hashFile(&h, module.builtin);
        for (module.imports) |imp| {
            h.update(imp.name);
            h.update(&.{0});
            h.update(std.mem.asBytes(&imp.module));
        }
        h.update(&.{0xff});
    }
    for (g.compiles) |c| {
        hashFile(&h, c.root);
        hashFile(&h, c.builtin);
    }
    return h.final();
}

fn hashFile(h: *std.hash.Wyhash, file: ?Vfs.FileId) void {
    const id: u32 = if (file) |f| f.index() else std.math.maxInt(u32);
    h.update(std.mem.asBytes(&id));
}

/// Workspace symbol index; with `auto_import`, the declaration and import-site index for
/// auto-import (only for Zig source files)
fn indexFiles(ctx: *Db.Ctx, files: []const Vfs.FileId, auto_import: bool) za.db.Error!void {
    for (files) |f| {
        if (auto_import) {
            if (!za.ide_db.imports.isZigSource(ctx.db.env.vfs.path(f))) continue;
            _ = try ctx.get(za.ide_db.imports.FileLinks, f);
            // `TestOnlyFiles` reads the `ImportSites` of each file: compute them here batch by
            // batch, evicting parse trees between batches. Otherwise it parses all project
            // files in one read transaction, and none of the parse trees can be evicted before the
            // transaction ends (about 700 MB on the Zig compiler source).
            _ = try ctx.get(za.ide_db.imports.ImportSites, f);
            continue;
        }
        _ = try ctx.get(za.syntax.FileIndex.Query, f);
        _ = try ctx.get(za.syntax.StringLiterals.Query, f);
        _ = try ctx.get(syntax_q.FileItemTree, f);
        _ = try ctx.get(syntax_q.ItemSummaries, f);
    }
}

/// The public export index is reused across completion requests and is built in the background
/// for the standard library, the `builtin` of each module, and named modules, not expanded in
/// completion requests. The files in the closures are indexed in batches, with parse trees and
/// other intermediate results evicted between batches: when one read transaction expands the
/// closure of the whole standard library, none of them can be evicted before the transaction
/// ends. Returns false when this round did not finish (the option was disabled, the server is
/// shutting down, or out of memory), in which case the caller must not mark the index usable.
fn indexImportRoots(server: *Server) bool {
    return warmImportRoots(server) catch |err| {
        log.err("failed to index import roots: {t}", .{err});
        return false;
    };
}

/// Roots whose public closures need to be warmed up: the standard library, the default builtin,
/// the builtin of each module, and the roots of imported modules
fn appendImportRoots(graph: ?*const ModuleGraph, roots: *std.ArrayList(Vfs.FileId), gpa: Allocator) Allocator.Error!void {
    const g = graph orelse return;
    if (g.std_root) |file| try roots.append(gpa, file);
    if (g.default_builtin) |file| try roots.append(gpa, file);
    for (g.modules) |module| {
        // Each module's `@import("builtin")` refers to its own generated file, and completion
        // queries this namespace unconditionally
        if (module.builtin) |file| try roots.append(gpa, file);
        for (module.imports) |imp| if (g.modules[imp.module].root) |file| try roots.append(gpa, file);
    }
    // The standard library uses the builtin of each compilation's root module
    for (g.compiles) |c| if (c.builtin) |file| try roots.append(gpa, file);
}

fn warmImportRoots(server: *Server) Allocator.Error!bool {
    const imports = za.ide_db.imports;
    var scratch: std.heap.ArenaAllocator = .init(server.gpa);
    defer scratch.deinit();
    var files: std.ArrayList(Vfs.FileId) = .empty;
    defer files.deinit(server.gpa);
    var seen: std.AutoHashMapUnmanaged(Vfs.FileId, void) = .empty;
    defer seen.deinit(server.gpa);
    while (true) {
        if (server.isShuttingDown() or !autoImportEnabled(server)) return false;
        // A canceled read begins again only once the pending writes have the lock (see
        // `Db.waitPendingWrites`)
        server.db.waitPendingWrites();
        var ctx = server.db.beginRead(scratch.allocator());
        defer ctx.end();
        const graph = (ctx.get(ModuleGraph.Input, {}) catch |err| switch (err) {
            error.Canceled => continue,
            error.OutOfMemory => return error.OutOfMemory,
        }) orelse return true;
        var roots: std.ArrayList(Vfs.FileId) = .empty;
        defer roots.deinit(server.gpa);
        try appendImportRoots(graph, &roots, server.gpa);
        // A module's root can be a data file (such as JSON added by `addAnonymousImport`)
        for (roots.items) |file| {
            if (!imports.isZigSource(server.vfs.path(file))) continue;
            if (!(try seen.getOrPut(server.gpa, file)).found_existing) try files.append(server.gpa, file);
        }
        break;
    }
    const root_count = files.items.len;
    var done: usize = 0;
    while (done < files.items.len) {
        if (server.isShuttingDown() or !autoImportEnabled(server)) return false;
        const end = @min(done + index_batch, files.items.len);
        _ = scratch.reset(.retain_capacity);
        var found: std.ArrayList(Vfs.FileId) = .empty;
        var canceled = false;
        {
            // A canceled read begins again only once the pending writes have the lock (see
            // `Db.waitPendingWrites`)
            server.db.waitPendingWrites();
            var ctx = server.db.beginRead(scratch.allocator());
            defer ctx.end();
            for (files.items[done..end]) |file| {
                imports.publicTargets(&ctx, file, &found, scratch.allocator()) catch |err| switch (err) {
                    error.Canceled => {
                        canceled = true;
                        break;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
            }
        }
        if (server.db.wantsSweep()) _ = server.db.trySweep();
        // Interrupted by an edit: retry this batch
        if (canceled) continue;
        for (found.items) |file| {
            if (!(try seen.getOrPut(server.gpa, file)).found_existing) try files.append(server.gpa, file);
        }
        done = end;
    }
    // Every file's index has been built; expanding the closures is only lookups and copying
    while (!server.isShuttingDown()) {
        if (!autoImportEnabled(server)) return false;
        _ = scratch.reset(.retain_capacity);
        // A canceled read begins again only once the pending writes have the lock (see
        // `Db.waitPendingWrites`)
        server.db.waitPendingWrites();
        var ctx = server.db.beginRead(scratch.allocator());
        defer ctx.end();
        var canceled = false;
        for (files.items[0..root_count]) |file| {
            _ = ctx.get(imports.Exports, .{ .ns = .{ .file = file, .container = 0 } }) catch |err| switch (err) {
                error.Canceled => {
                    canceled = true;
                    break;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        if (!canceled) return true;
    }
    return false;
}

test "importsBasis ignores the files of the module graph but follows modules and their imports" {
    const main: Vfs.FileId = @fromBackingInt(@intCast(1));
    const lib: Vfs.FileId = @fromBackingInt(@intCast(2));
    const std_root: Vfs.FileId = @fromBackingInt(@intCast(3));
    const modules = [_]ModuleGraph.Module{
        .{ .root = main, .imports = &.{.{ .name = "lib", .module = 1 }} },
        .{ .root = lib, .imports = &.{} },
    };
    const compiles = [_]ModuleGraph.Compile{.{ .root = main }};
    const base: ModuleGraph = .{ .arena = .{}, .std_root = std_root, .modules = &modules, .compiles = &compiles, .files = &.{.{ .file = main, .module = 0, .compile = 0 }} };
    // A build produced generated files: only files were
    // added, so the auto-import index remains usable
    var more_files = base;
    more_files.files = &.{ .{ .file = main, .module = 0, .compile = 0 }, .{ .file = lib, .module = 1, .compile = 0 } };
    try std.testing.expectEqual(importsBasis(&base), importsBasis(&more_files));
    const renamed = [_]ModuleGraph.Module{
        .{ .root = main, .imports = &.{.{ .name = "dep", .module = 1 }} },
        .{ .root = lib, .imports = &.{} },
    };
    var changed = base;
    changed.modules = &renamed;
    try std.testing.expect(importsBasis(&base) != importsBasis(&changed));
    var no_std = base;
    no_std.std_root = null;
    try std.testing.expect(importsBasis(&base) != importsBasis(&no_std));
    try std.testing.expectEqual(@as(u64, 0), importsBasis(null));
}

test "appendImportRoots warms std, module builtins and imported module roots" {
    const main: Vfs.FileId = @fromBackingInt(@intCast(1));
    const lib: Vfs.FileId = @fromBackingInt(@intCast(2));
    const std_root: Vfs.FileId = @fromBackingInt(@intCast(3));
    const default_builtin: Vfs.FileId = @fromBackingInt(@intCast(4));
    const module_builtin: Vfs.FileId = @fromBackingInt(@intCast(5));
    const modules = [_]ModuleGraph.Module{
        .{ .root = main, .builtin = module_builtin, .imports = &.{.{ .name = "lib", .module = 1 }} },
        .{ .root = lib, .imports = &.{} },
    };
    const graph: ModuleGraph = .{
        .arena = .{},
        .std_root = std_root,
        .default_builtin = default_builtin,
        .modules = &modules,
        .files = &.{},
    };
    var roots: std.ArrayList(Vfs.FileId) = .empty;
    defer roots.deinit(std.testing.allocator);
    try appendImportRoots(&graph, &roots, std.testing.allocator);
    for ([_]Vfs.FileId{ std_root, default_builtin, module_builtin, lib }) |expected|
        try std.testing.expect(std.mem.indexOfScalar(Vfs.FileId, roots.items, expected) != null);
    // A root that no module imports does not need warming up
    try std.testing.expect(std.mem.indexOfScalar(Vfs.FileId, roots.items, main) == null);
}

test "updateModuleGraph keeps the old inputs when an allocation fails" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var writer: transport.Writer = .{ .io = std.testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(std.testing.io, failing.allocator(), &writer);
    defer {
        failing.fail_index = std.math.maxInt(usize);
        server.deinit();
    }

    // First update: no failure point may leave a partially written input
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        try std.testing.expect(fail_index < 10_000);
        failing.alloc_index = 0;
        failing.resize_index = 0;
        failing.has_induced_failure = false;
        failing.fail_index = fail_index;
        if (updateModuleGraphInner(&server)) |_| {
            failing.fail_index = std.math.maxInt(usize);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failing.fail_index = std.math.maxInt(usize);
            server.db.beginWrite();
            const graph = server.db.peek(ModuleGraph.Input, {});
            const target = server.db.peek(za.sema.queries.TargetAbi, {});
            server.db.endWrite();
            try std.testing.expectEqual(null, graph);
            try std.testing.expect(std.meta.eql(za.sema.queries.TargetAbi.default, target));
        }
    }

    server.db.beginWrite();
    const old_graph = server.db.peek(ModuleGraph.Input, {});
    const old_target = server.db.peek(za.sema.queries.TargetAbi, {});
    server.db.endWrite();
    try std.testing.expect(old_graph != null);

    // When a later update fails, the old graph and TargetAbi are kept. Switch to another default
    // builtin.zig so that the new graph differs from the old one and the write is reached.
    try project_set.setToolchain(&server, .{ .default_builtin = try server.gpa.dupe(u8, "/zig-analyzer-test/builtin.zig") });
    fail_index = 0;
    while (true) : (fail_index += 1) {
        try std.testing.expect(fail_index < 10_000);
        failing.alloc_index = 0;
        failing.resize_index = 0;
        failing.has_induced_failure = false;
        failing.fail_index = fail_index;
        if (updateModuleGraphInner(&server)) |_| {
            failing.fail_index = std.math.maxInt(usize);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failing.fail_index = std.math.maxInt(usize);
            server.db.beginWrite();
            const graph = server.db.peek(ModuleGraph.Input, {});
            const target = server.db.peek(za.sema.queries.TargetAbi, {});
            server.db.endWrite();
            try std.testing.expectEqual(old_graph, graph);
            try std.testing.expect(std.meta.eql(old_target, target));
        }
    }
    server.db.beginWrite();
    const new_graph = server.db.peek(ModuleGraph.Input, {});
    server.db.endWrite();
    try std.testing.expect(new_graph != old_graph);
}

test "updateModuleGraph takes no write transaction when nothing changed" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var writer: transport.Writer = .{ .io = std.testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, &writer);
    defer server.deinit();
    try updateModuleGraphInner(&server);
    const writes = server.db.writes.load(.monotonic);
    // The module graph is updated after every build: opening a write transaction when nothing
    // changed would cancel in-flight computations and requests
    try updateModuleGraphInner(&server);
    try std.testing.expectEqual(writes, server.db.writes.load(.monotonic));
    try project_set.setToolchain(&server, .{ .default_builtin = try server.gpa.dupe(u8, "/zig-analyzer-test/builtin.zig") });
    try updateModuleGraphInner(&server);
    try std.testing.expectEqual(writes + 1, server.db.writes.load(.monotonic));
}

test "computeTargets reads each builtin once per update and reads it again in the next" {
    const text32 =
        \\pub const abi: std.Target.Abi = .musl;
        \\pub const cpu: std.Target.Cpu = .{
        \\    .arch = .x86,
        \\    .model = &std.Target.x86.cpu.i686,
        \\    .features = std.Target.x86.featureSet(&.{
        \\        .@"32bit_mode",
        \\    }),
        \\};
        \\pub const os: std.Target.Os = .{
        \\    .tag = .linux,
        \\};
    ;
    const text64 =
        \\pub const abi: std.Target.Abi = .gnu;
        \\pub const cpu: std.Target.Cpu = .{
        \\    .arch = .x86_64,
        \\    .model = &std.Target.x86.cpu.x86_64,
        \\    .features = std.Target.x86.featureSet(&.{
        \\        .@"64bit",
        \\    }),
        \\};
        \\pub const os: std.Target.Os = .{
        \\    .tag = .linux,
        \\};
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "builtin.zig", .data = text32 });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "builtin.zig" });
    defer std.testing.allocator.free(path);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var writer: transport.Writer = .{ .io = std.testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, &writer);
    defer server.deinit();
    const builtin = try server.vfs.intern(path);
    const modules = [_]ModuleGraph.Module{
        .{ .root = null, .builtin = builtin, .imports = &.{} },
        .{ .root = null, .builtin = builtin, .imports = &.{} },
    };
    const compiles = [_]ModuleGraph.Compile{
        .{ .root = null, .builtin = builtin },
        .{ .root = null, .builtin = builtin },
        .{ .root = null, .builtin = builtin },
    };
    const graph: ModuleGraph = .{ .arena = .{}, .std_root = null, .modules = &modules, .compiles = &compiles, .files = &.{} };

    var reads: std.atomic.Value(usize) = .init(0);
    server.hooks.builtin_target_reads = &reads;
    defer server.hooks.builtin_target_reads = null;
    {
        var targets = try computeTargets(&server, &graph, .latest);
        defer targets.deinit(server.gpa);
        // Three compilations, two modules and the common target all use the same builtin
        try std.testing.expectEqual(1, reads.load(.monotonic));
        try std.testing.expectEqual(@as(?u16, 32), targets.common.pointer_bits);
        for (targets.compiles) |target| try std.testing.expectEqual(@as(?u16, 32), target.pointer_bits);
    }
    // An editable builtin (`zig.builtin_path`) is read again in the next update, not taken from
    // the target recorded in `builtin_targets`
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "builtin.zig", .data = text64 });
    {
        var targets = try computeTargets(&server, &graph, .latest);
        defer targets.deinit(server.gpa);
        try std.testing.expectEqual(2, reads.load(.monotonic));
        try std.testing.expectEqual(@as(?u16, 64), targets.common.pointer_bits);
        for (targets.compiles) |target| try std.testing.expectEqual(@as(?u16, 64), target.pointer_bits);
    }
}

test "scanOnce: a comparison canceled by an edit is made again instead of writing the same files" {
    // Guards against a scan that found the files already recorded writing them again when an
    // edit's write transaction canceled its comparison: that write advanced the revision and
    // canceled the requests in flight
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var writer: transport.Writer = .{ .io = std.testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(std.testing.io, std.testing.allocator, &writer);
    defer server.deinit();
    const revision = server.db.revision;
    const writes = server.db.writes.load(.monotonic);
    // An edit's write transaction has registered and has not taken the lock yet, as between
    // `Db.beginWriteOf` registering it and locking: the scan's comparison is canceled
    _ = server.db.pending_write.fetchAdd(1, .seq_cst);
    var done: std.atomic.Value(bool) = .init(false);
    const Scan = struct {
        fn run(s: *Server, d: *std.atomic.Value(bool)) void {
            defer d.store(true, .release);
            scanOnce(s) catch |err| std.debug.panic("scan failed: {t}", .{err});
        }
    };
    const scan = try std.Thread.spawn(.{}, Scan.run, .{ &server, &done });
    // The scan either waits for the edit or finishes without waiting for it
    while (!done.load(.acquire) and server.db.pending_write_waiters.load(.seq_cst) == 0) std.Thread.yield() catch {};
    // The edit takes the lock
    _ = server.db.pending_write.fetchSub(1, .seq_cst);
    std.testing.io.futexWake(u32, &server.db.pending_write.raw, std.math.maxInt(u32));
    scan.join();
    // No root directories, so no source files: the same as recorded, nothing to write
    try std.testing.expectEqual(writes, server.db.writes.load(.monotonic));
    try std.testing.expectEqual(revision, server.db.revision);
}
