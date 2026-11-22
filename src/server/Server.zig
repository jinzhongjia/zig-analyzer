//! LSP server: main loop, message dispatch, read/write separation, and cancellation.
//!
//! - Write messages (notifications such as document sync) run serially on the main loop:
//!   `beginWrite` cancels in-flight read queries, then modifies inputs.
//! - Read requests run concurrently in `group`, each holding a read transaction on the state at
//!   the time the request was received; a request interrupted by a write transaction, or whose
//!   read transaction begins after a write transaction ordered after it, is answered with
//!   `ContentModified`, and one canceled by `$/cancelRequest` with `RequestCancelled`. A request
//!   interrupted only by a write the server made on its own runs again on the new state.

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
pub const Config = @import("../Config.zig");
const SemanticCache = @import("semantic_cache.zig");
const watch = @import("watch.zig");
const client_process = @import("client_process.zig");
const workspace_files = @import("workspace_files.zig");

const log = std.log.scoped(.server);

const Server = @This();
const ClientCaps = @import("ClientCaps.zig");
const SingleFiles = @import("SingleFiles.zig");
const Rerun = @import("Rerun.zig");

/// Request handlers by feature (see `request_handlers`)
const requests = struct {
    const code_actions = @import("handlers/code_actions.zig");
    const completion = @import("handlers/completion.zig");
    const document = @import("handlers/document.zig");
    const hover = @import("handlers/hover.zig");
    const inlay_hints = @import("handlers/inlay_hints.zig");
    const inspection = @import("handlers/inspection.zig");
    const navigation = @import("handlers/navigation.zig");
    const references = @import("handlers/references.zig");
    const rename = @import("handlers/rename.zig");
    const semantic_tokens = @import("handlers/semantic_tokens.zig");
};

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
/// Test hooks that hold the server at points of its execution; empty outside tests
hooks: TestHooks = .{},

/// Background tasks: reading projects' build system protocol, publishing diagnostics. Several
/// threads submit tasks to it, and `Io.Group` does not allow submitting during an await, so it
/// is canceled only once, on exit (after all projects have stopped); at other times the `busy`
/// count tells whether it is idle.
bg_group: Io.Group = .init,
/// Diagnostic publish queue: a fixed number of workers take jobs from it in turn, so the number of
/// tasks and read transactions does not grow linearly with the number of files
publish_queue: PublishQueue = .{},
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
/// Sub-projects under the root directories (absolute, normalized): directories other than the root
/// directories, under a root directory with a build.zig, that have a build.zig and whose
/// build.zig.zon depends by `.path` on such a root directory or on another sub-project (such as
/// the examples of a library). Found by each scan (see `refreshSubProjects`). With
/// `Config.build_sub_projects`, the project of each is started on demand: when one of its files is
/// opened (see `startSubProjectFor`), or when find references or rename need it (see
/// `subProjectGap`).
sub_projects: std.ArrayList([]u8) = .empty,
/// Protects `roots`, `root_has_build` and `sub_projects`
roots_mutex: Io.Mutex = .init,

/// Single-file mode: compile results of standalone .zig files (see `FileContext.detached`)
single: SingleFiles = .{},
/// Sequence number of the last compile result taken (shared by project builds and single-file
/// compiles; see `nextCompileGeneration`)
compile_generation: std.atomic.Value(u64) = .init(0),
/// Builds requested for saves and changes on disk (`requestBuild`, counted before a project
/// instance handles the request, so that one an instance being replaced drops counts too), and
/// changes notified during a build that its completion found to differ on disk (see
/// `Workspace.deferChanges`)
build_requests: std.atomic.Value(u64) = .init(0),
/// Compile results that only repeated a completed build after the maker exited (see
/// `Workspace.repeats`): tests leave them out when they count builds
repeated_builds: std.atomic.Value(u64) = .init(0),
/// Environment variables of the process: zig child processes are started with the zig path
/// overrides applied on top of them (see `ZigEnv.withOverrides`)
environ: std.process.Environ = .empty,
/// Protects `detected_env`, `envs`, `toolchains`, and `warned`
env_mutex: Io.Mutex = .init,
/// The effective zig environment and what is derived from it (see `setToolchain`)
toolchain: std.atomic.Value(*const Toolchain) = .init(&no_toolchain),
/// Every toolchain set so far: a replaced one may still be read, so all are freed only in deinit
toolchains: std.ArrayList(*Toolchain) = .empty,
/// `childEnviron` of the toolchain's environment, set together with it: the environment of the
/// zig child processes that queries start (`zig ast-check` of live diagnostics, read through
/// `Env`, which cannot depend on `Toolchain`)
zig_environ: std.atomic.Value(?*const std.process.Environ.Map) = .init(null),
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
/// The startup task has ended, also when it gave up early (zig cannot be run). Until then the
/// zig environment and the projects may still be unknown (see `projectsPending`)
startup_ended: std.atomic.Value(bool) = .init(false),
/// Restarts in progress of instances that had not finished loading (see `projectsPending`)
first_load_restarts: std.atomic.Value(u32) = .init(0),
/// The configuration that starts the projects has been requested from the client and has not
/// arrived: whether `sema.wait_for_project` is on is not known yet (see `holdForProjects`)
config_pulling: std.atomic.Value(bool) = .init(false),
/// Protects nothing by itself: wakes the requests held by `waitForProjects`, which check under it
/// (see `wakeProjectWaiters`)
project_wait_mutex: Io.Mutex = .init,
project_wait_cond: Io.Condition = .init,
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
/// Config option `sema.callsite_seeding`, set together with `config`: read by the IDE layer
/// through `Env`, which cannot depend on `Config`
callsite_seeding: std.atomic.Value(bool) = .init(true),
/// Counting allocator (set by the executable; used for `heap_bytes` in `zig-analyzer/status`)
heap: ?*const za.util.mem.Counting = null,
/// Statistics of the release allocator (set by the executable; `allocator` in
/// `zig-analyzer/status`)
allocator_stats: ?*const fn (Allocator) Allocator.Error!za.util.PagedAllocator.Stats = null,
/// The most type information that one request or diagnostics publish has added (InternPool bytes
/// and keys of the type-information queries, see `maybeResetSema`). A reclaim waits until the
/// type information is at least twice that: one that discards what a single request needs makes
/// every following request that needs it start from nothing and exceed the limit again.
sema_peak_growth: struct {
    bytes: std.atomic.Value(usize) = .init(0),
    keys: std.atomic.Value(usize) = .init(0),
} = .{},
/// Files pending publication due to edits (see `publishDebounced`)
edits_mutex: Io.Mutex = .init,
edits: std.AutoHashMapUnmanaged(Vfs.FileId, Edit) = .empty,
/// Live diagnostics that diagnostic publishing precomputes outside the read transaction (picked up
/// by `AstCheck` through `Env`)
live_prepared: live.Prepared = undefined,
/// Background indexing (see `scheduleIndexing`)
index: Indexing = .{},
/// Scans of the workspace for source files (see `scheduleScan`)
scan: Scans = .{},
/// The current configuration (see `setConfig`): replaced as a whole and never modified, so a
/// reader sees one consistent configuration without a lock
config: std.atomic.Value(*const Config) = .init(&default_config),
/// Every configuration set so far: a replaced one may still be read, so all are freed only in
/// deinit (accessed only by `setConfig`, which the main loop serializes)
configs: std.ArrayList(*Config) = .empty,
/// What the client supports, read from `initialize` (accessed only on the main loop)
caps: ClientCaps = .{},
/// The client answered a registration of file watchers with an error: it does not watch files
watch_registration_failed: std.atomic.Value(bool) = .init(false),
/// `workspace/inlayHint/refresh`: when the inlay hints settings or results of other documents
/// change, the client is asked to request them again
inlay_refresh: Refresh = .{ .id = "zig-analyzer/inlayHintRefresh", .method = "workspace/inlayHint/refresh" },
/// ID of the next `workspace/applyEdit` request (the request IDs are `apply_edit_prefix` + this)
next_apply_edit: std.atomic.Value(u64) = .init(0),
/// `workspace/semanticTokens/refresh`
semantic_refresh: Refresh = .{ .id = "zig-analyzer/semanticTokensRefresh", .method = "workspace/semanticTokens/refresh" },
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
/// external changes. Protected by `watched_built_mutex`: besides message handling and external
/// changes (under write_mutex), a project records it when a build completes during which a
/// change was notified (see `Workspace.deferChanges`).
watched_built: std.AutoHashMapUnmanaged(Vfs.FileId, ?u64) = .empty,
watched_built_mutex: Io.Mutex = .init,
/// Background task for server-side discovery of external changes (created by `startProjects`)
watcher: ?*watch.Watcher = null,
/// Minimum polling interval (ms) when native file watching is unavailable
poll_interval_ms: std.atomic.Value(u32) = .init(1000),
/// Number of processed batches of external changes discovered by the server (comparisons with the
/// disk that find nothing changed do not count); tests wait on it (protected by `watch_mutex`;
/// `watch_cond` is broadcast when it changes)
watch_batches: u64 = 0,
watch_mutex: Io.Mutex = .init,
watch_cond: Io.Condition = .init,
/// Open documents and what is known of them
docs: Documents = .{},
/// Files currently showing non-empty diagnostics (cleared by publishing an empty list when needed;
/// protected by `docs.mutex`)
published: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty,
/// Sequence number of diagnostic computations: each computation takes one before reading state
/// such as compile results and text (see `sendDiagnostics`)
publish_seq: std.atomic.Value(u64) = .init(0),
/// What was last sent for each file (see `sendDiagnostics`)
sent: Sent = .{},

pub const State = enum { uninitialized, running, shutdown };

/// The effective zig environment and what is derived from it. Replaced as a whole and never
/// changed, so a reader sees values that belong together without taking a lock.
pub const Toolchain = struct {
    /// The detected environment with the path overrides from the configuration applied (see
    /// `applyZigPaths`); null until the environment is queried in the background after startup
    env: ?*const ZigEnv = null,
    /// The lib directory of `env` is the `lib` directory of Zig's own source tree (see
    /// `origin.Rules.zig_source_tree`)
    source_tree: bool = false,
    /// builtin.zig for files that belong to no project (native target, Debug)
    default_builtin: ?[]const u8 = null,
};

const no_toolchain: Toolchain = .{};
const default_config: Config = .{};

pub const TestHooks = if (@import("builtin").is_test) struct {
    /// Holds the read and semantic requests of one method at a point of their execution (see
    /// `TestGate`)
    request: ?*TestGate = null,
    /// While set, each scan schedules another before it is recorded as finished, as when source
    /// files keep being created during every walk, so that a scan is always pending
    rescan: std.atomic.Value(bool) = .init(false),
    /// Holds the first diagnostics result that reaches `sendDiagnostics` (its read transaction has
    /// ended, nothing of it has been sent), so that a test can change server state between
    /// computing and sending a publish
    publish: ?*OnceGate = null,
    /// Holds the reading task of a project once when the maker's stream has ended, before the exit
    /// is handled (see `Workspace.ExitPause`)
    maker_exit: std.atomic.Value(?*Workspace.ExitPause) = .init(null),
    /// Holds the first comparison of external changes with the known text (`applyFileChanges`) in
    /// its read transaction, before anything is compared, so that a test can make a write
    /// transaction wait for the lock during the comparison
    compare: ?*OnceGate = null,
    /// Holds the first comparison of a module graph update with the current module graph
    /// (`moduleGraphUnchanged`) in its read transaction, before anything is compared, so that a
    /// test can make a write transaction wait for the lock during the comparison
    graph: ?*OnceGate = null,
    /// Whether the auto-import index is built ahead of the first completion (see
    /// `requestAutoImportIndex`). Off, a completion still builds it when it needs it, but the
    /// first completion after opening has no auto-imports. Indexing the standard library takes
    /// most of the time of a short test that waits for the server to be idle: tests turn it on
    /// only when they check auto-imports.
    eager_imports: bool = false,
} else struct {};

const Indexing = struct {
    /// Counts the module graph updates: a pass indexes the module graph as of its generation or
    /// later
    rerun: Rerun = .{},
    /// Completion has run at a name that can be auto-imported: only after that is the auto-import
    /// index built. Sessions without completion (browsing, goto) do not expand the public export
    /// closure of the standard library for it.
    imports_wanted: std.atomic.Value(bool) = .init(false),
    /// Composition of the module graph when the auto-import index was last completed (see
    /// `importsBasis`; `imports_pending` until it has been completed). When it differs at
    /// completion time, auto-import is not offered and the result is marked incomplete, so the
    /// client requests again as the user types: this avoids expanding the public export closures
    /// of the standard library and the projects for new modules synchronously inside a request. It
    /// does not change when the module graph only gains or loses files (such as generated files
    /// produced by a build); new files are indexed on demand during completion.
    imports_basis: std.atomic.Value(u64) = .init(imports_pending),
    /// Highest generation whose workspace symbol index has been built (the first step of an
    /// indexing pass). Workspace symbol requests wait for the generation current when they start,
    /// so that they do not parse the bulk of the files in one read transaction, nor answer with
    /// only part of them. Protected by `mutex`; `cond` is signaled when it advances, when indexing
    /// stops, and when requests are canceled.
    symbols: u64 = 0,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
};

const Scans = struct {
    /// Counts the times the source files under the root directories may have changed
    rerun: Rerun = .{},
    /// Generation of the last finished scan (0 before the first one); it only grows, since scans
    /// run one at a time. The search scope is complete when it equals the generation of `rerun`
    /// (see `scopeIncomplete`).
    done: std.atomic.Value(u64) = .init(0),
    /// `cond` is signaled when a scan finishes, when requests are canceled, and on shutdown (see
    /// `waitScans`)
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
};

/// Every field is protected by `mutex`
const PublishQueue = struct {
    mutex: Io.Mutex = .init,
    jobs: std.ArrayList(PublishJob) = .empty,
    workers: usize = 0,
    /// Files queued or being published; see `publishFiles`
    files: std.AutoHashMapUnmanaged(Vfs.FileId, PublishState) = .empty,
};

/// Every field is protected by `mutex`
const Sent = struct {
    mutex: Io.Mutex = .init,
    /// File → sequence number of the diagnostics sent
    seq: std.AutoHashMapUnmanaged(Vfs.FileId, u64) = .empty,
    /// File → hash of the last diagnostics notification sent
    hash: std.AutoHashMapUnmanaged(Vfs.FileId, u64) = .empty,
};

/// Open documents and what is known of them; every field is protected by `mutex`
const Documents = struct {
    mutex: Io.Mutex = .init,
    /// Open documents of each file (see `OpenDoc`)
    open: std.AutoArrayHashMapUnmanaged(Vfs.FileId, OpenDoc) = .empty,
    /// Version of each open file's current document, set in the same database write as its text
    /// so that a read transaction sees the version of the text it reads
    versions: std.AutoHashMapUnmanaged(Vfs.FileId, i32) = .empty,
    /// URI most recently used by the client: still used to publish diagnostics after the document
    /// is closed (clearing old diagnostics, republishing compiler diagnostics), so that the URI is
    /// not re-encoded from the internal path. For a virtual document, the entry is deleted once
    /// its diagnostics are cleared.
    last_uris: std.AutoArrayHashMapUnmanaged(Vfs.FileId, []u8) = .empty,
    /// Real paths of open documents (see `Vfs.realPath`; null when unreachable), computed when a
    /// tool reports a path the server does not know (see `toolFile`). An entry is dropped when its
    /// document is opened or closed, and all are dropped when files are created or deleted on
    /// disk.
    real: std.AutoHashMapUnmanaged(Vfs.FileId, ?[:0]u8) = .empty,
    /// Open documents with a non-file URI whose languageId is `zig` or `zon`: whether the
    /// document is ZON, which decides the extension of its virtual path (see `documentPath`).
    /// Keys are the URIs.
    virtual_langs: std.StringHashMapUnmanaged(bool) = .empty,
};

const HeldDocument = struct {
    file: Vfs.FileId,
    /// When its text last changed (see `Db.Ctx.inputChangedAt`)
    text_changed_at: za.db.Revision,
};

