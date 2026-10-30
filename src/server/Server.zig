//! LSP server: main loop, message dispatch, read/write separation, and cancellation.
//!
//! - Write messages (notifications such as document sync) run serially on the main loop:
//!   `beginWrite` cancels in-flight read queries, then modifies inputs.
//! - Read requests run concurrently in `group`, each holding a read transaction on the state at
//!   the time the request was received; a request interrupted by a write transaction, or whose
//!   read transaction begins after a write transaction that began since then, is answered with
//!   `ContentModified`, and one canceled by `$/cancelRequest` with `RequestCancelled`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;

const za = @import("../zig_analyzer.zig");
const types = za.lsp.types;
const jsonrpc = za.lsp.jsonrpc;
const transport = za.lsp.transport;
const offsets = za.util.offsets;
const never = za.util.assert.never;
const panic_context = za.util.panic_context;
const uri = za.base.uri;
const Vfs = za.base.Vfs;
const database = @import("../database.zig");
const Db = database.Db;
const FileText = database.inputs.FileText;
const WorkspaceFiles = database.inputs.WorkspaceFiles;
const syntax_q = database.syntax;
const live = database.live;
const ide = za.ide;
const compiler = za.diagnostics.compiler;
const ZigEnv = za.project.ZigEnv;
const Workspace = @import("Workspace.zig");
const origin = @import("origin.zig");
const ModuleGraph = za.names.ModuleGraph;
const Resolver = za.names.resolve.Resolver;
const ImportOptions = za.ide_db.organize_imports.Options;
const InternPool = za.sema.InternPool;
pub const Progress = @import("progress.zig");
pub const Config = @import("Config.zig");
const SemanticCache = @import("semantic_cache.zig");
const watch = @import("watch.zig");
const client_process = @import("client_process.zig");
const workspace_files = @import("workspace_files.zig");

const log = std.log.scoped(.server);

const Server = @This();

io: Io,
gpa: Allocator,
db: Db,
vfs: Vfs,
ip: InternPool,
env: database.Env,
out: *transport.Writer,
state: State = .uninitialized,
encoding: offsets.Encoding = .utf16,
/// Read requests running concurrently. Only the main loop submits tasks to it, so the main loop
/// can safely await it.
group: Io.Group = .init,
pending_mutex: Io.Mutex = .init,
pending: std.ArrayList(*Pending) = .empty,
/// Test hook: holds the read and semantic requests of one method at a point of their execution
/// (see `TestGate`); always null outside tests
test_gate: ?*TestGate = null,

/// Background tasks: reading projects' build system protocol, publishing diagnostics. Several
/// threads submit tasks to it, and `Io.Group` does not allow submitting during an await, so it
/// is canceled only once, on exit (after all projects have stopped); at other times the `busy`
/// count tells whether it is idle.
bg_group: Io.Group = .init,
/// Diagnostic publish queue: a fixed number of workers take jobs from it in turn, so the number of
/// tasks and read transactions does not grow linearly with the number of files
publish_queue_mutex: Io.Mutex = .init,
publish_queue: std.ArrayList(PublishJob) = .empty,
publish_workers: usize = 0,
/// Files queued or being published (protected by publish_queue_mutex); see `publishFiles`
publish_files: std.AutoHashMapUnmanaged(Vfs.FileId, PublishState) = .empty,
busy_mutex: Io.Mutex = .init,
busy_cond: Io.Condition = .init,
busy: usize = 0,

/// Workspace root directories (absolute paths): given at initialize, then added and removed by
/// `workspace/didChangeWorkspaceFolders`
roots: std.ArrayList([]u8) = .empty,
/// Parallel to `roots`: whether the root directory has a build.zig (checked synchronously when
/// the root is added, to avoid a wrong answer before the project finishes loading; updated when
/// build.zig is created or deleted, see `refreshRoot`)
root_has_build: std.ArrayList(bool) = .empty,
/// Protects `roots` and `root_has_build`
roots_mutex: Io.Mutex = .init,

single_mutex: Io.Mutex = .init,
/// Compile results of single-file mode (standalone .zig files, see `FileContext.detached`), keyed
/// by the compiled root file. The results also include errors in files imported by the root file.
single: std.AutoArrayHashMapUnmanaged(Vfs.FileId, SingleFile) = .empty,
/// Sequence number of the last compile result taken (shared by project builds and single-file
/// compiles; see `nextCompileGeneration`)
compile_generation: std.atomic.Value(u64) = .init(0),
/// Environment variables of the process: zig child processes are started with the zig path
/// overrides applied on top of them (see `ZigEnv.withOverrides`)
environ: std.process.Environ = .empty,
env_mutex: Io.Mutex = .init,
/// The effective zig environment: the detected one with the path overrides from the
/// configuration applied (see `applyZigPaths`). Queried in the background after startup; null
/// until the query completes
zig_env: ?*const ZigEnv = null,
/// The environment detected by `zig env`; null until the query completes
detected_env: ?*const ZigEnv = null,
/// All environments created so far: a replaced environment may still be in use by in-flight
/// tasks and running projects, so it is freed only in deinit
envs: std.ArrayList(*ZigEnv) = .empty,
/// Serializes applying the zig paths (at startup and on configuration changes)
zig_paths_mutex: Io.Mutex = .init,
/// Startup has finished: the zig environment is ready, and projects have been started for root
/// directories with a build.zig. Before that, nothing is compiled in single-file mode (caught up
/// when startup finishes): until projects start loading, compiling files that belong to a
/// project cannot be deferred yet (see `projectsLoading`).
startup_done: std.atomic.Value(bool) = .init(false),
/// builtin.zig for files that belong to no project (native target, Debug); protected by env_mutex
default_builtin: ?[]u8 = null,
warned: bool = false,
workspaces_mutex: Io.Mutex = .init,
/// Currently visible instance of each project (one reference held on each). Before an instance is
/// used outside the lock, `acquire` it first.
workspaces: std.ArrayList(*Workspace) = .empty,
/// Stopping all projects has begun (shutdown / exit / deinit): projects are not restarted anymore
shutting_down: bool = false,
/// Number of Workspace instances not yet freed (for statistics and tests)
live_workspaces: std.atomic.Value(usize) = .init(0),

progress: Progress = .{},

/// Serializes module graph updates so that an older snapshot does not overwrite a newer one
graph_mutex: Io.Mutex = .init,
/// Target parameters last parsed from each builtin.zig (protected by `graph_mutex`): used when the
/// file can no longer be read (the global cache was cleared during the session). Generated
/// builtin.zig files are named by the hash of their contents, so a path always has the same
/// contents.
builtin_targets: std.AutoHashMapUnmanaged(Vfs.FileId, za.sema.InternPool.Target) = .empty,
/// Generation of background indexing: incremented on every module graph update
index_generation: std.atomic.Value(u64) = .init(0),
/// Config option `sema.callsite_seeding` (read by the IDE layer through `Env`)
callsite_seeding: std.atomic.Value(bool) = .init(true),
/// Counting allocator (set by the executable; used for `heap_bytes` in `zig-analyzer/status`)
heap: ?*const za.util.mem.Counting = null,
/// Slow request log threshold (ms, 0 disables it), from the config option `log.slow_request_ms`
slow_request_ms: std.atomic.Value(u32) = .init(100),
/// Once the InternPool exceeds this many MB, type information is reclaimed as a whole
/// generation (0 disables reclaiming); from the config option `sema.max_intern_pool_mb`
max_intern_pool_mb: std.atomic.Value(u32) = .init(64),
/// Debounce (ms) of diagnostic publishing triggered by edits, from the config option
/// `diagnostics.debounce_ms`
debounce_ms: std.atomic.Value(u32) = .init(50),
/// Files pending publication due to edits (see `publishDebounced`)
edits_mutex: Io.Mutex = .init,
edits: std.AutoHashMapUnmanaged(Vfs.FileId, Edit) = .empty,
/// Live diagnostics that diagnostic publishing precomputes outside the read transaction (picked up
/// by `AstCheck` through `Env`)
live_prepared: live.Prepared = undefined,
/// Whether an indexing task is running (only one runs at a time)
indexing: std.atomic.Value(bool) = .init(false),
/// Completion has run at a name that can be auto-imported: only after that is the auto-import
/// index built. Sessions without completion (browsing, goto) do not expand the public export
/// closure of the standard library for it.
imports_wanted: std.atomic.Value(bool) = .init(false),
/// Composition of the module graph when the auto-import index was last completed (see
/// `importsBasis`; `imports_pending` until it has been completed). When it differs at completion
/// time, auto-import is not offered and the result is marked incomplete, so the client requests
/// again as the user types: this avoids expanding the public export closures of the standard
/// library and the projects for new modules synchronously inside a request. It does not change
/// when the module graph only gains or loses files (such as generated files produced by a build);
/// new files are indexed on demand during completion.
imports_basis: std.atomic.Value(u64) = .init(imports_pending),
/// Indexed files: while indexing is in progress, workspace symbol searches only these files (and
/// open documents)
indexed: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty,
indexed_mutex: Io.Mutex = .init,
/// Generation of the workspace file scan (see `scheduleScan`): incremented whenever the source
/// files under the root directories may have changed
scan_generation: std.atomic.Value(u64) = .init(0),
/// Generation of the last finished scan (`never_scanned` before the first one): the search scope is
/// complete only when it equals `scan_generation` (see `scopeIncomplete`)
scan_done: std.atomic.Value(u64) = .init(never_scanned),
/// Whether a scan task is running (only one runs at a time)
scanning: std.atomic.Value(bool) = .init(false),
config_mutex: Io.Mutex = .init,
config: Config = .{},
// ── Pulled configuration (accessed only on the main loop) ──
/// The client supports `workspace/configuration`
pull_config: bool = false,
/// The client supports dynamically registering `workspace/didChangeConfiguration` (once
/// registered, the client sends a notification when the configuration changes, and the server
/// pulls the contents)
register_config: bool = false,
/// The client supports dynamically registering `workspace/didChangeWatchedFiles` (watching
/// external changes on disk)
register_watch: bool = false,
/// The client supports `workspace/inlayHint/refresh` (when the inlay hints settings or results of
/// other documents change, the client is asked to request them again); at most one refresh
/// response is awaited at a time.
inlay_refresh: bool = false,
inlay_refresh_mutex: Io.Mutex = .init,
inlay_refresh_pending: bool = false,
inlay_refresh_dirty: bool = false,
/// The client supports deferring `edit` to `codeAction/resolve` (and sends `data` back unchanged):
/// naming fixes look up references only after the user has chosen them
code_action_resolve: bool = false,
/// The client supports `disabled` on code actions (shown as unavailable, with the reason)
code_action_disabled: bool = false,
/// The client supports edits with change annotations in `documentChanges`: renaming a public name
/// requires confirmation from the user
change_annotations: bool = false,
/// The client supports snippets in completion items (`completionItem.snippetSupport`)
snippet_support: bool = false,
/// The client supports insert and replace ranges in completion items
/// (`completionItem.insertReplaceSupport`)
insert_replace_support: bool = false,
/// The client supports the workspace semantic tokens refresh; at most one refresh response is
/// awaited at a time.
semantic_refresh: bool = false,
semantic_refresh_mutex: Io.Mutex = .init,
semantic_refresh_pending: bool = false,
semantic_refresh_dirty: bool = false,
semantic_cache: SemanticCache = .{},
/// Number of configuration requests sent; only the response to the most recent one is used
config_requests: u32 = 0,
/// Number of configuration requests not yet answered: counted as busy while waiting (waitIdle
/// waits for the configuration to take effect)
config_outstanding: u32 = 0,
/// Project startup is postponed until the response to the first pull arrives (startup needs
/// zig.path and the build arguments)
startup_pending: bool = false,
/// `initialized` has been handled: LSP specifies that it is sent only once; duplicates are ignored
initialized_received: bool = false,
/// Background task watching the client process (`processId` of `initialize`)
parent_watch: ?Io.Future(void) = null,
/// Client process that `parent_watch` waits on
parent_process: ?*client_process.Watch = null,
/// Projects have been started: changing zig.path after this requires restarting the server
started: bool = false,

/// Serializes message handling that modifies server state: held by the main loop while it
/// handles each message; external changes discovered by the server are also handled under it
/// (see `watch.zig`)
write_mutex: Io.Mutex = .init,
/// Disk contents of known files that are not open, read during external changes and already used
/// as the basis of a rebuild (hash; null if the file does not exist); see `didChangeWatchedFiles`.
/// Cleared when the document is opened: contents saved while it is open do not come through
/// external changes. Accessed only under write_mutex.
watched_built: std.AutoHashMapUnmanaged(Vfs.FileId, ?u64) = .empty,
/// Background task for server-side discovery of external changes (created by `startProjects`)
watcher: ?*watch.Watcher = null,
/// Minimum polling interval (ms) when native file watching is unavailable
poll_interval_ms: std.atomic.Value(u32) = .init(1000),
/// Number of processed batches of external changes discovered by the server; tests wait on it
/// (protected by `watch_mutex`; `watch_cond` is broadcast when it changes)
watch_batches: u64 = 0,
watch_mutex: Io.Mutex = .init,
watch_cond: Io.Condition = .init,
docs_mutex: Io.Mutex = .init,
/// Open documents: the URI used by the client (used verbatim when publishing diagnostics)
open_docs: std.AutoArrayHashMapUnmanaged(Vfs.FileId, []u8) = .empty,
/// Version of each open document, set in the same database write as its text so that a read
/// transaction sees the version of the text it reads (protected by `docs_mutex`)
doc_versions: std.AutoHashMapUnmanaged(Vfs.FileId, i32) = .empty,
/// URI most recently used by the client: still used to publish diagnostics after the document is
/// closed (clearing old diagnostics, republishing compiler diagnostics), so that the URI is not
/// re-encoded from the internal path. For a virtual document, the entry is deleted once its
/// diagnostics are cleared.
last_uris: std.AutoArrayHashMapUnmanaged(Vfs.FileId, []u8) = .empty,
/// Files currently showing non-empty diagnostics (cleared by publishing an empty list when needed)
published: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty,
/// Sequence number of diagnostic computations: each computation takes one before reading state
/// such as compile results and text (see `sendDiagnostics`)
publish_seq: std.atomic.Value(u64) = .init(0),
publish_mutex: Io.Mutex = .init,
/// File → sequence number of the diagnostics sent (protected by publish_mutex)
sent_seq: std.AutoHashMapUnmanaged(Vfs.FileId, u64) = .empty,
/// File → hash of the last diagnostics notification sent (protected by publish_mutex)
sent_hash: std.AutoHashMapUnmanaged(Vfs.FileId, u64) = .empty,

pub const State = enum { uninitialized, running, shutdown };

const SingleFile = struct {
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
    /// loading finishes (see `reconcileSingle`)
    pending: bool = false,

    fn clearResult(sf: *SingleFile, gpa: Allocator) void {
        if (sf.result) |r| r.release(gpa);
        sf.result = null;
        sf.files.deinit(gpa);
        sf.files = .empty;
        sf.inputs.deinit(gpa);
        sf.inputs = .empty;
    }
};

const Pending = struct {
    id: jsonrpc.Id,
    cancel: std.atomic.Value(bool) = .init(false),
    /// When the request was received: it is answered on the state at that point, or with
    /// `ContentModified` when a write transaction ordered after it has begun since then (the task
    /// may start reading only after the main loop has applied later messages such as `didChange`;
    /// the server's own updates are not ordered with requests, see `Db.WriteOrder`)
    since: Db.Mark,
};

/// Test hook: a read or semantic request of `method` stops at `point` until `release` is set or
/// the request is canceled, so that a test can place other messages and server work at a known
/// point of its execution
pub const TestGate = struct {
    method: []const u8,
    point: enum {
        /// Before the read transaction begins
        before_read,
        /// In the read transaction, before the handler runs
        in_read,
    },
    /// Set when a request reaches the gate
    entered: Io.Event = .unset,
    release: Io.Event = .unset,

    fn pass(gate: *TestGate, io: Io, pending: *const Pending) void {
        gate.entered.set(io);
        while (!pending.cancel.load(.acquire)) {
            gate.release.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } }) catch continue;
            return;
        }
    }
};

pub const HandlerError = error{
    Canceled,
    OutOfMemory,
    InvalidParams,
    /// The new name is not a valid identifier
    InvalidIdentifier,
};

/// Initializes in place: the query engine holds a pointer to `server.env`, so the Server must not
/// be moved after initialization.
pub fn init(server: *Server, io: Io, gpa: Allocator, out: *transport.Writer) Allocator.Error!void {
    server.* = .{ .io = io, .gpa = gpa, .db = undefined, .vfs = .init(io, gpa), .ip = try .init(gpa, io), .env = undefined, .out = out };
    server.live_prepared = .{ .gpa = gpa };
    server.env = .{ .vfs = &server.vfs, .ip = &server.ip, .callsite_seeding = &server.callsite_seeding, .live_prepared = &server.live_prepared };
    server.db = .init(io, gpa, &server.env);
}

pub fn deinit(server: *Server) void {
    if (server.parent_watch) |*f| {
        // Waiting for the process exit notification ignores cancellation: make it return first
        server.parent_process.?.stop();
        f.cancel(server.io);
        server.parent_process.?.destroy(server.gpa);
    }
    server.group.cancel(server.io);
    server.stopWorkspaces();
    server.waitIdle();
    server.bg_group.cancel(server.io);
    if (server.watcher) |w| {
        server.vfs.listener.store(null, .release);
        w.destroy();
    }
    // All background tasks have finished; only the references held by the list remain
    server.publish_queue.deinit(server.gpa);
    server.publish_files.deinit(server.gpa);
    for (server.workspaces.items) |ws| ws.release();
    server.workspaces.deinit(server.gpa);
    server.indexed.deinit(server.gpa);
    server.edits.deinit(server.gpa);
    server.live_prepared.deinit();
    za.util.log.setFile(null) catch {};
    for (server.roots.items) |r| server.gpa.free(r);
    server.roots.deinit(server.gpa);
    server.root_has_build.deinit(server.gpa);
    for (server.single.values()) |*sf| sf.clearResult(server.gpa);
    server.single.deinit(server.gpa);
    for (server.envs.items) |env| {
        env.deinit(server.gpa);
        server.gpa.destroy(env);
    }
    server.envs.deinit(server.gpa);
    if (server.default_builtin) |p| server.gpa.free(p);
    server.builtin_targets.deinit(server.gpa);
    for (server.open_docs.values()) |u| server.gpa.free(u);
    server.open_docs.deinit(server.gpa);
    server.doc_versions.deinit(server.gpa);
    for (server.last_uris.values()) |u| server.gpa.free(u);
    server.last_uris.deinit(server.gpa);
    server.published.deinit(server.gpa);
    server.sent_seq.deinit(server.gpa);
    server.sent_hash.deinit(server.gpa);
    server.semantic_cache.deinit(server.gpa);
    server.watched_built.deinit(server.gpa);
    server.progress.deinit(server.gpa);
    server.config.deinit(server.gpa);
    server.pending.deinit(server.gpa);
    server.db.deinit();
    server.ip.deinit();
    server.vfs.deinit();
    server.* = undefined;
}

/// Runs the main loop until `exit` is received or the input ends, and returns the process exit
/// code. Before returning, cancels the read requests in flight (nobody reads their results
/// anymore), stops the build system processes of all projects, and waits for the scheduled
/// background tasks (diagnostic publishing, etc.) to finish. If the input ends without an `exit`,
/// the client has already exited: its replies to server requests are no longer awaited.
pub fn run(server: *Server, reader: *Io.Reader) !u8 {
    var exited = false;
    while (true) {
        const arena = try server.gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(server.gpa);
        // The message body is allocated in the arena: parsed strings may point into it directly,
        // so it must live as long as the request
        const body = transport.readMessage(reader, arena.allocator()) catch |err| {
            server.destroyArena(arena);
            switch (err) {
                error.EndOfStream => break,
                else => {
                    log.err("failed to read message: {t}", .{err});
                    break;
                },
            }
        };
        if (try server.processMessage(arena, body) == .exit) {
            exited = true;
            break;
        }
    }
    server.cancelAllPending();
    server.group.await(server.io) catch {};
    if (!exited) server.abandonConfigRequests();
    server.stopWorkspaces();
    server.waitIdle();
    return if (server.state == .shutdown) 0 else 1;
}

/// Stops waiting for the client's replies to configuration requests (on shutdown, or when the
/// client has already exited)
fn abandonConfigRequests(server: *Server) void {
    server.startup_pending = false;
    while (server.config_outstanding > 0) : (server.config_outstanding -= 1) server.busyEnd();
}

/// How often to check whether the client process is still running
/// Watches the client process: the server exits when it exits (see `client_process.zig`). The
/// watch is created on the main loop, so a later stop is not lost.
fn watchParent(server: *Server, pid: i32) void {
    if (pid <= 0 or server.parent_watch != null) return;
    const w = client_process.Watch.create(server.gpa, server.io, pid) catch
        return log.warn("cannot watch the client process {d}: out of memory", .{pid});
    server.parent_watch = server.io.concurrent(parentWatcher, .{ server, w }) catch |err| {
        w.destroy(server.gpa);
        return log.warn("cannot watch the client process {d}: {t}", .{ pid, err });
    };
    server.parent_process = w;
}

fn parentWatcher(server: *Server, w: *client_process.Watch) void {
    if (w.wait() == .stopped) return;
    log.warn("client process {d} has exited, exiting", .{w.pid});
    server.stopWorkspaces();
    std.process.exit(1);
}

const Flow = enum { @"continue", exit };

/// Processes one message; ownership of `arena` passes to this function.
fn processMessage(server: *Server, arena: *std.heap.ArenaAllocator, body: []const u8) !Flow {
    const a = arena.allocator();
    const message = jsonrpc.parse(a, body) catch |err| {
        server.destroyArena(arena);
        if (err == error.OutOfMemory) return err;
        server.sendError(null, jsonrpc.error_codes.parse_error, "failed to parse JSON-RPC message");
        return .@"continue";
    };
    server.write_mutex.lockUncancelable(server.io);
    defer server.write_mutex.unlock(server.io);
    var pc: panic_context.Text = .{};
    switch (message) {
        .request => |req| messageContext(&pc, "request", req.method, req.params),
        .notification => |n| messageContext(&pc, "notification", n.method, n.params),
        .response => pc.enter("response", .{}),
    }
    defer pc.leave();
    switch (message) {
        .request => |req| try server.processRequest(arena, req.id, req.method, req.params),
        .notification => |n| {
            defer server.destroyArena(arena);
            return server.processNotification(a, n.method, n.params);
        },
        .response => |resp| {
            defer server.destroyArena(arena);
            if (resp.id) |id| switch (id) {
                .integer => |i| _ = server.progress.handleResponse(server, i, resp.@"error" == null),
                .string => |s| if (std.mem.startsWith(u8, s, config_request_prefix)) {
                    try server.handleConfigResponse(s, resp.result, resp.@"error" != null);
                } else if (std.mem.eql(u8, s, semantic_refresh_id)) {
                    server.semanticRefreshFinished();
                } else if (std.mem.eql(u8, s, inlay_refresh_id)) {
                    server.inlayRefreshFinished();
                },
            };
        },
    }
    return .@"continue";
}

/// Message in the panic context: kind, method, and the document in the params
fn messageContext(pc: *panic_context.Text, kind: []const u8, method: []const u8, params: json.Value) void {
    const document_uri: ?[]const u8 = blk: {
        if (params != .object) break :blk null;
        const doc = params.object.get("textDocument") orelse break :blk null;
        if (doc != .object) break :blk null;
        const u = doc.object.get("uri") orelse break :blk null;
        break :blk if (u == .string) u.string else null;
    };
    if (document_uri) |u| pc.enter("{s} {s} {s}", .{ kind, method, u }) else pc.enter("{s} {s}", .{ kind, method });
}

/// Read request in the panic context: method, and the document and position in the params
/// (lines and columns start at 1)
fn requestContext(pc: *panic_context.Text, comptime method: []const u8, params: anytype) void {
    const P = @TypeOf(params);
    if (@typeInfo(P) != .@"struct" or !@hasField(P, "textDocument")) return pc.enter("request {s}", .{method});
    const doc = params.textDocument.uri;
    if (@hasField(P, "position")) {
        return pc.enter("request {s} {s}:{d}:{d}", .{ method, doc, params.position.line + 1, params.position.character + 1 });
    }
    if (@hasField(P, "range")) {
        return pc.enter("request {s} {s}:{d}:{d}", .{ method, doc, params.range.start.line + 1, params.range.start.character + 1 });
    }
    pc.enter("request {s} {s}", .{ method, doc });
}

// ── Requests ─────────────────────────────────────────────────────────

const Mode = enum {
    /// Runs synchronously on the main loop (requests that change server state)
    sync,
    /// Runs concurrently on a separate thread, holding a read transaction
    read,
    /// Runs in a separate task without a read transaction (requests that may wait for a long time
    /// and must not block the main loop)
    background,
    /// Like `read`, but the handler does name resolution and type queries through a Resolver
    semantic,
    /// Like `read`, for handlers whose results depend only on the text of documents: write
    /// transactions that change no text (such as the module graph after a build) wait for them
    /// instead of canceling them
    syntax,
};

const request_handlers = .{
    .{ "initialize", Mode.sync, initialize },
    .{ "shutdown", Mode.sync, shutdown },
    .{ "zig-analyzer/waitIdle", Mode.background, waitIdleRequest },
    .{ "zig-analyzer/status", Mode.read, status },
    .{ "zig-analyzer/fileStatus", Mode.read, fileStatus },
    .{ "zig-analyzer/syntaxTree", Mode.syntax, syntaxTree },
    .{ "zig-analyzer/moduleGraph", Mode.read, moduleGraph },
    .{ "zig-analyzer/reloadWorkspace", Mode.sync, reloadWorkspace },
    .{ "textDocument/formatting", Mode.syntax, formatting },
    .{ "textDocument/documentSymbol", Mode.syntax, documentSymbol },
    .{ "textDocument/foldingRange", Mode.syntax, foldingRange },
    .{ "textDocument/selectionRange", Mode.syntax, selectionRange },
    .{ "textDocument/semanticTokens/full", Mode.semantic, semanticTokensFull },
    .{ "textDocument/semanticTokens/full/delta", Mode.semantic, semanticTokensDelta },
    .{ "textDocument/semanticTokens/range", Mode.semantic, semanticTokensRange },
    .{ "textDocument/definition", Mode.semantic, definition },
    .{ "textDocument/declaration", Mode.semantic, declaration },
    .{ "textDocument/typeDefinition", Mode.semantic, typeDefinition },
    .{ "textDocument/completion", Mode.semantic, completion },
    .{ "completionItem/resolve", Mode.semantic, completionResolve },
    .{ "textDocument/hover", Mode.semantic, hover },
    .{ "textDocument/signatureHelp", Mode.semantic, signatureHelp },
    .{ "textDocument/inlayHint", Mode.semantic, inlayHint },
    .{ "textDocument/references", Mode.semantic, references },
    .{ "textDocument/documentHighlight", Mode.semantic, documentHighlight },
    .{ "textDocument/prepareRename", Mode.semantic, prepareRename },
    .{ "textDocument/rename", Mode.semantic, rename },
    .{ "workspace/symbol", Mode.semantic, workspaceSymbol },
    .{ "textDocument/codeAction", Mode.semantic, codeAction },
    .{ "codeAction/resolve", Mode.semantic, codeActionResolve },
};

fn processRequest(server: *Server, arena: *std.heap.ArenaAllocator, id: jsonrpc.Id, method: []const u8, params_value: json.Value) !void {
    const a = arena.allocator();
    // A string ID points into the arena: error responses must be serialized before the arena is
    // freed, so all error exits free it with defer
    inline for (request_handlers) |h| {
        if (std.mem.eql(u8, method, h[0])) {
            const is_initialize = comptime std.mem.eql(u8, h[0], "initialize");
            if (server.state == .uninitialized and !is_initialize) {
                defer server.destroyArena(arena);
                return server.sendError(id, jsonrpc.error_codes.server_not_initialized, "server not initialized");
            }
            if (server.state != .uninitialized and is_initialize or server.state == .shutdown) {
                defer server.destroyArena(arena);
                return server.sendError(id, jsonrpc.error_codes.invalid_request, "request not allowed in current state");
            }

            const func = h[2];
            const Params = LastParam(@TypeOf(func));
            const params = jsonrpc.parseParams(Params, a, params_value) catch |err| {
                defer server.destroyArena(arena);
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return server.sendError(id, jsonrpc.error_codes.invalid_params, "malformed params");
            };

            switch (h[1]) {
                .sync => {
                    defer server.destroyArena(arena);
                    const result = func(server, a, params) catch |err| return server.sendHandlerError(id, err, false);
                    server.sendResponse(id, result);
                },
                .read, .semantic, .syntax => {
                    const inputs: ?Db.Inputs = if (h[1] == .syntax) comptime Db.inputSet(&.{FileText}) else null;
                    const pending = server.addPending(a, id, inputs) catch |err| {
                        defer server.destroyArena(arena);
                        server.sendError(id, jsonrpc.error_codes.internal_error, "out of memory");
                        return err;
                    };
                    const Task = if (h[1] == .semantic) SemanticTask(func, h[0]) else ReadTask(func, h[0]);
                    // semantic must run on a separate thread: when the thread count reaches the
                    // limit (CPU core count - 1; long-blocking project tasks also take slots),
                    // `async` runs synchronously on the main loop, while background requests wait
                    // for messages that the main loop must process (such as configuration pull
                    // responses), causing a deadlock
                    spawn(server.io, &server.group, Task.run, .{ server, arena, pending, params });
                },
                .background => server.group.concurrent(server.io, BackgroundTask(func).run, .{ server, arena, id, params }) catch {
                    defer server.destroyArena(arena);
                    server.sendError(id, jsonrpc.error_codes.internal_error, "failed to start background task");
                },
            }
            return;
        }
    }
    defer server.destroyArena(arena);
    server.sendError(id, jsonrpc.error_codes.method_not_found, "method not supported");
}

