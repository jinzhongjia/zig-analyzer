//! A project with a build.zig: manages the build system protocol process, the project model, the
//! compile set, and compiler diagnostics.
//!
//! Threading model: each Workspace has a dedicated background task that blocks reading BSP events
//! and handles them; the LSP main loop interacts with it only through `requestBuild` / `stop`.
//! Edits of files in the compile set may recompute it from other tasks (see `refreshImports`).
//!
//! Lifecycle: when maker crashes, build.zig or the build configuration changes, or maker's local
//! cache directory is deleted, the project is restarted as a new instance. The new instance is
//! invisible until its first build completes (or configuration fails); meanwhile the old
//! instance's model, compile set, and compiler diagnostics remain in effect. If the old instance
//! has no model, the new instance replaces it as soon as it is configured; if it has one and
//! configuration fails, the old instance stays (see `Server.restartWorkspace`, `Server.promote`,
//! `Server.keepOnConfigurationFailure`).
//! Instances are reclaimed by reference counting: the server's project list, the background task,
//! and callers that use an instance temporarily each hold one reference.
//!
//! Lock order: never begin a write transaction of the query engine while holding `mutex`. The
//! diagnostics publishing task acquires `mutex` inside a read transaction, and a write transaction
//! waits for all read transactions to finish, so acquiring them in opposite orders deadlocks.
//! `set_mutex` is acquired before `mutex` and outside any transaction; transactions may begin
//! while holding it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ErrorBundle = std.zig.ErrorBundle;

const za = @import("../zig_analyzer.zig");
const Server = @import("Server.zig");
const origin = @import("origin.zig");
const bsp = za.project.bsp;
const builtin = za.project.builtin;
const ZigEnv = za.project.ZigEnv;
const configuration = za.project.configuration;
const exports = za.project.exports;
const ProjectModel = za.base.ProjectModel;
const Vfs = za.base.Vfs;
const FileId = Vfs.FileId;
const compiler = za.diagnostics.compiler;
const CompileSet = za.diagnostics.compile_set;
const database = @import("../database.zig");
const panic_context = za.util.panic_context;
const FileText = database.inputs.FileText;
const FileIndex = database.FileIndex;

const Progress = Server.Progress.Progress;

const log = std.log.scoped(.workspace);

const Workspace = @This();

server: *Server,
gpa: Allocator,
/// Build root directory (absolute path, normalized)
root: []const u8,
/// The zig environment in effect at startup (held by the server until exit): the maker, reading
/// the build graph, and generating builtin.zig all use it, matching the lib directory and global
/// cache directory the maker uses; when the zig path configuration changes, the whole instance is
/// restarted and replaced
env: *const ZigEnv,
/// Copy of the configuration at startup (build arguments, diagnostics steps); a configuration
/// change restarts and replaces the whole instance
config: Server.Config,
/// `zig-analyzer.zon` in the project root (only the items that appear in it, see
/// `Config.parseProject`); null when there is none. Unchanged after startup; a change of the file
/// restarts and replaces the whole instance.
project: ?Server.Config = null,
/// This instance is the Nth automatic restart after consecutive maker crashes (0: normal start)
crash_restarts: u8 = 0,
/// Reference count; the instance is freed when it drops to zero (see `acquire` / `release`)
refs: std.atomic.Value(u32) = .init(0),
/// New instance created by a restart that has not replaced this one yet (holds a reference);
/// protected by `Server.workspaces_mutex`
successor: ?*Workspace = null,
/// The caller has decided where this instance goes: added to the project list, attached to an old
/// instance, or discarded (see `Server.startWorkspace`, `Server.restartWorkspace`).
/// Only after this does the background task handle events, and only then can `Server.isVisible`
/// and `Server.promote` decide based on the placement.
placed: Io.Event = .unset,

mutex: Io.Mutex = .init,
/// Serializes the computations of the compile set (by the background task, and by the tasks that
/// check edited files, see `refreshImports`) with changes to `model`, whose pointer the
/// computations use outside `mutex`
set_mutex: Io.Mutex = .init,
// ── The following fields are protected by mutex ──
client: ?*bsp.Client = null,
model: ?ProjectModel = null,
compile_set: ?CompileSet.Result = null,
/// Files reachable from compile steps other than the diagnostics steps (used only to determine
/// which modules files belong to, see `recomputeCompileSet`); null when it equals the compile set
resolve_set: ?CompileSet.Result = null,
/// Build scripts (see `CompileSet.buildScripts`): computed when the background task starts, from
/// the current text of the files (open files use their buffers, the rest are read from disk);
/// valid even when reading the build graph fails
build_scripts: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty,
/// Compiler diagnostics of the most recent build
result: ?*compiler.BuildResult = null,
/// Compile result sequence number taken when `result` was stored (see
/// `Server.nextCompileGeneration`): larger means newer
result_generation: u64 = 0,
/// Time when `result` was stored (Unix milliseconds)
result_at_ms: i64 = 0,
/// FileId → entry in `result`
result_files: std.AutoArrayHashMapUnmanaged(FileId, *const compiler.FileResult) = .empty,
building: bool = false,
/// At least one build has completed (used to decide whether crashes are "consecutive")
built: bool = false,
/// The first load has finished: the build graph was read and the compile set computed, or loading
/// failed or the instance has ended. Before that, it is not yet known which files outside the root
/// directory belong to the project, so single-file mode defers compiling (see
/// `Server.projectsLoading`).
load_done: bool = false,
/// Another build request arrived during the build: the result of this round is discarded, and the
/// project is rebuilt as soon as the round finishes
rebuild: bool = false,
/// New generated file paths became known during the build, but the compile set has not been
/// recomputed yet (throttled, see `generated_recompute_interval_ms`)
generated_dirty: bool = false,
/// End time and duration of the last compile set recompute triggered by generated files (see
/// `generatedRecomputeDue`)
generated_recomputed_at: ?Io.Timestamp = null,
generated_recompute_ns: u64 = 0,
stopping: bool = false,
/// Project loading progress (from startup until the first compile set is computed)
loading: ?*Progress = null,
/// Progress of the current build and the number of completed steps
build_progress: ?*Progress = null,
build_total: u32 = 0,
build_done: u32 = 0,
/// Diagnostics steps and their transitive dependencies: only errors from these steps are
/// published as compiler diagnostics (the extra steps in the build request that produce generated
/// files do not affect diagnostics, consistent with running `zig build <step>` directly)
diag_steps: std.DynamicBitSetUnmanaged = .{},
/// Identities (inode numbers) of the maker's local cache directory and of its manifest directory
/// `h`, taken when the build graph is read. The maker opens both once at startup and keeps
/// writing through those handles: once either is deleted or replaced, steps that write into the
/// cache fail without errors, so the maker is restarted (see `cacheReplaced`)
cache_identity: ?[2]Io.File.INode = null,

// ── The following fields are accessed only by the background task ──
bundles: std.ArrayList(ErrorBundle) = .empty,
/// Steps among the diagnostics steps and their dependencies that failed in this round, and those
/// of them that reported no errors (a missing system library, a failing Run or Fail step: the
/// cause is only on the maker's stderr, or a dependency failed)
failed_steps: std.ArrayList(u32) = .empty,
silent_steps: std.ArrayList(u32) = .empty,
/// Hash of the names of the steps last reported as failing without errors (0: none), so the
/// warning is not repeated on every save while nothing changes
silent_warned: u64 = 0,