const Pending = struct {
    id: jsonrpc.Id,
    cancel: std.atomic.Value(bool) = .init(false),
    /// When the request was received: it is answered on the state at that point, or with
    /// `ContentModified` when a write transaction ordered after it has begun since then (the task
    /// may start reading only after the main loop has applied later messages such as `didChange`;
    /// the server's own updates are not ordered with requests, see `Db.WriteOrder`). A workspace
    /// symbol request that waited for the index moves it to the end of the wait.
    since: Db.Mark,
    /// The document a request held by `waitForProjects` refers to, as it was when received
    document: ?HeldDocument = null,
    /// The scan generation a semantic request has waited for (see `waitScans`); 0 until it waits
    scans_awaited: u64 = 0,
    /// Type information when the task started (see `maybeResetSema`)
    sema_start: SemaUsage = .{},
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

/// Test hook: the first time the server reaches the point the gate is placed at (`hooks.publish`,
/// `hooks.compare`, `hooks.graph`), it stops there until `release` is set; later times pass
pub const OnceGate = struct {
    /// Set when the server stops at the gate
    entered: Io.Event = .unset,
    release: Io.Event = .unset,
    held: std.atomic.Value(bool) = .init(false),

    fn pass(gate: *OnceGate, io: Io) void {
        if (gate.held.swap(true, .acq_rel)) return;
        gate.entered.set(io);
        gate.release.waitUncancelable(io);
    }
};

pub const HandlerError = error{
    Canceled,
    OutOfMemory,
    InvalidParams,
    /// The new name is not a valid identifier
    InvalidIdentifier,
    /// A scan of the root directories is scheduled or running, so the search scope may lack files:
    /// the request waits for the scans scheduled so far and runs again (see `scopeIncomplete`)
    ScanPending,
    /// Sub-projects whose files may refer to the symbol are not loaded: the request starts their
    /// projects, waits until they have loaded, and runs again (see `subProjectGap`)
    SubProjectsPending,
};

/// Initializes in place: the query engine holds a pointer to `server.env`, so the Server must not
/// be moved after initialization.
pub fn init(server: *Server, io: Io, gpa: Allocator, out: *transport.Writer) Allocator.Error!void {
    server.* = .{ .io = io, .gpa = gpa, .db = undefined, .vfs = .init(io, gpa), .ip = try .init(gpa, io), .env = undefined, .out = out };
    server.live_prepared = .{ .gpa = gpa };
    server.env = .{ .vfs = &server.vfs, .ip = &server.ip, .callsite_seeding = &server.callsite_seeding, .live_prepared = &server.live_prepared, .zig_environ = &server.zig_environ };
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
    server.publish_queue.jobs.deinit(server.gpa);
    server.publish_queue.files.deinit(server.gpa);
    for (server.workspaces.items) |ws| ws.release();
    server.workspaces.deinit(server.gpa);
    server.edits.deinit(server.gpa);
    server.live_prepared.deinit();
    za.util.log.setFile(null) catch {};
    for (server.roots.items) |r| server.gpa.free(r);
    server.roots.deinit(server.gpa);
    server.root_has_build.deinit(server.gpa);
    for (server.sub_projects.items) |d| server.gpa.free(d);
    server.sub_projects.deinit(server.gpa);
    server.single.deinit(server.gpa);
    for (server.envs.items) |env| {
        env.deinit(server.gpa);
        server.gpa.destroy(env);
    }
    server.envs.deinit(server.gpa);
    for (server.toolchains.items) |t| {
        if (t.default_builtin) |p| server.gpa.free(p);
        server.gpa.destroy(t);
    }
    server.toolchains.deinit(server.gpa);
    server.builtin_targets.deinit(server.gpa);
    for (server.docs.open.values()) |*o| o.deinit(server.gpa);
    server.docs.open.deinit(server.gpa);
    server.docs.versions.deinit(server.gpa);
    for (server.docs.last_uris.values()) |u| server.gpa.free(u);
    server.docs.last_uris.deinit(server.gpa);
    server.forgetRealPath(null);
    server.docs.real.deinit(server.gpa);
    var virtual_langs = server.docs.virtual_langs.keyIterator();
    while (virtual_langs.next()) |k| server.gpa.free(k.*);
    server.docs.virtual_langs.deinit(server.gpa);
    server.published.deinit(server.gpa);
    server.sent.seq.deinit(server.gpa);
    server.sent.hash.deinit(server.gpa);
    server.semantic_cache.deinit(server.gpa);
    server.watched_built.deinit(server.gpa);
    server.progress.deinit(server.gpa);
    for (server.configs.items) |c| {
        c.deinit(server.gpa);
        server.gpa.destroy(c);
    }
    server.configs.deinit(server.gpa);
    server.pending.deinit(server.gpa);
    server.db.deinit();
    server.ip.deinit();
    server.vfs.deinit();
    server.* = undefined;
}

/// Runs the main loop until `exit` is received or the input ends, and returns the process exit
/// code. Before returning, cancels the read requests in flight (nobody reads their results
/// anymore), stops waiting for the client's replies to configuration requests (the main loop no
/// longer reads them, and a `waitIdle` request in flight waits for them), stops the build system
/// processes of all projects, and waits for the scheduled background tasks (diagnostic
/// publishing, etc.) to finish.
pub fn run(server: *Server, reader: *Io.Reader) !u8 {
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
        if (try server.processMessage(arena, body) == .exit) break;
    }
    server.cancelAllPending();
    server.abandonConfigRequests();
    server.group.await(server.io) catch {};
    server.stopWorkspaces();
    server.waitIdle();
    return if (server.state == .shutdown) 0 else 1;
}