/// Registers an in-flight request (can be canceled by `$/cancelRequest`); the Pending is allocated
/// in the request's arena. Called on the main loop when the request is received; `inputs` are the
/// inputs its result may depend on (null: all).
fn addPending(server: *Server, a: Allocator, id: jsonrpc.Id, inputs: ?Db.Inputs) !*Pending {
    const pending = try a.create(Pending);
    pending.* = .{ .id = id, .since = server.db.mark(inputs) };
    server.pending_mutex.lockUncancelable(server.io);
    defer server.pending_mutex.unlock(server.io);
    try server.pending.append(server.gpa, pending);
    return pending;
}

/// Runs the task on a separate thread. Does not use `async`: when the thread count reaches the
/// limit (CPU core count - 1; long-blocking project tasks also take slots), `async` runs the task
/// synchronously in the caller, and while it runs on the main loop, `$/cancelRequest` cannot be
/// received and later requests queue up. `concurrent` has no count limit by default and
/// fails only when a thread cannot be created, in which case this falls back to `async`.
fn spawn(io: Io, group: *Io.Group, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) void {
    group.concurrent(io, function, args) catch group.async(io, function, args);
}

/// Type of the handler's last parameter, which is the request params type
fn LastParam(comptime F: type) type {
    const param_types = @typeInfo(F).@"fn".param_types;
    return param_types[param_types.len - 1].?;
}

fn BackgroundTask(comptime func: anytype) type {
    const Params = LastParam(@TypeOf(func));
    return struct {
        fn run(server: *Server, arena: *std.heap.ArenaAllocator, id: jsonrpc.Id, params: Params) Io.Cancelable!void {
            defer server.destroyArena(arena);
            const result = func(server, arena.allocator(), params) catch |err| return server.sendHandlerError(id, err, false);
            server.sendResponse(id, result);
        }
    };
}

fn ReadTask(comptime func: anytype, comptime method: []const u8) type {
    const Params = LastParam(@TypeOf(func));
    return struct {
        fn run(server: *Server, arena: *std.heap.ArenaAllocator, pending: *Pending, params: Params) Io.Cancelable!void {
            defer server.finishRequest(arena, pending);
            const a = arena.allocator();
            server.testGate(method, .before_read, pending);
            var ctx = server.db.beginReadAt(a, pending.since);
            ctx.cancel = &pending.cancel;
            defer ctx.end();
            server.testGate(method, .in_read, pending);
            var trace: za.db.Trace = .{ .gpa = a };
            ctx.trace = &trace;
            var pc: panic_context.Text = .{};
            requestContext(&pc, method, params);
            defer pc.leave();
            const zone = za.util.tracy.zone(@src(), method);
            defer zone.end();
            const t0 = Io.Clock.awake.now(server.io);
            defer server.reportIfSlow(&ctx, method, t0, &trace);

            const result = func(server, &ctx, a, params) catch |err| {
                return server.sendHandlerError(pending.id, err, pending.cancel.load(.acquire));
            };
            // The handler may have swallowed `Canceled` with a fallback value (such as
            // `catch null` in type rendering), and then the result is incomplete
            ctx.checkCanceled() catch |err| return server.sendHandlerError(pending.id, err, pending.cancel.load(.acquire));
            server.sendResponse(pending.id, result);
        }
    };
}

/// Like ReadTask, but the handler gets a Resolver
fn SemanticTask(comptime func: anytype, comptime method: []const u8) type {
    const Params = LastParam(@TypeOf(func));
    return struct {
        fn run(server: *Server, arena: *std.heap.ArenaAllocator, pending: *Pending, params: Params) Io.Cancelable!void {
            defer server.finishRequest(arena, pending);
            const a = arena.allocator();
            server.testGate(method, .before_read, pending);
            var ctx = server.db.beginReadAt(a, pending.since);
            ctx.cancel = &pending.cancel;
            defer ctx.end();
            server.testGate(method, .in_read, pending);
            var trace: za.db.Trace = .{ .gpa = a };
            ctx.trace = &trace;
            var pc: panic_context.Text = .{};
            requestContext(&pc, method, params);
            defer pc.leave();
            const zone = za.util.tracy.zone(@src(), method);
            defer zone.end();
            const t0 = Io.Clock.awake.now(server.io);
            defer server.reportIfSlow(&ctx, method, t0, &trace);
            var r: Resolver = .{ .ctx = &ctx, .arena = a };
            const result = func(server, &r, a, params) catch |err| {
                return server.sendHandlerError(pending.id, err, pending.cancel.load(.acquire));
            };
            // As in ReadTask: a handler that swallowed `Canceled` has an incomplete result
            ctx.checkCanceled() catch |err| return server.sendHandlerError(pending.id, err, pending.cancel.load(.acquire));
            if (comptime isOutcome(@TypeOf(result))) switch (result) {
                .ok => |v| server.sendResponse(pending.id, v),
                .failed => |message| server.sendError(pending.id, jsonrpc.error_codes.request_failed, message),
            } else server.sendResponse(pending.id, result);
        }
    };
}

/// End of a read or semantic request task, after its read transaction: evicts when a query
/// exceeds its cache capacity and reclaims type information when needed (both only when no other
/// read transaction is active), then unregisters the request, which counts as in flight until
/// then
fn finishRequest(server: *Server, arena: *std.heap.ArenaAllocator, pending: *Pending) void {
    if (server.db.wantsSweep()) _ = server.db.trySweep();
    server.maybeResetSema();
    server.removePending(pending);
    server.destroyArena(arena);
}

fn testGate(server: *Server, comptime method: []const u8, point: @FieldType(TestGate, "point"), pending: *const Pending) void {
    if (!@import("builtin").is_test) return;
    const gate = server.test_gate orelse return;
    if (gate.point == point and std.mem.eql(u8, gate.method, method)) gate.pass(server.io, pending);
}

/// Result of a handler: success, or the reason for the failure (answered with `request_failed`;
/// the client shows the reason to the user)
fn Outcome(comptime T: type) type {
    return union(enum) {
        ok: T,
        failed: []const u8,
    };
}

fn isOutcome(comptime T: type) bool {
    return @typeInfo(T) == .@"union" and @hasField(T, "ok") and @hasField(T, "failed");
}

// ── Slow request log ───────────────────────────────────────────────

/// Logs requests that take longer than `log.slow_request_ms`: self time summed per query, and the
/// slow paths in the call tree. Called before the read transaction ends (describing a key reads
/// the ItemTree).
fn reportIfSlow(server: *Server, ctx: *Db.Ctx, method: []const u8, t0: Io.Timestamp, trace: *const za.db.Trace) void {
    // In tests, request times vary with machine load, and warn writes to stderr, which makes the
    // build output show a misleading `failed command`; the report contents are covered by tests
    // that call writeSlowReport directly
    if (@import("builtin").is_test) return;
    const threshold = server.slow_request_ms.load(.monotonic);
    if (threshold == 0) return;
    const ns: u64 = @intCast(@max(0, t0.durationTo(Io.Clock.awake.now(server.io)).nanoseconds));
    if (ns < @as(u64, threshold) * std.time.ns_per_ms) return;
    var out: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer out.deinit();
    // The call tree only expands nodes taking at least 2% of the total time (at least 1 ms)
    server.writeSlowReport(&out.writer, ctx, trace, @max(std.time.ns_per_ms, ns / 50)) catch return;
    log.warn("slow request {s}: {d:.1} ms, {d} queries executed\n{s}", .{ method, za.db_report.ms(ns), trace.events.items.len, out.written() });
}

/// Maximum number of call tree lines in a slow request report
const slow_tree_lines = 40;

/// Slow request report: self time summed per query, and call tree nodes taking at least `min_ns`
pub fn writeSlowReport(server: *Server, w: *std.Io.Writer, ctx: *Db.Ctx, trace: *const za.db.Trace, min_ns: u64) !void {
    const events = trace.events.items;
    // Self time: among the events in pre-order, an event's children are the consecutive events
    // after it with a greater depth
    var self_by_query: [Db.query_types.len]u64 = @splat(0);
    var count_by_query: [Db.query_types.len]u32 = @splat(0);
    for (events, 0..) |e, i| {
        var children: u64 = 0;
        var j = i + 1;
        while (j < events.len and events[j].depth > e.depth) : (j += 1) {
            if (events[j].depth == e.depth + 1) children += events[j].ns;
        }
        self_by_query[e.query] += e.ns -| children;
        count_by_query[e.query] += 1;
    }
    var order: [Db.query_types.len]usize = undefined;
    for (&order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, &order, &self_by_query, struct {
        fn gt(t: *const [Db.query_types.len]u64, a: usize, b: usize) bool {
            return t[a] > t[b];
        }
    }.gt);
    try w.writeAll("  by query (self time):\n");
    for (order[0..@min(order.len, 8)]) |qi| {
        if (count_by_query[qi] == 0) break;
        try w.print("    {s:<26} {d:>6}x {d:>9.1} ms\n", .{ za.db_report.shortName(queryName(qi)), count_by_query[qi], za.db_report.ms(self_by_query[qi]) });
    }
    try w.writeAll("  slowest paths:\n");
    var lines: usize = 0;
    var skip_below: ?u16 = null;
    for (events) |e| {
        if (skip_below) |d| {
            if (e.depth > d) continue;
            skip_below = null;
        }
        if (e.ns < min_ns) {
            skip_below = e.depth;
            continue;
        }
        if (lines == slow_tree_lines) {
            try w.writeAll("    ...\n");
            break;
        }
        lines += 1;
        try w.splatByteAll(' ', 4 + @as(usize, e.depth) * 2);
        try w.print("{s} ", .{za.db_report.shortName(queryName(e.query))});
        try server.describeKey(w, ctx, e.query, e.key);
        try w.print(" {d:.1} ms{s}{s}\n", .{ za.db_report.ms(e.ns), if (e.cutoff) " (cutoff)" else "", if (e.failed) " (canceled)" else "" });
    }
}

fn queryName(qi: usize) []const u8 {
    inline for (Db.query_types, 0..) |Q, i| if (i == qi) return @typeName(Q);
    unreachable;
}

/// Readable form of a key: a file is shown as its file name, a member as "file name:member name",
/// and other fields are written as is
fn describeKey(server: *Server, w: *std.Io.Writer, ctx: *Db.Ctx, qi: usize, index: u32) !void {
    inline for (Db.query_types, 0..) |Q, i| if (i == qi) {
        if (Q.Key == void) return;
        return server.writeValue(w, ctx, server.db.keyAt(Q, index));
    };
}

fn writeValue(server: *Server, w: *std.Io.Writer, ctx: *Db.Ctx, value: anytype) !void {
    const T = @TypeOf(value);
    if (T == Vfs.FileId) return w.writeAll(std.fs.path.basename(server.vfs.path(value)));
    if (T == za.database.hir.OwnerKey) {
        try w.writeAll(std.fs.path.basename(server.vfs.path(value.file)));
        const tree = ctx.get(syntax_q.FileItemTree, value.file) catch return w.print("#{d}", .{@backingInt(value.item)});
        for (tree.items) |it| if (it.ast_id == value.item) return w.print(":{s}", .{it.name orelse "_"});
        return w.print("#{d}", .{@backingInt(value.item)});
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            try w.writeAll("{");
            inline for (info.field_names, 0..) |name, i| {
                if (i > 0) try w.writeAll(" ");
                try w.print("{s}=", .{name});
                try server.writeValue(w, ctx, @field(value, name));
            }
            try w.writeAll("}");
        },
        .optional => if (value) |v| try server.writeValue(w, ctx, v) else try w.writeAll("null"),
        .@"enum" => try w.print("{any}", .{value}),
        else => try w.print("{any}", .{value}),
    }
}

/// Target-dependent parameters of value operations outside every compilation (pointer bit width,
/// layout rules of vector and scalar types): taken from the parts the builtins of all modules and
/// compilations agree on; parts that disagree are unknown (values depending on them are unknown);
/// without project modules, the default builtin (native) is used
fn targetAbi(server: *Server, graph: *const ModuleGraph) Allocator.Error!za.sema.InternPool.Target {
    var result: za.sema.InternPool.Target = .{};
    // Modules with the same parameters share the same builtin, and merging the same target again
    // does not change the result: each one is read and parsed only once
    var seen: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty;
    defer seen.deinit(server.gpa);
    for (graph.modules) |m| if (m.builtin) |file| try seen.put(server.gpa, file, {});
    for (graph.compiles) |c| if (c.builtin) |file| try seen.put(server.gpa, file, {});
    for (seen.keys(), 0..) |file, i| {
        const t = try server.builtinTarget(file);
        if (i == 0) {
            result = t;
            continue;
        }
        if (result.pointer_bits != t.pointer_bits) result.pointer_bits = null;
        if (result.vector_abi != t.vector_abi) result.vector_abi = .unknown;
        result.scalar_abi = result.scalar_abi.merge(t.scalar_abi);
    }
    if (seen.count() != 0) return result;
    if (graph.default_builtin) |f| return server.builtinTarget(f);
    return .{};
}

/// Target parameters of a builtin.zig; when it cannot be read, the ones last parsed from it (see
/// `builtin_targets`). The caller holds `graph_mutex`.
fn builtinTarget(server: *Server, file: Vfs.FileId) Allocator.Error!za.sema.InternPool.Target {
    const text = Io.Dir.cwd().readFileAlloc(server.io, server.vfs.path(file), server.gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return server.builtin_targets.get(file) orelse .{ .pointer_bits = null, .scalar_abi = .unknown },
    };
    defer server.gpa.free(text);
    const facts = za.project.builtin.vectorFacts(text);
    const target = za.project.builtin.target(text);
    const result: za.sema.InternPool.Target = .{
        .pointer_bits = za.project.builtin.pointerBits(text),
        .vector_abi = if (facts) |f| .of(f.backend, f.arch, f.avx, f.avx512f, f.soft_float) else .unknown,
        .scalar_abi = if (target) |*t| .of(t) else .unknown,
    };
    try server.builtin_targets.put(server.gpa, file, result);
    return result;
}

/// Combines the build graphs and compile sets of all projects and updates the module graph input
pub fn updateModuleGraph(server: *Server) void {
    server.updateModuleGraphInner() catch |err| return log.err("failed to update module graph: {t}", .{err});
    // Must come after the write transaction ends: the indexing task may run inline
    server.scheduleIndexing();
}

