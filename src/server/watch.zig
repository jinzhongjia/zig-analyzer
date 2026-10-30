//! The server detects external changes on disk (git checkout, code generation, other editors):
//! when the client cannot register file watchers dynamically (the default for Neovim on Linux), or
//! when `files.watcher` is configured as `server`. With `auto` and a client that registers file
//! watchers, the server still watches the files outside the root directories: clients apply the
//! registered watchers inside the workspace folders only (see `Server.WatchScope`).
//!
//! Files of interest: interned `.zig` / `.zon` files (analysis reads any imported file from disk
//! on demand), plus `build.zig`, `build.zig.zon`, and `zig-analyzer.zon` in each workspace root,
//! and the configure input directories of projects (see `Server.configureInputDirs`), whose
//! created and deleted entries are reported too; libraries, which never change, are excluded (see
//! `Server.watchable`). Changes are handled as `workspace/didChangeWatchedFiles` notifications,
//! along the same path as the client's notifications, open documents included: their buffers
//! take precedence, but builds read the disk.
//!
//! The directories containing these files are watched with the operating system's native
//! notifications: inotify on Linux, FSEvents on macOS, directory change notifications on Windows.
//! A directory that does not exist yet is watched through its nearest existing ancestor; once it
//! appears, it is watched itself, and files of interest already in it are treated as created. The
//! directories to watch are recomputed when new files are interned, roots are added or removed,
//! directories are created or deleted, or notifications are lost. Source files created in watched
//! directories that are not files of interest yet, and directories created or deleted, make the
//! server scan the root directories for source files again (see `Server.scheduleScan`).
//!
//! Polling (periodically checking size and modification time) is only the last resort: when
//! native notifications are unavailable (other platforms, initialization failure), or some
//! directories exceed the limit on the number of watches, only the files in those directories are
//! polled.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const za = @import("../zig_analyzer.zig");
const types = za.lsp.types;
const uri = za.base.uri;
const Vfs = za.base.Vfs;
const Server = @import("Server.zig");
const Config = @import("Config.zig");
const workspace_files = @import("workspace_files.zig");

const log = std.log.scoped(.watch);

/// After a notification, wait until no new notification has arrived for this long before handling:
/// the many files changed by one git checkout are merged into one batch
const debounce_ms = 50;
/// Maximum delay while notifications keep arriving
const max_debounce_ms = 500;
/// When polling, the wait between two checks is at least this many times the duration of one
/// check: with many files the interval grows, so polling takes no more than about 5% of the time
const min_idle_factor = 20;

/// One change reported by native notifications
const Event = struct {
    /// Absolute path; for `overflow`, empty means all files
    path: []const u8,
    kind: Kind,

    const Kind = enum {
        /// The file contents may have changed
        changed,
        /// This name was created or moved in (may be a directory)
        created,
        /// This name was deleted or moved out (may be a directory)
        removed,
        /// A directory was created or moved in
        dir_created,
        /// The watched directory itself or a subdirectory in it was deleted or moved away
        dir_gone,
        /// Notifications were lost (queue overflow, etc.): any file under `path` may have changed
        overflow,
    };
};

