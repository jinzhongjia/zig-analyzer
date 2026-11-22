//! Single-file mode: standalone .zig files (see `FileContext.detached`) are compiled with
//! `zig build-obj -fno-emit-bin`, each as the root of its own compile.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const za = @import("../zig_analyzer.zig");
const panic_context = za.util.panic_context;
const Vfs = za.base.Vfs;
const compiler = za.diagnostics.compiler;
const Server = @import("Server.zig");
const config_sync = @import("config_sync.zig");
const doc_sync = @import("doc_sync.zig");
const project_set = @import("project_set.zig");
const publishing = @import("publishing.zig");

const log = std.log.scoped(.server);

const SingleFiles = @This();

/// Protects `entries`
mutex: Io.Mutex = .init,
/// Compile results keyed by the compiled root file. The results also include errors in files
/// imported by the root file.
entries: std.AutoArrayHashMapUnmanaged(Vfs.FileId, Entry) = .empty,
/// The `zig build-obj` processes of compiles in progress: ended when the server stops
compiles: za.project.bsp.SingleFileCompiles = .{},

pub const Entry = struct {
    result: ?*compiler.BuildResult = null,
    /// FileId → entry in `result` (the root file itself and the files it imports)
    files: std.AutoArrayHashMapUnmanaged(Vfs.FileId, *const compiler.FileResult) = .empty,
    /// Files under the root file's directory read by the compile that produced `result`
    /// (including the files it imports): a change to any of them requires recompiling
    inputs: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty,
    /// Compile result sequence number taken when `result` was stored: larger is newer
    generation: u64 = 0,
    running: bool = false,
    rerun: bool = false,
    /// The compile was deferred (a project is still loading for the first time): it runs after
    /// loading finishes (see `reconcile`)
    pending: bool = false,

    fn clearResult(sf: *Entry, gpa: Allocator) void {
        if (sf.result) |r| r.release(gpa);
        sf.result = null;
        sf.files.deinit(gpa);
        sf.files = .empty;
        sf.inputs.deinit(gpa);
        sf.inputs = .empty;
    }
};

pub fn deinit(s: *SingleFiles, gpa: Allocator) void {
    for (s.entries.values()) |*sf| sf.clearResult(gpa);
    s.entries.deinit(gpa);
}

fn owner(s: *SingleFiles) *Server {
    return @alignCast(@fieldParentPtr("single", s));
}

/// Compiles a detached file in the background with `zig build-obj -fno-emit-bin`; when requested
/// again during a compile, recompiles after that compile finishes
pub fn compile(s: *SingleFiles, file: Vfs.FileId) void {
    const server = s.owner();
    if (!server.startup_done.load(.acquire)) return; // compiled when startup finishes
    if (project_set.fileContext(server, file) != .detached) return;
    if (!config_sync.buildFlags(server).compiler) return;
    // The compiler reads from disk: a file that is not on disk (a new file not saved yet, a deleted
    // file) is not compiled, and its previous compile result is dropped
    Io.Dir.cwd().access(server.io, server.vfs.path(file), .{}) catch {
        _ = s.drop(file);
        return;
    };
    // While projects are loading for the first time, the file may turn out to belong to a project:
    // compile it when loading finishes rather than in the wrong context (see `reconcile`)
    const deferred = project_set.projectsLoading(server);
    {
        s.mutex.lockUncancelable(server.io);
        defer s.mutex.unlock(server.io);
        const gop = s.entries.getOrPut(server.gpa, file) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        if (deferred) {
            gop.value_ptr.pending = true;
            return;
        }
        gop.value_ptr.pending = false;
        if (gop.value_ptr.running) {
            gop.value_ptr.rerun = true;
            return;
        }
        gop.value_ptr.running = true;
    }
    server.busyBegin();
    // A compile takes seconds; avoid running it synchronously on the main loop where possible
    // (otherwise messages such as responses to progress tokens cannot be handled meanwhile)
    Server.spawn(server.io, &server.bg_group, task, .{ s, file });
}