fn updateModuleGraphInner(server: *Server) Allocator.Error!void {
    server.graph_mutex.lockUncancelable(server.io);
    defer server.graph_mutex.unlock(server.io);
    var b: ModuleGraph.Builder = .init(server.gpa, &server.vfs);
    var builder_owned = true;
    errdefer if (builder_owned) b.deinit();
    const list = try server.workspaceList(server.gpa);
    defer server.releaseList(server.gpa, list);
    for (list) |ws| {
        ws.mutex.lockUncancelable(server.io);
        defer ws.mutex.unlock(server.io);
        if (ws.model) |*m| if (ws.compile_set) |*cs| try b.add(m, cs, if (ws.resolve_set) |*e| e else null);
        // The build.zig modules of the project and its dependency packages: after the compile
        // sets, which take priority for files in both
        if (ws.script_model) |*m| if (ws.script_set) |*s| try b.add(m, s, null);
    }
    const std_root: ?Vfs.FileId = if (server.zigEnv()) |env| blk: {
        const p = try std.fs.path.join(server.gpa, &.{ env.std_dir, "std.zig" });
        defer server.gpa.free(p);
        break :blk try server.vfs.intern(p);
    } else null;
    const default_builtin: ?Vfs.FileId = blk: {
        server.env_mutex.lockUncancelable(server.io);
        defer server.env_mutex.unlock(server.io);
        break :blk if (server.default_builtin) |p| try server.vfs.intern(p) else null;
    };
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
    const t = try server.targetAbi(graph);
    // Each compilation uses the target of its builtin (the root module's); when that is unknown,
    // the parameters common to all compilations
    const targets = try server.gpa.alloc(za.sema.InternPool.Target, graph.compiles.len);
    defer server.gpa.free(targets);
    for (graph.compiles, targets) |c, *ct| ct.* = if (c.builtin) |file| try server.builtinTarget(file) else t;
    // Do not open a write transaction when neither the module graph nor the targets have changed:
    // every build that finishes gets here, and a write transaction cancels in-flight computations
    // and requests (the requests fail with ContentModified)
    if (try server.moduleGraphUnchanged(graph, t, targets)) return;
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
/// the comparison.
fn moduleGraphUnchanged(server: *Server, graph: *const ModuleGraph, t: za.sema.InternPool.Target, targets: []const za.sema.InternPool.Target) Allocator.Error!bool {
    var ctx = server.db.beginRead(server.gpa);
    defer ctx.end();
    const current = ctx.get(ModuleGraph.Input, {}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Another write transaction is waiting: treat it as changed
        error.Canceled => return false,
    };
    const target = ctx.get(za.sema.queries.TargetAbi, {}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return false,
    };
    for (targets, 0..) |ct, i| {
        const cur = ctx.get(za.sema.queries.ContextTarget, @intCast(i)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return false,
        };
        if (!std.meta.eql(cur, ct)) return false;
    }
    return ModuleGraph.Input.eql(current, graph) and std.meta.eql(target, t);
}

const index_progress_delay_ms = 200;

/// Whether auto-import is still enabled: the indexing task checks again before each batch and
/// stops indexing once it is disabled
fn autoImportEnabled(server: *Server) bool {
    server.config_mutex.lockUncancelable(server.io);
    defer server.config_mutex.unlock(server.io);
    return server.config.completion_auto_import;
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
fn scheduleIndexing(server: *Server) void {
    _ = server.index_generation.fetchAdd(1, .monotonic);
    if (server.indexing.swap(true, .acq_rel)) return;
    server.busyBegin();
    spawn(server.io, &server.bg_group, indexTask, .{server});
}

/// Like `scheduleIndexing`, for requests that hold a read transaction: the indexing task may run
/// inline, and when its read transaction runs into a waiting write transaction, it and the caller
/// still holding the read lock wait for each other. Scheduling is done by another task; if that
/// task cannot start, no index is built and it is left to later requests.
fn scheduleIndexingFromRead(server: *Server) void {
    server.busyBegin();
    server.bg_group.concurrent(server.io, scheduleIndexingTask, .{server}) catch server.busyEnd();
}

fn scheduleIndexingTask(server: *Server) Io.Cancelable!void {
    defer server.busyEnd();
    server.scheduleIndexing();
}

fn indexTask(server: *Server) Io.Cancelable!void {
    defer server.busyEnd();
    while (true) {
        const generation = server.index_generation.load(.monotonic);
        server.indexOnce() catch |err| {
            server.indexing.store(false, .release);
            return err;
        };
        if (server.index_generation.load(.monotonic) != generation) continue;
        server.indexing.store(false, .release);
        // Updated again after the flag was released, and no other task took over: continue
        if (server.index_generation.load(.monotonic) == generation) {
            server.requestRefresh();
            return;
        }
        if (server.indexing.swap(true, .acq_rel)) return;
    }
}

/// Scans the root directories for the user's source files in the background (see
/// `workspace_files.scan`): when the scope of find references and rename may have changed (startup,
/// root directories added or removed, source files or directories created or deleted). Like
/// indexing, a running task does another pass when this is called again meanwhile. Must not be
/// called inside a read or write transaction: the task may run inline.
pub fn scheduleScan(server: *Server) void {
    _ = server.scan_generation.fetchAdd(1, .acq_rel);
    if (server.scanning.swap(true, .acq_rel)) return;
    server.busyBegin();
    spawn(server.io, &server.bg_group, scanTask, .{server});
}

fn scanTask(server: *Server) Io.Cancelable!void {
    defer server.busyEnd();
    while (true) {
        const generation = server.scan_generation.load(.acquire);
        server.scanOnce() catch |err| switch (err) {
            error.OutOfMemory => log.err("out of memory while scanning the workspace for source files", .{}),
        };
        server.scan_done.store(generation, .release);
        if (server.scan_generation.load(.acquire) != generation) continue;
        server.scanning.store(false, .release);
        // Scheduled again after the flag was released, and no other task took over: continue
        if (server.scan_generation.load(.monotonic) == generation) return;
        if (server.scanning.swap(true, .acq_rel)) return;
    }
}

/// One scan: updates `WorkspaceFiles` when the files found differ, and then indexes them for
/// workspace symbol
fn scanOnce(server: *Server) Allocator.Error!void {
    if (server.isShuttingDown()) return;
    var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rules = try server.originRules(a);
    const paths = try workspace_files.scan(server.io, a, &server.vfs, rules);
    var set: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty;
    for (paths) |p| try set.put(a, try server.vfs.intern(p), {});
    const files = set.keys();
    std.mem.sort(Vfs.FileId, files, {}, struct {
        fn lt(_: void, x: Vfs.FileId, y: Vfs.FileId) bool {
            return @backingInt(x) < @backingInt(y);
        }
    }.lt);
    // A write transaction cancels in-flight requests: write only when the files differ. Scans run
    // one at a time, so nobody else changes the input after the comparison.
    const unchanged = blk: {
        var ctx = server.db.beginRead(a);
        defer ctx.end();
        const current = ctx.get(WorkspaceFiles, {}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => break :blk false,
        };
        break :blk std.mem.eql(Vfs.FileId, current, files);
    };
    if (unchanged) return;
    {
        server.db.beginWriteOf(comptime Db.inputSet(&.{WorkspaceFiles}), .unordered);
        defer server.db.endWrite();
        // The engine takes ownership of the value, also when it fails
        try server.db.set(WorkspaceFiles, {}, try server.gpa.dupe(Vfs.FileId, files), .low);
    }
    server.scheduleIndexing();
}

fn indexOnce(server: *Server) Io.Cancelable!void {
    var pc: panic_context.Text = .{};
    pc.enter("workspace symbol indexing", .{});
    defer pc.leave();
    var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_state.deinit();
    var basis: u64 = 0;
    const Files = struct { symbols: []const Vfs.FileId, project: []const Vfs.FileId };
    const files: Files = while (true) {
        if (server.isShuttingDown()) return;
        var ctx = server.db.beginRead(arena_state.allocator());
        defer ctx.end();
        var r: Resolver = .{ .ctx = &ctx, .arena = arena_state.allocator() };
        // Interrupted by an edit: retry instead of abandoning this round
        basis = importsBasis(ctx.get(ModuleGraph.Input, {}) catch |err| switch (err) {
            error.Canceled => continue,
            error.OutOfMemory => return,
        });
        const symbols = za.ide_db.search.searchFiles(&r) catch |err| switch (err) {
            error.Canceled => continue,
            error.OutOfMemory => return,
        };
        const project = za.ide_db.search.projectFiles(&r) catch |err| switch (err) {
            error.Canceled => continue,
            error.OutOfMemory => return,
        };
        break .{ .symbols = symbols, .project = project };
    };
    // Two steps: first the regular index of the searched files (workspace symbols), usable as soon
    // as it is built; then the auto-import index (public closures of the standard library and of
    // each module, `FileLinks` of project files), during which completion works as usual, only
    // without auto-import
    if (!try server.indexBatches(files.symbols, "Indexing", false)) return;
    if (!(server.imports_wanted.load(.acquire) and server.autoImportEnabled())) return;
    // When warming up fails (out of memory), the index is not marked usable: the next completion
    // retries, instead of the closures being expanded synchronously in a request
    if (!server.indexImportRoots()) return;
    if (!try server.indexBatches(files.project, "Indexing for auto-import", true)) return;
    // The project-level results completion needs are also computed before the index is marked
    // usable, rather than being left to the first completion
    while (true) {
        if (server.isShuttingDown() or !server.autoImportEnabled()) return;
        var ctx = server.db.beginRead(arena_state.allocator());
        defer ctx.end();
        _ = ctx.get(za.ide_db.imports.TestOnlyFiles, {}) catch |err| switch (err) {
            error.Canceled => continue,
            error.OutOfMemory => return,
        };
        break;
    }
    if (server.autoImportEnabled()) server.imports_basis.store(basis, .release);
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
        if (server.isShuttingDown() or (auto_import and !server.autoImportEnabled())) return false;
        const end = @min(done + index_batch, files.len);
        _ = scratch.reset(.retain_capacity);
        {
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
        if (!auto_import) {
            server.indexed_mutex.lockUncancelable(server.io);
            defer server.indexed_mutex.unlock(server.io);
            for (files[done..end]) |f| server.indexed.put(server.gpa, f, {}) catch {};
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

/// The auto-import index has not been fully built yet (see `imports_basis`)
const imports_pending = std.math.maxInt(u64);

/// The composition of the module graph that determines the auto-import index: the standard
/// library, the default builtin, and each module's root, builtin, and imports, but not files
fn importsBasis(graph: ?*const ModuleGraph) u64 {
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

/// Workspace symbol index; with `auto_import`, the declaration index for auto-import (only for
/// Zig source files)
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
    return server.warmImportRoots() catch |err| {
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
        if (server.isShuttingDown() or !server.autoImportEnabled()) return false;
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
        if (server.isShuttingDown() or !server.autoImportEnabled()) return false;
        const end = @min(done + index_batch, files.items.len);
        _ = scratch.reset(.retain_capacity);
        var found: std.ArrayList(Vfs.FileId) = .empty;
        var canceled = false;
        {
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
        if (!server.autoImportEnabled()) return false;
        _ = scratch.reset(.retain_capacity);
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

fn removePending(server: *Server, pending: *Pending) void {
    server.pending_mutex.lockUncancelable(server.io);
    defer server.pending_mutex.unlock(server.io);
    for (server.pending.items, 0..) |p, i| {
        if (p == pending) {
            _ = server.pending.swapRemove(i);
            return;
        }
    }
}

fn cancelPending(server: *Server, id: jsonrpc.Id) void {
    server.pending_mutex.lockUncancelable(server.io);
    defer server.pending_mutex.unlock(server.io);
    for (server.pending.items) |p| {
        if (p.id.eql(id)) p.cancel.store(true, .release);
    }
}

fn cancelAllPending(server: *Server) void {
    server.pending_mutex.lockUncancelable(server.io);
    defer server.pending_mutex.unlock(server.io);
    for (server.pending.items) |p| p.cancel.store(true, .release);
}

const semantic_refresh_id = "zig-analyzer/semanticTokensRefresh";
const inlay_refresh_id = "zig-analyzer/inlayHintRefresh";

/// Results of other documents may have changed in ways the client cannot see (another document
/// edited, files changed on disk, the module graph loaded): semantic tokens and inlay hints are
/// pulled by the client, which is asked to pull both again
fn requestRefresh(server: *Server) void {
    server.requestSemanticRefresh();
    server.requestInlayRefresh();
}

fn openDocumentCount(server: *Server) usize {
    server.docs_mutex.lockUncancelable(server.io);
    defer server.docs_mutex.unlock(server.io);
    return server.open_docs.count();
}

/// Edits refresh other documents only after the debounce completes; indexing refreshes only
/// after a stable round ends. Changes made while waiting for the client's response are merged
/// into the next refresh, which is not sent inside any read transaction or state lock.
fn requestSemanticRefresh(server: *Server) void {
    if (!server.semantic_refresh or server.isShuttingDown() or server.openDocumentCount() == 0) return;
    server.semantic_refresh_mutex.lockUncancelable(server.io);
    if (server.semantic_refresh_pending) {
        server.semantic_refresh_dirty = true;
        server.semantic_refresh_mutex.unlock(server.io);
        return;
    }
    server.semantic_refresh_pending = true;
    server.semantic_refresh_mutex.unlock(server.io);
    const bytes = jsonrpc.request(server.gpa, .{ .string = semantic_refresh_id }, "workspace/semanticTokens/refresh", null) catch {
        server.semantic_refresh_mutex.lockUncancelable(server.io);
        server.semantic_refresh_pending = false;
        server.semantic_refresh_mutex.unlock(server.io);
        return log.err("out of memory while building semantic tokens refresh", .{});
    };
    server.send(bytes);
    // Retire the baselines only after the refresh is written out: every result sent afterwards
    // reaches the client after the refresh. If they were retired first, a result sent in between
    // could arrive before the refresh and become the baseline for the delta request the client
    // makes after refreshing.
    server.semantic_cache.retireBaselines(server.io);
}

fn semanticRefreshFinished(server: *Server) void {
    server.semantic_refresh_mutex.lockUncancelable(server.io);
    const dirty = server.semantic_refresh_dirty;
    server.semantic_refresh_pending = false;
    server.semantic_refresh_dirty = false;
    server.semantic_refresh_mutex.unlock(server.io);
    if (dirty) server.requestSemanticRefresh();
}

/// Like `requestSemanticRefresh`: at most one refresh awaits the client's response, and requests
/// made meanwhile are merged into one more refresh after it
fn requestInlayRefresh(server: *Server) void {
    if (!server.inlay_refresh or server.isShuttingDown() or server.openDocumentCount() == 0) return;
    server.inlay_refresh_mutex.lockUncancelable(server.io);
    if (server.inlay_refresh_pending) {
        server.inlay_refresh_dirty = true;
        server.inlay_refresh_mutex.unlock(server.io);
        return;
    }
    server.inlay_refresh_pending = true;
    server.inlay_refresh_mutex.unlock(server.io);
    const bytes = jsonrpc.request(server.gpa, .{ .string = inlay_refresh_id }, "workspace/inlayHint/refresh", null) catch {
        server.inlay_refresh_mutex.lockUncancelable(server.io);
        server.inlay_refresh_pending = false;
        server.inlay_refresh_mutex.unlock(server.io);
        return log.err("out of memory while building inlay hint refresh", .{});
    };
    server.send(bytes);
}

fn inlayRefreshFinished(server: *Server) void {
    server.inlay_refresh_mutex.lockUncancelable(server.io);
    const dirty = server.inlay_refresh_dirty;
    server.inlay_refresh_pending = false;
    server.inlay_refresh_dirty = false;
    server.inlay_refresh_mutex.unlock(server.io);
    if (dirty) server.requestInlayRefresh();
}

// ── Notifications ────────────────────────────────────────────────────

fn processNotification(server: *Server, arena: Allocator, method: []const u8, params_value: json.Value) !Flow {
    if (std.mem.eql(u8, method, "exit")) return .exit;
    // Before initialization and after shutdown, all notifications except exit are dropped
    if (server.state == .uninitialized or server.state == .shutdown) return .@"continue";

    const handlers = .{
        .{ "$/cancelRequest", cancelRequest },
        .{ "textDocument/didOpen", didOpen },
        .{ "textDocument/didChange", didChange },
        .{ "textDocument/didClose", didClose },
        .{ "textDocument/didSave", didSave },
        .{ "workspace/didChangeConfiguration", didChangeConfiguration },
        .{ "workspace/didChangeWatchedFiles", didChangeWatchedFiles },
        .{ "workspace/didChangeWorkspaceFolders", didChangeWorkspaceFolders },
        .{ "initialized", initialized },
    };
    inline for (handlers) |h| {
        if (std.mem.eql(u8, method, h[0])) {
            const Params = types.ParamsType(h[0]);
            const params = jsonrpc.parseParams(Params, arena, params_value) catch |err| {
                log.warn("{s}: malformed params: {t}", .{ h[0], err });
                return .@"continue";
            };
            h[1](server, arena, params) catch |err| log.err("{s} failed: {t}", .{ h[0], err });
            return .@"continue";
        }
    }
    return .@"continue";
}

fn cancelRequest(server: *Server, _: Allocator, params: types.CancelParams) !void {
    server.cancelPending(switch (params.id) {
        .integer => |i| .{ .integer = i },
        .string => |s| .{ .string = s },
    });
}

fn fileIdFromUri(server: *Server, arena: Allocator, document_uri: []const u8) !?Vfs.FileId {
    const path = try documentPath(arena, document_uri) orelse return null;
    return try server.vfs.intern(path);
}

/// Path of a document: the path of a file URI; a document with a non-file URI such as `untitled:`
/// maps to a path named after the URI under a virtual directory (it does not clash with real
/// files and does not exist on disk, so it is not passed to the compiler; other features treat it
/// as a single file)
fn documentPath(arena: Allocator, document_uri: []const u8) Allocator.Error!?[]const u8 {
    const path = uri.toPath(arena, document_uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedScheme => {
            const ext = if (std.mem.endsWith(u8, document_uri, ".zon")) ".zon" else ".zig";
            return try std.fmt.allocPrint(arena, "{s}{c}{x:0>16}{s}", .{ virtual_root, std.fs.path.sep, std.hash.Wyhash.hash(0, document_uri), ext });
        },
        error.InvalidUri => return null,
    };
    if (!std.fs.path.isAbsolute(path)) return null;
    return path;
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

fn didOpen(server: *Server, arena: Allocator, params: types.DidOpenTextDocumentParams) !void {
    const id = try server.fileIdFromUri(arena, params.textDocument.uri) orelse return;
    {
        const owned = try server.gpa.dupe(u8, params.textDocument.uri);
        const last = try server.gpa.dupe(u8, params.textDocument.uri);
        server.docs_mutex.lockUncancelable(server.io);
        defer server.docs_mutex.unlock(server.io);
        const gop = server.open_docs.getOrPut(server.gpa, id) catch |err| {
            server.gpa.free(owned);
            server.gpa.free(last);
            return err;
        };
        if (gop.found_existing) server.gpa.free(gop.value_ptr.*);
        gop.value_ptr.* = owned;
        const lgop = server.last_uris.getOrPut(server.gpa, id) catch |err| {
            server.gpa.free(last);
            return err;
        };
        if (lgop.found_existing) server.gpa.free(lgop.value_ptr.*);
        lgop.value_ptr.* = last;
    }
    _ = server.watched_built.remove(id);
    {
        const owned = try server.gpa.dupe(u8, params.textDocument.text);
        server.db.beginWrite();
        defer server.db.endWrite();
        try server.db.set(FileText, id, owned, .low);
        try server.setDocVersion(id, params.textDocument.version);
        // Before a new session starts, wait for old read requests to exit; it must not inherit
        // delta baselines from the period while the document was closed or from the old session.
        server.semantic_cache.remove(server.io, server.gpa, id);
    }
    server.publishFiles(&.{id}, false);
    server.publishDependents(&.{id});
    if (server.openDocumentCount() > 1) server.requestRefresh();
    server.compileSingle(id);
    server.scheduleCompileSetRefresh(&.{id});
}

fn didChange(server: *Server, arena: Allocator, params: types.DidChangeTextDocumentParams) !void {
    const id = try server.fileIdFromUri(arena, params.textDocument.uri) orelse return;
    {
        server.db.beginWrite();
        defer server.db.endWrite();
        const old = server.db.peek(FileText, id) orelse "";
        const new = try offsets.applyChanges(server.gpa, old, params.contentChanges, server.encoding);
        try server.db.set(FileText, id, new, .low);
        try server.setDocVersion(id, params.textDocument.version);
    }
    server.publishDebounced(id);
}

fn setDocVersion(server: *Server, id: Vfs.FileId, version: i32) Allocator.Error!void {
    server.docs_mutex.lockUncancelable(server.io);
    defer server.docs_mutex.unlock(server.io);
    try server.doc_versions.put(server.gpa, id, version);
}

/// The version of `file` when it is open in the client; null otherwise
fn docVersion(server: *Server, file: Vfs.FileId) ?i32 {
    server.docs_mutex.lockUncancelable(server.io);
    defer server.docs_mutex.unlock(server.io);
    return server.doc_versions.get(file);
}

fn didClose(server: *Server, arena: Allocator, params: types.DidCloseTextDocumentParams) !void {
    const id = try server.fileIdFromUri(arena, params.textDocument.uri) orelse return;
    defer {
        // Even if reading from disk or replacing the text fails, still wait for old read requests
        // to exit first, which prevents a snapshot from being written again after closing.
        server.db.beginWrite();
        defer server.db.endWrite();
        server.semantic_cache.remove(server.io, server.gpa, id);
    }
    // After closing, the disk contents are authoritative
    {
        server.docs_mutex.lockUncancelable(server.io);
        defer server.docs_mutex.unlock(server.io);
        _ = server.doc_versions.remove(id);
    }
    const disk = server.vfs.readFromDisk(id, arena) catch |err| switch (err) {
        error.FileTooBig => null,
        else => |e| return e,
    };
    try server.setFileText(id, disk);
    {
        server.docs_mutex.lockUncancelable(server.io);
        defer server.docs_mutex.unlock(server.io);
        if (server.open_docs.fetchSwapRemove(id)) |kv| server.gpa.free(kv.value);
    }
    server.publishDependents(&.{id});
    server.requestRefresh();
    server.scheduleCompileSetRefresh(&.{id});
    // When a single-file mode root file was deleted from disk while open (notifications of
    // external changes skip open files), drop its compile results on close and republish the files
    // it imports as well
    if (disk == null and server.dropSingle(id)) return;
    // Results that are no longer needed after closing are freed immediately, so they do not grow
    // linearly with the files opened over a long session
    server.releaseSingleIfUnused(id);
    // After closing, republish from the disk contents (files in the compile set may still have
    // compiler diagnostics)
    server.publishFiles(&.{id}, true);
}

/// After a document is closed, frees its single-file results if they no longer need to be kept:
/// no compile is running, and the results contain no diagnostics (diagnostics continue to be
/// published after closing). When the file is reopened or saved later, it is recompiled on demand.
fn releaseSingleIfUnused(server: *Server, file: Vfs.FileId) void {
    {
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        const sf = server.single.getPtr(file) orelse return;
        if (sf.running or sf.pending) return;
        if (sf.result) |r| for (r.files.values()) |fr| {
            if (fr.items.len != 0) return;
        };
        sf.clearResult(server.gpa);
        _ = server.single.swapRemove(file);
    }
}

fn didSave(server: *Server, arena: Allocator, params: types.DidSaveTextDocumentParams) !void {
    const id = try server.fileIdFromUri(arena, params.textDocument.uri) orelse return;
    const path = server.vfs.path(id);
    const base = std.fs.path.basename(path);
    const is_build_file = isProjectFile(base);

    // A build.zig newly created in a root directory: start the project
    if (std.mem.eql(u8, base, "build.zig")) if (std.fs.path.dirname(path)) |dir| {
        if (try server.refreshRoot(dir)) return;
    };

    // Rebuild every project that contains the file (shared modules, the standard library)
    const list = try server.workspaceList(arena);
    defer server.releaseList(arena, list);
    for (list) |ws| {
        // Outside watch mode, the maker does not reconfigure automatically: restart. Build
        // scripts and configure inputs may lie outside the project's files.
        if ((is_build_file and std.mem.eql(u8, std.fs.path.dirname(path) orelse "", ws.root)) or ws.isBuildScript(id) or
            ws.changesConfigureInput(path, .changed))
        {
            server.restartWorkspace(ws, 0);
        } else if (ws.owns(id)) {
            server.requestBuild(ws);
        }
    }
    // Single-file mode: compile the file itself if it is a standalone file; root files whose last
    // compile read it or reported errors in it are recompiled as well
    server.recompileSingle(&.{id}, &.{id});
}

/// Files in a project root directory whose changes require restarting the project
fn isProjectFile(base: []const u8) bool {
    return std.mem.eql(u8, base, "build.zig") or std.mem.eql(u8, base, "build.zig.zon") or std.mem.eql(u8, base, Config.project_file);
}

/// External changes on disk (outside the editor: git checkout, code generation, etc.). For open
/// files the buffer is authoritative; other known files are updated from the disk contents
/// (deleted ones become nonexistent), without writing or republishing when the contents equal
/// the known ones. A change to build.zig / build.zig.zon / zig-analyzer.zon in a workspace root
/// directory or to a project's build script restarts that project; creating or deleting
/// build.zig in a root directory starts or stops the project; changes to other files rebuild
/// projects and recompile single files; nothing is rebuilt when the disk contents equal those the
/// last rebuild was based on.
fn didChangeWatchedFiles(server: *Server, arena: Allocator, params: types.DidChangeWatchedFilesParams) !void {
    const Change = struct {
        file: Vfs.FileId,
        path: []const u8,
        text: ?[]u8,
        durability: database.Durability,
        /// Hash of the disk contents; null if the file does not exist
        disk: ?u64,
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
    // Known files that changed (including open files: the maker reads the disk)
    var known: std.ArrayList(Vfs.FileId) = .empty;
    // When a file changes several times in one batch, the last change wins: an atomic save first
    // deletes and then recreates the file, and with unchanged contents the two together are not a
    // change
    var events: std.StringArrayHashMapUnmanaged(types.FileChangeType) = .empty;
    for (params.changes) |event| {
        const path = uri.toPath(arena, event.uri) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnsupportedScheme, error.InvalidUri => continue,
        };
        if (!std.fs.path.isAbsolute(path)) continue;
        try events.put(arena, path, event.type);
    }
    // Source files created or deleted under the root directories change what find references and
    // rename search
    const rescan = try server.changesWorkspaceFiles(arena, rules, events.keys(), events.values());
    defer if (rescan) server.scheduleScan();
    for (events.keys(), events.values()) |path, kind| {
        const base = std.fs.path.basename(path);
        const dir = std.fs.path.dirname(path) orelse "";
        if (std.mem.eql(u8, base, "build.zig")) try build_zig_dirs.append(arena, dir);
        // Files never seen before have no known contents to update (a new file is loaded when it
        // is imported); project files have no contents to compare against and count as changed
        const file = try server.vfs.lookup(path) orelse {
            if (isProjectFile(base)) try build_files.append(arena, dir);
            continue;
        };
        const is_open = blk: {
            server.docs_mutex.lockUncancelable(server.io);
            defer server.docs_mutex.unlock(server.io);
            break :blk server.open_docs.contains(file);
        };
        if (is_open) {
            if (isProjectFile(base)) try build_files.append(arena, dir);
            try known.append(arena, file);
            continue;
        }
        const text = if (kind == .Deleted) null else server.vfs.readFromDisk(file, server.gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            error.FileTooBig => null,
        };
        changes.append(arena, .{
            .file = file,
            .path = path,
            .text = text,
            .durability = origin.classify(&server.vfs, rules, server.vfs.path(file), false).durability(),
            .disk = if (text) |t| std.hash.Wyhash.hash(0, t) else null,
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
        var ctx = server.db.beginRead(arena);
        defer ctx.end();
        var kept: usize = 0;
        for (changes.items) |*c| {
            c.edited = !sameText(&ctx, c.file, c.text);
            c.rebuild = if (server.watched_built.get(c.file)) |built| !std.meta.eql(built, c.disk) else true;
            if (!c.edited and !c.rebuild) {
                if (c.text) |t| server.gpa.free(t);
                continue;
            }
            changes.items[kept] = c.*;
            kept += 1;
        }
        changes.shrinkRetainingCapacity(kept);
    }
    var edited: std.ArrayList(Vfs.FileId) = .empty;
    var rebuilt: std.ArrayList(Vfs.FileId) = .empty;
    for (changes.items) |c| {
        if (c.edited) try edited.append(arena, c.file);
        if (!c.rebuild) continue;
        try rebuilt.append(arena, c.file);
        try known.append(arena, c.file);
        if (isProjectFile(std.fs.path.basename(c.path))) try build_files.append(arena, std.fs.path.dirname(c.path) orelse "");
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
    for (build_zig_dirs.items) |dir| if (try server.refreshRoot(dir)) try refreshed.append(arena, dir);

    const list = try server.workspaceList(arena);
    defer server.releaseList(arena, list);
    for (list) |ws| {
        // Outside watch mode, the maker does not reconfigure automatically: restart
        const reconfigure = for (build_files.items) |dir| {
            if (std.mem.eql(u8, dir, ws.root)) break true;
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
                if (std.mem.eql(u8, dir, ws.root)) break true;
            } else false;
            if (!started) server.restartWorkspace(ws, 0);
            continue;
        }
        for (rebuilt.items) |file| if (ws.owns(file)) {
            server.requestBuild(ws);
            break;
        };
    }
    if (edited.items.len != 0) {
        server.publishFiles(edited.items, true);
        server.publishDependents(edited.items);
        server.requestRefresh();
        server.scheduleCompileSetRefresh(edited.items);
    }
    if (rebuilt.items.len == 0) return;
    // Single-file mode: files imported by open files may have changed
    server.docs_mutex.lockUncancelable(server.io);
    const open = try arena.dupe(Vfs.FileId, server.open_docs.keys());
    server.docs_mutex.unlock(server.io);
    server.recompileSingle(open, rebuilt.items);
    // If it cannot be recorded, the next change rebuilds as usual
    for (changes.items) |c| if (c.rebuild) server.watched_built.put(server.gpa, c.file, c.disk) catch {};
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

/// The file's known text is the same as `text` (including both being absent); a failed read counts
/// as different
fn sameText(ctx: *Db.Ctx, file: Vfs.FileId, text: ?[]const u8) bool {
    const current = ctx.get(FileText, file) catch return false;
    const known = current orelse return text == null;
    return std.mem.eql(u8, known, text orelse return false);
}

/// External changes discovered by the server: handled the same way as the client's
/// `workspace/didChangeWatchedFiles` notification, serialized with main loop message handling
pub fn applyWatchedChanges(server: *Server, arena: Allocator, changes: []const types.FileEvent) void {
    defer {
        server.watch_mutex.lockUncancelable(server.io);
        server.watch_batches += 1;
        server.watch_mutex.unlock(server.io);
        server.watch_cond.broadcast(server.io);
    }
    server.write_mutex.lockUncancelable(server.io);
    defer server.write_mutex.unlock(server.io);
    if (server.state != .running or server.isShuttingDown()) return;
    // Count as busy during processing: when a project restarts, the old instance finishes before
    // the new instance counts as busy, and the watch task itself does not count as busy; whoever
    // waits for idle (waitIdle, shutdown) must not be allowed to return in between
    server.busyBegin();
    defer server.busyEnd();
    server.didChangeWatchedFiles(arena, .{ .changes = changes }) catch |err| log.err("applying changes on disk failed: {t}", .{err});
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
    server.docs_mutex.lockUncancelable(server.io);
    defer server.docs_mutex.unlock(server.io);
    return server.open_docs.contains(file);
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

/// Whether the server discovers external changes itself (see `Config.Watcher`)
pub fn watchesFiles(server: *Server) bool {
    server.config_mutex.lockUncancelable(server.io);
    defer server.config_mutex.unlock(server.io);
    return switch (server.config.files_watcher) {
        .auto => !server.register_watch,
        .client => false,
        .server => true,
    };
}

/// Rules for classifying file origins (see `origin.classify`), copied into `arena`: the zig
/// environment, the workspace root directories, and each project's local cache and dependency
/// packages (known only after the project has read its build graph). Read while holding
/// roots_mutex and then workspaces_mutex; must not be called inside a write transaction.
pub fn originRules(server: *Server, arena: Allocator) Allocator.Error!origin.Rules {
    var rules: origin.Rules = .{};
    if (server.zigEnv()) |env| {
        rules.zig_lib = try arena.dupe(u8, env.lib_dir);
        rules.global_cache = try arena.dupe(u8, env.global_cache_dir);
    }
    rules.roots = try server.rootsAlloc(arena);
    var local_caches: std.ArrayList([]const u8) = .empty;
    var packages: std.ArrayList([]const u8) = .empty;
    {
        // workspaces_mutex first, then ws.mutex
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        for (server.workspaces.items) |ws| try ws.libraryDirs(arena, &local_caches, &packages);
    }
    rules.local_caches = local_caches.items;
    rules.packages = packages.items;
    return rules;
}

/// The file belongs to some project's module graph (its compile set, or reachable from the
/// other compile steps)
fn inProject(server: *Server, file: Vfs.FileId) bool {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    for (server.workspaces.items) |ws| if (ws.contains(file)) return true;
    return false;
}

/// Origin of the file (see `origin.classify`)
pub fn fileOrigin(server: *Server, file: Vfs.FileId) origin.Origin {
    return server.originOf(file, server.inProject(file));
}

/// Treats the file as `.other` when out of memory leaves the classification rules unavailable
fn originOf(server: *Server, file: Vfs.FileId, in_project: bool) origin.Origin {
    var arena: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena.deinit();
    const rules = server.originRules(arena.allocator()) catch return .other;
    return origin.classify(&server.vfs, rules, server.vfs.path(file), in_project);
}

fn didChangeConfiguration(server: *Server, _: Allocator, params: types.DidChangeConfigurationParams) !void {
    // Clients that only notify "the configuration has changed" without contents (such as VS Code):
    // pull the configuration from the client
    if (params.settings == .null) {
        if (server.pull_config) server.requestConfig();
        return;
    }
    const fresh = Config.parse(server.gpa, params.settings) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidConfig => return server.showWarning("invalid zig-analyzer settings, keeping the previous ones"),
    };
    try server.applyConfig(fresh);
}

/// Replaces the current configuration; restarts the projects when build-related settings change
fn applyConfig(server: *Server, fresh: Config) Allocator.Error!void {
    var new = fresh;
    server.reportConfigWarnings("zig-analyzer settings", &new);
    server.config_mutex.lockUncancelable(server.io);
    const zig_changed = !server.config.sameZig(&new);
    const zig_paths_changed = !server.config.sameZigPaths(&new);
    const build_changed = !server.config.sameBuild(&new);
    const semantic_changed = server.config.callsite_seeding != new.callsite_seeding or server.config.semantic_tokens_mode != new.semantic_tokens_mode or
        server.config.semantic_tokens_global_var != new.semantic_tokens_global_var;
    const imports_enabled = !server.config.completion_auto_import and new.completion_auto_import;
    const inactive_changed = server.config.inactive_code != new.inactive_code;
    const naming_changed = !server.config.sameNaming(&new);
    const build_was_enabled = server.config.build_enable;
    const watcher_changed = server.config.files_watcher != new.files_watcher;
    const inlay_changed = server.config.inlay_types != new.inlay_types or server.config.inlay_field_types != new.inlay_field_types or
        server.config.inlay_anonymous_containers != new.inlay_anonymous_containers or
        server.config.inlay_parameters != new.inlay_parameters or server.config.inlay_builtin_parameters != new.inlay_builtin_parameters or
        server.config.inlay_exclude_single_argument != new.inlay_exclude_single_argument or
        server.config.hide_redundant_param_names != new.hide_redundant_param_names or server.config.inlay_max_length != new.inlay_max_length or
        server.config.callsite_seeding != new.callsite_seeding;
    const compiler_disabled = server.config.compiler_diagnostics and !new.compiler_diagnostics;
    const log_file_changed = !eqlOptionalStr(server.config.log_file, new.log_file);
    server.applyLogging(&new, log_file_changed);
    server.applyCacheLimits(&new);
    server.config.deinit(server.gpa);
    server.config = new;
    server.config_mutex.unlock(server.io);
    if (inactive_changed or naming_changed) server.publishOpenFiles();
    if (watcher_changed) server.resyncWatcher();

    if (zig_changed and server.started) server.showWarning("zig.path takes effect after restarting zig-analyzer");
    // Before startup, the startup phase applies them with the current configuration
    if (zig_paths_changed and server.started) {
        server.busyBegin();
        spawn(server.io, &server.bg_group, reloadZigPathsTask, .{server});
    }
    if (compiler_disabled) server.clearSingleFileResults();
    if (inlay_changed) server.requestInlayRefresh();
    if (semantic_changed) server.requestSemanticRefresh();
    if (imports_enabled and server.imports_wanted.load(.acquire)) server.scheduleIndexing();
    if (build_changed) {
        if (!new.build_enable) {
            // Build system integration turned off: stop the projects; their files are handled
            // in single-file mode instead
            server.stopProjects();
        } else if (!build_was_enabled) {
            if (server.zigEnv() != null) server.startProjectsForRoots();
        } else {
            const list = try server.workspaceList(server.gpa);
            defer server.releaseList(server.gpa, list);
            if (list.len != 0) log.info("build settings changed, restarting projects", .{});
            for (list) |ws| server.restartWorkspace(ws, 0);
        }
        // Files' compile contexts may have changed, and compiler diagnostics may be re-enabled
        server.reconcileSingle();
    }
}

/// Whether build system integration and compiler diagnostics are enabled
fn buildFlags(server: *Server) struct { build: bool, compiler: bool } {
    server.config_mutex.lockUncancelable(server.io);
    defer server.config_mutex.unlock(server.io);
    return .{ .build = server.config.build_enable, .compiler = server.config.compiler_diagnostics };
}

/// Stops all projects and clears the compiler diagnostics they published; the module graph is
/// updated accordingly
fn stopProjects(server: *Server) void {
    // Take them out of the list (together with the references the list holds)
    const list = blk: {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        const list = server.gpa.dupe(*Workspace, server.workspaces.items) catch return;
        server.workspaces.clearRetainingCapacity();
        break :blk list;
    };
    defer server.releaseList(server.gpa, list);
    var stale: std.ArrayList(Vfs.FileId) = .empty;
    defer stale.deinit(server.gpa);
    for (list) |ws| {
        server.stopProject(ws);
        ws.mutex.lockUncancelable(server.io);
        stale.appendSlice(server.gpa, ws.result_files.keys()) catch {};
        ws.mutex.unlock(server.io);
    }
    server.updateModuleGraph();
    server.publishFiles(stale.items, true);
    server.publishOpenFiles();
    // Open files are compiled in single-file mode instead
    server.reconcileSingle();
}

/// Starts projects for the root directories that have a build.zig (rechecked on disk: build.zig
/// may have been created or deleted after the root directory was added)
fn startProjectsForRoots(server: *Server) void {
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
        const has_build = server.hasBuildZig(root) catch return;
        _ = server.setRootHasBuild(root, has_build);
        if (has_build) server.startWorkspace(root);
    }
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

/// Records whether root directory `root` has a build.zig; returns whether the record changed
/// (false when `root` is not a root directory)
fn setRootHasBuild(server: *Server, root: []const u8, has_build: bool) bool {
    server.roots_mutex.lockUncancelable(server.io);
    defer server.roots_mutex.unlock(server.io);
    for (server.roots.items, server.root_has_build.items) |r, *flag| if (std.mem.eql(u8, r, root)) {
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
fn refreshRoot(server: *Server, dir: []const u8) Allocator.Error!bool {
    const has_build = try server.hasBuildZig(dir);
    if (!server.setRootHasBuild(dir, has_build)) return false;
    if (has_build) {
        log.info("{s}: build.zig was created", .{dir});
        if (server.zigEnv() != null) server.startWorkspace(dir);
    } else {
        log.info("{s}: build.zig was deleted", .{dir});
        server.removeProject(dir);
        server.updateModuleGraph();
    }
    // Open files: single-file mode results no longer apply, or they switch to single-file mode
    server.publishOpenFiles();
    server.reconcileSingle();
    return true;
}

/// Clears the compiler diagnostics of single-file mode (when compiler diagnostics are disabled).
/// Root files not being compiled are no longer recorded; when re-enabled, the open files are
/// recompiled.
fn clearSingleFileResults(server: *Server) void {
    var files: std.ArrayList(Vfs.FileId) = .empty;
    defer files.deinit(server.gpa);
    {
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        var i: usize = server.single.count();
        while (i > 0) {
            i -= 1;
            const sf = &server.single.values()[i];
            if (sf.result != null) {
                files.append(server.gpa, server.single.keys()[i]) catch {};
                files.appendSlice(server.gpa, sf.files.keys()) catch {};
            }
            sf.clearResult(server.gpa);
            if (!sf.running) server.single.swapRemoveAt(i);
        }
    }
    server.publishFiles(files.items, true);
}

/// Log level and slow request threshold; with `reopen_file`, reopens the log file as configured
fn applyLogging(server: *Server, config: *const Config, reopen_file: bool) void {
    za.util.log.setLevel(config.log_level);
    server.slow_request_ms.store(config.slow_request_ms, .monotonic);
    server.debounce_ms.store(config.debounce_ms, .monotonic);
    server.max_intern_pool_mb.store(config.max_intern_pool_mb, .monotonic);
    server.callsite_seeding.store(config.callsite_seeding, .monotonic);
    if (!reopen_file) return;
    za.util.log.setFile(config.log_file) catch |err| {
        log.warn("cannot open log file {s}: {t}", .{ config.log_file.?, err });
        server.showWarning("cannot open log.file, logging to stderr only");
    };
}

/// Cache capacity: settings in `cache.queries` take precedence; the number of syntax trees
/// (`ParseFile` and `FileAstIdMap`) defaults to `cache.capacity`
fn applyCacheLimits(server: *Server, config: *const Config) void {
    inline for (@typeInfo(Config.CacheQueries).@"struct".field_names) |name| {
        const limit = @field(config.cache_queries, name);
        const syntax_tree = comptime std.mem.eql(u8, name, "ParseFile") or std.mem.eql(u8, name, "FileAstIdMap");
        const count: ?usize = limit.count orelse if (syntax_tree) config.cache_capacity else null;
        const bytes: ?usize = if (limit.mb) |mb| @as(usize, mb) * 1024 * 1024 else null;
        server.db.setLru(QueryNamed(name), count, bytes);
    }
}

/// The query named `name` in `Db`
fn QueryNamed(comptime name: []const u8) type {
    // Compares `name` with the names of all queries
    @setEvalBranchQuota(10_000);
    var found: ?type = null;
    for (Db.query_types) |Q| if (std.mem.endsWith(u8, @typeName(Q), "." ++ name)) {
        if (found != null) @compileError("more than one query named " ++ name);
        found = Q;
    };
    return found orelse @compileError("no query named " ++ name);
}

fn eqlOptionalStr(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

const config_request_prefix = "zig-analyzer/configuration/";

/// Pulls the `zig-analyzer` configuration section from the client; the response is handled by
/// `handleConfigResponse`
fn requestConfig(server: *Server) void {
    var buf: [64]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, config_request_prefix ++ "{d}", .{server.config_requests}) catch unreachable;
    server.config_requests += 1;
    server.config_outstanding += 1;
    server.busyBegin();
    server.sendRequest(.{ .string = id }, "workspace/configuration", types.ConfigurationParams{ .items = &.{.{ .section = "zig-analyzer" }} });
}

fn handleConfigResponse(server: *Server, id: []const u8, result: json.Value, failed: bool) Allocator.Error!void {
    const n = std.fmt.parseInt(u32, id[config_request_prefix.len..], 10) catch return;
    // Shutdown has already stopped waiting for it
    if (server.config_outstanding == 0) return;
    defer {
        server.config_outstanding -= 1;
        server.busyEnd();
    }
    // A newer request has been sent since: wait for the latest response
    if (n + 1 != server.config_requests) return;
    defer if (server.startup_pending) {
        server.startup_pending = false;
        server.startProjects();
    };
    if (failed) return log.info("client failed to provide configuration", .{});
    // The result corresponds one-to-one to the requested items; it is null when the section is not
    // set, meaning all defaults are used
    const section: json.Value = if (result == .array and result.array.items.len == 1) result.array.items[0] else .null;
    const fresh: Config = if (section == .null) .{} else Config.parse(server.gpa, section) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidConfig => return server.showWarning("invalid zig-analyzer settings, keeping the previous ones"),
    };
    try server.applyConfig(fresh);
}

/// A copy of the current configuration (freed by the caller)
pub fn configSnapshot(server: *Server) Allocator.Error!Config {
    server.config_mutex.lockUncancelable(server.io);
    defer server.config_mutex.unlock(server.io);
    return server.config.clone(server.gpa);
}

fn initialized(server: *Server, arena: Allocator, _: types.InitializedParams) !void {
    if (server.initialized_received) return;
    server.initialized_received = true;
    var registrations: std.ArrayList(types.Registration) = .empty;
    if (server.register_config) try registrations.append(arena, .{ .id = "zig-analyzer/didChangeConfiguration", .method = "workspace/didChangeConfiguration" });
    if (server.register_watch) {
        // Changes made outside the editor (git checkout, code generation, etc.): source files,
        // build.zig.zon and project configuration files
        const options = try std.json.parseFromSliceLeaky(std.json.Value, arena,
            \\{"watchers": [{"globPattern": "**/*.zig"}, {"globPattern": "**/*.zon"}]}
        , .{});
        try registrations.append(arena, .{ .id = "zig-analyzer/didChangeWatchedFiles", .method = "workspace/didChangeWatchedFiles", .registerOptions = options });
    }
    if (registrations.items.len != 0) {
        server.sendRequest(.{ .string = "zig-analyzer/register" }, "client/registerCapability", types.RegistrationParams{ .registrations = registrations.items });
    }
    if (server.pull_config) {
        // Start projects once the configuration has been pulled
        server.startup_pending = true;
        server.requestConfig();
    } else {
        server.startProjects();
    }
}

fn startProjects(server: *Server) void {
    server.started = true;
    server.busyBegin();
    server.bg_group.concurrent(server.io, startup, .{server}) catch |err| {
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

// ── Projects and background tasks ────────────────────────────────────

/// Message shown when the user's zig differs from the version zig-analyzer was built with
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
    // The origin rules (the Zig installation and the global cache) are known from here on, also
    // when the zig environment cannot be queried
    defer server.scheduleScan();
    var config = server.configSnapshot() catch return;
    defer config.deinit(server.gpa);
    const queried = ZigEnv.query(server.gpa, server.io, config.zig_path) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        // `zig build test` deliberately cannot find zig (see `ZigEnv.query`)
        if (@import("builtin").is_test and !@import("build_options").zig_tests) return;
        const message = std.fmt.allocPrint(server.gpa, "cannot run {s} env ({t}): the standard library, named modules, and compiler diagnostics are unavailable; set zig.path to the zig executable", .{ config.zig_path orelse "zig", err }) catch null;
        defer if (message) |m| server.gpa.free(m);
        server.showWarning(message orelse "cannot run zig env: the standard library, named modules, and compiler diagnostics are unavailable; set zig.path to the zig executable");
        return;
    };
    const detected = server.ownEnv(queried) catch return log.err("out of memory while storing the zig environment", .{});
    {
        server.env_mutex.lockUncancelable(server.io);
        defer server.env_mutex.unlock(server.io);
        // An environment already exists (should not happen: `initialized` is handled only once):
        // keep the old value
        if (server.detected_env != null) return;
        server.detected_env = detected;
    }
    log.info("zig {s} ({s})", .{ detected.version, detected.zig_exe });
    _ = try server.applyZigPaths();
    const env = server.zigEnv() orelse return;
    if (!env.matchesBuiltin()) {
        // The in-process AstGen may not match the user's zig: live diagnostics use the user's
        // zig ast-check instead
        const built = @import("builtin").zig_version_string;
        const message = std.fmt.allocPrint(server.gpa, version_mismatch_message, .{ env.version, built, built, env.version }) catch null;
        defer if (message) |m| server.gpa.free(m);
        server.showWarningOnce(message orelse "zig version differs from the one zig-analyzer was built with");
        const exe = server.gpa.dupe(u8, env.zig_exe) catch return;
        server.db.beginWriteOf(comptime Db.inputSet(&.{live.LiveBackend}), .unordered);
        defer server.db.endWrite();
        server.db.set(live.LiveBackend, {}, .{ .subprocess = exe }, .high) catch {};
    }
    server.updateModuleGraph();
    if (server.buildFlags().build) server.startProjectsForRoots();
    // Detached files opened before startup: compile them now that the zig environment is ready and
    // projects have started loading
    server.startup_done.store(true, .release);
    // The origins of files opened before startup (the standard library, files outside the
    // workspace folders) are known only now, and naming hints depend on them
    server.publishOpenFiles();
    server.reconcileSingle();
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
    const detected, const current = blk: {
        server.env_mutex.lockUncancelable(io);
        defer server.env_mutex.unlock(io);
        break :blk .{ server.detected_env orelse return .{}, server.zig_env };
    };
    var config = server.configSnapshot() catch Config{};
    defer config.deinit(gpa);
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
        break :env server.ownEnv(fresh) catch {
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
        // `compileSingle`), whose diagnostics these files get
        break :blk za.project.builtin.generate(gpa, io, env, &.{"build-obj"}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => null,
        };
    };

    var change: ZigPathsChange = .{};
    var unused_builtin: ?[]u8 = default_builtin;
    {
        server.env_mutex.lockUncancelable(io);
        defer server.env_mutex.unlock(io);
        change.env = server.zig_env != env;
        server.zig_env = env;
        if (!eqlOptionalStr(server.default_builtin, default_builtin)) {
            change.builtin = true;
            // The default builtin.zig is read only while holding the lock (see
            // `updateModuleGraphInner`): the replaced path can be freed outside the lock
            unused_builtin = server.default_builtin;
            server.default_builtin = default_builtin;
        }
    }
    if (unused_builtin) |p| gpa.free(p);
    if (notes.end != 0) server.showWarning(notes.buffered());
    return change;
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
fn reloadZigPathsTask(server: *Server) Io.Cancelable!void {
    defer server.busyEnd();
    const change = try server.applyZigPaths();
    if (!change.env and !change.builtin) return;
    log.info("zig paths changed, reloading the standard library and builtin.zig", .{});
    server.updateModuleGraph();
    if (change.env) {
        const list = server.workspaceList(server.gpa) catch return;
        defer server.releaseList(server.gpa, list);
        if (list.len != 0) log.info("zig paths changed, restarting projects", .{});
        for (list) |ws| server.restartWorkspace(ws, 0);
        var roots: std.ArrayList(Vfs.FileId) = .empty;
        defer roots.deinit(server.gpa);
        {
            server.single_mutex.lockUncancelable(server.io);
            defer server.single_mutex.unlock(server.io);
            roots.appendSlice(server.gpa, server.single.keys()) catch {};
        }
        server.recompileSingle(roots.items, &.{});
        // Files in the standard library and the global cache are not watched (see `watchable`):
        // the set changes with the effective directories
        server.resyncWatcher();
    }
    // The origins of files (the standard library, dependency packages in the global cache) and
    // inference results may change
    server.publishOpenFiles();
    server.reconcileSingle();
}

// ── Single-file mode ─────────────────────────────────────────────────

/// Compile context of a file: decides whether it can be compiled as a root in single-file mode, and
/// whether single-file compile results are used for its diagnostics. Checked in order: dependency
/// library, a project's module graph, a root directory with build.zig, an unloaded project in an
/// ancestor directory; only a .zig file that is none of these is a detached file.
const FileContext = enum {
    /// Not compiled: virtual documents, and non-.zig files that belong to no project
    none,
    /// A file in a dependency library (see `origin.Origin.isLibrary`):
    /// compiled only as a dependency, never as a root. Errors reported
    /// in it by the real compile entry points are published as usual.
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
    fn usesSingle(context: FileContext) bool {
        return switch (context) {
            .none, .library, .detached => true,
            .project, .project_dir, .unloaded_project => false,
        };
    }
};

fn fileContext(server: *Server, file: Vfs.FileId) FileContext {
    const in_project = server.inProject(file);
    switch (server.originOf(file, in_project)) {
        .virtual => return .none,
        .zig_lib, .generated, .package => return .library,
        .user, .outside, .other => {},
    }
    if (in_project) return .project;
    const path = server.vfs.path(file);
    const build = server.buildFlags().build;
    if (build) {
        server.roots_mutex.lockUncancelable(server.io);
        defer server.roots_mutex.unlock(server.io);
        for (server.roots.items, server.root_has_build.items) |root, has_build| {
            if (has_build and server.vfs.isUnder(path, root)) return .project_dir;
        }
    }
    if (!std.mem.endsWith(u8, path, ".zig")) return .none;
    if (build and server.projectDirOf(path) != null) return .unloaded_project;
    return .detached;
}

/// Directory of the project a file belongs to: the first of its directory and that directory's
/// ancestors that has a build.zig. Stops at `.zig-cache` and `zig-pkg`: the files in them (caches,
/// fetched dependency packages) are not source code of the enclosing project.
fn projectDirOf(server: *Server, path: []const u8) ?[]const u8 {
    var dir = std.fs.path.dirname(path);
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        const name = std.fs.path.basename(d);
        if (std.mem.eql(u8, name, ".zig-cache") or std.mem.eql(u8, name, "zig-pkg")) return null;
        if (server.hasBuildZig(d) catch false) return d;
    }
    return null;
}

/// Some project is still loading for the first time (see `Workspace.load_done`): it is not yet
/// known which files outside the root directories belong to projects
fn projectsLoading(server: *Server) bool {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    for (server.workspaces.items) |ws| if (ws.isLoading()) return true;
    return false;
}

/// Compiles a detached file in the background with `zig build-obj -fno-emit-bin`; when requested
/// again during a compile, recompiles after that compile finishes
fn compileSingle(server: *Server, file: Vfs.FileId) void {
    if (!server.startup_done.load(.acquire)) return; // compiled when startup finishes
    if (server.fileContext(file) != .detached) return;
    if (!server.buildFlags().compiler) return;
    // The compiler reads from disk: a file that is not on disk (a new file not saved yet, a deleted
    // file) is not compiled, and its previous compile result is dropped
    Io.Dir.cwd().access(server.io, server.vfs.path(file), .{}) catch {
        _ = server.dropSingle(file);
        return;
    };
    // While projects are loading for the first time, the file may turn out to belong to a project:
    // compile it when loading finishes rather than in the wrong context (see `reconcileSingle`)
    const deferred = server.projectsLoading();
    {
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        const gop = server.single.getOrPut(server.gpa, file) catch return;
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
    spawn(server.io, &server.bg_group, singleFileTask, .{ server, file });
}

/// Reconciles single-file mode with the current compile context of each file; called after the
/// contexts may have changed (the zig environment became ready, a project finished loading, a
/// compile set changed, a new instance replaced an old one, projects or root directories were added
/// or removed, build integration or compiler diagnostics were toggled): roots that are no longer
/// detached files drop their compile results; deferred compiles are run, and open detached files
/// that have never been compiled are compiled. Whether single-file results are used for a file
/// depends on that file's context (see `FileContext.usesSingle`), so the files in the results are
/// republished accordingly.
pub fn reconcileSingle(server: *Server) void {
    if (server.isShuttingDown()) return;
    const gpa = server.gpa;
    var roots: std.ArrayList(Vfs.FileId) = .empty;
    defer roots.deinit(gpa);
    var affected: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty;
    defer affected.deinit(gpa);
    var compile: std.ArrayList(Vfs.FileId) = .empty;
    defer compile.deinit(gpa);
    {
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        roots.appendSlice(gpa, server.single.keys()) catch return;
        for (server.single.values()) |*sf| for (sf.files.keys()) |f| affected.put(gpa, f, {}) catch return;
    }
    // The context is determined outside the lock: that
    // needs the locks of projects and root directories
    for (roots.items) |root| {
        const detached = server.fileContext(root) == .detached;
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        const sf = server.single.getPtr(root) orelse continue;
        if (detached) {
            if (sf.pending) compile.append(gpa, root) catch {};
            continue;
        }
        affected.put(gpa, root, {}) catch {};
        for (sf.files.keys()) |f| affected.put(gpa, f, {}) catch {};
        if (sf.running) {
            // Dropped according to the context when the compile finishes (see `singleFileTask`)
            sf.rerun = true;
        } else {
            sf.clearResult(gpa);
            _ = server.single.swapRemove(root);
        }
    }
    server.publishFiles(affected.keys(), true);

    server.docs_mutex.lockUncancelable(server.io);
    const open = gpa.dupe(Vfs.FileId, server.open_docs.keys()) catch {
        server.docs_mutex.unlock(server.io);
        return;
    };
    server.docs_mutex.unlock(server.io);
    defer gpa.free(open);
    {
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        for (open) |file| if (!server.single.contains(file)) compile.append(gpa, file) catch {};
    }
    for (compile.items) |file| server.compileSingle(file);
    // Files in unloaded projects: the hint was deferred until startup finished
    // and projects finished loading (see `appendUnloadedProjectHint`), and the
    // context may also have just changed to this one
    var unloaded: std.ArrayList(Vfs.FileId) = .empty;
    defer unloaded.deinit(gpa);
    for (open) |file| if (server.fileContext(file) == .unloaded_project) unloaded.append(gpa, file) catch {};
    server.publishFiles(unloaded.items, false);
}

/// Sequence number of a compile result: project builds and single-file compiles each take one when
/// storing a result; larger is newer
pub fn nextCompileGeneration(server: *Server) u64 {
    return server.compile_generation.fetchAdd(1, .monotonic) + 1;
}

/// Drops the compile result of the root file `file`, which is no longer on disk, and republishes
/// the files that have errors in that result (errors in files it imports are cleared too). Returns
/// whether a result was dropped (`file` has then been republished as well).
fn dropSingle(server: *Server, file: Vfs.FileId) bool {
    var affected: std.ArrayList(Vfs.FileId) = .empty;
    defer affected.deinit(server.gpa);
    {
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        const sf = server.single.getPtr(file) orelse return false;
        // An ongoing compile may have read the file before it was deleted: recompile when it
        // finishes (the file is no longer on disk, so the result is empty)
        if (sf.running) sf.rerun = true;
        if (sf.result == null) return false;
        affected.append(server.gpa, file) catch {};
        affected.appendSlice(server.gpa, sf.files.keys()) catch {};
        sf.clearResult(server.gpa);
    }
    server.publishFiles(affected.items, true);
    return true;
}

fn singleFileTask(server: *Server, file: Vfs.FileId) Io.Cancelable!void {
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
        const env = server.zigEnv().?;
        var inputs: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty;
        const result: ?*compiler.BuildResult = blk: {
            // The file has been deleted from disk (if deleted during a compile, `dropSingle`
            // requests a recompile): no result
            Io.Dir.cwd().access(server.io, path, .{}) catch break :blk null;
            var compiled = za.project.bsp.compileSingleFile(server.gpa, server.io, env, path) catch |err| {
                log.warn("{s}: single-file compile failed: {t}", .{ path, err });
                break :blk null;
            };
            defer compiled.deinit(server.gpa);
            errors = compiled.errors.errorMessageCount();
            for (compiled.inputs) |p| {
                const id = server.vfs.intern(p) catch continue;
                inputs.put(server.gpa, id, {}) catch continue;
            }
            break :blk compiler.collect(server.gpa, &.{compiled.errors}, std.fs.path.dirname(path) orelse ".", path, server, readDisk) catch null;
        };
        var files: std.AutoArrayHashMapUnmanaged(Vfs.FileId, *const compiler.FileResult) = .empty;
        if (result) |r| for (r.files.keys(), r.files.values()) |p, *fr| {
            const id = server.vfs.intern(p) catch continue;
            files.put(server.gpa, id, fr) catch continue;
        };
        // During the compile, the file may have stopped being a detached file (its project finished
        // loading, a build.zig was created in its root directory, etc.), or compiler diagnostics
        // may have been turned off: in either case this result is not used
        const detached = server.fileContext(file) == .detached and server.buildFlags().compiler;
        server.single_mutex.lockUncancelable(server.io);
        const sf = server.single.getPtr(file).?;
        if (detached and sf.rerun) {
            sf.rerun = false;
            server.single_mutex.unlock(server.io);
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
            _ = server.single.swapRemove(file);
        }
        server.single_mutex.unlock(server.io);
        server.publishFiles(affected.items, true);
        return;
    }
}

/// Recompiles single-file mode roots: `roots`, plus the roots whose last
/// compile read a file in `changed` or reported errors in one (e.g. a
/// root that imports the saved file). Each root is compiled only once.
fn recompileSingle(server: *Server, roots: []const Vfs.FileId, changed: []const Vfs.FileId) void {
    var list: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty;
    defer list.deinit(server.gpa);
    for (roots) |root| list.put(server.gpa, root, {}) catch return;
    {
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        for (server.single.keys(), server.single.values()) |root, *sf| {
            for (changed) |f| if (sf.inputs.contains(f) or sf.files.contains(f)) {
                list.put(server.gpa, root, {}) catch return;
                break;
            };
        }
    }
    for (list.keys()) |root| server.compileSingle(root);
}

fn readDisk(ctx: *anyopaque, gpa: Allocator, path: []const u8) ?[]u8 {
    const server: *Server = @ptrCast(@alignCast(ctx));
    return Io.Dir.cwd().readFileAlloc(server.io, path, gpa, .limited(Vfs.max_file_size)) catch null;
}

/// Starts the project for a root directory; does nothing if the root directory already has a
/// project (startup and workspace folder changes may happen concurrently). Does not start when the
/// user's zig differs from the version zig-analyzer was built with: the build graph format is
/// defined by the standard library and cannot be read. Such projects get only live diagnostics
/// (zig ast-check) and are not compiled in single-file mode (files that use named modules would
/// report missing modules).
fn startWorkspace(server: *Server, root: []const u8) void {
    if (server.isShuttingDown() or !server.buildFlags().build) return;
    if (server.zigEnv()) |env| if (!env.matchesBuiltin()) return;
    {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        for (server.workspaces.items) |w| if (std.mem.eql(u8, w.root, root)) return;
    }
    const ws = Workspace.start(server, root, 0) catch |err| {
        log.err("{s}: failed to start build system protocol: {t}", .{ root, err });
        return;
    };
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    // The list takes over the reference returned by `start`. If a project was started for the same
    // root directory meanwhile, or the list cannot grow, the new instance is discarded.
    const added = server.visibleFor(root) == null and
        (if (server.workspaces.append(server.gpa, ws)) |_| true else |_| false);
    if (!added) ws.stop();
    ws.placed.set(server.io);
    if (!added) ws.release();
}

/// Adds a workspace root directory (`uri` is the URI of the directory). Starts its project
/// immediately if the zig environment is ready; otherwise startup starts it.
fn addRoot(server: *Server, root_uri: []const u8) !void {
    const path = uri.toPath(server.gpa, root_uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer server.gpa.free(path);
    const normalized = try Vfs.normalize(.native, server.gpa, path) orelse return;
    var owned = true;
    defer if (owned) server.gpa.free(normalized);
    const has_build = try server.hasBuildZig(normalized);
    {
        server.roots_mutex.lockUncancelable(server.io);
        defer server.roots_mutex.unlock(server.io);
        for (server.roots.items) |r| if (std.mem.eql(u8, r, normalized)) return;
        try server.root_has_build.ensureUnusedCapacity(server.gpa, 1);
        try server.roots.append(server.gpa, normalized);
        server.root_has_build.appendAssumeCapacity(has_build);
        owned = false;
    }
    if (has_build and server.zigEnv() != null) server.startWorkspace(normalized);
}

/// Removes a workspace root directory: stops its project
/// and clears the compiler diagnostics it published
fn removeRoot(server: *Server, arena: Allocator, root_uri: []const u8) !void {
    const path = uri.toPath(arena, root_uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    const normalized = try Vfs.normalize(.native, arena, path) orelse return;
    {
        server.roots_mutex.lockUncancelable(server.io);
        defer server.roots_mutex.unlock(server.io);
        for (server.roots.items, 0..) |r, i| if (std.mem.eql(u8, r, normalized)) {
            server.gpa.free(server.roots.orderedRemove(i));
            _ = server.root_has_build.orderedRemove(i);
            break;
        };
    }
    server.removeProject(normalized);
}

/// Stops the project of root directory `root` and clears the compiler diagnostics it published
/// (the caller updates the module graph)
fn removeProject(server: *Server, root: []const u8) void {
    var removed: ?*Workspace = null;
    {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        // Take it out together with the reference held by the list
        for (server.workspaces.items, 0..) |w, i| if (std.mem.eql(u8, w.root, root)) {
            removed = server.workspaces.orderedRemove(i);
            break;
        };
    }
    const ws = removed orelse return;
    defer ws.release();
    server.stopProject(ws);
    ws.mutex.lockUncancelable(server.io);
    const stale = server.gpa.dupe(Vfs.FileId, ws.result_files.keys()) catch &.{};
    ws.mutex.unlock(server.io);
    defer server.gpa.free(stale);
    server.publishFiles(stale, true);
}

/// Workspace folders added or removed
fn didChangeWorkspaceFolders(server: *Server, arena: Allocator, params: types.DidChangeWorkspaceFoldersParams) !void {
    for (params.event.removed) |f| try server.removeRoot(arena, f.uri);
    for (params.event.added) |f| try server.addRoot(f.uri);
    server.updateModuleGraph();
    // Open files may move into or out of project directories and unloaded projects (the hint
    // appears or disappears accordingly)
    server.publishOpenFiles();
    server.reconcileSingle();
    server.resyncWatcher();
    // Before startup, the scan at the end of startup covers the new roots
    if (server.started) server.scheduleScan();
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
    ws.stop();
    {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        // The project has been removed
        const visible = server.visibleFor(ws.root) orelse return;
        visible.stop();
        if (visible.successor) |pending| pending.stop();
    }
    if (server.isShuttingDown()) return;
    const fresh = Workspace.start(server, ws.root, crash_restarts) catch |err| {
        log.err("{s}: failed to restart build system protocol: {t}", .{ ws.root, err });
        return;
    };
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    // The server began shutting down while the new instance was starting, or the project has been
    // removed: discard the new instance
    const visible = (if (server.shutting_down) null else server.visibleFor(ws.root)) orelse {
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
    const target = blk: {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        // The project has been removed
        const visible = server.visibleFor(ws.root) orelse return;
        const t = visible.successor orelse visible;
        t.acquire();
        break :blk t;
    };
    defer target.release();
    target.requestBuild();
}

/// The instance in the list for the project of root
/// directory `root`; the caller holds `workspaces_mutex`
fn visibleFor(server: *Server, root: []const u8) ?*Workspace {
    for (server.workspaces.items) |w| if (std.mem.eql(u8, w.root, root)) return w;
    return null;
}

/// Snapshot of the instances in the list (each with a reference held; release with `releaseList`)
fn workspaceList(server: *Server, a: Allocator) Allocator.Error![]*Workspace {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    const list = try a.dupe(*Workspace, server.workspaces.items);
    for (list) |ws| ws.acquire();
    return list;
}

fn releaseList(server: *Server, a: Allocator, list: []*Workspace) void {
    _ = server;
    for (list) |ws| ws.release();
    a.free(list);
}

fn stopWorkspaces(server: *Server) void {
    {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        server.shutting_down = true;
        for (server.workspaces.items) |ws| {
            ws.stop();
            if (ws.successor) |s| s.stop();
        }
    }
    if (server.watcher) |w| w.stop();
}

pub fn isShuttingDown(server: *Server) bool {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    return server.shutting_down;
}

pub fn zigEnv(server: *Server) ?*const ZigEnv {
    server.env_mutex.lockUncancelable(server.io);
    defer server.env_mutex.unlock(server.io);
    return server.zig_env;
}

/// Unknown entries and entries of the wrong type in the configuration: combined into one warning.
/// Shows the problems in the configuration as one combined warning;
/// `source` is where the configuration comes from (the client's
/// configuration or the path of a project configuration file).
pub fn reportConfigWarnings(server: *Server, source: []const u8, config: *const Config) void {
    if (config.warnings.len == 0) return;
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{s}: ", .{source}) catch {};
    for (config.warnings, 0..) |msg, i| w.print("{s}{s}", .{ if (i > 0) "; " else "", msg }) catch break;
    server.showWarning(w.buffered());
}

pub fn showWarning(server: *Server, message: []const u8) void {
    // Already shown to the user: the log is only a record
    log.info("shown to the user: {s}", .{message});
    server.sendNotification("window/showMessage", types.ShowMessageParams{ .type = .Warning, .message = message });
}

pub fn showWarningOnce(server: *Server, message: []const u8) void {
    server.env_mutex.lockUncancelable(server.io);
    const first = !server.warned;
    server.warned = true;
    server.env_mutex.unlock(server.io);
    if (first) server.showWarning(message);
}

pub fn busyBegin(server: *Server) void {
    server.busy_mutex.lockUncancelable(server.io);
    defer server.busy_mutex.unlock(server.io);
    server.busy += 1;
}

pub fn busyEnd(server: *Server) void {
    server.busy_mutex.lockUncancelable(server.io);
    defer server.busy_mutex.unlock(server.io);
    server.busy -= 1;
    if (server.busy == 0) server.busy_cond.broadcast(server.io);
}

/// Waits for all background tasks (builds, compile
/// set computation, diagnostics publishing) to finish
fn waitIdle(server: *Server) void {
    server.busy_mutex.lockUncancelable(server.io);
    defer server.busy_mutex.unlock(server.io);
    while (server.busy != 0) server.busy_cond.waitUncancelable(server.io, &server.busy_mutex);
}

fn waitIdleRequest(server: *Server, _: Allocator, _: void) HandlerError!void {
    server.waitIdle();
}

// ── Publishing diagnostics ─────────────────────────────────────

/// Concurrency limit for publishing each batch: large batches of changes (watcher, build errors)
/// must not create a task and a read transaction per file
pub const max_publish_workers = 8;

/// When `tracked`, the file's state is recorded in `publish_files`,
/// and `clear` and `always` are taken from there when the job starts; when the state
/// cannot be recorded (allocation failure), requests are not coalesced
const PublishJob = struct { file: Vfs.FileId, clear: bool = false, always: bool = true, tracked: bool = true };

const PublishState = struct {
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
    server.enqueuePublish(files, clear, true);
}

/// Open files other than `changed`, whose text has just changed: their diagnostics may depend on
/// that text (notes and reference traces located in it, inactive code whose conditions read it,
/// naming hints that depend on its declarations), so they are recomputed. Most of them do not
/// depend on it: a result is sent only when it differs from the last one sent for the file.
fn publishDependents(server: *Server, changed: []const Vfs.FileId) void {
    var files: std.ArrayList(Vfs.FileId) = .empty;
    defer files.deinit(server.gpa);
    {
        server.docs_mutex.lockUncancelable(server.io);
        defer server.docs_mutex.unlock(server.io);
        for (server.open_docs.keys()) |file| {
            if (std.mem.indexOfScalar(Vfs.FileId, changed, file) != null) continue;
            files.append(server.gpa, file) catch return log.err("out of memory while publishing diagnostics", .{});
        }
    }
    server.enqueuePublish(files.items, false, false);
}

/// See `publishFiles`; when `always` is false, the result is not sent when it is the same as the
/// last one sent for the file
fn enqueuePublish(server: *Server, files: []const Vfs.FileId, clear: bool, always: bool) void {
    if (files.len == 0) return;
    var spawn_count: usize = 0;
    {
        server.publish_queue_mutex.lockUncancelable(server.io);
        defer server.publish_queue_mutex.unlock(server.io);
        for (files) |file| {
            const gop = server.publish_files.getOrPut(server.gpa, file) catch {
                server.publish_queue.append(server.gpa, .{ .file = file, .clear = clear, .always = always, .tracked = false }) catch {};
                continue;
            };
            if (gop.found_existing) {
                gop.value_ptr.clear = gop.value_ptr.clear or clear;
                gop.value_ptr.always = gop.value_ptr.always or always;
                if (!gop.value_ptr.queued) gop.value_ptr.again = true;
                continue;
            }
            gop.value_ptr.* = .{ .clear = clear, .always = always };
            server.publish_queue.append(server.gpa, .{ .file = file }) catch {
                _ = server.publish_files.remove(file);
            };
        }
        if (server.publish_workers < max_publish_workers and server.publish_queue.items.len != 0) {
            spawn_count = @min(max_publish_workers - server.publish_workers, server.publish_queue.items.len);
            server.publish_workers += spawn_count;
        }
    }
    for (0..spawn_count) |_| {
        server.busyBegin();
        spawn(server.io, &server.bg_group, publishWorker, .{server});
    }
}

fn publishWorker(server: *Server) Io.Cancelable!void {
    defer server.busyEnd();
    var counted = true;
    defer if (counted) {
        server.publish_queue_mutex.lockUncancelable(server.io);
        server.publish_workers -= 1;
        server.publish_queue_mutex.unlock(server.io);
    };
    while (true) {
        const job = blk: {
            server.publish_queue_mutex.lockUncancelable(server.io);
            defer server.publish_queue_mutex.unlock(server.io);
            if (server.publish_queue.items.len == 0) {
                // Under the same lock as enqueuing: decrement the count before exiting, so that an
                // enqueuer does not see the worker still present and skip spawning a new task
                server.publish_workers -= 1;
                counted = false;
                return;
            }
            var job = server.publish_queue.swapRemove(0);
            if (job.tracked) {
                const state = server.publish_files.getPtr(job.file).?;
                state.queued = false;
                job.clear = state.clear;
                state.clear = false;
                job.always = state.always;
                state.always = false;
            }
            break :blk job;
        };
        server.publishNow(job.file, job.clear, job.always, null);
        if (job.tracked) server.publishDone(job.file);
        server.maybeResetSema();
    }
}

/// A publish finished: requeues the file if requests arrived during the computation (handled by a
/// worker that is still running)
fn publishDone(server: *Server, file: Vfs.FileId) void {
    server.publish_queue_mutex.lockUncancelable(server.io);
    defer server.publish_queue_mutex.unlock(server.io);
    const state = server.publish_files.getPtr(file).?;
    if (!state.again) {
        _ = server.publish_files.remove(file);
        return;
    }
    state.again = false;
    state.queued = true;
    server.publish_queue.append(server.gpa, .{ .file = file }) catch {
        _ = server.publish_files.remove(file);
    };
}

pub fn publishOpenFiles(server: *Server) void {
    server.docs_mutex.lockUncancelable(server.io);
    const files = server.gpa.dupe(Vfs.FileId, server.open_docs.keys()) catch {
        server.docs_mutex.unlock(server.io);
        return;
    };
    server.docs_mutex.unlock(server.io);
    defer server.gpa.free(files);
    server.publishFiles(files, false);
}

/// Edit generation of a file, and whether a publish task is already waiting
const Edit = struct { generation: u64 = 0, scheduled: bool = false };

/// Publishing triggered by edits: at most one waiting task per file, which computes only when there
/// has been no new edit for `diagnostics.debounce_ms`. While typing, diagnostics (AstGen and
/// inference of inactive code) are not computed for every keystroke, and tasks repeatedly
/// interrupted by write transactions do not pile up.
fn publishDebounced(server: *Server, file: Vfs.FileId) void {
    {
        server.edits_mutex.lockUncancelable(server.io);
        defer server.edits_mutex.unlock(server.io);
        const gop = server.edits.getOrPut(server.gpa, file) catch return server.publishFiles(&.{file}, false);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.generation += 1;
        if (gop.value_ptr.scheduled) return;
        gop.value_ptr.scheduled = true;
    }
    // Spawned outside the lock: when falling back to `async`, the task runs synchronously here and
    // acquires `edits_mutex` again
    server.busyBegin();
    spawn(server.io, &server.bg_group, debounceTask, .{ server, file });
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
        const ms = server.debounce_ms.load(.monotonic);
        if (ms > 0) try (Io.Clock.Duration{ .raw = .fromMilliseconds(ms), .clock = .awake }).sleep(server.io);
    }
    server.publishNow(file, false, true, seen);
    server.publishDependents(&.{file});
    if (server.openDocumentCount() > 1) server.requestRefresh();
    server.refreshCompileSets(&.{file});
    server.maybeResetSema();
}

/// The text of these files has changed: each project whose compile set read their imports
/// recomputes it if the imports differ (see `Workspace.refreshImports`)
fn refreshCompileSets(server: *Server, files: []const Vfs.FileId) void {
    const list = server.workspaceList(server.gpa) catch return log.err("out of memory while updating compile sets", .{});
    defer server.releaseList(server.gpa, list);
    for (list) |ws| ws.refreshImports(files) catch log.err("{s}: out of memory while updating the compile set", .{ws.root});
}

/// `refreshCompileSets` in a background task: a recompute can take a while in a large project
fn scheduleCompileSetRefresh(server: *Server, files: []const Vfs.FileId) void {
    const owned = server.gpa.dupe(Vfs.FileId, files) catch return log.err("out of memory while updating compile sets", .{});
    server.busyBegin();
    spawn(server.io, &server.bg_group, compileSetRefreshTask, .{ server, owned });
}

fn compileSetRefreshTask(server: *Server, files: []const Vfs.FileId) Io.Cancelable!void {
    defer server.busyEnd();
    defer server.gpa.free(files);
    server.refreshCompileSets(files);
}

fn editGeneration(server: *Server, file: Vfs.FileId) u64 {
    server.edits_mutex.lockUncancelable(server.io);
    defer server.edits_mutex.unlock(server.io);
    return if (server.edits.get(file)) |e| e.generation else 0;
}

/// Reclaims type information (see `resetSema`) when the InternPool exceeds
/// `sema.max_intern_pool_mb` or the type-information queries have more than `sema_reset_keys`
/// keys. Called when a request or a diagnostics publish finishes, outside read transactions.
fn maybeResetSema(server: *Server) void {
    const limit = server.max_intern_pool_mb.load(.monotonic);
    if (limit == 0) return;
    const limit_bytes = @as(usize, limit) * 1024 * 1024;
    if (server.ip.bytes() < limit_bytes and server.semaKeys() < sema_reset_keys) return;
    if (!server.db.tryBeginWrite()) return;
    defer server.db.endWrite();
    // Another thread may have reclaimed since the check above
    if (server.ip.bytes() < limit_bytes and server.semaKeysLocked() < sema_reset_keys) return;
    server.resetSemaLocked();
}

/// When the total number of keys of the type-information queries exceeds this value, the whole
/// generation is reclaimed as well: keys and dependency edges are not freed by eviction and keep
/// growing in long sessions with the members and instances visited (about 250,000 after 40 rounds
/// over the Zig compiler source, tens of MB including the dependency edges)
const sema_reset_keys = 200_000;

/// Queries cleared by a whole-generation reclaim
const sema_queries = .{ database.sema.Infer, database.sema.LocalValue, database.sema.DeclType, database.sema.CallEval, database.sema.ComptimeOnly, database.sema.ErrorSetOf, database.sema.InactiveRanges, database.sema.ZonValue, database.sema.ZonResultType, database.ide_db.seed.Query, database.ide_db.seed.Instances, database.ide_db.seed.AllInstances, database.ide_db.seed.RootCallers, database.ide_db.seed.CallsIn };

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
    server.resetSemaLocked();
    return true;
}

/// `resetSema` in a write transaction the caller holds
fn resetSemaLocked(server: *Server) void {
    const before = server.ip.bytes();
    const keys = server.semaKeysLocked();
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
    if (isVirtual(server.vfs.path(file))) {
        server.docs_mutex.lockUncancelable(server.io);
        const wanted = server.open_docs.contains(file) or server.last_uris.contains(file);
        server.docs_mutex.unlock(server.io);
        if (!wanted) return;
    }
    // Retry when canceled by a write transaction: a publish triggered by a build result must not be
    // lost because of an unrelated edit
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        if (generation) |g| if (server.editGeneration(file) != g) return;
        server.prepareLive(file);
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        var ctx = server.db.beginRead(arena);
        // Another edit came in after preparing: prepare again outside the lock instead of running
        // AstGen inside the read transaction (while typing, AstGen may be slower than keystrokes)
        const ready = server.liveReady(&ctx, file) catch false;
        if (!ready) {
            ctx.end();
            continue;
        }
        // Take the sequence number before reading state
        // such as compile results (see `sendDiagnostics`)
        const seq = server.publish_seq.fetchAdd(1, .acq_rel);
        const params = server.computeDiagnostics(&ctx, arena, file) catch |err| {
            ctx.end();
            switch (err) {
                error.Canceled => continue,
                error.OutOfMemory => return log.err("out of memory while computing diagnostics", .{}),
            }
        };
        // If the computation swallowed `Canceled`, the result is incomplete: retry as well
        const canceled = if (ctx.checkCanceled()) |_| false else |_| true;
        ctx.end();
        if (canceled) continue;
        server.sendDiagnostics(file, params, clear, always, seq);
        return;
    }
}

/// Runs AstGen on the file's current text outside any read transaction (see `live.Prepared`):
/// AstGen does not check for cancellation, so if it ran inside a read transaction, write
/// transactions would have to wait for it to finish. A read transaction is held briefly, only to
/// read the text. Any failure just falls back to computing in the query.
fn prepareLive(server: *Server, file: Vfs.FileId) void {
    if (!server.liveEligible(file)) return;
    var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text, const backend = blk: {
        var ctx = server.db.beginRead(a);
        defer ctx.end();
        const backend: live.Backend = switch (ctx.get(live.LiveBackend, {}) catch return) {
            .in_process => .in_process,
            .subprocess => |exe| .{ .subprocess = a.dupe(u8, exe) catch return },
        };
        const t = (ctx.get(FileText, file) catch return) orelse return;
        break :blk .{ a.dupe(u8, t) catch return, backend };
    };
    const mode = live.modeOf(server.vfs.path(file));
    if (!server.live_prepared.claim(server.io, file, live.Prepared.hash(text, mode, backend))) return;
    const result = live.checkWith(server.gpa, server.io, backend, text, mode) catch return;
    server.live_prepared.put(server.io, file, text, mode, backend, result) catch {};
}

/// The live diagnostics of the current text have already been prepared outside a read transaction
/// (or need no preparation)
fn liveReady(server: *Server, ctx: *Db.Ctx, file: Vfs.FileId) !bool {
    if (!server.liveEligible(file)) return true;
    const backend = try ctx.get(live.LiveBackend, {});
    const text = try ctx.get(FileText, file) orelse return true;
    return server.live_prepared.prepared(server.io, file, live.Prepared.hash(text, live.modeOf(server.vfs.path(file)), backend));
}

/// Sends the diagnostics computed with sequence number `seq`, dropping them if a result
/// with a larger number has already been sent. Several publish tasks for the same file
/// compute concurrently, and one that started earlier may finish later. Every state
/// change is followed by a new publish: it takes its number after the change, which is
/// larger than those of all computations that took theirs before the change, and it
/// reads the state after the change. So when only results whose number is no smaller
/// than the one already sent are sent, the last result sent has read the state after
/// the last change. Comparing and writing both happen inside publish_mutex, so the
/// order of writes matches the comparisons; serialization happens outside the lock.
/// `clear`: sent even when empty for a file that is not showing diagnostics; `always`: sent even
/// when it is the same as the last result sent for the file.
fn sendDiagnostics(server: *Server, file: Vfs.FileId, params: types.PublishDiagnosticsParams, clear: bool, always: bool, seq: u64) void {
    const bytes = jsonrpc.notification(server.gpa, "textDocument/publishDiagnostics", params) catch return log.err("out of memory while building notification", .{});
    var sent = false;
    defer if (!sent) server.gpa.free(bytes);
    const hash = std.hash.Wyhash.hash(0, bytes);
    server.publish_mutex.lockUncancelable(server.io);
    defer server.publish_mutex.unlock(server.io);
    if (server.sent_seq.getOrPut(server.gpa, file)) |gop| {
        if (gop.found_existing and gop.value_ptr.* > seq) return;
        gop.value_ptr.* = seq;
    } else |_| {}
    if (!always) if (server.sent_hash.get(file)) |last| if (last == hash) return;
    {
        server.docs_mutex.lockUncancelable(server.io);
        defer server.docs_mutex.unlock(server.io);
        const was_published = server.published.contains(file);
        if (params.diagnostics.len == 0) {
            // A file that never had diagnostics shown needs no empty list (except open files: the
            // client may still be showing old results)
            if (!was_published and !clear and !server.open_docs.contains(file)) return;
            _ = server.published.swapRemove(file);
        } else {
            server.published.put(server.gpa, file, {}) catch {};
        }
    }
    sent = true;
    server.sent_hash.put(server.gpa, file, hash) catch {
        _ = server.sent_hash.remove(file);
    };
    server.send(bytes);
    // The clearing for the virtual document has been sent: its URI is no longer needed
    if (isVirtual(server.vfs.path(file))) {
        server.docs_mutex.lockUncancelable(server.io);
        defer server.docs_mutex.unlock(server.io);
        if (!server.open_docs.contains(file)) if (server.last_uris.fetchSwapRemove(file)) |kv| server.gpa.free(kv.value);
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
    server.sendDiagnostics(a, .{ .uri = "file:///a.zig", .diagnostics = &.{} }, true, true, 2);
    server.sendDiagnostics(a, .{ .uri = "file:///a.zig", .diagnostics = &.{stale} }, true, true, 1);
    server.sendDiagnostics(b, .{ .uri = "file:///b.zig", .diagnostics = &.{stale} }, true, true, 0);
    server.sendDiagnostics(a, .{ .uri = "file:///a.zig", .diagnostics = &.{stale} }, true, true, 3);
    // A republish of a file for a change in another file is sent only when its result differs
    server.sendDiagnostics(a, .{ .uri = "file:///a.zig", .diagnostics = &.{stale} }, false, false, 4);
    server.sendDiagnostics(a, .{ .uri = "file:///a.zig", .diagnostics = &.{} }, false, false, 5);
    server.sendDiagnostics(a, .{ .uri = "file:///a.zig", .diagnostics = &.{} }, true, true, 6);

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
        try server.db.set(FileText, file.*, try gpa.dupe(u8, text), .low);
    }
    server.publishFiles(files, true);
    {
        server.publish_queue_mutex.lockUncancelable(server.io);
        defer server.publish_queue_mutex.unlock(server.io);
        try std.testing.expect(server.publish_workers <= max_publish_workers);
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
        try server.db.set(FileText, file, try gpa.dupe(u8, "fn f() void {\n    var x = 1;\n}\n"), .low);
    }
    const before = server.publish_seq.load(.monotonic);
    // During the write transaction, publish tasks stop before their read transactions: all later
    // requests arrive while the first publish is queued or computing
    server.db.beginWrite();
    for (0..10) |_| server.publishFiles(&.{file}, true);
    server.db.endWrite();
    server.waitIdle();
    // Queued requests are coalesced, and requests that arrive after computation starts are combined
    // into one run after it finishes
    const computed = server.publish_seq.load(.monotonic) - before;
    try std.testing.expect(computed >= 1 and computed <= 2);
    try std.testing.expectEqual(0, server.publish_files.count());
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
        if (server.updateModuleGraphInner()) |_| {
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
    server.default_builtin = try failing.allocator().dupe(u8, "/zig-analyzer-test/builtin.zig");
    fail_index = 0;
    while (true) : (fail_index += 1) {
        try std.testing.expect(fail_index < 10_000);
        failing.alloc_index = 0;
        failing.resize_index = 0;
        failing.has_induced_failure = false;
        failing.fail_index = fail_index;
        if (server.updateModuleGraphInner()) |_| {
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
    try server.updateModuleGraphInner();
    const writes = server.db.writes.load(.monotonic);
    // The module graph is updated after every build: opening a write transaction when nothing
    // changed would cancel in-flight computations and requests
    try server.updateModuleGraphInner();
    try std.testing.expectEqual(writes, server.db.writes.load(.monotonic));
    server.default_builtin = try std.testing.allocator.dupe(u8, "/zig-analyzer-test/builtin.zig");
    try server.updateModuleGraphInner();
    try std.testing.expectEqual(writes + 1, server.db.writes.load(.monotonic));
}

/// Whether to publish live diagnostics for the file: it belongs to no project, or one of the
/// projects it belongs to wants them (see `Workspace.liveEligible`)
fn liveEligible(server: *Server, file: Vfs.FileId) bool {
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

fn uriFor(server: *Server, arena: Allocator, file: Vfs.FileId) Allocator.Error![]const u8 {
    server.docs_mutex.lockUncancelable(server.io);
    defer server.docs_mutex.unlock(server.io);
    if (server.open_docs.get(file)) |u| return arena.dupe(u8, u);
    if (server.last_uris.get(file)) |u| return arena.dupe(u8, u);
    return uri.fromPath(arena, server.vfs.path(file));
}

const OtherFiles = struct {
    server: *Server,
    ctx: *Db.Ctx,
    /// Compile results in use, each with a reference held (released by `release`): they are not
    /// freed by being replaced with newer results before the diagnostics are computed (the notes
    /// of their errors also refer to the texts they hold)
    builds: std.ArrayList(*compiler.BuildResult) = .empty,

    fn get(opaque_ctx: *anyopaque, arena: Allocator, path: []const u8) ?compiler.OtherFile {
        const self: *OtherFiles = @ptrCast(@alignCast(opaque_ctx));
        const file = self.server.vfs.lookup(path) catch return null;
        const loaded: ?[]const u8 = if (file) |f| (self.ctx.get(FileText, f) catch null) orelse null else null;
        const text = loaded orelse Io.Dir.cwd().readFileAlloc(self.server.io, path, arena, .limited(Vfs.max_file_size)) catch return null;
        const u = if (file) |f| self.server.uriFor(arena, f) catch return null else uri.fromPath(arena, path) catch return null;
        return .{ .uri = u, .text = text };
    }

    /// Takes `fr` from the compile result `build` (called while holding the lock that protects
    /// `build`)
    fn use(self: *OtherFiles, arena: Allocator, fr: *const compiler.FileResult, build: *compiler.BuildResult) Allocator.Error!*const compiler.FileResult {
        try self.builds.ensureUnusedCapacity(arena, 1);
        self.builds.appendAssumeCapacity(build.retain());
        return fr;
    }

    fn release(self: *OtherFiles) void {
        for (self.builds.items) |b| b.release(self.server.gpa);
        self.builds.clearRetainingCapacity();
    }
};

/// Compiler diagnostics of `file`: the results of the latest build of each project
/// that contains it; whether single-file compile results are used depends on the
/// file's context (see `FileContext.usesSingle`). Multiple results are merged with
/// `compiler.combine`, taking the text read by the newest compile as authoritative.
/// A reference to each result is taken under its lock and recorded in `other`; no lock is held
/// while merging.
fn compilerResult(server: *Server, arena: Allocator, file: Vfs.FileId, other: *OtherFiles) Allocator.Error!?*const compiler.FileResult {
    const Found = struct {
        generation: u64,
        result: *const compiler.FileResult,

        fn newer(_: void, a: @This(), b: @This()) bool {
            return a.generation > b.generation;
        }
    };
    var found: std.ArrayList(Found) = .empty;
    {
        const list = try server.workspaceList(arena);
        defer server.releaseList(arena, list);
        for (list) |ws| {
            ws.mutex.lockUncancelable(server.io);
            defer ws.mutex.unlock(server.io);
            const fr = ws.result_files.get(file) orelse continue;
            const build = ws.result orelse {
                _ = never(true, @src(), "workspace has result files without a result");
                continue;
            };
            try found.append(arena, .{ .generation = ws.result_generation, .result = try other.use(arena, fr, build) });
        }
    }
    if (server.fileContext(file).usesSingle()) {
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        for (server.single.values()) |*sf| if (sf.files.get(file)) |fr| {
            const build = sf.result orelse {
                _ = never(true, @src(), "single-file root has result files without a result");
                continue;
            };
            try found.append(arena, .{ .generation = sf.generation, .result = try other.use(arena, fr, build) });
        };
    }
    switch (found.items.len) {
        0 => return null,
        1 => return found.items[0].result,
        else => {},
    }
    std.mem.sort(Found, found.items, {}, Found.newer);
    const results = try arena.alloc(*const compiler.FileResult, found.items.len);
    for (found.items, results) |f, *r| r.* = f.result;
    const combined = try arena.create(compiler.FileResult);
    combined.* = try compiler.combine(arena, results);
    return combined;
}

fn computeDiagnostics(server: *Server, ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId) !types.PublishDiagnosticsParams {
    const document_uri = try server.uriFor(arena, file);
    const text = try ctx.get(FileText, file);

    // Live diagnostics: the file is loaded, and it belongs to no project or one of its projects
    // wants them (see `Workspace.liveEligible`)
    var live_result: ?*live.Result = null;
    if (text != null and server.liveEligible(file)) live_result = try ctx.get(live.AstCheck, file);

    // Compiler diagnostics: errors in an imported file are
    // reported by the project or root file that compiles it
    var other: OtherFiles = .{ .server = server, .ctx = ctx };
    defer other.release();
    const fr = try server.compilerResult(arena, file, &other);
    const current = text orelse if (fr) |r| r.base_text else "";
    var diags = try compiler.merge(arena, .{
        .text = current,
        .lines = try offsets.LineIndex.init(arena, current),
        .encoding = server.encoding,
        .uri = document_uri,
        .live = live_result,
        .compiler = fr,
        .other_file = OtherFiles.get,
        .other_ctx = &other,
    });
    if (text) |t| if (server.wantsInactiveCode(file)) {
        diags = try server.appendInactiveCode(ctx, arena, file, t, diags);
    };
    if (text) |t| if (try server.namingFor(arena, file, t)) |settings| {
        diags = try server.appendNaming(ctx, arena, file, t, settings, diags);
    };
    if (text) |t| diags = try server.appendUnloadedProjectHint(arena, file, t, diags);
    return .{ .uri = document_uri, .diagnostics = diags };
}

test "computeDiagnostics: notes of combined results keep the coordinates of their own build" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var writer: transport.Writer = .{ .io = io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(io, gpa, &writer);
    defer server.deinit();

    const old_util =
        \\pub fn bad() u32 {
        \\    return helper(1, 2);
        \\} // end bad
        \\fn helper(x: u32) u32 {
        \\    return x;
        \\} // end helper
        \\
    ;
    const new_util = "// one\n// two\n// three\n" ++ old_util;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "util.zig", .data = new_util });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const util_path = try std.fs.path.join(arena, &.{ dir, "util.zig" });

    const Disk = struct {
        text: []const u8,
        fn read(ctx: *anyopaque, a: Allocator, _: []const u8) ?[]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return a.dupe(u8, self.text) catch null;
        }
    };
    const Build = struct {
        /// A compile of a root importing util.zig that read `text` as util.zig
        fn result(path: []const u8, text: []const u8) !*compiler.BuildResult {
            var wip: std.zig.ErrorBundle.Wip = try .init(gpa);
            defer wip.deinit();
            const call: u32 = @intCast(std.mem.indexOf(u8, text, "helper(1, 2)").?);
            const decl: u32 = @intCast(std.mem.indexOf(u8, text, "fn helper(x: u32) u32").?);
            const src_path = try wip.addString(path);
            try wip.addRootErrorMessageWithNotes(.{
                .msg = try wip.addString("expected 1 argument(s), found 2"),
                .src_loc = try wip.addSourceLocation(.{ .src_path = src_path, .line = 0, .column = 0, .span_start = call, .span_main = call, .span_end = call + 12 }),
                .notes_len = 1,
            }, &.{.{
                .msg = try wip.addString("function declared here"),
                .src_loc = try wip.addSourceLocation(.{ .src_path = src_path, .line = 0, .column = 0, .span_start = decl, .span_main = decl, .span_end = decl + 21 }),
            }});
            var eb = try wip.toOwnedBundle("");
            defer eb.deinit(gpa);
            var disk: Disk = .{ .text = text };
            return compiler.collect(gpa, &.{eb}, std.fs.path.dirname(path).?, path, &disk, Disk.read);
        }
    };
    const util = try server.vfs.intern(util_path);
    // The root opened first is still compiling the older text when the other root's compile of
    // the saved text finishes: the older result is iterated first
    for ([_][]const u8{ "b.zig", "a.zig" }, [_][]const u8{ old_util, new_util }, 1..) |root, text, generation| {
        const result = try Build.result(util_path, text);
        const gop = try server.single.getOrPut(gpa, try server.vfs.intern(try std.fs.path.join(arena, &.{ dir, root })));
        gop.value_ptr.* = .{ .result = result, .generation = generation };
        try gop.value_ptr.files.put(gpa, util, result.files.getPtr(util_path).?);
    }

    var ctx = server.db.beginRead(arena);
    defer ctx.end();
    const params = try server.computeDiagnostics(&ctx, arena, util);
    try std.testing.expectEqual(1, params.diagnostics.len);
    const related = params.diagnostics[0].relatedInformation.?;
    try std.testing.expectEqual(1, related.len);
    // Guards against shifting the newest build's notes with the older build's text of the file,
    // which moved them by the length of the inserted lines a second time
    try std.testing.expectEqual(6, related[0].location.range.start.line);
    try std.testing.expectEqual(0, related[0].location.range.start.character);
    try std.testing.expectEqual(6, related[0].location.range.end.line);
    try std.testing.expectEqual(21, related[0].location.range.end.character);
}

/// An open file that belongs to a project that is not loaded (see `FileContext.unloaded_project`):
/// a hint to add the project directory to the workspace. Like rust-analyzer's hint for files that
/// belong to no crate, it is a Hint marking only the first few characters of the file. No hint
/// before startup finishes or while projects are loading for the first time: the file may later
/// show up in a project's module graph (modules added by path).
fn appendUnloadedProjectHint(server: *Server, arena: Allocator, file: Vfs.FileId, text: []const u8, diags: []const types.Diagnostic) ![]const types.Diagnostic {
    const path = server.vfs.path(file);
    if (!server.isOpen(path) or !server.startup_done.load(.acquire) or server.projectsLoading()) return diags;
    if (server.fileContext(file) != .unloaded_project) return diags;
    const dir = server.projectDirOf(path) orelse return diags;
    var end: usize = 0;
    var chars: usize = 0;
    while (chars < 3 and end < text.len and text[end] != '\n' and text[end] != '\r') : (chars += 1) {
        end += std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
    }
    const lines = try offsets.LineIndex.init(arena, text);
    const out = try arena.alloc(types.Diagnostic, diags.len + 1);
    @memcpy(out[0..diags.len], diags);
    out[diags.len] = .{
        .range = lines.range(0, @intCast(@min(end, text.len)), server.encoding),
        .severity = .Hint,
        .source = "zig-analyzer",
        .message = .{ .string = try std.fmt.allocPrint(arena, "this file belongs to the project at {s}, which is not loaded: it is not compiled on its own, " ++
            "since only the project's build can resolve its imports by name; add the directory to the workspace folders to load the project", .{dir}) },
    };
    return out;
}

/// Inactive code is shown only for open files: it requires inferring all members of the file
fn wantsInactiveCode(server: *Server, file: Vfs.FileId) bool {
    {
        server.config_mutex.lockUncancelable(server.io);
        defer server.config_mutex.unlock(server.io);
        if (!server.config.inactive_code) return false;
    }
    server.docs_mutex.lockUncancelable(server.io);
    defer server.docs_mutex.unlock(server.io);
    return server.open_docs.contains(file);
}

/// Code that is not compiled under the current build configuration (branches known at comptime not
/// to execute): hints tagged `Unnecessary`, which editors show faded
fn appendInactiveCode(server: *Server, ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId, text: []const u8, diags: []const types.Diagnostic) ![]const types.Diagnostic {
    var r: Resolver = .{ .ctx = ctx, .arena = arena };
    const ranges = try za.ide.inactive.ranges(&r, file);
    if (ranges.len == 0) return diags;
    const lines = try offsets.LineIndex.init(arena, text);
    const out = try arena.alloc(types.Diagnostic, diags.len + ranges.len);
    @memcpy(out[0..diags.len], diags);
    var n = diags.len;
    for (ranges) |x| {
        // Inference may mark as inactive code in which the compile behind the diagnostics reports
        // errors (AstGen checks every branch, and a file can be compiled in several
        // configurations): no hint is published where it overlaps a compiler diagnostic, so that
        // the same code is not both an error and inactive
        if (conflictsWithCompilerError(diags, text, server.encoding, x)) continue;
        out[n] = .{
            .range = lines.range(x.start, x.end, server.encoding),
            .severity = .Hint,
            .source = "zig-analyzer",
            .message = .{ .string = "code is inactive: a comptime condition excludes it under the current build configuration" },
            .tags = &.{.Unnecessary},
        };
        n += 1;
    }
    return out[0..n];
}

fn conflictsWithCompilerError(diags: []const types.Diagnostic, text: []const u8, enc: offsets.Encoding, range: za.ide.inactive.Range) bool {
    for (diags) |d| {
        const source = d.source orelse continue;
        if (!std.mem.eql(u8, source, "zig")) continue;
        const start: u32 = @intCast(offsets.positionToOffset(text, d.range.start, enc));
        const end: u32 = @intCast(offsets.positionToOffset(text, d.range.end, enc));
        if (range.start < end and start < range.end) return true;
    }
    return false;
}

/// Naming check settings for one file: the client's configuration, overridden by the entries
/// present in the `zig-analyzer.zon` of the project containing the file
const NamingSettings = struct {
    ignore: []const []const u8,
    rules: Config.NamingRules,

    fn allows(s: NamingSettings, f: ide.naming.Located) bool {
        const enabled = switch (f.rule) {
            inline else => |rule| @field(s.rules, @tagName(rule)),
        };
        if (!enabled) return false;
        for (s.ignore) |pattern| if (ide.naming.globMatch(pattern, f.name)) return false;
        return true;
    }
};

/// Whether the file gets naming checks, and their settings: open user code (see
/// `origin.Origin.user` and `origin.Origin.outside`) with the check enabled, not in
/// `naming.exclude`, and not generated code (see `naming.isGenerated`)
fn namingFor(server: *Server, arena: Allocator, file: Vfs.FileId, text: []const u8) Allocator.Error!?NamingSettings {
    {
        server.docs_mutex.lockUncancelable(server.io);
        defer server.docs_mutex.unlock(server.io);
        if (!server.open_docs.contains(file)) return null;
    }
    const path = server.vfs.path(file);
    var enable: bool = undefined;
    var ignore: []const []const u8 = undefined;
    var exclude: []const []const u8 = undefined;
    var rules: Config.NamingRules = undefined;
    {
        server.config_mutex.lockUncancelable(server.io);
        defer server.config_mutex.unlock(server.io);
        enable = server.config.naming_enable;
        ignore = try dupeStrings(arena, server.config.naming_ignore);
        exclude = try dupeStrings(arena, server.config.naming_exclude);
        rules = server.config.naming_rules;
    }
    // `naming.exclude` paths are relative to the workspace root directory, or to the project root
    // directory when they come from `zig-analyzer.zon`
    var base = try server.rootOf(arena, path);
    {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        // For nested projects, take the innermost one
        var best: ?*Workspace = null;
        for (server.workspaces.items) |ws| {
            if (server.vfs.isUnder(path, ws.root) and (best == null or ws.root.len > best.?.root.len)) best = ws;
        }
        if (best) |ws| if (ws.project) |*p| {
            if (p.isSet("naming_enable")) enable = p.naming_enable;
            if (p.isSet("naming_ignore")) ignore = try dupeStrings(arena, p.naming_ignore);
            if (p.isSet("naming_rules")) rules = p.naming_rules;
            if (p.isSet("naming_exclude")) {
                exclude = try dupeStrings(arena, p.naming_exclude);
                base = try arena.dupe(u8, ws.root);
            }
        };
    }
    if (!enable) return null;
    if (exclude.len != 0) {
        var rel = path;
        if (base) |b| if (b.len < path.len) {
            rel = path[b.len..];
            while (rel.len > 0 and (rel[0] == '/' or rel[0] == '\\')) rel = rel[1..];
        };
        const normalized = try arena.dupe(u8, rel);
        std.mem.replaceScalar(u8, normalized, '\\', '/');
        for (exclude) |pattern| if (ide.naming.globMatch(pattern, normalized)) return null;
    }
    switch (server.fileOrigin(file)) {
        .virtual, .user, .outside => {},
        .zig_lib, .generated, .package, .other => return null,
    }
    if (ide.naming.isGenerated(text)) return null;
    return .{ .ignore = ignore, .rules = rules };
}

fn dupeStrings(arena: Allocator, list: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, list.len);
    for (list, out) |src, *dst| dst.* = try arena.dupe(u8, src);
    return out;
}

/// Layout rules of the import block for `file`: the client's settings, overridden by the
/// `zig-analyzer.zon` of the project containing the file (the innermost one when nested)
fn importOptionsFor(server: *Server, file: Vfs.FileId) ImportOptions {
    var options = blk: {
        server.config_mutex.lockUncancelable(server.io);
        defer server.config_mutex.unlock(server.io);
        break :blk server.config.importOptions();
    };
    const path = server.vfs.path(file);
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    var best: ?*Workspace = null;
    for (server.workspaces.items) |ws| {
        if (server.vfs.isUnder(path, ws.root) and (best == null or ws.root.len > best.?.root.len)) best = ws;
    }
    if (best) |ws| if (ws.project) |*p| {
        if (p.isSet("imports_derived")) options.derived = p.imports_derived;
        if (p.isSet("imports_sort")) options.sort = p.imports_sort;
    };
    return options;
}

/// The workspace root directory containing `path`
/// (the innermost one when nested), copied into `arena`
fn rootOf(server: *Server, arena: Allocator, path: []const u8) Allocator.Error!?[]const u8 {
    server.roots_mutex.lockUncancelable(server.io);
    defer server.roots_mutex.unlock(server.io);
    return if (server.vfs.rootOf(server.roots.items, path)) |b| try arena.dupe(u8, b) else null;
}

/// The workspace root directories, copied into `arena`
fn rootsAlloc(server: *Server, arena: Allocator) Allocator.Error![]const []const u8 {
    server.roots_mutex.lockUncancelable(server.io);
    defer server.roots_mutex.unlock(server.io);
    return dupeStrings(arena, server.roots.items);
}

/// Names that violate the naming conventions (see `naming`): low-severity hints with code
/// `naming.<rule>` and a link to the official rules
fn appendNaming(server: *Server, ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId, text: []const u8, settings: NamingSettings, diags: []const types.Diagnostic) ![]const types.Diagnostic {
    var r: Resolver = .{ .ctx = ctx, .arena = arena };
    const found = try ide.naming.findings(&r, file, null);
    if (found.len == 0) return diags;
    const lines = try offsets.LineIndex.init(arena, text);
    var out: std.ArrayList(types.Diagnostic) = .empty;
    try out.appendSlice(arena, diags);
    for (found) |f| {
        if (!settings.allows(f)) continue;
        try out.append(arena, .{
            .range = lines.range(f.start, f.end, server.encoding),
            .severity = .Hint,
            .code = .{ .string = f.rule.code() },
            .codeDescription = .{ .href = ide.naming.guide_url },
            .source = "zig-analyzer",
            .message = .{ .string = try ide.naming.message(arena, f) },
        });
    }
    return out.items;
}

// ── Request handlers ──────────────────────────────────────────────────

/// Maps a URI in a read request to a known file; returns
/// null for files that are not open or do not exist
fn lookupFile(server: *Server, arena: Allocator, document_uri: []const u8) !?Vfs.FileId {
    const path = try documentPath(arena, document_uri) orelse return null;
    return try server.vfs.lookup(path);
}

/// Converts a range in a request to byte offsets; a range
/// whose start and end are reversed is treated as swapped
fn rangeOffsets(server: *const Server, text: []const u8, range: types.Range) struct { u32, u32 } {
    const a: u32 = @intCast(offsets.positionToOffset(text, range.start, server.encoding));
    const b: u32 = @intCast(offsets.positionToOffset(text, range.end, server.encoding));
    return .{ @min(a, b), @max(a, b) };
}

/// File text and line index
fn fileLines(ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId) !offsets.LineIndex {
    const text = try ctx.get(FileText, file) orelse "";
    return offsets.LineIndex.init(arena, text);
}

fn formatting(server: *Server, ctx: *Db.Ctx, arena: Allocator, params: types.DocumentFormattingParams) HandlerError!types.ResultType("textDocument/formatting") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const lines = try fileLines(ctx, arena, file);
    const mode = za.syntax.Parse.modeOf(server.vfs.path(file));
    return ide.format.format(arena, lines, mode, server.encoding);
}

fn documentSymbol(server: *Server, ctx: *Db.Ctx, arena: Allocator, params: types.DocumentSymbolParams) HandlerError!types.ResultType("textDocument/documentSymbol") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const parse = try ctx.get(syntax_q.ParseFile, file);
    if (parse.mode == .zon) {
        const lines = try fileLines(ctx, arena, file);
        return .{ .array_of_DocumentSymbol = try ide.document_symbol.zonSymbols(arena, parse.rootNode(), lines, server.encoding) };
    }
    const items = try ctx.get(syntax_q.FileItemTree, file);
    const map = try ctx.get(syntax_q.FileAstIdMap, file);
    const lines = try fileLines(ctx, arena, file);
    return .{ .array_of_DocumentSymbol = try ide.document_symbol.documentSymbols(arena, items, map, lines, server.encoding) };
}

fn foldingRange(server: *Server, ctx: *Db.Ctx, arena: Allocator, params: types.FoldingRangeParams) HandlerError!types.ResultType("textDocument/foldingRange") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const parse = try ctx.get(syntax_q.ParseFile, file);
    const lines = try fileLines(ctx, arena, file);
    return try ide.folding.foldingRanges(arena, parse.rootNode(), lines);
}

fn selectionRange(server: *Server, ctx: *Db.Ctx, arena: Allocator, params: types.SelectionRangeParams) HandlerError!types.ResultType("textDocument/selectionRange") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const parse = try ctx.get(syntax_q.ParseFile, file);
    const lines = try fileLines(ctx, arena, file);
    return try ide.selection_range.selectionRanges(arena, parse.rootNode(), lines, server.encoding, params.positions);
}

fn semanticTokensFull(server: *Server, r: *Resolver, arena: Allocator, params: types.SemanticTokensParams) HandlerError!types.ResultType("textDocument/semanticTokens/full") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const lines = try fileLines(r.ctx, arena, file);
    const data = try ide.semantic_tokens.semanticTokens(r, file, lines, server.encoding, null, server.semanticTokensOptions());
    const result = try server.semanticTokensResult(r.ctx, arena, file, data, null);
    return result.SemanticTokens;
}

fn semanticTokensDelta(server: *Server, r: *Resolver, arena: Allocator, params: types.SemanticTokensDeltaParams) HandlerError!types.ResultType("textDocument/semanticTokens/full/delta") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const lines = try fileLines(r.ctx, arena, file);
    const data = try ide.semantic_tokens.semanticTokens(r, file, lines, server.encoding, null, server.semanticTokensOptions());
    return try server.semanticTokensResult(r.ctx, arena, file, data, params.previousResultId);
}

fn semanticTokensOptions(server: *Server) ide.semantic_tokens.Options {
    server.config_mutex.lockUncancelable(server.io);
    defer server.config_mutex.unlock(server.io);
    return .{ .partial = server.config.semantic_tokens_mode == .partial, .global_var = server.config.semantic_tokens_global_var };
}

fn semanticTokensResult(server: *Server, ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId, data: []const u32, previous_id: ?[]const u8) HandlerError!SemanticCache.Result {
    const is_open = blk: {
        server.docs_mutex.lockUncancelable(server.io);
        defer server.docs_mutex.unlock(server.io);
        break :blk server.open_docs.contains(file);
    };
    try ctx.checkCanceled();
    // The read transaction guarantees that closing the document first waits for this request to
    // exit; for a document that is not open, only the data is returned, and no snapshot reusable
    // across sessions of the document is saved.
    if (!is_open) return .{ .SemanticTokens = .{ .data = data } };
    return try server.semantic_cache.update(server.io, server.gpa, arena, file, data, previous_id);
}

fn semanticTokensRange(server: *Server, r: *Resolver, arena: Allocator, params: types.SemanticTokensRangeParams) HandlerError!types.ResultType("textDocument/semanticTokens/range") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const lines = try fileLines(r.ctx, arena, file);
    return .{ .data = try ide.semantic_tokens.semanticTokens(r, file, lines, server.encoding, params.range, server.semanticTokensOptions()) };
}

fn initialize(server: *Server, _: Allocator, params: types.InitializeParams) HandlerError!types.InitializeResult {
    // Prefer UTF-8 (matches the internal byte offsets);
    // otherwise fall back to the protocol default UTF-16
    if (params.capabilities.general) |general| {
        if (general.positionEncodings) |encodings| {
            for (encodings) |e| {
                if (offsets.Encoding.fromLsp(e) == .utf8) server.encoding = .utf8;
            }
        }
    }
    server.state = .running;
    if (params.capabilities.window) |window| server.progress.enabled = window.workDoneProgress orelse false;
    if (params.capabilities.workspace) |ws| {
        server.pull_config = ws.configuration orelse false;
        if (ws.didChangeConfiguration) |d| server.register_config = d.dynamicRegistration orelse false;
        if (ws.didChangeWatchedFiles) |d| server.register_watch = d.dynamicRegistration orelse false;
        if (ws.inlayHint) |ih| server.inlay_refresh = ih.refreshSupport orelse false;
        if (ws.semanticTokens) |st| server.semantic_refresh = st.refreshSupport orelse false;
        if (ws.workspaceEdit) |we| server.change_annotations = (we.documentChanges orelse false) and we.changeAnnotationSupport != null;
    }
    if (params.capabilities.textDocument) |td| if (td.codeAction) |ca| {
        server.code_action_disabled = ca.disabledSupport orelse false;
        if (ca.resolveSupport) |rs| for (rs.properties) |p| {
            if (std.mem.eql(u8, p, "edit")) server.code_action_resolve = ca.dataSupport orelse false;
        };
    };
    if (params.capabilities.textDocument) |td| if (td.completion) |c| if (c.completionItem) |ci| {
        server.snippet_support = ci.snippetSupport orelse false;
        server.insert_replace_support = ci.insertReplaceSupport orelse false;
    };
    if (params.initializationOptions) |options| if (options != .null) {
        server.config = Config.parse(server.gpa, options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidConfig => blk: {
                server.showWarning("invalid zig-analyzer initializationOptions, using defaults");
                break :blk .{};
            },
        };
        server.reportConfigWarnings("zig-analyzer settings", &server.config);
        server.applyLogging(&server.config, server.config.log_file != null);
        server.applyCacheLimits(&server.config);
    };
    log.info("initialized, position encoding {t}", .{server.encoding});
    if (params.processId) |pid| server.watchParent(pid);

    // Workspace root directories: workspaceFolders first, then rootUri / rootPath
    var root_uris: std.ArrayList([]const u8) = .empty;
    defer root_uris.deinit(server.gpa);
    if (params.workspaceFolders) |folders| for (folders) |f| try root_uris.append(server.gpa, f.uri);
    if (root_uris.items.len == 0) if (params.rootUri) |r| try root_uris.append(server.gpa, r);
    for (root_uris.items) |root_uri| try server.addRoot(root_uri);

    return .{
        .capabilities = .{
            .positionEncoding = server.encoding.toLsp(),
            .textDocumentSync = .{ .TextDocumentSyncOptions = .{
                .openClose = true,
                .change = .Incremental,
                .save = .{ .boolean = true },
            } },
            .documentFormattingProvider = .{ .boolean = true },
            .documentSymbolProvider = .{ .boolean = true },
            .foldingRangeProvider = .{ .boolean = true },
            .selectionRangeProvider = .{ .boolean = true },
            .definitionProvider = .{ .boolean = true },
            .declarationProvider = .{ .boolean = true },
            .typeDefinitionProvider = .{ .boolean = true },
            .completionProvider = .{ .triggerCharacters = &.{ ".", "@", "\"", "/" }, .resolveProvider = true },
            .hoverProvider = .{ .boolean = true },
            .signatureHelpProvider = .{ .triggerCharacters = &.{ "(", "," } },
            .inlayHintProvider = .{ .boolean = true },
            .referencesProvider = .{ .boolean = true },
            .documentHighlightProvider = .{ .boolean = true },
            .renameProvider = .{ .RenameOptions = .{ .prepareProvider = true } },
            .workspaceSymbolProvider = .{ .boolean = true },
            .workspace = .{ .workspaceFolders = .{ .supported = true, .changeNotifications = .{ .boolean = true } } },
            .codeActionProvider = .{ .CodeActionOptions = .{
                .codeActionKinds = &.{ types.CodeActionKind.QuickFix, types.CodeActionKind.RefactorExtract, types.CodeActionKind.RefactorRewrite, types.CodeActionKind.SourceOrganizeImports },
                .resolveProvider = true,
            } },
            .semanticTokensProvider = .{ .SemanticTokensOptions = .{
                .legend = ide.semantic_tokens.legend,
                .full = .{ .SemanticTokensFullDelta = .{ .delta = true } },
                .range = .{ .boolean = true },
            } },
        },
        .serverInfo = .{ .name = "zig-analyzer", .version = za.version },
    };
}

fn shutdown(server: *Server, _: Allocator, _: void) HandlerError!void {
    // First release the waits that depend on the main loop: if the client never answered a
    // configuration request, stop waiting for it. After this the main loop blocks on await and
    // cannot handle a late response, so an in-flight `waitIdle` request can only end through this.
    server.abandonConfigRequests();
    // Stop the build system processes of all projects; wait for in-flight requests to complete,
    // then for background tasks (diagnostics publishing, etc.) to wind down
    server.stopWorkspaces();
    server.group.await(server.io) catch {};
    server.waitIdle();
    server.state = .shutdown;
}

const StatusResult = struct {
    revision: u64,
    files: usize,
    deep_verifications: u64,
    /// Number of write transactions (see `db.Stats.writes`)
    writes: u64,
    /// Peak resident memory of the process (KB; 0 on unsupported platforms)
    max_rss_kb: u64,
    /// Number of types and values in the InternPool
    intern_pool_items: usize,
    /// Bytes used by the InternPool
    intern_pool_bytes: usize,
    /// Bytes allocated through the server's allocator and not yet freed (when the executable wraps
    /// the allocator with `mem.Counting`; 0 otherwise)
    heap_bytes: usize,
    queries: []const struct {
        name: []const u8,
        executions: u64,
        hits: u64,
        cutoffs: u64,
        total_ms: f64,
        self_ms: f64,
        max_ms: f64,
        memos: usize,
        keys: usize,
        /// Bytes used by retained values (for queries that declare `bytes`; 0 otherwise)
        bytes: usize,
        deps: usize,
        incomplete: u64,
    },
    /// Cumulative counts of incomplete results by cause (cycles, stack depth)
    incomplete_causes: struct { cycle: u64, stack: u64 },
};

fn definition(server: *Server, r: *Resolver, arena: Allocator, params: types.DefinitionParams) HandlerError!types.ResultType("textDocument/definition") {
    const locs = try server.gotoTargets(r, arena, params.textDocument.uri, params.position, ide.definition.definitionTargets);
    return switch (locs.len) {
        0 => null,
        1 => .{ .Definition = .{ .Location = locs[0] } },
        else => .{ .Definition = .{ .array_of_Location = locs } },
    };
}

fn declaration(server: *Server, r: *Resolver, arena: Allocator, params: types.DeclarationParams) HandlerError!types.ResultType("textDocument/declaration") {
    const locs = try server.gotoTargets(r, arena, params.textDocument.uri, params.position, ide.definition.declarationTargets);
    return switch (locs.len) {
        0 => null,
        1 => .{ .Declaration = .{ .Location = locs[0] } },
        else => .{ .Declaration = .{ .array_of_Location = locs } },
    };
}

fn typeDefinition(server: *Server, r: *Resolver, arena: Allocator, params: types.TypeDefinitionParams) HandlerError!types.ResultType("textDocument/typeDefinition") {
    const at = try server.textPosition(r, arena, params.textDocument.uri, params.position) orelse return null;
    const targets = try ide.definition.typeDefinitionTargets(r, at.file, at.offset);
    const locs = try arena.alloc(types.Location, targets.len);
    for (targets, locs) |t, *loc| loc.* = try server.targetLocation(r, arena, t);
    return switch (locs.len) {
        0 => null,
        1 => .{ .Definition = .{ .Location = locs[0] } },
        else => .{ .Definition = .{ .array_of_Location = locs } },
    };
}

/// All goto targets at the cursor, computed with `find`. A path in `build.zig.zon` goes to the start
/// of the file it points to, without interning that file
fn gotoTargets(server: *Server, r: *Resolver, arena: Allocator, document_uri: []const u8, pos: types.Position, comptime find: anytype) ![]const types.Location {
    const at = try server.textPosition(r, arena, document_uri, pos) orelse return &.{};
    if (try ide.definition.manifestPath(r, at.file, at.offset)) |path| {
        const target_uri = if (try server.vfs.lookup(path)) |f| try server.uriFor(arena, f) else try uri.fromPath(arena, path);
        return arena.dupe(types.Location, &.{.{ .uri = target_uri, .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } } }});
    }
    const targets = try find(r, at.file, at.offset);
    const locs = try arena.alloc(types.Location, targets.len);
    for (targets, locs) |t, *loc| loc.* = try server.targetLocation(r, arena, t);
    return locs;
}

fn targetLocation(server: *Server, r: *Resolver, arena: Allocator, t: ide.definition.Target) !types.Location {
    const target_uri = try server.uriFor(arena, t.file);
    // The start of a file (the target of an import or of a path in `build.zig.zon`) needs no read
    // of the file: a path can point to a file of any size and content
    if (t.start == 0 and t.end == 0) return .{ .uri = target_uri, .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } } };
    const target_text = (try r.ctx.get(syntax_q.SourceText, t.file)).text;
    const lines = try offsets.LineIndex.init(arena, target_text);
    return .{ .uri = target_uri, .range = lines.range(t.start, t.end, server.encoding) };
}

fn completion(server: *Server, r: *Resolver, arena: Allocator, params: types.CompletionParams) HandlerError!types.ResultType("textDocument/completion") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const text = try r.ctx.get(FileText, file) orelse return null;
    const line = offsets.Line.init(text, params.position.line);
    const offset: u32 = @intCast(if (line) |l| l.offset(params.position.character, server.encoding) else text.len);
    const auto_import = server.autoImportEnabled();
    // Auto-imports are not offered until the index has been built for the current module graph, and
    // the result is marked incomplete: the client requests again as the user types, and they are
    // offered then. Indexing starts the first time completion happens where a name could be
    // imported; later, if the index is still not built and no indexing is in progress (the previous
    // round failed, or the task could not start), it starts again.
    const imports_ready = auto_import and
        server.imports_basis.load(.acquire) == importsBasis(try r.ctx.get(ModuleGraph.Input, {}));
    const max_auto_imports, const snippets, const placeholders = blk: {
        server.config_mutex.lockUncancelable(server.io);
        defer server.config_mutex.unlock(server.io);
        const c = &server.config;
        break :blk .{ c.completion_max_auto_imports, c.completion_snippets, c.completion_argument_placeholders };
    };
    const import_options = server.importOptionsFor(file);
    // `/` and `"` are trigger characters for paths; typed elsewhere they start no name
    const path_trigger = blk: {
        const c = params.context orelse break :blk false;
        const t = c.triggerCharacter orelse break :blk false;
        break :blk c.triggerKind == .TriggerCharacter and (std.mem.eql(u8, t, "/") or std.mem.eql(u8, t, "\""));
    };
    const result = try ide.completion.complete(r, file, offset, .{
        .auto_import = auto_import and imports_ready,
        .detect_import_position = auto_import and !imports_ready,
        .max_auto_imports = if (max_auto_imports == 0) std.math.maxInt(usize) else max_auto_imports,
        .imports = import_options,
        .snippets = server.snippet_support and snippets,
        .argument_placeholders = placeholders,
        .paths_only = path_trigger,
    });
    const imports_waiting = auto_import and !imports_ready and result.import_position;
    if (imports_waiting) {
        const first = !server.imports_wanted.swap(true, .acq_rel);
        if (first or !server.indexing.load(.acquire)) server.scheduleIndexingFromRead();
    }
    const out = try arena.alloc(types.CompletionItem, result.items.len);
    var ranges: CompletionRanges = .{ .text = text, .line = line, .encoding = server.encoding };
    for (result.items, out) |it, *o| {
        o.* = .{
            .label = it.label,
            .kind = switch (it.kind) {
                .param, .variable => .Variable,
                .type_param => .TypeParameter,
                .function, .builtin => .Function,
                .method => .Method,
                .constant, .error_name => .Constant,
                .namespace, .module => .Module,
                .@"struct" => .Struct,
                .@"enum" => .Enum,
                .type => .Class,
                .field => .Field,
                .enum_member => .EnumMember,
                .file => .File,
                .folder => .Folder,
                .label => .Reference,
                .snippet => .Snippet,
            },
            .documentation = if (it.doc) |d| .{ .MarkupContent = .{ .kind = .markdown, .value = d } } else null,
            .detail = it.detail,
            .filterText = it.filter,
            .sortText = it.sort,
            .data = if (it.target) |t| try completionData(r, arena, file, t) else null,
            .labelDetails = if (it.qualifier) |q| .{ .description = q } else null,
        };
        // A replaced range ends at the end of the word (or path) at the cursor; inserting replaces
        // only up to the cursor. Clients that support both ranges apply the one the user chose;
        // others get the replaced range for every item
        if (it.replace) |range| {
            const new_text = it.snippet orelse it.label;
            const replace = try ranges.get(arena, range.start, range.end);
            o.textEdit = if (server.insert_replace_support) .{ .InsertReplaceEdit = .{
                .newText = new_text,
                .insert = try ranges.get(arena, range.start, std.math.clamp(offset, range.start, range.end)),
                .replace = replace,
            } } else .{ .TextEdit = .{ .range = replace, .newText = new_text } };
            if (it.snippet != null) o.insertTextFormat = .Snippet;
        }
        if (it.import_edit) |edit| {
            const edits = try arena.alloc(types.TextEdit, 1);
            edits[0] = .{ .range = try ranges.get(arena, edit.start, edit.end), .newText = edit.text };
            o.additionalTextEdits = edits;
        }
    }
    if (result.is_incomplete or imports_waiting) return .{ .CompletionList = .{ .isIncomplete = true, .items = out } };
    return .{ .array_of_CompletionItem = out };
}

/// Converts the ranges of completion items to LSP ranges. Replaced ranges are almost always in the
/// line of the cursor and are converted within that line, without building a line table for the
/// whole file (on large files, building the line table is slower than the completion itself); only
/// other ranges (added imports, ranges spanning lines) build the line table
const CompletionRanges = struct {
    text: []const u8,
    /// The line of the cursor
    line: ?offsets.Line,
    encoding: offsets.Encoding,
    lines: ?offsets.LineIndex = null,
    /// The range converted last: items mostly replace the same range
    last: ?struct { start: u32, end: u32, range: types.Range } = null,

    fn get(c: *CompletionRanges, arena: Allocator, start: u32, end: u32) Allocator.Error!types.Range {
        if (c.last) |l| if (l.start == start and l.end == end) return l.range;
        const range = c.inLine(start, end) orelse blk: {
            if (c.lines == null) c.lines = try offsets.LineIndex.init(arena, c.text);
            break :blk c.lines.?.range(start, end, c.encoding);
        };
        c.last = .{ .start = start, .end = end, .range = range };
        return range;
    }

    /// The range when both ends are in the line of the cursor
    fn inLine(c: *const CompletionRanges, start: u32, end: u32) ?types.Range {
        const line = c.line orelse return null;
        return .{
            .start = line.position(start, c.encoding) orelse return null,
            .end = line.position(end, c.encoding) orelse return null,
        };
    }
};

test "CompletionRanges: ranges in the line of the cursor and elsewhere convert as with the line table" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // CRLF line breaks and characters of 2, 3 and 4 UTF-8 bytes before the word at the cursor
    const text = "const a = @import(\"a.zig\");\r\nfn f() void {\r\n    _ = \"é€😀\" ++ ad;\r\n}\r\n";
    const word = std.mem.indexOf(u8, text, "ad;").?;
    const line_start = std.mem.indexOf(u8, text, "    _").?;
    const line_end = std.mem.indexOfPos(u8, text, line_start, "\r").?;
    for ([_]offsets.Encoding{ .utf8, .utf16, .utf32 }) |enc| {
        const lines = try offsets.LineIndex.init(arena, text);
        var ranges: CompletionRanges = .{ .text = text, .line = offsets.Line.init(text, 2), .encoding = enc };
        // In the line of the cursor (the word, an empty range at its end, the whole line): no line
        // table is built
        for ([_][2]usize{ .{ word, word + 2 }, .{ word + 2, word + 2 }, .{ line_start, line_end } }) |r| {
            try std.testing.expectEqualDeep(lines.range(r[0], r[1], enc), try ranges.get(arena, @intCast(r[0]), @intCast(r[1])));
        }
        try std.testing.expect(ranges.lines == null);
        // An import added in the first line, and a range spanning lines
        for ([_][2]usize{ .{ 0, 0 }, .{ line_start - 2, word } }) |r| {
            try std.testing.expectEqualDeep(lines.range(r[0], r[1], enc), try ranges.get(arena, @intCast(r[0]), @intCast(r[1])));
        }
        try std.testing.expect(ranges.lines != null);
    }
}

