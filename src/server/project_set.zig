//! The projects of the workspace: startup, the zig toolchain, workspace roots and sub-projects, the
//! compile context of files, and the lifecycle of `Workspace` instances.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const za = @import("../zig_analyzer.zig");
const types = za.lsp.types;
const transport = za.lsp.transport;
const uri = za.base.uri;
const Vfs = za.base.Vfs;
const database = @import("../database.zig");
const Db = database.Db;
const live = database.live;
const ide = za.ide;
const ZigEnv = za.project.ZigEnv;
const Workspace = @import("Workspace.zig");
const Config = @import("../Config.zig");
const watch = @import("watch.zig");
const origin = @import("origin.zig");

const Server = @import("Server.zig");
const config_sync = @import("config_sync.zig");
const file_changes = @import("file_changes.zig");
const indexing = @import("indexing.zig");
const publishing = @import("publishing.zig");
const Pending = Server.Pending;
const SubProjectWait = Server.SubProjectWait;
const Toolchain = Server.Toolchain;

const log = std.log.scoped(.server);

/// Starts the projects of the sub-projects recorded in `wait` (see `subProjectGap`) and waits until
/// none of them is loading, or until `pending` is canceled or the server shuts down. The request
/// then runs again with `wait.awaited` set.
pub fn loadSubProjects(server: *Server, pending: *const Pending, wait: *SubProjectWait) void {
    wait.awaited = true;
    for (wait.dirs.items) |dir| {
        log.info("{s}: loading the sub-project, whose files may refer to the symbol", .{dir});
        startWorkspace(server, dir);
    }
    server.project_wait_mutex.lockUncancelable(server.io);
    defer server.project_wait_mutex.unlock(server.io);
    while (!pending.cancel.load(.acquire) and !server.isShuttingDown()) {
        const loading = for (wait.dirs.items) |dir| {
            if (server.subProjectState(dir) == .loading) break true;
        } else false;
        if (!loading) return;
        server.project_wait_cond.wait(server.io, &server.project_wait_mutex) catch return;
    }
}

/// Stops all projects and clears the compiler diagnostics they published; the module graph is
/// updated accordingly
pub fn stopProjects(server: *Server) void {
    // Take them out of the list (together with the references the list holds)
    const list = blk: {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        const list = server.gpa.dupe(*Workspace, server.workspaces.items) catch return;
        server.workspaces.clearRetainingCapacity();
        break :blk list;
    };
    defer releaseList(server, server.gpa, list);
    var stale: std.ArrayList(Vfs.FileId) = .empty;
    defer stale.deinit(server.gpa);
    for (list) |ws| {
        stopProject(server, ws);
        ws.mutex.lockUncancelable(server.io);
        stale.appendSlice(server.gpa, ws.result_files.keys()) catch {};
        ws.mutex.unlock(server.io);
    }
    indexing.updateModuleGraph(server);
    publishing.publishFiles(server, stale.items, true);
    publishing.publishOpenFiles(server);
    // Open files are compiled in single-file mode instead
    server.single.reconcile();
}

/// Starts projects for the root directories that have a build.zig (rechecked on disk: build.zig
/// may have been created or deleted after the root directory was added)
pub fn startProjectsForRoots(server: *Server) void {
    var roots: std.ArrayList([]u8) = .empty;
    defer {
        for (roots.items) |r| server.gpa.free(r);
        roots.deinit(server.gpa);
    }
    {
        server.roots_mutex.lockUncancelable(server.io);
        defer server.roots_mutex.unlock(server.io);
        for (server.roots.items) |root| {
            const copy = server.gpa.dupe(u8, root) catch return;
            roots.append(server.gpa, copy) catch {
                server.gpa.free(copy);
                return;
            };
        }
    }
    for (roots.items) |root| {
        const has_build = hasBuildZig(server, root) catch return;
        _ = setRootHasBuild(server, root, has_build);
        if (has_build) startWorkspace(server, root);
    }
    startOpenSubProjects(server);
}

/// Directory `dir` contains a file named build.zig. The name must match exactly: on
/// case-insensitive file systems (the default on macOS and Windows), accessing build.zig by path
/// also succeeds for Build.zig, so the standard library directory (which has `std/Build.zig`)
/// would be treated as a project, and `zig build` would then use Build.zig as the build script,
/// with the errors of the failed compile landing in standard library files.
fn hasBuildZig(server: *Server, dir: []const u8) Allocator.Error!bool {
    const path = try std.fs.path.join(server.gpa, &.{ dir, "build.zig" });
    defer server.gpa.free(path);
    Io.Dir.cwd().access(server.io, path, .{}) catch return false;
    var d = Io.Dir.cwd().openDir(server.io, dir, .{ .iterate = true }) catch return false;
    defer d.close(server.io);
    var it = d.iterate();
    while (it.next(server.io) catch return false) |entry| {
        if (std.mem.eql(u8, entry.name, "build.zig")) return true;
    }
    return false;
}

/// The root directory that is `dir` (see `Vfs.samePath`), spelled as it was added (allocated by
/// `gpa`); null when `dir` is not a root directory
fn rootSpelling(server: *Server, dir: []const u8) Allocator.Error!?[]u8 {
    server.roots_mutex.lockUncancelable(server.io);
    defer server.roots_mutex.unlock(server.io);
    for (server.roots.items) |r| if (server.vfs.samePath(r, dir)) return try server.gpa.dupe(u8, r);
    return null;
}

/// Records whether root directory `root` has a build.zig; returns whether the record changed
/// (false when `root` is not a root directory)
fn setRootHasBuild(server: *Server, root: []const u8, has_build: bool) bool {
    server.roots_mutex.lockUncancelable(server.io);
    defer server.roots_mutex.unlock(server.io);
    for (server.roots.items, server.root_has_build.items) |r, *flag| if (server.vfs.samePath(r, root)) {
        if (flag.* == has_build) return false;
        flag.* = has_build;
        return true;
    };
    return false;
}