// ── The following fields are protected by set_mutex ──
/// Files whose loading from disk has already been attempted (nonexistent files are recorded too,
/// to avoid repeated attempts)
loaded: std.AutoHashMapUnmanaged(FileId, void) = .empty,
/// Hash of the imports (see `importsHash`) of each file the latest compile set computation read;
/// null when the computation read different imports at different times
read_imports: std.AutoHashMapUnmanaged(FileId, ?u64) = .empty,

/// Recomputing the compile set during a build because of generated file paths: at least
/// `generated_recompute_interval_ms` after the previous recompute ended, and no less than
/// `generated_recompute_cost_factor` times the duration of the previous recompute. In a large
/// project one recompute can take seconds (the Zig compiler's build graph has over four thousand
/// compile steps, and computing the files reachable from them takes about 1 second); with a fixed
/// interval, the task reading build events would be recomputing all the time: maker's events pile
/// up, the build slows down, the module graph is updated every second throughout the build, and
/// background indexing never stops.
const generated_recompute_interval_ms = 1000;
const generated_recompute_cost_factor = 4;

/// Starts maker and reads its events in the background. The returned instance carries one
/// reference owned by the caller; the caller sets `placed` once it has decided where the instance
/// goes.
pub fn start(server: *Server, root: []const u8, crash_restarts: u8) !*Workspace {
    const gpa = server.gpa;
    const env = server.zigEnv() orelse return error.ZigNotFound;
    const ws = try gpa.create(Workspace);
    errdefer gpa.destroy(ws);
    // One reference belongs to the background task, one to the caller
    ws.* = .{ .server = server, .gpa = gpa, .root = try gpa.dupe(u8, root), .env = env, .config = undefined, .crash_restarts = crash_restarts, .refs = .init(2) };
    errdefer gpa.free(ws.root);
    ws.config = try server.configSnapshot();
    errdefer ws.config.deinit(gpa);
    ws.project = try loadProjectConfig(server, root);
    errdefer if (ws.project) |*p| p.deinit(gpa);
    if (ws.project) |*p| try ws.config.overlayProject(gpa, p);
    var title_buf: [256]u8 = undefined;
    ws.loading = server.progress.begin(server, std.fmt.bufPrint(&title_buf, "Loading project {s}", .{std.fs.path.basename(root)}) catch "Loading project", false);
    errdefer server.progress.end(server, ws.loading, null);
    ws.client = try bsp.Client.start(gpa, server.io, env, root, ws.config.build_args);
    errdefer ws.client.?.deinit();
    // Counted as busy before the background task starts: the task may reach its final busyEnd
    // before execution gets here
    server.busyBegin();
    errdefer server.busyEnd();
    try server.bg_group.concurrent(server.io, run, .{ws});
    _ = server.live_workspaces.fetchAdd(1, .monotonic);
    return ws;
}

pub fn acquire(ws: *Workspace) void {
    _ = ws.refs.fetchAdd(1, .monotonic);
}

/// Drops a reference; dropping the last one frees the instance (the background task has ended by
/// then)
pub fn release(ws: *Workspace) void {
    if (ws.refs.fetchSub(1, .acq_rel) == 1) ws.destroy();
}

/// Reads `zig-analyzer.zon` in the project root; null when the file does not exist. Problems in it
/// are reported to the user, and the problematic items (the whole file on a syntax error) are
/// ignored.
fn loadProjectConfig(server: *Server, root: []const u8) Allocator.Error!?Server.Config {
    const gpa = server.gpa;
    const path = try std.fs.path.join(gpa, &.{ root, Server.Config.project_file });
    defer gpa.free(path);
    const text = Io.Dir.cwd().readFileAlloc(server.io, path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return null,
        else => {
            log.warn("{s}: cannot read: {t}", .{ path, err });
            return null;
        },
    };
    defer gpa.free(text);
    const project = try Server.Config.parseProject(gpa, text);
    server.reportConfigWarnings(path, &project);
    return project;
}

/// Stops: immediately terminates maker and its child processes (an in-progress build does not
/// continue); the background task then reads end of input, wraps up, and reaps the process
pub fn stop(ws: *Workspace) void {
    ws.mutex.lockUncancelable(ws.server.io);
    defer ws.mutex.unlock(ws.server.io);
    ws.stopping = true;
    if (ws.client) |c| c.terminate();
}

/// Maximum number of automatic restarts after consecutive maker crashes
const max_crash_restarts = 3;

fn destroy(ws: *Workspace) void {
    const gpa = ws.gpa;
    _ = ws.server.live_workspaces.fetchSub(1, .monotonic);
    if (ws.successor) |s| s.release();
    if (ws.model) |*m| m.deinit(gpa);
    if (ws.compile_set) |*s| s.deinit(gpa);
    if (ws.resolve_set) |*s| s.deinit(gpa);
    ws.build_scripts.deinit(gpa);
    if (ws.result) |r| r.release(gpa);
    ws.result_files.deinit(gpa);
    ws.diag_steps.deinit(gpa);
    ws.config.deinit(gpa);
    if (ws.project) |*p| p.deinit(gpa);
    for (ws.bundles.items) |*eb| eb.deinit(gpa);
    ws.bundles.deinit(gpa);
    ws.failed_steps.deinit(gpa);
    ws.silent_steps.deinit(gpa);
    ws.loaded.deinit(gpa);
    ws.read_imports.deinit(gpa);
    gpa.free(ws.root);
    gpa.destroy(ws);
}

/// Requests a build after a file is saved; while a build is in progress, marks it to be rebuilt
/// once it finishes. When the maker's local cache directory has been deleted or replaced, the
/// project is restarted instead (its build would fail).
pub fn requestBuild(ws: *Workspace) void {
    const io = ws.server.io;
    const replaced = blk: {
        ws.mutex.lockUncancelable(io);
        defer ws.mutex.unlock(io);
        const client = ws.client orelse return;
        const model = &(ws.model orelse return);
        if (ws.stopping) return;
        if (ws.building) {
            ws.rebuild = true;
            return;
        }
        if (ws.cacheReplaced()) break :blk true;
        const steps = model.buildSteps(ws.gpa, ws.config.compiler_diagnostics) catch return;
        defer ws.gpa.free(steps);
        if (steps.len != 0) {
            ws.building = true;
            ws.server.busyBegin();
            ws.build_progress = ws.server.progress.begin(ws.server, buildTitle(model, ws.config.compiler_diagnostics), true);
            sendBuild(ws, client, model, steps) catch |err| {
                log.err("failed to send build request: {t}", .{err});
                ws.building = false;
                ws.server.progress.end(ws.server, ws.build_progress, "Failed to send build request");
                ws.build_progress = null;
                ws.server.busyEnd();
            };
            return;
        }
        break :blk false;
    };
    if (replaced) {
        log.info("{s}: the local cache directory of zig build was deleted or replaced, restarting", .{ws.root});
        ws.server.restartWorkspace(ws, 0);
        return;
    }
    // The compiler is not run and there are no generated files to produce: do not build, but
    // finish once with an empty result (clears compiler diagnostics published before a restart)
    ws.finishBuild() catch {};
}