pub const Watcher = struct {
    server: *Server,
    gpa: Allocator,
    backend: Backend,
    listener: Vfs.Listener,
    /// The files of interest and the watched directories need to be recomputed (new files were
    /// interned, roots were added or removed)
    resync_requested: std.atomic.Value(bool) = .init(true),
    stopping: std.atomic.Value(bool) = .init(false),

    // ── The following fields are accessed only by the background task ──
    /// What is being watched (see `Server.WatchScope`); `.none` while not watching
    scope: Server.WatchScope = .none,
    /// Arena holding `files` and `missing`; replaced as a whole on recomputation
    state_arena: std.heap.ArenaAllocator,
    /// Files of interest: identity key (lowercased when case-insensitive) → path
    files: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// Directories of files of interest that do not exist yet: identity key → path (their nearest
    /// existing ancestors are watched instead)
    missing: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// Configure input directories whose entries are of interest (see
    /// `Server.configureInputDirs`): identity keys in `state_arena`. Each is also a file of
    /// interest itself, so its appearance and disappearance, and its modification time when
    /// polled, are noticed.
    entry_dirs: std.StringHashMapUnmanaged(void) = .empty,
    /// Files polled because their directory cannot be watched (paths are in `state_arena`)
    fallback: std.ArrayList([]const u8) = .empty,
    poller: Poller,
    /// Other files additionally registered by file name when the client detects external changes
    /// (`registerClientGlobs`); keys are allocated by `gpa`
    client_names: std.StringHashMapUnmanaged(void) = .empty,
    client_registrations: u32 = 0,
    /// Duration of the last poll (see `min_idle_factor`)
    poll_ns: i96 = 0,
    next_poll: ?Io.Timestamp = null,

    /// Created on the main loop, so later `wake` / `stop` calls are not lost. Falls back to polling
    /// when native notifications are unavailable.
    pub fn create(server: *Server) Allocator.Error!*Watcher {
        const gpa = server.gpa;
        const w = try gpa.create(Watcher);
        errdefer gpa.destroy(w);
        const backend: Backend = if (Native.create(gpa, server.io)) |native| .{ .native = native } else |err| blk: {
            if (Native != Unsupported) log.warn("native file watching is unavailable ({t}), checking files on disk periodically instead", .{err});
            break :blk .{ .fallback = try Fallback.create(gpa, server.io) };
        };
        w.* = .{
            .server = server,
            .gpa = gpa,
            .backend = backend,
            .listener = .{ .ctx = w, .notify = onNewPath },
            .state_arena = .init(gpa),
            .poller = .{ .gpa = gpa },
        };
        return w;
    }

    /// Called after the background task ends
    pub fn destroy(w: *Watcher) void {
        var names = w.client_names.keyIterator();
        while (names.next()) |k| w.gpa.free(k.*);
        w.client_names.deinit(w.gpa);
        w.backend.destroy(w.gpa);
        w.fallback.deinit(w.gpa);
        w.files.deinit(w.gpa);
        w.missing.deinit(w.gpa);
        w.entry_dirs.deinit(w.gpa);
        w.state_arena.deinit();
        w.poller.deinit();
        w.gpa.destroy(w);
    }

    /// The files of interest may have changed (roots added or removed), or how files are watched
    /// may have changed (configuration): recompute in the background task
    pub fn requestResync(w: *Watcher) void {
        w.resync_requested.store(true, .release);
        w.backend.wake();
    }

    /// Makes the background task end (server shutdown)
    pub fn stop(w: *Watcher) void {
        w.stopping.store(true, .release);
        w.backend.wake();
    }

    fn onNewPath(ctx: *anyopaque) void {
        const w: *Watcher = @ptrCast(@alignCast(ctx));
        // Wake only when the flag goes from false to true: loading a project interns thousands of
        // files in a row
        if (!w.resync_requested.swap(true, .acq_rel)) w.backend.wake();
    }

    /// Background task: ends when the server shuts down
    pub fn run(w: *Watcher) Io.Cancelable!void {
        defer w.deactivate();
        while (!w.stopping.load(.acquire)) {
            const scope = w.server.watchScope();
            if (scope == .none) {
                w.deactivate();
                // Clear first, then check: new files interned during the check wake the task
                // again (see `onNewPath`)
                w.resync_requested.store(false, .release);
                if (w.server.register_watch) w.registerClientGlobs() catch |err| switch (err) {
                    error.OutOfMemory => log.err("out of memory while registering file watchers", .{}),
                };
                w.backend.wait(null);
                var discard: std.heap.ArenaAllocator = .init(w.gpa);
                defer discard.deinit();
                var events: std.ArrayList(Event) = .empty;
                w.backend.drain(discard.allocator(), &events) catch {};
                continue;
            }
            w.step(scope) catch |err| switch (err) {
                error.OutOfMemory => log.err("out of memory while watching files on disk", .{}),
            };
        }
    }

    /// When the client detects external changes, the initially registered globs cover only
    /// `.zig` and `.zon`: other interned files (files used by `@embedFile`, configure inputs) are
    /// additionally registered by file name (`**/<file name>`; notifications for other files with
    /// the same name are ignored, since those are not interned), the directories under the root
    /// directories that contain interned files by their name (`**/<name>`: a directory deleted,
    /// moved or renamed is reported by its own path only), and configure input directories by
    /// their name and their entries (`**/<name>`, `**/<name>/*`). A name containing glob special
    /// characters cannot be written as a glob and is not registered.
    fn registerClientGlobs(w: *Watcher) Allocator.Error!void {
        const server = w.server;
        var arena: std.heap.ArenaAllocator = .init(w.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const rules = try server.originRules(a);
        var globs: std.ArrayList([]const u8) = .empty;
        var dir_names: std.StringHashMapUnmanaged(void) = .empty;
        for (0..server.vfs.count()) |i| {
            const path = server.vfs.path(@fromBackingInt(@as(u32, @intCast(i))));
            if (!server.watchable(rules, path)) continue;
            if (server.vfs.rootOf(rules.roots, path)) |root| {
                var dir = std.fs.path.dirname(path);
                while (dir) |d| : (dir = std.fs.path.dirname(d)) {
                    if (d.len <= root.len) break;
                    const name = std.fs.path.basename(d);
                    if (w.client_names.contains(name)) continue;
                    const gop = try dir_names.getOrPut(a, name);
                    if (!gop.found_existing) try globs.append(a, try std.fmt.allocPrint(a, "**/{s}", .{name}));
                }
            }
            if (std.mem.endsWith(u8, path, ".zig") or std.mem.endsWith(u8, path, ".zon")) continue;
            try globs.append(a, try std.fmt.allocPrint(a, "**/{s}", .{std.fs.path.basename(path)}));
        }
        for (try server.configureInputDirs(a)) |dir| {
            if (!server.watchable(rules, dir)) continue;
            const base = std.fs.path.basename(dir);
            try globs.append(a, try std.fmt.allocPrint(a, "**/{s}", .{base}));
            try globs.append(a, try std.fmt.allocPrint(a, "**/{s}/*", .{base}));
        }
        var out: std.Io.Writer.Allocating = .init(a);
        var added: usize = 0;
        for (globs.items) |glob| {
            const name = glob["**/".len..];
            const literal = if (std.mem.endsWith(u8, name, "/*")) name[0 .. name.len - 2] else name;
            if (std.mem.indexOfAny(u8, literal, "*?[]{}") != null or w.client_names.contains(name)) continue;
            try w.client_names.put(w.gpa, try w.gpa.dupe(u8, name), {});
            out.writer.writeAll(if (added == 0) "{\"watchers\": [" else ", ") catch return error.OutOfMemory;
            std.json.Stringify.value(.{ .globPattern = glob }, .{}, &out.writer) catch return error.OutOfMemory;
            added += 1;
        }
        if (added == 0) return;
        out.writer.writeAll("]}") catch return error.OutOfMemory;
        const options = std.json.parseFromSliceLeaky(std.json.Value, a, out.written(), .{}) catch return error.OutOfMemory;
        w.client_registrations += 1;
        const id = try std.fmt.allocPrint(a, "zig-analyzer/didChangeWatchedFiles/{d}", .{w.client_registrations});
        server.sendRequest(.{ .string = id }, "client/registerCapability", types.RegistrationParams{ .registrations = &.{.{ .id = id, .method = "workspace/didChangeWatchedFiles", .registerOptions = options }} });
    }

    /// One round: recompute the watched directories (if needed), wait for notifications or the
    /// time to poll, and handle this batch of changes
    fn step(w: *Watcher, scope: Server.WatchScope) Allocator.Error!void {
        const io = w.server.io;
        var batch_arena: std.heap.ArenaAllocator = .init(w.gpa);
        defer batch_arena.deinit();
        const a = batch_arena.allocator();
        var pending: Pending = .{};

        // Clear the request before computing: a request arriving during the computation wakes
        // the task again
        const requested = w.resync_requested.swap(false, .acq_rel);
        if (w.scope != scope or requested) {
            try w.resync(a, scope, &pending);
            if (pending.paths.count() != 0) return w.apply(a, &pending);
        }

        // Wait for notifications; when some files need polling, wait at most until the next poll
        const timeout_ns: ?u64 = if (w.next_poll) |at| blk: {
            const left = Io.Clock.awake.now(io).durationTo(at).nanoseconds;
            break :blk if (left <= 0) 0 else @intCast(left);
        } else null;
        w.backend.wait(timeout_ns);
        if (w.stopping.load(.acquire)) return;

        var events: std.ArrayList(Event) = .empty;
        try w.backend.drain(a, &events);
        if (events.items.len != 0) {
            // Merge a burst of consecutive notifications
            const deadline = Io.Clock.awake.now(io).addDuration(.fromMilliseconds(max_debounce_ms));
            while (Io.Clock.awake.now(io).durationTo(deadline).nanoseconds > 0) {
                const before = events.items.len;
                w.backend.wait(debounce_ms * std.time.ns_per_ms);
                if (w.stopping.load(.acquire)) return;
                try w.backend.drain(a, &events);
                if (events.items.len == before) break;
            }
        }
        const dirs_changed = try w.handle(a, events.items, &pending);

        if (w.next_poll) |at| if (Io.Clock.awake.now(io).durationTo(at).nanoseconds <= 0) {
            const start = Io.Clock.awake.now(io);
            try w.poller.poll(io, a, w.fallback.items, &pending);
            w.poll_ns = start.durationTo(Io.Clock.awake.now(io)).nanoseconds;
            w.schedulePoll();
        };

        // First add watches for newly appeared directories, then read the state of the files:
        // every later change will be notified
        const requested_now = w.resync_requested.swap(false, .acq_rel);
        if (dirs_changed or requested_now) try w.resync(a, w.scope, &pending);
        if (pending.paths.count() != 0) try w.apply(a, &pending);
    }

    /// Stops watching and discards the state: when watching starts again, the disk state at that
    /// time is taken as is, and changes in between are not reported afterwards
    fn deactivate(w: *Watcher) void {
        if (w.scope == .none) return;
        w.scope = .none;
        var none: std.ArrayList([]const u8) = .empty;
        w.backend.setDirs(w.gpa, &.{}, &none) catch {};
        none.deinit(w.gpa);
        w.files.clearRetainingCapacity();
        w.missing.clearRetainingCapacity();
        w.entry_dirs.clearRetainingCapacity();
        w.fallback.clearRetainingCapacity();
        _ = w.state_arena.reset(.retain_capacity);
        w.poller.reset();
        w.next_poll = null;
    }

    /// Identity key: consistent with Vfs file identity; lowercased when case-insensitive
    fn key(w: *const Watcher, a: Allocator, path: []const u8) Allocator.Error![]const u8 {
        if (w.server.vfs.case == .sensitive) return path;
        return std.ascii.allocLowerString(a, path);
    }

    /// Recomputes the files of interest and the watched directories for `scope`; with
    /// `.outside_roots`, also registers the client's additional file watchers. Files of interest
    /// that already exist in directories that did not exist before but have appeared now are
    /// recorded in `pending`.
    fn resync(w: *Watcher, a: Allocator, scope: Server.WatchScope, pending: *Pending) Allocator.Error!void {
        const server = w.server;
        const gpa = w.gpa;
        if (scope == .outside_roots) try w.registerClientGlobs();
        var next_arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer next_arena.deinit();
        const na = next_arena.allocator();

        var files: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        errdefer files.deinit(gpa);
        const rules = try server.originRules(a);
        // With `.outside_roots`, the client watches the files under the root directories
        const outside_only = scope == .outside_roots;
        const count = server.vfs.count();
        for (0..count) |i| {
            const path = server.vfs.path(@fromBackingInt(@as(u32, @intCast(i))));
            if (!server.watchable(rules, path)) continue;
            if (outside_only and server.vfs.rootOf(rules.roots, path) != null) continue;
            try files.put(gpa, try w.key(na, path), path);
        }
        if (!outside_only) {
            server.roots_mutex.lockUncancelable(server.io);
            defer server.roots_mutex.unlock(server.io);
            for (server.roots.items) |root| for ([_][]const u8{ "build.zig", "build.zig.zon", Config.project_file }) |name| {
                const path = try std.fs.path.join(na, &.{ root, name });
                try files.put(gpa, try w.key(na, path), path);
            };
        }
        var entry_dirs: std.StringHashMapUnmanaged(void) = .empty;
        errdefer entry_dirs.deinit(gpa);
        for (try server.configureInputDirs(na)) |dir| {
            if (!server.watchable(rules, dir)) continue;
            if (outside_only and server.vfs.rootOf(rules.roots, dir) != null) continue;
            const k = try w.key(na, dir);
            try files.put(gpa, k, dir);
            try entry_dirs.put(gpa, k, {});
        }

        // Each file's directory: watch it if it exists, otherwise its nearest existing ancestor
        var dirs: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        defer dirs.deinit(gpa);
        var missing: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        errdefer missing.deinit(gpa);
        // File → watched directory (index into `dirs`)
        const targets = try a.alloc(u32, files.count());
        for (files.values(), targets) |path, *target| {
            const dir = std.fs.path.dirname(path) orelse path;
            const dir_key = try w.key(na, dir);
            if (dirs.getIndex(dir_key)) |i| {
                target.* = @intCast(i);
                continue;
            }
            const watched = if (missing.get(dir_key)) |_| null else if (isDir(server.io, dir)) dir else null;
            const watch_dir = watched orelse blk: {
                try missing.put(gpa, dir_key, dir);
                break :blk ancestor(server.io, dir);
            };
            const gop = try dirs.getOrPut(gpa, try w.key(na, watch_dir));
            if (!gop.found_existing) gop.value_ptr.* = watch_dir;
            target.* = @intCast(gop.index);
        }
        // Configure input directories are watched themselves for their entries
        var entry_watches: std.ArrayList(u32) = .empty;
        var entries = entry_dirs.keyIterator();
        while (entries.next()) |k| {
            const dir = files.get(k.*).?;
            if (!isDir(server.io, dir)) continue;
            const gop = try dirs.getOrPut(gpa, k.*);
            if (!gop.found_existing) gop.value_ptr.* = dir;
            try entry_watches.append(a, @intCast(gop.index));
        }

        var failed: std.ArrayList([]const u8) = .empty;
        defer failed.deinit(gpa);
        try w.backend.setDirs(gpa, dirs.values(), &failed);
        var failed_set: std.StringHashMapUnmanaged(void) = .empty;
        defer failed_set.deinit(gpa);
        for (failed.items) |d| try failed_set.put(gpa, try w.key(a, d), {});
        var fallback: std.ArrayList([]const u8) = .empty;
        errdefer fallback.deinit(gpa);
        if (failed_set.count() != 0) for (files.values(), targets) |path, target| {
            if (failed_set.contains(dirs.keys()[target])) try fallback.append(gpa, path);
        };
        // A configure input directory that cannot be watched: its modification time is polled
        for (entry_watches.items) |i| if (failed_set.contains(dirs.keys()[i])) {
            const dir = dirs.values()[i];
            for (fallback.items) |p| {
                if (p.ptr == dir.ptr) break;
            } else try fallback.append(gpa, dir);
        };

        // Directories that did not exist before but have appeared now: files of interest already in
        // them were created before watching started
        if (w.scope != .none) {
            var appeared: std.StringHashMapUnmanaged(void) = .empty;
            defer appeared.deinit(gpa);
            for (w.missing.keys()) |k| if (!missing.contains(k)) try appeared.put(gpa, k, {});
            if (appeared.count() != 0) for (files.keys(), files.values()) |k, path| {
                const dir_key = std.fs.path.dirname(k) orelse continue;
                if (appeared.contains(dir_key)) try pending.add(a, path, .created);
            };
        }

        w.files.deinit(gpa);
        w.files = files;
        w.missing.deinit(gpa);
        w.missing = missing;
        w.entry_dirs.deinit(gpa);
        w.entry_dirs = entry_dirs;
        w.fallback.deinit(gpa);
        w.fallback = fallback;
        w.state_arena.deinit();
        w.state_arena = next_arena;
        w.scope = scope;
        if (w.fallback.items.len == 0) {
            w.next_poll = null;
            w.poller.reset();
        } else if (w.next_poll == null) {
            w.schedulePoll();
        }
        log.debug("watching {d} directories for {d} files ({d} checked periodically)", .{ dirs.count(), w.files.count(), w.fallback.items.len });
    }

    fn schedulePoll(w: *Watcher) void {
        const interval_ns = @as(i96, w.server.poll_interval_ms.load(.monotonic)) * std.time.ns_per_ms;
        const wait_ns = @max(interval_ns, w.poll_ns * min_idle_factor);
        w.next_poll = Io.Clock.awake.now(w.server.io).addDuration(.{ .nanoseconds = wait_ns });
    }

    /// Maps notifications to files of interest and records them in `pending`; returns whether
    /// directories changed (the watched directories need to be recomputed)
    fn handle(w: *Watcher, a: Allocator, events: []const Event, pending: *Pending) Allocator.Error!bool {
        // Directory changes: any file of interest under them may have changed. An empty path
        // means all files.
        var dirs: std.StringHashMapUnmanaged(void) = .empty;
        var all = false;
        // Source files the server does not know yet may belong to the workspace (see
        // `Server.scheduleScan`), and so may directories that appear or disappear
        var rescan = false;
        var created: std.ArrayList([]const u8) = .empty;
        for (events) |ev| switch (ev.kind) {
            .changed, .created, .removed => {
                const k = try w.key(a, ev.path);
                if (w.files.get(k)) |path| {
                    try pending.add(a, path, if (ev.kind == .created) .created else .changed);
                } else {
                    // An entry created in or removed from a configure input directory
                    if (ev.kind != .changed and w.inEntryDir(k)) try pending.add(a, ev.path, if (ev.kind == .created) .created else .changed);
                    if (ev.kind == .created) {
                        // Not known whether it is a directory (Windows notifications do not
                        // tell): a path leading to a nonexistent directory has appeared
                        if (w.leadsToMissing(k)) try dirs.put(a, k, {});
                        if (workspace_files.isSource(std.fs.path.basename(ev.path))) try created.append(a, ev.path);
                    }
                }
            },
            .dir_created, .dir_gone, .overflow => {
                rescan = true;
                if (ev.path.len == 0) all = true else {
                    const k = try w.key(a, ev.path);
                    try dirs.put(a, k, {});
                    if (ev.kind != .overflow and w.inEntryDir(k)) try pending.add(a, ev.path, if (ev.kind == .dir_created) .created else .changed);
                }
            },
        };
        if (!rescan and created.items.len != 0) {
            const rules = try w.server.originRules(a);
            for (created.items) |path| {
                if (workspace_files.contains(&w.server.vfs, rules, path)) rescan = true;
            }
        }
        if (rescan) w.server.scheduleScan();
        if (!all and dirs.count() == 0) return false;
        for (w.files.keys(), w.files.values()) |k, path| {
            if (!all and !underAny(k, &dirs)) continue;
            try pending.add(a, path, .changed);
        }
        return true;
    }

    /// `k` (an identity key) is an entry of a configure input directory
    fn inEntryDir(w: *const Watcher, k: []const u8) bool {
        return w.entry_dirs.contains(std.fs.path.dirname(k) orelse return false);
    }

    /// `k` (an identity key) is a nonexistent directory itself or one of its ancestors
    fn leadsToMissing(w: *const Watcher, k: []const u8) bool {
        for (w.missing.keys()) |m| if (w.server.vfs.isUnder(m, k)) return true;
        return false;
    }

    /// Generates change events from the current state of the files and hands them to the server.
    /// Open documents are included: their buffers take precedence, but builds read the disk.
    fn apply(w: *Watcher, a: Allocator, pending: *Pending) Allocator.Error!void {
        const server = w.server;
        var events: std.ArrayList(types.FileEvent) = .empty;
        for (pending.paths.keys(), pending.paths.values()) |path, hint| {
            const exists = stat(server.io, path) != null;
            const kind: types.FileChangeType = if (!exists) .Deleted else if (hint == .created) .Created else .Changed;
            try events.append(a, .{ .uri = try uri.fromPath(a, path), .type = kind });
        }
        if (events.items.len == 0) return;
        log.debug("{d} file(s) changed on disk", .{events.items.len});
        server.applyWatchedChanges(a, events.items);
    }
};

/// A batch of pending changes: path → whether it was created. Paths are copied into this batch's
/// arena: the files of interest may be recomputed before handling, which frees the arena they were
/// originally in.
const Pending = struct {
    paths: std.StringArrayHashMapUnmanaged(Hint) = .empty,

    const Hint = enum { changed, created };

    fn add(p: *Pending, a: Allocator, path: []const u8, hint: Hint) Allocator.Error!void {
        const gop = try p.paths.getOrPut(a, path);
        if (gop.found_existing) {
            if (hint == .created) gop.value_ptr.* = hint;
            return;
        }
        gop.key_ptr.* = a.dupe(u8, path) catch |err| {
            _ = p.paths.pop();
            return err;
        };
        gop.value_ptr.* = hint;
    }
};

/// `k` is one of the directories in `dirs` or is under one
fn underAny(k: []const u8, dirs: *const std.StringHashMapUnmanaged(void)) bool {
    var cur: ?[]const u8 = k;
    while (cur) |c| : (cur = std.fs.path.dirname(c)) {
        if (dirs.contains(c)) return true;
    }
    return false;
}

fn isDir(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// The nearest existing ancestor directory of `dir` (the root directory always exists)
fn ancestor(io: Io, dir: []const u8) []const u8 {
    var cur = dir;
    while (std.fs.path.dirname(cur)) |parent| : (cur = parent) {
        if (isDir(io, parent)) return parent;
    }
    return cur;
}

/// State of a file on disk; null when it does not exist
const Stamp = struct {
    size: u64,
    mtime: i96,
};

fn stat(io: Io, path: []const u8) ?Stamp {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    if (st.kind == .directory) return null;
    return .{ .size = st.size, .mtime = st.mtime.nanoseconds };
}

/// Polling: checks the size and modification time of a set of files. The first check of a file
/// only records its state; only later changes count.
const Poller = struct {
    gpa: Allocator,
    /// Path (owned by `gpa`) → state at the last check
    seen: std.StringArrayHashMapUnmanaged(?Stamp) = .empty,

    fn deinit(p: *Poller) void {
        p.reset();
        p.seen.deinit(p.gpa);
    }

    fn reset(p: *Poller) void {
        for (p.seen.keys()) |k| p.gpa.free(k);
        p.seen.clearRetainingCapacity();
    }

    /// Checks `paths` and records changes in `pending`; files not in `paths` are no longer tracked
    fn poll(p: *Poller, io: Io, a: Allocator, paths: []const []const u8, pending: *Pending) Allocator.Error!void {
        var current: std.StringArrayHashMapUnmanaged(?Stamp) = .empty;
        for (paths) |path| try current.put(a, path, stat(io, path));
        var i: usize = p.seen.count();
        while (i > 0) {
            i -= 1;
            if (current.contains(p.seen.keys()[i])) continue;
            p.gpa.free(p.seen.keys()[i]);
            p.seen.swapRemoveAt(i);
        }
        for (current.keys(), current.values()) |path, now| {
            const gop = try p.seen.getOrPut(p.gpa, path);
            if (!gop.found_existing) {
                gop.key_ptr.* = p.gpa.dupe(u8, path) catch |err| {
                    p.seen.swapRemoveAt(gop.index);
                    return err;
                };
                gop.value_ptr.* = now;
                continue;
            }
            const before = gop.value_ptr.*;
            gop.value_ptr.* = now;
            if (before == null and now == null) continue;
            if (before != null and now != null and std.meta.eql(before.?, now.?)) continue;
            try pending.add(a, path, if (before == null) .created else .changed);
        }
    }
};

// ── Watch backends ────────────────────────────────────────────────────

const Backend = union(enum) {
    native: *Native,
    fallback: *Fallback,

    fn destroy(b: Backend, gpa: Allocator) void {
        switch (b) {
            inline else => |x| x.destroy(gpa),
        }
    }

    /// Wakes the waiting background task; may be called from any thread
    fn wake(b: Backend) void {
        switch (b) {
            inline else => |x| x.wake(),
        }
    }

    /// Changes the watched directories to `dirs` (absolute paths); directories that cannot be
    /// watched are appended to `failed` (taken from `dirs`). Called only in the background task.
    fn setDirs(b: Backend, gpa: Allocator, dirs: []const []const u8, failed: *std.ArrayList([]const u8)) Allocator.Error!void {
        switch (b) {
            inline else => |x| try x.setDirs(gpa, dirs, failed),
        }
    }

    /// Waits until there are notifications, a wake-up, or a timeout (null means no timeout)
    fn wait(b: Backend, timeout_ns: ?u64) void {
        switch (b) {
            inline else => |x| x.wait(timeout_ns),
        }
    }

    /// Takes out notifications that have arrived (without waiting); paths are allocated in `a`
    fn drain(b: Backend, a: Allocator, out: *std.ArrayList(Event)) Allocator.Error!void {
        switch (b) {
            inline else => |x| try x.drain(a, out),
        }
    }
};

const Native = switch (builtin.os.tag) {
    .linux => Inotify,
    .macos => FsEvents,
    .windows => DirNotify,
    else => Unsupported,
};

const Unsupported = struct {
    fn create(_: Allocator, _: Io) error{Unsupported}!*Unsupported {
        return error.Unsupported;
    }
    fn destroy(_: *Unsupported, _: Allocator) void {
        unreachable;
    }
    fn wake(_: *Unsupported) void {
        unreachable;
    }
    fn setDirs(_: *Unsupported, _: Allocator, _: []const []const u8, _: *std.ArrayList([]const u8)) Allocator.Error!void {
        unreachable;
    }
    fn wait(_: *Unsupported, _: ?u64) void {
        unreachable;
    }
    fn drain(_: *Unsupported, _: Allocator, _: *std.ArrayList(Event)) Allocator.Error!void {
        unreachable;
    }
};

/// No native notifications: no directory can be watched (all files are polled); only waking
/// up is provided
const Fallback = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    signaled: bool = false,

    fn create(gpa: Allocator, io: Io) Allocator.Error!*Fallback {
        const f = try gpa.create(Fallback);
        f.* = .{ .io = io };
        return f;
    }

    fn destroy(f: *Fallback, gpa: Allocator) void {
        gpa.destroy(f);
    }

    fn wake(f: *Fallback) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.signaled = true;
        f.cond.signal(f.io);
    }

    fn setDirs(_: *Fallback, gpa: Allocator, dirs: []const []const u8, failed: *std.ArrayList([]const u8)) Allocator.Error!void {
        try failed.appendSlice(gpa, dirs);
    }

    fn wait(f: *Fallback, timeout_ns: ?u64) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const deadline: ?Io.Timestamp = if (timeout_ns) |ns| Io.Clock.awake.now(f.io).addDuration(.{ .nanoseconds = ns }) else null;
        while (!f.signaled) {
            if (deadline) |d| {
                f.cond.waitTimeout(f.io, &f.mutex, .{ .deadline = .{ .raw = d, .clock = .awake } }) catch break;
            } else f.cond.waitUncancelable(f.io, &f.mutex);
        }
        f.signaled = false;
    }

    fn drain(_: *Fallback, _: Allocator, _: *std.ArrayList(Event)) Allocator.Error!void {}
};