/// The build.zig in directory `dir` may have been created or deleted: rechecks it on disk. When
/// `dir` is a root directory and something changed, starts the project if build.zig appeared;
/// if it disappeared, stops the project, and its files no longer belong to a project (they
/// become standalone files, or belong to an unloaded project when an ancestor directory still
/// has a build.zig). Returns whether anything changed.
pub fn refreshRoot(server: *Server, dir: []const u8) Allocator.Error!bool {
    // `dir` may be spelled differently from the root directory (see `Vfs.samePath`): the project
    // uses the root directory's spelling
    const root = try rootSpelling(server, dir) orelse return false;
    defer server.gpa.free(root);
    const has_build = try hasBuildZig(server, root);
    if (!setRootHasBuild(server, root, has_build)) return false;
    if (has_build) {
        log.info("{s}: build.zig was created", .{root});
        if (zigEnv(server) != null) startWorkspace(server, root);
    } else {
        log.info("{s}: build.zig was deleted", .{root});
        removeProject(server, root);
        // Its sub-projects go with it
        _ = stopStrayProjects(server);
        indexing.updateModuleGraph(server);
    }
    // Open files: single-file mode results no longer apply, or they switch to single-file mode
    publishing.publishOpenFiles(server);
    server.single.reconcile();
    return true;
}

pub fn startProjects(server: *Server) void {
    server.started = true;
    server.busyBegin();
    server.bg_group.concurrent(server.io, startup, .{server}) catch |err| {
        endStartup(server);
        server.busyEnd();
        log.err("failed to start project loading task: {t}", .{err});
    };
    // Created on the main loop so that later wakeups and stops are not
    // lost. Runs until the server shuts down and does not count as busy;
    // must not fall back to running synchronously on the main loop.
    const w = watch.Watcher.create(server) catch return log.err("out of memory while starting to watch files on disk", .{});
    server.watcher = w;
    server.vfs.listener.store(&w.listener, .release);
    server.bg_group.concurrent(server.io, watch.Watcher.run, .{w}) catch |err| {
        log.warn("failed to start watching files on disk: {t}", .{err});
        server.vfs.listener.store(null, .release);
        server.watcher = null;
        w.destroy();
    };
}

/// Message shown when the user's zig is a version whose build graphs cannot be read
/// (arguments: the user's version, the build-time version, the build-time version, the user's
/// version). The build graph file has no version number and is read byte for byte into structs, so
/// a mismatched format causes out-of-bounds reads; projects with build.zig are therefore not loaded
/// (see `startWorkspace`): besides compiler diagnostics, imports of named modules cannot be
/// resolved either, which affects goto, hover and completion.
const version_mismatch_message = "zig {s} differs from zig {s} that zig-analyzer was built with. " ++
    "Projects with build.zig are not loaded: they get no compiler diagnostics, and imports of named modules " ++
    "(dependencies, build options) are not resolved. Live diagnostics use zig ast-check. " ++
    "Use zig {s}, or a zig-analyzer built for zig {s}.";

/// Queries the zig environment and starts the build
/// system protocol for each workspace with a build.zig
fn startup(server: *Server) Io.Cancelable!void {
    defer server.busyEnd();
    defer endStartup(server);
    // The origin rules (the Zig installation and the global cache) are known from here on, also
    // when the zig environment cannot be queried
    defer indexing.scheduleScan(server);
    const config = server.config.load(.acquire);
    const queried = ZigEnv.query(server.gpa, server.io, config.zig_path) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        // `zig build test` deliberately cannot find zig (see `ZigEnv.query`)
        if (@import("builtin").is_test and !@import("build_options").zig_tests) return;
        const message = std.fmt.allocPrint(server.gpa, "cannot run {s} env ({t}): the standard library, named modules, and compiler diagnostics are unavailable; set zig.path to the zig executable", .{ config.zig_path orelse "zig", err }) catch null;
        defer if (message) |m| server.gpa.free(m);
        server.showWarning(message orelse "cannot run zig env: the standard library, named modules, and compiler diagnostics are unavailable; set zig.path to the zig executable");
        return;
    };
    const detected = ownEnv(server, queried) catch return log.err("out of memory while storing the zig environment", .{});
    {
        server.env_mutex.lockUncancelable(server.io);
        defer server.env_mutex.unlock(server.io);
        // An environment already exists (should not happen: `initialized` is handled only once):
        // keep the old value
        if (server.detected_env != null) return;
        server.detected_env = detected;
    }
    log.info("zig {s} ({s})", .{ detected.version, detected.zig_exe });
    _ = try applyZigPaths(server);
    const env = zigEnv(server) orelse return;
    const dialect: za.syntax.Parse.Dialect = .of(env.version);
    if (dialect != za.syntax.Parse.Dialect.latest) {
        server.db.beginWriteOf(comptime Db.inputSet(&.{database.syntax.SyntaxDialect}), .unordered);
        defer server.db.endWrite();
        server.db.set(database.syntax.SyntaxDialect, {}, dialect, .high) catch {};
    }
    const renderer: ide.format.Renderer = .of(env.version);
    if (renderer != ide.format.Renderer.built) {
        server.db.beginWriteOf(comptime Db.inputSet(&.{ide.format.ZigFmtRenderer}), .unordered);
        defer server.db.endWrite();
        server.db.set(ide.format.ZigFmtRenderer, {}, renderer, .high) catch {};
    }
    if (!env.matchesBuiltin()) {
        // The in-process AstGen may not match the user's zig: live diagnostics use the user's
        // zig ast-check instead
        if (!env.readsBuildGraph()) {
            const built = @import("builtin").zig_version_string;
            const message = std.fmt.allocPrint(server.gpa, version_mismatch_message, .{ env.version, built, built, env.version }) catch null;
            defer if (message) |m| server.gpa.free(m);
            server.showWarningOnce(message orelse "zig version differs from the one zig-analyzer was built with");
        }
        const exe = server.gpa.dupe(u8, env.zig_exe) catch return;
        server.db.beginWriteOf(comptime Db.inputSet(&.{live.LiveBackend}), .unordered);
        defer server.db.endWrite();
        server.db.set(live.LiveBackend, {}, .{ .subprocess = exe }, .high) catch {};
    }
    indexing.updateModuleGraph(server);
    if (config_sync.buildFlags(server).build) startProjectsForRoots(server);
    // Detached files opened before startup: compile them now that the zig environment is ready and
    // projects have started loading
    server.startup_done.store(true, .release);
    // The origins of files opened before startup (the standard library, files outside the
    // workspace folders) are known only now, and naming hints depend on them; their live
    // diagnostics may also have switched to the configured zig's `zig ast-check`
    publishing.publishOpenFiles(server);
    server.single.reconcile();
}

