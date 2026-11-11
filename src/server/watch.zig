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
//! take precedence, but builds read the disk. A notification may name a file of interest under
//! another spelling (see `Spellings`): it counts for that file.
//!
//! The directories containing these files are watched with the operating system's native
//! notifications: inotify on Linux, FSEvents on macOS, directory change notifications on Windows.
//! A directory that does not exist yet is watched through its nearest existing ancestor; once it
//! appears, it is watched itself, and files of interest already in it are treated as created. The
//! directories to watch are recomputed when new files are interned, roots are added or removed,
//! directories are created or deleted, or notifications are lost. Source files created in watched
//! directories that are not files of interest yet, and directories created or deleted, make the
//! server scan the root directories for source files again (see `Server.scheduleScan`).
//! A file becomes of interest when it is interned, and the server may read it before this task
//! watches it: once it is watched, its known text is compared with the disk, so a change in
//! between is not lost. A file still being read then, or when a change to it is notified, is
//! compared once the read is done: what the read gets is not known before.
//!
//! When the server watches the root directories too, source files created anywhere the workspace
//! scan walks must be noticed (see `workspace_files`), also in directories without files of
//! interest. FSEvents and Windows watch each root with its subdirectories; inotify watches each
//! directory on its own, so every directory the last scan entered is watched as well (see
//! `scanned`). A directory created or moved in makes the server scan again, which walks it and
//! hands it over to be watched; a source file created in it before that is found by a scan that
//! starts after the watch (see `epoch`).
//!
//! Polling (periodically checking size and modification time) is only the last resort: when
//! native notifications are unavailable (other platforms, initialization failure), or some
//! directories exceed the limit on the number of watches, only the files in those directories are
//! polled, and the modification times of the directories the scan entered.

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
const origin = @import("origin.zig");
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
/// A file being read from disk when it was to be compared with the disk is compared again after
/// this long
const reverify_ms = 10;

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
    /// Test hook (null outside tests): the background task stops before its next round until the
    /// pause is released, so that a test can change files before the task gets to them
    test_pause: std.atomic.Value(?*TestPause) = .init(null),
    /// Test hook (null outside tests): the background task stops before it hands a batch of
    /// changes to the server (which takes `Server.write_mutex`) until the pause is released
    test_apply_pause: std.atomic.Value(?*TestPause) = .init(null),
    /// Incremented by the background task whenever it starts watching a directory it did not
    /// watch before, natively or by polling: a scan that started walking before then may have
    /// missed a source file created in that directory before the watch (see `scanned`)
    epoch: std.atomic.Value(u64) = .init(0),

    // ── Workspace scans handed over by `scanned`, protected by `scan_mutex` ──
    scan_mutex: Io.Mutex = .init,
    /// Arena holding `scan_dirs`; replaced as a whole by each scan
    scan_arena: std.heap.ArenaAllocator,
    /// The directories the last scan entered, kept when the backend does not watch
    /// subdirectories (see `Backend.recursive`)
    scan_dirs: []const []const u8 = &.{},
    /// The value of `epoch` when the last scan not yet handled by the background task started
    /// walking; null when there is none
    scan_epoch: ?u64 = null,
    /// `Server.busyBegin` was called for that scan: the server is not idle until the background
    /// task has handled it, or until `closeScan`
    scan_held: bool = false,
    /// The background task has ended or the server is shutting down (see `closeScan`): scans
    /// are no longer held
    scan_closed: bool = false,

    // ── The following fields are accessed only by the background task ──
    /// What is being watched (see `Server.WatchScope`); `.none` while not watching
    scope: Server.WatchScope = .none,
    /// The scope seen in the previous round of `run`; null before the first round
    last_scope: ?Server.WatchScope = null,
    /// The scope has widened: the files of interest are compared with the disk once recomputed
    verify: bool = false,
    /// Arena holding `files` and `missing`; replaced as a whole on recomputation
    state_arena: std.heap.ArenaAllocator,
    /// Files of interest: identity key (lowercased when case-insensitive) → path
    files: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// Other spellings of files of interest seen in notifications; reset along with `files`
    spellings: Spellings = .{},
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
    /// Directories the last scan entered that cannot be watched: their modification times are
    /// polled, and a change makes the server scan again (paths are in `state_arena`)
    fallback_dirs: std.ArrayList([]const u8) = .empty,
    dir_poller: Poller,
    /// Already warned that a root directory cannot be watched with its subdirectories
    tree_warned: bool = false,
    /// Other files additionally registered by file name when the client detects external changes
    /// (`registerClientGlobs`); keys are allocated by `gpa`
    client_names: std.StringHashMapUnmanaged(void) = .empty,
    client_registrations: u32 = 0,
    /// Classification of the interned files (see `classify`)
    classes: Classes,
    /// Duration of the last poll (see `min_idle_factor`)
    poll_ns: i96 = 0,
    next_poll: ?Io.Timestamp = null,
    /// Files to compare with the disk again: they were being read from disk when compared (see
    /// `Server.ChangeSource`); allocated by `gpa`
    reverify: std.ArrayList([]u8) = .empty,

    /// Ids of the requests sent by `registerClientGlobs` start with this
    pub const registration_prefix = "zig-analyzer/didChangeWatchedFiles/";

    /// See `test_pause`
    pub const TestPause = struct {
        /// Set when the background task has stopped
        entered: Io.Event = .unset,
        release: Io.Event = .unset,
    };

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
            .scan_arena = .init(gpa),
            .classes = .{ .arena = .init(gpa) },
            .poller = .{ .gpa = gpa },
            .dir_poller = .{ .gpa = gpa, .dirs = true },
        };
        return w;
    }

    /// Called after the background task ends
    pub fn destroy(w: *Watcher) void {
        var names = w.client_names.keyIterator();
        while (names.next()) |k| w.gpa.free(k.*);
        w.client_names.deinit(w.gpa);
        w.classes.deinit(w.gpa);
        w.backend.destroy(w.gpa);
        w.fallback.deinit(w.gpa);
        w.fallback_dirs.deinit(w.gpa);
        w.files.deinit(w.gpa);
        w.spellings.deinit(w.gpa);
        w.missing.deinit(w.gpa);
        w.entry_dirs.deinit(w.gpa);
        w.state_arena.deinit();
        w.scan_arena.deinit();
        w.poller.deinit();
        w.clearReverify();
        w.reverify.deinit(w.gpa);
        w.dir_poller.deinit();
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

    /// The current value of `epoch`: read by a workspace scan before it starts walking
    pub fn watchEpoch(w: *Watcher) u64 {
        return w.epoch.load(.acquire);
    }

    /// A workspace scan that started walking at `epoch` (see `watchEpoch`) entered `dirs`. When
    /// the background task has started watching a directory since, a source file created there
    /// before the watch was neither found nor notified: the server scans again. The server is
    /// busy until the background task has handled this, so that a client waiting for the server
    /// to be idle sees the result of that scan. Called from any thread.
    ///
    /// The background task may be waiting for `Server.write_mutex` (see `apply`) when this is
    /// called, and releases the hold only after it got the mutex: whoever waits for the server
    /// to be idle while holding that mutex (shutdown) calls `closeScan` first.
    pub fn scanned(w: *Watcher, dirs: []const []const u8, epoch: u64) void {
        const server = w.server;
        {
            w.scan_mutex.lockUncancelable(server.io);
            defer w.scan_mutex.unlock(server.io);
            if (w.scan_closed) return;
            if (!w.backend.recursive()) {
                var next: std.heap.ArenaAllocator = .init(w.gpa);
                if (dupePaths(next.allocator(), dirs)) |copy| {
                    w.scan_arena.deinit();
                    w.scan_arena = next;
                    w.scan_dirs = copy;
                } else |err| switch (err) {
                    error.OutOfMemory => {
                        next.deinit();
                        log.err("out of memory while recording the directories to watch", .{});
                    },
                }
            }
            w.scan_epoch = epoch;
            if (!w.scan_held) {
                w.scan_held = true;
                server.busyBegin();
            }
        }
        w.requestResync();
    }

    /// What `scanned` handed over and the background task has not handled yet
    const Scan = struct {
        /// The directories the last scan entered (see `scan_dirs`)
        dirs: []const []const u8,
        epoch: ?u64,
        held: bool,
    };

    /// Takes the scan to handle, with the directories copied into `a`; the caller calls
    /// `Server.busyEnd` when it is `held`
    fn takeScan(w: *Watcher, a: Allocator) Allocator.Error!Scan {
        w.scan_mutex.lockUncancelable(w.server.io);
        defer w.scan_mutex.unlock(w.server.io);
        const s: Scan = .{ .dirs = try dupePaths(a, w.scan_dirs), .epoch = w.scan_epoch, .held = w.scan_held };
        w.scan_epoch = null;
        w.scan_held = false;
        return s;
    }

    /// Drops the scan to handle while nothing is watched
    fn dropScan(w: *Watcher) void {
        w.scan_mutex.lockUncancelable(w.server.io);
        const held = w.scan_held;
        w.scan_held = false;
        w.scan_epoch = null;
        w.scan_mutex.unlock(w.server.io);
        if (held) w.server.busyEnd();
    }

    /// The background task ends, or the server shuts down and nobody waits for a scan's result:
    /// the scan not handled yet and later scans are not held. Called from any thread.
    pub fn closeScan(w: *Watcher) void {
        {
            w.scan_mutex.lockUncancelable(w.server.io);
            defer w.scan_mutex.unlock(w.server.io);
            w.scan_closed = true;
        }
        w.dropScan();
    }

    fn onNewPath(ctx: *anyopaque) void {
        const w: *Watcher = @ptrCast(@alignCast(ctx));
        // Wake only when the flag goes from false to true: loading a project interns thousands of
        // files in a row
        if (!w.resync_requested.swap(true, .acq_rel)) w.backend.wake();
    }

    fn testPause(w: *Watcher, hook: *std.atomic.Value(?*TestPause)) void {
        if (!builtin.is_test) return;
        const pause = hook.load(.acquire) orelse return;
        const io = w.server.io;
        pause.entered.set(io);
        while (!w.stopping.load(.acquire)) {
            pause.release.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } }) catch continue;
            return;
        }
    }

    /// Background task: ends when the server shuts down
    pub fn run(w: *Watcher) Io.Cancelable!void {
        defer w.closeScan();
        defer w.deactivate();
        while (!w.stopping.load(.acquire)) {
            w.testPause(&w.test_pause);
            const scope = w.server.watchScope();
            // Files the server starts watching may have changed while nobody watched them: they
            // are compared with the disk. At startup, they were all just read.
            if (w.last_scope) |last| if (@backingInt(scope) > @backingInt(last)) {
                w.verify = true;
            };
            w.last_scope = scope;
            if (scope == .none) {
                w.deactivate();
                w.dropScan();
                // Clear first, then check: new files interned during the check wake the task
                // again (see `onNewPath`)
                w.resync_requested.store(false, .release);
                if (w.server.clientWatches()) w.registerClientGlobs() catch |err| switch (err) {
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

    /// The classification of the files interned so far, by FileId (see `Classes`): files
    /// interned since the last call are classified under `rules`, and all of them again when the
    /// rules have changed
    fn classify(w: *Watcher, rules: origin.Rules) Allocator.Error![]const Classes.Class {
        const server = w.server;
        const c = &w.classes;
        if (c.rules == null or !sameRules(c.rules.?, rules)) {
            c.rules = null;
            c.list.clearRetainingCapacity();
            c.globs_done = 0;
            _ = c.arena.reset(.retain_capacity);
            c.rules = try dupeRules(c.arena.allocator(), rules);
        }
        const count = server.vfs.count();
        try c.list.ensureTotalCapacity(w.gpa, count);
        for (c.list.items.len..count) |i| {
            const path = server.vfs.path(@fromBackingInt(@as(u32, @intCast(i))));
            const watchable = server.watchable(rules, path);
            c.list.appendAssumeCapacity(.{ .watchable = watchable, .in_root = watchable and server.vfs.rootOf(rules.roots, path) != null });
        }
        return c.list.items;
    }

    /// When the client detects external changes, the initially registered globs cover only
    /// `.zig` and `.zon`: other interned files (files used by `@embedFile`, configure inputs) are
    /// additionally registered by file name (`**/<file name>`; notifications for other files with
    /// the same name are ignored, since those are not interned), the directories under the root
    /// directories that contain interned files by their name (`**/<name>`: a directory deleted,
    /// moved or renamed is reported by its own path only), and configure input directories by
    /// their name and their entries (`**/<name>`, `**/<name>/*`). A name containing glob special
    /// characters cannot be written as a glob and is not registered. Files handled by an earlier
    /// call under the same rules are skipped: each of their globs is registered already or cannot
    /// be written.
    fn registerClientGlobs(w: *Watcher) Allocator.Error!void {
        const server = w.server;
        var arena: std.heap.ArenaAllocator = .init(w.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const rules = try server.originRules(a);
        const classes = try w.classify(rules);
        var globs: std.ArrayList([]const u8) = .empty;
        var dir_names: std.StringHashMapUnmanaged(void) = .empty;
        for (w.classes.globs_done..classes.len) |i| {
            if (!classes[i].watchable) continue;
            const path = server.vfs.path(@fromBackingInt(@as(u32, @intCast(i))));
            if (classes[i].in_root) {
                const root = server.vfs.rootOf(rules.roots, path).?;
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
        w.classes.globs_done = @intCast(classes.len);
        if (added == 0) return;
        out.writer.writeAll("]}") catch return error.OutOfMemory;
        const options = std.json.parseFromSliceLeaky(std.json.Value, a, out.written(), .{}) catch return error.OutOfMemory;
        w.client_registrations += 1;
        const id = try std.fmt.allocPrint(a, registration_prefix ++ "{d}", .{w.client_registrations});
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
            if (w.verify) {
                w.verify = false;
                for (w.files.keys(), w.files.values()) |k, path| {
                    if (!w.entry_dirs.contains(k)) try pending.add(a, path, .verify);
                }
            }
            if (pending.paths.count() != 0) return w.apply(a, &pending);
        }

        // Wait for notifications; when some files need polling or comparing again, wait at most
        // until then
        var timeout_ns: ?u64 = if (w.next_poll) |at| blk: {
            const left = Io.Clock.awake.now(io).durationTo(at).nanoseconds;
            break :blk if (left <= 0) 0 else @intCast(left);
        } else null;
        if (w.reverify.items.len != 0) timeout_ns = @min(timeout_ns orelse std.math.maxInt(u64), reverify_ms * std.time.ns_per_ms);
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
            // Entries created, removed or renamed in a directory the scan entered
            var dir_changes: Pending = .{};
            try w.dir_poller.poll(io, a, w.fallback_dirs.items, &dir_changes);
            if (dir_changes.paths.count() != 0) w.server.scheduleScan();
            w.poll_ns = start.durationTo(Io.Clock.awake.now(io)).nanoseconds;
            w.schedulePoll();
        };
        for (w.reverify.items) |path| try pending.add(a, path, .verify);
        w.clearReverify();

        // First add watches for newly appeared directories, then read the state of the files:
        // every later change will be notified
        const requested_now = w.resync_requested.swap(false, .acq_rel);
        if (dirs_changed or requested_now) try w.resync(a, w.scope, &pending);
        if (pending.paths.count() != 0) try w.apply(a, &pending);
    }

    /// Stops watching and discards the state; when watching starts again, the files of interest
    /// are compared with the disk (see `verify`)
    fn deactivate(w: *Watcher) void {
        if (w.scope == .none) return;
        w.scope = .none;
        var none: std.ArrayList([]const u8) = .empty;
        _ = w.backend.setDirs(w.gpa, &.{}, &.{}, &none) catch {};
        none.deinit(w.gpa);
        w.files.clearRetainingCapacity();
        w.spellings.reset(w.gpa);
        w.missing.clearRetainingCapacity();
        w.entry_dirs.clearRetainingCapacity();
        w.fallback.clearRetainingCapacity();
        w.fallback_dirs.clearRetainingCapacity();
        _ = w.state_arena.reset(.retain_capacity);
        w.poller.reset();
        w.dir_poller.reset();
        w.next_poll = null;
        w.clearReverify();
    }

    fn clearReverify(w: *Watcher) void {
        for (w.reverify.items) |path| w.gpa.free(path);
        w.reverify.clearRetainingCapacity();
    }

    /// Identity key: consistent with Vfs file identity; lowercased on a case-insensitive volume
    fn key(w: *const Watcher, a: Allocator, path: []const u8) Allocator.Error![]const u8 {
        for (path) |c| {
            if (std.ascii.isUpper(c)) break;
        } else return path;
        if (w.server.vfs.caseOfFile(path) == .sensitive) return path;
        return std.ascii.allocLowerString(a, path);
    }

    /// Recomputes the files of interest and the watched directories for `scope`; with
    /// `.outside_roots`, also registers the client's additional file watchers. Files of interest
    /// that already exist in directories that did not exist before but have appeared now are
    /// recorded in `pending`, and so are the files that were not of interest before, to be
    /// compared with the disk.
    fn resync(w: *Watcher, a: Allocator, scope: Server.WatchScope, pending: *Pending) Allocator.Error!void {
        const server = w.server;
        const gpa = w.gpa;
        if (scope == .outside_roots) try w.registerClientGlobs();
        var next_arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer next_arena.deinit();
        const na = next_arena.allocator();
        const scan = try w.takeScan(na);
        defer if (scan.held) server.busyEnd();

        var files: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        errdefer files.deinit(gpa);
        const rules = try server.originRules(a);
        // With `.outside_roots`, the client watches the files under the root directories
        const outside_only = scope == .outside_roots;
        for (try w.classify(rules), 0..) |class, i| {
            if (!class.watchable) continue;
            if (outside_only and class.in_root) continue;
            const path = server.vfs.path(@fromBackingInt(@as(u32, @intCast(i))));
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
        // Where the workspace scan walks (see `scanned`): the existing roots with their
        // subdirectories when the backend watches those, otherwise the directories the last scan
        // entered, each on its own
        var trees: std.ArrayList([]const u8) = .empty;
        var tree_keys: std.StringHashMapUnmanaged(void) = .empty;
        var scan_watches: std.ArrayList(u32) = .empty;
        if (scope == .all) {
            if (w.backend.recursive()) {
                var roots: std.ArrayList([]const u8) = .empty;
                for (rules.roots) |root| {
                    if (!isDir(server.io, root)) continue;
                    try roots.append(a, root);
                    try tree_keys.put(a, try w.key(a, root), {});
                }
                // A root inside another one is watched with it
                for (roots.items) |root| {
                    if (std.fs.path.dirname(try w.key(a, root))) |parent| if (underAny(parent, &tree_keys)) continue;
                    try trees.append(a, root);
                }
            } else for (scan.dirs) |dir| {
                const gop = try dirs.getOrPut(gpa, try w.key(na, dir));
                if (!gop.found_existing) gop.value_ptr.* = dir;
                try scan_watches.append(a, @intCast(gop.index));
            }
        }
        // The directories under a tree are watched with it
        var own: std.ArrayList([]const u8) = .empty;
        for (dirs.keys(), dirs.values()) |k, dir| {
            if (!underAny(k, &tree_keys)) try own.append(a, dir);
        }

        var failed: std.ArrayList([]const u8) = .empty;
        defer failed.deinit(gpa);
        var added = try w.backend.setDirs(gpa, own.items, trees.items, &failed);
        // A tree that cannot be watched as a whole: each directory is watched on its own instead
        var tree_failed = false;
        for (failed.items) |f| for (trees.items) |t| {
            if (f.ptr == t.ptr) tree_failed = true;
        };
        if (tree_failed) {
            if (!w.tree_warned) {
                w.tree_warned = true;
                log.warn("cannot watch the workspace folders with their subdirectories: source files in directories created later are noticed only when another change makes the server scan the folders", .{});
            }
            failed.clearRetainingCapacity();
            if (try w.backend.setDirs(gpa, dirs.values(), &.{}, &failed)) added = true;
        }
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
        // A directory the scan entered that cannot be watched: its modification time is polled
        var fallback_dirs: std.ArrayList([]const u8) = .empty;
        errdefer fallback_dirs.deinit(gpa);
        for (scan_watches.items) |i| if (failed_set.contains(dirs.keys()[i])) try fallback_dirs.append(gpa, dirs.values()[i]);
        // Like adding a watch, from now on: changes before the first poll are reported too
        if (fallback.items.len == 0) w.poller.reset() else _ = try w.poller.track(server.io, a, fallback.items);
        if (fallback_dirs.items.len == 0) w.dir_poller.reset() else if (try w.dir_poller.track(server.io, a, fallback_dirs.items)) {
            added = true;
        }

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
        // Files that were not of interest before: the server may have read them before they were
        // watched (they are interned and read first, and recomputing the watched directories
        // follows in this task), and a change in between was not notified. Now that later changes
        // are notified or polled, their known text is compared with the disk.
        for (files.keys(), files.values()) |k, path| {
            if (!w.files.contains(k) and !entry_dirs.contains(k)) try pending.add(a, path, .verify);
        }

        w.spellings.reset(gpa);
        w.files.deinit(gpa);
        w.files = files;
        w.missing.deinit(gpa);
        w.missing = missing;
        w.entry_dirs.deinit(gpa);
        w.entry_dirs = entry_dirs;
        w.fallback.deinit(gpa);
        w.fallback = fallback;
        w.fallback_dirs.deinit(gpa);
        w.fallback_dirs = fallback_dirs;
        w.state_arena.deinit();
        w.state_arena = next_arena;
        w.scope = scope;
        if (w.fallback.items.len == 0 and w.fallback_dirs.items.len == 0) {
            w.next_poll = null;
        } else if (w.next_poll == null) w.schedulePoll();
        if (added) _ = w.epoch.fetchAdd(1, .acq_rel);
        // A scan that started walking before a directory was watched (see `scanned`), and the
        // root directories after nobody watched them (see `verify`), may miss source files
        if (scope == .all) {
            const missed = if (scan.epoch) |e| e != w.epoch.load(.monotonic) else false;
            if (missed or w.verify) server.scheduleScan();
        }
        log.debug("watching {d} directories ({d} with their subdirectories) for {d} files ({d} files and {d} directories checked periodically)", .{
            own.items.len,
            trees.items.len,
            w.files.count(),
            w.fallback.items.len,
            w.fallback_dirs.items.len,
        });
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
        // `Server.scheduleScan`), and directories that appear or disappear may hold some
        var rescan = false;
        var created: std.ArrayList([]const u8) = .empty;
        var dirs_changed: std.ArrayList([]const u8) = .empty;
        // Other names created: a directory among them may have been moved in with source files,
        // which are not notified (when notifications do not tell directories apart)
        var created_other: std.ArrayList([]const u8) = .empty;
        // Names created or removed that are not files of interest: they may be directories
        // (Windows notifications do not tell), moved or renamed with files of interest in them
        var unknown: std.StringHashMapUnmanaged(void) = .empty;
        for (events) |ev| switch (ev.kind) {
            .changed, .created, .removed => {
                const hint: Pending.Hint = if (ev.kind == .created) .created else .changed;
                const k = try w.key(a, ev.path);
                if (w.files.getIndex(k)) |i| {
                    // The name may now lead to another file
                    if (ev.kind != .changed) w.spellings.forgetFile(w.gpa, @intCast(i));
                    try pending.add(a, w.files.values()[i], hint);
                    continue;
                }
                // A name created anew may be another file than the one seen before
                if (ev.kind == .created) w.spellings.forget(w.gpa, k);
                const same = try w.spellings.find(w.gpa, w.server.io, &w.files, k, ev.path);
                if (ev.kind == .removed) w.spellings.forget(w.gpa, k);
                if (same) |i| {
                    if (ev.kind != .changed) w.spellings.forgetFile(w.gpa, i);
                    try pending.add(a, w.files.values()[i], hint);
                    continue;
                }
                // An entry created in or removed from a configure input directory
                if (ev.kind != .changed and w.inEntryDir(k)) try pending.add(a, ev.path, hint);
                if (ev.kind != .changed) try unknown.put(a, k, {});
                if (ev.kind == .created) {
                    // A path leading to a nonexistent directory has appeared
                    if (w.leadsToMissing(k)) try dirs.put(a, k, {});
                    if (workspace_files.isSource(std.fs.path.basename(ev.path))) {
                        try created.append(a, ev.path);
                    } else if (Native.created_may_be_dir and w.backend == .native) try created_other.append(a, ev.path);
                }
            },
            .dir_created, .dir_gone, .overflow => {
                if (ev.path.len == 0) {
                    all = true;
                    rescan = true;
                } else {
                    const k = try w.key(a, ev.path);
                    try dirs.put(a, k, {});
                    if (ev.kind != .overflow and w.inEntryDir(k)) try pending.add(a, ev.path, if (ev.kind == .dir_created) .created else .changed);
                    // Lost notifications may hide changes anywhere
                    if (ev.kind == .overflow) rescan = true else try dirs_changed.append(a, ev.path);
                }
            },
        };
        // Files of interest under an unknown name: it is a directory
        var moved = false;
        if (unknown.count() != 0) for (w.files.keys(), w.files.values()) |k, path| {
            if (!underAny(k, &unknown)) continue;
            moved = true;
            try pending.add(a, path, .changed);
        };
        if (moved) rescan = true;
        // Every build creates directories in `.zig-cache` and `zig-out`: a scan for them would find
        // nothing new, and find references and rename would wait for it after every build
        if (!rescan and (created.items.len != 0 or dirs_changed.items.len != 0 or created_other.items.len != 0)) {
            const rules = try w.server.originRules(a);
            for (created.items) |path| {
                if (workspace_files.contains(&w.server.vfs, rules, path)) rescan = true;
            }
            for (dirs_changed.items) |dir| {
                if (workspace_files.affectsScan(&w.server.vfs, rules, dir)) rescan = true;
            }
            // Only a name the scan would walk is looked up on disk
            for (created_other.items) |path| {
                if (rescan) break;
                if (workspace_files.affectsScan(&w.server.vfs, rules, path) and isDir(w.server.io, path)) rescan = true;
            }
        }
        if (rescan) w.server.scheduleScan();
        if (!all and dirs.count() == 0) return moved;
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
        w.testPause(&w.test_apply_pause);
        var events: std.ArrayList(types.FileEvent) = .empty;
        var verified: std.ArrayList(types.FileEvent) = .empty;
        for (pending.paths.keys(), pending.paths.values()) |path, hint| {
            const exists = stat(server.io, path) != null;
            const kind: types.FileChangeType = if (!exists) .Deleted else if (hint == .created) .Created else .Changed;
            try (if (hint == .verify) &verified else &events).append(a, .{ .uri = try uri.fromPath(a, path), .type = kind });
        }
        if (verified.items.len != 0) try w.reverifyLater(server.applyWatchedChanges(a, verified.items, .verified));
        if (events.items.len == 0) return;
        log.debug("{d} file(s) changed on disk", .{events.items.len});
        try w.reverifyLater(server.applyWatchedChanges(a, events.items, .notified));
    }

    /// Files that were being read from disk when their changes were handled: compared with the
    /// disk again after `reverify_ms`
    fn reverifyLater(w: *Watcher, paths: []const []const u8) Allocator.Error!void {
        for (paths) |path| {
            const owned = try w.gpa.dupe(u8, path);
            w.reverify.append(w.gpa, owned) catch |err| {
                w.gpa.free(owned);
                return err;
            };
        }
    }
};

/// A batch of pending changes: path → whether it was created. Paths are copied into this batch's
/// arena: the files of interest may be recomputed before handling, which frees the arena they were
/// originally in.
const Pending = struct {
    paths: std.StringArrayHashMapUnmanaged(Hint) = .empty,

    /// From the weakest: `verify` (compare with the known text, see `Server.ChangeSource`)
    const Hint = enum { verify, changed, created };

    fn add(p: *Pending, a: Allocator, path: []const u8, hint: Hint) Allocator.Error!void {
        const gop = try p.paths.getOrPut(a, path);
        if (gop.found_existing) {
            if (@backingInt(hint) > @backingInt(gop.value_ptr.*)) gop.value_ptr.* = hint;
            return;
        }
        gop.key_ptr.* = a.dupe(u8, path) catch |err| {
            _ = p.paths.pop();
            return err;
        };
        gop.value_ptr.* = hint;
    }
};

/// Other spellings of files of interest in notifications. FSEvents reports names in the Unicode
/// form stored on disk, which may be decomposed while the client and the server use the composed
/// form; a file may also be reached under the name of a symbolic link in its directory. A
/// reported path that is not a file of interest is that file of interest in the same directory
/// whose real path (see `Vfs.realPath`) is the same. Only unknown names in directories with files
/// of interest are resolved on disk; results are kept until the files of interest are recomputed,
/// and dropped for a name that is created or removed.
const Spellings = struct {
    /// Identity key of a reported path (owned) → index of the file of interest it names, or null
    found: std.StringHashMapUnmanaged(?u32) = .empty,
    /// Identity key of a directory → indexes of the files of interest in it; built when first
    /// needed (the keys point into the identity keys of the files of interest)
    dirs: ?std.StringHashMapUnmanaged(std.ArrayList(u32)) = null,
    /// Index of a file of interest → its real path (owned), or null when unreachable
    real: std.AutoHashMapUnmanaged(u32, ?[:0]u8) = .empty,

    fn deinit(s: *Spellings, gpa: Allocator) void {
        s.reset(gpa);
        s.found.deinit(gpa);
        s.real.deinit(gpa);
    }

    /// The files of interest are recomputed: their indexes change
    fn reset(s: *Spellings, gpa: Allocator) void {
        var found = s.found.keyIterator();
        while (found.next()) |k| gpa.free(k.*);
        s.found.clearRetainingCapacity();
        if (s.dirs) |*dirs| {
            var lists = dirs.valueIterator();
            while (lists.next()) |l| l.deinit(gpa);
            dirs.deinit(gpa);
            s.dirs = null;
        }
        var real = s.real.valueIterator();
        while (real.next()) |r| if (r.*) |p| gpa.free(p);
        s.real.clearRetainingCapacity();
    }

    /// Forgets what the reported path with identity key `k` names
    fn forget(s: *Spellings, gpa: Allocator, k: []const u8) void {
        if (s.found.fetchRemove(k)) |kv| gpa.free(kv.key);
    }

    /// Forgets the real path of the file of interest `file`
    fn forgetFile(s: *Spellings, gpa: Allocator, file: u32) void {
        if (s.real.fetchRemove(file)) |kv| if (kv.value) |p| gpa.free(p);
    }

    /// The file of interest (index into `files`) that the reported `path` (identity key `k`, not
    /// itself a file of interest) names, if any
    fn find(s: *Spellings, gpa: Allocator, io: Io, files: *const std.StringArrayHashMapUnmanaged([]const u8), k: []const u8, path: []const u8) Allocator.Error!?u32 {
        if (s.found.get(k)) |known| return known;
        if (s.dirs == null) {
            var dirs: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty;
            errdefer {
                var lists = dirs.valueIterator();
                while (lists.next()) |l| l.deinit(gpa);
                dirs.deinit(gpa);
            }
            for (files.keys(), 0..) |fk, i| {
                const gop = try dirs.getOrPut(gpa, std.fs.path.dirname(fk) orelse continue);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(gpa, @intCast(i));
            }
            s.dirs = dirs;
        }
        const in_dir = s.dirs.?.get(std.fs.path.dirname(k) orelse return null) orelse return null;
        // Not cached: a removed name no longer leads anywhere, and one created later is resolved
        // again
        const real = try Vfs.realPath(io, gpa, path) orelse return null;
        defer gpa.free(real);
        var same: ?u32 = null;
        for (in_dir.items) |i| {
            const gop = try s.real.getOrPut(gpa, i);
            if (!gop.found_existing) gop.value_ptr.* = Vfs.realPath(io, gpa, files.values()[i]) catch |err| {
                _ = s.real.remove(i);
                return err;
            };
            if (gop.value_ptr.*) |r| if (std.mem.eql(u8, r, real)) {
                same = i;
                break;
            };
        }
        const owned = try gpa.dupe(u8, k);
        errdefer gpa.free(owned);
        try s.found.put(gpa, owned, same);
        return same;
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

/// What `Watcher.classify` remembers. Under the same rules, whether an interned path is watched
/// (`Server.watchable`) and whether it is under a root directory never change (the case rule of a
/// directory is fixed once it has been seen), so each file is classified once instead of on every
/// recomputation; loading a project recomputes many times while it interns thousands of files.
const Classes = struct {
    /// The rules the files are classified under (copied into `arena`); null before the first
    /// classification
    rules: ?origin.Rules = null,
    arena: std.heap.ArenaAllocator,
    /// By FileId, for the files interned up to the last classification
    list: std.ArrayList(Class) = .empty,
    /// How many of them `Watcher.registerClientGlobs` has handled under `rules`
    globs_done: u32 = 0,

    const Class = packed struct(u8) {
        watchable: bool,
        /// Under one of `rules.roots` (only computed for watchable files)
        in_root: bool,
        _: u6 = 0,
    };

    fn deinit(c: *Classes, gpa: Allocator) void {
        c.list.deinit(gpa);
        c.arena.deinit();
    }
};

/// Whether two sets of classification rules are the same, field by field
fn sameRules(x: origin.Rules, y: origin.Rules) bool {
    const info = @typeInfo(origin.Rules).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        const a = @field(x, name);
        const b = @field(y, name);
        switch (T) {
            ?[]const u8 => if (a == null or b == null) {
                if (a != null or b != null) return false;
            } else if (!std.mem.eql(u8, a.?, b.?)) return false,
            []const []const u8 => {
                if (a.len != b.len) return false;
                for (a, b) |p, q| if (!std.mem.eql(u8, p, q)) return false;
            },
            else => @compileError("compare the rule field " ++ name),
        }
    }
    return true;
}

/// A copy of `rules` in `a`
fn dupeRules(a: Allocator, rules: origin.Rules) Allocator.Error!origin.Rules {
    var out: origin.Rules = .{};
    const info = @typeInfo(origin.Rules).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        @field(out, name) = switch (T) {
            ?[]const u8 => if (@field(rules, name)) |s| try a.dupe(u8, s) else null,
            []const []const u8 => try dupePaths(a, @field(rules, name)),
            else => @compileError("copy the rule field " ++ name),
        };
    }
    return out;
}

/// Copies of `paths` (the list and each path) in `a`
fn dupePaths(a: Allocator, paths: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, paths.len);
    for (paths, out) |p, *o| o.* = try a.dupe(u8, p);
    return out;
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

/// State of a directory on disk: its modification time changes when entries are created, removed
/// or renamed; null when it does not exist
fn statDir(io: Io, path: []const u8) ?Stamp {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    if (st.kind != .directory) return null;
    return .{ .size = 0, .mtime = st.mtime.nanoseconds };
}

/// Polling: checks the size and modification time of a set of files (or of directories, see
/// `statDir`). The state of a path is recorded when it starts being polled (`track`, or its first
/// check); only later changes count.
const Poller = struct {
    gpa: Allocator,
    /// The paths are directories
    dirs: bool = false,
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

    fn stamp(p: *const Poller, io: Io, path: []const u8) ?Stamp {
        return if (p.dirs) statDir(io, path) else stat(io, path);
    }

    /// Starts tracking the paths in `paths` not tracked yet, recording their current state, so
    /// their changes from now on count; paths not in `paths` are no longer tracked. Returns whether
    /// any path started being tracked.
    fn track(p: *Poller, io: Io, a: Allocator, paths: []const []const u8) Allocator.Error!bool {
        var wanted: std.StringHashMapUnmanaged(void) = .empty;
        for (paths) |path| try wanted.put(a, path, {});
        p.retain(&wanted);
        var added = false;
        for (paths) |path| {
            const gop = try p.seen.getOrPut(p.gpa, path);
            if (gop.found_existing) continue;
            gop.key_ptr.* = p.gpa.dupe(u8, path) catch |err| {
                p.seen.swapRemoveAt(gop.index);
                return err;
            };
            gop.value_ptr.* = p.stamp(io, path);
            added = true;
        }
        return added;
    }

    /// Stops tracking the files not in `wanted`
    fn retain(p: *Poller, wanted: *const std.StringHashMapUnmanaged(void)) void {
        var i: usize = p.seen.count();
        while (i > 0) {
            i -= 1;
            if (wanted.contains(p.seen.keys()[i])) continue;
            p.gpa.free(p.seen.keys()[i]);
            p.seen.swapRemoveAt(i);
        }
    }

    /// Checks `paths` and records changes in `pending`; files not in `paths` are no longer tracked
    fn poll(p: *Poller, io: Io, a: Allocator, paths: []const []const u8, pending: *Pending) Allocator.Error!void {
        var current: std.StringArrayHashMapUnmanaged(?Stamp) = .empty;
        var wanted: std.StringHashMapUnmanaged(void) = .empty;
        for (paths) |path| {
            try current.put(a, path, p.stamp(io, path));
            try wanted.put(a, path, {});
        }
        p.retain(&wanted);
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

    /// Changes the watched directories to `dirs` and `trees` (absolute paths), `trees` with their
    /// subdirectories (empty unless `recursive`); directories that cannot be watched are appended
    /// to `failed` (taken from `dirs` and `trees`). Returns whether a directory not watched
    /// before is watched now. Called only in the background task.
    fn setDirs(b: Backend, gpa: Allocator, dirs: []const []const u8, trees: []const []const u8, failed: *std.ArrayList([]const u8)) Allocator.Error!bool {
        switch (b) {
            inline else => |x| return x.setDirs(gpa, dirs, trees, failed),
        }
    }

    /// Directories can be watched with their subdirectories (see `setDirs`); does not change after
    /// creation, so may be called from any thread
    fn recursive(b: Backend) bool {
        return switch (b) {
            .native => Native.recursive,
            .fallback => false,
        };
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
    const recursive = false;
    const created_may_be_dir = false;

    fn create(_: Allocator, _: Io) error{Unsupported}!*Unsupported {
        return error.Unsupported;
    }
    fn destroy(_: *Unsupported, _: Allocator) void {
        unreachable;
    }
    fn wake(_: *Unsupported) void {
        unreachable;
    }
    fn setDirs(_: *Unsupported, _: Allocator, _: []const []const u8, _: []const []const u8, _: *std.ArrayList([]const u8)) Allocator.Error!bool {
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

    fn setDirs(_: *Fallback, gpa: Allocator, dirs: []const []const u8, trees: []const []const u8, failed: *std.ArrayList([]const u8)) Allocator.Error!bool {
        try failed.appendSlice(gpa, dirs);
        try failed.appendSlice(gpa, trees);
        return false;
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
    const recursive = false;
    const created_may_be_dir = false;

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

    fn setDirs(n: *Inotify, gpa: Allocator, dirs: []const []const u8, trees: []const []const u8, failed: *std.ArrayList([]const u8)) Allocator.Error!bool {
        std.debug.assert(trees.len == 0);
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
        var added = false;
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
            added = true;
        }
        return added;
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

    /// Appends `events` to `out` with their paths mapped back to the written form (allocated by
    /// `gpa`)
    fn carry(r: *const RootAliases, gpa: Allocator, events: []const Event, out: *std.ArrayList(Event)) Allocator.Error!void {
        try out.ensureUnusedCapacity(gpa, events.len);
        for (events) |e| out.appendAssumeCapacity(.{ .path = try r.written(gpa, e.path), .kind = e.kind });
    }
};

/// macOS: FSEvents (recursive watching, managed by a system service). CoreServices is loaded
/// dynamically, with no dependency on the SDK; callbacks run on a serial queue created by this
/// backend, the received changes are buffered on that queue, and the background task takes them
/// via `dispatch_sync`.
/// The IDs of the events a FSEvents stream reports before its HistoryDone event (the changes after
/// the event it starts at, made before it was registered). FSEvents may report events of this
/// history again after the HistoryDone event, with the same IDs: an event ID names one change, so
/// the second report says nothing new. Handled again, the creation of a watch root it reports would
/// schedule another scan of the workspace.
const HistoryIds = struct {
    ids: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The largest of `ids`
    max: u64 = 0,
    /// The stream is still reporting its history
    in_history: bool = false,

    /// A stream starts; it reports a history unless it starts at `since_now`
    fn start(h: *HistoryIds, gpa: Allocator, history: bool) void {
        h.ids.clearAndFree(gpa);
        h.max = 0;
        h.in_history = history;
    }

    /// The stream has reported its HistoryDone event
    fn done(h: *HistoryIds) void {
        h.in_history = false;
    }

    /// Whether the stream has reported event `id` before; otherwise, during the history, records it
    fn again(h: *HistoryIds, gpa: Allocator, id: u64) bool {
        // Some events (the root changed, a volume mounted) carry no ID
        if (id == 0) return false;
        if (h.in_history) {
            // Without memory, the event may be handled twice, which costs a scan at most
            const gop = h.ids.getOrPut(gpa, id) catch return false;
            if (gop.found_existing) return true;
            h.max = @max(h.max, id);
            return false;
        }
        if (h.ids.count() == 0) return false;
        // Live events arrive in the order of their IDs: after one past the history, none repeats it
        if (id > h.max) {
            h.ids.clearAndFree(gpa);
            return false;
        }
        return h.ids.remove(id);
    }

    fn deinit(h: *HistoryIds, gpa: Allocator) void {
        h.ids.deinit(gpa);
    }
};

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
    /// The ID of the event up to which the current stream has reported the changes: where it
    /// started, then the latest event it delivered (accessed only on `queue` while the stream
    /// runs)
    reported: u64 = 0,
    /// The events of the current stream's history (accessed only on `queue` while the stream runs)
    history: HistoryIds = .{},
    /// Changes received from a replaced stream, already mapped back to the written form with the
    /// roots of that stream (accessed only by the background task; paths are owned by `gpa`)
    carried: std.ArrayList(Event) = .empty,

    /// FSEvents has an undocumented limit on the number of watched paths (reportedly 4096)
    const max_roots = 2048;
    const recursive = true;
    const created_may_be_dir = false;

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
        FSEventStreamFlushSync: *const fn (stream: FSEventStreamRef) callconv(.c) void,
        FSEventStreamInvalidate: *const fn (stream: FSEventStreamRef) callconv(.c) void,
        FSEventStreamRelease: *const fn (stream: FSEventStreamRef) callconv(.c) void,
        CFRelease: *const fn (cf: *const anyopaque) callconv(.c) void,
        CFArrayCreate: *const fn (allocator: ?*const anyopaque, values: [*]const ?CFStringRef, num_values: isize, call_backs: ?*const anyopaque) callconv(.c) ?CFArrayRef,
        CFStringCreateWithCString: *const fn (allocator: ?*const anyopaque, c_str: [*:0]const u8, encoding: u32) callconv(.c) ?CFStringRef,
        FSEventsGetCurrentEventId: *const fn () callconv(.c) u64,
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
        for (f.carried.items) |e| gpa.free(e.path);
        f.carried.deinit(gpa);
        f.history.deinit(gpa);
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

    fn setDirs(f: *FsEvents, gpa: Allocator, dirs: []const []const u8, trees: []const []const u8, failed: *std.ArrayList([]const u8)) Allocator.Error!bool {
        // Of nested directories, keep only the outermost: watching is recursive
        const sorted = try gpa.alloc([]const u8, dirs.len + trees.len);
        defer gpa.free(sorted);
        @memcpy(sorted[0..dirs.len], dirs);
        @memcpy(sorted[dirs.len..], trees);
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
            } else return false;
        }

        // The changes the old stream still holds back (for its latency) are delivered now and
        // kept, mapped with the roots they were reported under
        const replaced = f.stream != null;
        if (f.stream) |stream| f.sym.FSEventStreamFlushSync(stream);
        f.stopStream();
        var taken = f.takeQueued();
        defer {
            for (taken.events.items) |e| gpa.free(e.path);
            taken.events.deinit(gpa);
        }
        try f.aliases.carry(gpa, taken.events.items, &f.carried);
        // A stream reports the changes after the event it starts at, also those made before the
        // system service registers it. The new one starts where the old one stopped reporting:
        // a stopped stream does not report the changes the service had not handed to it yet,
        // even when flushed, and a stream still reporting the changes before its start has not
        // reported those after. Without an old stream, it starts at the latest event as of now,
        // so a change made after this call is reported however long the stream takes to start.
        const since = if (replaced) taken.reported else f.currentEventId();
        f.clearRoots();
        for (roots.items) |r| try f.roots.append(gpa, try gpa.dupeSentinel(u8, r, 0));
        try f.aliases.set(gpa, f.io, f.roots.items);
        if (f.roots.items.len == 0) return false;
        f.startStream(since) catch {
            log.warn("cannot start FSEvents stream, checking files on disk periodically instead", .{});
            try failed.appendSlice(gpa, dirs);
            try failed.appendSlice(gpa, trees);
            return false;
        };
        return true;
    }

    /// The ID of the latest event the system service has seen, on any volume; `since_now` when it
    /// has none (a stream starting at ID 0 would replay the whole history)
    fn currentEventId(f: *const FsEvents) u64 {
        const id = f.sym.FSEventsGetCurrentEventId();
        return if (id == 0) since_now else id;
    }

    /// Starts a stream for `roots` reporting the changes after event `since` (see `currentEventId`)
    fn startStream(f: *FsEvents, since: u64) error{ OutOfMemory, StartFailed }!void {
        const s = f.sym;
        f.cf_paths = try f.gpa.alloc(?CFStringRef, f.roots.items.len);
        @memset(f.cf_paths, null);
        for (f.roots.items, f.cf_paths) |r, *p| p.* = s.CFStringCreateWithCString(null, r.ptr, cf_string_encoding_utf8) orelse return error.OutOfMemory;
        f.cf_array = s.CFArrayCreate(null, f.cf_paths.ptr, @intCast(f.cf_paths.len), null) orelse return error.OutOfMemory;
        const ctx: StreamContext = .{ .info = f };
        const stream = s.FSEventStreamCreate(null, callback, &ctx, f.cf_array.?, since, @as(f64, debounce_ms) / 1000.0, .{
            .watch_root = true,
            .file_events = true,
        }) orelse return error.StartFailed;
        // No callback runs before the stream starts
        f.reported = since;
        f.history.start(f.gpa, since != since_now);
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
        ids: [*]const u64,
    ) callconv(.c) void {
        const f: *FsEvents = @ptrCast(@alignCast(info));
        const paths: [*]const [*:0]const u8 = @ptrCast(@alignCast(paths_ptr));
        for (paths[0..count], flags_ptr[0..count], ids[0..count]) |p, fl, id| {
            // Some events (the root changed, a volume mounted) carry no ID
            f.reported = @max(f.reported, id);
            if (fl.history_done) {
                f.history.done();
                continue;
            }
            if (f.history.again(f.gpa, id)) continue;
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

    const Taken = struct {
        /// Paths owned by `gpa`
        events: std.ArrayList(Event),
        /// See `reported`
        reported: u64,
    };

    /// Takes the changes received by the callback so far, with the event the stream has reported
    /// them up to
    fn takeQueued(f: *FsEvents) Taken {
        const Take = struct {
            f: *FsEvents,
            taken: std.ArrayList(Event) = .empty,
            reported: u64 = 0,
            fn run(ctx: ?*anyopaque) callconv(.c) void {
                const t: *@This() = @ptrCast(@alignCast(ctx));
                t.taken = t.f.queued;
                t.f.queued = .empty;
                t.reported = t.f.reported;
            }
        };
        var take: Take = .{ .f = f };
        dispatch.sync_f(f.queue, &take, Take.run);
        return .{ .events = take.taken, .reported = take.reported };
    }

    fn drain(f: *FsEvents, a: Allocator, out: *std.ArrayList(Event)) Allocator.Error!void {
        var taken = f.takeQueued();
        defer {
            for (taken.events.items) |e| f.gpa.free(e.path);
            taken.events.deinit(f.gpa);
            for (f.carried.items) |e| f.gpa.free(e.path);
            f.carried.clearRetainingCapacity();
        }
        for (f.carried.items) |e| try out.append(a, .{ .path = try a.dupe(u8, e.path), .kind = e.kind });
        for (taken.events.items) |e| try out.append(a, .{ .path = try f.aliases.written(a, e.path), .kind = e.kind });
    }
};

/// Windows: change notifications for directories, the roots with their subdirectories (see
/// `Backend.setDirs`). A completed notification is delivered as an APC to the thread that issued
/// it (the background task) and runs during an alertable wait; an event object is used for waking
/// up. While a directory is open, its ancestors cannot be renamed or deleted: watching each root as
/// a whole leaves the directories under it free to be.
const DirNotify = struct {
    const windows = std.os.windows;
    const recursive = true;
    /// Notifications do not tell whether a name is a directory
    const created_may_be_dir = true;

    gpa: Allocator,
    wake_event: windows.HANDLE,
    dirs: std.StringArrayHashMapUnmanaged(*Directory) = .empty,
    /// Directories whose notification has completed and awaits handling (added in the APC)
    ready: std.DoublyLinkedList = .{},

    const Directory = struct {
        path: []u8,
        handle: windows.HANDLE,
        /// Notifications cover the subdirectories too, and name entries by their paths relative
        /// to `path`
        recursive: bool,
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

    /// Returns at once when notifications have already completed: their APCs may have run during
    /// an alertable wait elsewhere on this thread (such as file I/O while a batch was handled), and
    /// those directories are not listening again until they are drained
    fn wait(d: *DirNotify, timeout_ns: ?u64) void {
        if (d.ready.first != null) return;
        if (timeout_ns) |ns| {
            const interval: windows.LARGE_INTEGER = -@as(windows.LARGE_INTEGER, @intCast(@min(ns / 100, std.math.maxInt(i63))));
            _ = windows.ntdll.NtWaitForSingleObject(d.wake_event, .TRUE, &interval);
        } else {
            _ = windows.ntdll.NtWaitForSingleObject(d.wake_event, .TRUE, null);
        }
    }

    fn setDirs(d: *DirNotify, gpa: Allocator, dirs: []const []const u8, trees: []const []const u8, failed: *std.ArrayList([]const u8)) Allocator.Error!bool {
        // Path → watched with its subdirectories
        var want: std.StringArrayHashMapUnmanaged(bool) = .empty;
        defer want.deinit(gpa);
        for (dirs) |p| try want.put(gpa, p, false);
        for (trees) |p| try want.put(gpa, p, true);
        // A directory watched the other way is closed after its replacement listens, so no change
        // in between is lost
        var replaced: std.ArrayList(*Directory) = .empty;
        defer {
            for (replaced.items) |dir| d.close(dir);
            replaced.deinit(gpa);
        }
        var i = d.dirs.count();
        while (i > 0) {
            i -= 1;
            const dir = d.dirs.values()[i];
            const wanted = want.get(d.dirs.keys()[i]);
            if (wanted != null and wanted.? == dir.recursive) continue;
            d.dirs.swapRemoveAt(i);
            if (wanted == null) {
                d.close(dir);
            } else replaced.append(gpa, dir) catch |err| {
                d.close(dir);
                return err;
            };
        }
        var added = false;
        for (want.keys(), want.values()) |p, tree| {
            if (d.dirs.contains(p)) continue;
            const dir = d.open(p, tree) catch |err| switch (err) {
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
            added = true;
        }
        return added;
    }

    fn open(d: *DirNotify, path: []const u8, tree: bool) !*Directory {
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
        dir.* = .{ .path = try d.gpa.dupe(u8, path), .handle = handle, .recursive = tree };
        errdefer d.gpa.free(dir.path);
        try d.listen(dir);
        return dir;
    }

    fn listen(d: *DirNotify, dir: *Directory) !void {
        switch (NtNotifyChangeDirectoryFile(
            dir.handle,
            null,
            &notifyApc,
            d,
            &dir.iosb,
            &dir.buffer,
            dir.buffer.len,
            .{ .FILE_NAME = true, .DIR_NAME = true, .SIZE = true, .LAST_WRITE = true, .CREATION = true },
            if (dir.recursive) .TRUE else .FALSE,
        )) {
            .SUCCESS, .PENDING => dir.state = .listening,
            else => return error.CannotWatchDirectory,
        }
    }

    /// Fills the buffer with `FILE_NOTIFY_INFORMATION` records, as `NtNotifyChangeDirectoryFileEx`
    /// does with `DirectoryNotifyInformation`; the latter exists only from Windows 10 1709 on, and
    /// a program that imports it does not start on earlier versions (Zig supports Windows 10 from
    /// 1507 on). `std.os.windows.ntdll` declares only the latter.
    extern "ntdll" fn NtNotifyChangeDirectoryFile(
        FileHandle: windows.HANDLE,
        Event: ?windows.HANDLE,
        ApcRoutine: ?*align(2) const windows.IO_APC_ROUTINE,
        ApcContext: ?*anyopaque,
        IoStatusBlock: *windows.IO_STATUS_BLOCK,
        Buffer: *anyopaque,
        Length: windows.ULONG,
        CompletionFilter: windows.FILE.NOTIFY.CHANGE,
        WatchTree: windows.BOOLEAN,
    ) callconv(.winapi) windows.NTSTATUS;

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
    _ = try n.setDirs(testing.allocator, &.{dir}, &.{}, &failed);
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

test "native watching reports whether directories are newly watched" {
    if (Native == Unsupported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "a");
    try tmp.dir.createDirPath(testing.io, "b");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const dir_a = try std.fs.path.join(a, &.{ base, "a" });
    const dir_b = try std.fs.path.join(a, &.{ base, "b" });

    const n = try Native.create(testing.allocator, testing.io);
    defer n.destroy(testing.allocator);
    var failed: std.ArrayList([]const u8) = .empty;
    defer failed.deinit(testing.allocator);
    try testing.expect(try n.setDirs(testing.allocator, &.{dir_a}, &.{}, &failed));
    try testing.expect(!try n.setDirs(testing.allocator, &.{dir_a}, &.{}, &failed));
    try testing.expect(try n.setDirs(testing.allocator, &.{ dir_a, dir_b }, &.{}, &failed));
    try testing.expectEqual(0, failed.items.len);
}

// Prevents missing source files created in directories that did not exist when watching started
test "native watching with subdirectories reports changes in directories created later" {
    if (!Native.recursive) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);

    const n = try Native.create(testing.allocator, testing.io);
    defer n.destroy(testing.allocator);
    var failed: std.ArrayList([]const u8) = .empty;
    defer failed.deinit(testing.allocator);
    try testing.expect(try n.setDirs(testing.allocator, &.{}, &.{dir}, &failed));
    try testing.expectEqual(0, failed.items.len);

    try tmp.dir.createDirPath(testing.io, "sub/inner");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sub/inner/x.zig", .data = "x" });
    try expectReported(n, a, &.{try std.fs.path.join(a, &.{ dir, "sub", "inner", "x.zig" })});
}

// Prevents waiting forever for a notification whose APC already ran during an alertable wait
// elsewhere on the thread
test "DirNotify: a notification completed outside of waiting ends the next wait at once" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);

    const n = try DirNotify.create(testing.allocator, testing.io);
    defer n.destroy(testing.allocator);
    var failed: std.ArrayList([]const u8) = .empty;
    defer failed.deinit(testing.allocator);
    _ = try n.setDirs(testing.allocator, &.{dir}, &.{}, &failed);
    try testing.expectEqual(0, failed.items.len);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "a" });
    // The APC runs here, not in `wait`
    while (n.ready.first == null) std.Io.Threaded.waitForApcOrAlert();
    const start = Io.Clock.awake.now(testing.io);
    n.wait(10 * std.time.ns_per_s);
    try testing.expect(start.durationTo(Io.Clock.awake.now(testing.io)).toSeconds() < 5);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var events: std.ArrayList(Event) = .empty;
    try n.drain(arena.allocator(), &events);
    try testing.expect(events.items.len != 0);
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
    _ = try n.setDirs(testing.allocator, &.{link}, &.{}, &failed);
    _ = try n.setDirs(testing.allocator, &.{}, &.{}, &failed);
    _ = try n.setDirs(testing.allocator, &.{link}, &.{}, &failed);
    try testing.expectEqual(0, failed.items.len);
}

// Prevents losing the changes a replaced FSEvents stream still held back: they are mapped with the
// roots they were reported under, which the replacement no longer knows
test "root aliases carry changes over a change of the roots" {
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

    var aliases: RootAliases = .{};
    defer aliases.deinit(testing.allocator);
    try aliases.set(testing.allocator, testing.io, &.{link});
    var carried: std.ArrayList(Event) = .empty;
    defer {
        for (carried.items) |e| testing.allocator.free(e.path);
        carried.deinit(testing.allocator);
    }
    const received = [_]Event{.{ .path = try std.fs.path.join(a, &.{ dir, "real", "f.zig" }), .kind = .changed }};
    try aliases.carry(testing.allocator, &received, &carried);
    try aliases.set(testing.allocator, testing.io, &.{});
    try testing.expectEqual(1, carried.items.len);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ link, "f.zig" }), carried.items[0].path);
}

test "FSEvents: changes held back by a replaced stream are still reported" {
    if (Native != FsEvents) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "a");
    try tmp.dir.createDirPath(testing.io, "b");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/f.zig", .data = "1" });
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir_a = try std.fs.path.join(a, &.{ dir, "a" });
    const dir_b = try std.fs.path.join(a, &.{ dir, "b" });

    const n = try Native.create(testing.allocator, testing.io);
    defer n.destroy(testing.allocator);
    var failed: std.ArrayList([]const u8) = .empty;
    defer failed.deinit(testing.allocator);
    _ = try n.setDirs(testing.allocator, &.{dir_a}, &.{}, &failed);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/f.zig", .data = "22" });
    // Within the stream's latency
    try testing.io.sleep(.fromMilliseconds(20), .awake);
    _ = try n.setDirs(testing.allocator, &.{ dir_a, dir_b }, &.{}, &failed);
    try testing.expectEqual(0, failed.items.len);
    try expectReported(n, a, &.{try std.fs.path.join(a, &.{ dir_a, "f.zig" })});
}

// Prevents losing a change the system service had not handed to the stream yet when the stream
// was replaced
test "FSEvents: a change made just before the stream is replaced is reported" {
    if (Native != FsEvents) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "a");
    try tmp.dir.createDirPath(testing.io, "b");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/f.zig", .data = "1" });
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir_a = try std.fs.path.join(a, &.{ dir, "a" });
    const dir_b = try std.fs.path.join(a, &.{ dir, "b" });

    const n = try Native.create(testing.allocator, testing.io);
    defer n.destroy(testing.allocator);
    var failed: std.ArrayList([]const u8) = .empty;
    defer failed.deinit(testing.allocator);
    _ = try n.setDirs(testing.allocator, &.{dir_a}, &.{}, &failed);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/f.zig", .data = "22" });
    _ = try n.setDirs(testing.allocator, &.{ dir_a, dir_b }, &.{}, &failed);
    try testing.expectEqual(0, failed.items.len);
    try expectReported(n, a, &.{try std.fs.path.join(a, &.{ dir_a, "f.zig" })});
}

// Prevents losing a change made after a file starts being polled but before its first check:
// the state is recorded when the file joins the polled files, not at the first check
test "FSEvents history: events of the history reported again after it are recognized" {
    const gpa = testing.allocator;
    var h: HistoryIds = .{};
    defer h.deinit(gpa);
    h.start(gpa, true);
    // The history, in no particular order, with an event reported twice in it
    for ([_]u64{ 325, 343, 334 }) |id| try testing.expect(!h.again(gpa, id));
    try testing.expect(h.again(gpa, 334));
    // Events without an ID are never recognized
    try testing.expect(!h.again(gpa, 0));
    try testing.expect(!h.again(gpa, 0));
    h.done();
    // Live: the history again, and a change between its events that it did not report
    try testing.expect(h.again(gpa, 325));
    try testing.expect(!h.again(gpa, 330));
    try testing.expect(h.again(gpa, 334));
    try testing.expect(h.again(gpa, 343));
    // Past the history, nothing is recorded any more
    try testing.expect(!h.again(gpa, 410));
    try testing.expectEqual(0, h.ids.count());
    // A stream starting at `since_now` reports no history
    h.start(gpa, false);
    try testing.expect(!h.again(gpa, 500));
    try testing.expect(!h.again(gpa, 500));
}

// Prevents a second scan of the workspace: under load, FSEvents reported the creation of the watch
// root (and of the files in it) before the HistoryDone event and again after it, with the same IDs
test "FSEvents: events of the history reported again after it are dropped" {
    if (Native != FsEvents) return error.SkipZigTest;
    const n = try Native.create(testing.allocator, testing.io);
    defer n.destroy(testing.allocator);
    n.history.start(testing.allocator, true);
    // The order and flags FSEvents used, the last event being a later change to lib.zig
    var paths = [_][*:0]const u8{ "/p", "/p/lib.zig", "/p/main.zig", "/p", "/p", "/p/main.zig", "/p/lib.zig", "/p/lib.zig" };
    const raw = [_]u32{ 0x28100, 0x19100, 0x19100, 0x10, 0x28100, 0x19100, 0x19100, 0x19500 };
    const ids = [_]u64{ 325, 343, 334, 343, 325, 334, 343, 410 };
    var flags: [raw.len]FsEvents.EventFlags = undefined;
    for (raw, &flags) |r, *f| f.* = @bitCast(r);
    FsEvents.callback(undefined, n, paths.len, @ptrCast(&paths), &flags, &ids);
    var taken = n.takeQueued();
    defer {
        for (taken.events.items) |e| testing.allocator.free(e.path);
        taken.events.deinit(testing.allocator);
    }
    const want = [_]Event{
        .{ .path = "/p", .kind = .dir_created },
        .{ .path = "/p/lib.zig", .kind = .created },
        .{ .path = "/p/main.zig", .kind = .created },
        .{ .path = "/p/lib.zig", .kind = .created },
    };
    try testing.expectEqual(want.len, taken.events.items.len);
    for (want, taken.events.items) |w, e| {
        try testing.expectEqualStrings(w.path, e.path);
        try testing.expectEqual(w.kind, e.kind);
    }
    try testing.expectEqual(410, taken.reported);
}

test "poller: a change before the first check of a tracked file is reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const a_path = try std.fs.path.join(a, &.{ dir, "a.zig" });
    const b_path = try std.fs.path.join(a, &.{ dir, "b.zig" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "a" });

    var poller: Poller = .{ .gpa = testing.allocator };
    defer poller.deinit();
    const paths = [_][]const u8{ a_path, b_path };
    _ = try poller.track(testing.io, a, &paths);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "aa" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.zig", .data = "b" });
    // Tracking again keeps the recorded states
    _ = try poller.track(testing.io, a, &paths);
    var pending: Pending = .{};
    try poller.poll(testing.io, a, &paths, &pending);
    try testing.expectEqual(Pending.Hint.changed, pending.paths.get(a_path).?);
    try testing.expectEqual(Pending.Hint.created, pending.paths.get(b_path).?);
    // Files no longer tracked are forgotten
    _ = try poller.track(testing.io, a, paths[0..1]);
    try testing.expectEqual(1, poller.seen.count());
}