/// Linux: inotify watches individual directories (non-recursively); eventfd is used for waking up
const Inotify = struct {
    const linux = std.os.linux;
    const IN = linux.IN;

    gpa: Allocator,
    fd: linux.fd_t,
    wake_fd: linux.fd_t,
    /// Watch descriptor → directory path (owned by `gpa`, shared with the keys of `by_path`)
    by_wd: std.AutoArrayHashMapUnmanaged(i32, [:0]u8) = .empty,
    by_path: std.StringArrayHashMapUnmanaged(i32) = .empty,
    /// Already warned that the limit on the number of watches was reached
    warned: bool = false,
    buf: [64 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined,

    const mask = IN.CLOSE_WRITE | IN.CREATE | IN.DELETE | IN.MOVED_FROM | IN.MOVED_TO |
        IN.DELETE_SELF | IN.MOVE_SELF | IN.ONLYDIR | IN.EXCL_UNLINK;

    fn create(gpa: Allocator, _: Io) error{ OutOfMemory, InotifyUnavailable }!*Inotify {
        const fd_rc = linux.inotify_init1(IN.CLOEXEC | IN.NONBLOCK);
        if (linux.errno(fd_rc) != .SUCCESS) return error.InotifyUnavailable;
        const fd: linux.fd_t = @intCast(fd_rc);
        errdefer _ = linux.close(fd);
        const wake_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(wake_rc) != .SUCCESS) return error.InotifyUnavailable;
        const wake_fd: linux.fd_t = @intCast(wake_rc);
        errdefer _ = linux.close(wake_fd);
        const n = try gpa.create(Inotify);
        n.* = .{ .gpa = gpa, .fd = fd, .wake_fd = wake_fd };
        return n;
    }

    fn destroy(n: *Inotify, gpa: Allocator) void {
        _ = linux.close(n.fd);
        _ = linux.close(n.wake_fd);
        for (n.by_wd.values()) |p| gpa.free(p);
        n.by_wd.deinit(gpa);
        n.by_path.deinit(gpa);
        gpa.destroy(n);
    }

    fn wake(n: *Inotify) void {
        const one: u64 = 1;
        _ = linux.write(n.wake_fd, @ptrCast(&one), @sizeOf(u64));
    }

    fn setDirs(n: *Inotify, gpa: Allocator, dirs: []const []const u8, failed: *std.ArrayList([]const u8)) Allocator.Error!void {
        var want: std.StringHashMapUnmanaged(void) = .empty;
        defer want.deinit(gpa);
        for (dirs) |d| try want.put(gpa, d, {});
        var i = n.by_path.count();
        while (i > 0) {
            i -= 1;
            if (want.contains(n.by_path.keys()[i])) continue;
            const wd = n.by_path.values()[i];
            _ = linux.inotify_rm_watch(n.fd, wd);
            n.forget(wd);
        }
        for (dirs) |d| {
            if (n.by_path.contains(d)) continue;
            const z = try gpa.dupeSentinel(u8, d, 0);
            const rc = linux.inotify_add_watch(n.fd, z, mask);
            const err = linux.errno(rc);
            // Another spelling of the same directory (via a symbolic link): one watch can map to
            // only one path
            const duplicate = err == .SUCCESS and n.by_wd.contains(@intCast(rc));
            if (err != .SUCCESS or duplicate) {
                gpa.free(z);
                if ((err == .NOSPC or err == .NOMEM) and !n.warned) {
                    n.warned = true;
                    log.warn("inotify watch limit reached (fs.inotify.max_user_watches), some directories are checked periodically instead", .{});
                }
                try failed.append(gpa, d);
                continue;
            }
            const wd: i32 = @intCast(rc);
            try n.by_wd.put(gpa, wd, z);
            try n.by_path.put(gpa, z, wd);
        }
    }

    /// Stops tracking watch `wd` (already removed)
    fn forget(n: *Inotify, wd: i32) void {
        const kv = n.by_wd.fetchSwapRemove(wd) orelse return;
        _ = n.by_path.swapRemove(kv.value);
        n.gpa.free(kv.value);
    }

    fn wait(n: *Inotify, timeout_ns: ?u64) void {
        var fds = [_]std.posix.pollfd{
            .{ .fd = n.fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = n.wake_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ms: i32 = if (timeout_ns) |ns| @intCast(@min(ns / std.time.ns_per_ms, std.math.maxInt(i32))) else -1;
        _ = std.posix.poll(&fds, ms) catch {};
    }

    fn drain(n: *Inotify, a: Allocator, out: *std.ArrayList(Event)) Allocator.Error!void {
        var counter: u64 = undefined;
        _ = linux.read(n.wake_fd, @ptrCast(&counter), @sizeOf(u64));
        while (true) {
            const rc = linux.read(n.fd, &n.buf, n.buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return,
            }
            var offset: usize = 0;
            while (offset + @sizeOf(linux.inotify_event) <= rc) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&n.buf[offset]));
                offset += @sizeOf(linux.inotify_event) + ev.len;
                try n.event(a, ev, out);
            }
        }
    }

    fn event(n: *Inotify, a: Allocator, ev: *const linux.inotify_event, out: *std.ArrayList(Event)) Allocator.Error!void {
        if (ev.mask & IN.Q_OVERFLOW != 0) return out.append(a, .{ .path = "", .kind = .overflow });
        const dir = n.by_wd.get(ev.wd) orelse return;
        if (ev.getName()) |name| {
            const is_dir = ev.mask & IN.ISDIR != 0;
            const kind: Event.Kind = if (ev.mask & (IN.CREATE | IN.MOVED_TO) != 0)
                (if (is_dir) .dir_created else .created)
            else if (ev.mask & (IN.DELETE | IN.MOVED_FROM) != 0)
                (if (is_dir) .dir_gone else .removed)
            else
                .changed;
            return out.append(a, .{ .path = try std.fs.path.join(a, &.{ dir, name }), .kind = kind });
        }
        // The watched directory itself was deleted or moved away (later notifications follow the
        // inode, so the path is no longer right), or its file system was unmounted
        if (ev.mask & (IN.DELETE_SELF | IN.MOVE_SELF | IN.IGNORED | IN.UNMOUNT) == 0) return;
        try out.append(a, .{ .path = try a.dupe(u8, dir), .kind = .dir_gone });
        if (ev.mask & IN.IGNORED == 0) _ = linux.inotify_rm_watch(n.fd, ev.wd);
        n.forget(ev.wd);
    }
};