/// Takes ownership of `env` and returns the server's copy of it (freed only in deinit)
pub fn ownEnv(server: *Server, env: ZigEnv) Allocator.Error!*const ZigEnv {
    var owned = env;
    errdefer owned.deinit(server.gpa);
    const ptr = try server.gpa.create(ZigEnv);
    errdefer server.gpa.destroy(ptr);
    server.env_mutex.lockUncancelable(server.io);
    defer server.env_mutex.unlock(server.io);
    try server.envs.append(server.gpa, ptr);
    ptr.* = owned;
    return ptr;
}

/// What `applyZigPaths` changed
const ZigPathsChange = struct {
    /// The effective zig environment (lib, standard library, and global cache directories)
    env: bool = false,
    /// The default builtin.zig
    builtin: bool = false,
};

/// Applies the path overrides from the configuration (`zig.lib_path`, `zig.global_cache_path`,
/// `zig.builtin_path`) to the detected environment, producing the effective zig environment and
/// the default builtin.zig (used by files outside any project; modules in projects use the one
/// generated from the build arguments). Overrides that cannot be used are reported to the user,
/// falling back to the detected values. Does nothing before the environment is detected: the
/// startup phase calls it after detection.
fn applyZigPaths(server: *Server) Io.Cancelable!ZigPathsChange {
    const gpa = server.gpa;
    const io = server.io;
    server.zig_paths_mutex.lockUncancelable(io);
    defer server.zig_paths_mutex.unlock(io);
    const detected = blk: {
        server.env_mutex.lockUncancelable(io);
        defer server.env_mutex.unlock(io);
        break :blk server.detected_env orelse return .{};
    };
    // Toolchains are set only here, under `zig_paths_mutex`: this is still the current one when
    // the new one is set
    const old = server.toolchain.load(.acquire);
    const current = old.env;
    const config = server.config.load(.acquire);
    var buf: [2048]u8 = undefined;
    var notes: std.Io.Writer = .fixed(&buf);

    const base = current orelse detected;
    var rejected: ZigEnv.Rejected = .{};
    const env: *const ZigEnv = env: {
        const fresh = detected.withOverrides(gpa, io, server.environ, .{
            .lib_dir = config.zig_lib_path,
            .global_cache_dir = config.zig_global_cache_path,
        }, &rejected) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory, error.Unexpected => {
                log.err("failed to apply the zig path settings: {t}", .{err});
                break :env base;
            },
        };
        if (fresh.samePaths(base)) {
            var unused = fresh;
            unused.deinit(gpa);
            break :env base;
        }
        break :env ownEnv(server, fresh) catch {
            log.err("out of memory while applying the zig path settings", .{});
            break :env base;
        };
    };
    if (rejected.lib_dir) appendNote(&notes, "zig.lib_path {s} does not contain std/std.zig, using {s}", .{ config.zig_lib_path.?, detected.lib_dir });
    if (rejected.global_cache_dir) appendNote(&notes, "zig.global_cache_path {s} is not an existing directory, using {s}", .{ config.zig_global_cache_path.?, detected.global_cache_dir });

    const default_builtin: ?[]u8 = blk: {
        if (config.zig_builtin_path) |path| {
            const file = ZigEnv.resolveFile(gpa, io, path) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => null,
            };
            if (file) |f| break :blk f;
            appendNote(&notes, "zig.builtin_path {s} is not an existing file, using the generated builtin.zig", .{path});
        }
        // Generated with the settings of the single-file compile (`zig build-obj`, see
        // `SingleFiles.compile`), whose diagnostics these files get
        break :blk za.project.builtin.generate(gpa, io, env, &.{"build-obj"}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => null,
        };
    };

    const source_tree = if (std.fs.path.dirname(env.lib_dir)) |parent| hasBuildZig(server, parent) catch false else false;
    const change: ZigPathsChange = .{
        .env = old.env != env,
        .builtin = !config_sync.eqlOptionalStr(old.default_builtin, default_builtin),
    };
    if (change.env or change.builtin or old.source_tree != source_tree) {
        setToolchain(server, .{ .env = env, .source_tree = source_tree, .default_builtin = default_builtin }) catch {
            log.err("out of memory while applying the zig path settings", .{});
            return .{};
        };
    } else if (default_builtin) |p| gpa.free(p);
    if (notes.end != 0) server.showWarning(notes.buffered());
    return change;
}

/// Makes `toolchain` current, taking ownership of its `default_builtin` (allocated with `gpa`,
/// freed also on error). Only `applyZigPaths` and tests set toolchains.
pub fn setToolchain(server: *Server, toolchain: Toolchain) Allocator.Error!void {
    errdefer if (toolchain.default_builtin) |p| server.gpa.free(p);
    const ptr = try server.gpa.create(Toolchain);
    errdefer server.gpa.destroy(ptr);
    ptr.* = toolchain;
    {
        server.env_mutex.lockUncancelable(server.io);
        defer server.env_mutex.unlock(server.io);
        try server.toolchains.append(server.gpa, ptr);
    }
    server.toolchain.store(ptr, .release);
    server.zig_environ.store(if (toolchain.env) |env| env.childEnviron() else null, .release);
}

/// Appends a note about a configuration problem to `w`; the notes are merged into a single
/// message (as in `reportConfigWarnings`)
fn appendNote(w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) void {
    w.writeAll(if (w.end == 0) "zig-analyzer settings: " else "; ") catch {};
    w.print(fmt, args) catch {};
}

/// Reapplies the zig path overrides after they change in the configuration: the standard library
/// and the default builtin.zig are reloaded with the module graph; when the effective environment
/// changes, projects are restarted and detached files are recompiled, all running zig with the
/// new paths
pub fn reloadZigPathsTask(server: *Server) Io.Cancelable!void {
    defer server.busyEnd();
    const change = try applyZigPaths(server);
    if (!change.env and !change.builtin) return;
    log.info("zig paths changed, reloading the standard library and builtin.zig", .{});
    indexing.updateModuleGraph(server);
    if (change.env) {
        const list = workspaceList(server, server.gpa) catch return;
        defer releaseList(server, server.gpa, list);
        if (list.len != 0) log.info("zig paths changed, restarting projects", .{});
        for (list) |ws| restartWorkspace(server, ws, 0);
        var roots: std.ArrayList(Vfs.FileId) = .empty;
        defer roots.deinit(server.gpa);
        {
            server.single.mutex.lockUncancelable(server.io);
            defer server.single.mutex.unlock(server.io);
            roots.appendSlice(server.gpa, server.single.entries.keys()) catch {};
        }
        server.single.recompile(roots.items, &.{});
        // Files in the standard library and the global cache are not watched (see `watchable`):
        // the set changes with the effective directories
        file_changes.resyncWatcher(server);
    }
    // The origins of files (the standard library, dependency packages in the global cache) and
    // inference results may change
    publishing.publishOpenFiles(server);
    server.single.reconcile();
}