/// Reconciles single-file mode with the current compile context of each file; called after the
/// contexts may have changed (the zig environment became ready, a project finished loading, a
/// compile set changed, a new instance replaced an old one, projects or root directories were added
/// or removed, build integration or compiler diagnostics were toggled): roots that are no longer
/// detached files drop their compile results; deferred compiles are run, and open detached files
/// that have never been compiled are compiled. Whether single-file results are used for a file
/// depends on that file's context (see `FileContext.usesSingle`), so the files in the results are
/// republished accordingly.
pub fn reconcile(s: *SingleFiles) void {
    const server = s.owner();
    if (server.isShuttingDown()) return;
    const gpa = server.gpa;
    var roots: std.ArrayList(Vfs.FileId) = .empty;
    defer roots.deinit(gpa);
    var affected: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty;
    defer affected.deinit(gpa);
    var to_compile: std.ArrayList(Vfs.FileId) = .empty;
    defer to_compile.deinit(gpa);
    {
        s.mutex.lockUncancelable(server.io);
        defer s.mutex.unlock(server.io);
        roots.appendSlice(gpa, s.entries.keys()) catch return;
        for (s.entries.values()) |*sf| for (sf.files.keys()) |f| affected.put(gpa, f, {}) catch return;
    }
    // The context is determined outside the lock: that
    // needs the locks of projects and root directories
    for (roots.items) |root| {
        const detached = project_set.fileContext(server, root) == .detached;
        s.mutex.lockUncancelable(server.io);
        defer s.mutex.unlock(server.io);
        const sf = s.entries.getPtr(root) orelse continue;
        if (detached) {
            if (sf.pending) to_compile.append(gpa, root) catch {};
            continue;
        }
        affected.put(gpa, root, {}) catch {};
        for (sf.files.keys()) |f| affected.put(gpa, f, {}) catch {};
        if (sf.running) {
            // Dropped according to the context when the compile finishes (see `task`)
            sf.rerun = true;
        } else {
            sf.clearResult(gpa);
            _ = s.entries.swapRemove(root);
        }
    }
    publishing.publishFiles(server, affected.keys(), true);

    server.docs.mutex.lockUncancelable(server.io);
    const open = gpa.dupe(Vfs.FileId, server.docs.open.keys()) catch {
        server.docs.mutex.unlock(server.io);
        return;
    };
    server.docs.mutex.unlock(server.io);
    defer gpa.free(open);
    {
        s.mutex.lockUncancelable(server.io);
        defer s.mutex.unlock(server.io);
        for (open) |file| if (!s.entries.contains(file)) to_compile.append(gpa, file) catch {};
    }
    for (to_compile.items) |file| s.compile(file);
    // Files in unloaded projects: the hint was deferred until startup finished
    // and projects finished loading (see `appendUnloadedProjectHint`), and the
    // context may also have just changed to this one
    var unloaded: std.ArrayList(Vfs.FileId) = .empty;
    defer unloaded.deinit(gpa);
    for (open) |file| if (project_set.fileContext(server, file) == .unloaded_project) unloaded.append(gpa, file) catch {};
    publishing.publishFiles(server, unloaded.items, false);
}

/// Recompiles single-file mode roots: `roots`, plus the roots whose last
/// compile read a file in `changed` or reported errors in one (e.g. a
/// root that imports the saved file). Each root is compiled only once.
pub fn recompile(s: *SingleFiles, roots: []const Vfs.FileId, changed: []const Vfs.FileId) void {
    const server = s.owner();
    var list: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty;
    defer list.deinit(server.gpa);
    for (roots) |root| list.put(server.gpa, root, {}) catch return;
    {
        s.mutex.lockUncancelable(server.io);
        defer s.mutex.unlock(server.io);
        for (s.entries.keys(), s.entries.values()) |root, *sf| {
            for (changed) |f| if (sf.inputs.contains(f) or sf.files.contains(f)) {
                list.put(server.gpa, root, {}) catch return;
                break;
            };
        }
    }
    for (list.keys()) |root| s.compile(root);
}

/// Drops the compile result of the root file `file`, which is no longer on disk, and republishes
/// the files that have errors in that result (errors in files it imports are cleared too). Returns
/// whether a result was dropped (`file` has then been republished as well).
pub fn drop(s: *SingleFiles, file: Vfs.FileId) bool {
    const server = s.owner();
    var affected: std.ArrayList(Vfs.FileId) = .empty;
    defer affected.deinit(server.gpa);
    {
        s.mutex.lockUncancelable(server.io);
        defer s.mutex.unlock(server.io);
        const sf = s.entries.getPtr(file) orelse return false;
        // An ongoing compile may have read the file before it was deleted: recompile when it
        // finishes (the file is no longer on disk, so the result is empty)
        if (sf.running) sf.rerun = true;
        if (sf.result == null) return false;
        affected.append(server.gpa, file) catch {};
        affected.appendSlice(server.gpa, sf.files.keys()) catch {};
        sf.clearResult(server.gpa);
    }
    publishing.publishFiles(server, affected.items, true);
    return true;
}

/// After a document is closed, frees its single-file results if they no longer need to be kept:
/// no compile is running, and the results contain no diagnostics (diagnostics continue to be
/// published after closing). When the file is reopened or saved later, it is recompiled on demand.
pub fn releaseIfUnused(s: *SingleFiles, file: Vfs.FileId) void {
    const server = s.owner();
    {
        s.mutex.lockUncancelable(server.io);
        defer s.mutex.unlock(server.io);
        const sf = s.entries.getPtr(file) orelse return;
        if (sf.running or sf.pending) return;
        if (sf.result) |r| for (r.files.values()) |fr| {
            if (fr.items.len != 0) return;
        };
        sf.clearResult(server.gpa);
        _ = s.entries.swapRemove(file);
    }
}