/// Identities of the local cache directory `cache` and of its manifest directory `h`; null when
/// either cannot be found
fn cacheIdentity(io: Io, cache: []const u8) ?[2]Io.File.INode {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const h = std.fmt.bufPrint(&buf, "{s}{c}h", .{ cache, std.fs.path.sep }) catch return null;
    const root = Io.Dir.cwd().statFile(io, cache, .{}) catch return null;
    const manifests = Io.Dir.cwd().statFile(io, h, .{}) catch return null;
    return .{ root.inode, manifests.inode };
}

/// The local cache directory the maker opened has been deleted or replaced since the build graph
/// was read. While the maker holds the old directories open, their inode numbers cannot be reused,
/// so a recreated directory always has a different identity. The caller holds mutex.
fn cacheReplaced(ws: *Workspace) bool {
    const known = ws.cache_identity orelse return false;
    const model = &(ws.model orelse return false);
    const now = cacheIdentity(ws.server.io, model.local_cache_root) orelse return true;
    return !std.mem.eql(Io.File.INode, &known, &now);
}

/// Title of the build progress: the names of the diagnostics steps; without compiler diagnostics
/// only generated files are built
fn buildTitle(model: *const ProjectModel, with_diagnostics: bool) []const u8 {
    if (!with_diagnostics) return "zig build (generated files)";
    const S = struct {
        threadlocal var buf: [256]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.buf);
    w.writeAll("zig build") catch {};
    for (model.diagnostics_steps) |s| w.print(" {s}", .{model.steps[s].name}) catch break;
    return w.buffered();
}

/// Sends a build request and resets the progress counters; the caller holds mutex
fn sendBuild(ws: *Workspace, client: *bsp.Client, model: *const ProjectModel, steps: []const u32) !void {
    var closure = try model.dependencyClosure(ws.gpa, steps);
    defer closure.deinit(ws.gpa);
    ws.build_total = @intCast(closure.count());
    ws.build_done = 0;
    try client.buildSteps(steps);
}

/// Whether the file belongs to this project: it is in the compile set or under the build root
pub fn owns(ws: *Workspace, file: FileId) bool {
    ws.mutex.lockUncancelable(ws.server.io);
    defer ws.mutex.unlock(ws.server.io);
    if (ws.compile_set) |*s| if (s.contains(file)) return true;
    return ws.server.vfs.isUnder(ws.server.vfs.path(file), ws.root);
}

/// Whether the file is in this project's module graph: it is in the compile set, or reachable
/// from the other compile steps
pub fn contains(ws: *Workspace, file: FileId) bool {
    ws.mutex.lockUncancelable(ws.server.io);
    defer ws.mutex.unlock(ws.server.io);
    if (ws.compile_set) |*s| if (s.contains(file)) return true;
    if (ws.resolve_set) |*s| if (s.contains(file)) return true;
    return false;
}

/// Library directories of this project (see `origin.Rules`): the local cache directory used by
/// maker (where generated files live, not necessarily `<build root>/.zig-cache`; it is left out
/// when it contains the build root, since generated files cannot be told apart from project files
/// then) and the fetched dependency packages, copied into `arena`
pub fn libraryDirs(ws: *Workspace, arena: Allocator, local_caches: *std.ArrayList([]const u8), packages: *std.ArrayList([]const u8)) Allocator.Error!void {
    ws.mutex.lockUncancelable(ws.server.io);
    defer ws.mutex.unlock(ws.server.io);
    const model = &(ws.model orelse return);
    const cache = model.local_cache_root;
    if (cache.len != 0 and !ws.server.vfs.isUnder(ws.root, cache)) try local_caches.append(arena, try arena.dupe(u8, cache));
    for (model.package_roots) |p| try packages.append(arena, try arena.dupe(u8, p));
}

/// The first load has not finished yet (see `load_done`)
pub fn isLoading(ws: *Workspace) bool {
    ws.mutex.lockUncancelable(ws.server.io);
    defer ws.mutex.unlock(ws.server.io);
    return !ws.load_done;
}

/// Ends the first load: single-file compiles deferred until now proceed with the files' context
/// at this point
fn finishLoading(ws: *Workspace) void {
    {
        ws.mutex.lockUncancelable(ws.server.io);
        defer ws.mutex.unlock(ws.server.io);
        if (ws.load_done) return;
        ws.load_done = true;
    }
    ws.server.reconcileSingle();
}

/// Whether to publish live diagnostics: yes before the compile set is computed; afterwards for
/// build scripts, files reachable from any compile step, and files under the directory of a
/// module's root file. A relative `@import` cannot leave the directory of its module's root file,
/// so a file outside all of them is never compiled with the project; a file inside one is compiled
/// once it is imported, so files not imported yet and files only tests compile get syntax and
/// AstGen errors while they are edited.
pub fn liveEligible(ws: *Workspace, file: FileId) bool {
    ws.mutex.lockUncancelable(ws.server.io);
    defer ws.mutex.unlock(ws.server.io);
    if (ws.build_scripts.contains(file)) return true;
    const set = &(ws.compile_set orelse return true);
    // The build graph compiles nothing: treat an empty set as not yet computed, so that not every
    // file loses live diagnostics
    if (set.files.count() == 0) return true;
    if (set.contains(file)) return true;
    if (ws.resolve_set) |*s| if (s.contains(file)) return true;
    const model = &(ws.model orelse return false);
    const path = ws.server.vfs.path(file);
    for (model.modules) |m| {
        const dir = std.fs.path.dirname(m.root_file orelse continue) orelse continue;
        if (ws.server.vfs.isUnder(path, dir)) return true;
    }
    return false;
}

/// Whether this project takes part in the module graph: it has a model and a compile set (see
/// `Server.updateModuleGraph`)
pub fn inModuleGraph(ws: *Workspace) bool {
    ws.mutex.lockUncancelable(ws.server.io);
    defer ws.mutex.unlock(ws.server.io);
    return ws.model != null and ws.compile_set != null;
}

/// Whether the file is a build script of this project: a change requires reconfiguring
pub fn isBuildScript(ws: *Workspace, file: FileId) bool {
    ws.mutex.lockUncancelable(ws.server.io);
    defer ws.mutex.unlock(ws.server.io);
    return ws.build_scripts.contains(file);
}

/// How a path changed on disk, for `changesConfigureInput`
pub const PathChange = enum { created, changed, deleted };

/// Whether a change of `path` (an absolute, normalized path) changes an input of the configure
/// phase that build.zig declares (see `ProjectModel.configure_inputs`): such a file itself, or
/// such a directory itself or an entry created in or deleted from it. Outside watch mode the
/// maker does not reconfigure by itself, so the project is restarted.
pub fn changesConfigureInput(ws: *Workspace, path: []const u8, change: PathChange) bool {
    ws.mutex.lockUncancelable(ws.server.io);
    defer ws.mutex.unlock(ws.server.io);
    const model = &(ws.model orelse return false);
    const vfs = &ws.server.vfs;
    for (model.configure_inputs) |input| {
        if (path.len == input.path.len and vfs.isUnder(path, input.path)) return true;
        if (!input.directory or change == .changed) continue;
        const dir = std.fs.path.dirname(path) orelse continue;
        if (dir.len == input.path.len and vfs.isUnder(dir, input.path)) return true;
    }
    return false;
}