/// `data` of a completion item: the file where completion happens (`from`), the target file, and
/// the `AstId` of the declaration in it (which still finds the same declaration after edits). When
/// the item is selected, the client sends it with a `completionItem/resolve` request.
fn completionData(r: *Resolver, arena: Allocator, from: Vfs.FileId, target: za.ide_db.imports.Target) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "from", .{ .integer = from.index() });
    switch (target) {
        .decl => |d| {
            try obj.put(arena, "file", .{ .integer = d.file.index() });
            try obj.put(arena, "item", .{ .integer = @backingInt((try r.itemTree(d.file)).items[d.item].ast_id) });
        },
        .file => |f| try obj.put(arena, "file", .{ .integer = f.index() }),
    }
    return .{ .object = obj };
}

/// A completion item was selected: fills in the signature (`detail`), the doc comment and the
/// definition's location (`documentation`). Returns the item unchanged if `data` did not come from
/// this server or the declaration it refers to no longer exists.
fn completionResolve(server: *Server, r: *Resolver, _: Allocator, params: types.CompletionItem) HandlerError!types.ResultType("completionItem/resolve") {
    var item = params;
    const data = switch (params.data orelse return item) {
        .object => |o| o,
        else => return item,
    };
    const from = server.dataFile(data, "from") orelse return item;
    const file = server.dataFile(data, "file") orelse return item;
    const target: za.ide_db.imports.Target = if (data.get("item")) |v| blk: {
        if (v != .integer or v.integer < 0 or v.integer > std.math.maxInt(u32)) return item;
        const def = try ide.context.defOfKey(r, .{ .file = file, .item = @fromBackingInt(@as(u32, @intCast(v.integer))) }) orelse return item;
        break :blk .{ .decl = .{ .file = file, .item = def.item.item } };
    } else .{ .file = file };
    const description = try ide.completion.describe(r, from, target);
    item.detail = description.detail;
    item.documentation = .{ .MarkupContent = .{ .kind = .markdown, .value = description.doc } };
    return item;
}

