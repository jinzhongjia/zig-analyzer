//! Document sync: the URIs of open documents, virtual documents, and `textDocument/didOpen`,
//! `didChange`, `didClose`, and `didSave`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const za = @import("../zig_analyzer.zig");
const types = za.lsp.types;
const jsonrpc = za.lsp.jsonrpc;
const transport = za.lsp.transport;
const offsets = za.util.offsets;
const uri = za.base.uri;
const Vfs = za.base.Vfs;
const database = @import("../database.zig");
const FileText = database.inputs.FileText;
const Workspace = @import("Workspace.zig");
const origin = @import("origin.zig");

const Server = @import("Server.zig");
const indexing = @import("indexing.zig");
const project_set = @import("project_set.zig");
const publishing = @import("publishing.zig");

const log = std.log.scoped(.server);

fn fileIdFromUri(server: *Server, arena: Allocator, document_uri: []const u8) !?Vfs.FileId {
    const path = try documentPath(server, arena, document_uri) orelse return null;
    return try server.vfs.intern(path);
}

/// FileId of a document the client opens. A path the server does not know under this spelling
/// may reach through symbolic links a file the server knows by its real path, or a file of a
/// dependency library, whose locations come from tools that resolve symbolic links (`zig env`
/// locates the Zig installation from the real path of the zig executable, so Homebrew's
/// `/opt/homebrew/lib/zig` is reported under its `Cellar`): the document's path then becomes an
/// alias of the file at the real path (see `Vfs.alias`). The file keeps its origin and its
/// module, and its diagnostics are published on the document's URI.
fn documentFile(server: *Server, arena: Allocator, document_uri: []const u8) !?Vfs.FileId {
    const path = try documentPath(server, arena, document_uri) orelse return null;
    if (try server.vfs.lookup(path)) |id| return id;
    if (!isVirtual(path)) if (try Vfs.realPath(server.io, arena, path)) |real| if (!std.mem.eql(u8, real, path)) {
        const known = try server.vfs.lookup(real) orelse blk: {
            const rules = try server.originRules(arena);
            if (!origin.classify(&server.vfs, rules, real, false).isLibrary()) break :blk null;
            break :blk try server.vfs.intern(real);
        };
        if (known) |id| {
            try server.vfs.alias(path, id);
            return id;
        }
    };
    return try server.vfs.intern(path);
}

/// FileId of a path a tool reported (compiler and build results). A path the server does not
/// know under this spelling may name a file the client has open under another one (through a
/// symbolic link, or with names in another Unicode normalization form): the path then becomes
/// an alias of that document (see `Vfs.alias`), and its diagnostics are published on the
/// document's URI. Only unknown paths are resolved on disk, and only while documents are open.
pub fn toolFile(server: *Server, path: []const u8) Allocator.Error!Vfs.FileId {
    if (try server.vfs.lookup(path)) |id| return id;
    if (try openDocumentAt(server, path)) |id| {
        try server.vfs.alias(path, id);
        return id;
    }
    return server.vfs.intern(path);
}

/// The open document whose file on disk is `path` (equal real paths)
fn openDocumentAt(server: *Server, path: []const u8) Allocator.Error!?Vfs.FileId {
    server.docs.mutex.lockUncancelable(server.io);
    defer server.docs.mutex.unlock(server.io);
    if (server.docs.open.count() == 0) return null;
    const real = try Vfs.realPath(server.io, server.gpa, path) orelse return null;
    defer server.gpa.free(real);
    for (server.docs.open.keys()) |doc| {
        const gop = try server.docs.real.getOrPut(server.gpa, doc);
        if (!gop.found_existing) gop.value_ptr.* = Vfs.realPath(server.io, server.gpa, server.vfs.path(doc)) catch |err| {
            _ = server.docs.real.remove(doc);
            return err;
        };
        if (gop.value_ptr.*) |r| if (std.mem.eql(u8, r, real)) return doc;
    }
    return null;
}