/// Directories among the configure inputs (see `changesConfigureInput`), copied into `arena`
pub fn configureInputDirs(ws: *Workspace, arena: Allocator, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    ws.mutex.lockUncancelable(ws.server.io);
    defer ws.mutex.unlock(ws.server.io);
    const model = &(ws.model orelse return);
    for (model.configure_inputs) |input| if (input.directory) try out.append(arena, try arena.dupe(u8, input.path));
}

// ── Background task ──────────────────────────────────────────────────

fn run(ws: *Workspace) Io.Cancelable!void {
    var started = true;
    // maker exits when build.zig fails to compile, which is expected (it is restarted when
    // build.zig is saved)
    var config_failed = false;
    const client = ws.client.?;
    ws.placed.waitUncancelable(ws.server.io);
    ws.computeBuildScripts() catch log.err("{s}: out of memory while finding build scripts", .{ws.root});
    while (true) {
        var event = client.next() catch |err| {
            if (err == error.Canceled or ws.server.isShuttingDown()) {
                // Server shutting down: the reading task was canceled, not a maker problem
            } else if (config_failed) {
                log.info("{s}: build.zig failed to compile, build system exited; will restart when build.zig is saved", .{ws.root});
            } else if (!ws.isStopping()) {
                // maker crashed (e.g. the 0.17 maker has a race when it receives a new build
                // request, easily triggered with few cores): restart automatically
                ws.mutex.lockUncancelable(ws.server.io);
                const next = if (ws.built) 1 else ws.crash_restarts + 1;
                ws.mutex.unlock(ws.server.io);
                if (next > max_crash_restarts) {
                    log.err("{s}: build system exited unexpectedly: {t} ({?t})", .{ ws.root, err, client.readError() });
                    ws.server.showWarning("zig build keeps exiting unexpectedly, compiler diagnostics are unavailable until build.zig is saved");
                    ws.server.abandon(ws);
                } else {
                    log.info("{s}: build system exited unexpectedly ({t}, {?t}), restarting", .{ ws.root, err, client.readError() });
                    // Count as busy during the restart: this instance may not be busy when it
                    // crashes, and waitIdle (e.g. in shutdown) must not return before the new
                    // instance counts as busy, otherwise the new instance's progress may end only
                    // after shutdown
                    ws.server.busyBegin();
                    ws.server.restartWorkspace(ws, next);
                    ws.server.busyEnd();
                }
            }
            break;
        };
        if (event == .configuration_failed) config_failed = true;
        defer event.deinit(ws.gpa);
        ws.handle(&event) catch |err| switch (err) {
            error.OutOfMemory => log.err("{s}: out of memory while handling build event", .{ws.root}),
        };
        // Startup ends once the first build graph is handled (or loading the build graph fails).
        // Deferred single-file compiles start before counting as idle.
        if (started and (event == .configuration or event == .configuration_failed)) {
            started = false;
            ws.finishLoading();
            ws.server.busyEnd();
        }
    }
    ws.mutex.lockUncancelable(ws.server.io);
    const was_building = ws.building;
    ws.building = false;
    const c = ws.client;
    ws.client = null;
    ws.server.progress.end(ws.server, ws.build_progress, "Build interrupted");
    ws.build_progress = null;
    ws.server.progress.end(ws.server, ws.loading, if (config_failed) "build.zig has errors" else null);
    ws.loading = null;
    ws.mutex.unlock(ws.server.io);
    ws.finishLoading();
    // Count as idle only after the progress ends: by the time waitIdle (e.g. in shutdown)
    // returns, the client has received the end
    if (started) ws.server.busyEnd();
    if (was_building) ws.server.busyEnd();
    if (c) |cl| cl.deinit();
    ws.release();
}

fn isStopping(ws: *Workspace) bool {
    ws.mutex.lockUncancelable(ws.server.io);
    defer ws.mutex.unlock(ws.server.io);
    return ws.stopping;
}