/// Stops waiting for the client's replies to configuration requests (on shutdown, or when the
/// main loop ends)
fn abandonConfigRequests(server: *Server) void {
    server.startup_pending = false;
    server.endConfigPull();
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
        switch (err) {
            error.OutOfMemory => return err,
            error.InvalidJson => server.sendError(null, jsonrpc.error_codes.parse_error, "failed to parse JSON-RPC message"),
            error.InvalidMessage => server.sendError(null, jsonrpc.error_codes.invalid_request, "not a JSON-RPC request, notification or response"),
        }
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
                .integer => |i| _ = server.progress.handleResponse(server, i, !resp.failed),
                .string => |s| if (std.mem.startsWith(u8, s, config_request_prefix)) {
                    try server.handleConfigResponse(s, resp.result, resp.failed);
                } else if (std.mem.startsWith(u8, s, apply_edit_prefix)) {
                    requests.code_actions.applyEditResponse(server, resp.result, resp.failed);
                } else if (std.mem.eql(u8, s, server.semantic_refresh.id)) {
                    if (server.semantic_refresh.finished(server.io)) server.requestSemanticRefresh();
                } else if (std.mem.eql(u8, s, server.inlay_refresh.id)) {
                    if (server.inlay_refresh.finished(server.io)) server.requestInlayRefresh();
                } else if (resp.failed and (std.mem.eql(u8, s, register_id) or std.mem.startsWith(u8, s, watch.Watcher.registration_prefix))) {
                    server.watchRegistrationFailed();
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
        return pc.enter("request {s} {s}:{d}:{d}", .{ method, doc, @as(u64, params.position.line) + 1, @as(u64, params.position.character) + 1 });
    }
    if (@hasField(P, "range")) {
        return pc.enter("request {s} {s}:{d}:{d}", .{ method, doc, @as(u64, params.range.start.line) + 1, @as(u64, params.range.start.character) + 1 });
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

/// The command of a code action on a `build.zig.zon` dependency: runs `zig fetch` and applies the
/// hash to the manifest
pub const fetch_hash_command = "zig-analyzer/fetchDependencyHash";
/// IDs of the `workspace/applyEdit` requests (a string, so that no progress request ID is reused)
pub const apply_edit_prefix = "zig-analyzer/apply-edit/";

const request_handlers = .{
    .{ "initialize", Mode.sync, initialize },
    .{ "shutdown", Mode.sync, shutdown },
    .{ "zig-analyzer/waitIdle", Mode.background, waitIdleRequest },
    .{ "zig-analyzer/status", Mode.read, requests.inspection.status },
    .{ "zig-analyzer/fileStatus", Mode.read, requests.inspection.fileStatus },
    .{ "zig-analyzer/packages", Mode.read, requests.inspection.packagesRequest },
    .{ "zig-analyzer/syntaxTree", Mode.syntax, requests.inspection.syntaxTree },
    .{ "zig-analyzer/moduleGraph", Mode.read, requests.inspection.moduleGraph },
    .{ "zig-analyzer/reloadWorkspace", Mode.sync, reloadWorkspace },
    .{ "workspace/executeCommand", Mode.background, requests.code_actions.executeCommand },
    .{ "textDocument/formatting", Mode.syntax, requests.document.formatting },
    .{ "textDocument/documentSymbol", Mode.semantic, requests.document.documentSymbol },
    .{ "textDocument/foldingRange", Mode.syntax, requests.document.foldingRange },
    .{ "textDocument/selectionRange", Mode.syntax, requests.document.selectionRange },
    .{ "textDocument/semanticTokens/full", Mode.semantic, requests.semantic_tokens.semanticTokensFull },
    .{ "textDocument/semanticTokens/full/delta", Mode.semantic, requests.semantic_tokens.semanticTokensDelta },
    .{ "textDocument/semanticTokens/range", Mode.semantic, requests.semantic_tokens.semanticTokensRange },
    .{ "textDocument/definition", Mode.semantic, requests.navigation.definition },
    .{ "textDocument/declaration", Mode.semantic, requests.navigation.declaration },
    .{ "textDocument/typeDefinition", Mode.semantic, requests.navigation.typeDefinition },
    .{ "textDocument/completion", Mode.semantic, requests.completion.completion },
    .{ "completionItem/resolve", Mode.semantic, requests.completion.completionResolve },
    .{ "textDocument/hover", Mode.semantic, requests.hover.hover },
    .{ "textDocument/signatureHelp", Mode.semantic, requests.hover.signatureHelp },
    .{ "textDocument/inlayHint", Mode.semantic, requests.inlay_hints.inlayHint },
    .{ "textDocument/references", Mode.semantic, requests.references.references },
    .{ "textDocument/documentHighlight", Mode.semantic, requests.references.documentHighlight },
    .{ "textDocument/prepareRename", Mode.semantic, requests.rename.prepareRename },
    .{ "textDocument/rename", Mode.semantic, requests.rename.rename },
    .{ "workspace/symbol", Mode.semantic, requests.references.workspaceSymbol },
    .{ "textDocument/codeAction", Mode.semantic, requests.code_actions.codeAction },
    .{ "codeAction/resolve", Mode.semantic, requests.code_actions.codeActionResolve },
};

/// Maximum nesting depth of request params (see `processRequest`)
const max_params_depth = 128;

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
            // Results echo values from the params (`LSPAny` such as `data` and command arguments,
            // the client's diagnostics) a level or two deeper than they were, and
            // `std.json.Stringify` panics in builds with safety checks when a message nests more
            // than 256 levels: deeper params are rejected, leaving room for the levels around them
            if (jsonrpc.nestedDeeper(params_value, max_params_depth)) {
                defer server.destroyArena(arena);
                return server.sendError(id, jsonrpc.error_codes.invalid_params, "params nested too deeply");
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
                    const inputs: ?Db.Inputs = if (h[1] == .syntax) comptime Db.inputSet(&.{ FileText, database.syntax.SyntaxDialect, ide.format.ZigFmtRenderer }) else null;
                    const pending = server.addPending(a, id, inputs) catch |err| {
                        defer server.destroyArena(arena);
                        server.sendError(id, jsonrpc.error_codes.internal_error, "out of memory");
                        return err;
                    };
                    if (h[1] == .semantic and @typeInfo(Params) == .@"struct" and @hasField(Params, "textDocument")) {
                        server.rememberHeldDocument(a, pending, params.textDocument.uri);
                    }
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
    // LSP: requests starting with `$/` are answered with MethodNotFound in every state; other
    // methods get the same error for the state as known ones
    if (std.mem.startsWith(u8, method, "$/")) {
        server.sendError(id, jsonrpc.error_codes.method_not_found, "method not supported");
    } else if (server.state == .uninitialized) {
        server.sendError(id, jsonrpc.error_codes.server_not_initialized, "server not initialized");
    } else if (server.state == .shutdown) {
        server.sendError(id, jsonrpc.error_codes.invalid_request, "request not allowed in current state");
    } else {
        server.sendError(id, jsonrpc.error_codes.method_not_found, "method not supported");
    }
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
pub fn spawn(io: Io, group: *Io.Group, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) void {
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

/// A handler failed with `err`: answers the request and returns true, or returns false when the
/// handler must run again. A read interrupted only by a write the server made on its own
/// (`Db.WriteOrder.unordered`) runs again on the new state: the text the request refers to has not
/// changed, so the client has nothing to act on. When a write ordered after the request caused the
/// interruption, the next read transaction would be stale, and `ContentModified` is answered there.
/// The caller begins the next read only once that write has taken the lock (see
/// `Db.waitPendingWrites`): beginning it at once could keep the write waiting.
fn answerFailure(server: *Server, ctx: *const Db.Ctx, pending: *const Pending, err: anyerror) bool {
    const by_client = pending.cancel.load(.acquire);
    if (err == error.Canceled and !by_client and !ctx.stale and !server.isShuttingDown()) return false;
    server.sendHandlerError(pending.id, err, by_client);
    return true;
}

fn ReadTask(comptime func: anytype, comptime method: []const u8) type {
    const Params = LastParam(@TypeOf(func));
    return struct {
        fn run(server: *Server, arena: *std.heap.ArenaAllocator, pending: *Pending, params: Params) Io.Cancelable!void {
            defer server.finishRequest(arena, pending);
            pending.sema_start = server.semaUsage();
            server.testGate(method, .before_read, pending);
            while (!attempt(server, pending, params)) server.db.waitPendingWrites();
        }

        /// Returns whether the request was answered (see `answerFailure`)
        fn attempt(server: *Server, pending: *Pending, params: Params) bool {
            var attempt_arena: std.heap.ArenaAllocator = .init(server.gpa);
            defer attempt_arena.deinit();
            const a = attempt_arena.allocator();
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

            const result = func(server, &ctx, a, params) catch |err| return server.answerFailure(&ctx, pending, err);
            // The handler may have swallowed `Canceled` with a fallback value (such as
            // `catch null` in type rendering), and then the result is incomplete
            ctx.checkCanceled() catch |err| return server.answerFailure(&ctx, pending, err);
            server.sendResponse(pending.id, result);
            return true;
        }
    };
}

/// Like ReadTask, but the handler gets a Resolver
fn SemanticTask(comptime func: anytype, comptime method: []const u8) type {
    const Params = LastParam(@TypeOf(func));
    return struct {
        fn run(server: *Server, arena: *std.heap.ArenaAllocator, pending: *Pending, params: Params) Io.Cancelable!void {
            defer server.finishRequest(arena, pending);
            pending.sema_start = server.semaUsage();
            const waited_for_projects = server.waitForProjects(pending);
            if (comptime std.mem.eql(u8, method, "workspace/symbol")) {
                // After a wait, reads the state at its end: the request has no position that
                // refers to the text it was sent on, and an edit during the wait would otherwise
                // answer it with `ContentModified`
                if (server.waitSymbolIndex(pending) or waited_for_projects) pending.since = server.db.mark(pending.since.inputs);
            }
            server.testGate(method, .before_read, pending);
            var sub_projects: SubProjectWait = .{ .arena = arena.allocator() };
            while (true) switch (attempt(server, pending, params, waited_for_projects, &sub_projects)) {
                .answered => return,
                .again => server.db.waitPendingWrites(),
                // Outside the read transaction: the scan's write waits for read transactions
                .after_scans => server.waitScans(pending),
                // Likewise: loading a project writes the module graph
                .after_sub_projects => server.loadSubProjects(pending, &sub_projects),
            };
        }

        const Next = enum {
            answered,
            /// Run again once the pending writes have taken the lock (see `answerFailure`)
            again,
            /// Run again after the scans scheduled so far (see `HandlerError.ScanPending`)
            after_scans,
            /// Run again once the sub-projects recorded have loaded (see
            /// `HandlerError.SubProjectsPending`)
            after_sub_projects,
        };

        fn attempt(server: *Server, pending: *Pending, params: Params, waited_for_projects: bool, sub_projects: *SubProjectWait) Next {
            var attempt_arena: std.heap.ArenaAllocator = .init(server.gpa);
            defer attempt_arena.deinit();
            const a = attempt_arena.allocator();
            var ctx = server.db.beginReadAt(a, pending.since);
            ctx.cancel = &pending.cancel;
            defer ctx.end();
            // After a wait of seconds, writes since the request was received are common (another
            // tab opened, a file changed on disk). Its positions only refer to its own document:
            // when that text is unchanged it is answered on the state now
            if (waited_for_projects) if (pending.document) |d| {
                if (ctx.inputChangedAt(FileText, d.file) == d.text_changed_at) ctx.stale = false;
            };
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
            handler_scans_awaited = pending.scans_awaited;
            defer handler_scans_awaited = 0;
            sub_projects.dirs.clearRetainingCapacity();
            handler_sub_projects = sub_projects;
            defer handler_sub_projects = null;
            const result = func(server, &r, a, params) catch |err| return failed(server, &ctx, pending, sub_projects, err);
            // As in ReadTask: a handler that swallowed `Canceled` has an incomplete result
            ctx.checkCanceled() catch |err| return failed(server, &ctx, pending, sub_projects, err);
            if (comptime isOutcome(@TypeOf(result))) switch (result) {
                .ok => |v| server.sendResponse(pending.id, v),
                .failed => |message| server.sendError(pending.id, jsonrpc.error_codes.request_failed, message),
            } else server.sendResponse(pending.id, result);
            return .answered;
        }

        fn failed(server: *Server, ctx: *const Db.Ctx, pending: *const Pending, sub_projects: *const SubProjectWait, err: anyerror) Next {
            const go_on = !pending.cancel.load(.acquire) and !server.isShuttingDown();
            // Waits once: after the wait, the scans it waited for are enough (see `scopeIncomplete`),
            // so the scope is still incomplete only when the wait was cut short
            if (err == error.ScanPending and pending.scans_awaited == 0 and go_on) return .after_scans;
            // Likewise once: sub-projects still not loaded after the wait are left out (see
            // `subProjectGap`), which does not report them again
            if (err == error.SubProjectsPending and !sub_projects.awaited and go_on) return .after_sub_projects;
            return if (server.answerFailure(ctx, pending, err)) .answered else .again;
        }
    };
}

/// End of a read or semantic request task, after its read transaction: evicts when a query
/// exceeds its cache capacity and reclaims type information when needed (both only when no other
/// read transaction is active), then unregisters the request, which counts as in flight until
/// then
fn finishRequest(server: *Server, arena: *std.heap.ArenaAllocator, pending: *Pending) void {
    if (server.db.wantsSweep()) _ = server.db.trySweep();
    server.maybeResetSema(pending.sema_start);
    server.removePending(pending);
    server.destroyArena(arena);
}

fn testGate(server: *Server, comptime method: []const u8, point: @FieldType(TestGate, "point"), pending: *const Pending) void {
    if (!@import("builtin").is_test) return;
    const gate = server.hooks.request orelse return;
    if (gate.point == point and std.mem.eql(u8, gate.method, method)) gate.pass(server.io, pending);
}

/// Result of a handler: success, or the reason for the failure (answered with `request_failed`;
/// the client shows the reason to the user)
pub fn Outcome(comptime T: type) type {
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
    const threshold = server.config.load(.acquire).slow_request_ms;
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
        if (tree.itemOf(value.item)) |i| return w.print(":{s}", .{tree.items[i].name orelse "_"});
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
        if (result.endian != t.endian) result.endian = null;
        result.scalar_abi = result.scalar_abi.merge(t.scalar_abi);
    }
    if (seen.count() == 0) result = if (graph.default_builtin) |f| try server.builtinTarget(f) else .{};
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
/// `builtin_targets`). The caller holds `graph_mutex`.
fn builtinTarget(server: *Server, file: Vfs.FileId) Allocator.Error!za.sema.InternPool.Target {
    const text = Io.Dir.cwd().readFileAlloc(server.io, server.vfs.path(file), server.gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return server.builtin_targets.get(file) orelse .{ .pointer_bits = null, .scalar_abi = .unknown, .endian = null },
    };
    defer server.gpa.free(text);
    const result = targetOfBuiltin(text);
    try server.builtin_targets.put(server.gpa, file, result);
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
    const dialect: za.syntax.Parse.Dialect = if (server.zigEnv()) |env| .of(env.version) else .latest;
    var t = try server.targetAbi(graph);
    t.dialect = dialect;
    // Each compilation uses the target of its builtin (the root module's); when that is unknown,
    // the parameters common to all compilations. The error limit is the compilation's own.
    const targets = try server.gpa.alloc(za.sema.InternPool.Target, graph.compiles.len);
    defer server.gpa.free(targets);
    for (graph.compiles, targets) |c, *ct| {
        ct.* = if (c.builtin) |file| try server.builtinTarget(file) else t;
        ct.error_bits = za.sema.InternPool.errorBitsOf(c.error_limit);
        ct.dialect = dialect;
    }
    // Do not open a write transaction when neither the module graph nor the targets have changed:
    // every build that finishes gets here, and a write transaction cancels in-flight computations
    // and makes in-flight requests start over
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
/// the comparison. A comparison canceled by a write transaction tells nothing about the module
/// graph: it is made again once that write has taken the lock (see `Db.waitPendingWrites`).
/// Waiting under graph_mutex is safe: no write transaction takes it.
fn moduleGraphUnchanged(server: *Server, graph: *const ModuleGraph, t: za.sema.InternPool.Target, targets: []const za.sema.InternPool.Target) Allocator.Error!bool {
    while (true) {
        return server.sameModuleGraph(graph, t, targets) catch |err| switch (err) {
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
    if (!server.autoImportEnabled()) return;
    if (!server.hasOpenZigDocument()) return;
    // The module graph and the files it covers are final only after the first project load: an
    // index built earlier would be built again after the graph changes
    if (server.projectsPending()) return;
    if (server.index.imports_wanted.swap(true, .acq_rel)) return;
    server.scheduleIndexing();
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
    if (!server.index.rerun.schedule()) return;
    server.busyBegin();
    spawn(server.io, &server.bg_group, indexTask, .{server});
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
    server.scheduleIndexing();
}

fn indexTask(server: *Server) Io.Cancelable!void {
    defer server.busyEnd();
    while (true) {
        const generation = server.index.rerun.begin();
        server.indexOnce(generation) catch |err| {
            server.index.rerun.stop();
            server.wakeSymbolWaiters();
            return err;
        };
        const next = server.index.rerun.finish(generation);
        // The task stopped running at least for a moment: wake the workspace symbol requests
        // waiting for the index (see `waitSymbolIndex`)
        if (next != .again) server.wakeSymbolWaiters();
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

fn wakeSymbolWaiters(server: *Server) void {
    server.index.mutex.lockUncancelable(server.io);
    defer server.index.mutex.unlock(server.io);
    server.index.cond.broadcast(server.io);
}

/// Waits until the workspace symbol index covers the module graph as it is now: returns at once
/// when no indexing is running, and also when `pending` is canceled or indexing stops without
/// finishing (shutting down, out of memory), in which case the request computes what is missing
/// itself. Returns whether it waited.
fn waitSymbolIndex(server: *Server, pending: *const Pending) bool {
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
    spawn(server.io, &server.bg_group, scanTask, .{server});
}

fn scanTask(server: *Server) Io.Cancelable!void {
    defer server.busyEnd();
    while (true) {
        const generation = server.scan.rerun.begin();
        server.scanOnce() catch |err| switch (err) {
            error.OutOfMemory => log.err("out of memory while scanning the workspace for source files", .{}),
        };
        if (@import("builtin").is_test and server.hooks.rescan.load(.acquire)) server.scheduleScan();
        server.scan.done.store(generation, .release);
        server.wakeScanWaiters();
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
fn waitScans(server: *Server, pending: *Pending) void {
    const target = server.scan.rerun.generation.load(.acquire);
    pending.scans_awaited = target;
    server.scan.mutex.lockUncancelable(server.io);
    defer server.scan.mutex.unlock(server.io);
    while (server.scan.done.load(.acquire) < target and !pending.cancel.load(.acquire) and !server.isShuttingDown()) {
        server.scan.cond.wait(server.io, &server.scan.mutex) catch break;
    }
}

fn wakeScanWaiters(server: *Server) void {
    server.scan.mutex.lockUncancelable(server.io);
    defer server.scan.mutex.unlock(server.io);
    server.scan.cond.broadcast(server.io);
}

/// Starts the projects of the sub-projects recorded in `wait` (see `subProjectGap`) and waits until
/// none of them is loading, or until `pending` is canceled or the server shuts down. The request
/// then runs again with `wait.awaited` set.
fn loadSubProjects(server: *Server, pending: *const Pending, wait: *SubProjectWait) void {
    wait.awaited = true;
    for (wait.dirs.items) |dir| {
        log.info("{s}: loading the sub-project, whose files may refer to the symbol", .{dir});
        server.startWorkspace(dir);
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
    try server.refreshSubProjects(a, found.files);
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
    server.scheduleIndexing();
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
    if (!try server.indexBatches(files, "Indexing", false)) return;
    {
        server.index.mutex.lockUncancelable(server.io);
        defer server.index.mutex.unlock(server.io);
        server.index.symbols = @max(server.index.symbols, generation);
        server.index.cond.broadcast(server.io);
    }
    if (!(server.index.imports_wanted.load(.acquire) and server.autoImportEnabled())) return;
    // When warming up fails (out of memory), the index is not marked usable: the next completion
    // retries, instead of the closures being expanded synchronously in a request
    if (!server.indexImportRoots()) return;
    if (!try server.indexBatches(files, "Indexing for auto-import", true)) return;
    // The project-level results completion needs are also computed before the index is marked
    // usable, rather than being left to the first completion
    while (true) {
        if (server.isShuttingDown() or !server.autoImportEnabled()) return;
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
    if (server.autoImportEnabled()) server.index.imports_basis.store(basis, .release);
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

/// The auto-import index has not been fully built yet (see `index.imports_basis`)
const imports_pending = std.math.maxInt(u64);

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
        if (server.isShuttingDown() or !server.autoImportEnabled()) return false;
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
        if (!server.autoImportEnabled()) return false;
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

/// Cancels the request `id`; one waiting for the workspace symbol index, for projects or for scans
/// stops waiting
fn cancelPending(server: *Server, id: jsonrpc.Id) void {
    server.pending_mutex.lockUncancelable(server.io);
    defer server.pending_mutex.unlock(server.io);
    for (server.pending.items) |p| {
        if (p.id.eql(id)) p.cancel.store(true, .release);
    }
    server.wakeSymbolWaiters();
    server.wakeProjectWaiters();
    server.wakeScanWaiters();
}

fn cancelAllPending(server: *Server) void {
    server.pending_mutex.lockUncancelable(server.io);
    defer server.pending_mutex.unlock(server.io);
    for (server.pending.items) |p| p.cancel.store(true, .release);
    server.wakeSymbolWaiters();
    server.wakeProjectWaiters();
    server.wakeScanWaiters();
}

/// A refresh request to the client (`workspace/*/refresh`): at most one awaits the client's
/// response, and requests made meanwhile are merged into one more refresh after it
const Refresh = struct {
    /// Request id, also used to recognize the response
    id: []const u8,
    method: []const u8,
    /// The client supports this refresh
    supported: bool = false,
    mutex: Io.Mutex = .init,
    pending: bool = false,
    dirty: bool = false,

    /// Whether to send a refresh now: false when one awaits the response, which then sends one more
    fn claim(r: *Refresh, io: Io) bool {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        if (r.pending) {
            r.dirty = true;
            return false;
        }
        r.pending = true;
        return true;
    }

    /// The response arrived (or the claimed refresh was not sent); returns whether another
    /// refresh was requested meanwhile
    fn finished(r: *Refresh, io: Io) bool {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        const dirty = r.dirty;
        r.pending = false;
        r.dirty = false;
        return dirty;
    }
};

/// Results of other documents may have changed in ways the client cannot see (another document
/// edited, files changed on disk, the module graph loaded): semantic tokens and inlay hints are
/// pulled by the client, which is asked to pull both again
fn requestRefresh(server: *Server) void {
    server.requestSemanticRefresh();
    server.requestInlayRefresh();
}

fn openDocumentCount(server: *Server) usize {
    server.docs.mutex.lockUncancelable(server.io);
    defer server.docs.mutex.unlock(server.io);
    return server.docs.open.count();
}

/// Sends refresh `r` unless one awaits the response; returns whether it was sent. Edits refresh
/// other documents only after the debounce completes; indexing refreshes only after a stable round
/// ends. Changes made while waiting for the client's response are merged into the next refresh,
/// which is not sent inside any read transaction or state lock.
fn sendRefresh(server: *Server, r: *Refresh) bool {
    if (!r.supported or server.isShuttingDown() or server.openDocumentCount() == 0) return false;
    if (!r.claim(server.io)) return false;
    const bytes = jsonrpc.request(server.gpa, .{ .string = r.id }, r.method, {}) catch {
        _ = r.finished(server.io);
        log.err("out of memory while building {s}", .{r.method});
        return false;
    };
    server.send(bytes);
    return true;
}

fn requestSemanticRefresh(server: *Server) void {
    if (!server.sendRefresh(&server.semantic_refresh)) return;
    // Retire the baselines only after the refresh is written out: every result sent afterwards
    // reaches the client after the refresh. If they were retired first, a result sent in between
    // could arrive before the refresh and become the baseline for the delta request the client
    // makes after refreshing.
    server.semantic_cache.retireBaselines(server.io);
}

fn requestInlayRefresh(server: *Server) void {
    _ = server.sendRefresh(&server.inlay_refresh);
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
    const path = try server.documentPath(arena, document_uri) orelse return null;
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
    const path = try server.documentPath(arena, document_uri) orelse return null;
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
    if (try server.openDocumentAt(path)) |id| {
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
fn forgetRealPath(server: *Server, file: ?Vfs.FileId) void {
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
const OpenDoc = struct {
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

    fn deinit(o: *OpenDoc, gpa: Allocator) void {
        for (o.docs.items) |d| d.deinit(gpa);
        o.docs.deinit(gpa);
    }

    fn current(o: *const OpenDoc) *Doc {
        return &o.docs.items[o.docs.items.len - 1];
    }

    fn find(o: *const OpenDoc, document_uri: []const u8) ?usize {
        for (o.docs.items, 0..) |d, i| if (std.mem.eql(u8, d.uri, document_uri)) return i;
        return null;
    }

    /// Makes document `i` the current one
    fn makeCurrent(o: *OpenDoc, i: usize) void {
        const d = o.docs.orderedRemove(i);
        o.docs.appendAssumeCapacity(d);
    }
};

fn didOpen(server: *Server, arena: Allocator, params: types.DidOpenTextDocumentParams) !void {
    try server.setVirtualLanguage(params.textDocument.uri, params.textDocument.languageId);
    const id = try server.documentFile(arena, params.textDocument.uri) orelse return;
    {
        server.watched_built_mutex.lockUncancelable(server.io);
        defer server.watched_built_mutex.unlock(server.io);
        _ = server.watched_built.remove(id);
    }
    {
        const owned = try server.gpa.dupe(u8, params.textDocument.text);
        server.db.beginWrite();
        defer server.db.endWrite();
        server.addDocument(id, params.textDocument) catch |err| {
            server.gpa.free(owned);
            return err;
        };
        try server.db.set(FileText, id, owned, .low);
        try server.setDocVersion(id, params.textDocument.version);
        // Before a new session starts, wait for old read requests to exit; it must not inherit
        // delta baselines from the period while the document was closed or from the old session.
        server.semantic_cache.remove(server.io, server.gpa, id);
    }
    // Before publishing: a file of a sub-project then belongs to its project (loading)
    server.startSubProjectFor(server.vfs.path(id));
    server.publishFiles(&.{id}, false);
    server.publishDependents(&.{id});
    if (server.openDocumentCount() > 1) server.requestRefresh();
    server.single.compile(id);
    server.scheduleCompileSetRefresh(&.{id});
    // The auto-import index starts here so that the first completion at a name includes
    // auto-imports
    server.requestAutoImportIndex();
}

/// Records `item` as the current document of its file `id` (see `OpenDoc`); called in the write
/// transaction that sets the file's text
fn addDocument(server: *Server, id: Vfs.FileId, item: types.TextDocumentItem) Allocator.Error!void {
    const gpa = server.gpa;
    server.docs.mutex.lockUncancelable(server.io);
    defer server.docs.mutex.unlock(server.io);
    server.forgetRealPath(id);
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
fn didChange(server: *Server, arena: Allocator, params: types.DidChangeTextDocumentParams) !void {
    const path = try server.documentPath(arena, params.textDocument.uri) orelse return;
    const id = try server.vfs.lookup(path) orelse return;
    {
        server.db.beginWrite();
        defer server.db.endWrite();
        const new = try server.changeDocument(id, params) orelse return;
        try server.db.set(FileText, id, new, .low);
        try server.setDocVersion(id, params.textDocument.version);
    }
    server.publishDebounced(id);
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

fn didClose(server: *Server, arena: Allocator, params: types.DidCloseTextDocumentParams) !void {
    const id = try server.fileIdFromUri(arena, params.textDocument.uri) orelse return;
    server.clearVirtualLanguage(params.textDocument.uri);
    switch (try server.closeDocument(id, params.textDocument.uri)) {
        .last => {},
        .not_open => return,
        .others => {
            // The file stays open under its other documents, with the text of one of them
            server.clearDocument(params.textDocument.uri);
            server.publishFiles(&.{id}, false);
            server.publishDependents(&.{id});
            server.requestRefresh();
            server.scheduleCompileSetRefresh(&.{id});
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
    try server.setFileText(id, disk);
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
        server.forgetRealPath(id);
    }
    server.publishDependents(&.{id});
    server.requestRefresh();
    server.scheduleCompileSetRefresh(&.{id});
    // When a single-file mode root file was deleted from disk while open (notifications of
    // external changes skip open files), drop its compile results on close and republish the files
    // it imports as well
    if (disk == null and server.single.drop(id)) return;
    // Results that are no longer needed after closing are freed immediately, so they do not grow
    // linearly with the files opened over a long session
    server.single.releaseIfUnused(id);
    // After closing, republish from the disk contents (files in the compile set may still have
    // compiler diagnostics)
    server.publishFiles(&.{id}, true);
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
    server.forgetRealPath(id);
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

fn didSave(server: *Server, arena: Allocator, params: types.DidSaveTextDocumentParams) !void {
    const id = try server.fileIdFromUri(arena, params.textDocument.uri) orelse return;
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
        if (try server.refreshRoot(dir)) return;
    };

    // Rebuild every project that contains the file (shared modules, the standard library)
    const list = try server.workspaceList(arena);
    defer server.releaseList(arena, list);
    for (list) |ws| {
        // Outside watch mode, the maker does not reconfigure automatically: restart. Build
        // scripts and configure inputs may lie outside the project's files.
        if ((is_build_file and server.vfs.samePath(std.fs.path.dirname(path) orelse "", ws.root)) or ws.isBuildScript(id) or
            ws.changesConfigureInput(path, .changed))
        {
            server.restartWorkspace(ws, 0);
        } else if (ws.owns(id)) {
            server.requestBuild(ws);
        }
    }
    // Single-file mode: compile the file itself if it is a standalone file; root files whose last
    // compile read it or reported errors in it are recompiled as well
    server.single.recompile(&.{id}, &.{id});
}

/// Files in a project root directory whose changes require restarting the project
fn isProjectFile(base: []const u8) bool {
    for (Workspace.project_files) |name| if (std.mem.eql(u8, base, name)) return true;
    return false;
}

/// Whether the project file at `path` has the disk contents `disk` (hash; null when absent) that
/// the newest instance of the project of its directory started with (see `Workspace.startedWith`):
/// FSEvents reports writes made shortly before the stream started, which do not change what that
/// maker read
fn projectStartedWith(server: *Server, path: []const u8, disk: ?u64) bool {
    const dir = std.fs.path.dirname(path) orelse return false;
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    for (server.workspaces.items) |w| if (server.vfs.samePath(w.root, dir)) {
        return (w.successor orelse w).startedWith(std.fs.path.basename(path), disk);
    };
    return false;
}

fn didChangeWatchedFiles(server: *Server, arena: Allocator, params: types.DidChangeWatchedFilesParams) !void {
    _ = try server.applyFileChanges(arena, params.changes, .notified, null);
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
    const folders = try server.addFolderContents(arena, &events);
    // A file created or deleted may change what the paths of open documents resolve to
    for (events.values()) |kind| if (kind != .Changed) {
        server.docs.mutex.lockUncancelable(server.io);
        defer server.docs.mutex.unlock(server.io);
        server.forgetRealPath(null);
        break;
    };
    // Source files created or deleted under the root directories change what find references and
    // rename search
    const rescan = folders or try server.changesWorkspaceFiles(arena, rules, events.keys(), events.values());
    defer if (rescan) server.scheduleScan();
    for (events.keys(), events.values()) |path, kind| {
        const base = std.fs.path.basename(path);
        const dir = std.fs.path.dirname(path) orelse "";
        if (std.mem.eql(u8, base, "build.zig")) try build_zig_dirs.append(arena, dir);
        // Files never seen before have no known contents to update (a new file is loaded when it
        // is imported); project files count as changed unless the project started with these
        // contents
        const file = try server.vfs.lookup(path) orelse {
            if (source == .verified or !isProjectFile(base)) continue;
            const read = if (kind == .Deleted) null else Io.Dir.cwd().readFileAlloc(server.io, path, arena, .limited(Vfs.max_file_size)) catch |err| switch (err) {
                error.OutOfMemory, error.Canceled => |e| return e,
                else => null,
            };
            if (!server.projectStartedWith(path, if (read) |t| std.hash.Wyhash.hash(0, t) else null)) try build_files.append(arena, dir);
            continue;
        };
        const is_open = blk: {
            server.docs.mutex.lockUncancelable(server.io);
            defer server.docs.mutex.unlock(server.io);
            break :blk server.docs.open.contains(file);
        };
        if (is_open and source == .verified) continue;
        if (source == .verified) switch (server.knownTextOf(arena, file)) {
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
            else if (server.watchedBuilt(c.file)) |built|
                !std.meta.eql(built, c.disk)
            else
                !(isProjectFile(std.fs.path.basename(c.path)) and server.projectStartedWith(c.path, c.disk));
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
    // A build.zig or build.zig.zon below a root directory changed: whether its directory is a
    // sub-project may have changed (see `refreshSubProjects`)
    if (server.started) for (build_files.items) |dir| if (server.nestedUnderRoot(dir)) {
        server.scheduleScan();
        break;
    };
    const changed = changes.items.len != 0 or build_files.items.len != 0 or refreshed.items.len != 0;

    // Files whose rebuild a project in the middle of a build decides when the build completes, and
    // those a rebuild was requested for right away
    var deferred_files: std.AutoHashMapUnmanaged(Vfs.FileId, void) = .empty;
    var requested_files: std.AutoHashMapUnmanaged(Vfs.FileId, void) = .empty;
    const list = try server.workspaceList(arena);
    defer server.releaseList(arena, list);
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
            if (!started) server.restartWorkspace(ws, 0);
            continue;
        }
        var owned: std.ArrayList(Vfs.FileId) = .empty;
        for (rebuilt.items) |file| if (ws.owns(file)) try owned.append(arena, file);
        if (owned.items.len == 0) continue;
        if (source == .notified and server.deferChanges(ws, owned.items)) {
            for (owned.items) |file| try deferred_files.put(arena, file, {});
            continue;
        }
        server.requestBuild(ws);
        for (owned.items) |file| try requested_files.put(arena, file, {});
    }
    if (edited.items.len != 0) {
        server.publishFiles(edited.items, true);
        server.publishDependents(edited.items);
        server.requestRefresh();
        server.scheduleCompileSetRefresh(edited.items);
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
    const changed = server.applyFileChanges(arena, changes, source, &deferred) catch |err| blk: {
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
    return server.openDocument(file);
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
        .auto => if (server.clientWatches()) .outside_roots else .all,
        .client => .none,
        .server => .all,
    };
}

/// The client watches files: it supports registering file watchers, and has not rejected a
/// registration
pub fn clientWatches(server: *Server) bool {
    return server.caps.register_watch and !server.watch_registration_failed.load(.acquire);
}

/// Id of the registration request sent after `initialized`
const register_id = "zig-analyzer/register";

/// The client answered a registration of file watchers with an error (an error answers a
/// registration request as a whole): with `files.watcher` set to `auto`, the server watches the
/// files itself instead
fn watchRegistrationFailed(server: *Server) void {
    if (server.watch_registration_failed.swap(true, .acq_rel)) return;
    log.info("the client cannot watch files, watching them on the server instead", .{});
    server.resyncWatcher();
}

/// Rules for classifying file origins (see `origin.classify`), copied into `arena`: the zig
/// environment, the workspace root directories, and each project's local cache and dependency
/// packages (known only after the project has read its build graph). Read while holding
/// roots_mutex and then workspaces_mutex; must not be called inside a write transaction.
pub fn originRules(server: *Server, arena: Allocator) Allocator.Error!origin.Rules {
    var rules: origin.Rules = .{};
    const toolchain = server.toolchain.load(.acquire);
    if (toolchain.env) |env| {
        rules.zig_lib = try arena.dupe(u8, env.lib_dir);
        rules.global_cache = try arena.dupe(u8, env.global_cache_dir);
        rules.zig_source_tree = toolchain.source_tree;
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
pub fn inProject(server: *Server, file: Vfs.FileId) bool {
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
        if (server.caps.pull_config) server.requestConfig();
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
    const old = server.config.load(.acquire);
    if (old.same(&new)) {
        new.deinit(server.gpa);
        return;
    }
    const zig_changed = !old.sameZig(&new);
    const zig_paths_changed = !old.sameZigPaths(&new);
    const build_changed = !old.sameBuild(&new);
    const semantic_changed = old.callsite_seeding != new.callsite_seeding or old.semantic_tokens_mode != new.semantic_tokens_mode or
        old.semantic_tokens_global_var != new.semantic_tokens_global_var;
    const imports_enabled = !old.completion_auto_import and new.completion_auto_import;
    const inactive_changed = old.inactive_code != new.inactive_code;
    const naming_changed = !old.sameNaming(&new);
    const unused_changed = old.unused_enable != new.unused_enable;
    const lint_changed = !old.sameLint(&new);
    const build_was_enabled = old.build_enable;
    const sub_projects_changed = old.build_sub_projects != new.build_sub_projects;
    const watcher_changed = old.files_watcher != new.files_watcher;
    const inlay_changed = old.inlay_types != new.inlay_types or old.inlay_capture_types != new.inlay_capture_types or
        old.inlay_field_types != new.inlay_field_types or
        old.inlay_anonymous_containers != new.inlay_anonymous_containers or
        old.inlay_parameters != new.inlay_parameters or old.inlay_builtin_parameters != new.inlay_builtin_parameters or
        old.inlay_exclude_single_argument != new.inlay_exclude_single_argument or
        old.hide_redundant_param_names != new.hide_redundant_param_names or old.inlay_max_length != new.inlay_max_length or
        old.callsite_seeding != new.callsite_seeding;
    const compiler_disabled = old.compiler_diagnostics and !new.compiler_diagnostics;
    const log_file_changed = !eqlOptionalStr(old.log_file, new.log_file);
    server.applyLogging(&new, log_file_changed);
    server.applyCacheLimits(&new);
    try server.setConfig(new);
    server.wakeProjectWaiters();
    if (inactive_changed or naming_changed or unused_changed or lint_changed) server.publishOpenFiles();
    if (watcher_changed) server.resyncWatcher();

    if (zig_changed and server.started) server.showWarning("zig.path takes effect after restarting zig-analyzer");
    // Before startup, the startup phase applies them with the current configuration
    if (zig_paths_changed and server.started) {
        server.busyBegin();
        spawn(server.io, &server.bg_group, reloadZigPathsTask, .{server});
    }
    if (compiler_disabled) server.single.clear();
    if (inlay_changed) server.requestInlayRefresh();
    if (semantic_changed) server.requestSemanticRefresh();
    if (imports_enabled) {
        if (server.index.imports_wanted.load(.acquire)) server.scheduleIndexing();
        server.requestAutoImportIndex();
    }
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
        server.single.reconcile();
    }
    if (sub_projects_changed and new.build_enable) {
        // Off: the projects of sub-projects stop, and their open files get the unloaded-project
        // hint. On: those that contain open documents start.
        if (server.stopStrayProjects()) server.updateModuleGraph();
        server.startOpenSubProjects();
        server.publishOpenFiles();
        server.single.reconcile();
    }
}

/// Whether build system integration and compiler diagnostics are enabled
pub fn buildFlags(server: *Server) struct { build: bool, compiler: bool } {
    const config = server.config.load(.acquire);
    return .{ .build = config.build_enable, .compiler = config.compiler_diagnostics };
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
    server.single.reconcile();
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
    server.startOpenSubProjects();
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
fn refreshRoot(server: *Server, dir: []const u8) Allocator.Error!bool {
    // `dir` may be spelled differently from the root directory (see `Vfs.samePath`): the project
    // uses the root directory's spelling
    const root = try server.rootSpelling(dir) orelse return false;
    defer server.gpa.free(root);
    const has_build = try server.hasBuildZig(root);
    if (!server.setRootHasBuild(root, has_build)) return false;
    if (has_build) {
        log.info("{s}: build.zig was created", .{root});
        if (server.zigEnv() != null) server.startWorkspace(root);
    } else {
        log.info("{s}: build.zig was deleted", .{root});
        server.removeProject(root);
        // Its sub-projects go with it
        _ = server.stopStrayProjects();
        server.updateModuleGraph();
    }
    // Open files: single-file mode results no longer apply, or they switch to single-file mode
    server.publishOpenFiles();
    server.single.reconcile();
    return true;
}

/// Log level; with `reopen_file`, reopens the log file as configured
fn applyLogging(server: *Server, config: *const Config, reopen_file: bool) void {
    za.util.log.setLevel(config.log_level);
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
        server.endConfigPull();
    };
    if (failed) return log.info("client failed to provide configuration", .{});
    // The result corresponds one-to-one to the requested items. A null section means the client
    // cannot provide it (LSP): the current settings, from `initializationOptions` and earlier
    // pushes, stay in effect
    const section: json.Value = if (result == .array and result.array.items.len == 1) result.array.items[0] else .null;
    if (section == .null) return log.info("client provided no zig-analyzer settings, keeping the current ones", .{});
    const fresh = Config.parse(server.gpa, section) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidConfig => return server.showWarning("invalid zig-analyzer settings, keeping the previous ones"),
    };
    try server.applyConfig(fresh);
}

/// Publishes `config` as the current configuration (taking ownership of it, freed also on
/// error); `callsite_seeding` is set together with it. Only the main loop sets configurations.
fn setConfig(server: *Server, config: Config) Allocator.Error!void {
    var owned = config;
    errdefer owned.deinit(server.gpa);
    const ptr = try server.gpa.create(Config);
    errdefer server.gpa.destroy(ptr);
    try server.configs.append(server.gpa, ptr);
    ptr.* = owned;
    server.config.store(ptr, .release);
    server.callsite_seeding.store(ptr.callsite_seeding, .release);
}

fn initialized(server: *Server, arena: Allocator, _: types.InitializedParams) !void {
    if (server.initialized_received) return;
    server.initialized_received = true;
    var registrations: std.ArrayList(types.Registration) = .empty;
    if (server.caps.register_config) try registrations.append(arena, .{ .id = "zig-analyzer/didChangeConfiguration", .method = "workspace/didChangeConfiguration" });
    if (server.caps.register_watch) {
        // Changes made outside the editor (git checkout, code generation, etc.): source files,
        // build.zig.zon and project configuration files
        const options = try std.json.parseFromSliceLeaky(std.json.Value, arena,
            \\{"watchers": [{"globPattern": "**/*.zig"}, {"globPattern": "**/*.zon"}]}
        , .{});
        try registrations.append(arena, .{ .id = "zig-analyzer/didChangeWatchedFiles", .method = "workspace/didChangeWatchedFiles", .registerOptions = options });
    }
    if (registrations.items.len != 0) {
        server.sendRequest(.{ .string = register_id }, "client/registerCapability", types.RegistrationParams{ .registrations = registrations.items });
    }
    if (server.caps.pull_config) {
        // Start projects once the configuration has been pulled
        server.startup_pending = true;
        server.config_pulling.store(true, .release);
        server.requestConfig();
    } else {
        server.startProjects();
    }
}

fn startProjects(server: *Server) void {
    server.started = true;
    server.busyBegin();
    server.bg_group.concurrent(server.io, startup, .{server}) catch |err| {
        server.endStartup();
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
    defer server.endStartup();
    // The origin rules (the Zig installation and the global cache) are known from here on, also
    // when the zig environment cannot be queried
    defer server.scheduleScan();
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
    server.updateModuleGraph();
    if (server.buildFlags().build) server.startProjectsForRoots();
    // Detached files opened before startup: compile them now that the zig environment is ready and
    // projects have started loading
    server.startup_done.store(true, .release);
    // The origins of files opened before startup (the standard library, files outside the
    // workspace folders) are known only now, and naming hints depend on them; their live
    // diagnostics may also have switched to the configured zig's `zig ast-check`
    server.publishOpenFiles();
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
        // `SingleFiles.compile`), whose diagnostics these files get
        break :blk za.project.builtin.generate(gpa, io, env, &.{"build-obj"}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => null,
        };
    };

    const source_tree = if (std.fs.path.dirname(env.lib_dir)) |parent| server.hasBuildZig(parent) catch false else false;
    const change: ZigPathsChange = .{
        .env = old.env != env,
        .builtin = !eqlOptionalStr(old.default_builtin, default_builtin),
    };
    if (change.env or change.builtin or old.source_tree != source_tree) {
        server.setToolchain(.{ .env = env, .source_tree = source_tree, .default_builtin = default_builtin }) catch {
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
            server.single.mutex.lockUncancelable(server.io);
            defer server.single.mutex.unlock(server.io);
            roots.appendSlice(server.gpa, server.single.entries.keys()) catch {};
        }
        server.single.recompile(roots.items, &.{});
        // Files in the standard library and the global cache are not watched (see `watchable`):
        // the set changes with the effective directories
        server.resyncWatcher();
    }
    // The origins of files (the standard library, dependency packages in the global cache) and
    // inference results may change
    server.publishOpenFiles();
    server.single.reconcile();
}

// ── Single-file mode ─────────────────────────────────────────────────

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
    fn usesSingle(context: FileContext) bool {
        return switch (context) {
            .none, .library, .detached => true,
            .project, .project_dir, .unloaded_project => false,
        };
    }
};

pub fn fileContext(server: *Server, file: Vfs.FileId) FileContext {
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
        const sub_projects = server.config.load(.acquire).build_sub_projects;
        server.roots_mutex.lockUncancelable(server.io);
        defer server.roots_mutex.unlock(server.io);
        for (server.roots.items, server.root_has_build.items) |root, has_build| {
            if (!has_build or !server.vfs.isUnder(path, root)) continue;
            // A sub-project is loaded on demand when the setting is on (see `startSubProjectFor`);
            // when it is off, its project is not loaded, and the root's project does not resolve
            // its imports by name
            if (!sub_projects and std.mem.endsWith(u8, path, ".zig") and server.subProjectOfLocked(path) != null) return .unloaded_project;
            return .project_dir;
        }
    }
    if (!std.mem.endsWith(u8, path, ".zig")) return .none;
    if (build and server.projectDirOf(path) != null) return .unloaded_project;
    if (server.inZigLib(path)) return .library;
    return .detached;
}

/// `path` lies in the lib directory of the zig in use (`zig env`, or `zig.lib_path`). Zig compiles
/// its files as parts of its own modules (`std`, and the build runner, compiler_rt and the other
/// roots in `lib/compiler`), so they are never compiled on their own, even where they are user code
/// (Zig's own source tree, see `origin.Rules.zig_source_tree`): compiled alone, a file of `std`
/// would be in two modules ("file exists in modules 'std' and ..."). Other Zig installations are
/// not told apart from other files: only the toolchain in use says where its library is.
fn inZigLib(server: *Server, path: []const u8) bool {
    const env = server.zigEnv() orelse return false;
    return server.vfs.isUnder(path, env.lib_dir);
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
fn holdForProjects(server: *Server) bool {
    if (server.config_pulling.load(.acquire)) return true;
    return server.config.load(.acquire).wait_for_project and server.projectsPending();
}

/// Holds a semantic request back (see `holdForProjects`) until it can be answered, or until it is
/// canceled or the server shuts down. Returns whether it waited.
fn waitForProjects(server: *Server, pending: *const Pending) bool {
    server.project_wait_mutex.lockUncancelable(server.io);
    defer server.project_wait_mutex.unlock(server.io);
    var waited = false;
    while (server.holdForProjects() and !pending.cancel.load(.acquire) and !server.isShuttingDown()) {
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
    server.wakeProjectWaiters();
    // No project load may follow (single-file mode): start the auto-import index now. With
    // projects, the end of their first load calls this too.
    server.requestAutoImportIndex();
}

fn endConfigPull(server: *Server) void {
    server.config_pulling.store(false, .release);
    server.wakeProjectWaiters();
}

/// Called on the main loop when a request that refers to a document is received: if it may be held
/// back, records that document's state (see `SemanticTask`)
fn rememberHeldDocument(server: *Server, arena: Allocator, pending: *Pending, document_uri: []const u8) void {
    if (!server.holdForProjects()) return;
    const file = (server.lookupFile(arena, document_uri) catch return) orelse return;
    var ctx = server.db.beginRead(arena);
    defer ctx.end();
    pending.document = .{ .file = file, .text_changed_at = ctx.inputChangedAt(FileText, file) };
}

/// Sequence number of a compile result: project builds and single-file compiles each take one when
/// storing a result; larger is newer
pub fn nextCompileGeneration(server: *Server) u64 {
    return server.compile_generation.fetchAdd(1, .monotonic) + 1;
}

/// Starts the project for a root directory; does nothing if the root directory already has a
/// project (startup and workspace folder changes may happen concurrently), or when it is no longer
/// a root directory with a build.zig (the folder was removed, or its build.zig deleted, after the
/// caller looked it up). Does not start when the user's zig is a version whose build graphs cannot
/// be read: the build graph format is defined by the standard library.
/// Such projects get only live diagnostics (zig ast-check) and are not compiled in single-file
/// mode (files that use named modules would report missing modules).
pub fn startWorkspace(server: *Server, root: []const u8) void {
    if (server.isShuttingDown() or !server.buildFlags().build) return;
    if (server.zigEnv()) |env| if (!env.readsBuildGraph()) return;
    {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        if (!server.startsProject(root)) return;
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
    const added = !server.shutting_down and server.startsProject(root) and server.visibleFor(root) == null and
        (if (server.workspaces.append(server.gpa, ws)) |_| true else |_| false);
    if (!added) ws.stop();
    ws.placed.set(server.io);
    if (!added) ws.release();
}

/// `root` is a root directory recorded as having a build.zig
fn isProjectRoot(server: *Server, root: []const u8) bool {
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
fn subProjectOf(server: *Server, a: Allocator, path: []const u8) Allocator.Error!?[]u8 {
    server.roots_mutex.lockUncancelable(server.io);
    defer server.roots_mutex.unlock(server.io);
    const dir = server.subProjectOfLocked(path) orelse return null;
    return try a.dupe(u8, dir);
}

/// One of the files of the sub-project that contains `path` (see `subProjectOf`) was opened: starts
/// its project, while `build.sub_projects` is on (and once the zig environment is known; startup
/// starts it otherwise, see `refreshSubProjects`)
fn startSubProjectFor(server: *Server, path: []const u8) void {
    if (!server.config.load(.acquire).build_sub_projects or server.zigEnv() == null) return;
    const dir = (server.subProjectOf(server.gpa, path) catch return) orelse return;
    defer server.gpa.free(dir);
    server.startWorkspace(dir);
}

/// Starts the projects of the sub-projects that contain open documents (see `startSubProjectFor`)
fn startOpenSubProjects(server: *Server) void {
    if (!server.config.load(.acquire).build_sub_projects or server.zigEnv() == null) return;
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
        const dir = (server.subProjectOf(a, server.vfs.path(f)) catch return) orelse continue;
        for (dirs.items) |d| {
            if (std.mem.eql(u8, d, dir)) break;
        } else dirs.append(a, dir) catch return;
    }
    for (dirs.items) |d| server.startWorkspace(d);
}

/// Stops the projects that can no longer be started (see `startsProject`): those of directories
/// that are no longer sub-projects or whose root directory was removed or lost its build.zig, and
/// all of sub-projects when `build.sub_projects` is off. Returns whether it stopped any (the
/// caller updates the module graph).
fn stopStrayProjects(server: *Server) bool {
    const list = server.workspaceList(server.gpa) catch return false;
    defer server.releaseList(server.gpa, list);
    var stopped = false;
    for (list) |ws| if (!server.startsProject(ws.root)) {
        log.info("{s}: not a sub-project to load any more, stopping its project", .{ws.root});
        server.removeProject(ws.root);
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
fn refreshSubProjects(server: *Server, a: Allocator, files: []const []const u8) Allocator.Error!void {
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
        if (server.containsPath(all_roots.items, dir)) continue;
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
                if (!server.containsPath(build_roots.items, d) and !server.containsPath(eligible.items, d)) continue;
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
            if (!server.containsPath(server.sub_projects.items, d)) break false;
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
    if (server.stopStrayProjects()) server.updateModuleGraph();
    server.startOpenSubProjects();
    server.publishOpenFiles();
    server.single.reconcile();
}

/// Whether `list` has a path that is `path` (see `Vfs.samePath`)
fn containsPath(server: *Server, list: []const []const u8, path: []const u8) bool {
    for (list) |p| if (server.vfs.samePath(p, path)) return true;
    return false;
}

/// Directory `dir` is under a root directory with a build.zig, and is not a root directory itself
fn nestedUnderRoot(server: *Server, dir: []const u8) bool {
    server.roots_mutex.lockUncancelable(server.io);
    defer server.roots_mutex.unlock(server.io);
    if (server.containsPath(server.roots.items, dir)) return false;
    for (server.roots.items, server.root_has_build.items) |r, has_build| {
        if (has_build and server.vfs.isUnder(dir, r)) return true;
    }
    return false;
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
        for (server.roots.items) |r| if (server.vfs.samePath(r, normalized)) return;
        try server.root_has_build.ensureUnusedCapacity(server.gpa, 1);
        try server.roots.append(server.gpa, normalized);
        server.root_has_build.appendAssumeCapacity(has_build);
        owned = false;
    }
    if (has_build and server.zigEnv() != null) server.startWorkspace(normalized);
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
    server.removeProject(normalized);
    _ = server.stopStrayProjects();
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
    server.wakeProjectWaiters();
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
    server.single.reconcile();
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
        server.wakeProjectWaiters();
        // The new instance could not start or was discarded: no first load ends after this one
        server.requestAutoImportIndex();
    };
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
    {
        fresh.mutex.lockUncancelable(server.io);
        defer fresh.mutex.unlock(server.io);
        fresh.repeats = repeats;
    }
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
    _ = server.build_requests.fetchAdd(1, .acq_rel);
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

/// A change on disk of `files` (owned by the project of `ws`) was notified: if the project's
/// current instance is in the middle of a build, it decides whether to rebuild for them when the
/// build completes (see `Workspace.deferChanges`) and this returns true
pub fn deferChanges(server: *Server, ws: *Workspace, files: []const Vfs.FileId) bool {
    const target = blk: {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        const visible = server.visibleFor(ws.root) orelse return false;
        const t = visible.successor orelse visible;
        t.acquire();
        break :blk t;
    };
    defer target.release();
    return target.deferChanges(files);
}

/// The disk contents the latest rebuild for `file` was based on (see `watched_built`)
fn watchedBuilt(server: *Server, file: Vfs.FileId) ??u64 {
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
fn visibleFor(server: *Server, root: []const u8) ?*Workspace {
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
    server.wakeProjectWaiters();
    server.wakeScanWaiters();
    if (server.watcher) |w| w.stop();
    server.single.compiles.stop(server.io);
}

pub fn isShuttingDown(server: *Server) bool {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    return server.shutting_down;
}

pub fn zigEnv(server: *Server) ?*const ZigEnv {
    return server.toolchain.load(.acquire).env;
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
/// set computation, diagnostics publishing) to finish. Shutdown calls this while it holds
/// `write_mutex`: whoever holds the busy count must not wait for that mutex (see
/// `applyWatchedChanges`; shutdown first releases the hold of a workspace scan, see
/// `watch.Watcher.scanned`)
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

/// When `tracked`, the file's state is recorded in `publish_queue.files`,
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
        server.docs.mutex.lockUncancelable(server.io);
        defer server.docs.mutex.unlock(server.io);
        for (server.docs.open.keys()) |file| {
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
        server.publish_queue.mutex.lockUncancelable(server.io);
        defer server.publish_queue.mutex.unlock(server.io);
        for (files) |file| {
            const gop = server.publish_queue.files.getOrPut(server.gpa, file) catch {
                server.publish_queue.jobs.append(server.gpa, .{ .file = file, .clear = clear, .always = always, .tracked = false }) catch {};
                continue;
            };
            if (gop.found_existing) {
                gop.value_ptr.clear = gop.value_ptr.clear or clear;
                gop.value_ptr.always = gop.value_ptr.always or always;
                if (!gop.value_ptr.queued) gop.value_ptr.again = true;
                continue;
            }
            gop.value_ptr.* = .{ .clear = clear, .always = always };
            server.publish_queue.jobs.append(server.gpa, .{ .file = file }) catch {
                _ = server.publish_queue.files.remove(file);
            };
        }
        if (server.publish_queue.workers < max_publish_workers and server.publish_queue.jobs.items.len != 0) {
            spawn_count = @min(max_publish_workers - server.publish_queue.workers, server.publish_queue.jobs.items.len);
            server.publish_queue.workers += spawn_count;
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
        server.publish_queue.mutex.lockUncancelable(server.io);
        server.publish_queue.workers -= 1;
        server.publish_queue.mutex.unlock(server.io);
    };
    while (true) {
        const job = blk: {
            server.publish_queue.mutex.lockUncancelable(server.io);
            defer server.publish_queue.mutex.unlock(server.io);
            if (server.publish_queue.jobs.items.len == 0) {
                // Under the same lock as enqueuing: decrement the count before exiting, so that an
                // enqueuer does not see the worker still present and skip spawning a new task
                server.publish_queue.workers -= 1;
                counted = false;
                return;
            }
            var job = server.publish_queue.jobs.swapRemove(0);
            if (job.tracked) {
                const state = server.publish_queue.files.getPtr(job.file).?;
                state.queued = false;
                job.clear = state.clear;
                state.clear = false;
                job.always = state.always;
                state.always = false;
            }
            break :blk job;
        };
        const start = server.semaUsage();
        server.publishNow(job.file, job.clear, job.always, null);
        if (job.tracked) server.publishDone(job.file);
        server.maybeResetSema(start);
    }
}

/// A publish finished: requeues the file if requests arrived during the computation (handled by a
/// worker that is still running)
fn publishDone(server: *Server, file: Vfs.FileId) void {
    server.publish_queue.mutex.lockUncancelable(server.io);
    defer server.publish_queue.mutex.unlock(server.io);
    const state = server.publish_queue.files.getPtr(file).?;
    if (!state.again) {
        _ = server.publish_queue.files.remove(file);
        return;
    }
    state.again = false;
    state.queued = true;
    server.publish_queue.jobs.append(server.gpa, .{ .file = file }) catch {
        _ = server.publish_queue.files.remove(file);
    };
}

pub fn publishOpenFiles(server: *Server) void {
    server.docs.mutex.lockUncancelable(server.io);
    const files = server.gpa.dupe(Vfs.FileId, server.docs.open.keys()) catch {
        server.docs.mutex.unlock(server.io);
        return;
    };
    server.docs.mutex.unlock(server.io);
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
        const ms = server.config.load(.acquire).debounce_ms;
        if (ms > 0) try (Io.Clock.Duration{ .raw = .fromMilliseconds(ms), .clock = .awake }).sleep(server.io);
    }
    const start = server.semaUsage();
    server.publishNow(file, false, true, seen);
    server.publishDependents(&.{file});
    if (server.openDocumentCount() > 1) server.requestRefresh();
    server.refreshCompileSets(&.{file});
    server.maybeResetSema(start);
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

/// Size of the type information: the InternPool's bytes and the keys of the type-information
/// queries (see `sema_queries`)
const SemaUsage = struct { bytes: usize = 0, keys: usize = 0 };

fn semaUsage(server: *Server) SemaUsage {
    return .{ .bytes = server.ip.bytes(), .keys = server.semaKeys() };
}

/// Reclaims type information (see `resetSema`) when the InternPool exceeds
/// `sema.max_intern_pool_mb` or the type-information queries have more than `sema_reset_keys`
/// keys, and in both cases twice the most that one request or publish has added (see
/// `sema_peak_growth`). Called when a request or a diagnostics publish that started at `start`
/// finishes, outside read transactions.
fn maybeResetSema(server: *Server, start: SemaUsage) void {
    const limit = server.config.load(.acquire).max_intern_pool_mb;
    if (limit == 0) return;
    const now = server.semaUsage();
    // A reclaim in the meantime counts as no growth
    const peak_bytes = server.sema_peak_growth.bytes.fetchMax(now.bytes -| start.bytes, .monotonic);
    const peak_keys = server.sema_peak_growth.keys.fetchMax(now.keys -| start.keys, .monotonic);
    const limit_bytes = @max(@as(usize, limit) * 1024 * 1024, 2 * @max(peak_bytes, now.bytes -| start.bytes));
    const limit_keys = @max(sema_reset_keys, 2 * @max(peak_keys, now.keys -| start.keys));
    if (now.bytes < limit_bytes and now.keys < limit_keys) return;
    if (!server.db.tryBeginWrite()) return;
    defer server.db.endWrite();
    // Another thread may have reclaimed since the check above
    if (server.ip.bytes() < limit_bytes and server.semaKeysLocked() < limit_keys) return;
    server.resetSemaLocked();
}

/// When the total number of keys of the type-information queries exceeds this value, the whole
/// generation is reclaimed as well: keys and dependency edges are not freed by eviction and keep
/// growing in long sessions with the members and instances visited (about 250,000 after 40 rounds
/// over the Zig compiler source, tens of MB including the dependency edges)
const sema_reset_keys = 200_000;

/// Queries cleared by a whole-generation reclaim
const sema_queries = .{ database.sema.Infer, database.sema.LocalValue, database.sema.LocalEval, database.sema.CapturedVar, database.sema.SignatureInst, database.sema.DeclType, database.sema.CallEval, database.sema.ComptimeOnly, database.sema.ErrorSetOf, database.sema.InactiveRanges, database.sema.ZonValue, database.sema.ZonImports, database.sema.ZonResultType, database.ide_db.seed.Query, database.ide_db.seed.Instances, database.ide_db.seed.AllInstances, database.ide_db.seed.GenericCallers, database.ide_db.seed.RootCallers, database.ide_db.seed.CallsIn };

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
        server.docs.mutex.lockUncancelable(server.io);
        const wanted = server.docs.open.contains(file) or server.docs.last_uris.contains(file);
        server.docs.mutex.unlock(server.io);
        if (!wanted) return;
    }
    // Retry when canceled by a write transaction, however often: a publish triggered by a build
    // result or a file deleted on disk must not be lost because of unrelated edits. Before
    // retrying, wait for the write transaction to take the lock (see `Db.waitPendingWrites`);
    // retrying at once could keep it waiting.
    while (true) {
        if (generation) |g| if (server.editGeneration(file) != g) return;
        const prepared = server.prepareLive(file);
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        var ctx = server.db.beginRead(arena);
        // Another edit came in after preparing: prepare again outside the lock instead of running
        // AstGen inside the read transaction (while typing, AstGen may be slower than keystrokes).
        // When preparing failed, the query runs AstGen itself.
        const ready = !prepared or (server.liveReady(&ctx, file) catch |err| switch (err) {
            error.Canceled => {
                ctx.end();
                server.db.waitPendingWrites();
                continue;
            },
            error.OutOfMemory => true,
        });
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
                error.Canceled => {
                    server.db.waitPendingWrites();
                    continue;
                },
                error.OutOfMemory => return log.err("out of memory while computing diagnostics", .{}),
            }
        };
        // If the computation swallowed `Canceled`, the result is incomplete: retry as well
        const canceled = if (ctx.checkCanceled()) |_| false else |_| true;
        ctx.end();
        if (canceled) {
            server.db.waitPendingWrites();
            continue;
        }
        server.sendDiagnostics(file, params, clear, always, seq);
        return;
    }
}

/// Runs AstGen on the file's current text outside any read transaction (see `live.Prepared`):
/// AstGen does not check for cancellation, so if it ran inside a read transaction, write
/// transactions would have to wait for it to finish. A read transaction is held briefly, only to
/// read the text. Returns false when preparing failed: the query then computes the live
/// diagnostics itself (a publish waiting for a preparation that keeps failing would never finish).
/// A read canceled by a write transaction is not a failure: it returns true once the write
/// transaction has the lock, and the caller reads again.
fn prepareLive(server: *Server, file: Vfs.FileId) bool {
    if (!server.liveEligible(file)) return true;
    var arena_state: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Read = struct { text: []const u8, backend: live.Backend };
    const read: ?Read = blk: {
        var ctx = server.db.beginRead(a);
        defer ctx.end();
        const backend: live.Backend = switch (ctx.get(live.LiveBackend, {}) catch |err| switch (err) {
            error.Canceled => break :blk null,
            error.OutOfMemory => return false,
        }) {
            .in_process => .in_process,
            .subprocess => |exe| .{ .subprocess = a.dupe(u8, exe) catch return false },
        };
        const t = (ctx.get(FileText, file) catch |err| switch (err) {
            error.Canceled => break :blk null,
            error.OutOfMemory => return false,
        }) orelse return true;
        break :blk .{ .text = a.dupe(u8, t) catch return false, .backend = backend };
    };
    const r = read orelse {
        server.db.waitPendingWrites();
        return true;
    };
    const mode = live.modeOf(server.vfs.path(file));
    if (!server.live_prepared.claim(server.io, file, live.Prepared.hash(r.text, mode, r.backend))) return true;
    const result = live.checkWith(server.gpa, server.io, r.backend, server.zig_environ.load(.acquire), r.text, mode) catch return false;
    if (!result.complete) {
        result.destroy(server.gpa);
        return false;
    }
    server.live_prepared.put(server.io, file, r.text, mode, r.backend, result) catch return false;
    return true;
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
/// the last change. Comparing and writing both happen inside `sent.mutex`, so the
/// order of writes matches the comparisons; serialization happens outside the lock.
/// `clear`: sent even when empty for a file that is not showing diagnostics; `always`: sent even
/// when it is the same as the last result sent for the file.
fn sendDiagnostics(server: *Server, file: Vfs.FileId, params: types.PublishDiagnosticsParams, clear: bool, always: bool, seq: u64) void {
    if (@import("builtin").is_test) if (server.hooks.publish) |gate| gate.pass(server.io);
    const bytes = jsonrpc.notification(server.gpa, "textDocument/publishDiagnostics", params) catch return log.err("out of memory while building notification", .{});
    var sent = false;
    defer if (!sent) server.gpa.free(bytes);
    const hash = std.hash.Wyhash.hash(0, bytes);
    server.sent.mutex.lockUncancelable(server.io);
    defer server.sent.mutex.unlock(server.io);
    if (server.sent.seq.getOrPut(server.gpa, file)) |gop| {
        if (gop.found_existing and gop.value_ptr.* > seq) return;
        gop.value_ptr.* = seq;
    } else |_| {}
    if (!always) if (server.sent.hash.get(file)) |last| if (last == hash) return;
    // The other documents of the file, when it has several or `params.uri` is no longer one of
    // them (see `OpenDoc`): they get the same diagnostics. Rare, so they are serialized here.
    var others: std.ArrayList([]u8) = .empty;
    defer {
        for (others.items) |u| server.gpa.free(u);
        others.deinit(server.gpa);
    }
    var to_params = true;
    {
        server.docs.mutex.lockUncancelable(server.io);
        defer server.docs.mutex.unlock(server.io);
        const was_published = server.published.contains(file);
        if (params.diagnostics.len == 0) {
            // A file that never had diagnostics shown needs no empty list (except open files: the
            // client may still be showing old results)
            if (!was_published and !clear and !server.docs.open.contains(file)) return;
            _ = server.published.swapRemove(file);
        } else {
            server.published.put(server.gpa, file, {}) catch {};
        }
        if (server.docs.open.getPtr(file)) |open| if (open.docs.items.len > 1 or open.find(params.uri) == null) {
            to_params = open.find(params.uri) != null;
            for (open.docs.items) |d| if (!std.mem.eql(u8, d.uri, params.uri)) {
                const u = server.gpa.dupe(u8, d.uri) catch continue;
                others.append(server.gpa, u) catch server.gpa.free(u);
            };
        };
    }
    sent = true;
    server.sent.hash.put(server.gpa, file, hash) catch {
        _ = server.sent.hash.remove(file);
    };
    if (to_params) server.send(bytes) else server.gpa.free(bytes);
    for (others.items) |u| {
        var copy = params;
        copy.uri = u;
        copy.version = null;
        server.send(jsonrpc.notification(server.gpa, "textDocument/publishDiagnostics", copy) catch {
            log.err("out of memory while building notification", .{});
            continue;
        });
    }
    // The clearing for the closed virtual document has been sent: its URI is no longer needed. A
    // result computed before the close and sent after it clears nothing, and the clearing that the
    // close requested still needs the URI
    if (params.diagnostics.len == 0 and isVirtual(server.vfs.path(file))) {
        server.docs.mutex.lockUncancelable(server.io);
        defer server.docs.mutex.unlock(server.io);
        if (!server.docs.open.contains(file)) if (server.docs.last_uris.fetchSwapRemove(file)) |kv| server.gpa.free(kv.value);
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
        server.publish_queue.mutex.lockUncancelable(server.io);
        defer server.publish_queue.mutex.unlock(server.io);
        try std.testing.expect(server.publish_queue.workers <= max_publish_workers);
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
    try std.testing.expectEqual(0, server.publish_queue.files.count());
}

// Prevents a publish from giving up after a fixed number of attempts interrupted by write
// transactions: the clearing of a file deleted on disk and closed was lost, and its compile errors
// stayed published
test "publishFiles: a publish interrupted by write transactions again and again still sends its result" {
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var writer: transport.Writer = .{ .io = std.testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(std.testing.io, gpa, &writer);
    defer server.deinit();
    const native = @import("../util/test_path.zig").native;
    const file = try server.vfs.intern(native("/tmp/zig-analyzer-publish-interrupted.zig"));
    {
        server.db.beginWrite();
        defer server.db.endWrite();
        try server.db.set(FileText, file, try gpa.dupe(u8, "fn f() void {\n    var x = 1;\n}\n"), .low);
    }
    server.publishFiles(&.{file}, true);
    // Write transactions follow each other for a while, canceling the reads the publish begins
    // meanwhile
    const t0 = Io.Clock.awake.now(server.io);
    var writes: usize = 0;
    while (writes < 1000 or t0.durationTo(Io.Clock.awake.now(server.io)).nanoseconds < 200 * std.time.ns_per_ms) : (writes += 1) {
        server.db.beginWrite();
        server.db.endWrite();
    }
    server.waitIdle();
    var reader: Io.Reader = .fixed(out.written());
    var diagnostics: std.ArrayList(usize) = .empty;
    defer diagnostics.deinit(gpa);
    while (transport.readMessage(&reader, gpa)) |body| {
        defer gpa.free(body);
        const msg = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
        defer msg.deinit();
        const method = msg.value.object.get("method") orelse continue;
        if (!std.mem.eql(u8, method.string, "textDocument/publishDiagnostics")) continue;
        try diagnostics.append(gpa, msg.value.object.get("params").?.object.get("diagnostics").?.array.items.len);
    } else |err| if (err != error.EndOfStream) return err;
    try std.testing.expectEqual(1, diagnostics.items.len);
    try std.testing.expect(diagnostics.items[0] > 0);
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
    try server.addRoot(root_uri);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig", .data = "" });
    const variant = try std.ascii.allocUpperString(gpa, root);
    defer gpa.free(variant);
    try std.testing.expect(!std.mem.eql(u8, variant, root));
    try std.testing.expect(try server.refreshRoot(variant));
    try std.testing.expect(server.root_has_build.items[0]);
    try std.testing.expect(!try server.refreshRoot(variant));
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
    try std.testing.expect(try server.toolFile(real_b) != opened);
    var doc: OpenDoc = .{};
    try doc.docs.append(gpa, .{ .uri = try gpa.dupe(u8, "file:///link/a.zig"), .version = 1 });
    try server.docs.open.put(gpa, opened, doc);
    try std.testing.expectEqual(opened, try server.toolFile(real_a));
    try std.testing.expectEqual(opened, (try server.vfs.lookup(real_a)).?);
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ dir, "link/a.zig" }), server.vfs.path(opened));
    // Known paths are not resolved on disk again; a path no open document names stays apart
    try std.testing.expectEqual(1, server.docs.real.count());
    try std.testing.expect(try server.toolFile(try std.fs.path.join(a, &.{ dir, "real/missing.zig" })) != opened);
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
    try server.setToolchain(.{ .default_builtin = try server.gpa.dupe(u8, "/zig-analyzer-test/builtin.zig") });
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
    try server.setToolchain(.{ .default_builtin = try server.gpa.dupe(u8, "/zig-analyzer-test/builtin.zig") });
    try server.updateModuleGraphInner();
    try std.testing.expectEqual(writes + 1, server.db.writes.load(.monotonic));
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
            s.scanOnce() catch |err| std.debug.panic("scan failed: {t}", .{err});
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

pub fn uriFor(server: *Server, arena: Allocator, file: Vfs.FileId) Allocator.Error![]const u8 {
    server.docs.mutex.lockUncancelable(server.io);
    defer server.docs.mutex.unlock(server.io);
    if (server.docs.open.getPtr(file)) |open| return arena.dupe(u8, open.current().uri);
    if (server.docs.last_uris.get(file)) |u| return arena.dupe(u8, u);
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
        // With `FileText`, the `SourceText` is that text, whose line table is cached
        const line_starts: ?[]const u32 = if (loaded != null) self.ctx.get(syntax_q.LineStarts, file.?) catch null else null;
        return .{ .uri = u, .text = text, .line_starts = line_starts };
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
        server.single.mutex.lockUncancelable(server.io);
        defer server.single.mutex.unlock(server.io);
        for (server.single.entries.values()) |*sf| if (sf.files.get(file)) |fr| {
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
    // An open `.zon` file always: what makes it valid ZON does not depend on any build
    const is_zon = live.modeOf(server.vfs.path(file)) == .zon;
    if (text != null and (server.liveEligible(file) or (is_zon and server.isOpen(server.vfs.path(file))))) live_result = try ctx.get(live.AstCheck, file);

    // Compiler diagnostics: errors in an imported file are
    // reported by the project or root file that compiles it
    var other: OtherFiles = .{ .server = server, .ctx = ctx };
    defer other.release();
    const fr = try server.compilerResult(arena, file, &other);
    const current = text orelse if (fr) |r| r.base_text else "";
    // With `FileText`, the `SourceText` is that text, whose line table is cached
    const lines = if (text != null) try sourceLines(ctx, file) else try offsets.LineIndex.init(arena, current);
    var diags = try compiler.merge(arena, .{
        .text = current,
        .lines = lines,
        .encoding = server.encoding,
        .uri = document_uri,
        .live = live_result,
        .compiler = fr,
        .other_file = OtherFiles.get,
        .other_ctx = &other,
    });
    if (text != null) if (server.wantsInactiveCode(file)) {
        diags = try server.appendInactiveCode(ctx, arena, file, lines, diags);
    };
    if (text) |t| if (try server.namingFor(arena, file, t)) |settings| {
        diags = try server.appendNaming(ctx, arena, file, lines, settings, diags);
    };
    if (text) |t| if (server.unusedFor(file, t)) {
        diags = try appendUnused(server, ctx, arena, file, lines, diags);
    };
    if (text) |t| if (server.lintFor(file, t)) |rules| {
        diags = try appendLint(server, ctx, arena, file, lines, rules, diags);
    };
    if (text != null) diags = try server.appendUnloadedProjectHint(arena, file, lines, diags);
    if (text != null) if (is_zon and std.mem.eql(u8, std.fs.path.basename(server.vfs.path(file)), Config.project_file)) {
        diags = try server.appendProjectConfigProblems(arena, lines, diags);
    };
    if (text != null) diags = try filterSuppressed(ctx, arena, file, lines, diags);
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
        const gop = try server.single.entries.getOrPut(gpa, try server.vfs.intern(try std.fs.path.join(arena, &.{ dir, root })));
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

/// The problems `zig-analyzer.zon` has beyond its syntax, which is reported as for any `.zon` file
fn appendProjectConfigProblems(server: *Server, arena: Allocator, lines: offsets.LineIndex, diags: []const types.Diagnostic) ![]const types.Diagnostic {
    if (diags.len > 0) return diags;
    const text = lines.text;
    const problems = try Config.projectProblems(server.gpa, arena, text);
    const out = try arena.alloc(types.Diagnostic, problems.len);
    for (problems, out) |p, *o| {
        const start: u32 = @min(p.start orelse 0, @as(u32, @intCast(text.len)));
        var end = start;
        while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_' or text[end] == '.')) end += 1;
        if (end == start and end < text.len) end += 1;
        o.* = .{
            .range = lines.range(start, end, server.encoding),
            .severity = if (p.fatal) .Error else .Warning,
            .source = "zig-analyzer",
            .message = .{ .string = if (p.fatal) try std.fmt.allocPrint(arena, "{s}; the file is ignored", .{p.message}) else p.message },
        };
    }
    return out;
}

/// An open file that belongs to a project that is not loaded (see `FileContext.unloaded_project`):
/// a hint to add the project directory to the workspace. Like rust-analyzer's hint for files that
/// belong to no crate, it is a Hint marking only the first few characters of the file. No hint
/// before startup finishes or while projects are loading for the first time: the file may later
/// show up in a project's module graph (modules added by path).
fn appendUnloadedProjectHint(server: *Server, arena: Allocator, file: Vfs.FileId, lines: offsets.LineIndex, diags: []const types.Diagnostic) ![]const types.Diagnostic {
    const path = server.vfs.path(file);
    if (!server.isOpen(path) or !server.startup_done.load(.acquire) or server.projectsLoading()) return diags;
    if (server.fileContext(file) != .unloaded_project) return diags;
    const sub_project = try server.subProjectOf(arena, path);
    const dir = sub_project orelse server.projectDirOf(path) orelse return diags;
    const text = lines.text;
    var end: usize = 0;
    var chars: usize = 0;
    while (chars < 3 and end < text.len and text[end] != '\n' and text[end] != '\r') : (chars += 1) {
        end += std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
    }
    const out = try arena.alloc(types.Diagnostic, diags.len + 1);
    @memcpy(out[0..diags.len], diags);
    out[diags.len] = .{
        .range = lines.range(0, @intCast(@min(end, text.len)), server.encoding),
        .severity = .Hint,
        .source = "zig-analyzer",
        .message = .{ .string = if (sub_project != null)
            try std.fmt.allocPrint(arena, "this file belongs to the sub-project at {s}, which is not loaded since `build.sub_projects` is off: it is not compiled " ++
                "on its own, since only the project's build can resolve its imports by name; turn the setting on, or add the directory to the workspace folders, to load the project", .{dir})
        else
            try std.fmt.allocPrint(arena, "this file belongs to the project at {s}, which is not loaded: it is not compiled on its own, " ++
                "since only the project's build can resolve its imports by name; add the directory to the workspace folders to load the project", .{dir}) },
    };
    return out;
}

/// Inactive code is shown only for open files: it requires inferring all members of the file
fn wantsInactiveCode(server: *Server, file: Vfs.FileId) bool {
    if (!server.config.load(.acquire).inactive_code) return false;
    server.docs.mutex.lockUncancelable(server.io);
    defer server.docs.mutex.unlock(server.io);
    return server.docs.open.contains(file);
}

/// Code that is not compiled under the current build configuration (branches known at comptime not
/// to execute): hints tagged `Unnecessary`, which editors show faded
fn appendInactiveCode(server: *Server, ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId, lines: offsets.LineIndex, diags: []const types.Diagnostic) ![]const types.Diagnostic {
    var r: Resolver = .{ .ctx = ctx, .arena = arena };
    const ranges = try za.ide.inactive.ranges(&r, file);
    if (ranges.len == 0) return diags;
    const out = try arena.alloc(types.Diagnostic, diags.len + ranges.len);
    @memcpy(out[0..diags.len], diags);
    var n = diags.len;
    for (ranges) |x| {
        // Inference may mark as inactive code in which the compile behind the diagnostics reports
        // errors (AstGen checks every branch, and a file can be compiled in several
        // configurations): no hint is published where it overlaps a compiler diagnostic, so that
        // the same code is not both an error and inactive
        if (conflictsWithCompilerError(diags, lines, server.encoding, x)) continue;
        out[n] = .{
            .range = lines.range(x.start, x.end, server.encoding),
            .severity = .Hint,
            .source = ide.hints.source,
            .code = .{ .string = ide.hints.inactive_code },
            .message = .{ .string = "code is inactive: a comptime condition excludes it under the current build configuration" },
            .tags = &.{.Unnecessary},
        };
        n += 1;
    }
    return out[0..n];
}

fn conflictsWithCompilerError(diags: []const types.Diagnostic, lines: offsets.LineIndex, enc: offsets.Encoding, range: za.ide.inactive.Range) bool {
    for (diags) |d| {
        const source = d.source orelse continue;
        if (!std.mem.eql(u8, source, "zig")) continue;
        const start: u32 = @intCast(lines.offsetOf(d.range.start, enc));
        const end: u32 = @intCast(lines.offsetOf(d.range.end, enc));
        if (range.start < end and start < range.end) return true;
    }
    return false;
}

/// Naming check settings for one file: the client's configuration, overridden by the entries
/// present in the `zig-analyzer.zon` of the project containing the file
const NamingSettings = struct {
    ignore: []const []const u8,
    rules: Config.NamingRules,

    pub fn allows(s: NamingSettings, f: ide.naming.Located) bool {
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
pub fn namingFor(server: *Server, arena: Allocator, file: Vfs.FileId, text: []const u8) Allocator.Error!?NamingSettings {
    if (!hintsEligible(server, file, text)) return null;
    const path = server.vfs.path(file);
    const config = server.config.load(.acquire);
    var enable = config.naming_enable;
    var ignore = config.naming_ignore;
    var exclude = config.naming_exclude;
    var rules = config.naming_rules;
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
    return .{ .ignore = ignore, .rules = rules };
}

/// Whether the file gets analyzer-owned hints: open user code (or a file outside the workspace),
/// not generated
fn hintsEligible(server: *Server, file: Vfs.FileId, text: []const u8) bool {
    {
        server.docs.mutex.lockUncancelable(server.io);
        defer server.docs.mutex.unlock(server.io);
        if (!server.docs.open.contains(file)) return false;
    }
    switch (server.fileOrigin(file)) {
        .virtual, .user, .outside => {},
        .zig_lib, .generated, .package, .other => return false,
    }
    return !ide.naming.isGenerated(text);
}

/// Whether the file gets unused-declaration hints: the setting from the client or the project of
/// the file, for open user code that is not generated
fn unusedFor(server: *Server, file: Vfs.FileId, text: []const u8) bool {
    if (!hintsEligible(server, file, text)) return false;
    const path = server.vfs.path(file);
    var enable = server.config.load(.acquire).unused_enable;
    {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        // For nested projects, take the innermost one
        var best: ?*Workspace = null;
        for (server.workspaces.items) |ws| {
            if (server.vfs.isUnder(path, ws.root) and (best == null or ws.root.len > best.?.root.len)) best = ws;
        }
        if (best) |ws| if (ws.project) |*p| {
            if (p.isSet("unused_enable")) enable = p.unused_enable;
        };
    }
    return enable;
}

/// The lint rules the file gets, null when lint hints are off for it: the setting from the client
/// or the project of the file, for open user code that is not generated
pub fn lintFor(server: *Server, file: Vfs.FileId, text: []const u8) ?Config.LintRules {
    if (!hintsEligible(server, file, text)) return null;
    const path = server.vfs.path(file);
    const config = server.config.load(.acquire);
    var enable = config.lint_enable;
    var rules = config.lint_rules;
    {
        server.workspaces_mutex.lockUncancelable(server.io);
        defer server.workspaces_mutex.unlock(server.io);
        // For nested projects, take the innermost one
        var best: ?*Workspace = null;
        for (server.workspaces.items) |ws| {
            if (server.vfs.isUnder(path, ws.root) and (best == null or ws.root.len > best.?.root.len)) best = ws;
        }
        if (best) |ws| if (ws.project) |*p| {
            if (p.isSet("lint_enable")) enable = p.lint_enable;
            if (p.isSet("lint_rules")) rules = p.lint_rules;
        };
    }
    return if (enable) rules else null;
}

pub fn lintAllows(rules: Config.LintRules, rule: ide.lint.Rule) bool {
    return switch (rule) {
        inline else => |r| @field(rules, @tagName(r)),
    };
}

fn dupeStrings(arena: Allocator, list: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, list.len);
    for (list, out) |src, *dst| dst.* = try arena.dupe(u8, src);
    return out;
}

/// Layout rules of the import block for `file`: the client's settings, overridden by the
/// `zig-analyzer.zon` of the project containing the file (the innermost one when nested)
pub fn importOptionsFor(server: *Server, file: Vfs.FileId) ImportOptions {
    var options = server.config.load(.acquire).importOptions();
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
pub fn rootsAlloc(server: *Server, arena: Allocator) Allocator.Error![]const []const u8 {
    server.roots_mutex.lockUncancelable(server.io);
    defer server.roots_mutex.unlock(server.io);
    return dupeStrings(arena, server.roots.items);
}

/// Names that violate the naming conventions (see `naming`): low-severity hints with code
/// `naming.<rule>` and a link to the official rules
fn appendNaming(server: *Server, ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId, lines: offsets.LineIndex, settings: NamingSettings, diags: []const types.Diagnostic) ![]const types.Diagnostic {
    var r: Resolver = .{ .ctx = ctx, .arena = arena };
    const found = try ide.naming.findings(&r, file, null);
    if (found.len == 0) return diags;
    const guide_url = ide.naming.guideUrl(try ctx.get(database.syntax.SyntaxDialect, {}));
    var out: std.ArrayList(types.Diagnostic) = .empty;
    try out.appendSlice(arena, diags);
    for (found) |f| {
        if (!settings.allows(f)) continue;
        try out.append(arena, .{
            .range = lines.range(f.start, f.end, server.encoding),
            .severity = .Hint,
            .code = .{ .string = f.rule.code() },
            .codeDescription = .{ .href = guide_url },
            .source = ide.hints.source,
            .message = .{ .string = try ide.naming.message(arena, f) },
        });
    }
    return out.items;
}

/// Private declarations that no code in the file uses: hints tagged `Unnecessary`, which editors
/// show faded
fn appendUnused(server: *Server, ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId, lines: offsets.LineIndex, diags: []const types.Diagnostic) ![]const types.Diagnostic {
    var r: Resolver = .{ .ctx = ctx, .arena = arena };
    const found = try ide.unused.findings(&r, file);
    if (found.len == 0) return diags;
    var out: std.ArrayList(types.Diagnostic) = .empty;
    try out.appendSlice(arena, diags);
    for (found) |f| try out.append(arena, .{
        .range = lines.range(f.start, f.end, server.encoding),
        .severity = .Hint,
        .code = .{ .string = ide.hints.unused_code },
        .source = ide.hints.source,
        .tags = &.{.Unnecessary},
        .message = .{ .string = try std.fmt.allocPrint(arena, "declaration `{s}` is never used", .{f.name}) },
    });
    return out.items;
}

/// Lint hints: a comparison with a constant result is a warning, since it is most likely a bug (a
/// loop that never ends); code without effect is a hint tagged `Unnecessary`
fn appendLint(server: *Server, ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId, lines: offsets.LineIndex, rules: Config.LintRules, diags: []const types.Diagnostic) ![]const types.Diagnostic {
    var r: Resolver = .{ .ctx = ctx, .arena = arena };
    const found = try ide.lint.findings(&r, file, null);
    if (found.len == 0) return diags;
    var out: std.ArrayList(types.Diagnostic) = .empty;
    try out.appendSlice(arena, diags);
    for (found) |f| {
        if (!lintAllows(rules, f.rule)) continue;
        const warning = f.rule == .constant_comparison;
        try out.append(arena, .{
            .range = lines.range(f.start, f.end, server.encoding),
            .severity = if (warning) .Warning else .Hint,
            .code = .{ .string = f.rule.code() },
            .source = ide.hints.source,
            .tags = if (warning) null else &.{.Unnecessary},
            .message = .{ .string = f.message },
        });
    }
    return out.items;
}

/// Removes analyzer-owned diagnostics covered by a suppression comment in the file. Compiler
/// diagnostics are never removed: published diagnostics must equal the compiler's output (see
/// `docs/diagnostics.md`)
fn filterSuppressed(ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId, lines: offsets.LineIndex, diags: []const types.Diagnostic) ![]const types.Diagnostic {
    var any = false;
    for (diags) |d| if (suppressibleCode(d) != null) {
        any = true;
        break;
    };
    if (!any) return diags;
    const parse = try ctx.get(database.syntax.ParseFile, file);
    const map = try ide.suppression.parse(arena, parse, lines);
    if (map.next_lines.len == 0 and map.ranges.len == 0) return diags;
    var out: std.ArrayList(types.Diagnostic) = .empty;
    for (diags) |d| {
        const code = suppressibleCode(d) orelse {
            try out.append(arena, d);
            continue;
        };
        if (map.isSuppressed(d.range.start.line, d.range.end.line, code)) continue;
        try out.append(arena, d);
    }
    return out.items;
}

/// The code of an analyzer-owned diagnostic that a suppression comment may remove
fn suppressibleCode(d: types.Diagnostic) ?[]const u8 {
    const source = d.source orelse return null;
    const code = switch (d.code orelse return null) {
        .string => |s| s,
        else => return null,
    };
    return ide.hints.suppressible(source, code);
}

// ── Request handlers ──────────────────────────────────────────────────

/// Maps a URI in a read request to a known file; returns
/// null for files that are not open or do not exist
pub fn lookupFile(server: *Server, arena: Allocator, document_uri: []const u8) !?Vfs.FileId {
    const path = try server.documentPath(arena, document_uri) orelse return null;
    return try server.vfs.lookup(path);
}

/// Converts a range in a request to byte offsets; a range
/// whose start and end are reversed is treated as swapped
pub fn rangeOffsets(server: *const Server, lines: offsets.LineIndex, range: types.Range) struct { u32, u32 } {
    const a: u32 = @intCast(lines.offsetOf(range.start, server.encoding));
    const b: u32 = @intCast(lines.offsetOf(range.end, server.encoding));
    return .{ @min(a, b), @max(a, b) };
}

/// Text and line index of the `SourceText` of `file`; the line table is cached for each revision
/// of the text (`LineStarts`)
pub fn sourceLines(ctx: *Db.Ctx, file: Vfs.FileId) !offsets.LineIndex {
    return .{ .text = (try ctx.get(syntax_q.SourceText, file)).text, .line_starts = try ctx.get(syntax_q.LineStarts, file) };
}

/// File text and line index; empty for a file without `FileText`
pub fn fileLines(ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId) !offsets.LineIndex {
    if (try ctx.get(FileText, file) == null) return offsets.LineIndex.init(arena, "");
    // With `FileText`, the `SourceText` is that text
    return sourceLines(ctx, file);
}

fn initialize(server: *Server, arena: Allocator, params: types.InitializeParams) HandlerError!types.InitializeResult {
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
        if (ws.inlayHint) |ih| server.inlay_refresh.supported = ih.refreshSupport orelse false;
        if (ws.semanticTokens) |st| server.semantic_refresh.supported = st.refreshSupport orelse false;
    }
    server.caps.read(params.capabilities);
    if (params.initializationOptions) |options| if (options != .null) {
        var config: Config = Config.parse(server.gpa, options) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidConfig => blk: {
                server.showWarning("invalid zig-analyzer initializationOptions, using defaults");
                break :blk .{};
            },
        };
        server.reportConfigWarnings("zig-analyzer settings", &config);
        server.applyLogging(&config, config.log_file != null);
        server.applyCacheLimits(&config);
        try server.setConfig(config);
    };
    log.info("initialized, position encoding {t}", .{server.encoding});
    if (params.processId) |pid| server.watchParent(pid);

    // Workspace root directories: workspaceFolders first, then rootUri / rootPath
    var root_uris: std.ArrayList([]const u8) = .empty;
    defer root_uris.deinit(server.gpa);
    if (params.workspaceFolders) |folders| for (folders) |f| try root_uris.append(server.gpa, f.uri);
    if (root_uris.items.len == 0) {
        if (params.rootUri) |r| {
            try root_uris.append(server.gpa, r);
        } else if (params.rootPath) |p| if (std.fs.path.isAbsolute(p)) {
            try root_uris.append(server.gpa, try uri.fromPath(arena, p));
        };
    }
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
            .renameProvider = if (server.caps.prepare_rename) .{ .RenameOptions = .{ .prepareProvider = true } } else .{ .boolean = true },
            .workspaceSymbolProvider = .{ .boolean = true },
            .executeCommandProvider = if (server.caps.apply_edit) .{ .commands = &.{fetch_hash_command} } else null,
            .workspace = .{ .workspaceFolders = .{ .supported = true, .changeNotifications = .{ .boolean = true } } },
            // Every action is a `CodeAction` literal: most carry an edit, and the dependency hash
            // action carries a command
            .codeActionProvider = if (server.caps.code_action_literals) .{ .CodeActionOptions = .{
                .codeActionKinds = &.{ types.CodeActionKind.QuickFix, types.CodeActionKind.RefactorExtract, types.CodeActionKind.RefactorRewrite, types.CodeActionKind.SourceOrganizeImports, types.CodeActionKind.SourceFixAll },
                .resolveProvider = true,
            } } else .{ .boolean = false },
            .semanticTokensProvider = .{ .SemanticTokensOptions = .{
                .legend = ide.semantic_tokens.legend,
                .full = .{ .SemanticTokensFullDelta = .{ .delta = true } },
                .range = .{ .boolean = true },
            } },
        },
        .serverInfo = .{ .name = "zig-analyzer", .version = za.version },
    };
}

/// A symbol kind the client supports: a client that lists its kinds handles any kind; for other
/// clients, kinds added after the initial protocol version (`File` to `Array`) are sent as the
/// closest initial kind
pub fn clientSymbolKind(listed: bool, kind: types.SymbolKind) types.SymbolKind {
    if (listed or @backingInt(kind) <= @backingInt(types.SymbolKind.Array)) return kind;
    return switch (kind) {
        .Struct, .Object => .Class,
        .EnumMember => .Enum,
        .TypeParameter => .Class,
        else => .Variable,
    };
}

/// Markup content in the formats the client accepts: without markdown, code fences are removed
/// and the text is sent as plain text
pub fn markup(arena: Allocator, markdown: bool, text: []const u8) Allocator.Error!types.MarkupContent {
    if (markdown) return .{ .kind = .markdown, .value = text };
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "```")) continue;
        if (!first) try out.append(arena, '\n');
        first = false;
        try out.appendSlice(arena, line);
    }
    return .{ .kind = .plaintext, .value = out.items };
}

fn shutdown(server: *Server, _: Allocator, _: void) HandlerError!void {
    // First release the waits that depend on the main loop: if the client never answered a
    // configuration request, stop waiting for it. After this the main loop blocks on await and
    // cannot handle a late response, so an in-flight `waitIdle` request can only end through this.
    server.abandonConfigRequests();
    // Likewise a workspace scan's hold on the busy count: the watch task releases it only after it
    // got `write_mutex`, which this request holds. Nobody waits for a scan's result any more.
    if (server.watcher) |w| w.closeScan();
    // Stop the build system processes of all projects; wait for in-flight requests to complete,
    // then for background tasks (diagnostics publishing, etc.) to wind down
    server.stopWorkspaces();
    server.group.await(server.io) catch {};
    server.waitIdle();
    server.state = .shutdown;
}

/// The file, text, line index and position of a request
pub fn textPosition(server: *Server, r: *Resolver, arena: Allocator, document_uri: []const u8, pos: types.Position) !?struct { file: Vfs.FileId, text: []const u8, lines: offsets.LineIndex, offset: u32 } {
    const file = try server.lookupFile(arena, document_uri) orelse return null;
    const lines = try sourceLines(r.ctx, file);
    return .{ .file = file, .text = lines.text, .lines = lines, .offset = @intCast(lines.offsetOf(pos, server.encoding)) };
}

/// `Pending.scans_awaited` of the semantic request whose handler runs on this thread (see
/// `SemanticTask`): the handlers that call `scopeIncomplete` get no `Pending`
threadlocal var handler_scans_awaited: u64 = 0;

/// Why the search scope may lack files that refer to a declaration right now, or null: the first
/// scan of the root directories has not been scheduled yet (startup has not ended), or a project is
/// of a root directory is still in its first load (until then, which files belong to it and what
/// its imports by name resolve to are not known; sub-projects are handled by `subProjectGap`).
/// Find references, rename and the fixes that edit references fail with this reason instead of
/// returning partial results. While a scan is scheduled or running (source
/// files may have changed since the last one, see `scheduleScan`), returns `error.ScanPending`
/// instead: the request waits for the scans scheduled so far, which takes a moment, and runs again
/// (see `waitScans`). Once it has waited, the scans it waited for are enough.
pub fn scopeIncomplete(server: *Server) error{ScanPending}!?[]const u8 {
    const scheduled = server.scan.rerun.generation.load(.acquire);
    if (scheduled == 0)
        return "the workspace folders are still being searched for source files, so not all files that may refer to it are known yet";
    if (server.rootProjectsLoading()) return "the project is still loading, so not all files that may refer to it are known yet";
    const needed = if (handler_scans_awaited != 0) handler_scans_awaited else scheduled;
    if (server.scan.done.load(.acquire) < needed) return error.ScanPending;
    return null;
}

/// A project of a root directory is still in its first load (see `projectsLoading`)
fn rootProjectsLoading(server: *Server) bool {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    for (server.workspaces.items) |ws| if (ws.isLoading() and server.isProjectRoot(ws.root)) return true;
    return false;
}

/// Sub-projects whose projects a semantic request starts and waits for before it runs again (see
/// `subProjectGap`)
const SubProjectWait = struct {
    /// Lives as long as the request
    arena: Allocator,
    dirs: std.ArrayList([]const u8) = .empty,
    /// The request has waited for them: it does not wait again
    awaited: bool = false,
};

/// The `SubProjectWait` of the semantic request whose handler runs on this thread (see
/// `SemanticTask`); null for other handlers
threadlocal var handler_sub_projects: ?*SubProjectWait = null;

/// What a request does with the references it finds (see `scopeIncompleteFor`)
pub const ScopeUse = enum {
    /// Lists them: uses in sub-projects that cannot be loaded are left out, as are those in a
    /// project that failed to load
    find,
    /// Edits them: fails instead of leaving uses in such sub-projects behind
    edit,
};

const SubProjectState = enum { loaded, loading, failed, unloaded };

/// State of the project of sub-project `dir`: `loaded` once it takes part in the module graph,
/// `failed` when its first load ended without (build.zig has errors, the build graph cannot be
/// read)
fn subProjectState(server: *Server, dir: []const u8) SubProjectState {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    const ws = server.visibleFor(dir) orelse return .unloaded;
    if (ws.isLoading()) return .loading;
    if (ws.inModuleGraph()) return .loaded;
    // Restarted after the first load failed: the new instance is loading
    if (ws.successor) |fresh| if (fresh.isLoading()) return .loading;
    return .failed;
}

/// Why the references of a declaration named `name` in sub-projects (see `sub_projects`) cannot all
/// be found now, or null. A sub-project matters when one of its files in the search scope mentions
/// the name: its files resolve their imports by name (`@import("lib")`) only once its project has
/// loaded, and until then they are not known to reach the declaration. With `build.sub_projects`
/// on, the first time such sub-projects are not loaded, they are recorded in
/// `handler_sub_projects` and `error.SubProjectsPending` is returned: the request starts their
/// projects, waits until they have loaded, and runs again (see `loadSubProjects`). A sub-project
/// still not loaded then (its project failed to load or could not be started, or the wait was cut
/// short), or not loaded with the setting off, leaves its uses out: `find` goes on without them,
/// and `edit` fails with the reason.
pub fn subProjectGap(server: *Server, r: *Resolver, name: []const u8, use: ScopeUse) !?[]const u8 {
    if (!server.buildFlags().build) return null;
    const dirs = blk: {
        server.roots_mutex.lockUncancelable(server.io);
        defer server.roots_mutex.unlock(server.io);
        const dirs = try r.arena.alloc([]const u8, server.sub_projects.items.len);
        for (dirs, server.sub_projects.items) |*d, s| d.* = try r.arena.dupe(u8, s);
        break :blk dirs;
    };
    var scope: ?[]const Vfs.FileId = null;
    const Missing = struct { dir: []const u8, state: SubProjectState };
    var missing: std.ArrayList(Missing) = .empty;
    for (dirs) |dir| {
        const state = server.subProjectState(dir);
        if (state == .loaded) continue;
        if (scope == null) scope = try server.searchScope(r);
        if (!try server.mentionedUnder(r, scope.?, dir, name)) continue;
        try missing.append(r.arena, .{ .dir = dir, .state = state });
    }
    if (missing.items.len == 0) return null;
    const enabled = server.config.load(.acquire).build_sub_projects;
    // A project that failed to load stays so until build.zig changes: waiting would not help
    if (enabled) if (handler_sub_projects) |wait| if (!wait.awaited) {
        for (missing.items) |m| if (m.state != .failed) try wait.dirs.append(wait.arena, try wait.arena.dupe(u8, m.dir));
        if (wait.dirs.items.len != 0) return error.SubProjectsPending;
    };
    if (use == .find) return null;
    const m = missing.items[0];
    const why = if (!enabled) "sub-projects are not loaded (`build.sub_projects` is off)" else switch (m.state) {
        .loaded => unreachable,
        .loading => "its project is still loading",
        .failed => "its project failed to load",
        .unloaded => "its project could not be started",
    };
    return try std.fmt.allocPrint(r.arena, "files of the sub-project at {s} mention it, but {s}, so its uses there are not known", .{ m.dir, why });
}

/// Whether a file of `scope` under directory `dir` has an identifier `name`: the same filter that
/// find references applies to candidate files (see `FileIndex`), so a file without one has none of
/// its references. build.zig.zon files are skipped: the build system gives their fields (`.name`,
/// `.path`, ...), which do not refer to declarations.
fn mentionedUnder(server: *Server, r: *Resolver, scope: []const Vfs.FileId, dir: []const u8, name: []const u8) !bool {
    for (scope) |f| {
        const path = server.vfs.path(f);
        if (!server.vfs.isUnder(path, dir) or std.mem.eql(u8, std.fs.path.basename(path), "build.zig.zon")) continue;
        if ((try r.ctx.get(za.syntax.FileIndex.Query, f)).contains(name)) return true;
    }
    return false;
}

/// Scope of find references and workspace symbol: project files in the module graph (excluding the
/// standard library), the user's source files under the root directories, and open documents
pub fn searchScope(server: *Server, r: *Resolver) ![]const Vfs.FileId {
    var set: std.AutoArrayHashMapUnmanaged(Vfs.FileId, void) = .empty;
    for (try za.ide_db.search.searchFiles(r)) |f| try set.put(r.arena, f, {});
    server.docs.mutex.lockUncancelable(server.io);
    defer server.docs.mutex.unlock(server.io);
    for (server.docs.open.keys()) |f| try set.put(r.arena, f, {});
    return set.keys();
}

/// Scope of workspace symbol: excludes files in dependency libraries by default;
/// `workspace_symbol.dependencies` includes them. Every file of the scope is searched: the request
/// first waits for background indexing (see `waitSymbolIndex`), and files not indexed yet (added
/// since, or when indexing stopped early) are indexed in the request.
pub fn symbolScope(server: *Server, r: *Resolver) ![]const Vfs.FileId {
    const scope = try server.searchScope(r);
    if (server.config.load(.acquire).workspace_symbol_dependencies) return scope;
    const rules = try server.originRules(r.arena);
    var user: std.ArrayList(Vfs.FileId) = .empty;
    for (scope) |f| if (!origin.classify(&server.vfs, rules, server.vfs.path(f), false).isLibrary()) try user.append(r.arena, f);
    return user.items;
}

/// Restarts all projects (same as saving build.zig): used when the build graph or compile results
/// need a manual refresh
fn reloadWorkspace(server: *Server, arena: Allocator, _: void) HandlerError!void {
    const list = try server.workspaceList(arena);
    defer server.releaseList(arena, list);
    if (list.len != 0) log.info("restarting projects on request", .{});
    for (list) |ws| server.restartWorkspace(ws, 0);
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
        // Answered only when the wait for scans or sub-projects was cut short, by a cancellation or
        // the shutdown (see `SemanticTask`)
        error.ScanPending, error.SubProjectsPending => if (canceled_by_client)
            server.sendError(id, jsonrpc.error_codes.request_cancelled, "request cancelled")
        else
            server.sendError(id, jsonrpc.error_codes.request_failed, "the server is shutting down"),
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
    _ = Rerun;
    _ = watch;
    _ = client_process;
    _ = origin;
    _ = workspace_files;
    _ = Workspace;
    _ = requests.code_actions;
    _ = requests.completion;
    _ = requests.document;
    _ = requests.hover;
    _ = requests.inlay_hints;
    _ = requests.inspection;
    _ = requests.navigation;
    _ = requests.references;
    _ = requests.rename;
    _ = requests.semantic_tokens;
    _ = @import("Server_test.zig");
    _ = @import("semantic_tokens_test.zig");
    _ = @import("build_e2e_test.zig");
    _ = @import("packages_e2e_test.zig");
    _ = @import("compiler_e2e_test.zig");
    _ = @import("names_e2e_test.zig");
    _ = @import("refs_e2e_test.zig");
    _ = @import("naming_e2e_test.zig");
    _ = @import("hints_e2e_test.zig");
    _ = @import("remove_param_e2e_test.zig");
    _ = @import("unused_capture_e2e_test.zig");
    _ = @import("workspace_e2e_test.zig");
    _ = @import("maker_e2e_test.zig");
    _ = @import("auto_import_test.zig");
}