/// Compile context of a file: decides whether it can be compiled as a root in single-file mode, and
/// whether single-file compile results are used for its diagnostics. Checked in order: dependency
/// library, a project's module graph, a root directory with build.zig, an unloaded project in an
/// ancestor directory, the Zig lib directory in use; only a .zig file that is none of these is a
/// detached file.
pub const FileContext = enum {
    /// Not compiled: virtual documents, and non-.zig files that belong to no project
    none,
    /// A file in a dependency library (see `origin.Origin.isLibrary`), or in the Zig lib directory
    /// in use outside the projects (see `inZigLib`): compiled only as a dependency, never as a root.
    /// Errors reported in it by the real compile entry points are published as usual.
    library,
    /// In some project's module graph (the compile set, or reachable from the other compile steps):
    /// compiler diagnostics come from the project's build
    project,
    /// A file under a root directory with build.zig that is not in the module graph: handled by the
    /// project, not compiled on its own
    project_dir,
    /// A .zig file with a build.zig in an ancestor directory whose project is not loaded (e.g. a
    /// file in another project outside the workspace): only that project's build can resolve its
    /// imports by name, so it is not compiled on its own; when it is open, a hint suggests adding
    /// the project to the workspace (see `appendUnloadedProjectHint`)
    unloaded_project,
    /// A detached .zig file: compiled on its own as a root
    detached,

    /// Whether single-file compile results are used for files of this context:
    /// a project file imported by relative path from a detached file is in a
    /// different module there, where imports by name resolve differently than
    /// in the project, so only the project's build results are used
    pub fn usesSingle(context: FileContext) bool {
        return switch (context) {
            .none, .library, .detached => true,
            .project, .project_dir, .unloaded_project => false,
        };
    }
};

pub fn fileContext(server: *Server, file: Vfs.FileId) FileContext {
    const in_project = server.inProject(file);
    return fileContextWithOrigin(server, file, server.originOf(file, in_project), in_project);
}

/// `fileContext` with the origin of the file and whether some project contains it already
/// classified (as `Server.fileOrigin` does), so that one computation can serve several checks
pub fn fileContextWithOrigin(server: *Server, file: Vfs.FileId, file_origin: origin.Origin, in_project: bool) FileContext {
    switch (file_origin) {
        .virtual => return .none,
        .zig_lib, .generated, .package => return .library,
        .user, .outside, .other => {},
    }
    if (in_project) return .project;
    const path = server.vfs.path(file);
    const build = config_sync.buildFlags(server).build;
    if (build) {
        const sub_projects = server.config.load(.acquire).build_sub_projects;
        server.roots_mutex.lockUncancelable(server.io);
        defer server.roots_mutex.unlock(server.io);
        for (server.roots.items, server.root_has_build.items) |root, has_build| {
            if (!has_build or !server.vfs.isUnder(path, root)) continue;
            // A sub-project is loaded on demand when the setting is on (see `startSubProjectFor`);
            // when it is off, its project is not loaded, and the root's project does not resolve
            // its imports by name
            if (!sub_projects and std.mem.endsWith(u8, path, ".zig") and subProjectOfLocked(server, path) != null) return .unloaded_project;
            return .project_dir;
        }
    }
    if (!std.mem.endsWith(u8, path, ".zig")) return .none;
    if (build and projectDirOf(server, path) != null) return .unloaded_project;
    if (inZigLib(server, path)) return .library;
    return .detached;
}

/// `path` lies in the lib directory of the zig in use (`zig env`, or `zig.lib_path`). Zig compiles
/// its files as parts of its own modules (`std`, and the build runner, compiler_rt and the other
/// roots in `lib/compiler`), so they are never compiled on their own, even where they are user code
/// (Zig's own source tree, see `origin.Rules.zig_source_tree`): compiled alone, a file of `std`
/// would be in two modules ("file exists in modules 'std' and ..."). Other Zig installations are
/// not told apart from other files: only the toolchain in use says where its library is.
fn inZigLib(server: *Server, path: []const u8) bool {
    const env = zigEnv(server) orelse return false;
    return server.vfs.isUnder(path, env.lib_dir);
}

/// Directory of the project a file belongs to: the first of its directory and that directory's
/// ancestors that has a build.zig. Stops at `.zig-cache` and `zig-pkg`: the files in them (caches,
/// fetched dependency packages) are not source code of the enclosing project.
pub fn projectDirOf(server: *Server, path: []const u8) ?[]const u8 {
    var dir = std.fs.path.dirname(path);
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        const name = std.fs.path.basename(d);
        if (std.mem.eql(u8, name, ".zig-cache") or std.mem.eql(u8, name, "zig-pkg")) return null;
        if (hasBuildZig(server, d) catch false) return d;
    }
    return null;
}

/// Some project is still loading for the first time (see `Workspace.load_done`): it is not yet
/// known which files outside the root directories belong to projects
pub fn projectsLoading(server: *Server) bool {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    for (server.workspaces.items) |ws| if (ws.isLoading()) return true;
    return false;
}

/// The zig environment or a project's first load is still pending: name resolution and types may
/// be incomplete. A restart does not end a first load: it goes on in the new instance.
pub fn projectsPending(server: *Server) bool {
    if (!server.startup_ended.load(.acquire) or server.first_load_restarts.load(.acquire) != 0) return true;
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    for (server.workspaces.items) |ws| {
        if (ws.isLoading()) return true;
        if (ws.successor) |fresh| if (!ws.inModuleGraph() and fresh.isLoading()) return true;
    }
    return false;
}

/// Whether a semantic request must not be answered yet: with `sema.wait_for_project`, while a
/// project is pending; and while the configuration that says whether that setting is on is on its
/// way from the client
pub fn holdForProjects(server: *Server) bool {
    if (server.config_pulling.load(.acquire)) return true;
    return server.config.load(.acquire).wait_for_project and projectsPending(server);
}

