//! Changes on disk: `workspace/didChangeWatchedFiles`, the changes found by the server's own watcher,
//! and the registration of file watchers with the client.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const za = @import("../zig_analyzer.zig");
const types = za.lsp.types;
const uri = za.base.uri;
const Vfs = za.base.Vfs;
const database = @import("../database.zig");
const Db = database.Db;
const FileText = database.inputs.FileText;
const WorkspaceFiles = database.inputs.WorkspaceFiles;
const syntax_q = database.syntax;
const Workspace = @import("Workspace.zig");
const origin = @import("origin.zig");
const workspace_files = @import("workspace_files.zig");

const Server = @import("Server.zig");
const doc_sync = @import("doc_sync.zig");
const indexing = @import("indexing.zig");
const project_set = @import("project_set.zig");
const publishing = @import("publishing.zig");

const log = std.log.scoped(.server);

pub fn didChangeWatchedFiles(server: *Server, arena: Allocator, params: types.DidChangeWatchedFilesParams) !void {
    _ = try applyFileChanges(server, arena, params.changes, .notified, null);
}

/// How changes on disk were found
pub const ChangeSource = enum {
    /// Reported by a file watcher (the client's or the server's)
    notified,
    /// Files compared with the disk because a change to them may not have been notified: nobody
    /// watched them for a while, or they were read before they were watched (see
    /// `watch.Watcher`). Only a known file whose known text differs from the disk changed; open
    /// documents and files never loaded are skipped
    verified,
};