fn handle(ws: *Workspace, event: *bsp.Event) Allocator.Error!void {
    const io = ws.server.io;
    var pc: panic_context.Text = .{};
    pc.enter("project {s}: build event {t}", .{ ws.root, event.* });
    defer pc.leave();
    // A stopped instance (replaced by a restart, project removed, server shutting down) no longer
    // handles events maker sent before exiting: their results would not be used.
    // Progress and the busy count are wrapped up when the background task ends.
    if (ws.isStopping()) return;
    switch (event.*) {
        .handshake => |h| if (h.version != bsp.protocol_version) {
            log.err("{s}: build system protocol version {d} does not match supported version {d}", .{ ws.root, h.version, bsp.protocol_version });
            ws.stop();
            ws.server.abandon(ws);
        },
        .configuration => |path| {
            // The project is not started when the user's zig differs from the version used at
            // compile time (see `Server.startWorkspace`), so the build graph format matches
            ws.reportLoading("Reading build graph");
            var model = configuration.load(ws.gpa, io, ws.root, path, ws.env) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    // Cannot build without a model: end loading and stop maker, and finish with no
                    // compile result (clears earlier compiler diagnostics)
                    var buf: [512]u8 = undefined;
                    ws.server.showWarning(std.fmt.bufPrint(&buf, "cannot read the build graph of {s} ({t}): compiler diagnostics are unavailable until build.zig is saved", .{ ws.root, err }) catch
                        "cannot read the build graph: compiler diagnostics are unavailable until build.zig is saved");
                    ws.endLoading("Failed to read the build graph");
                    ws.stop();
                    try ws.finishBuild();
                    return;
                },
            };
            if (!model.hasCompileSteps()) try ws.loadExports(&model);
            try ws.generateBuiltins(&model);
            {
                const names = try ws.config.diagnosticsSteps(ws.gpa);
                defer if (names.ptr != ws.config.diagnostics_steps.ptr) ws.gpa.free(names);
                if (try model.setDiagnosticsSteps(ws.gpa, names) != 0) {
                    var buf: [256]u8 = undefined;
                    ws.server.showWarning(std.fmt.bufPrint(&buf, "some diagnostics.steps are not steps of {s}, they are ignored", .{ws.root}) catch "some diagnostics.steps are not steps of the project, they are ignored");
                }
            }
            const identity = cacheIdentity(io, model.local_cache_root);
            {
                ws.set_mutex.lockUncancelable(io);
                defer ws.set_mutex.unlock(io);
                ws.mutex.lockUncancelable(io);
                defer ws.mutex.unlock(io);
                if (ws.model) |*old| old.deinit(ws.gpa);
                ws.model = model;
                ws.cache_identity = identity;
                ws.diag_steps.deinit(ws.gpa);
                ws.diag_steps = .{};
                // Without compiler diagnostics there are no diagnostics steps: errors in the
                // build are not published
                ws.diag_steps = if (ws.config.compiler_diagnostics)
                    try ws.model.?.dependencyClosure(ws.gpa, ws.model.?.diagnostics_steps)
                else
                    try .initEmpty(ws.gpa, ws.model.?.steps.len);
            }
            // Files among the configure inputs are watched like the other known files (interned);
            // the watcher takes the directories among them from `configureInputDirs`
            for (ws.model.?.configure_inputs) |input| if (!input.directory) {
                _ = try ws.server.vfs.intern(input.path);
            };
            if (ws.model.?.configure_inputs.len != 0) ws.server.resyncWatcher();
            try ws.recomputeCompileSet();
            // If the old instance has no model worth keeping, there is no need to wait for the
            // whole build to finish
            ws.promote(.configured);
            ws.endLoading("Done");
            ws.requestBuild();
        },
        .configuration_failed => |*eb| {
            // build.zig itself has errors: publish them as a build result. When build.zig.zon is
            // wrong or fetching a dependency package fails, maker only writes the errors to its
            // stderr and the errors it sends are empty: notify the user
            if (eb.errorMessageCount() == 0) {
                var buf: [512]u8 = undefined;
                ws.server.showWarning(std.fmt.bufPrint(&buf, "zig build cannot load {s} (build.zig.zon or a dependency may have errors), run zig build there to see why", .{ws.root}) catch
                    "zig build cannot load the project (build.zig.zon or a dependency may have errors), run zig build to see why");
            }
            try ws.bundles.append(ws.gpa, eb.*);
            eb.* = .empty;
            // After a restart, an old instance with a build graph stays in effect: without a build
            // graph, named imports would stop resolving and references and rename would miss
            // their importers until the configuration is fixed. The configuration errors replace
            // its compiler diagnostics, as in `zig build`.
            if (ws.server.keepOnConfigurationFailure(ws)) |old| {
                defer old.release();
                try ws.storeResult(old);
            } else try ws.finishBuild();
        },
        .step_started => |step| {
            ws.mutex.lockUncancelable(io);
            defer ws.mutex.unlock(io);
            const name = if (ws.model) |*m| if (step < m.steps.len) m.steps[step].name else null else null;
            ws.server.progress.report(ws.server, ws.build_progress, name, ws.build_done * 100 / @max(ws.build_total, 1));
        },
        .step_completed => |*sc| {
            var roots_changed = false;
            {
                ws.set_mutex.lockUncancelable(io);
                defer ws.set_mutex.unlock(io);
                ws.mutex.lockUncancelable(io);
                defer ws.mutex.unlock(io);
                ws.build_done += 1;
                const in_diag = sc.step < ws.diag_steps.bit_length and ws.diag_steps.isSet(sc.step);
                if (in_diag and sc.status == .failure) {
                    try ws.failed_steps.append(ws.gpa, sc.step);
                    if (sc.errors.errorMessageCount() == 0) try ws.silent_steps.append(ws.gpa, sc.step);
                }
                if (in_diag and sc.errors.errorMessageCount() != 0) {
                    try ws.bundles.append(ws.gpa, sc.errors);
                    sc.errors = .empty;
                }
                if (ws.model) |*m| for (sc.generated) |g| {
                    const path = try configuration.generatedPath(ws.gpa, m, ws.env, g.prefix, g.sub_path);
                    defer ws.gpa.free(path);
                    if (try m.setGeneratedPath(ws.gpa, g.file, path)) roots_changed = true;
                };
            }
            // The path of a generated module root file just became known (or changed): update the
            // compile set without waiting for the whole build to finish, but throttled. The build
            // graph of a large project has over a thousand modules rooted at generated files (e.g.
            // the build_options of each test variant); recomputing for each one would update the
            // module graph over a thousand times, each time republishing diagnostics of open files
            // and recomputing the inference in them.
            if (roots_changed) ws.generated_dirty = true;
            if (ws.generated_dirty) {
                const now = Io.Clock.awake.now(io);
                if (generatedRecomputeDue(ws.generated_recomputed_at, ws.generated_recompute_ns, now)) {
                    ws.generated_dirty = false;
                    try ws.recomputeCompileSet();
                    const end = Io.Clock.awake.now(io);
                    ws.generated_recompute_ns = @intCast(@max(0, now.durationTo(end).nanoseconds));
                    ws.generated_recomputed_at = end;
                }
            }
        },
        .build_completed => {
            ws.mutex.lockUncancelable(io);
            ws.built = true;
            const rebuild = ws.rebuild;
            ws.rebuild = false;
            ws.mutex.unlock(io);
            if (rebuild) {
                // Files were saved again during the build: the result may not match the disk;
                // discard it and rebuild
                ws.clearBundles();
                ws.mutex.lockUncancelable(io);
                defer ws.mutex.unlock(io);
                ws.server.progress.report(ws.server, ws.build_progress, "Files changed, rebuilding", 0);
                if (ws.client) |c| if (ws.model) |*m| {
                    const steps = m.buildSteps(ws.gpa, ws.config.compiler_diagnostics) catch return;
                    defer ws.gpa.free(steps);
                    sendBuild(ws, c, m, steps) catch {};
                };
                return;
            }
            {
                // The local cache directory was deleted or replaced during the build: steps that
                // write into it failed without errors, so the result is not that of the sources.
                // Keep the published diagnostics and restart; the new instance's first build
                // replaces them.
                ws.mutex.lockUncancelable(io);
                const replaced = ws.cacheReplaced();
                if (replaced) {
                    ws.server.progress.end(ws.server, ws.build_progress, "Cache directory deleted, restarting");
                    ws.build_progress = null;
                    ws.building = false;
                    ws.rebuild = false;
                }
                ws.mutex.unlock(io);
                if (replaced) {
                    ws.clearBundles();
                    log.info("{s}: the local cache directory of zig build was deleted or replaced during the build, restarting", .{ws.root});
                    ws.server.restartWorkspace(ws, 0);
                    ws.server.busyEnd();
                    return;
                }
            }
            var errors: u32 = 0;
            for (ws.bundles.items) |eb| errors += eb.errorMessageCount();
            var warning_buf: [768]u8 = undefined;
            var warning: ?[]const u8 = null;
            {
                var buf: [256]u8 = undefined;
                var w: Io.Writer = .fixed(&buf);
                ws.mutex.lockUncancelable(io);
                defer ws.mutex.unlock(io);
                if (errors != 0) w.print("{d} error(s)", .{errors}) catch {};
                // Steps that failed without reporting errors, not because a dependency failed:
                // the build is not clean even when no errors are published. Their output is only
                // on the maker's stderr.
                var hasher: std.hash.Wyhash = .init(0);
                var first: ?[]const u8 = null;
                var count: usize = 0;
                if (ws.model) |*m| for (ws.silent_steps.items) |s| {
                    const dependency_failed = for (m.steps[s].deps) |d| {
                        if (std.mem.indexOfScalar(u32, ws.failed_steps.items, d) != null) break true;
                    } else false;
                    if (dependency_failed) continue;
                    const name = m.steps[s].name;
                    hasher.update(name);
                    hasher.update(&.{0});
                    if (first == null) first = name;
                    count += 1;
                    w.print("{s}{s} failed", .{ if (w.end == 0) "" else "; ", name }) catch {};
                };
                const key = if (count == 0) 0 else hasher.final() | 1;
                if (key != 0 and key != ws.silent_warned) {
                    var more_buf: [32]u8 = undefined;
                    const more = if (count > 1) std.fmt.bufPrint(&more_buf, " (and {d} more)", .{count - 1}) catch "" else "";
                    warning = std.fmt.bufPrint(&warning_buf, "zig build step '{s}'{s} failed without reporting errors in {s}: run `{s}` there to see why", .{ first.?, more, ws.root, buildTitle(&ws.model.?, ws.config.compiler_diagnostics) }) catch
                        "a zig build step failed without reporting errors: run zig build to see why";
                }
                ws.silent_warned = key;
                ws.server.progress.end(ws.server, ws.build_progress, if (w.end == 0) "Done" else w.buffered());
                ws.build_progress = null;
            }
            if (warning) |message| ws.server.showWarning(message);
            try ws.finishBuild();
            ws.generated_dirty = false;
            try ws.recomputeCompileSet();
            ws.mutex.lockUncancelable(io);
            ws.building = false;
            const again = ws.rebuild;
            ws.rebuild = false;
            ws.mutex.unlock(io);
            // More files were saved while the result was being published: `requestBuild` only
            // recorded `rebuild` then, so the next round starts here. Start the new build before
            // ending this round's busy, so a waiter for idle does not return between the rounds.
            if (again) ws.requestBuild();
            ws.server.busyEnd();
        },
        else => {},
    }
}