/// Holds a semantic request back (see `holdForProjects`) until it can be answered, or until it is
/// canceled or the server shuts down. Returns whether it waited.
pub fn waitForProjects(server: *Server, pending: *const Pending) bool {
    server.project_wait_mutex.lockUncancelable(server.io);
    defer server.project_wait_mutex.unlock(server.io);
    var waited = false;
    while (holdForProjects(server) and !pending.cancel.load(.acquire) and !server.isShuttingDown()) {
        waited = true;
        server.project_wait_cond.wait(server.io, &server.project_wait_mutex) catch break;
    }
    return waited;
}

/// Called after changing anything `waitForProjects` checks. The caller must not hold the locks it
/// takes while checking (`workspaces_mutex`, a workspace's mutex).
pub fn wakeProjectWaiters(server: *Server) void {
    server.project_wait_mutex.lockUncancelable(server.io);
    defer server.project_wait_mutex.unlock(server.io);
    server.project_wait_cond.broadcast(server.io);
}

fn endStartup(server: *Server) void {
    server.startup_ended.store(true, .release);
    wakeProjectWaiters(server);
    // No project load may follow (single-file mode): start the auto-import index now. With
    // projects, the end of their first load calls this too.
    indexing.requestAutoImportIndex(server);
}

/// Starts the project for a root directory; does nothing if the root directory already has a
/// project (startup and workspace folder changes may happen concurrently), or when it is no longer
/// a root directory with a build.zig (the folder was removed, or its build.zig deleted, after the
/// caller looked it up). Does not start when the user's zig is a version whose build graphs cannot
/// be read: the build graph format is defined by the standard library.
/// Such projects get only live diagnostics (zig ast-check) and are not compiled in single-file
/// mode (files that use named modules would report missing modules).
pub fn startWorkspace(server: *Server, root: []const u8) void {
    if (server.isShuttingDown() or !config_sync.buildFlags(server).build) return;
    if (zigEnv(server)) |env| if (!env.readsBuildGraph()) return;
    {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        if (!startsProject(server, root)) return;
        for (server.workspaces.items) |w| if (server.vfs.samePath(w.root, root)) return;
    }
    const ws = Workspace.start(server, root, 0) catch |err| {
        log.err("{s}: failed to start build system protocol: {t}", .{ root, err });
        return;
    };
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    // The list takes over the reference returned by `start`. If the server began shutting down
    // meanwhile (stopping the projects missed this one, and waiting for idle would never end), a
    // project was started for the same root directory meanwhile, the root directory was removed or
    // lost its build.zig meanwhile (or, for a sub-project, it is no longer one or loading them was
    // turned off), or the list cannot grow, the new instance is discarded. A removal updates the
    // root directories (and the setting) before it takes the project out of this list, so either it
    // is seen here or it finds the project in the list.
    const added = !server.shutting_down and startsProject(server, root) and visibleFor(server, root) == null and
        (if (server.workspaces.append(server.gpa, ws)) |_| true else |_| false);
    if (!added) ws.stop();
    ws.placed.set(server.io);
    if (!added) ws.release();
}

/// `root` is a root directory recorded as having a build.zig
pub fn isProjectRoot(server: *Server, root: []const u8) bool {
    server.roots_mutex.lockUncancelable(server.io);
    defer server.roots_mutex.unlock(server.io);
    for (server.roots.items, server.root_has_build.items) |r, has_build| {
        if (server.vfs.samePath(r, root)) return has_build;
    }
    return false;
}

/// A project can be started for directory `root`: it is a root directory recorded as having a
/// build.zig, or, while `build.sub_projects` is on, a sub-project (see `sub_projects`) under a root
/// directory that still has one
fn startsProject(server: *Server, root: []const u8) bool {
    const enabled = server.config.load(.acquire).build_sub_projects;
    server.roots_mutex.lockUncancelable(server.io);
    defer server.roots_mutex.unlock(server.io);
    for (server.roots.items, server.root_has_build.items) |r, has_build| {
        if (server.vfs.samePath(r, root)) return has_build;
    }
    if (!enabled) return false;
    const listed = for (server.sub_projects.items) |d| {
        if (server.vfs.samePath(d, root)) break true;
    } else false;
    if (!listed) return false;
    for (server.roots.items, server.root_has_build.items) |r, has_build| {
        if (has_build and server.vfs.isUnder(root, r)) return true;
    }
    return false;
}

/// The innermost sub-project (see `sub_projects`) whose directory contains `path`, with
/// `roots_mutex` held; the result is valid while it is held
fn subProjectOfLocked(server: *Server, path: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (server.sub_projects.items) |d| if (server.vfs.isUnder(path, d)) {
        if (best == null or d.len > best.?.len) best = d;
    };
    return best;
}

/// `subProjectOfLocked`, allocated by `a`
pub fn subProjectOf(server: *Server, a: Allocator, path: []const u8) Allocator.Error!?[]u8 {
    server.roots_mutex.lockUncancelable(server.io);
    defer server.roots_mutex.unlock(server.io);
    const dir = subProjectOfLocked(server, path) orelse return null;
    return try a.dupe(u8, dir);
}

/// One of the files of the sub-project that contains `path` (see `subProjectOf`) was opened: starts
/// its project, while `build.sub_projects` is on (and once the zig environment is known; startup
/// starts it otherwise, see `refreshSubProjects`)
pub fn startSubProjectFor(server: *Server, path: []const u8) void {
    if (!server.config.load(.acquire).build_sub_projects or zigEnv(server) == null) return;
    const dir = (subProjectOf(server, server.gpa, path) catch return) orelse return;
    defer server.gpa.free(dir);
    startWorkspace(server, dir);
}

/// Starts the projects of the sub-projects that contain open documents (see `startSubProjectFor`)
pub fn startOpenSubProjects(server: *Server) void {
    if (!server.config.load(.acquire).build_sub_projects or zigEnv(server) == null) return;
    var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const open = blk: {
        server.docs.mutex.lockUncancelable(server.io);
        defer server.docs.mutex.unlock(server.io);
        break :blk a.dupe(Vfs.FileId, server.docs.open.keys()) catch return;
    };
    var dirs: std.ArrayList([]const u8) = .empty;
    for (open) |f| {
        const dir = (subProjectOf(server, a, server.vfs.path(f)) catch return) orelse continue;
        for (dirs.items) |d| {
            if (std.mem.eql(u8, d, dir)) break;
        } else dirs.append(a, dir) catch return;
    }
    for (dirs.items) |d| startWorkspace(server, d);
}