/// External changes on disk (outside the editor: git checkout, code generation, etc.). For open
/// files the buffer is authoritative, but the builds read the disk, so they are rebuilt as well;
/// other known files are updated from the disk contents (deleted ones become nonexistent),
/// without writing or republishing when the contents equal the known ones. A change to build.zig
/// / build.zig.zon / zig-analyzer.zon in a workspace root directory or to a project's build
/// script restarts that project; creating or deleting build.zig in a root directory starts or
/// stops the project; changes to other files rebuild projects and recompile single files; nothing
/// is rebuilt when the disk contents equal those the last rebuild was based on (see `didSave`). A
/// project in the middle of a build compares a notified change when the build completes (see
/// `Workspace.deferChanges`). Returns whether anything changed: a known file's text or rebuild
/// basis, or a project started or stopped. When `deferred` is given, the files being read from
/// disk are added to it instead of being compared with the disk: what the read gets is not known
/// yet, so their text is compared again once the read is done (see `applyWatchedChanges`). The
/// rebuild of a notified change does not wait for that, since the builds read the disk.
fn applyFileChanges(server: *Server, arena: Allocator, file_events: []const types.FileEvent, source: ChangeSource, deferred: ?*std.ArrayList([]const u8)) !bool {
    const Change = struct {
        file: Vfs.FileId,
        path: []const u8,
        /// Disk contents to write; null for open documents (their buffer is authoritative)
        text: ?[]u8,
        open: bool,
        durability: database.Durability,
        /// Hash of the disk contents; null if the file does not exist
        disk: ?u64,
        /// Being read from disk (`SourceText`): compared with the disk again once the read is done
        /// (see `deferred`)
        reading: bool = false,
        /// Differs from the known text: write it and republish
        edited: bool = true,
        /// Differs from what `watched_built` recorded: rebuild
        rebuild: bool = true,
    };
    var changes: std.ArrayList(Change) = .empty;
    defer for (changes.items) |c| if (c.text) |t| server.gpa.free(t);
    const rules = try server.originRules(arena);
    var build_files: std.ArrayList([]const u8) = .empty;
    var build_zig_dirs: std.ArrayList([]const u8) = .empty;
    // Known files that changed
    var known: std.ArrayList(Vfs.FileId) = .empty;
    // When a file changes several times in one batch, the last change wins: an atomic save first
    // deletes and then recreates the file, and with unchanged contents the two together are not a
    // change
    var events: std.StringArrayHashMapUnmanaged(types.FileChangeType) = .empty;
    for (file_events) |event| {
        const path = uri.toPath(arena, event.uri) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnsupportedScheme, error.InvalidUri => continue,
        };
        if (!std.fs.path.isAbsolute(path)) continue;
        try events.put(arena, path, event.type);
    }
    // A folder created, deleted, moved or renamed is reported by its own path only
    const folders = try addFolderContents(server, arena, &events);
    // A file created or deleted may change what the paths of open documents resolve to
    for (events.values()) |kind| if (kind != .Changed) {
        server.docs.mutex.lockUncancelable(server.io);
        defer server.docs.mutex.unlock(server.io);
        doc_sync.forgetRealPath(server, null);
        break;
    };
    // Source files created or deleted under the root directories change what find references and
    // rename search
    const rescan = folders or try changesWorkspaceFiles(server, arena, rules, events.keys(), events.values());
    defer if (rescan) indexing.scheduleScan(server);
    for (events.keys(), events.values()) |path, kind| {
        const base = std.fs.path.basename(path);
        const dir = std.fs.path.dirname(path) orelse "";
        if (std.mem.eql(u8, base, "build.zig")) try build_zig_dirs.append(arena, dir);
        // Files never seen before have no known contents to update (a new file is loaded when it
        // is imported); project files count as changed unless the project started with these
        // contents
        const file = try server.vfs.lookup(path) orelse {
            if (source == .verified or !doc_sync.isProjectFile(base)) continue;
            const read = if (kind == .Deleted) null else Io.Dir.cwd().readFileAlloc(server.io, path, arena, .limited(Vfs.max_file_size)) catch |err| switch (err) {
                error.OutOfMemory, error.Canceled => |e| return e,
                else => null,
            };
            if (!doc_sync.projectStartedWith(server, path, if (read) |t| std.hash.Wyhash.hash(0, t) else null)) try build_files.append(arena, dir);
            continue;
        };
        const is_open = blk: {
            server.docs.mutex.lockUncancelable(server.io);
            defer server.docs.mutex.unlock(server.io);
            break :blk server.docs.open.contains(file);
        };
        if (is_open and source == .verified) continue;
        if (source == .verified) switch (knownTextOf(server, arena, file)) {
            // Nothing was computed from a file never read: it cannot differ (see `sameText`), so
            // the disk is not read for it
            .none => continue,
            // What the read gets is not known yet
            .reading => {
                if (deferred) |list| try list.append(arena, path);
                continue;
            },
            .known => {},
        };
        const read = if (kind == .Deleted) null else server.vfs.readFromDisk(file, server.gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            error.FileTooBig => null,
        };
        const disk: ?u64 = if (read) |t| std.hash.Wyhash.hash(0, t) else null;
        const text = if (is_open) blk: {
            if (read) |t| server.gpa.free(t);
            break :blk null;
        } else read;
        changes.append(arena, .{
            .file = file,
            .path = path,
            .text = text,
            .open = is_open,
            .durability = origin.classify(&server.vfs, rules, server.vfs.path(file), false).durability(),
            .disk = disk,
        }) catch |err| {
            if (text) |t| server.gpa.free(t);
            return err;
        };
    }
    // When a build step rewrites a file in the source tree with identical contents every time
    // (such as generated code), the write transaction cancels in-flight computations and
    // requests, and the rebuild rewrites the file again, forming a loop. Whether to rebuild cannot
    // be decided from the known text: the build reads the disk, while the known text may also come
    // from reads when documents were opened or closed or at the first load, which the build has
    // not necessarily seen.
    if (changes.items.len != 0) {
        if (deferred) |list| try list.ensureUnusedCapacity(arena, changes.items.len);
        // A comparison canceled by a write transaction (a project loading files, the module graph
        // update, a scan, ...) tells nothing about the files: all of them are compared again once
        // that write has taken the lock (see `Db.waitPendingWrites`)
        while (true) {
            const canceled = blk: {
                var ctx = server.db.beginRead(arena);
                defer ctx.end();
                if (@import("builtin").is_test) if (server.hooks.compare) |gate| gate.pass(server.io);
                for (changes.items) |*c| {
                    // A notified file being read from disk, or a verified one whose read began
                    // after the check above
                    c.reading = deferred != null and !c.open and knownText(&ctx, c.file) == .reading;
                    c.edited = !c.reading and !c.open and !(sameText(&ctx, c.file, c.text) catch break :blk true);
                }
                break :blk false;
            };
            if (!canceled) break;
            server.db.waitPendingWrites();
        }
        var kept: usize = 0;
        for (changes.items) |*c| {
            if (c.reading) deferred.?.appendAssumeCapacity(c.path);
            c.rebuild = if (source == .verified)
                c.edited
            else if (project_set.watchedBuilt(server, c.file)) |built|
                !std.meta.eql(built, c.disk)
            else
                !(doc_sync.isProjectFile(std.fs.path.basename(c.path)) and doc_sync.projectStartedWith(server, c.path, c.disk));
            if (!c.edited and !c.rebuild) {
                if (c.text) |t| server.gpa.free(t);
                continue;
            }
            changes.items[kept] = c.*;
            kept += 1;
        }
        changes.shrinkRetainingCapacity(kept);
    }
    // Only the verified files whose contents differ from the known text changed
    if (source == .verified) {
        events.clearRetainingCapacity();
        for (changes.items) |c| try events.put(arena, c.path, if (c.disk == null) .Deleted else .Changed);
    }
    var edited: std.ArrayList(Vfs.FileId) = .empty;
    var rebuilt: std.ArrayList(Vfs.FileId) = .empty;
    for (changes.items) |c| {
        if (c.edited) try edited.append(arena, c.file);
        if (!c.rebuild) continue;
        try rebuilt.append(arena, c.file);
        try known.append(arena, c.file);
        if (doc_sync.isProjectFile(std.fs.path.basename(c.path))) try build_files.append(arena, std.fs.path.dirname(c.path) orelse "");
    }
    if (edited.items.len != 0) {
        server.db.beginWrite();
        defer server.db.endWrite();
        for (changes.items) |*c| if (c.edited) {
            try server.db.set(FileText, c.file, c.text, c.durability);
            c.text = null;
        };
    }

    // A build.zig was created or deleted in a root directory: start or stop the project; projects
    // that were just started need not be restarted
    var refreshed: std.ArrayList([]const u8) = .empty;
    for (build_zig_dirs.items) |dir| if (try project_set.refreshRoot(server, dir)) try refreshed.append(arena, dir);
    // A build.zig or build.zig.zon below a root directory changed: whether its directory is a
    // sub-project may have changed (see `refreshSubProjects`)
    if (server.started) for (build_files.items) |dir| if (project_set.nestedUnderRoot(server, dir)) {
        indexing.scheduleScan(server);
        break;
    };
    const changed = changes.items.len != 0 or build_files.items.len != 0 or refreshed.items.len != 0;

    // Files whose rebuild a project in the middle of a build decides when the build completes, and
    // those a rebuild was requested for right away
    var deferred_files: std.AutoHashMapUnmanaged(Vfs.FileId, void) = .empty;
    var requested_files: std.AutoHashMapUnmanaged(Vfs.FileId, void) = .empty;
    const list = try project_set.workspaceList(server, arena);
    defer project_set.releaseList(server, arena, list);
    for (list) |ws| {
        // Outside watch mode, the maker does not reconfigure automatically: restart
        const reconfigure = for (build_files.items) |dir| {
            if (server.vfs.samePath(dir, ws.root)) break true;
        } else for (known.items) |file| {
            if (ws.isBuildScript(file)) break true;
        } else for (events.keys(), events.values()) |path, kind| {
            const normalized = try Vfs.normalize(.native, arena, path) orelse continue;
            const change: Workspace.PathChange = switch (kind) {
                .Created => .created,
                .Changed => .changed,
                .Deleted => .deleted,
                _ => .changed,
            };
            if (ws.changesConfigureInput(normalized, change)) break true;
        } else false;
        if (reconfigure) {
            const started = for (refreshed.items) |dir| {
                if (server.vfs.samePath(dir, ws.root)) break true;
            } else false;
            if (!started) project_set.restartWorkspace(server, ws, 0);
            continue;
        }
        var owned: std.ArrayList(Vfs.FileId) = .empty;
        for (rebuilt.items) |file| if (ws.owns(file)) try owned.append(arena, file);
        if (owned.items.len == 0) continue;
        if (source == .notified and project_set.deferChanges(server, ws, owned.items)) {
            for (owned.items) |file| try deferred_files.put(arena, file, {});
            continue;
        }
        project_set.requestBuild(server, ws);
        for (owned.items) |file| try requested_files.put(arena, file, {});
    }
    if (edited.items.len != 0) {
        publishing.publishFiles(server, edited.items, true);
        publishing.publishDependents(server, edited.items);
        server.requestRefresh();
        publishing.scheduleCompileSetRefresh(server, edited.items);
    }
    if (rebuilt.items.len == 0) return changed;
    // Single-file mode: files imported by open files may have changed
    server.docs.mutex.lockUncancelable(server.io);
    const open = try arena.dupe(Vfs.FileId, server.docs.open.keys());
    server.docs.mutex.unlock(server.io);
    server.single.recompile(open, rebuilt.items);
    // If it cannot be recorded, the next change rebuilds as usual. The projects that decide when
    // their build completes record what they then compare.
    server.watched_built_mutex.lockUncancelable(server.io);
    defer server.watched_built_mutex.unlock(server.io);
    for (changes.items) |c| if (c.rebuild) {
        if (deferred_files.contains(c.file) and !requested_files.contains(c.file)) continue;
        server.watched_built.put(server.gpa, c.file, c.disk) catch {};
    };
    return changed;
}