/// `path` is the directory `dir` itself or lies under it (POSIX paths)
fn underPosix(path: []const u8, dir: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir)) return false;
    return path.len == dir.len or path[dir.len] == '/' or std.mem.eql(u8, dir, "/");
}

/// Watch roots whose real path differs from the written path: FSEvents reports real paths, which
/// are mapped back to the written form. Independent of the platform's notifications.
const RootAliases = struct {
    list: std.ArrayList(Alias) = .empty,

    const Alias = struct {
        /// Owned by `gpa`; allocated with its sentinel (`realPathFileAlloc`), and freed as such
        real: [:0]u8,
        /// Borrowed from the roots passed to `set`
        written: []const u8,
    };

    fn deinit(r: *RootAliases, gpa: Allocator) void {
        r.clear(gpa);
        r.list.deinit(gpa);
    }

    fn clear(r: *RootAliases, gpa: Allocator) void {
        for (r.list.items) |al| gpa.free(al.real);
        r.list.clearRetainingCapacity();
    }

    /// Replaces the aliases with those of `roots`, which must outlive them; a root whose real
    /// path cannot be determined is taken as written
    fn set(r: *RootAliases, gpa: Allocator, io: Io, roots: []const [:0]const u8) Allocator.Error!void {
        r.clear(gpa);
        for (roots) |root| {
            const real = Io.Dir.cwd().realPathFileAlloc(io, root, gpa) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            if (std.mem.eql(u8, real, root)) {
                gpa.free(real);
                continue;
            }
            r.list.append(gpa, .{ .real = real, .written = root }) catch |err| {
                gpa.free(real);
                return err;
            };
        }
    }

    /// Maps a real path back to the written form of its watch root (allocated in `a`)
    fn written(r: *const RootAliases, a: Allocator, path: []const u8) Allocator.Error![]const u8 {
        for (r.list.items) |al| if (underPosix(path, al.real)) {
            return std.mem.concat(a, u8, &.{ al.written, path[al.real.len..] });
        };
        return a.dupe(u8, path);
    }
};