/// Drops the cached real path of an open document (`file`, or all when null). Callers hold
/// `docs.mutex`.
pub fn forgetRealPath(server: *Server, file: ?Vfs.FileId) void {
    if (file) |f| {
        if (server.docs.real.fetchRemove(f)) |kv| if (kv.value) |r| server.gpa.free(r);
        return;
    }
    var it = server.docs.real.valueIterator();
    while (it.next()) |r| if (r.*) |p| server.gpa.free(p);
    server.docs.real.clearRetainingCapacity();
}

/// Path of a document: the path of a file URI; a document with a non-file URI such as `untitled:`
/// maps to a path named after the URI under a virtual directory (it does not clash with real
/// files and does not exist on disk, so it is not passed to the compiler; other features treat it
/// as a single file). The virtual path ends in `.zon` for a document opened with languageId
/// `zon`, in `.zig` for languageId `zig`, and otherwise follows the end of the URI.
pub fn documentPath(server: *Server, arena: Allocator, document_uri: []const u8) Allocator.Error!?[]const u8 {
    const path = uri.toPath(arena, document_uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedScheme => {
            const zon = blk: {
                server.docs.mutex.lockUncancelable(server.io);
                defer server.docs.mutex.unlock(server.io);
                break :blk server.docs.virtual_langs.get(document_uri) orelse std.mem.endsWith(u8, document_uri, ".zon");
            };
            const ext = if (zon) ".zon" else ".zig";
            return try std.fmt.allocPrint(arena, "{s}{c}{x:0>16}{s}", .{ virtual_root, std.fs.path.sep, std.hash.Wyhash.hash(0, document_uri), ext });
        },
        error.InvalidUri => return null,
    };
    if (!std.fs.path.isAbsolute(path)) return null;
    return path;
}

/// Records the language of a document opened with a non-file URI (see `documentPath`)
fn setVirtualLanguage(server: *Server, document_uri: []const u8, language_id: []const u8) Allocator.Error!void {
    if (uri.isFile(document_uri)) return;
    const zon = if (std.mem.eql(u8, language_id, "zon")) true else if (std.mem.eql(u8, language_id, "zig")) false else return;
    server.docs.mutex.lockUncancelable(server.io);
    defer server.docs.mutex.unlock(server.io);
    const gop = try server.docs.virtual_langs.getOrPut(server.gpa, document_uri);
    if (!gop.found_existing) gop.key_ptr.* = server.gpa.dupe(u8, document_uri) catch |err| {
        server.docs.virtual_langs.removeByPtr(gop.key_ptr);
        return err;
    };
    gop.value_ptr.* = zon;
}

/// Forgets the language of a closed document (see `setVirtualLanguage`)
fn clearVirtualLanguage(server: *Server, document_uri: []const u8) void {
    server.docs.mutex.lockUncancelable(server.io);
    defer server.docs.mutex.unlock(server.io);
    if (server.docs.virtual_langs.fetchRemove(document_uri)) |kv| server.gpa.free(kv.key);
}

/// Virtual directory for documents with non-file URIs
const virtual_root = if (@import("builtin").os.tag == .windows) "C:\\.zig-analyzer-virtual" else "/.zig-analyzer-virtual";

pub fn isVirtual(path: []const u8) bool {
    return Vfs.isUnderStyle(.native, .sensitive, path, virtual_root);
}

fn setFileText(server: *Server, id: Vfs.FileId, text: ?[]const u8) !void {
    const owned = if (text) |t| try server.gpa.dupe(u8, t) else null;
    server.db.beginWrite();
    defer server.db.endWrite();
    try server.db.set(FileText, id, owned, .low);
}