/// Whether the compile set should be recomputed during a build because of generated files:
/// `last` is when the previous recompute ended, `last_ns` is how long it took
fn generatedRecomputeDue(last: ?Io.Timestamp, last_ns: u64, now: Io.Timestamp) bool {
    const end = last orelse return true;
    const wait = @max(generated_recompute_interval_ms * std.time.ns_per_ms, generated_recompute_cost_factor * last_ns);
    return end.durationTo(now).nanoseconds >= wait;
}

test "generated-file recomputes wait at least a second and in proportion to the last recompute" {
    const end: Io.Timestamp = .{ .nanoseconds = 5 * std.time.ns_per_s };
    const after = struct {
        fn ms(n: i96) Io.Timestamp {
            return .{ .nanoseconds = 5 * std.time.ns_per_s + n * std.time.ns_per_ms };
        }
    }.ms;
    try std.testing.expect(generatedRecomputeDue(null, 0, after(0)));
    // Fast recompute: the minimum interval applies
    try std.testing.expect(!generatedRecomputeDue(end, std.time.ns_per_ms, after(999)));
    try std.testing.expect(generatedRecomputeDue(end, std.time.ns_per_ms, after(1000)));
    // A recompute takes 1.2 seconds: wait 4 times as long, so the task reading build events is
    // not recomputing all the time
    try std.testing.expect(!generatedRecomputeDue(end, 1200 * std.time.ns_per_ms, after(4799)));
    try std.testing.expect(generatedRecomputeDue(end, 1200 * std.time.ns_per_ms, after(4800)));
}

/// The build graph has no compile step (a library that only exports modules): merge in the
/// modules the project exports, so files in the project are assigned to modules through them
fn loadExports(ws: *Workspace, model: *ProjectModel) Allocator.Error!void {
    ws.reportLoading("Reading exported modules");
    var exported = try exports.load(ws.gpa, ws.server.io, ws.env, ws.root, ws.config.build_args) orelse return;
    defer exported.deinit(ws.gpa);
    try model.appendExports(ws.gpa, &exported);
}

/// Generates builtin.zig for each distinct argument list of the model
fn generateBuiltins(ws: *Workspace, model: *ProjectModel) Allocator.Error!void {
    const env = ws.env;
    const io = ws.server.io;
    ws.reportLoading("Generating builtin.zig");
    // Generated in parallel (each launches the compiler once, unless the argument record has a hit)
    const paths = try ws.gpa.alloc(?[]u8, model.builtins.len);
    defer {
        for (paths) |p| if (p) |x| ws.gpa.free(x);
        ws.gpa.free(paths);
    }
    @memset(paths, null);
    var failed: std.atomic.Value(bool) = .init(false);
    var group: Io.Group = .init;
    for (model.builtins, paths) |b, *out| group.async(io, generateOne, .{ ws.gpa, io, env, b.args, out, &failed });
    group.await(io) catch {};
    if (failed.load(.acquire)) return error.OutOfMemory;
    for (paths, 0..) |p, i| if (p) |path| try model.setBuiltinFile(ws.gpa, @intCast(i), path);
}

fn generateOne(gpa: Allocator, io: Io, env: *const ZigEnv, args: []const []const u8, out: *?[]u8, failed: *std.atomic.Value(bool)) Io.Cancelable!void {
    out.* = builtin.generate(gpa, io, env, args) catch |err| switch (err) {
        error.OutOfMemory => blk: {
            failed.store(true, .release);
            break :blk null;
        },
        error.Canceled => return error.Canceled,
    };
}

fn reportLoading(ws: *Workspace, message: ?[]const u8) void {
    ws.mutex.lockUncancelable(ws.server.io);
    defer ws.mutex.unlock(ws.server.io);
    ws.server.progress.report(ws.server, ws.loading, message, null);
}

fn endLoading(ws: *Workspace, message: ?[]const u8) void {
    ws.mutex.lockUncancelable(ws.server.io);
    defer ws.mutex.unlock(ws.server.io);
    ws.server.progress.end(ws.server, ws.loading, message);
    ws.loading = null;
}

/// Discards what this round collected: error bundles and failed steps
fn clearBundles(ws: *Workspace) void {
    for (ws.bundles.items) |*eb| eb.deinit(ws.gpa);
    ws.bundles.clearRetainingCapacity();
    ws.failed_steps.clearRetainingCapacity();
    ws.silent_steps.clearRetainingCapacity();
}

/// Converts the errors collected in this round into diagnostics, replaces the previous round's
/// result, and republishes the affected files
fn finishBuild(ws: *Workspace) Allocator.Error!void {
    try ws.storeResult(ws);
}

/// Converts the errors collected in this round into diagnostics, replaces the result of `target`
/// (this instance, or the old instance that stays in effect, see `Server.keepOnConfigurationFailure`)
/// with them, and republishes the files that had or now have diagnostics
fn storeResult(ws: *Workspace, target: *Workspace) Allocator.Error!void {
    defer ws.clearBundles();
    const build_zig = try std.fs.path.join(ws.gpa, &.{ ws.root, "build.zig" });
    defer ws.gpa.free(build_zig);
    const result = try compiler.collect(ws.gpa, ws.bundles.items, ws.root, build_zig, ws, readDisk);
    errdefer result.release(ws.gpa);

    var files: std.AutoArrayHashMapUnmanaged(FileId, *const compiler.FileResult) = .empty;
    errdefer files.deinit(ws.gpa);
    for (result.files.keys(), result.files.values()) |path, *fr| {
        try files.put(ws.gpa, try ws.server.vfs.intern(path), fr);
    }

    // Affected files: files with compiler diagnostics in the previous round or this one
    var affected: std.ArrayList(FileId) = .empty;
    defer affected.deinit(ws.gpa);
    {
        const io = ws.server.io;
        target.mutex.lockUncancelable(io);
        defer target.mutex.unlock(io);
        try affected.appendSlice(ws.gpa, target.result_files.keys());
        try affected.appendSlice(ws.gpa, files.keys());
        if (target.result) |old| old.release(ws.gpa);
        target.result_files.deinit(ws.gpa);
        target.result = result;
        target.result_generation = ws.server.nextCompileGeneration();
        target.result_at_ms = @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
        target.result_files = files;
    }
    // For a new instance created by a restart, the first result replaces the old instance along
    // with the model and the compile set
    if (target == ws) ws.promote(.built);
    ws.server.publishFiles(affected.items, true);
}