/// Clients report a folder created, deleted, moved or renamed by its own path, without the files
/// in it: adds a change of every known file under such a path to `events` (re-read from disk, so
/// whether it still exists is decided then). Returns whether any event was such a folder.
fn addFolderContents(server: *Server, arena: Allocator, events: *std.StringArrayHashMapUnmanaged(types.FileChangeType)) Allocator.Error!bool {
    // Identity keys of directories: lowercased on a case-insensitive volume (see `Vfs`)
    const dirKey = struct {
        fn dirKey(vfs: *Vfs, out: *std.ArrayList(u8), a: Allocator, dir: []const u8) Allocator.Error![]const u8 {
            out.clearRetainingCapacity();
            try out.appendSlice(a, dir);
            if (vfs.caseOf(dir) == .insensitive) _ = std.ascii.lowerString(out.items, out.items);
            return out.items;
        }
    }.dirKey;
    var key: std.ArrayList(u8) = .empty;
    // The paths that are not known files
    var folders: std.StringHashMapUnmanaged(void) = .empty;
    for (events.keys()) |path| {
        if (try server.vfs.lookup(path) != null) continue;
        const normalized = try Vfs.normalize(.native, arena, path) orelse continue;
        try folders.put(arena, try arena.dupe(u8, try dirKey(&server.vfs, &key, arena, normalized)), {});
    }
    if (folders.count() == 0) return false;
    var found = false;
    for (0..server.vfs.count()) |i| {
        const path = server.vfs.path(@fromBackingInt(@as(u32, @intCast(i))));
        var dir = std.fs.path.dirname(path);
        while (dir) |d| : (dir = std.fs.path.dirname(d)) {
            if (!folders.contains(try dirKey(&server.vfs, &key, arena, d))) continue;
            found = true;
            const gop = try events.getOrPut(arena, path);
            if (!gop.found_existing) gop.value_ptr.* = .Changed;
            break;
        }
    }
    return found;
}

