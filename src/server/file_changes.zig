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
const Text = database.inputs.Text;
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
    server.changes_mutex.lockUncancelable(server.io);
    defer server.changes_mutex.unlock(server.io);
    var prepared = try prepareFileChanges(server, arena, params.changes, .notified);
    defer prepared.deinit(server.gpa);
    server.write_mutex.lockUncancelable(server.io);
    defer server.write_mutex.unlock(server.io);
    _ = try applyFileChanges(server, arena, &prepared, .notified, null);
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

/// Disk contents of one file of a batch of external changes
const Read = struct {
    /// Contents read from disk; null if the file does not exist (or is too big)
    text: ?*Text,
    /// Hash of `text`; null if there are no contents
    hash: ?u64,
};

/// A batch of external changes with the disk contents of its files read before `write_mutex` was
/// taken (see `prepareFileChanges`). Its maps live in the caller's arena; `deinit` frees the disk
/// contents that `applyFileChanges` did not take: those of files that were opened in between, or
/// that it does not need.
pub const Prepared = struct {
    /// The file events, with the known files under a changed folder added (see
    /// `addFolderContents`); the last of several events for a path wins
    events: std.StringArrayHashMapUnmanaged(types.FileChangeType) = .empty,
    /// Disk contents of the files that were read, by path
    reads: std.StringArrayHashMapUnmanaged(Read) = .empty,
    /// An event was a folder (see `addFolderContents`)
    folders: bool = false,

    pub fn deinit(p: *Prepared, gpa: Allocator) void {
        for (p.reads.values()) |r| if (r.text) |t| t.release(gpa);
        p.* = .{};
    }
};

/// Disk contents as a text buffer shared with `FileText`
fn asText(gpa: Allocator, disk: ?[]u8) Allocator.Error!?*Text {
    const bytes = disk orelse return null;
    defer gpa.free(bytes);
    return try .init(gpa, bytes);
}