/// A new instance created by a restart has reached `stage`: replaces the old instance (see
/// `Server.promote`), updates the module graph, republishes open files and the files the old
/// instance published compiler diagnostics for, and lets single-file mode converge to the new
/// module graph
fn promote(ws: *Workspace, stage: Server.PromoteStage) void {
    const old = ws.server.promote(ws, stage) orelse return;
    defer old.release();
    ws.server.updateModuleGraph();
    ws.server.publishOpenFiles();
    old.mutex.lockUncancelable(ws.server.io);
    const stale = ws.gpa.dupe(FileId, old.result_files.keys()) catch &.{};
    old.mutex.unlock(ws.server.io);
    defer ws.gpa.free(stale);
    ws.server.publishFiles(stale, true);
    ws.server.reconcileSingle();
}

/// Result of the most recent build: when it was stored (Unix milliseconds), the number of files
/// with compiler diagnostics, and the number of diagnostics
pub const LastBuild = struct { at_ms: i64, files: usize, diagnostics: usize };

/// null when there is no result yet
pub fn lastBuild(ws: *Workspace) ?LastBuild {
    ws.mutex.lockUncancelable(ws.server.io);
    defer ws.mutex.unlock(ws.server.io);
    const r = ws.result orelse return null;
    var diagnostics: usize = 0;
    for (r.files.values()) |fr| diagnostics += fr.items.len;
    return .{ .at_ms = ws.result_at_ms, .files = r.files.count(), .diagnostics = diagnostics };
}

/// Clears compiler diagnostics and republishes the files that had diagnostics published
pub fn clearResult(ws: *Workspace) void {
    ws.mutex.lockUncancelable(ws.server.io);
    const stale = ws.gpa.dupe(FileId, ws.result_files.keys()) catch &.{};
    if (ws.result) |r| r.release(ws.gpa);
    ws.result = null;
    ws.result_files.clearRetainingCapacity();
    ws.mutex.unlock(ws.server.io);
    defer ws.gpa.free(stale);
    ws.server.publishFiles(stale, true);
}

fn readDisk(ctx: *anyopaque, gpa: Allocator, path: []const u8) ?[]u8 {
    const ws: *Workspace = @ptrCast(@alignCast(ctx));
    return Io.Dir.cwd().readFileAlloc(ws.server.io, path, gpa, .limited(Vfs.max_file_size)) catch null;
}

// ── Compile set and file loading ──────────────────────────────────────

const Resolver = struct {
    ws: *Workspace,
    ctx: *database.Db.Ctx,
    /// Records the hash of the imports read for each file (see `importsHash`)
    read: ?*std.AutoHashMapUnmanaged(FileId, u64) = null,

    pub fn intern(r: Resolver, file_path: []const u8) !FileId {
        return r.ws.server.vfs.intern(file_path);
    }

    pub fn path(r: Resolver, file: FileId) []const u8 {
        return r.ws.server.vfs.path(file);
    }

    pub fn imports(r: Resolver, file: FileId) !?[]const []const u8 {
        const text = try r.ctx.get(FileText, file);
        const list = if (text != null)
            try syntaxImports(r.ws.server, r.ctx, file)
        else if (r.ws.loaded.contains(file))
            &.{}
        else
            return null;
        if (r.read) |read| try read.put(r.ws.gpa, file, importsHash(list));
        return list;
    }
};

fn importsHash(list: []const []const u8) u64 {
    var h: std.hash.Wyhash = .init(0);
    for (list) |s| {
        h.update(std.mem.asBytes(&s.len));
        h.update(s);
    }
    return h.final();
}

/// The `@import` strings of a file in its syntax tree. The compiler follows the imports recorded in
/// ZIR, but a file with a parse error or a duplicate member name has no ZIR: while such a file is
/// being edited, the files imported through it still belong to the same modules in every build
/// that compiles, so the syntax tree, which keeps the imports of a broken file, is used instead.
/// ZON files import nothing.
fn syntaxImports(server: *Server, ctx: *database.Db.Ctx, file: FileId) za.db.Error![]const []const u8 {
    if (database.live.modeOf(server.vfs.path(file)) == .zon) return &.{};
    return (try ctx.get(FileIndex.Query, file)).imports;
}

/// Computes the compile set; on encountering files that are not loaded, loads them from disk and
/// recomputes, until nothing is missing
pub fn recomputeCompileSet(ws: *Workspace) Allocator.Error!void {
    ws.set_mutex.lockUncancelable(ws.server.io);
    defer ws.set_mutex.unlock(ws.server.io);
    try ws.recomputeLocked();
}

/// Recomputes the compile set when the imports of one of `files` (whose text has changed) differ
/// from those the latest computation read: the compile set and the module membership follow
/// imports added and removed by edits without waiting for a build, which with compiler
/// diagnostics off never runs. Files the computation did not read cannot change the result.
pub fn refreshImports(ws: *Workspace, files: []const FileId) Allocator.Error!void {
    const io = ws.server.io;
    ws.set_mutex.lockUncancelable(io);
    defer ws.set_mutex.unlock(io);
    {
        ws.mutex.lockUncancelable(io);
        defer ws.mutex.unlock(io);
        if (ws.stopping or ws.model == null or ws.compile_set == null) return;
    }
    for (files) |f| {
        if (ws.read_imports.contains(f)) break;
    } else return;
    const changed = while (true) {
        var arena: std.heap.ArenaAllocator = .init(ws.gpa);
        defer arena.deinit();
        var ctx = ws.server.db.beginRead(arena.allocator());
        defer ctx.end();
        break ws.importsChanged(&ctx, files) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Interrupted by an edit: retry
            error.Canceled => continue,
        };
    };
    if (changed) try ws.recomputeLocked();
}

fn importsChanged(ws: *Workspace, ctx: *database.Db.Ctx, files: []const FileId) za.db.Error!bool {
    for (files) |f| {
        const read = ws.read_imports.get(f) orelse continue;
        const list = if (try ctx.get(FileText, f) != null) try syntaxImports(ws.server, ctx, f) else &.{};
        if (read != importsHash(list)) return true;
    }
    return false;
}