/// Whether file events change the user's source files under the root directories (see
/// `scheduleScan`): a source file the scan would find is created and is not known to be one yet,
/// or one of them is deleted
fn changesWorkspaceFiles(server: *Server, arena: Allocator, rules: origin.Rules, paths: []const []const u8, kinds: []const types.FileChangeType) !bool {
    var current: ?[]const Vfs.FileId = null;
    for (paths, kinds) |path, kind| {
        if (kind == .Changed or !workspace_files.contains(&server.vfs, rules, path)) continue;
        const file = try server.vfs.lookup(path) orelse {
            if (kind == .Created) return true;
            continue;
        };
        const list = current orelse blk: {
            var ctx = server.db.beginRead(arena);
            defer ctx.end();
            const value = ctx.get(WorkspaceFiles, {}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // A write transaction is waiting: scan instead of deciding here
                error.Canceled => return true,
            };
            break :blk try arena.dupe(Vfs.FileId, value);
        };
        current = list;
        const listed = std.sort.binarySearch(Vfs.FileId, list, file, struct {
            fn order(x: Vfs.FileId, y: Vfs.FileId) std.math.Order {
                return std.math.order(@backingInt(x), @backingInt(y));
            }
        }.order) != null;
        if (listed != (kind == .Created)) return true;
    }
    return false;
}