/// The file named by `key` in `data`; null if it is not a file of the current session
fn dataFile(server: *Server, data: std.json.ObjectMap, key: []const u8) ?Vfs.FileId {
    const v = data.get(key) orelse return null;
    if (v != .integer or v.integer < 0 or v.integer >= server.vfs.count()) return null;
    return @fromBackingInt(@as(u32, @intCast(v.integer)));
}

/// The file, text and position of a request
fn textPosition(server: *Server, r: *Resolver, arena: Allocator, document_uri: []const u8, pos: types.Position) !?struct { file: Vfs.FileId, text: []const u8, offset: u32 } {
    const file = try server.lookupFile(arena, document_uri) orelse return null;
    const text = (try r.ctx.get(syntax_q.SourceText, file)).text;
    return .{ .file = file, .text = text, .offset = @intCast(offsets.positionToOffset(text, pos, server.encoding)) };
}

fn hover(server: *Server, r: *Resolver, arena: Allocator, params: types.HoverParams) HandlerError!types.ResultType("textDocument/hover") {
    const at = try server.textPosition(r, arena, params.textDocument.uri, params.position) orelse return null;
    const info = try ide.hover.hover(r, at.file, at.offset, try server.rootsAlloc(arena)) orelse return null;
    const lines = try offsets.LineIndex.init(arena, at.text);
    return .{
        .contents = .{ .MarkupContent = .{ .kind = .markdown, .value = info.text } },
        .range = lines.range(info.start, info.end, server.encoding),
    };
}