/// Reads the disk contents of the files of a batch of external changes, and adds the known files
/// under the folders in it (see `addFolderContents`), before `write_mutex` is taken. The files
/// that `applyFileChanges` needs are read; it reads one itself when the state changed in between
/// such that the read was skipped. Files that it would skip are not read.
pub fn prepareFileChanges(server: *Server, arena: Allocator, file_events: []const types.FileEvent, source: ChangeSource) !Prepared {
    var prepared: Prepared = .{};
    errdefer prepared.deinit(server.gpa);
    for (file_events) |event| {
        const path = uri.toPath(arena, event.uri) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnsupportedScheme, error.InvalidUri => continue,
        };
        if (!std.fs.path.isAbsolute(path)) continue;
        try prepared.events.put(arena, path, event.type);
    }
    prepared.folders = try addFolderContents(server, arena, &prepared.events);
    try prepared.reads.ensureTotalCapacity(arena, prepared.events.count());
    for (prepared.events.keys(), prepared.events.values()) |path, kind| {
        // A deleted file has no contents to read
        if (kind == .Deleted) continue;
        const file = try server.vfs.lookup(path);
        const read: ?[]u8 = if (file) |id| blk: {
            const is_open = blk_open: {
                server.docs.mutex.lockUncancelable(server.io);
                defer server.docs.mutex.unlock(server.io);
                break :blk_open server.docs.open.contains(id);
            };
            // The same files `applyFileChanges` skips
            if (source == .verified) {
                if (is_open) continue;
                switch (knownTextOf(server, arena, id)) {
                    .none, .reading => continue,
                    .known => {},
                }
            }
            break :blk server.vfs.readFromDisk(id, server.gpa) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                error.FileTooBig => null,
            };
        } else blk: {
            // A file never seen has no known contents to update (a new file is loaded when it is
            // imported); project files count as changed unless the project started with these
            // contents
            if (source == .verified or !doc_sync.isProjectFile(std.fs.path.basename(path))) continue;
            break :blk Io.Dir.cwd().readFileAlloc(server.io, path, server.gpa, .limited(Vfs.max_file_size)) catch |err| switch (err) {
                error.OutOfMemory, error.Canceled => |e| return e,
                else => null,
            };
        };
        const text = try asText(server.gpa, read);
        const hash: ?u64 = if (text) |t| std.hash.Wyhash.hash(0, t.bytes()) else null;
        prepared.reads.putAssumeCapacity(path, .{ .text = text, .hash = hash });
    }
    return prepared;
}

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
/// basis, or a project started or stopped. The disk contents were read before `write_mutex` was
/// taken (see `prepareFileChanges`); the state decisions and the database writes re-check the
/// state and take the reads. When `deferred` is given, the files being read from disk are added to
/// it instead of being compared with the disk: what the read gets is not known yet, so their text
/// is compared again once the read is done (see `applyWatchedChanges`). The rebuild of a notified
/// change does not wait for that, since the builds read the disk.
fn applyFileChanges(server: *Server, arena: Allocator, prepared: *Prepared, source: ChangeSource, deferred: ?*std.ArrayList([]const u8)) !bool {
    const Change = struct {
        file: Vfs.FileId,
        path: []const u8,
        /// Disk contents to write; null for open documents (their buffer is authoritative)
        text: ?*Text,
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
    defer for (changes.items) |c| if (c.text) |t| t.release(server.gpa);
    const rules = try server.originRules(arena);
    var build_files: std.ArrayList([]const u8) = .empty;
    var build_zig_dirs: std.ArrayList([]const u8) = .empty;
    // Known files that changed
    var known: std.ArrayList(Vfs.FileId) = .empty;
    const events = &prepared.events;
    // A folder created, deleted, moved or renamed is reported by its own path only
    const folders = prepared.folders;
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
            const disk: ?u64 = if (kind == .Deleted) null else blk: {
                if (prepared.reads.get(path)) |r| break :blk r.hash;
                // The read was skipped because the state said so (see `prepareFileChanges`): read
                // it here
                const read = Io.Dir.cwd().readFileAlloc(server.io, path, server.gpa, .limited(Vfs.max_file_size)) catch |err| switch (err) {
                    error.OutOfMemory, error.Canceled => |e| return e,
                    else => null,
                };
                defer if (read) |t| server.gpa.free(t);
                break :blk if (read) |t| std.hash.Wyhash.hash(0, t) else null;
            };
            if (!doc_sync.projectStartedWith(server, path, disk)) try build_files.append(arena, dir);
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
        // The disk contents were read before `write_mutex`; the read moved the text into `read`
        var read: ?*Text = null;
        var disk: ?u64 = null;
        if (kind != .Deleted) {
            if (prepared.reads.getPtr(path)) |r| {
                read = r.text;
                r.text = null;
                disk = r.hash;
            } else {
                // The read was skipped because the state said so (see `prepareFileChanges`), and
                // the state has changed: read it here
                const contents = server.vfs.readFromDisk(file, server.gpa) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Canceled => return error.Canceled,
                    error.FileTooBig => null,
                };
                read = try asText(server.gpa, contents);
                disk = if (read) |t| std.hash.Wyhash.hash(0, t.bytes()) else null;
            }
        }
        const text = if (is_open) blk: {
            if (read) |t| t.release(server.gpa);
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
            if (text) |t| t.release(server.gpa);
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
                if (c.text) |t| t.release(server.gpa);
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
    var folder_paths: std.ArrayList([]const u8) = .empty;
    for (events.keys()) |path| {
        if (try server.vfs.lookup(path) != null) continue;
        const normalized = try Vfs.normalize(.native, arena, path) orelse continue;
        const folder_key = try dirKey(&server.vfs, &key, arena, normalized);
        const gop = try folders.getOrPut(arena, try arena.dupe(u8, folder_key));
        if (!gop.found_existing) try folder_paths.append(arena, normalized);
    }
    if (folder_paths.items.len == 0) return false;
    var found = false;
    for (0..server.vfs.count()) |i| {
        const path = server.vfs.path(@fromBackingInt(@as(u32, @intCast(i))));
        var under = false;
        for (folder_paths.items) |folder| if (path.len > folder.len and server.vfs.isUnder(path, folder)) {
            under = true;
            break;
        };
        if (!under) continue;
        found = true;
        const gop = try events.getOrPut(arena, path);
        if (!gop.found_existing) gop.value_ptr.* = .Changed;
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
fn sameText(ctx: *Db.Ctx, file: Vfs.FileId, text: ?*Text) error{Canceled}!bool {
    const current = ctx.get(FileText, file) catch |err| switch (err) {
        error.OutOfMemory => return false,
        error.Canceled => return error.Canceled,
    };
    if (current) |known| return std.mem.eql(u8, known.bytes(), if (text) |t| t.bytes() else return false);
    if (ctx.isSet(FileText, file)) return text == null;
    return switch (ctx.memoized(syntax_q.SourceText, file)) {
        .none => true,
        .computing, .evicted => false,
        .value => |read| if (read.owned) std.mem.eql(u8, read.text, if (text) |t| t.bytes() else return false) else text == null,
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
/// loop message handling. The disk is read before `write_mutex` is taken (see
/// `prepareFileChanges`). Returns the files being read from disk (allocated in `arena`), to be
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
    server.changes_mutex.lockUncancelable(server.io);
    defer server.changes_mutex.unlock(server.io);
    var prepared = prepareFileChanges(server, arena, changes, source) catch |err| {
        // A canceled batch is dropped, not a failure: the server is shutting down (see `Server.deinit`)
        if (err != error.Canceled) log.err("applying changes on disk failed: {t}", .{err});
        return &.{};
    };
    defer prepared.deinit(server.gpa);
    server.write_mutex.lockUncancelable(server.io);
    defer server.write_mutex.unlock(server.io);
    if (server.state != .running or server.isShuttingDown()) return &.{};
    // Count as busy during processing: when a project restarts, the old instance finishes before
    // the new instance counts as busy, and the watch task itself does not count as busy; whoever
    // waits for idle (waitIdle, shutdown) must not be allowed to return in between
    server.busyBegin();
    defer server.busyEnd();
    const changed = applyFileChanges(server, arena, &prepared, source, &deferred) catch |err| blk: {
        // A canceled batch is dropped, not a failure: the server is shutting down (see `Server.deinit`)
        if (err != error.Canceled) log.err("applying changes on disk failed: {t}", .{err});
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

const test_support = struct {
    fn text(server: *Server, a: Allocator, file: Vfs.FileId) !?[]const u8 {
        var ctx = server.db.beginRead(a);
        defer ctx.end();
        const value = try ctx.get(FileText, file);
        return if (value) |t| try a.dupe(u8, t.bytes()) else null;
    }

    fn isSet(server: *Server, a: Allocator, file: Vfs.FileId) !bool {
        var ctx = server.db.beginRead(a);
        defer ctx.end();
        return ctx.isSet(FileText, file);
    }
};

test "a document opened after the disk read keeps its buffer" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var writer: za.lsp.transport.Writer = .{ .io = testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(testing.io, gpa, &writer);
    defer server.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, "a.zig" });
    const disk = "const disk = 1;\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = disk });
    const file = try server.vfs.intern(path);
    {
        server.db.beginWrite();
        defer server.db.endWrite();
        try server.db.set(FileText, file, try Text.init(gpa, disk), .low);
    }
    // The rebuild basis is the disk contents: opening the document need not rebuild
    {
        server.watched_built_mutex.lockUncancelable(server.io);
        defer server.watched_built_mutex.unlock(server.io);
        try server.watched_built.put(gpa, file, std.hash.Wyhash.hash(0, disk));
    }
    const event: types.FileEvent = .{ .uri = try uri.fromPath(a, path), .type = .Changed };
    var prepared = try prepareFileChanges(&server, a, &.{event}, .notified);
    defer prepared.deinit(server.gpa);
    // The client opened the document after the disk read: the buffer is authoritative
    const buffer = "const buffer = 2;\n";
    {
        var doc: doc_sync.OpenDoc = .{};
        try doc.docs.append(gpa, .{ .uri = try gpa.dupe(u8, event.uri), .version = 1 });
        try server.docs.open.put(gpa, file, doc);
    }
    {
        server.db.beginWrite();
        defer server.db.endWrite();
        try server.db.set(FileText, file, try Text.init(gpa, buffer), .low);
    }
    try testing.expect(!try applyFileChanges(&server, a, &prepared, .notified, null));
    try testing.expectEqualStrings(buffer, (try test_support.text(&server, a, file)).?);
}

test "a batch of created, changed and deleted files applies from the disk contents" {
    const testing = std.testing;
    const gpa = testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var writer: za.lsp.transport.Writer = .{ .io = testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(testing.io, gpa, &writer);
    defer server.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const mod_path = try std.fs.path.join(a, &.{ dir, "mod.zig" });
    const del_path = try std.fs.path.join(a, &.{ dir, "del.zig" });
    const new_path = try std.fs.path.join(a, &.{ dir, "new.zig" });
    const mod_disk = "pub const mod = 2;\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "mod.zig", .data = mod_disk });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "new.zig", .data = "pub const new = 3;\n" });
    const mod = try server.vfs.intern(mod_path);
    const del = try server.vfs.intern(del_path);
    {
        server.db.beginWrite();
        defer server.db.endWrite();
        try server.db.set(FileText, mod, try Text.init(gpa, "pub const mod = 1;\n"), .low);
        try server.db.set(FileText, del, try Text.init(gpa, "pub const del = 1;\n"), .low);
    }
    // Both rebuilds are based on the new state: neither file is rebuilt
    {
        server.watched_built_mutex.lockUncancelable(server.io);
        defer server.watched_built_mutex.unlock(server.io);
        try server.watched_built.put(gpa, mod, std.hash.Wyhash.hash(0, mod_disk));
        try server.watched_built.put(gpa, del, null);
    }
    const events = [_]types.FileEvent{
        .{ .uri = try uri.fromPath(a, mod_path), .type = .Changed },
        .{ .uri = try uri.fromPath(a, del_path), .type = .Deleted },
        .{ .uri = try uri.fromPath(a, new_path), .type = .Created },
    };
    var prepared = try prepareFileChanges(&server, a, &events, .notified);
    defer prepared.deinit(server.gpa);
    try testing.expect(try applyFileChanges(&server, a, &prepared, .notified, null));
    try testing.expectEqualStrings(mod_disk, (try test_support.text(&server, a, mod)).?);
    try testing.expect(try test_support.isSet(&server, a, del));
    try testing.expect((try test_support.text(&server, a, del)) == null);
    // A file that was never seen is not loaded
    try testing.expect((try server.vfs.lookup(new_path)) == null);
}