/// The file's known text is the same as `text` (including both being absent). A read that runs out
/// of memory counts as different (writing the disk contents loses no change); one canceled by a
/// write transaction waiting for the lock tells nothing about the file and fails with `Canceled`.
/// When the text was never set, the file is read from disk on demand (`SourceText`) and that read
/// is kept until the text is set, even to absent: the known text is then that read, and a file
/// never read has no text that anything was computed from. FSEvents reports writes made shortly
/// before the stream started, which are not changes to such files.
fn sameText(ctx: *Db.Ctx, file: Vfs.FileId, text: ?[]const u8) error{Canceled}!bool {
    const current = ctx.get(FileText, file) catch |err| switch (err) {
        error.OutOfMemory => return false,
        error.Canceled => return error.Canceled,
    };
    if (current) |known| return std.mem.eql(u8, known, text orelse return false);
    if (ctx.isSet(FileText, file)) return text == null;
    return switch (ctx.memoized(syntax_q.SourceText, file)) {
        .none => true,
        .computing, .evicted => false,
        .value => |read| if (read.owned) std.mem.eql(u8, read.text, text orelse return false) else text == null,
    };
}

/// What `sameText` compares the disk contents of a file with
const KnownText = enum {
    /// Nothing: its text was never set nor read from disk
    none,
    /// A read from disk (`SourceText`) in progress, whose result is not known yet
    reading,
    /// Its text as set, or as read from disk
    known,
};

fn knownText(ctx: *Db.Ctx, file: Vfs.FileId) KnownText {
    if (ctx.isSet(FileText, file)) return .known;
    return switch (ctx.memoized(syntax_q.SourceText, file)) {
        .none => .none,
        .computing => .reading,
        .evicted, .value => .known,
    };
}

fn knownTextOf(server: *Server, arena: Allocator, file: Vfs.FileId) KnownText {
    var ctx = server.db.beginRead(arena);
    defer ctx.end();
    return knownText(&ctx, file);
}