/// The documents the client has a file open under. A file has several when the client opens
/// spellings of its path that differ only in case on a case-insensitive volume: they are one
/// file, as the operating system and the compiler see them. The file has the text of the
/// document opened or changed last, and its diagnostics are published to each document. While
/// several are open, each keeps the client's text of it, so edits apply to the text of their own
/// document and closing one leaves the file with the text of another; the disk contents apply
/// once the last one is closed.
pub const OpenDoc = struct {
    /// Ordered by the last open or change: the last one is the current document, whose text the
    /// file has
    docs: std.ArrayList(Doc) = .empty,

    const Doc = struct {
        /// The URI used by the client (used verbatim when publishing diagnostics)
        uri: []u8,
        /// The client's text of the document, kept while the file has several documents
        text: ?[]u8 = null,
        version: i32,

        fn deinit(d: Doc, gpa: Allocator) void {
            gpa.free(d.uri);
            if (d.text) |t| gpa.free(t);
        }
    };

    pub fn deinit(o: *OpenDoc, gpa: Allocator) void {
        for (o.docs.items) |d| d.deinit(gpa);
        o.docs.deinit(gpa);
    }

    pub fn current(o: *const OpenDoc) *Doc {
        return &o.docs.items[o.docs.items.len - 1];
    }

    pub fn find(o: *const OpenDoc, document_uri: []const u8) ?usize {
        for (o.docs.items, 0..) |d, i| if (std.mem.eql(u8, d.uri, document_uri)) return i;
        return null;
    }

    /// Makes document `i` the current one
    fn makeCurrent(o: *OpenDoc, i: usize) void {
        const d = o.docs.orderedRemove(i);
        o.docs.appendAssumeCapacity(d);
    }
};

pub fn didOpen(server: *Server, arena: Allocator, params: types.DidOpenTextDocumentParams) !void {
    try setVirtualLanguage(server, params.textDocument.uri, params.textDocument.languageId);
    const id = try documentFile(server, arena, params.textDocument.uri) orelse return;
    {
        server.watched_built_mutex.lockUncancelable(server.io);
        defer server.watched_built_mutex.unlock(server.io);
        _ = server.watched_built.remove(id);
    }
    {
        const owned = try server.gpa.dupe(u8, params.textDocument.text);
        server.db.beginWrite();
        defer server.db.endWrite();
        addDocument(server, id, params.textDocument) catch |err| {
            server.gpa.free(owned);
            return err;
        };
        try server.db.set(FileText, id, owned, .low);
        try setDocVersion(server, id, params.textDocument.version);
        // Before a new session starts, wait for old read requests to exit; it must not inherit
        // delta baselines from the period while the document was closed or from the old session.
        server.semantic_cache.remove(server.io, server.gpa, id);
    }
    // Before publishing: a file of a sub-project then belongs to its project (loading)
    project_set.startSubProjectFor(server, server.vfs.path(id));
    publishing.publishFiles(server, &.{id}, false);
    publishing.publishDependents(server, &.{id});
    if (server.openDocumentCount() > 1) server.requestRefresh();
    server.single.compile(id);
    publishing.scheduleCompileSetRefresh(server, &.{id});
    // The auto-import index starts here so that the first completion at a name includes
    // auto-imports
    indexing.requestAutoImportIndex(server);
}

/// Records `item` as the current document of its file `id` (see `OpenDoc`); called in the write
/// transaction that sets the file's text
fn addDocument(server: *Server, id: Vfs.FileId, item: types.TextDocumentItem) Allocator.Error!void {
    const gpa = server.gpa;
    server.docs.mutex.lockUncancelable(server.io);
    defer server.docs.mutex.unlock(server.io);
    forgetRealPath(server, id);
    try server.docs.last_uris.ensureUnusedCapacity(gpa, 1);
    const gop = try server.docs.open.getOrPut(gpa, id);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const open = gop.value_ptr;
    errdefer if (open.docs.items.len == 0) {
        open.deinit(gpa);
        _ = server.docs.open.swapRemove(id);
    };
    // Opened again under the same URI: the new text replaces the old one
    if (open.find(item.uri)) |i| open.docs.orderedRemove(i).deinit(gpa);
    try open.docs.ensureUnusedCapacity(gpa, 1);
    const doc_uri = try gpa.dupe(u8, item.uri);
    errdefer gpa.free(doc_uri);
    const last = try gpa.dupe(u8, item.uri);
    errdefer gpa.free(last);
    var text: ?[]u8 = null;
    if (open.docs.items.len != 0) {
        // The file gets several documents: the one open so far keeps the file's text
        const other = &open.docs.items[0];
        if (other.text == null) other.text = try gpa.dupe(u8, server.db.peek(FileText, id) orelse "");
        text = try gpa.dupe(u8, item.text);
    }
    open.docs.appendAssumeCapacity(.{ .uri = doc_uri, .text = text, .version = item.version });
    const lgop = server.docs.last_uris.getOrPutAssumeCapacity(id);
    if (lgop.found_existing) gpa.free(lgop.value_ptr.*);
    lgop.value_ptr.* = last;
}