/// Clears the compiler diagnostics of single-file mode (when compiler diagnostics are disabled).
/// Root files not being compiled are no longer recorded; when re-enabled, the open files are
/// recompiled.
pub fn clear(s: *SingleFiles) void {
    const server = s.owner();
    var files: std.ArrayList(Vfs.FileId) = .empty;
    defer files.deinit(server.gpa);
    {
        s.mutex.lockUncancelable(server.io);
        defer s.mutex.unlock(server.io);
        var i: usize = s.entries.count();
        while (i > 0) {
            i -= 1;
            const sf = &s.entries.values()[i];
            if (sf.result != null) {
                files.append(server.gpa, s.entries.keys()[i]) catch {};
                files.appendSlice(server.gpa, sf.files.keys()) catch {};
            }
            sf.clearResult(server.gpa);
            if (!sf.running) s.entries.swapRemoveAt(i);
        }
    }
    publishing.publishFiles(server, files.items, true);
}

fn task(s: *SingleFiles, file: Vfs.FileId) Io.Cancelable!void {
    const server = s.owner();
    defer server.busyEnd();
    const path = server.vfs.path(file);
    var pc: panic_context.Text = .{};
    pc.enter("single-file compile {s}", .{path});
    defer pc.leave();
    var title_buf: [256]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Compiling {s}", .{std.fs.path.basename(path)}) catch "Compiling";
    const progress = server.progress.begin(server, title, false);
    var errors: usize = 0;
    defer server.progress.end(server, progress, if (errors == 0) "Done" else "Has errors");
    while (true) {
        // Taken for every compile: after the zig path configuration changes, recompiles use the new
        // environment
        const env = project_set.zigEnv(server).?;
        var inputs: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty;
        const result: ?*compiler.BuildResult = blk: {
            // The file has been deleted from disk (if deleted during a compile, `drop`
            // requests a recompile): no result
            Io.Dir.cwd().access(server.io, path, .{}) catch break :blk null;
            var compiled = za.project.bsp.compileSingleFile(server.gpa, server.io, env, path, &s.compiles) catch |err| switch (err) {
                // The server is stopping: the compile was ended, and nothing is published anymore
                error.Stopped => {
                    s.mutex.lockUncancelable(server.io);
                    defer s.mutex.unlock(server.io);
                    s.entries.getPtr(file).?.running = false;
                    return;
                },
                else => {
                    log.warn("{s}: single-file compile failed: {t}", .{ path, err });
                    break :blk null;
                },
            };
            defer compiled.deinit(server.gpa);
            errors = compiled.errors.errorMessageCount();
            for (compiled.inputs) |p| {
                const id = doc_sync.toolFile(server, p) catch continue;
                inputs.put(server.gpa, id, {}) catch continue;
            }
            break :blk compiler.collect(server.gpa, &.{compiled.errors}, std.fs.path.dirname(path) orelse ".", path, server, readDisk) catch null;
        };
        var files: std.AutoArrayHashMapUnmanaged(Vfs.FileId, *const compiler.FileResult) = .empty;
        if (result) |r| for (r.files.keys(), r.files.values()) |p, *fr| {
            const id = doc_sync.toolFile(server, p) catch continue;
            files.put(server.gpa, id, fr) catch continue;
        };
        // During the compile, the file may have stopped being a detached file (its project finished
        // loading, a build.zig was created in its root directory, etc.), or compiler diagnostics
        // may have been turned off: in either case this result is not used
        const detached = project_set.fileContext(server, file) == .detached and config_sync.buildFlags(server).compiler;
        s.mutex.lockUncancelable(server.io);
        const sf = s.entries.getPtr(file).?;
        if (detached and sf.rerun) {
            sf.rerun = false;
            s.mutex.unlock(server.io);
            files.deinit(server.gpa);
            inputs.deinit(server.gpa);
            if (result) |r| r.release(server.gpa);
            continue;
        }
        // Affected files: the root file itself, and the files with errors in the previous and the
        // current result (imported files included)
        var affected: std.ArrayList(Vfs.FileId) = .empty;
        defer affected.deinit(server.gpa);
        affected.append(server.gpa, file) catch {};
        affected.appendSlice(server.gpa, sf.files.keys()) catch {};
        sf.clearResult(server.gpa);
        if (detached) {
            affected.appendSlice(server.gpa, files.keys()) catch {};
            sf.result = result;
            sf.files = files;
            sf.inputs = inputs;
            sf.generation = server.nextCompileGeneration();
            sf.running = false;
        } else {
            // Discard this result and stop tracking this root file
            files.deinit(server.gpa);
            inputs.deinit(server.gpa);
            if (result) |r| r.release(server.gpa);
            _ = s.entries.swapRemove(file);
        }
        s.mutex.unlock(server.io);
        publishing.publishFiles(server, affected.items, true);
        return;
    }
}

fn readDisk(ctx: *anyopaque, gpa: Allocator, path: []const u8) ?[]u8 {
    const server: *Server = @ptrCast(@alignCast(ctx));
    return Io.Dir.cwd().readFileAlloc(server.io, path, gpa, .limited(Vfs.max_file_size)) catch null;
}