/// macOS: FSEvents (recursive watching, managed by a system service). CoreServices is loaded
/// dynamically, with no dependency on the SDK; callbacks run on a serial queue created by this
/// backend, the received changes are buffered on that queue, and the background task takes them
/// via `dispatch_sync`.
const FsEvents = struct {
    const dispatch = std.c.dispatch;

    gpa: Allocator,
    io: Io,
    lib: std.DynLib,
    sym: Symbols,
    queue: dispatch.queue_t,
    sem: dispatch.semaphore_t,
    stream: ?FSEventStreamRef = null,
    cf_paths: []?CFStringRef = &.{},
    cf_array: ?CFArrayRef = null,
    /// Current watch roots (owned by `gpa`)
    roots: std.ArrayList([:0]u8) = .empty,
    /// Real paths of the watch roots (FSEvents reports real paths)
    aliases: RootAliases = .{},
    /// Changes received by the callback and not yet taken (accessed only on `queue`; paths are
    /// owned by `gpa`)
    queued: std.ArrayList(Event) = .empty,

    /// FSEvents has an undocumented limit on the number of watched paths (reportedly 4096)
    const max_roots = 2048;

    const Symbols = struct {
        FSEventStreamCreate: *const fn (
            allocator: ?*const anyopaque,
            callback: *const fn (ConstFSEventStreamRef, ?*anyopaque, usize, *anyopaque, [*]const EventFlags, [*]const u64) callconv(.c) void,
            ctx: ?*const StreamContext,
            paths_to_watch: CFArrayRef,
            since_when: u64,
            latency: f64,
            flags: CreateFlags,
        ) callconv(.c) ?FSEventStreamRef,
        FSEventStreamSetDispatchQueue: *const fn (stream: FSEventStreamRef, queue: dispatch.queue_t) callconv(.c) void,
        FSEventStreamStart: *const fn (stream: FSEventStreamRef) callconv(.c) bool,
        FSEventStreamStop: *const fn (stream: FSEventStreamRef) callconv(.c) void,
        FSEventStreamInvalidate: *const fn (stream: FSEventStreamRef) callconv(.c) void,
        FSEventStreamRelease: *const fn (stream: FSEventStreamRef) callconv(.c) void,
        CFRelease: *const fn (cf: *const anyopaque) callconv(.c) void,
        CFArrayCreate: *const fn (allocator: ?*const anyopaque, values: [*]const ?CFStringRef, num_values: isize, call_backs: ?*const anyopaque) callconv(.c) ?CFArrayRef,
        CFStringCreateWithCString: *const fn (allocator: ?*const anyopaque, c_str: [*:0]const u8, encoding: u32) callconv(.c) ?CFStringRef,
    };

    const CFStringRef = *const opaque {};
    const CFArrayRef = *const opaque {};
    const FSEventStreamRef = *opaque {};
    const ConstFSEventStreamRef = *const opaque {};
    const cf_string_encoding_utf8 = 0x08000100;
    const since_now = std.math.maxInt(u64);

    const StreamContext = extern struct {
        version: isize = 0,
        info: ?*anyopaque,
        retain: ?*const anyopaque = null,
        release: ?*const anyopaque = null,
        copy_description: ?*const anyopaque = null,
    };

    const CreateFlags = packed struct(u32) {
        use_cf_types: bool = false,
        no_defer: bool = false,
        watch_root: bool = false,
        ignore_self: bool = false,
        file_events: bool = false,
        _: u27 = 0,
    };

    const EventFlags = packed struct(u32) {
        must_scan_sub_dirs: bool,
        user_dropped: bool,
        kernel_dropped: bool,
        event_ids_wrapped: bool,
        history_done: bool,
        root_changed: bool,
        mount: bool,
        unmount: bool,
        item_created: bool,
        item_removed: bool,
        item_inode_meta_mod: bool,
        item_renamed: bool,
        item_modified: bool,
        item_finder_info_mod: bool,
        item_change_owner: bool,
        item_xattr_mod: bool,
        item_is_file: bool,
        item_is_dir: bool,
        item_is_symlink: bool,
        _: u13,
    };

    fn create(gpa: Allocator, io: Io) error{ OutOfMemory, OpenFrameworkFailed, MissingSymbol, SystemResources }!*FsEvents {
        var lib = std.DynLib.open("/System/Library/Frameworks/CoreServices.framework/CoreServices") catch return error.OpenFrameworkFailed;
        errdefer lib.close();
        var sym: Symbols = undefined;
        inline for (@typeInfo(Symbols).@"struct".field_names, @typeInfo(Symbols).@"struct".field_types) |name, T| {
            @field(sym, name) = lib.lookup(T, name) orelse return error.MissingSymbol;
        }
        const sem = dispatch.semaphore_create(0) orelse return error.SystemResources;
        errdefer sem.as_object().release();
        const queue = dispatch.queue_create("zig-analyzer-watch", .SERIAL()) orelse return error.SystemResources;
        errdefer queue.as_object().release();
        const f = try gpa.create(FsEvents);
        f.* = .{ .gpa = gpa, .io = io, .lib = lib, .sym = sym, .queue = queue, .sem = sem };
        return f;
    }

    fn destroy(f: *FsEvents, gpa: Allocator) void {
        f.stopStream();
        f.clearRoots();
        f.roots.deinit(gpa);
        f.aliases.deinit(gpa);
        for (f.queued.items) |e| gpa.free(e.path);
        f.queued.deinit(gpa);
        f.queue.as_object().release();
        f.sem.as_object().release();
        f.lib.close();
        gpa.destroy(f);
    }

    fn wake(f: *FsEvents) void {
        _ = f.sem.signal();
    }

    fn wait(f: *FsEvents, timeout_ns: ?u64) void {
        const when: dispatch.time_t = if (timeout_ns) |ns| .time(.NOW, @intCast(@min(ns, std.math.maxInt(i64)))) else .FOREVER;
        _ = f.sem.wait(when);
    }

    fn setDirs(f: *FsEvents, gpa: Allocator, dirs: []const []const u8, failed: *std.ArrayList([]const u8)) Allocator.Error!void {
        // Of nested directories, keep only the outermost: watching is recursive
        const sorted = try gpa.dupe([]const u8, dirs);
        defer gpa.free(sorted);
        std.mem.sort([]const u8, sorted, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        var roots: std.ArrayList([]const u8) = .empty;
        defer roots.deinit(gpa);
        for (sorted) |d| {
            if (roots.items.len != 0 and underPosix(d, roots.items[roots.items.len - 1])) continue;
            try roots.append(gpa, d);
        }
        // With too many directories, watch the whole file system: expensive, but still native
        // notifications
        if (roots.items.len > max_roots) {
            roots.clearRetainingCapacity();
            try roots.append(gpa, "/");
        }
        if (roots.items.len == f.roots.items.len) {
            for (roots.items, f.roots.items) |x, y| {
                if (!std.mem.eql(u8, x, y)) break;
            } else return;
        }

        f.stopStream();
        f.clearRoots();
        for (roots.items) |r| try f.roots.append(gpa, try gpa.dupeSentinel(u8, r, 0));
        try f.aliases.set(gpa, f.io, f.roots.items);
        if (f.roots.items.len == 0) return;
        f.startStream() catch {
            log.warn("cannot start FSEvents stream, checking files on disk periodically instead", .{});
            try failed.appendSlice(gpa, dirs);
        };
    }

    fn startStream(f: *FsEvents) error{ OutOfMemory, StartFailed }!void {
        const s = f.sym;
        f.cf_paths = try f.gpa.alloc(?CFStringRef, f.roots.items.len);
        @memset(f.cf_paths, null);
        for (f.roots.items, f.cf_paths) |r, *p| p.* = s.CFStringCreateWithCString(null, r.ptr, cf_string_encoding_utf8) orelse return error.OutOfMemory;
        f.cf_array = s.CFArrayCreate(null, f.cf_paths.ptr, @intCast(f.cf_paths.len), null) orelse return error.OutOfMemory;
        const ctx: StreamContext = .{ .info = f };
        const stream = s.FSEventStreamCreate(null, callback, &ctx, f.cf_array.?, since_now, @as(f64, debounce_ms) / 1000.0, .{
            .watch_root = true,
            .file_events = true,
        }) orelse return error.StartFailed;
        s.FSEventStreamSetDispatchQueue(stream, f.queue);
        if (!s.FSEventStreamStart(stream)) {
            s.FSEventStreamInvalidate(stream);
            s.FSEventStreamRelease(stream);
            return error.StartFailed;
        }
        f.stream = stream;
    }

    fn stopStream(f: *FsEvents) void {
        const s = f.sym;
        if (f.stream) |stream| {
            s.FSEventStreamStop(stream);
            s.FSEventStreamInvalidate(stream);
            s.FSEventStreamRelease(stream);
            f.stream = null;
        }
        if (f.cf_array) |arr| s.CFRelease(arr);
        f.cf_array = null;
        for (f.cf_paths) |p| if (p) |x| s.CFRelease(x);
        f.gpa.free(f.cf_paths);
        f.cf_paths = &.{};
    }

    fn clearRoots(f: *FsEvents) void {
        f.aliases.clear(f.gpa);
        for (f.roots.items) |r| f.gpa.free(r);
        f.roots.clearRetainingCapacity();
    }

    fn callback(
        _: ConstFSEventStreamRef,
        info: ?*anyopaque,
        count: usize,
        paths_ptr: *anyopaque,
        flags_ptr: [*]const EventFlags,
        _: [*]const u64,
    ) callconv(.c) void {
        const f: *FsEvents = @ptrCast(@alignCast(info));
        const paths: [*]const [*:0]const u8 = @ptrCast(@alignCast(paths_ptr));
        for (paths[0..count], flags_ptr[0..count]) |p, fl| {
            if (fl.history_done) continue;
            const kind: Event.Kind = if (fl.must_scan_sub_dirs or fl.user_dropped or fl.kernel_dropped)
                .overflow
            else if (fl.root_changed)
                .dir_gone
            else if (fl.item_is_dir)
                (if (fl.item_removed) .dir_gone else if (fl.item_created or fl.item_renamed) .dir_created else continue)
            else if (fl.item_created and !fl.item_removed)
                .created
            else
                .changed;
            const path = f.gpa.dupe(u8, std.mem.span(p)) catch continue;
            f.queued.append(f.gpa, .{ .path = path, .kind = kind }) catch f.gpa.free(path);
        }
        _ = f.sem.signal();
    }

    fn drain(f: *FsEvents, a: Allocator, out: *std.ArrayList(Event)) Allocator.Error!void {
        const Take = struct {
            f: *FsEvents,
            taken: std.ArrayList(Event) = .empty,
            fn run(ctx: ?*anyopaque) callconv(.c) void {
                const t: *@This() = @ptrCast(@alignCast(ctx));
                t.taken = t.f.queued;
                t.f.queued = .empty;
            }
        };
        var take: Take = .{ .f = f };
        dispatch.sync_f(f.queue, &take, Take.run);
        defer {
            for (take.taken.items) |e| f.gpa.free(e.path);
            take.taken.deinit(f.gpa);
        }
        for (take.taken.items) |e| try out.append(a, .{ .path = try f.aliases.written(a, e.path), .kind = e.kind });
    }
};

/// Windows: change notifications for individual directories (non-recursive). A completed
/// notification is delivered as an APC to the thread that issued it (the background task) and
/// runs during an alertable wait; an event object is used for waking up.
const DirNotify = struct {
    const windows = std.os.windows;

    gpa: Allocator,
    wake_event: windows.HANDLE,
    dirs: std.StringArrayHashMapUnmanaged(*Directory) = .empty,
    /// Directories whose notification has completed and awaits handling (added in the APC)
    ready: std.DoublyLinkedList = .{},

    const Directory = struct {
        path: []u8,
        handle: windows.HANDLE,
        state: enum { idle, listening, ready } = .idle,
        iosb: windows.IO_STATUS_BLOCK = undefined,
        /// A single notification for a directory on the network is at most 64 KB
        buffer: [64 * 1024]u8 align(@alignOf(windows.FILE.NOTIFY.INFORMATION)) = undefined,
        ready_node: std.DoublyLinkedList.Node = .{},
    };

    fn create(gpa: Allocator, _: Io) error{ OutOfMemory, SystemResources }!*DirNotify {
        var event: windows.HANDLE = undefined;
        switch (windows.ntdll.NtCreateEvent(&event, windows.ACCESS_MASK.Specific.Event.ALL_ACCESS, null, .Synchronization, .FALSE)) {
            .SUCCESS => {},
            else => return error.SystemResources,
        }
        errdefer windows.CloseHandle(event);
        const d = try gpa.create(DirNotify);
        d.* = .{ .gpa = gpa, .wake_event = event };
        return d;
    }

    fn destroy(d: *DirNotify, gpa: Allocator) void {
        for (d.dirs.values()) |dir| d.close(dir);
        d.dirs.deinit(gpa);
        windows.CloseHandle(d.wake_event);
        gpa.destroy(d);
    }

    fn wake(d: *DirNotify) void {
        _ = windows.ntdll.NtSetEvent(d.wake_event, null);
    }

    fn wait(d: *DirNotify, timeout_ns: ?u64) void {
        if (timeout_ns) |ns| {
            const interval: windows.LARGE_INTEGER = -@as(windows.LARGE_INTEGER, @intCast(@min(ns / 100, std.math.maxInt(i63))));
            _ = windows.ntdll.NtWaitForSingleObject(d.wake_event, .TRUE, &interval);
        } else {
            _ = windows.ntdll.NtWaitForSingleObject(d.wake_event, .TRUE, null);
        }
    }

    fn setDirs(d: *DirNotify, gpa: Allocator, dirs: []const []const u8, failed: *std.ArrayList([]const u8)) Allocator.Error!void {
        var want: std.StringHashMapUnmanaged(void) = .empty;
        defer want.deinit(gpa);
        for (dirs) |p| try want.put(gpa, p, {});
        var i = d.dirs.count();
        while (i > 0) {
            i -= 1;
            if (want.contains(d.dirs.keys()[i])) continue;
            const dir = d.dirs.values()[i];
            d.dirs.swapRemoveAt(i);
            d.close(dir);
        }
        for (dirs) |p| {
            if (d.dirs.contains(p)) continue;
            const dir = d.open(p) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try failed.append(gpa, p);
                    continue;
                },
            };
            d.dirs.put(gpa, dir.path, dir) catch |err| {
                d.close(dir);
                return err;
            };
        }
    }

    fn open(d: *DirNotify, path: []const u8) !*Directory {
        const path_w = try std.Io.Threaded.sliceToPrefixedFileW(null, path, .{});
        var handle: windows.HANDLE = undefined;
        var iosb: windows.IO_STATUS_BLOCK = undefined;
        switch (windows.ntdll.NtCreateFile(
            &handle,
            .{
                .SPECIFIC = .{ .FILE_DIRECTORY = .{ .LIST = true } },
                .STANDARD = .{ .SYNCHRONIZE = true },
                .GENERIC = .{ .READ = true },
            },
            &.{ .RootDirectory = null, .ObjectName = @constCast(&path_w.string()) },
            &iosb,
            null,
            .{},
            .VALID_FLAGS,
            .OPEN,
            .{ .DIRECTORY_FILE = true, .IO = .ASYNCHRONOUS, .OPEN_FOR_BACKUP_INTENT = true },
            null,
            0,
        )) {
            .SUCCESS => {},
            else => return error.CannotOpenDirectory,
        }
        errdefer windows.CloseHandle(handle);
        const dir = try d.gpa.create(Directory);
        errdefer d.gpa.destroy(dir);
        dir.* = .{ .path = try d.gpa.dupe(u8, path), .handle = handle };
        errdefer d.gpa.free(dir.path);
        try d.listen(dir);
        return dir;
    }

    fn listen(d: *DirNotify, dir: *Directory) !void {
        switch (windows.ntdll.NtNotifyChangeDirectoryFileEx(
            dir.handle,
            null,
            &notifyApc,
            d,
            &dir.iosb,
            &dir.buffer,
            dir.buffer.len,
            .{ .FILE_NAME = true, .DIR_NAME = true, .SIZE = true, .LAST_WRITE = true, .CREATION = true },
            .FALSE,
            .Notify,
        )) {
            .SUCCESS, .PENDING => dir.state = .listening,
            else => return error.CannotWatchDirectory,
        }
    }

    fn notifyApc(context: ?*anyopaque, iosb: *windows.IO_STATUS_BLOCK, _: windows.ULONG) align(std.Io.Threaded.apc_align) callconv(.winapi) void {
        const d: *DirNotify = @ptrCast(@alignCast(context));
        const dir: *Directory = @fieldParentPtr("iosb", iosb);
        d.ready.append(&dir.ready_node);
        dir.state = .ready;
    }

    /// Cancels the in-progress notification and closes the directory after its APC has run
    fn close(d: *DirNotify, dir: *Directory) void {
        if (dir.state == .listening) {
            var cancel_iosb: windows.IO_STATUS_BLOCK = undefined;
            _ = windows.ntdll.NtCancelIoFileEx(dir.handle, &dir.iosb, &cancel_iosb);
            while (dir.state == .listening) std.Io.Threaded.waitForApcOrAlert();
        }
        if (dir.state == .ready) d.ready.remove(&dir.ready_node);
        windows.CloseHandle(dir.handle);
        d.gpa.free(dir.path);
        d.gpa.destroy(dir);
    }

    fn drain(d: *DirNotify, a: Allocator, out: *std.ArrayList(Event)) Allocator.Error!void {
        var gone: std.ArrayList(*Directory) = .empty;
        while (d.ready.popFirst()) |node| {
            const dir: *Directory = @fieldParentPtr("ready_node", node);
            dir.state = .idle;
            switch (dir.iosb.u.Status) {
                .SUCCESS => {
                    if (dir.iosb.Information == 0) {
                        try out.append(a, .{ .path = try a.dupe(u8, dir.path), .kind = .overflow });
                    } else try parse(a, dir, out);
                },
                // Too many changes to fit in the buffer
                .NOTIFY_ENUM_DIR => try out.append(a, .{ .path = try a.dupe(u8, dir.path), .kind = .overflow }),
                .CANCELLED => continue,
                // The directory was deleted, etc.: stop watching it; recomputation handles it
                // based on the state at that time
                else => {
                    try out.append(a, .{ .path = try a.dupe(u8, dir.path), .kind = .dir_gone });
                    try gone.append(a, dir);
                    continue;
                },
            }
            d.listen(dir) catch {
                try out.append(a, .{ .path = try a.dupe(u8, dir.path), .kind = .dir_gone });
                try gone.append(a, dir);
            };
        }
        for (gone.items) |dir| {
            _ = d.dirs.swapRemove(dir.path);
            d.close(dir);
        }
    }

    fn parse(a: Allocator, dir: *Directory, out: *std.ArrayList(Event)) Allocator.Error!void {
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        var offset: usize = 0;
        while (true) {
            const info: *windows.FILE.NOTIFY.INFORMATION = @ptrCast(@alignCast(&dir.buffer[offset]));
            const name = name_buf[0..std.unicode.wtf16LeToWtf8(&name_buf, info.fileName())];
            const kind: Event.Kind = switch (info.Action) {
                1, 5 => .created, // created, or the new name after a rename
                2, 4 => .removed, // deleted, or the old name before a rename
                else => .changed,
            };
            try out.append(a, .{ .path = try std.fs.path.join(a, &.{ dir.path, name }), .kind = kind });
            if (info.NextEntryOffset == 0) break;
            offset += info.NextEntryOffset;
        }
    }
};