/// Stops the projects that can no longer be started (see `startsProject`): those of directories
/// that are no longer sub-projects or whose root directory was removed or lost its build.zig, and
/// all of sub-projects when `build.sub_projects` is off. Returns whether it stopped any (the
/// caller updates the module graph).
pub fn stopStrayProjects(server: *Server) bool {
    const list = workspaceList(server, server.gpa) catch return false;
    defer releaseList(server, server.gpa, list);
    var stopped = false;
    for (list) |ws| if (!startsProject(server, ws.root)) {
        log.info("{s}: not a sub-project to load any more, stopping its project", .{ws.root});
        removeProject(server, ws.root);
        stopped = true;
    };
    return stopped;
}

/// Finds the sub-projects (see `sub_projects`) among the build.zig files of a scan (`files`, the
/// paths found by `workspace_files.scan`), reading their build.zig.zon files from disk; when the
/// list changes, stops the projects of directories that are no longer sub-projects, starts those
/// of new sub-projects that contain open documents, and republishes the open documents (whose
/// context may have changed, see `fileContext`). Nested projects whose build.zig.zon has no `.path`
/// dependency on a root directory or another sub-project are left out, so that in a repository with
/// many unrelated nested projects (the Zig source tree has dozens of test projects) none is loaded.
pub fn refreshSubProjects(server: *Server, a: Allocator, files: []const []const u8) Allocator.Error!void {
    var all_roots: std.ArrayList([]const u8) = .empty;
    var build_roots: std.ArrayList([]const u8) = .empty;
    {
        server.roots_mutex.lockUncancelable(server.io);
        defer server.roots_mutex.unlock(server.io);
        for (server.roots.items, server.root_has_build.items) |r, has_build| {
            const copy = try a.dupe(u8, r);
            try all_roots.append(a, copy);
            if (has_build) try build_roots.append(a, copy);
        }
    }
    const Candidate = struct { dir: []const u8, deps: []const []const u8, eligible: bool = false };
    var candidates: std.ArrayList(Candidate) = .empty;
    for (files) |p| {
        if (!std.mem.eql(u8, std.fs.path.basename(p), "build.zig")) continue;
        const dir = std.fs.path.dirname(p) orelse continue;
        if (containsPath(server, all_roots.items, dir)) continue;
        const under = for (build_roots.items) |r| {
            if (server.vfs.isUnder(dir, r)) break true;
        } else false;
        if (!under) continue;
        const zon = try std.fs.path.join(a, &.{ dir, "build.zig.zon" });
        const text = Io.Dir.cwd().readFileAllocOptions(server.io, zon, a, .limited(16 * 1024 * 1024), .of(u8), 0) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        try candidates.append(a, .{ .dir = dir, .deps = try za.project.packages.pathDependencies(a, server.gpa, dir, text) });
    }
    // A dependency chain can go through other sub-projects (an example that depends on another)
    var eligible: std.ArrayList([]const u8) = .empty;
    var grew = true;
    while (grew) {
        grew = false;
        for (candidates.items) |*c| {
            if (c.eligible) continue;
            for (c.deps) |d| {
                if (!containsPath(server, build_roots.items, d) and !containsPath(server, eligible.items, d)) continue;
                c.eligible = true;
                try eligible.append(a, c.dir);
                grew = true;
                break;
            }
        }
    }
    const changed = blk: {
        server.roots_mutex.lockUncancelable(server.io);
        defer server.roots_mutex.unlock(server.io);
        const same = server.sub_projects.items.len == eligible.items.len and for (eligible.items) |d| {
            if (!containsPath(server, server.sub_projects.items, d)) break false;
        } else true;
        if (same) break :blk false;
        var fresh: std.ArrayList([]u8) = .empty;
        errdefer {
            for (fresh.items) |d| server.gpa.free(d);
            fresh.deinit(server.gpa);
        }
        try fresh.ensureTotalCapacity(server.gpa, eligible.items.len);
        for (eligible.items) |d| fresh.appendAssumeCapacity(try server.gpa.dupe(u8, d));
        for (server.sub_projects.items) |d| server.gpa.free(d);
        server.sub_projects.deinit(server.gpa);
        server.sub_projects = fresh;
        break :blk true;
    };
    if (!changed) return;
    log.info("{d} sub-projects under the workspace folders", .{eligible.items.len});
    for (eligible.items) |d| log.debug("sub-project: {s}", .{d});
    if (stopStrayProjects(server)) indexing.updateModuleGraph(server);
    startOpenSubProjects(server);
    publishing.publishOpenFiles(server);
    server.single.reconcile();
}

/// Whether `list` has a path that is `path` (see `Vfs.samePath`)
fn containsPath(server: *Server, list: []const []const u8, path: []const u8) bool {
    for (list) |p| if (server.vfs.samePath(p, path)) return true;
    return false;
}

/// Directory `dir` is under a root directory with a build.zig, and is not a root directory itself
pub fn nestedUnderRoot(server: *Server, dir: []const u8) bool {
    server.roots_mutex.lockUncancelable(server.io);
    defer server.roots_mutex.unlock(server.io);
    if (containsPath(server, server.roots.items, dir)) return false;
    for (server.roots.items, server.root_has_build.items) |r, has_build| {
        if (has_build and server.vfs.isUnder(dir, r)) return true;
    }
    return false;
}