fn signatureHelp(server: *Server, r: *Resolver, arena: Allocator, params: types.SignatureHelpParams) HandlerError!types.ResultType("textDocument/signatureHelp") {
    const at = try server.textPosition(r, arena, params.textDocument.uri, params.position) orelse return null;
    const sig = try ide.signature_help.signatureHelp(r, at.file, at.offset) orelse return null;
    const ps = try arena.alloc(types.ParameterInformation, sig.params.len);
    for (sig.params, ps) |p, *o| o.* = .{ .label = .{ .string = p } };
    const info = try arena.alloc(types.SignatureInformation, 1);
    info[0] = .{
        .label = sig.label,
        .parameters = ps,
        .activeParameter = if (ps.len == 0) null else sig.active,
        .documentation = if (sig.doc) |d| .{ .MarkupContent = .{ .kind = .markdown, .value = d } } else null,
    };
    return .{ .signatures = info, .activeSignature = 0, .activeParameter = if (ps.len == 0) null else sig.active };
}

fn inlayHint(server: *Server, r: *Resolver, arena: Allocator, params: types.InlayHintParams) HandlerError!types.ResultType("textDocument/inlayHint") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const text = (try r.ctx.get(syntax_q.SourceText, file)).text;
    const start, const end = server.rangeOffsets(text, params.range);
    const opts: ide.inlay_hints.Options = blk: {
        server.config_mutex.lockUncancelable(server.io);
        defer server.config_mutex.unlock(server.io);
        const c = &server.config;
        break :blk .{
            .types = c.inlay_types,
            .field_types = c.inlay_field_types,
            .anonymous_containers = c.inlay_anonymous_containers,
            .parameters = c.inlay_parameters,
            .builtin_parameters = c.inlay_builtin_parameters,
            .exclude_single_argument = c.inlay_exclude_single_argument,
            .hide_redundant_param_names = c.hide_redundant_param_names,
            .max_length = c.inlay_max_length,
        };
    };
    const hints = try ide.inlay_hints.inlayHints(r, file, start, end, opts);
    const lines = try offsets.LineIndex.init(arena, text);
    const out = try arena.alloc(types.InlayHint, hints.len);
    for (hints, out) |h, *o| o.* = .{
        .position = lines.position(h.offset, server.encoding),
        .label = .{ .string = h.label },
        .kind = switch (h.kind) {
            .type => .Type,
            .parameter => .Parameter,
        },
        .paddingRight = if (h.kind == .parameter) true else null,
        .tooltip = if (h.tooltip) |t| .{ .string = t } else null,
    };
    return out;
}