/// `recomputeCompileSet` with `set_mutex` held
fn recomputeLocked(ws: *Workspace) Allocator.Error!void {
    const io = ws.server.io;
    var steps: []u32 = &.{};
    defer ws.gpa.free(steps);
    var all: std.ArrayList(u32) = .empty;
    defer all.deinit(ws.gpa);
    {
        ws.mutex.lockUncancelable(io);
        defer ws.mutex.unlock(io);
        const model = &(ws.model orelse return);
        steps = try model.compileStepsOf(ws.gpa, model.diagnostics_steps);
        for (model.steps, 0..) |st, i| if (st.kind == .compile) try all.append(ws.gpa, @intCast(i));
        // The diagnostics steps compile nothing (e.g. a library with only addModule and addTest,
        // whose default install is empty): use all compile steps of the build graph instead,
        // otherwise the compile set is empty and no file in the project gets live diagnostics
        if (steps.len == 0) {
            ws.gpa.free(steps);
            steps = try ws.gpa.dupe(u32, all.items);
        }
        // A file belongs to the compile step that reaches it first: native-target steps come first,
        // so files compiled for multiple targets (e.g. code compiled both as a wasm library and as
        // a native example) are analyzed for the native target
        const Native = struct {
            fn lt(m: *const ProjectModel, a: u32, b: u32) bool {
                return m.isNativeStep(a) and !m.isNativeStep(b);
            }
        };
        std.mem.sort(u32, steps, model, Native.lt);
        std.mem.sort(u32, all.items, model, Native.lt);
    }

    var read: std.AutoHashMapUnmanaged(FileId, ?u64) = .empty;
    defer read.deinit(ws.gpa);
    var result = try ws.computeSet(steps, &read) orelse return;
    errdefer result.deinit(ws.gpa);
    // Files reachable from the other compile steps (tests, examples, etc.): used only to determine
    // which modules files belong to and to resolve imports; no live diagnostics are published
    const extra: ?CompileSet.Result = if (all.items.len > steps.len) try ws.computeSet(all.items, &read) else null;
    std.mem.swap(std.AutoHashMapUnmanaged(FileId, ?u64), &ws.read_imports, &read);
    ws.mutex.lockUncancelable(io);
    if (ws.compile_set) |*old| old.deinit(ws.gpa);
    ws.compile_set = result;
    if (ws.resolve_set) |*old| old.deinit(ws.gpa);
    ws.resolve_set = extra;
    ws.mutex.unlock(io);
    // A change of the compile set affects which modules files belong to, live diagnostics of open
    // files, and whether files are compiled in single-file mode. A new instance that has not
    // replaced the old one yet has no effect (everything is updated when it replaces it).
    if (!ws.server.isVisible(ws)) return;
    ws.server.updateModuleGraph();
    ws.server.publishOpenFiles();
    ws.server.reconcileSingle();
}

/// Computes the build scripts; missing files are read in and the computation repeated
fn computeBuildScripts(ws: *Workspace) Allocator.Error!void {
    ws.set_mutex.lockUncancelable(ws.server.io);
    defer ws.set_mutex.unlock(ws.server.io);
    var rounds: usize = 0;
    while (rounds < 256) : (rounds += 1) {
        var arena: std.heap.ArenaAllocator = .init(ws.gpa);
        defer arena.deinit();
        var result = blk: {
            var ctx = ws.server.db.beginRead(arena.allocator());
            defer ctx.end();
            break :blk CompileSet.buildScripts(ws.gpa, ws.root, Resolver{ .ws = ws, .ctx = &ctx }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // Interrupted by an edit: retry
                error.Canceled => continue,
            };
        };
        if (result.missing.count() == 0) {
            result.missing.deinit(ws.gpa);
            ws.mutex.lockUncancelable(ws.server.io);
            defer ws.mutex.unlock(ws.server.io);
            ws.build_scripts.deinit(ws.gpa);
            ws.build_scripts = result.files;
            return;
        }
        defer result.deinit(ws.gpa);
        try ws.loadFiles(result.missing.keys());
    }
    log.warn("{s}: build script computation did not converge", .{ws.root});
}

/// Files reachable through imports from the root modules of these compile steps; missing files
/// are read in and the computation repeated. Returns null when it does not converge. The hashes of
/// the imports read in the final round are added to `read`, with null for a file whose imports
/// differ from those an earlier computation added (the file changed in between).
fn computeSet(ws: *Workspace, steps: []const u32, read: *std.AutoHashMapUnmanaged(FileId, ?u64)) Allocator.Error!?CompileSet.Result {
    const io = ws.server.io;
    var round_read: std.AutoHashMapUnmanaged(FileId, u64) = .empty;
    defer round_read.deinit(ws.gpa);
    var rounds: usize = 0;
    while (rounds < 256) : (rounds += 1) {
        var arena: std.heap.ArenaAllocator = .init(ws.gpa);
        defer arena.deinit();
        round_read.clearRetainingCapacity();
        var result = blk: {
            var ctx = ws.server.db.beginRead(arena.allocator());
            defer ctx.end();
            ws.mutex.lockUncancelable(io);
            // model is replaced or changed only with set_mutex held, which the caller holds, so its
            // pointer is safe to use outside the lock
            const model = &ws.model.?;
            ws.mutex.unlock(io);
            break :blk CompileSet.compute(ws.gpa, model, steps, Resolver{ .ws = ws, .ctx = &ctx, .read = &round_read }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // Interrupted by an edit: retry
                error.Canceled => continue,
            };
        };
        if (result.missing.count() == 0) {
            errdefer result.deinit(ws.gpa);
            var it = round_read.iterator();
            while (it.next()) |e| {
                const gop = try read.getOrPut(ws.gpa, e.key_ptr.*);
                gop.value_ptr.* = if (gop.found_existing and gop.value_ptr.* != e.value_ptr.*) null else e.value_ptr.*;
            }
            return result;
        }
        defer result.deinit(ws.gpa);
        var buf: [64]u8 = undefined;
        ws.reportLoading(std.fmt.bufPrint(&buf, "Analyzing compile set ({d} files)", .{result.files.count()}) catch null);
        try ws.loadFiles(result.missing.keys());
    }
    log.warn("{s}: compile set computation did not converge", .{ws.root});
    return null;
}

fn loadFiles(ws: *Workspace, files: []const FileId) Allocator.Error!void {
    const Loaded = struct { file: FileId, text: ?[]u8, durability: database.Durability };
    var batch: std.ArrayList(Loaded) = .empty;
    defer batch.deinit(ws.gpa);
    var arena: std.heap.ArenaAllocator = .init(ws.gpa);
    defer arena.deinit();
    const rules = try ws.server.originRules(arena.allocator());
    for (files) |file| {
        try ws.loaded.put(ws.gpa, file, {});
        const path = ws.server.vfs.path(file);
        const text = ws.server.vfs.readFromDisk(file, ws.gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        try batch.append(ws.gpa, .{ .file = file, .text = text, .durability = origin.classify(&ws.server.vfs, rules, path, false).durability() });
    }
    const db = &ws.server.db;
    db.beginWrite();
    defer db.endWrite();
    for (batch.items) |l| {
        // Files the client opened in the meantime: their buffers take precedence
        if (db.peek(FileText, l.file) != null) {
            if (l.text) |t| ws.gpa.free(t);
            continue;
        }
        try db.set(FileText, l.file, l.text, l.durability);
    }
}