const testing = std.testing;

test "poller: changes, creation and deletion after the first check" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const a_path = try std.fs.path.join(testing.allocator, &.{ dir, "a.zig" });
    defer testing.allocator.free(a_path);
    const b_path = try std.fs.path.join(testing.allocator, &.{ dir, "b.zig" });
    defer testing.allocator.free(b_path);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "a" });

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var poller: Poller = .{ .gpa = testing.allocator };
    defer poller.deinit();
    var pending: Pending = .{};
    const paths = [_][]const u8{ a_path, b_path };
    try poller.poll(testing.io, arena.allocator(), &paths, &pending);
    try testing.expectEqual(0, pending.paths.count());

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "aa" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.zig", .data = "b" });
    try poller.poll(testing.io, arena.allocator(), &paths, &pending);
    try testing.expectEqual(Pending.Hint.changed, pending.paths.get(a_path).?);
    try testing.expectEqual(Pending.Hint.created, pending.paths.get(b_path).?);
}

// Prevents pending changes from borrowing the paths of files of interest: when the files of
// interest are recomputed within the same batch, the arena holding those paths is freed
test "pending changes keep their own copies of the paths" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var source = "/p/build.zig".*;
    var pending: Pending = .{};
    try pending.add(arena.allocator(), &source, .changed);
    try pending.add(arena.allocator(), &source, .created);
    @memset(&source, 'x');
    try testing.expectEqualStrings("/p/build.zig", pending.paths.keys()[0]);
    try testing.expectEqual(Pending.Hint.created, pending.paths.values()[0]);
}