/// External changes discovered by the server: handled the same way as the client's
/// `workspace/didChangeWatchedFiles` notification (see `applyFileChanges`), serialized with main
/// loop message handling. Returns the files being read from disk (allocated in `arena`), to be
/// compared with the disk again.
pub fn applyWatchedChanges(server: *Server, arena: Allocator, changes: []const types.FileEvent, source: ChangeSource) []const []const u8 {
    var deferred: std.ArrayList([]const u8) = .empty;
    // A comparison with the disk that finds nothing changed is not a batch of external changes
    var counted = true;
    defer if (counted) {
        server.watch_mutex.lockUncancelable(server.io);
        server.watch_batches += 1;
        server.watch_mutex.unlock(server.io);
        server.watch_cond.broadcast(server.io);
    };
    server.write_mutex.lockUncancelable(server.io);
    defer server.write_mutex.unlock(server.io);
    if (server.state != .running or server.isShuttingDown()) return &.{};
    // Count as busy during processing: when a project restarts, the old instance finishes before
    // the new instance counts as busy, and the watch task itself does not count as busy; whoever
    // waits for idle (waitIdle, shutdown) must not be allowed to return in between
    server.busyBegin();
    defer server.busyEnd();
    const changed = applyFileChanges(server, arena, changes, source, &deferred) catch |err| blk: {
        log.err("applying changes on disk failed: {t}", .{err});
        break :blk true;
    };
    counted = changed or source == .notified;
    return deferred.items;
}

/// Files watched when the server discovers external changes (besides the project files of each
/// root directory): files interned in the Vfs (`.zig` / `.zon` and `@embedFile` files) that are
/// not virtual documents and not in dependency libraries. While the zig environment is unknown,
/// dependency libraries cannot be told apart yet, so nothing is watched.
pub fn watchable(server: *Server, rules: origin.Rules, path: []const u8) bool {
    if (rules.zig_lib == null) return false;
    return switch (origin.classify(&server.vfs, rules, path, false)) {
        .user, .outside, .other => true,
        .virtual, .zig_lib, .generated, .package => false,
    };
}

/// `path` is an open document
pub fn isOpen(server: *Server, path: []const u8) bool {
    const file = (server.vfs.lookup(path) catch return false) orelse return false;
    return openDocument(server, file);
}

/// `file` is an open document
fn openDocument(server: *Server, file: Vfs.FileId) bool {
    server.docs.mutex.lockUncancelable(server.io);
    defer server.docs.mutex.unlock(server.io);
    return server.docs.open.contains(file);
}

/// The watched files or the watch method may have changed: tells the watch task to recompute
pub fn resyncWatcher(server: *Server) void {
    if (server.watcher) |w| w.requestResync();
}

/// Directories among the configure inputs of all projects, including new instances that have
/// not replaced the old ones yet (see `Workspace.changesConfigureInput`): an entry created in or
/// deleted from them reconfigures the project, so they are watched. Copied into `arena`.
pub fn configureInputDirs(server: *Server, arena: Allocator) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    for (server.workspaces.items) |ws| {
        try ws.configureInputDirs(arena, &out);
        if (ws.successor) |s| try s.configureInputDirs(arena, &out);
    }
    return out.items;
}

/// Which files the server watches on disk itself (see `Config.Watcher`), from the narrowest
pub const WatchScope = enum {
    none,
    /// Files outside the root directories: the client watches those inside (clients apply the
    /// registered watchers inside the workspace folders only)
    outside_roots,
    all,
};

pub fn watchScope(server: *Server) WatchScope {
    return switch (server.config.load(.acquire).files_watcher) {
        .auto => if (clientWatches(server)) .outside_roots else .all,
        .client => .none,
        .server => .all,
    };
}

/// The client watches files: it supports registering file watchers, and has not rejected a
/// registration
pub fn clientWatches(server: *Server) bool {
    return server.caps.register_watch and !server.watch_registration_failed.load(.acquire);
}

/// The client answered a registration of file watchers with an error (an error answers a
/// registration request as a whole): with `files.watcher` set to `auto`, the server watches the
/// files itself instead
pub fn watchRegistrationFailed(server: *Server) void {
    if (server.watch_registration_failed.swap(true, .acq_rel)) return;
    log.info("the client cannot watch files, watching them on the server instead", .{});
    resyncWatcher(server);
}