/// Adds a workspace root directory (`uri` is the URI of the directory). Starts its project
/// immediately if the zig environment is ready; otherwise startup starts it.
pub fn addRoot(server: *Server, root_uri: []const u8) !void {
    const path = uri.toPath(server.gpa, root_uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer server.gpa.free(path);
    const normalized = try Vfs.normalize(.native, server.gpa, path) orelse return;
    var owned = true;
    defer if (owned) server.gpa.free(normalized);
    const has_build = try hasBuildZig(server, normalized);
    {
        server.roots_mutex.lockUncancelable(server.io);
        defer server.roots_mutex.unlock(server.io);
        for (server.roots.items) |r| if (server.vfs.samePath(r, normalized)) return;
        try server.root_has_build.ensureUnusedCapacity(server.gpa, 1);
        try server.roots.append(server.gpa, normalized);
        server.root_has_build.appendAssumeCapacity(has_build);
        owned = false;
    }
    if (has_build and zigEnv(server) != null) startWorkspace(server, normalized);
}

/// Removes a workspace root directory: stops its project and those of its sub-projects, and clears
/// the compiler diagnostics they published
fn removeRoot(server: *Server, arena: Allocator, root_uri: []const u8) !void {
    const path = uri.toPath(arena, root_uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    const normalized = try Vfs.normalize(.native, arena, path) orelse return;
    {
        server.roots_mutex.lockUncancelable(server.io);
        defer server.roots_mutex.unlock(server.io);
        for (server.roots.items, 0..) |r, i| if (server.vfs.samePath(r, normalized)) {
            server.gpa.free(server.roots.orderedRemove(i));
            _ = server.root_has_build.orderedRemove(i);
            break;
        };
    }
    removeProject(server, normalized);
    _ = stopStrayProjects(server);
}

/// Stops the project of root directory `root` and clears the compiler diagnostics it published
/// (the caller updates the module graph)
fn removeProject(server: *Server, root: []const u8) void {
    var removed: ?*Workspace = null;
    {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        // Take it out together with the reference held by the list
        for (server.workspaces.items, 0..) |w, i| if (server.vfs.samePath(w.root, root)) {
            removed = server.workspaces.orderedRemove(i);
            break;
        };
    }
    const ws = removed orelse return;
    defer ws.release();
    wakeProjectWaiters(server);
    stopProject(server, ws);
    ws.mutex.lockUncancelable(server.io);
    const stale = server.gpa.dupe(Vfs.FileId, ws.result_files.keys()) catch &.{};
    ws.mutex.unlock(server.io);
    defer server.gpa.free(stale);
    publishing.publishFiles(server, stale, true);
}

/// Workspace folders added or removed
pub fn didChangeWorkspaceFolders(server: *Server, arena: Allocator, params: types.DidChangeWorkspaceFoldersParams) !void {
    for (params.event.removed) |f| try removeRoot(server, arena, f.uri);
    for (params.event.added) |f| try addRoot(server, f.uri);
    indexing.updateModuleGraph(server);
    // Open files may move into or out of project directories and unloaded projects (the hint
    // appears or disappears accordingly)
    publishing.publishOpenFiles(server);
    server.single.reconcile();
    file_changes.resyncWatcher(server);
    // Before startup, the scan at the end of startup covers the new roots
    if (server.started) indexing.scheduleScan(server);
}

/// Restarts the project of `ws` (finding the project's current instance by root directory: the
/// caller's snapshot of the list may be stale). `crash_restarts` is the number of automatic
/// restarts after consecutive maker crashes (0 for a normal restart).
///
/// The old maker is stopped first (so that it does not build at the same time as the new instance),
/// then the new instance is started. The new instance stays invisible (see `promote`) until its
/// first build finishes (or configuration fails; or, when the old instance has no model, until
/// configuration finishes): meanwhile the list still holds the old instance, whose model, compile
/// set and compiler diagnostics stay in effect, and build requests are forwarded to the new
/// instance (see `requestBuild`).
pub fn restartWorkspace(server: *Server, ws: *Workspace, crash_restarts: u8) void {
    // The maker exited while idle after a completed build, or before the first result of an
    // instance that was to repeat one: the new instance's first build repeats that build unless
    // another is requested meanwhile (see `Workspace.repeats`)
    const repeats: ?u64 = if (crash_restarts == 0) null else blk: {
        ws.mutex.lockUncancelable(server.io);
        defer ws.mutex.unlock(server.io);
        if (ws.repeats) |r| break :blk r;
        break :blk if (ws.built and !ws.building) ws.requests_built else null;
    };
    // Stopping ends this instance's load before the new instance is known
    const first_load = !ws.inModuleGraph();
    if (first_load) _ = server.first_load_restarts.fetchAdd(1, .acq_rel);
    defer if (first_load) {
        _ = server.first_load_restarts.fetchSub(1, .acq_rel);
        wakeProjectWaiters(server);
        // The new instance could not start or was discarded: no first load ends after this one
        indexing.requestAutoImportIndex(server);
    };
    ws.stop();
    {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        // The project has been removed
        const visible = visibleFor(server, ws.root) orelse return;
        visible.stop();
        if (visible.successor) |pending| pending.stop();
    }
    if (server.isShuttingDown()) return;
    const fresh = Workspace.start(server, ws.root, crash_restarts) catch |err| {
        log.err("{s}: failed to restart build system protocol: {t}", .{ ws.root, err });
        return;
    };
    {
        fresh.mutex.lockUncancelable(server.io);
        defer fresh.mutex.unlock(server.io);
        fresh.repeats = repeats;
    }
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    // The server began shutting down while the new instance was starting, or the project has been
    // removed: discard the new instance
    const visible = (if (server.shutting_down) null else visibleFor(server, ws.root)) orelse {
        fresh.stop();
        fresh.placed.set(server.io);
        fresh.release();
        return;
    };
    // A new instance created earlier (or by a concurrent restart) that has not yet replaced the old
    // instance is discarded too
    if (visible.successor) |pending| {
        pending.stop();
        pending.release();
    }
    visible.successor = fresh;
    fresh.placed.set(server.io);
}

/// When a new instance replaces the old one. `built`: the first build finished (or configuration
/// failed while the old instance has no build graph, see `keepOnConfigurationFailure`; the build
/// graph could not be read; or no build is needed); always replaces.
/// `configured`: the build graph was read and the compile set computed; replaces
/// only when the old instance does not take part in the module graph (configuration
/// failed, the build graph could not be read, or the maker crashed before
/// configuring): the old instance has no modules to keep using, so there is no need
/// to wait for the whole build to finish before named modules can be resolved.
pub const PromoteStage = enum { configured, built };

/// The new instance `ws` created by a restart has reached `stage`: replaces the
/// old instance in the list. Returns the replaced instance (together with the
/// reference the list held, which the caller releases); returns null when `ws`
/// is not a new instance waiting to replace one, or when it is not yet time.
pub fn promote(server: *Server, ws: *Workspace, stage: PromoteStage) ?*Workspace {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    if (server.shutting_down) return null;
    for (server.workspaces.items) |*w| if (w.*.successor == ws) {
        const old = w.*;
        if (stage == .configured and old.inModuleGraph()) return null;
        // The list takes over the reference held by `successor`
        old.successor = null;
        w.* = ws;
        return old;
    };
    return null;
}

/// The new instance `ws` created by a restart will not proceed (the maker keeps crashing, exited
/// during the configure phase, or the protocol version does not match): stops waiting for it to
/// replace the old instance. The old instance's model and compile set continue to determine which
/// modules files belong to; its compiler diagnostics will no longer be updated, so they are cleared.
pub fn abandon(server: *Server, ws: *Workspace) void {
    const old = blk: {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        for (server.workspaces.items) |w| if (w.successor == ws) {
            w.successor = null;
            w.acquire();
            break :blk w;
        };
        return;
    };
    defer old.release();
    // The reference held by `successor` (the caller holds another one)
    ws.release();
    old.clearResult();
}

/// The configuration of the new instance `ws` created by a restart failed: when the old instance
/// takes part in the module graph, it stays in the list (its model and compile set keep resolving
/// named imports and finding importers until the configuration is fixed) and `ws` no longer
/// replaces it. Returns the old instance with a reference held for the caller, which stores the
/// configuration errors as its result; null when `ws` should replace the old instance as usual.
pub fn keepOnConfigurationFailure(server: *Server, ws: *Workspace) ?*Workspace {
    const old = blk: {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        if (server.shutting_down) return null;
        for (server.workspaces.items) |w| if (w.successor == ws) {
            if (!w.inModuleGraph()) return null;
            w.successor = null;
            w.acquire();
            break :blk w;
        };
        return null;
    };
    // The reference held by `successor` (the caller holds another one)
    ws.release();
    return old;
}

/// Whether `ws` is the (visible) instance in the list
pub fn isVisible(server: *Server, ws: *Workspace) bool {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    return std.mem.indexOfScalar(*Workspace, server.workspaces.items, ws) != null;
}

/// Stops the instance `ws` in the list, and the new instance that has not yet replaced it
fn stopProject(server: *Server, ws: *Workspace) void {
    ws.stop();
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    if (ws.successor) |s| s.stop();
}

/// Requests a build of the project of `ws` (finding the project's
/// current instance by root directory: the caller's snapshot of the list
/// may be stale); during a restart, the request goes to the new instance
pub fn requestBuild(server: *Server, ws: *Workspace) void {
    _ = server.build_requests.fetchAdd(1, .acq_rel);
    const target = blk: {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        // The project has been removed
        const visible = visibleFor(server, ws.root) orelse return;
        const t = visible.successor orelse visible;
        t.acquire();
        break :blk t;
    };
    defer target.release();
    target.requestBuild();
}

/// A change on disk of `files` (owned by the project of `ws`) was notified: if the project's
/// current instance is in the middle of a build, it decides whether to rebuild for them when the
/// build completes (see `Workspace.deferChanges`) and this returns true
pub fn deferChanges(server: *Server, ws: *Workspace, files: []const Vfs.FileId) bool {
    const target = blk: {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        const visible = visibleFor(server, ws.root) orelse return false;
        const t = visible.successor orelse visible;
        t.acquire();
        break :blk t;
    };
    defer target.release();
    return target.deferChanges(files);
}

/// The disk contents the latest rebuild for `file` was based on (see `watched_built`)
pub fn watchedBuilt(server: *Server, file: Vfs.FileId) ??u64 {
    server.watched_built_mutex.lockUncancelable(server.io);
    defer server.watched_built_mutex.unlock(server.io);
    return server.watched_built.get(file);
}

/// Whether the disk contents of any of `files` differ from those the latest rebuild was based on
/// (see `watched_built`), recording the current contents as that basis: a project calls this when
/// a build completes during which their change was notified (see `Workspace.deferChanges`)
pub fn changedSinceBuilt(server: *Server, files: []const Vfs.FileId) Io.Cancelable!bool {
    var changed = false;
    for (files) |file| {
        const read = server.vfs.readFromDisk(file, server.gpa) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.FileTooBig => null,
            error.OutOfMemory => {
                changed = true;
                continue;
            },
        };
        defer if (read) |t| server.gpa.free(t);
        const disk: ?u64 = if (read) |t| std.hash.Wyhash.hash(0, t) else null;
        server.watched_built_mutex.lockUncancelable(server.io);
        defer server.watched_built_mutex.unlock(server.io);
        const gop = server.watched_built.getOrPut(server.gpa, file) catch {
            changed = true;
            continue;
        };
        if (gop.found_existing and std.meta.eql(gop.value_ptr.*, disk)) continue;
        gop.value_ptr.* = disk;
        changed = true;
    }
    return changed;
}

/// The instance in the list for the project of root
/// directory `root`; the caller holds `workspaces_mutex`
pub fn visibleFor(server: *Server, root: []const u8) ?*Workspace {
    for (server.workspaces.items) |w| if (server.vfs.samePath(w.root, root)) return w;
    return null;
}

/// Snapshot of the instances in the list (each with a reference held; release with `releaseList`)
pub fn workspaceList(server: *Server, a: Allocator) Allocator.Error![]*Workspace {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    const list = try a.dupe(*Workspace, server.workspaces.items);
    for (list) |ws| ws.acquire();
    return list;
}

pub fn releaseList(server: *Server, a: Allocator, list: []*Workspace) void {
    _ = server;
    for (list) |ws| ws.release();
    a.free(list);
}

pub fn stopWorkspaces(server: *Server) void {
    {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        server.shutting_down = true;
        for (server.workspaces.items) |ws| {
            ws.stop();
            if (ws.successor) |s| s.stop();
        }
    }
    wakeProjectWaiters(server);
    indexing.wakeScanWaiters(server);
    if (server.watcher) |w| w.stop();
    server.single.compiles.stop(server.io);
}

pub fn zigEnv(server: *Server) ?*const ZigEnv {
    return server.toolchain.load(.acquire).env;
}

// Prevents ignoring a build.zig created or saved through another spelling of a root directory on a
// case-insensitive file system: roots are compared by file identity, not byte by byte
test "refreshRoot: a root directory spelled with another case is the same root" {
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var writer: transport.Writer = .{ .io = std.testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(std.testing.io, gpa, &writer);
    defer server.deinit();
    server.vfs.case = .insensitive;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    const root_uri = try uri.fromPath(gpa, root);
    defer gpa.free(root_uri);
    try addRoot(&server, root_uri);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data = "" });
    const variant = try std.ascii.allocUpperString(gpa, root);
    defer gpa.free(variant);
    try std.testing.expect(!std.mem.eql(u8, variant, root));
    try std.testing.expect(try refreshRoot(&server, variant));
    try std.testing.expect(server.root_has_build.items[0]);
    try std.testing.expect(!try refreshRoot(&server, variant));
}