test "under any: a path is under one of the directories, or is one of them" {
    const native = @import("../util/test_path.zig").native;
    var dirs: std.StringHashMapUnmanaged(void) = .empty;
    defer dirs.deinit(testing.allocator);
    try dirs.put(testing.allocator, native("/p/src"), {});
    try testing.expect(underAny(native("/p/src/a.zig"), &dirs));
    try testing.expect(underAny(native("/p/src/sub/b.zig"), &dirs));
    try testing.expect(underAny(native("/p/src"), &dirs));
    try testing.expect(!underAny(native("/p/srcx/a.zig"), &dirs));
    try testing.expect(!underAny(native("/p/a.zig"), &dirs));
}

/// Waits until every path in `paths` has been reported (within 10 seconds)
fn expectReported(n: *Native, a: Allocator, paths: []const []const u8) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var events: std.ArrayList(Event) = .empty;
    const deadline = Io.Clock.awake.now(testing.io).addDuration(.fromSeconds(10));
    while (seen.count() < paths.len) {
        if (Io.Clock.awake.now(testing.io).durationTo(deadline).nanoseconds <= 0) return error.Timeout;
        n.wait(std.time.ns_per_s);
        events.clearRetainingCapacity();
        try n.drain(a, &events);
        for (events.items) |e| for (paths) |p| {
            if (std.mem.eql(u8, e.path, p)) try seen.put(a, p, {});
        };
    }
}