/// Changes to a document that is not open are ignored: the client owns a document's text only
/// between didOpen and didClose
pub fn didChange(server: *Server, arena: Allocator, params: types.DidChangeTextDocumentParams) !void {
    const path = try documentPath(server, arena, params.textDocument.uri) orelse return;
    const id = try server.vfs.lookup(path) orelse return;
    {
        server.db.beginWrite();
        defer server.db.endWrite();
        const new = try changeDocument(server, id, params) orelse return;
        try server.db.set(FileText, id, new, .low);
        try setDocVersion(server, id, params.textDocument.version);
    }
    publishing.publishDebounced(server, id);
}

/// Applies the changes of `params` to its document of file `id` and makes it the current one
/// (see `OpenDoc`); returns the new text of the file (owned by the caller), or null when the
/// document is not open. Called in a write transaction.
fn changeDocument(server: *Server, id: Vfs.FileId, params: types.DidChangeTextDocumentParams) Allocator.Error!?[]u8 {
    const gpa = server.gpa;
    server.docs.mutex.lockUncancelable(server.io);
    defer server.docs.mutex.unlock(server.io);
    const open = server.docs.open.getPtr(id) orelse return null;
    const i = open.find(params.textDocument.uri) orelse return null;
    const doc = &open.docs.items[i];
    const old = doc.text orelse {
        const new = try offsets.applyChanges(gpa, server.db.peek(FileText, id) orelse "", params.contentChanges, server.encoding);
        doc.version = params.textDocument.version;
        return new;
    };
    const new = try offsets.applyChanges(gpa, old, params.contentChanges, server.encoding);
    errdefer gpa.free(new);
    const file_text = try gpa.dupe(u8, new);
    gpa.free(old);
    doc.text = new;
    doc.version = params.textDocument.version;
    open.makeCurrent(i);
    return file_text;
}

fn setDocVersion(server: *Server, id: Vfs.FileId, version: i32) Allocator.Error!void {
    server.docs.mutex.lockUncancelable(server.io);
    defer server.docs.mutex.unlock(server.io);
    try server.docs.versions.put(server.gpa, id, version);
}

/// The version of `file` when it is open in the client; null otherwise
pub fn docVersion(server: *Server, file: Vfs.FileId) ?i32 {
    server.docs.mutex.lockUncancelable(server.io);
    defer server.docs.mutex.unlock(server.io);
    return server.docs.versions.get(file);
}