/// `scan_done` before the first scan of the root directories has finished
const never_scanned = std.math.maxInt(u64);

/// Why the search scope may lack files that refer to a declaration right now, or null: the root
/// directories have not been scanned since source files may have changed (see `scheduleScan`), or
/// a project is still in its first load (until then, which files belong to it and what its imports
/// by name resolve to are not known). Find references, rename and the fixes that edit references
/// fail with this reason instead of returning partial results.
fn scopeIncomplete(server: *Server) ?[]const u8 {
    if (server.scan_done.load(.acquire) != server.scan_generation.load(.acquire))
        return "the workspace folders are still being searched for source files, so not all files that may refer to it are known yet";
    if (server.projectsLoading()) return "the project is still loading, so not all files that may refer to it are known yet";
    return null;
}

/// Scope of find references and workspace symbol: project files in the module graph (excluding the
/// standard library), the user's source files under the root directories, and open documents
fn searchScope(server: *Server, r: *Resolver) ![]const Vfs.FileId {
    var set: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty;
    for (try za.ide_db.search.searchFiles(r)) |f| try set.put(r.arena, f, {});
    server.docs_mutex.lockUncancelable(server.io);
    defer server.docs_mutex.unlock(server.io);
    for (server.open_docs.keys()) |f| try set.put(r.arena, f, {});
    return set.keys();
}

/// Scope of workspace symbol: excludes files in dependency libraries by default;
/// `workspace_symbol.dependencies` includes them. While indexing is in progress, only indexed files
/// and open documents are used, and the remaining files are not parsed during the request (LSP's
/// workspace/symbol has no isIncomplete: the client requests again as the user types, and the
/// results fill in as indexing progresses).
fn symbolScope(server: *Server, r: *Resolver) ![]const Vfs.FileId {
    var scope = try server.searchScope(r);
    const dependencies = blk: {
        server.config_mutex.lockUncancelable(server.io);
        defer server.config_mutex.unlock(server.io);
        break :blk server.config.workspace_symbol_dependencies;
    };
    if (!dependencies) {
        const rules = try server.originRules(r.arena);
        var user: std.ArrayList(Vfs.FileId) = .empty;
        for (scope) |f| if (!origin.classify(&server.vfs, rules, server.vfs.path(f), false).isLibrary()) try user.append(r.arena, f);
        scope = user.items;
    }
    if (!server.indexing.load(.acquire)) return scope;
    var out: std.ArrayList(Vfs.FileId) = .empty;
    server.indexed_mutex.lockUncancelable(server.io);
    defer server.indexed_mutex.unlock(server.io);
    server.docs_mutex.lockUncancelable(server.io);
    defer server.docs_mutex.unlock(server.io);
    for (scope) |f| if (server.indexed.contains(f) or server.open_docs.contains(f)) try out.append(r.arena, f);
    return out.items;
}

/// The symbol at the cursor (see `definition.symbolAt`)
fn symbolAtPosition(server: *Server, r: *Resolver, arena: Allocator, document_uri: []const u8, pos: types.Position) !?struct { symbol: za.ide_db.search.Symbol, file: Vfs.FileId } {
    const at = try server.textPosition(r, arena, document_uri, pos) orelse return null;
    const symbol = try ide.definition.symbolAt(r, at.file, at.offset) orelse return null;
    return .{ .symbol = symbol, .file = at.file };
}

/// Why the references of `symbol` cannot all be found now (see `scopeIncomplete`); null also when
/// only its own file can refer to it
fn scopeIncompleteFor(server: *Server, r: *Resolver, symbol: za.ide_db.search.Symbol) !?[]const u8 {
    if (!try ownFileOnly(r, symbol)) return server.scopeIncomplete();
    return null;
}

/// Whether only the file of `symbol` can refer to it: local names, labels, and declarations without
/// `pub` other than fields. Error names are global.
fn ownFileOnly(r: *Resolver, symbol: za.ide_db.search.Symbol) !bool {
    return switch (symbol) {
        .def => |def| !try za.ide_db.search.visibleOutsideFile(r, def),
        .label => true,
        .error_name => false,
    };
}

/// Converts reference positions to LSP ranges (caching the line index per file)
const RangeMapper = struct {
    server: *Server,
    r: *Resolver,
    file: ?Vfs.FileId = null,
    lines: offsets.LineIndex = undefined,

    fn range(m: *RangeMapper, file: Vfs.FileId, start: u32, end: u32) !types.Range {
        if (m.file != file) {
            m.lines = try offsets.LineIndex.init(m.r.arena, (try m.r.ctx.get(syntax_q.SourceText, file)).text);
            m.file = file;
        }
        return m.lines.range(start, end, m.server.encoding);
    }
};

fn references(server: *Server, r: *Resolver, arena: Allocator, params: types.ReferenceParams) HandlerError!Outcome(types.ResultType("textDocument/references")) {
    const found = try server.symbolAtPosition(r, arena, params.textDocument.uri, params.position) orelse return .{ .ok = null };
    if (try server.scopeIncompleteFor(r, found.symbol)) |reason| return .{ .failed = try std.fmt.allocPrint(arena, "cannot find all references: {s}", .{reason}) };
    const refs = try za.ide_db.search.symbolReferences(r, found.symbol, .{ .scope = try server.searchScope(r) });
    var out: std.ArrayList(types.Location) = .empty;
    var m: RangeMapper = .{ .server = server, .r = r };
    for (refs) |ref| {
        if (ref.is_decl and !params.context.includeDeclaration) continue;
        try out.append(arena, .{ .uri = try server.uriFor(arena, ref.file), .range = try m.range(ref.file, ref.start, ref.end) });
    }
    return .{ .ok = out.items };
}

/// Occurrences of the symbol at the cursor in the same file: declarations and the targets of
/// assignments are written to (`Write`), other uses read it (`Read`)
fn documentHighlight(server: *Server, r: *Resolver, arena: Allocator, params: types.DocumentHighlightParams) HandlerError!types.ResultType("textDocument/documentHighlight") {
    const found = try server.symbolAtPosition(r, arena, params.textDocument.uri, params.position) orelse return null;
    const refs = try za.ide_db.search.symbolReferences(r, found.symbol, .{ .scope = &.{}, .only_file = found.file });
    const out = try arena.alloc(types.DocumentHighlight, refs.len);
    var m: RangeMapper = .{ .server = server, .r = r };
    for (refs, out) |ref, *o| o.* = .{ .range = try m.range(ref.file, ref.start, ref.end), .kind = if (ref.is_decl or ref.is_write) .Write else .Read };
    return out;
}

/// Why `symbol` cannot be renamed, or null when it can: the user's own code (see
/// `origin.Origin.user`) and unsaved documents can be renamed. In a file outside the workspace
/// folders (`origin.Origin.outside`), only what its own file alone can refer to can be renamed
/// (see `ownFileOnly`): which other files use the rest is not known.
fn renameRefusal(server: *Server, r: *Resolver, symbol: za.ide_db.search.Symbol) !?[]const u8 {
    const file = switch (symbol) {
        .def => |def| switch (def) {
            .item => |it| it.file,
            .local => |l| l.file,
            // `@import` and its path string lead to a file, which is not a name in the code
            .file => return "cannot rename: the cursor is on the import of a file, and files cannot be renamed",
        },
        .label => |l| l.file,
        .error_name => |e| e.file,
    };
    if (try za.ide_db.search.symbolName(r, symbol) == null) return "cannot rename: there is no name here";
    const rules = try server.originRules(r.arena);
    return switch (origin.classify(&server.vfs, rules, server.vfs.path(file), server.inProject(file))) {
        // Unsaved documents (`untitled:` etc.) exist only in the editor
        .virtual, .user => null,
        .outside => if (try ownFileOnly(r, symbol))
            null
        else if (symbol == .error_name)
            "cannot rename an error name in a file outside the workspace folders: error names are global, and the files that use it are not known"
        else
            "cannot rename a public declaration or field of a file outside the workspace folders: the files that use it are not known",
        .zig_lib, .generated, .package, .other => "cannot rename a symbol defined outside the workspace",
    };
}

fn prepareRename(server: *Server, r: *Resolver, arena: Allocator, params: types.PrepareRenameParams) HandlerError!Outcome(types.ResultType("textDocument/prepareRename")) {
    const at = try server.textPosition(r, arena, params.textDocument.uri, params.position) orelse return .{ .ok = null };
    const tok = try ide.definition.tokenAt(r, at.file, at.offset) orelse return .{ .ok = null };
    if (tok.kind != .identifier) return .{ .ok = null };
    const symbol = try ide.definition.symbolAt(r, at.file, at.offset) orelse return .{ .ok = null };
    if (try server.renameRefusal(r, symbol)) |reason| return .{ .failed = reason };
    if (symbol == .def) if (try ide.rename.stdRootLookup(r, symbol.def)) |p| {
        const prefix = try std.fmt.allocPrint(arena, "cannot rename `{s}`", .{za.syntax.ast.identName(tok.text)});
        return .{ .failed = try server.fixProblem(r, arena, prefix, p.file, p.offset, p.message) };
    };
    const lines = try offsets.LineIndex.init(arena, at.text);
    return .{ .ok = .{ .PrepareRenamePlaceholder = .{
        .range = lines.range(tok.offset, tok.offset + @as(u32, @intCast(tok.text.len)), server.encoding),
        .placeholder = za.syntax.ast.identName(tok.text),
    } } };
}

fn rename(server: *Server, r: *Resolver, arena: Allocator, params: types.RenameParams) HandlerError!Outcome(types.ResultType("textDocument/rename")) {
    _ = try identifierText(arena, params.newName, false);
    const at = try server.textPosition(r, arena, params.textDocument.uri, params.position) orelse return .{ .ok = null };
    const symbol = try ide.definition.symbolAt(r, at.file, at.offset) orelse return .{ .ok = null };
    if (try server.renameRefusal(r, symbol)) |reason| return .{ .failed = reason };
    const old = (try za.ide_db.search.symbolName(r, symbol)).?;
    const outcome = switch (symbol) {
        .def => |def| try server.checkedRename(r, arena, def, old, params.newName),
        .label => |l| try server.checkedLabelRename(r, arena, l, old, params.newName),
        .error_name => |e| try server.checkedErrorRename(r, arena, e.file, old, params.newName),
    };
    const checked = switch (outcome) {
        .ok => |checked| checked,
        .failed => |reason| return .{ .failed = reason },
    };
    return .{ .ok = try server.renameEdit(r, arena, checked.refs, checked.text, null) };
}

const CheckedRename = struct {
    refs: []const za.ide_db.search.Reference,
    /// The new name as written in the source (see `identifierText`)
    text: []const u8,
};

/// The references of `def` and the source text of the new name for renaming it from `old` to
/// `new` (as given, possibly `@"..."`), or why the result would be partial or break the build:
/// the references cannot all be confirmed (see `renameReferences`), the new name conflicts with an
/// existing one (a member of the same container, shadowing, or a reference that would become
/// ambiguous; see `rename.declarationConflict` and `rename.resolutionConflict`), or AstGen
/// reports a new error in the declaration's file once it is renamed (`rename.verifyAstGen`).
fn checkedRename(server: *Server, r: *Resolver, arena: Allocator, def: za.names.resolve.Def, old: []const u8, new: []const u8) !Outcome(CheckedRename) {
    const refs = switch (try server.renameReferences(r, arena, .{ .def = def }, old, new)) {
        .ok => |refs| refs,
        .failed => |reason| return .{ .failed = reason },
    };
    const name = try decodedName(arena, new);
    if (try ide.rename.declarationConflict(r, def, name)) |p| return .{ .failed = try server.renameProblem(r, arena, old, new, p.file, p.offset, p.message) };
    if (try ide.rename.resolutionConflict(r, def, name)) |p| return .{ .failed = try server.renameProblem(r, arena, old, new, p.file, p.offset, p.message) };
    const def_file = switch (def) {
        .item => |it| it.file,
        .local => |l| l.file,
        .file => unreachable,
    };
    const is_field = switch (def) {
        .item => |it| (try r.itemTree(it.file)).items[it.item].kind == .field,
        .local, .file => false,
    };
    const text = try identifierText(arena, new, is_field);
    // Shadowing and name clashes can only occur in the file of the declaration, and missed
    // references in that file are reported too: confirm by running AstGen on the renamed text
    var edits: std.ArrayList(ide.rename.Edit) = .empty;
    for (refs) |ref| if (ref.file == def_file) try edits.append(arena, .{ .start = ref.start, .end = ref.end, .text = text });
    if (try ide.rename.verifyAstGen(r, def_file, edits.items)) |p| return .{ .failed = try server.renameProblem(r, arena, old, new, p.file, p.offset, p.message) };
    // Strings (`@field`, `@hasDecl`, `@fieldParentPtr`, serialization keys) can name only
    // container members, and one without `pub` only in its own file
    if (def == .item) {
        const files = if (try za.ide_db.search.visibleOutsideFile(r, def)) try za.ide_db.search.importers(r, def_file, try server.searchScope(r)) else try arena.dupe(Vfs.FileId, &.{def_file});
        if (try ide.rename.stringReference(r, files, old)) |p| return .{ .failed = try server.renameProblem(r, arena, old, new, p.file, p.offset, p.message) };
    }
    return .{ .ok = .{ .refs = refs, .text = text } };
}

/// The name that `new` (as given, possibly `@"..."`) spells
fn decodedName(arena: Allocator, new: []const u8) HandlerError![]const u8 {
    if (!std.mem.startsWith(u8, new, "@\"")) return new;
    return std.zig.string_literal.parseAlloc(arena, new[1..]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidLiteral => return error.InvalidIdentifier,
    };
}

/// The references of a label and the source text of its new name (see `checkedRename`): the label
/// and the `break` / `continue` that target it are all in one member, and AstGen confirms the
/// renamed file (a label must not redefine a label of an enclosing expression)
fn checkedLabelRename(server: *Server, r: *Resolver, arena: Allocator, label: za.ide_db.search.Label, old: []const u8, new: []const u8) !Outcome(CheckedRename) {
    const refs = switch (try server.renameReferences(r, arena, .{ .label = label }, old, new)) {
        .ok => |refs| refs,
        .failed => |reason| return .{ .failed = reason },
    };
    const text = try identifierText(arena, new, false);
    const edits = try arena.alloc(ide.rename.Edit, refs.len);
    for (refs, edits) |ref, *e| e.* = .{ .start = ref.start, .end = ref.end, .text = text };
    if (try ide.rename.verifyAstGen(r, label.file, edits)) |p| return .{ .failed = try server.renameProblem(r, arena, old, new, p.file, p.offset, p.message) };
    return .{ .ok = .{ .refs = refs, .text = text } };
}

/// The uses of the error `old`, found in `file`, and the source text of its new name (see
/// `checkedRename`). Error names are global, so the uses in all files compiled together with
/// `file` are renamed: each must be confirmed and editable (see `renameReferences`), no file that
/// is not renamed may use `old`, and `new` must not already be an error name (see
/// `rename.errorNameConflict`); `@errorName` results may be compared with a string of the name,
/// and AstGen confirms each renamed file.
fn checkedErrorRename(server: *Server, r: *Resolver, arena: Allocator, file: Vfs.FileId, old: []const u8, new: []const u8) !Outcome(CheckedRename) {
    const refs = switch (try server.renameReferences(r, arena, .{ .error_name = .{ .file = file, .name = old } }, old, new)) {
        .ok => |refs| refs,
        .failed => |reason| return .{ .failed = reason },
    };
    const scope = try server.searchScope(r);
    if (try ide.rename.errorNameConflict(r, file, scope, old, try decodedName(arena, new))) |p| return .{ .failed = try server.renameProblem(r, arena, old, new, p.file, p.offset, p.message) };
    const files = try za.ide_db.search.candidateFiles(r, try za.ide_db.search.importers(r, file, scope), scope);
    if (try ide.rename.stringReference(r, files, old)) |p| return .{ .failed = try server.renameProblem(r, arena, old, new, p.file, p.offset, p.message) };
    // Error names may be names of primitive types (`error.u8`)
    const text = try identifierText(arena, new, true);
    var i: usize = 0;
    while (i < refs.len) {
        const f = refs[i].file;
        var edits: std.ArrayList(ide.rename.Edit) = .empty;
        while (i < refs.len and refs[i].file == f) : (i += 1) try edits.append(arena, .{ .start = refs[i].start, .end = refs[i].end, .text = text });
        if (try ide.rename.verifyAstGen(r, f, edits.items)) |p| return .{ .failed = try server.renameProblem(r, arena, old, new, p.file, p.offset, p.message) };
    }
    return .{ .ok = .{ .refs = refs, .text = text } };
}

/// All references of `symbol` for renaming it from `old` to `new`, or why they cannot all be
/// confirmed, in which case renaming would leave a partially renamed result: the standard library
/// looks the declaration up by name in the root source file (see `rename.stdRootLookup`), the
/// search scope is still incomplete (see `scopeIncomplete`), a reference is ambiguous in a generic
/// function, goes through a member access of unknown type, or depends on instances that grow
/// without bound, or a file that mentions the name has syntax errors.
fn renameReferences(server: *Server, r: *Resolver, arena: Allocator, symbol: za.ide_db.search.Symbol, old: []const u8, new: []const u8) !Outcome([]const za.ide_db.search.Reference) {
    if (symbol == .def) if (try ide.rename.stdRootLookup(r, symbol.def)) |p| return .{ .failed = try server.renameProblem(r, arena, old, new, p.file, p.offset, p.message) };
    if (try server.scopeIncompleteFor(r, symbol)) |reason| return .{ .failed = try std.fmt.allocPrint(arena, "cannot rename `{s}` to `{s}`: {s}", .{ old, new, reason }) };
    const scope = try server.searchScope(r);
    var ambiguous: ?za.ide_db.search.Reference = null;
    var uncertain: ?za.ide_db.search.Reference = null;
    var incomplete: ?za.ide_db.search.Reference = null;
    var syntax_error: ?Vfs.FileId = null;
    const refs = try za.ide_db.search.symbolReferences(r, symbol, .{
        .scope = scope,
        .ambiguous = &ambiguous,
        .uncertain = &uncertain,
        .incomplete = &incomplete,
        .syntax_error = &syntax_error,
    });
    if (syntax_error) |file| return .{ .failed = try server.renameProblem(r, arena, old, new, file, null, "the file has syntax errors, so references in it may be missed") };
    if (ambiguous) |a| return .{ .failed = try server.renameProblem(r, arena, old, new, a.file, a.start, za.ide_db.search.ambiguous_message) };
    if (uncertain) |u| return .{ .failed = try server.renameProblem(r, arena, old, new, u.file, u.start, if (symbol == .error_name)
        "the type here is unknown, so whether this is the same error cannot be confirmed"
    else
        "the type here is unknown, so whether this refers to the same declaration cannot be confirmed") };
    if (incomplete) |u| return .{ .failed = try server.renameProblem(r, arena, old, new, u.file, u.start, "this reference depends on instantiations of a generic function that grow without bound, so not all of them can be checked") };
    const rules = try server.originRules(arena);
    for (refs, 0..) |ref, i| {
        // Sorted by file: check each file once
        if (i > 0 and refs[i - 1].file == ref.file) continue;
        if (!server.editable(rules, ref.file)) return .{ .failed = try server.renameProblem(r, arena, old, new, ref.file, ref.start, not_editable) };
    }
    return .{ .ok = refs };
}

/// Why an edit that a rename or fix needs in a file that is not `editable` is refused
const not_editable = "this use is in a dependency library (the Zig installation, a fetched package, a generated file) or a stale copy of one, which must not be edited";

/// Whether renames and fixes may edit `file`: the user's own code (see `origin.Origin`). A
/// fetched package is restored from its hash on other machines, the Zig installation is shared by
/// every project, and generated files are overwritten by builds.
fn editable(server: *Server, rules: origin.Rules, file: Vfs.FileId) bool {
    return switch (origin.classify(&server.vfs, rules, server.vfs.path(file), server.inProject(file))) {
        .virtual, .user, .outside => true,
        .zig_lib, .generated, .package, .other => false,
    };
}

/// Edits that change the references (sorted by file and position, including the declaration) to
/// `new_text`. When `confirm` is not null, the edits carry an annotation with it as the label
/// that requires user confirmation (see `workspaceEdit`).
fn renameEdit(server: *Server, r: *Resolver, arena: Allocator, refs: []const za.ide_db.search.Reference, new_text: []const u8, confirm: ?[]const u8) !types.WorkspaceEdit {
    var files: std.ArrayList(ide.rename.FileEdits) = .empty;
    var i: usize = 0;
    while (i < refs.len) {
        const file = refs[i].file;
        var edits: std.ArrayList(ide.rename.Edit) = .empty;
        while (i < refs.len and refs[i].file == file) : (i += 1) {
            try edits.append(arena, .{ .start = refs[i].start, .end = refs[i].end, .text = new_text });
        }
        try files.append(arena, .{ .file = file, .edits = edits.items });
    }
    return server.workspaceEdit(r, arena, files.items, if (confirm) |label| .{
        .id = "zig-analyzer.rename-public",
        .label = label,
        .description = "code outside this workspace that uses the name is not updated",
    } else null);
}

/// A change annotation that requires user confirmation
const Confirmation = struct {
    id: []const u8,
    label: []const u8,
    description: []const u8,
};

/// Edits of each file (sorted by file, and by position within a file). When `confirm` is not
/// null and the client supports change annotations, the edits carry an annotation requiring user
/// confirmation, and the client asks the user to confirm before applying them.
fn workspaceEdit(server: *Server, r: *Resolver, arena: Allocator, files: []const ide.rename.FileEdits, confirm: ?Confirmation) !types.WorkspaceEdit {
    const annotated = confirm != null and server.change_annotations;
    const DocumentChange = @typeInfo(@typeInfo(@FieldType(types.WorkspaceEdit, "documentChanges")).optional.child).pointer.child;
    const DocumentEdit = @typeInfo(@FieldType(types.TextDocumentEdit, "edits")).pointer.child;
    var changes: std.json.ArrayHashMap([]const types.TextEdit) = .{};
    var documents: std.ArrayList(DocumentChange) = .empty;
    var m: RangeMapper = .{ .server = server, .r = r };
    for (files) |fe| {
        const file_uri = try server.uriFor(arena, fe.file);
        if (annotated) {
            const edits = try arena.alloc(DocumentEdit, fe.edits.len);
            for (fe.edits, edits) |e, *o| o.* = .{ .AnnotatedTextEdit = .{ .range = try m.range(fe.file, e.start, e.end), .newText = e.text, .annotationId = confirm.?.id } };
            try documents.append(arena, .{ .TextDocumentEdit = .{ .textDocument = .{ .uri = file_uri, .version = server.docVersion(fe.file) }, .edits = edits } });
        } else {
            const edits = try arena.alloc(types.TextEdit, fe.edits.len);
            for (fe.edits, edits) |e, *o| o.* = .{ .range = try m.range(fe.file, e.start, e.end), .newText = e.text };
            try changes.map.put(arena, file_uri, edits);
        }
    }
    if (!annotated) return .{ .changes = changes };
    var annotations: std.json.ArrayHashMap(types.ChangeAnnotation) = .{};
    try annotations.map.put(arena, confirm.?.id, .{
        .label = confirm.?.label,
        .needsConfirmation = true,
        .description = confirm.?.description,
    });
    return .{ .documentChanges = documents.items, .changeAnnotations = annotations };
}

/// Source text of a new name: `@"..."` is validated and used as is; anything else is wrapped in
/// `@"..."` when needed: keywords, names with special characters, `_`, and names of primitive types
/// and values (`u8`, `true`; declarations and locals cannot share these names). With `is_field`,
/// primitive names are used as is: field declarations and accesses after `.` can both use them
/// (e.g. `null` and `bool` of `std.json.Value`).
fn identifierText(arena: Allocator, name: []const u8, is_field: bool) HandlerError![]const u8 {
    if (std.mem.startsWith(u8, name, "@\"")) {
        // The whole name must be a single identifier token, and the quoted part must have valid
        // escapes, be non-empty, and contain no NUL
        var tokenizer: std.zig.Tokenizer = .init(try arena.dupeSentinel(u8, name, 0));
        const token = tokenizer.next();
        if (token.tag != .identifier or token.loc.end != name.len) return error.InvalidIdentifier;
        const decoded = std.zig.string_literal.parseAlloc(arena, name[1..]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidLiteral => return error.InvalidIdentifier,
        };
        if (decoded.len == 0 or std.mem.indexOfScalar(u8, decoded, 0) != null) return error.InvalidIdentifier;
        return name;
    }
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "\"\n\r\\\x00") != null) return error.InvalidIdentifier;
    return std.fmt.allocPrint(arena, "{f}", .{std.zig.fmtIdFlags(name, .{ .allow_primitive = is_field })});
}