test "poller: polling directories reports entries created in them" {
    // `Io.Dir.setTimestamps` is not implemented on Windows
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "d");
    // An old modification time: a new entry changes it even within the clock's granularity
    try tmp.dir.setTimestamps(testing.io, "d", .{ .modify_timestamp = .{ .new = .{ .nanoseconds = std.time.ns_per_s * 1_000_000_000 } } });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const d = try std.fs.path.join(a, &.{ base, "d" });

    var poller: Poller = .{ .gpa = testing.allocator, .dirs = true };
    defer poller.deinit();
    try testing.expect(try poller.track(testing.io, a, &.{d}));
    try testing.expect(!try poller.track(testing.io, a, &.{d}));
    var pending: Pending = .{};
    try poller.poll(testing.io, a, &.{d}, &pending);
    try testing.expectEqual(0, pending.paths.count());
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "d/new.zig", .data = "" });
    try poller.poll(testing.io, a, &.{d}, &pending);
    try testing.expectEqual(Pending.Hint.changed, pending.paths.get(d).?);
}

// Prevents ignoring a directory renamed, moved or deleted when the notification does not say it is
// a directory (Windows): the files of interest under it must be checked again
test "a name created or removed without being reported as a directory reaches the files under it" {
    const native = @import("../util/test_path.zig").native;
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var writer: za.lsp.transport.Writer = .{ .io = testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(testing.io, testing.allocator, &writer);
    defer server.deinit();
    const w = try Watcher.create(&server);
    defer w.destroy();
    const sa = w.state_arena.allocator();
    for ([_][]const u8{ native("/p/src/sub/x.zig"), native("/p/src/main.zig") }) |path| {
        try w.files.put(testing.allocator, try w.key(sa, path), path);
    }
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Renamed (the old and the new name), as Windows reports it
    var pending: Pending = .{};
    const renamed = [_]Event{
        .{ .path = native("/p/src/sub"), .kind = .removed },
        .{ .path = native("/p/src/sub2"), .kind = .created },
    };
    try testing.expect(try w.handle(a, &renamed, &pending));
    try testing.expectEqual(1, pending.paths.count());
    try testing.expect(pending.paths.contains(native("/p/src/sub/x.zig")));

    // A removed file that is not of interest changes nothing
    pending = .{};
    try testing.expect(!try w.handle(a, &.{.{ .path = native("/p/src/other.txt"), .kind = .removed }}, &pending));
    try testing.expectEqual(0, pending.paths.count());
}

test "spellings: a reported name that is another spelling of a file of interest names it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    try tmp.dir.createDirPath(testing.io, "sub");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "target.zig", .data = "a" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "other.zig", .data = "b" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sub/target.zig", .data = "c" });
    try tmp.dir.symLink(testing.io, "target.zig", "link.zig", .{});
    // On macOS, the client spells a name in the composed form while FSEvents reports the form
    // stored on disk, here the decomposed one: APFS treats both as the same name
    const macos = builtin.os.tag == .macos;
    if (macos) try tmp.dir.writeFile(testing.io, .{ .sub_path = "cafe\u{301}.zig", .data = "d" });
    const path = struct {
        fn join(al: Allocator, d: []const u8, name: []const u8) ![]const u8 {
            return std.fs.path.join(al, &.{ d, name });
        }
    }.join;

    var files: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer files.deinit(gpa);
    for ([_][]const u8{ "other.zig", "link.zig", "caf\u{e9}.zig" }) |name| {
        if (!macos and std.mem.eql(u8, name, "caf\u{e9}.zig")) continue;
        const p = try path(a, dir, name);
        try files.put(gpa, p, p);
    }
    var s: Spellings = .{};
    defer s.deinit(gpa);
    const target = try path(a, dir, "target.zig");
    // The symbolic link `link.zig` is the file the notification names as `target.zig`
    try testing.expectEqual(1, (try s.find(gpa, testing.io, &files, target, target)).?);
    try testing.expectEqual(1, s.found.get(target).?.?);
    // A name of another file in the same directory, and a name in a directory without files of
    // interest, name none
    const nested = try path(a, dir, "sub/target.zig");
    try testing.expectEqual(null, try s.find(gpa, testing.io, &files, nested, nested));
    try testing.expect(!s.found.contains(nested));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "new.zig", .data = "e" });
    const new = try path(a, dir, "new.zig");
    try testing.expectEqual(null, try s.find(gpa, testing.io, &files, new, new));
    if (macos) {
        const decomposed = try path(a, dir, "cafe\u{301}.zig");
        try testing.expectEqual(2, (try s.find(gpa, testing.io, &files, decomposed, decomposed)).?);
    }
    // Removed: the name is still known until it is forgotten; then it leads nowhere
    try tmp.dir.deleteFile(testing.io, "target.zig");
    try testing.expectEqual(1, (try s.find(gpa, testing.io, &files, target, target)).?);
    s.forget(gpa, target);
    s.forgetFile(gpa, 1);
    try testing.expectEqual(null, try s.find(gpa, testing.io, &files, target, target));
    // The files of interest are recomputed
    s.reset(gpa);
    try testing.expectEqual(0, s.found.count());
    try testing.expect(s.dirs == null);
}