pub fn didClose(server: *Server, arena: Allocator, params: types.DidCloseTextDocumentParams) !void {
    const id = try fileIdFromUri(server, arena, params.textDocument.uri) orelse return;
    clearVirtualLanguage(server, params.textDocument.uri);
    switch (try closeDocument(server, id, params.textDocument.uri)) {
        .last => {},
        .not_open => return,
        .others => {
            // The file stays open under its other documents, with the text of one of them
            clearDocument(server, params.textDocument.uri);
            publishing.publishFiles(server, &.{id}, false);
            publishing.publishDependents(server, &.{id});
            server.requestRefresh();
            publishing.scheduleCompileSetRefresh(server, &.{id});
            return;
        },
    }
    defer {
        // Even if reading from disk or replacing the text fails, still wait for old read requests
        // to exit first, which prevents a snapshot from being written again after closing.
        server.db.beginWrite();
        defer server.db.endWrite();
        server.semantic_cache.remove(server.io, server.gpa, id);
    }
    // After closing, the disk contents are authoritative
    {
        server.docs.mutex.lockUncancelable(server.io);
        defer server.docs.mutex.unlock(server.io);
        _ = server.docs.versions.remove(id);
    }
    const disk = server.vfs.readFromDisk(id, arena) catch |err| switch (err) {
        error.FileTooBig => null,
        else => |e| return e,
    };
    try setFileText(server, id, disk);
    {
        server.docs.mutex.lockUncancelable(server.io);
        defer server.docs.mutex.unlock(server.io);
        if (server.docs.open.fetchSwapRemove(id)) |kv| {
            var open = kv.value;
            // Diagnostics published after closing go to the URI the document was closed under
            if (server.docs.last_uris.getPtr(id)) |last| if (!std.mem.eql(u8, last.*, params.textDocument.uri)) {
                std.mem.swap([]u8, last, &open.current().uri);
            };
            open.deinit(server.gpa);
        }
        forgetRealPath(server, id);
    }
    publishing.publishDependents(server, &.{id});
    server.requestRefresh();
    publishing.scheduleCompileSetRefresh(server, &.{id});
    // When a single-file mode root file was deleted from disk while open (notifications of
    // external changes skip open files), drop its compile results on close and republish the files
    // it imports as well
    if (disk == null and server.single.drop(id)) return;
    // Results that are no longer needed after closing are freed immediately, so they do not grow
    // linearly with the files opened over a long session
    server.single.releaseIfUnused(id);
    // After closing, republish from the disk contents (files in the compile set may still have
    // compiler diagnostics)
    publishing.publishFiles(server, &.{id}, true);
}

/// Removes the document `document_uri` of file `id` (see `OpenDoc`). When other documents of the
/// file stay open, the file takes the text of the current one. `.last`: it is the file's only
/// document, or the file has none (the caller restores the disk contents and removes it);
/// `.not_open`: the file is open, but not under this URI.
fn closeDocument(server: *Server, id: Vfs.FileId, document_uri: []const u8) Allocator.Error!enum { last, others, not_open } {
    const gpa = server.gpa;
    server.db.beginWrite();
    defer server.db.endWrite();
    server.docs.mutex.lockUncancelable(server.io);
    defer server.docs.mutex.unlock(server.io);
    const open = server.docs.open.getPtr(id) orelse return .last;
    const i = open.find(document_uri) orelse return .not_open;
    if (open.docs.items.len == 1) return .last;
    const current = open.current();
    const text = try gpa.dupe(u8, (if (i == open.docs.items.len - 1) &open.docs.items[i - 1] else current).text.?);
    errdefer gpa.free(text);
    try server.docs.versions.ensureUnusedCapacity(gpa, 1);
    open.docs.orderedRemove(i).deinit(gpa);
    try server.db.set(FileText, id, text, .low);
    const now = open.current();
    server.docs.versions.putAssumeCapacity(id, now.version);
    // A single document is the file's text again
    if (open.docs.items.len == 1) {
        gpa.free(now.text.?);
        now.text = null;
    }
    forgetRealPath(server, id);
    return .others;
}

/// Clears the diagnostics shown for `document_uri`, a document closed while other documents of
/// its file stay open (the file's diagnostics are published to those). Under `sent.mutex`, after
/// the document is removed: a publish sent before is overridden, and one sent after does not go
/// to it.
fn clearDocument(server: *Server, document_uri: []const u8) void {
    const bytes = jsonrpc.notification(server.gpa, "textDocument/publishDiagnostics", types.PublishDiagnosticsParams{ .uri = document_uri, .diagnostics = &.{} }) catch return log.err("out of memory while building notification", .{});
    server.sent.mutex.lockUncancelable(server.io);
    defer server.sent.mutex.unlock(server.io);
    server.send(bytes);
}