test "rename: source text of the new name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("greet", try identifierText(a, "greet", false));
    try std.testing.expectEqualStrings("@\"fn\"", try identifierText(a, "fn", false));
    try std.testing.expectEqualStrings("@\"a b\"", try identifierText(a, "a b", false));
    // Names of primitive types and values, and `_`: written as is, the declaration would have the
    // same name as a primitive, which is a compile error
    try std.testing.expectEqualStrings("@\"u8\"", try identifierText(a, "u8", false));
    try std.testing.expectEqualStrings("@\"true\"", try identifierText(a, "true", false));
    try std.testing.expectEqualStrings("@\"_\"", try identifierText(a, "_", false));
    // Fields may share a name with a primitive; `_` marks
    // an enum as non-exhaustive, so it is still quoted
    try std.testing.expectEqualStrings("bool", try identifierText(a, "bool", true));
    try std.testing.expectEqualStrings("@\"_\"", try identifierText(a, "_", true));
    try std.testing.expectEqualStrings("@\"x\\\"y\"", try identifierText(a, "@\"x\\\"y\"", false));
    try std.testing.expectError(error.InvalidIdentifier, identifierText(a, "@\"a\"b\"", false));
    try std.testing.expectError(error.InvalidIdentifier, identifierText(a, "@\"\"", false));
    try std.testing.expectError(error.InvalidIdentifier, identifierText(a, "", false));
    // The compiler rejects identifiers containing NUL
    try std.testing.expectError(error.InvalidIdentifier, identifierText(a, "a\x00b", false));
    try std.testing.expectError(error.InvalidIdentifier, identifierText(a, "@\"a\\x00b\"", false));
    try std.testing.expectError(error.InvalidIdentifier, identifierText(a, "@\"\\u{0}\"", false));
}

fn workspaceSymbol(server: *Server, r: *Resolver, arena: Allocator, params: types.WorkspaceSymbolParams) HandlerError!types.ResultType("workspace/symbol") {
    const scope = try server.symbolScope(r);
    const limit = blk: {
        server.config_mutex.lockUncancelable(server.io);
        defer server.config_mutex.unlock(server.io);
        break :blk server.config.workspace_symbol_limit;
    };
    const syms = try ide.workspace_symbol.search(r, scope, params.query, if (limit == 0) std.math.maxInt(usize) else limit);
    const out = try arena.alloc(types.WorkspaceSymbol, syms.len);
    var m: RangeMapper = .{ .server = server, .r = r };
    for (syms, out) |s, *o| o.* = .{
        .name = s.name,
        .kind = s.kind,
        .containerName = s.container,
        .location = .{ .Location = .{ .uri = try server.uriFor(arena, s.file), .range = try m.range(s.file, s.start, s.end) } },
    };
    return .{ .array_of_WorkspaceSymbol = out };
}

/// The code action kinds requested by the client (`context.only`)
/// include `kind`: kinds are hierarchical by `.`, so `source` includes
/// `source.organizeImports`. Any kind qualifies when none is requested.
fn wantsKind(only: ?[]const []const u8, kind: []const u8) bool {
    const list = only orelse return true;
    for (list) |k| {
        if (std.mem.eql(u8, kind, k)) return true;
        if (kind.len > k.len and std.mem.startsWith(u8, kind, k) and kind[k.len] == '.') return true;
    }
    return false;
}

fn codeAction(server: *Server, r: *Resolver, arena: Allocator, params: types.CodeActionParams) HandlerError!types.ResultType("textDocument/codeAction") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const text = (try r.ctx.get(syntax_q.SourceText, file)).text;
    const start, const end = server.rangeOffsets(text, params.range);
    const only = params.context.only;
    const import_options = server.importOptionsFor(file);
    var actions: std.ArrayList(ide.code_actions.Action) = .empty;
    if (wantsKind(only, types.CodeActionKind.QuickFix) or wantsKind(only, types.CodeActionKind.RefactorExtract) or wantsKind(only, types.CodeActionKind.RefactorRewrite))
        try actions.appendSlice(arena, try ide.code_actions.codeActions(r, file, start, end));
    // When organize imports is requested explicitly (a keybinding,
    // organizing on save), the cursor position is ignored
    if (wantsKind(only, types.CodeActionKind.SourceOrganizeImports)) {
        if (try ide.code_actions.organizeImports(r, file, start, end, import_options, only != null)) |a| try actions.append(arena, a);
    }
    const lines = try offsets.LineIndex.init(arena, text);
    const doc_uri = try server.uriFor(arena, file);
    const Item = @typeInfo(@typeInfo(types.ResultType("textDocument/codeAction")).optional.child).pointer.child;
    var out: std.ArrayList(Item) = .empty;
    for (actions.items) |a| {
        const kind = switch (a.kind) {
            .quickfix => types.CodeActionKind.QuickFix,
            .refactor_extract => types.CodeActionKind.RefactorExtract,
            .refactor_rewrite => types.CodeActionKind.RefactorRewrite,
            .source_organize_imports => types.CodeActionKind.SourceOrganizeImports,
        };
        if (!wantsKind(only, kind)) continue;
        const edits = try arena.alloc(types.TextEdit, a.edits.len);
        for (a.edits, edits) |e, *te| te.* = .{ .range = lines.range(e.start, e.end, server.encoding), .newText = e.text };
        var changes: std.json.ArrayHashMap([]const types.TextEdit) = .{};
        try changes.map.put(arena, doc_uri, edits);
        // Link the same diagnostic sent by the client (same range and message, so another
        // diagnostic on the same name, such as a naming hint, is not taken for it), so that the
        // fix shows up on the diagnostic
        const diagnostics: ?[]const types.Diagnostic = if (a.diagnostic) |d| blk: {
            const range = lines.range(d.start, d.end, server.encoding);
            for (params.context.diagnostics) |cd| {
                if (std.meta.eql(cd.range, range) and cd.message == .string and std.mem.eql(u8, cd.message.string, d.message))
                    break :blk try arena.dupe(types.Diagnostic, &.{cd});
            }
            break :blk null;
        } else null;
        try out.append(arena, .{ .CodeAction = .{
            .title = a.title,
            .kind = kind,
            .diagnostics = diagnostics,
            .isPreferred = if (a.diagnostic != null and a.preferred) true else null,
            .edit = .{ .changes = changes },
        } });
    }
    if (wantsKind(only, types.CodeActionKind.QuickFix)) {
        for (try ide.remove_param.targets(r, file, start, end)) |t| {
            const range = lines.range(t.start, t.end, server.encoding);
            if (try server.removeParamAction(r, arena, doc_uri, range, t, params.context.diagnostics)) |action| try out.append(arena, .{ .CodeAction = action });
        }
    }
    if (wantsKind(only, types.CodeActionKind.QuickFix)) if (try server.namingFor(arena, file, text)) |settings| {
        for (try ide.naming.findings(r, file, .{ .start = start, .end = end })) |f| {
            if (!settings.allows(f)) continue;
            const range = lines.range(f.start, f.end, server.encoding);
            if (try server.namingAction(r, arena, doc_uri, range, f, params.context.diagnostics)) |action| try out.append(arena, .{ .CodeAction = action });
        }
    };
    return out.items;
}

/// Data kept between `textDocument/codeAction` and `codeAction/resolve` (`CodeAction.data`) for
/// fixes whose edits are computed only after they are selected
const ResolveData = struct {
    /// Naming fix
    naming: ?struct {
        uri: []const u8,
        /// Start of the name
        line: u32,
        character: u32,
        name: []const u8,
        new_name: []const u8,
    } = null,
    /// Removing an unused parameter
    remove_param: ?struct {
        uri: []const u8,
        /// Start of the parameter name
        line: u32,
        character: u32,
        name: []const u8,
    } = null,
};

/// Rename fix for a name that violates the naming conventions, applied only when the user picks it
/// (not marked preferred). If the client supports `codeAction/resolve`, only the title and `data`
/// are given, and references are searched and conflicts checked only after it is picked; otherwise
/// the edit is computed right away. If the name cannot be renamed safely, the action carries the
/// reason when the client supports `disabled`, and is not offered otherwise.
fn namingAction(server: *Server, r: *Resolver, arena: Allocator, doc_uri: []const u8, range: types.Range, f: ide.naming.Located, client_diagnostics: []const types.Diagnostic) !?types.CodeAction {
    const what = if (f.def == .item and f.public) (if (f.rule == .field) "field " else "public ") else "";
    var action: types.CodeAction = .{
        .title = try std.fmt.allocPrint(arena, "rename {s}`{s}` to `{s}`", .{ what, f.name, f.suggestion }),
        .kind = types.CodeActionKind.QuickFix,
    };
    // Link the same hint sent by the client
    for (client_diagnostics) |d| {
        const c = d.code orelse continue;
        if (c == .string and std.mem.eql(u8, c.string, f.rule.code()) and std.meta.eql(d.range, range)) {
            action.diagnostics = try arena.dupe(types.Diagnostic, &.{d});
            break;
        }
    }
    // A conflict at the declaration needs no reference search
    if (try ide.rename.declarationConflict(r, f.def, f.suggestion)) |p| {
        if (!server.code_action_disabled) return null;
        action.disabled = .{ .reason = try server.renameProblem(r, arena, f.name, f.suggestion, p.file, p.offset, p.message) };
        return action;
    }
    if (server.code_action_resolve) {
        const inner: std.json.ObjectMap = try .init(arena, &.{ "uri", "line", "character", "name", "new_name" }, &.{
            .{ .string = doc_uri },
            .{ .integer = range.start.line },
            .{ .integer = range.start.character },
            .{ .string = f.name },
            .{ .string = f.suggestion },
        });
        action.data = .{ .object = try .init(arena, &.{"naming"}, &.{.{ .object = inner }}) };
        return action;
    }
    switch (try server.namingEdit(r, arena, f)) {
        .ok => |edit| action.edit = edit,
        .failed => |reason| {
            if (!server.code_action_disabled) return null;
            action.disabled = .{ .reason = reason };
        },
    }
    return action;
}

/// Fills in the edits of naming fixes and parameter removals; other code actions are already
/// complete from `textDocument/codeAction` and are returned unchanged
fn codeActionResolve(server: *Server, r: *Resolver, arena: Allocator, params: types.CodeAction) HandlerError!Outcome(types.CodeAction) {
    const value = params.data orelse return .{ .ok = params };
    const data = std.json.parseFromValueLeaky(ResolveData, arena, value, .{ .ignore_unknown_fields = true }) catch return .{ .ok = params };
    var action = params;
    if (data.naming) |d| {
        const at = try server.textPosition(r, arena, d.uri, .{ .line = d.line, .character = d.character }) orelse
            return .{ .failed = "cannot rename: the document is no longer available" };
        // The document may have changed between the two requests: find the name again by its position
        const found = for (try ide.naming.findings(r, at.file, .{ .start = at.offset, .end = at.offset })) |f| {
            if (f.start == at.offset and std.mem.eql(u8, f.name, d.name) and std.mem.eql(u8, f.suggestion, d.new_name)) break f;
        } else return .{ .failed = "cannot rename: the name has changed since the fix was offered" };
        switch (try server.namingEdit(r, arena, found)) {
            .ok => |edit| action.edit = edit,
            .failed => |reason| return .{ .failed = reason },
        }
    } else if (data.remove_param) |d| {
        const at = try server.textPosition(r, arena, d.uri, .{ .line = d.line, .character = d.character }) orelse
            return .{ .failed = "cannot remove parameter: the document is no longer available" };
        const found = for (try ide.remove_param.targets(r, at.file, at.offset, at.offset)) |t| {
            if (t.start == at.offset and std.mem.eql(u8, t.name, d.name)) break t;
        } else return .{ .failed = "cannot remove parameter: the parameter has changed since the fix was offered" };
        switch (try server.removeParamEdit(r, arena, found)) {
            .ok => |edit| action.edit = edit,
            .failed => |reason| return .{ .failed = reason },
        }
    }
    return .{ .ok = action };
}

/// Renames a name that violates the naming conventions to the suggested spelling. Returns only
/// complete and safe edits, as rename does (see `checkedRename`): nothing is renamed when some
/// reference cannot be confirmed, the new name conflicts with an existing one, or the name appears
/// in a string (reflection).
fn namingEdit(server: *Server, r: *Resolver, arena: Allocator, f: ide.naming.Located) !Outcome(types.WorkspaceEdit) {
    const def = f.def;
    if (try server.renameRefusal(r, .{ .def = def })) |reason| return .{ .failed = reason };
    const checked = switch (try server.checkedRename(r, arena, def, f.name, f.suggestion)) {
        .ok => |checked| checked,
        .failed => |reason| return .{ .failed = reason },
    };
    const confirm = if (f.public) try std.fmt.allocPrint(arena, "Rename public `{s}` to `{s}`", .{ f.name, f.suggestion }) else null;
    return .{ .ok = try server.renameEdit(r, arena, checked.refs, checked.text, confirm) };
}

/// Explanation of why a name cannot be renamed:
/// "cannot rename `a` to `b`: reason (file:line:column)"; only the file when the position is null
fn renameProblem(server: *Server, r: *Resolver, arena: Allocator, old: []const u8, new: []const u8, file: Vfs.FileId, offset: ?u32, reason: []const u8) ![]const u8 {
    return server.fixProblem(r, arena, try std.fmt.allocPrint(arena, "cannot rename `{s}` to `{s}`", .{ old, new }), file, offset, reason);
}

/// Why a fix cannot be applied: "<prefix>: reason (file:line:column)"; only the file when the
/// position is null
fn fixProblem(server: *Server, r: *Resolver, arena: Allocator, prefix: []const u8, file: Vfs.FileId, offset: ?u32, reason: []const u8) ![]const u8 {
    const shown = server.vfs.shownPath(try server.rootsAlloc(arena), server.vfs.path(file));
    const at = offset orelse return std.fmt.allocPrint(arena, "{s}: {s} ({s})", .{ prefix, reason, shown });
    const text = (try r.ctx.get(syntax_q.SourceText, file)).text;
    const pos = (try offsets.LineIndex.init(arena, text)).position(at, server.encoding);
    return std.fmt.allocPrint(arena, "{s}: {s} ({s}:{d}:{d})", .{ prefix, reason, shown, pos.line + 1, pos.character + 1 });
}

/// Removes an unused parameter together with the matching argument at each call site, applied
/// only when the user selects it (not marked preferred). Calls in the whole workspace have to be
/// found: when the client supports `codeAction/resolve`, only the title and `data` are given, and
/// the edits are computed after selection; otherwise they are computed right away. When the
/// parameter cannot be removed, the reason is attached if the client supports `disabled`;
/// otherwise the action is not offered.
fn removeParamAction(server: *Server, r: *Resolver, arena: Allocator, doc_uri: []const u8, range: types.Range, t: ide.remove_param.Target, client_diagnostics: []const types.Diagnostic) !?types.CodeAction {
    if (try server.renameRefusal(r, .{ .def = .{ .item = .{ .file = t.file, .item = t.item } } }) != null) return null;
    var action: types.CodeAction = .{
        .title = try std.fmt.allocPrint(arena, "remove parameter `{s}`", .{t.name}),
        .kind = types.CodeActionKind.QuickFix,
    };
    // Attach the same diagnostic sent by the client (a naming hint may share the position)
    for (client_diagnostics) |d| {
        if (std.meta.eql(d.range, range) and d.message == .string and std.mem.eql(u8, d.message.string, ide.remove_param.unused_message)) {
            action.diagnostics = try arena.dupe(types.Diagnostic, &.{d});
            break;
        }
    }
    if (server.code_action_resolve) {
        const inner: std.json.ObjectMap = try .init(arena, &.{ "uri", "line", "character", "name" }, &.{
            .{ .string = doc_uri },
            .{ .integer = range.start.line },
            .{ .integer = range.start.character },
            .{ .string = t.name },
        });
        action.data = .{ .object = try .init(arena, &.{"remove_param"}, &.{.{ .object = inner }}) };
        return action;
    }
    switch (try server.removeParamEdit(r, arena, t)) {
        .ok => |edit| action.edit = edit,
        .failed => |reason| {
            if (!server.code_action_disabled) return null;
            action.disabled = .{ .reason = reason };
        },
    }
    return action;
}

/// Removes the parameter `t` and the arguments at each call site (see `ide.remove_param.edits`).
/// When the function is pub, the edits require user confirmation: calls outside the workspace
/// are not updated.
fn removeParamEdit(server: *Server, r: *Resolver, arena: Allocator, t: ide.remove_param.Target) !Outcome(types.WorkspaceEdit) {
    const fn_name = (try r.itemTree(t.file)).items[t.item].name orelse "";
    if (try server.scopeIncompleteFor(r, .{ .def = .{ .item = .{ .file = t.file, .item = t.item } } })) |reason|
        return .{ .failed = try std.fmt.allocPrint(arena, "cannot remove parameter `{s}`: {s}", .{ t.name, reason }) };
    const prefix = try std.fmt.allocPrint(arena, "cannot remove parameter `{s}`", .{t.name});
    switch (try ide.remove_param.edits(r, t, try server.searchScope(r))) {
        .ok => |files| {
            const rules = try server.originRules(arena);
            for (files) |fe| if (!server.editable(rules, fe.file)) {
                return .{ .failed = try server.fixProblem(r, arena, prefix, fe.file, if (fe.edits.len != 0) fe.edits[0].start else null, not_editable) };
            };
            return .{ .ok = try server.workspaceEdit(r, arena, files, if (t.public) .{
                .id = "zig-analyzer.remove-param-public",
                .label = try std.fmt.allocPrint(arena, "Remove parameter `{s}` of public `{s}`", .{ t.name, fn_name }),
                .description = "code outside this workspace that calls the function is not updated",
            } else null) };
        },
        .failed => |p| return .{ .failed = try server.fixProblem(r, arena, prefix, p.file, p.offset, p.message) },
    }
}

/// Parameters of inspection requests that take a document
const DocumentParams = struct { textDocument: types.TextDocumentIdentifier };

const FileStatusResult = struct {
    path: []const u8,
    /// Origin of the file (see `origin.Origin`)
    origin: origin.Origin,
    /// Compile context (see `FileContext`)
    context: FileContext,
    open: bool,
    /// Modules the file belongs to in the module graph (given as root files; `std` for the standard
    /// library, an empty string for a generated file whose path is not known yet), in priority
    /// order; empty when the file is not in the module graph
    modules: []const []const u8,
    /// Root directories of the projects containing it, and their latest builds
    projects: []const struct { root: []const u8, last_build: ?Workspace.LastBuild },
    /// Root files of the single-file compiles that read it (or reported errors in it)
    single_file_roots: []const []const u8,
};

/// How the file is treated: origin, compile context, the modules and
/// projects it belongs to, the related single-file compiles. Used to
/// diagnose problems that users report with diagnostics or name resolution.
fn fileStatus(server: *Server, ctx: *Db.Ctx, arena: Allocator, params: DocumentParams) HandlerError!?FileStatusResult {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const open = blk: {
        server.docs_mutex.lockUncancelable(server.io);
        defer server.docs_mutex.unlock(server.io);
        break :blk server.open_docs.contains(file);
    };
    var modules: std.ArrayList([]const u8) = .empty;
    if (try ctx.get(ModuleGraph.Input, {})) |g| if (g.entry(file)) |e| {
        try modules.append(arena, server.moduleName(g, e.module));
        for (e.others) |m| try modules.append(arena, server.moduleName(g, m));
    };
    const Project = @typeInfo(@FieldType(FileStatusResult, "projects")).pointer.child;
    var projects: std.ArrayList(Project) = .empty;
    {
        const list = try server.workspaceList(arena);
        defer server.releaseList(arena, list);
        for (list) |ws| if (ws.contains(file)) try projects.append(arena, .{ .root = try arena.dupe(u8, ws.root), .last_build = ws.lastBuild() });
    }
    var roots: std.ArrayList([]const u8) = .empty;
    {
        server.single_mutex.lockUncancelable(server.io);
        defer server.single_mutex.unlock(server.io);
        for (server.single.keys(), server.single.values()) |root, *sf| {
            if (root == file or sf.inputs.contains(file) or sf.files.contains(file)) try roots.append(arena, server.vfs.path(root));
        }
    }
    return .{
        .path = server.vfs.path(file),
        .origin = server.fileOrigin(file),
        .context = server.fileContext(file),
        .open = open,
        .modules = modules.items,
        .projects = projects.items,
        .single_file_roots = roots.items,
    };
}

fn moduleName(server: *Server, g: *const ModuleGraph, module: u32) []const u8 {
    if (module == ModuleGraph.std_module) return "std";
    const root = g.modules[module].root orelse return "";
    return server.vfs.path(root);
}

/// Syntax tree of the document: indented nodes and tokens (without trivia), followed by the syntax
/// errors. Used to diagnose problems with parsing and error recovery.
fn syntaxTree(server: *Server, ctx: *Db.Ctx, arena: Allocator, params: DocumentParams) HandlerError!?[]const u8 {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const parse = try ctx.get(syntax_q.ParseFile, file);
    var out: std.Io.Writer.Allocating = .init(arena);
    parse.rootNode().dump(&out.writer, .{}) catch return error.OutOfMemory;
    for (parse.errors) |e| out.writer.print("error@{d}: {s}\n", .{ e.offset, e.message }) catch return error.OutOfMemory;
    return out.written();
}

const ModuleGraphResult = struct {
    /// Root file of the standard library
    std_root: ?[]const u8,
    modules: []const struct {
        /// Root file; null for a generated file whose path is not known yet
        root: ?[]const u8,
        /// builtin.zig generated from the module's parameters
        builtin: ?[]const u8,
        imports: []const struct { name: []const u8, module: u32 },
        /// Number of files belonging to it (including those that also belong to other modules)
        files: usize,
    },
};

/// The module graph (aggregated from the build graphs of all projects, see `updateModuleGraph`):
/// each module's root file, builtin, imports and file count. Used to diagnose problems with imports
/// and name resolution.
fn moduleGraph(server: *Server, ctx: *Db.Ctx, arena: Allocator, _: void) HandlerError!ModuleGraphResult {
    const g = try ctx.get(ModuleGraph.Input, {}) orelse return .{ .std_root = null, .modules = &.{} };
    const Item = @typeInfo(@FieldType(ModuleGraphResult, "modules")).pointer.child;
    const Import = @typeInfo(@FieldType(Item, "imports")).pointer.child;
    const out = try arena.alloc(Item, g.modules.len);
    for (g.modules, out) |m, *o| {
        const imports = try arena.alloc(Import, m.imports.len);
        // The response is serialized only after the read transaction ends, when the module graph
        // may have been replaced: copy the names out
        for (m.imports, imports) |imp, *x| x.* = .{ .name = try arena.dupe(u8, imp.name), .module = imp.module };
        o.* = .{
            .root = if (m.root) |r| server.vfs.path(r) else null,
            .builtin = if (m.builtin) |b| server.vfs.path(b) else null,
            .imports = imports,
            .files = 0,
        };
    }
    // Standard library files (`std_module`) are not counted
    for (g.files) |e| {
        if (e.module < out.len) out[e.module].files += 1;
        for (e.others) |m| if (m < out.len) {
            out[m].files += 1;
        };
    }
    return .{ .std_root = if (g.std_root) |r| server.vfs.path(r) else null, .modules = out };
}

/// Restarts all projects (same as saving build.zig): used when the build graph or compile results
/// need a manual refresh
fn reloadWorkspace(server: *Server, arena: Allocator, _: void) HandlerError!void {
    const list = try server.workspaceList(arena);
    defer server.releaseList(arena, list);
    if (list.len != 0) log.info("restarting projects on request", .{});
    for (list) |ws| server.restartWorkspace(ws, 0);
}

fn status(server: *Server, _: *Db.Ctx, arena: Allocator, _: void) HandlerError!StatusResult {
    var stats: [Db.query_types.len]za.db.QueryStats = undefined;
    const summary = server.db.stats(&stats);
    const queries = try arena.alloc(@typeInfo(@FieldType(StatusResult, "queries")).pointer.child, stats.len);
    inline for (Db.query_types, 0..) |Q, i| {
        const q = stats[i];
        queries[i] = .{
            .name = @typeName(Q),
            .executions = q.executions,
            .hits = q.hits,
            .cutoffs = q.cutoffs,
            .total_ms = za.db_report.ms(q.total_ns),
            .self_ms = za.db_report.ms(q.self_ns),
            .max_ms = za.db_report.ms(q.max_ns),
            .memos = q.memos,
            .keys = q.keys,
            .bytes = q.bytes,
            .deps = q.deps,
            .incomplete = q.incomplete,
        };
    }
    return .{
        .revision = summary.revision,
        .files = server.vfs.count(),
        .deep_verifications = summary.deep_verifications,
        .writes = summary.writes,
        .max_rss_kb = maxRssKb(),
        .intern_pool_items = server.ip.count(),
        .intern_pool_bytes = server.ip.bytes(),
        .heap_bytes = if (server.heap) |h| h.liveBytes() else 0,
        .queries = queries,
        .incomplete_causes = .{
            .cycle = summary.incomplete_causes.get(.cycle),
            .stack = summary.incomplete_causes.get(.stack),
        },
    };
}

/// Peak resident memory of the process (KB)
fn maxRssKb() u64 {
    const builtin_os = @import("builtin").os.tag;
    if (builtin_os == .windows) {
        const w = std.os.windows;
        var c: w.PROCESS.VM_COUNTERS = undefined;
        if (w.ntdll.NtQueryInformationProcess(w.GetCurrentProcess(), .VmCounters, &c, @sizeOf(w.PROCESS.VM_COUNTERS), null) != .SUCCESS) return 0;
        return c.PeakWorkingSetSize / 1024;
    }
    if (builtin_os == .wasi) return 0;
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    const rss: u64 = @intCast(@max(0, usage.maxrss));
    // macOS reports bytes, Linux reports KB
    return if (builtin_os == .macos) rss / 1024 else rss;
}

// ── Sending ──────────────────────────────────────────────────────────

fn send(server: *Server, bytes: []u8) void {
    defer server.gpa.free(bytes);
    server.out.writeMessage(bytes) catch |err| log.err("failed to write message: {t}", .{err});
}

fn sendResponse(server: *Server, id: jsonrpc.Id, result: anytype) void {
    const bytes = jsonrpc.response(server.gpa, id, result) catch return log.err("out of memory while building response", .{});
    server.send(bytes);
}

pub fn sendRequest(server: *Server, id: jsonrpc.Id, method: []const u8, params: anytype) void {
    const bytes = jsonrpc.request(server.gpa, id, method, params) catch return log.err("out of memory while building request", .{});
    server.send(bytes);
}

pub fn sendNotification(server: *Server, method: []const u8, params: anytype) void {
    const bytes = jsonrpc.notification(server.gpa, method, params) catch return log.err("out of memory while building notification", .{});
    server.send(bytes);
}

fn sendError(server: *Server, id: ?jsonrpc.Id, code: i32, message: []const u8) void {
    const bytes = jsonrpc.errorResponse(server.gpa, id, code, message) catch return log.err("out of memory while building error response", .{});
    server.send(bytes);
}

fn sendHandlerError(server: *Server, id: jsonrpc.Id, err: anyerror, canceled_by_client: bool) void {
    switch (err) {
        error.Canceled => if (canceled_by_client)
            server.sendError(id, jsonrpc.error_codes.request_cancelled, "request cancelled")
        else
            server.sendError(id, jsonrpc.error_codes.content_modified, "content modified"),
        error.InvalidParams => server.sendError(id, jsonrpc.error_codes.invalid_params, "invalid params"),
        error.InvalidIdentifier => server.sendError(id, jsonrpc.error_codes.request_failed, "new name is not a valid identifier"),
        else => server.sendError(id, jsonrpc.error_codes.internal_error, @errorName(err)),
    }
}

fn destroyArena(server: *Server, arena: *std.heap.ArenaAllocator) void {
    arena.deinit();
    server.gpa.destroy(arena);
}

test {
    // Files reached only through functions: a filter that selects only their tests analyzes no
    // function that imports them, so they are referenced here
    _ = Progress;
    _ = Config;
    _ = SemanticCache;
    _ = watch;
    _ = client_process;
    _ = origin;
    _ = workspace_files;
    _ = Workspace;
    _ = @import("Server_test.zig");
    _ = @import("semantic_tokens_test.zig");
    _ = @import("build_e2e_test.zig");
    _ = @import("compiler_e2e_test.zig");
    _ = @import("names_e2e_test.zig");
    _ = @import("refs_e2e_test.zig");
    _ = @import("naming_e2e_test.zig");
    _ = @import("remove_param_e2e_test.zig");
    _ = @import("unused_capture_e2e_test.zig");
    _ = @import("workspace_e2e_test.zig");
    _ = @import("maker_e2e_test.zig");
    _ = @import("auto_import_test.zig");
}