test "native watching reports changes, creation and removal in watched directories" {
    if (Native == Unsupported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "a" });

    const n = try Native.create(testing.allocator, testing.io);
    defer n.destroy(testing.allocator);
    var failed: std.ArrayList([]const u8) = .empty;
    defer failed.deinit(testing.allocator);
    try n.setDirs(testing.allocator, &.{dir}, &failed);
    try testing.expectEqual(0, failed.items.len);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const a_path = try std.fs.path.join(a, &.{ dir, "a.zig" });
    const b_path = try std.fs.path.join(a, &.{ dir, "b.zig" });

    // Rewrite a.zig and create b.zig: both are reported (FSEvents merges multiple changes of the
    // same file, so the kind is only a hint; the state at handling time decides)
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "aa" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.zig", .data = "b" });
    try expectReported(n, a, &.{ a_path, b_path });
    // Delete a.zig
    try tmp.dir.deleteFile(testing.io, "a.zig");
    try expectReported(n, a, &.{a_path});

    // Wake: returns even without notifications
    n.wake();
    n.wait(null);
    var events: std.ArrayList(Event) = .empty;
    try n.drain(a, &events);
}

// Prevents freeing the real path of an aliased watch root without its sentinel: the allocator
// rejects the size mismatch
test "root aliases map real paths back to the written roots and free them as allocated" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "real");
    try tmp.dir.symLink(testing.io, "real", "link", .{ .is_directory = true });
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const link = try std.fs.path.joinZ(a, &.{ dir, "link" });
    const real = try std.fs.path.join(a, &.{ dir, "real" });

    var aliases: RootAliases = .{};
    defer aliases.deinit(testing.allocator);
    try aliases.set(testing.allocator, testing.io, &.{link});
    try testing.expectEqual(1, aliases.list.items.len);
    try testing.expectEqualStrings(
        try std.fs.path.join(a, &.{ link, "a.zig" }),
        try aliases.written(a, try std.fs.path.join(a, &.{ real, "a.zig" })),
    );
    try aliases.set(testing.allocator, testing.io, &.{});
    try testing.expectEqual(0, aliases.list.items.len);
    try aliases.set(testing.allocator, testing.io, &.{link});
}

test "FSEvents: watch roots reached through a symbolic link are replaced and freed cleanly" {
    if (Native != FsEvents) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "real");
    try tmp.dir.symLink(testing.io, "real", "link", .{ .is_directory = true });
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const link = try std.fs.path.join(testing.allocator, &.{ dir, "link" });
    defer testing.allocator.free(link);

    const n = try Native.create(testing.allocator, testing.io);
    defer n.destroy(testing.allocator);
    var failed: std.ArrayList([]const u8) = .empty;
    defer failed.deinit(testing.allocator);
    try n.setDirs(testing.allocator, &.{link}, &failed);
    try n.setDirs(testing.allocator, &.{}, &failed);
    try n.setDirs(testing.allocator, &.{link}, &failed);
    try testing.expectEqual(0, failed.items.len);
}