pub fn didSave(server: *Server, arena: Allocator, params: types.DidSaveTextDocumentParams) !void {
    const id = try fileIdFromUri(server, arena, params.textDocument.uri) orelse return;
    const path = server.vfs.path(id);
    const base = std.fs.path.basename(path);
    const is_build_file = isProjectFile(base);
    // The rebuilds below read the saved contents: the notification of this write by a file
    // watcher then rebuilds nothing more (see `didChangeWatchedFiles`)
    const saved = server.vfs.readFromDisk(id, arena) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => |e| return e,
        error.FileTooBig => null,
    };
    {
        server.watched_built_mutex.lockUncancelable(server.io);
        defer server.watched_built_mutex.unlock(server.io);
        if (saved) |t| server.watched_built.put(server.gpa, id, std.hash.Wyhash.hash(0, t)) catch {} else _ = server.watched_built.remove(id);
    }

    // A build.zig newly created in a root directory: start the project
    if (std.mem.eql(u8, base, "build.zig")) if (std.fs.path.dirname(path)) |dir| {
        if (try project_set.refreshRoot(server, dir)) return;
    };

    // Rebuild every project that contains the file (shared modules, the standard library)
    const list = try project_set.workspaceList(server, arena);
    defer project_set.releaseList(server, arena, list);
    for (list) |ws| {
        // Outside watch mode, the maker does not reconfigure automatically: restart. Build
        // scripts and configure inputs may lie outside the project's files.
        if ((is_build_file and server.vfs.samePath(std.fs.path.dirname(path) orelse "", ws.root)) or ws.isBuildScript(id) or
            ws.changesConfigureInput(path, .changed))
        {
            project_set.restartWorkspace(server, ws, 0);
        } else if (ws.owns(id)) {
            project_set.requestBuild(server, ws);
        }
    }
    // Single-file mode: compile the file itself if it is a standalone file; root files whose last
    // compile read it or reported errors in it are recompiled as well
    server.single.recompile(&.{id}, &.{id});
}

/// Files in a project root directory whose changes require restarting the project
pub fn isProjectFile(base: []const u8) bool {
    for (Workspace.project_files) |name| if (std.mem.eql(u8, base, name)) return true;
    return false;
}

/// Whether the project file at `path` has the disk contents `disk` (hash; null when absent) that
/// the newest instance of the project of its directory started with (see `Workspace.startedWith`):
/// FSEvents reports writes made shortly before the stream started, which do not change what that
/// maker read
pub fn projectStartedWith(server: *Server, path: []const u8, disk: ?u64) bool {
    const dir = std.fs.path.dirname(path) orelse return false;
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    for (server.workspaces.items) |w| if (server.vfs.samePath(w.root, dir)) {
        return (w.successor orelse w).startedWith(std.fs.path.basename(path), disk);
    };
    return false;
}

test "toolFile: a path naming an open document under another spelling is that document" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var writer: transport.Writer = .{ .io = std.testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(std.testing.io, gpa, &writer);
    defer server.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    try tmp.dir.createDirPath(std.testing.io, "real");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "real/a.zig", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "real/b.zig", .data = "" });
    try tmp.dir.symLink(std.testing.io, "real", "link", .{ .is_directory = true });
    const opened = try server.vfs.intern(try std.fs.path.join(a, &.{ dir, "link/a.zig" }));
    const real_a = try std.fs.path.join(a, &.{ dir, "real/a.zig" });
    const real_b = try std.fs.path.join(a, &.{ dir, "real/b.zig" });
    // No document is open: the path is interned as it is
    try std.testing.expect(try toolFile(&server, real_b) != opened);
    var doc: OpenDoc = .{};
    try doc.docs.append(gpa, .{ .uri = try gpa.dupe(u8, "file:///link/a.zig"), .version = 1 });
    try server.docs.open.put(gpa, opened, doc);
    try std.testing.expectEqual(opened, try toolFile(&server, real_a));
    try std.testing.expectEqual(opened, (try server.vfs.lookup(real_a)).?);
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ dir, "link/a.zig" }), server.vfs.path(opened));
    // Known paths are not resolved on disk again; a path no open document names stays apart
    try std.testing.expectEqual(1, server.docs.real.count());
    try std.testing.expect(try toolFile(&server, try std.fs.path.join(a, &.{ dir, "real/missing.zig" })) != opened);
}
