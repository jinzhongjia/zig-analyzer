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
const syntax_q = database.syntax;
const live = database.live;
const ide = za.ide;
const compiler = za.diagnostics.compiler;
const ZigEnv = za.project.ZigEnv;
const Workspace = @import("Workspace.zig");
const origin = @import("origin.zig");
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

const config_sync = @import("config_sync.zig");
const doc_sync = @import("doc_sync.zig");
const file_changes = @import("file_changes.zig");
const file_diagnostics = @import("file_diagnostics.zig");
pub const indexing = @import("indexing.zig");
const project_set = @import("project_set.zig");
const publishing = @import("publishing.zig");
const slow_log = @import("slow_log.zig");

const Edit = publishing.Edit;
const OpenDoc = doc_sync.OpenDoc;
const PublishJob = publishing.PublishJob;
const PublishState = publishing.PublishState;
const SemaUsage = publishing.SemaUsage;
const config_request_prefix = config_sync.config_request_prefix;

/// The auto-import index has not been fully built yet (see `index.imports_basis`)
const imports_pending = std.math.maxInt(u64);

/// Id of the registration request sent after `initialized`
const register_id = "zig-analyzer/register";

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
/// Serializes semantic token responses with the refresh request caused by a later edit: a
/// response computed from the pre-edit text holds it from before its read transaction ends until
/// it is written, and `requestSemanticRefresh` holds it while writing the refresh and retiring the
/// baselines (see `requestSemanticRefresh`)
semantic_send: Io.Mutex = .init,
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

/// Serializes batches of external changes from reading the disk to applying them (see
/// `file_changes.prepareFileChanges`): a batch that starts later waits for an earlier one, so the
/// batches cannot apply out of order. Taken before `write_mutex` and released after it.
changes_mutex: Io.Mutex = .init,
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
    /// Holds the formatting result once it has been computed outside the read transaction, before
    /// the staleness check and the answer, so that a test can send an edit in between
    format: ?*OnceGate = null,
    /// Holds a request's response after its read transaction has ended, before it is written, so
    /// that a test can inspect the state the request no longer holds
    response: ?*OnceGate = null,
    /// Holds a semantic tokens refresh request after it has been claimed, before it takes
    /// `semantic_send`, so that a test can order it with a semantic tokens response
    semantic_refresh: ?*OnceGate = null,
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
    /// Counts the reads of builtin.zig files in module graph updates (see `indexing.builtinTarget`)
    builtin_target_reads: ?*std.atomic.Value(usize) = null,
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

pub const Pending = struct {
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
    /// The file whose live diagnostics a semantic request prepares outside its read transaction
    /// before running again (see `HandlerError.LivePending`)
    live_file: ?Vfs.FileId = null,
    /// Preparing `live_file` failed: the handler then computes the live diagnostics itself, as a
    /// publish does when its preparation fails
    live_prepare_failed: bool = false,
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
        /// After the read transaction ended, before the live diagnostics the handler needs are
        /// prepared outside it (see `HandlerError.LivePending`)
        before_live,
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

    pub fn pass(gate: *OnceGate, io: Io) void {
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
    /// The live diagnostics of the document are not prepared: the request prepares them outside
    /// the read transaction and runs again (see `requireLivePrepared`)
    LivePending,
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
    project_set.stopWorkspaces(server);
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
    doc_sync.forgetRealPath(server, null);
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
    config_sync.abandonConfigRequests(server);
    server.group.await(server.io) catch {};
    project_set.stopWorkspaces(server);
    server.waitIdle();
    return if (server.state == .shutdown) 0 else 1;
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
    project_set.stopWorkspaces(server);
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
    var pc: panic_context.Text = .{};
    switch (message) {
        .request => |req| messageContext(&pc, "request", req.method, req.params),
        .notification => |n| messageContext(&pc, "notification", n.method, n.params),
        .response => pc.enter("response", .{}),
    }
    defer pc.leave();
    // The disk contents of an external change are read before `write_mutex` is taken (see
    // `file_changes.prepareFileChanges`). The main loop handles no other message meanwhile, so
    // the notification keeps its place in the LSP message order.
    if (message == .notification) {
        const n = message.notification;
        if (std.mem.eql(u8, n.method, "workspace/didChangeWatchedFiles")) {
            return server.processWatchedFilesNotification(arena, n.params);
        }
    }
    server.write_mutex.lockUncancelable(server.io);
    defer server.write_mutex.unlock(server.io);
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
                    try config_sync.handleConfigResponse(server, s, resp.result, resp.failed);
                } else if (std.mem.startsWith(u8, s, apply_edit_prefix)) {
                    requests.code_actions.applyEditResponse(server, resp.result, resp.failed);
                } else if (std.mem.eql(u8, s, server.semantic_refresh.id)) {
                    if (server.semantic_refresh.finished(server.io)) server.requestSemanticRefresh();
                } else if (std.mem.eql(u8, s, server.inlay_refresh.id)) {
                    if (server.inlay_refresh.finished(server.io)) server.requestInlayRefresh();
                } else if (resp.failed and (std.mem.eql(u8, s, register_id) or std.mem.startsWith(u8, s, watch.Watcher.registration_prefix))) {
                    file_changes.watchRegistrationFailed(server);
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
    /// Like `syntax`, but the handler only copies the text, line table, and renderer inside the
    /// read transaction; the formatting itself runs after it ends (see `FormattingTask`)
    formatting,
};

/// The command of a code action on a `build.zig.zon` dependency: runs `zig fetch` and applies the
/// hash to the manifest
pub const fetch_hash_command = "zig-analyzer/fetchDependencyHash";
/// The command of the code action on an `@import` in build.zig of a dependency that is not
/// fetched: runs `zig build --fetch` in the project and restarts it
pub const fetch_dependencies_command = "zig-analyzer/fetchDependencies";
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
    .{ "textDocument/formatting", Mode.formatting, requests.document.formatting },
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
                .read, .semantic, .syntax, .formatting => {
                    const inputs: ?Db.Inputs = if (h[1] == .syntax or h[1] == .formatting) comptime Db.inputSet(&.{ FileText, database.syntax.SyntaxDialect, ide.format.ZigFmtRenderer }) else null;
                    const pending = server.addPending(a, id, inputs) catch |err| {
                        defer server.destroyArena(arena);
                        server.sendError(id, jsonrpc.error_codes.internal_error, "out of memory");
                        return err;
                    };
                    if (h[1] == .semantic and @typeInfo(Params) == .@"struct" and @hasField(Params, "textDocument")) {
                        server.rememberHeldDocument(a, pending, params.textDocument.uri);
                    }
                    const Task = if (h[1] == .semantic) SemanticTask(func, h[0]) else if (h[1] == .formatting) FormattingTask(func, h[0]) else ReadTask(func, h[0]);
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

/// A handler failed with `err`: sets `response` to the bytes of the error response and returns
/// true, or returns false when the handler must run again. A read interrupted only by a write the
/// server made on its own (`Db.WriteOrder.unordered`) runs again on the new state: the text the
/// request refers to has not changed, so the client has nothing to act on. When a write ordered
/// after the request caused the interruption, the next read transaction would be stale, and
/// `ContentModified` is answered there. The caller begins the next read only once that write has
/// taken the lock (see `Db.waitPendingWrites`): beginning it at once could keep the write waiting.
/// The response is serialized here, inside the read transaction, because its values may point into
/// memoized values that the next write frees; it is sent by the caller after `ctx.end()`.
fn answerFailureBytes(server: *Server, ctx: *const Db.Ctx, pending: *const Pending, err: anyerror, response: *?[]u8) bool {
    const by_client = pending.cancel.load(.acquire);
    if (err == error.Canceled and !by_client and !ctx.stale and !server.isShuttingDown()) return false;
    response.* = server.handlerErrorBytes(pending.id, err, by_client);
    return true;
}

/// Sends the response of an attempt after its read transaction has ended (see `answerFailureBytes`)
fn sendAttempt(server: *Server, response: ?[]u8, slow: ?slow_log.Report) void {
    if (response) |bytes| {
        if (@import("builtin").is_test) if (server.hooks.response) |gate| gate.pass(server.io);
        server.send(bytes);
    }
    if (slow) |report| slow_log.logReport(report);
}

fn ReadTask(comptime func: anytype, comptime method: []const u8) type {
    const Params = LastParam(@TypeOf(func));
    return struct {
        fn run(server: *Server, arena: *std.heap.ArenaAllocator, pending: *Pending, params: Params) Io.Cancelable!void {
            defer server.finishRequest(arena, pending);
            pending.sema_start = publishing.semaUsage(server);
            server.testGate(method, .before_read, pending);
            while (!attempt(server, pending, params)) server.db.waitPendingWrites();
        }

        /// Returns whether the request was answered (see `answerFailureBytes`)
        fn attempt(server: *Server, pending: *Pending, params: Params) bool {
            var attempt_arena: std.heap.ArenaAllocator = .init(server.gpa);
            defer attempt_arena.deinit();
            const a = attempt_arena.allocator();
            var response: ?[]u8 = null;
            var slow: ?slow_log.Report = null;
            const answered = outcome: {
                var ctx = server.db.beginReadAt(a, pending.since);
                ctx.cancel = &pending.cancel;
                defer ctx.end();
                server.testGate(method, .in_read, pending);
                var trace: za.db.Trace = .{ .gpa = a };
                if (slow_log.traceEnabled(server)) ctx.trace = &trace;
                var pc: panic_context.Text = .{};
                requestContext(&pc, method, params);
                defer pc.leave();
                const zone = za.util.tracy.zone(@src(), method);
                defer zone.end();
                const t0 = Io.Clock.awake.now(server.io);
                defer slow = slow_log.captureIfSlow(server, &ctx, method, t0, &trace);

                const result = func(server, &ctx, a, params) catch |err| {
                    break :outcome server.answerFailureBytes(&ctx, pending, err, &response);
                };
                // The handler may have swallowed `Canceled` with a fallback value (such as
                // `catch null` in type rendering), and then the result is incomplete
                ctx.checkCanceled() catch |err| {
                    break :outcome server.answerFailureBytes(&ctx, pending, err, &response);
                };
                response = server.responseBytes(pending.id, result);
                break :outcome true;
            };
            sendAttempt(server, response, slow);
            return answered;
        }
    };
}

/// Like ReadTask, but the handler gets a Resolver
fn SemanticTask(comptime func: anytype, comptime method: []const u8) type {
    const Params = LastParam(@TypeOf(func));
    return struct {
        fn run(server: *Server, arena: *std.heap.ArenaAllocator, pending: *Pending, params: Params) Io.Cancelable!void {
            defer server.finishRequest(arena, pending);
            pending.sema_start = publishing.semaUsage(server);
            const waited_for_projects = project_set.waitForProjects(server, pending);
            if (comptime std.mem.eql(u8, method, "workspace/symbol")) {
                // After a wait, reads the state at its end: the request has no position that
                // refers to the text it was sent on, and an edit during the wait would otherwise
                // answer it with `ContentModified`
                if (indexing.waitSymbolIndex(server, pending) or waited_for_projects) pending.since = server.db.mark(pending.since.inputs);
            }
            server.testGate(method, .before_read, pending);
            var sub_projects: SubProjectWait = .{ .arena = arena.allocator() };
            while (true) switch (attempt(server, pending, params, waited_for_projects, &sub_projects)) {
                .answered => return,
                .again => server.db.waitPendingWrites(),
                // Outside the read transaction: the scan's write waits for read transactions
                .after_scans => indexing.waitScans(server, pending),
                // Likewise: loading a project writes the module graph
                .after_sub_projects => project_set.loadSubProjects(server, pending, &sub_projects),
                // Likewise: AstGen or `zig ast-check` must not run inside a read transaction
                .after_live => {
                    server.testGate(method, .before_live, pending);
                    pending.live_prepare_failed = !publishing.prepareLive(server, pending.live_file.?);
                    server.db.waitPendingWrites();
                },
            };
        }

        const Next = enum {
            answered,
            /// Run again once the pending writes have taken the lock (see `answerFailureBytes`)
            again,
            /// Run again after the scans scheduled so far (see `HandlerError.ScanPending`)
            after_scans,
            /// Run again once the sub-projects recorded have loaded (see
            /// `HandlerError.SubProjectsPending`)
            after_sub_projects,
            /// Run again once the live diagnostics of `pending.live_file` are prepared (see
            /// `HandlerError.LivePending`)
            after_live,
        };

        fn attempt(server: *Server, pending: *Pending, params: Params, waited_for_projects: bool, sub_projects: *SubProjectWait) Next {
            var attempt_arena: std.heap.ArenaAllocator = .init(server.gpa);
            defer attempt_arena.deinit();
            const a = attempt_arena.allocator();
            var response: ?[]u8 = null;
            var slow: ?slow_log.Report = null;
            var semantic_send_locked = false;
            defer if (semantic_send_locked) server.semantic_send.unlock(server.io);
            const next = outcome: {
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
                if (slow_log.traceEnabled(server)) ctx.trace = &trace;
                var pc: panic_context.Text = .{};
                requestContext(&pc, method, params);
                defer pc.leave();
                const zone = za.util.tracy.zone(@src(), method);
                defer zone.end();
                const t0 = Io.Clock.awake.now(server.io);
                defer slow = slow_log.captureIfSlow(server, &ctx, method, t0, &trace);
                var r: Resolver = .{ .ctx = &ctx, .arena = a };
                handler_scans_awaited = pending.scans_awaited;
                defer handler_scans_awaited = 0;
                sub_projects.dirs.clearRetainingCapacity();
                handler_sub_projects = sub_projects;
                defer handler_sub_projects = null;
                handler_live_file = null;
                defer handler_live_file = null;
                handler_live_skip = pending.live_prepare_failed;
                defer handler_live_skip = false;
                const result = func(server, &r, a, params) catch |err| break :outcome failed(server, &ctx, pending, sub_projects, err, &response);
                // As in ReadTask: a handler that swallowed `Canceled` has an incomplete result
                ctx.checkCanceled() catch |err| break :outcome failed(server, &ctx, pending, sub_projects, err, &response);
                if (comptime isOutcome(@TypeOf(result))) switch (result) {
                    .ok => |v| response = server.responseBytes(pending.id, v),
                    .failed => |message| response = server.errorResponseBytes(pending.id, jsonrpc.error_codes.request_failed, message),
                } else response = server.responseBytes(pending.id, result);
                // A write can begin only after this read transaction ends, so the refresh it
                // triggers waits for this response to be written (see `requestSemanticRefresh`).
                // Waiting here keeps this request's read transaction open: while another thread
                // writes a semantic token response, a second semantic token request delays writes.
                if (comptime std.mem.startsWith(u8, method, "textDocument/semanticTokens/")) {
                    server.semantic_send.lockUncancelable(server.io);
                    semantic_send_locked = true;
                }
                break :outcome .answered;
            };
            sendAttempt(server, response, slow);
            return next;
        }

        fn failed(server: *Server, ctx: *const Db.Ctx, pending: *Pending, sub_projects: *const SubProjectWait, err: anyerror, response: *?[]u8) Next {
            const go_on = !pending.cancel.load(.acquire) and !server.isShuttingDown();
            // Waits once: after the wait, the scans it waited for are enough (see `scopeIncomplete`),
            // so the scope is still incomplete only when the wait was cut short
            if (err == error.ScanPending and pending.scans_awaited == 0 and go_on) return .after_scans;
            // Likewise once: sub-projects still not loaded after the wait are left out (see
            // `subProjectGap`), which does not report them again
            if (err == error.SubProjectsPending and !sub_projects.awaited and go_on) return .after_sub_projects;
            // The live check runs outside the read transaction (see `HandlerError.LivePending`)
            if (err == error.LivePending and go_on) if (handler_live_file) |file| {
                pending.live_file = file;
                return .after_live;
            };
            return if (server.answerFailureBytes(ctx, pending, err, response)) .answered else .again;
        }
    };
}

/// `textDocument/formatting`: copies the text and the renderer inside the read transaction, then
/// formats after it has ended. The whole-file parse and render take long enough that an edit (and
/// the main loop behind it) would otherwise wait for them. The answer is sent only when no write
/// to the file's inputs has begun since the request was received: edits computed on the old text
/// would otherwise be applied to the buffer after the client's edit (see `Db.markChanged`).
fn FormattingTask(comptime func: anytype, comptime method: []const u8) type {
    const Params = LastParam(@TypeOf(func));
    return struct {
        fn run(server: *Server, arena: *std.heap.ArenaAllocator, pending: *Pending, params: Params) Io.Cancelable!void {
            defer server.finishRequest(arena, pending);
            pending.sema_start = publishing.semaUsage(server);
            server.testGate(method, .before_read, pending);
            while (!attempt(server, pending, params)) server.db.waitPendingWrites();
        }

        /// Returns whether the request was answered (see `answerFailureBytes`)
        fn attempt(server: *Server, pending: *Pending, params: Params) bool {
            var attempt_arena: std.heap.ArenaAllocator = .init(server.gpa);
            defer attempt_arena.deinit();
            const a = attempt_arena.allocator();
            var response: ?[]u8 = null;
            var slow: ?slow_log.Report = null;
            var input: ?requests.document.FormattingInput = null;
            const answered = outcome: {
                var ctx = server.db.beginReadAt(a, pending.since);
                ctx.cancel = &pending.cancel;
                defer ctx.end();
                server.testGate(method, .in_read, pending);
                var trace: za.db.Trace = .{ .gpa = a };
                if (slow_log.traceEnabled(server)) ctx.trace = &trace;
                var pc: panic_context.Text = .{};
                requestContext(&pc, method, params);
                defer pc.leave();
                const zone = za.util.tracy.zone(@src(), method);
                defer zone.end();
                const t0 = Io.Clock.awake.now(server.io);
                defer slow = slow_log.captureIfSlow(server, &ctx, method, t0, &trace);

                input = requests.document.formatting(server, &ctx, a, params) catch |err| {
                    break :outcome server.answerFailureBytes(&ctx, pending, err, &response);
                };
                ctx.checkCanceled() catch |err| {
                    break :outcome server.answerFailureBytes(&ctx, pending, err, &response);
                };
                // A document that does not exist is answered with null, serialized inside the
                // transaction like every other answer
                if (input == null) response = server.responseBytes(pending.id, @as(?[]const types.TextEdit, null));
                break :outcome true;
            };
            if (!answered) {
                if (slow) |report| slow_log.logReport(report);
                return false;
            }
            // The result is built from the text copy and the renderer read inside the transaction
            // and points only into this attempt's arena, so serializing it here is safe.
            if (response == null) if (input) |in| {
                if (ide.format.format(a, in.lines, in.mode, server.encoding, in.renderer)) |edits| {
                    if (@import("builtin").is_test) if (server.hooks.format) |gate| gate.pass(server.io);
                    if (pending.cancel.load(.acquire)) {
                        response = server.errorResponseBytes(pending.id, jsonrpc.error_codes.request_cancelled, "request cancelled");
                    } else if (server.db.markChanged(pending.since)) {
                        response = server.errorResponseBytes(pending.id, jsonrpc.error_codes.content_modified, "content modified");
                    } else if (server.db.pendingInputWrite(pending.since.inputs)) {
                        // A write of any order waiting for the lock would have made the
                        // in-transaction check retry; formatting runs after the transaction, so it
                        // is checked here before answering with the copied renderer or dialect
                        if (server.isShuttingDown()) {
                            response = server.errorResponseBytes(pending.id, jsonrpc.error_codes.content_modified, "content modified");
                        } else {
                            if (slow) |report| slow_log.logReport(report);
                            return false;
                        }
                    } else {
                        response = server.responseBytes(pending.id, edits);
                    }
                } else |err| response = server.errorResponseBytes(pending.id, jsonrpc.error_codes.internal_error, @errorName(err));
            };
            sendAttempt(server, response, slow);
            return true;
        }
    };
}

/// End of a read or semantic request task, after its read transaction: evicts when a query
/// exceeds its cache capacity and reclaims type information when needed (both only when no other
/// read transaction is active), then unregisters the request, which counts as in flight until
/// then
fn finishRequest(server: *Server, arena: *std.heap.ArenaAllocator, pending: *Pending) void {
    if (server.db.wantsSweep()) _ = server.db.trySweep();
    publishing.maybeResetSema(server, pending.sema_start);
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

// ── Pending requests and refresh ─────────────────────────────────────

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
    indexing.wakeSymbolWaiters(server);
    project_set.wakeProjectWaiters(server);
    indexing.wakeScanWaiters(server);
}

fn cancelAllPending(server: *Server) void {
    server.pending_mutex.lockUncancelable(server.io);
    defer server.pending_mutex.unlock(server.io);
    for (server.pending.items) |p| p.cancel.store(true, .release);
    indexing.wakeSymbolWaiters(server);
    project_set.wakeProjectWaiters(server);
    indexing.wakeScanWaiters(server);
}

/// Called on the main loop when a request that refers to a document is received: if it may be held
/// back, records that document's state (see `SemanticTask`)
fn rememberHeldDocument(server: *Server, arena: Allocator, pending: *Pending, document_uri: []const u8) void {
    if (!project_set.holdForProjects(server)) return;
    const file = (server.lookupFile(arena, document_uri) catch return) orelse return;
    var ctx = server.db.beginRead(arena);
    defer ctx.end();
    pending.document = .{ .file = file, .text_changed_at = ctx.inputChangedAt(FileText, file) };
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
pub fn requestRefresh(server: *Server) void {
    server.requestSemanticRefresh();
    server.requestInlayRefresh();
}

pub fn openDocumentCount(server: *Server) usize {
    server.docs.mutex.lockUncancelable(server.io);
    defer server.docs.mutex.unlock(server.io);
    return server.docs.open.count();
}

/// Claims `r` and builds its request; null when nothing is sent (unsupported, shutting down, no
/// open document, or one refresh already awaits the client's response).
fn prepareRefresh(server: *Server, r: *Refresh) ?[]u8 {
    if (!r.supported or server.isShuttingDown() or server.openDocumentCount() == 0) return null;
    if (!r.claim(server.io)) return null;
    return jsonrpc.request(server.gpa, .{ .string = r.id }, r.method, {}) catch {
        _ = r.finished(server.io);
        log.err("out of memory while building {s}", .{r.method});
        return null;
    };
}

/// Sends refresh `r` unless one awaits the response; returns whether it was sent. Edits refresh
/// other documents only after the debounce completes; indexing refreshes only after a stable round
/// ends. Changes made while waiting for the client's response are merged into the next refresh,
/// which is not sent inside any read transaction or state lock.
fn sendRefresh(server: *Server, r: *Refresh) bool {
    const bytes = server.prepareRefresh(r) orelse return false;
    server.send(bytes);
    return true;
}

pub fn requestSemanticRefresh(server: *Server) void {
    // Checked before taking the send lock: calls that send nothing (unsupported client, no open
    // document, or one refresh already awaits the response) must not make a main-loop caller wait.
    const bytes = server.prepareRefresh(&server.semantic_refresh) orelse return;
    if (@import("builtin").is_test) if (server.hooks.semantic_refresh) |gate| gate.pass(server.io);
    // A semantic token response computed before a write holds this from before its read
    // transaction ends until it is written; the write waits for that transaction, so the refresh
    // it causes is always written after that response.
    server.semantic_send.lockUncancelable(server.io);
    defer server.semantic_send.unlock(server.io);
    server.send(bytes);
    // Retire the baselines only after the refresh is written out: every result sent afterwards
    // reaches the client after the refresh. If they were retired first, a result sent in between
    // could arrive before the refresh and become the baseline for the delta request the client
    // makes after refreshing.
    server.semantic_cache.retireBaselines(server.io);
}

pub fn requestInlayRefresh(server: *Server) void {
    _ = server.sendRefresh(&server.inlay_refresh);
}

// ── Lifecycle requests ───────────────────────────────────────────────

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
        config_sync.applyLogging(server, &config, config.log_file != null);
        config_sync.applyCacheLimits(server, &config);
        try config_sync.setConfig(server, config);
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
    for (root_uris.items) |root_uri| try project_set.addRoot(server, root_uri);

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
            .executeCommandProvider = .{ .commands = if (server.caps.apply_edit) &.{ fetch_hash_command, fetch_dependencies_command } else &.{fetch_dependencies_command} },
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

fn shutdown(server: *Server, _: Allocator, _: void) HandlerError!void {
    // First release the waits that depend on the main loop: if the client never answered a
    // configuration request, stop waiting for it. After this the main loop blocks on await and
    // cannot handle a late response, so an in-flight `waitIdle` request can only end through this.
    config_sync.abandonConfigRequests(server);
    // Likewise a workspace scan's hold on the busy count: the watch task releases it only after it
    // got `write_mutex`, which this request holds. Nobody waits for a scan's result any more.
    if (server.watcher) |w| w.closeScan();
    // Stop the build system processes of all projects; wait for in-flight requests to complete,
    // then for background tasks (diagnostics publishing, etc.) to wind down
    project_set.stopWorkspaces(server);
    server.group.await(server.io) catch {};
    server.waitIdle();
    server.state = .shutdown;
}

/// Restarts all projects (same as saving build.zig): used when the build graph or compile results
/// need a manual refresh
fn reloadWorkspace(server: *Server, arena: Allocator, _: void) HandlerError!void {
    const list = try project_set.workspaceList(server, arena);
    defer project_set.releaseList(server, arena, list);
    if (list.len != 0) log.info("restarting projects on request", .{});
    for (list) |ws| project_set.restartWorkspace(server, ws, 0);
}

fn waitIdleRequest(server: *Server, _: Allocator, _: void) HandlerError!void {
    server.waitIdle();
}

// ── Notifications ────────────────────────────────────────────────────

/// `workspace/didChangeWatchedFiles`, handled without `write_mutex` at first: the notification
/// reads the disk before taking it (see `file_changes.didChangeWatchedFiles`). The main loop
/// handles no other message meanwhile.
fn processWatchedFilesNotification(server: *Server, arena: *std.heap.ArenaAllocator, params_value: json.Value) !Flow {
    const a = arena.allocator();
    defer server.destroyArena(arena);
    // Before initialization and after shutdown, all notifications except exit are dropped
    if (server.state == .uninitialized or server.state == .shutdown) return .@"continue";
    const params = jsonrpc.parseParams(types.DidChangeWatchedFilesParams, a, params_value) catch |err| {
        log.warn("workspace/didChangeWatchedFiles: malformed params: {t}", .{err});
        return .@"continue";
    };
    file_changes.didChangeWatchedFiles(server, a, params) catch |err| log.err("workspace/didChangeWatchedFiles failed: {t}", .{err});
    return .@"continue";
}

fn processNotification(server: *Server, arena: Allocator, method: []const u8, params_value: json.Value) !Flow {
    if (std.mem.eql(u8, method, "exit")) return .exit;
    // Before initialization and after shutdown, all notifications except exit are dropped
    if (server.state == .uninitialized or server.state == .shutdown) return .@"continue";

    const handlers = .{
        .{ "$/cancelRequest", cancelRequest },
        .{ "textDocument/didOpen", doc_sync.didOpen },
        .{ "textDocument/didChange", doc_sync.didChange },
        .{ "textDocument/didClose", doc_sync.didClose },
        .{ "textDocument/didSave", doc_sync.didSave },
        .{ "workspace/didChangeConfiguration", config_sync.didChangeConfiguration },
        .{ "workspace/didChangeWorkspaceFolders", project_set.didChangeWorkspaceFolders },
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
        config_sync.requestConfig(server);
    } else {
        project_set.startProjects(server);
    }
}

// ── Search scope of find references and rename ───────────────────────

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
    for (server.workspaces.items) |ws| if (ws.isLoading() and project_set.isProjectRoot(server, ws.root)) return true;
    return false;
}

/// Sub-projects whose projects a semantic request starts and waits for before it runs again (see
/// `subProjectGap`)
pub const SubProjectWait = struct {
    /// Lives as long as the request
    arena: Allocator,
    dirs: std.ArrayList([]const u8) = .empty,
    /// The request has waited for them: it does not wait again
    awaited: bool = false,
};

/// The `SubProjectWait` of the semantic request whose handler runs on this thread (see
/// `SemanticTask`); null for other handlers
threadlocal var handler_sub_projects: ?*SubProjectWait = null;

/// The file whose live diagnostics the semantic request on this thread needs prepared outside its
/// read transaction (see `requireLivePrepared` and `HandlerError.LivePending`)
threadlocal var handler_live_file: ?Vfs.FileId = null;

/// Preparing `handler_live_file` failed in a previous attempt: the handler computes the live
/// diagnostics itself, as a publish does when its preparation fails (see `publishing.prepareLive`)
threadlocal var handler_live_skip = false;

/// Called by a handler before it reads `live.AstCheck`: when the result for the current text has
/// not been prepared outside a read transaction, returns `error.LivePending` so that `SemanticTask`
/// ends the transaction, prepares it (see `publishing.prepareLive`), and runs the handler again.
/// AstGen and `zig ast-check` do not check for cancellation, so running them inside the
/// transaction would make typing wait for them. When a previous preparation failed, the handler
/// runs the check itself, as a publish does.
pub fn requireLivePrepared(server: *Server, ctx: *Db.Ctx, file: Vfs.FileId) HandlerError!void {
    if (handler_live_skip) return;
    if (try publishing.liveReady(server, ctx, file)) return;
    handler_live_file = file;
    return error.LivePending;
}

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
pub fn subProjectState(server: *Server, dir: []const u8) SubProjectState {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    const ws = project_set.visibleFor(server, dir) orelse return .unloaded;
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
    if (!config_sync.buildFlags(server).build) return null;
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

// ── Files, positions, and settings ───────────────────────────────────

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

/// The innermost workspace whose root directory contains `path`; the caller holds
/// `workspaces_mutex`
fn innermostWorkspaceLocked(server: *Server, path: []const u8) ?*Workspace {
    var best: ?*Workspace = null;
    for (server.workspaces.items) |ws| {
        if (server.vfs.isUnder(path, ws.root) and (best == null or ws.root.len > best.?.root.len)) best = ws;
    }
    return best;
}

/// The innermost workspace whose root directory contains `path`, with a reference held (release
/// with `Workspace.release`); null when no workspace contains it
pub fn innermostWorkspace(server: *Server, path: []const u8) ?*Workspace {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    const ws = innermostWorkspaceLocked(server, path) orelse return null;
    ws.acquire();
    return ws;
}

/// Origin of the file (see `origin.classify`)
pub fn fileOrigin(server: *Server, file: Vfs.FileId) origin.Origin {
    return server.originOf(file, server.inProject(file));
}

/// Treats the file as `.other` when out of memory leaves the classification rules unavailable
pub fn originOf(server: *Server, file: Vfs.FileId, in_project: bool) origin.Origin {
    var arena: std.heap.ArenaAllocator = .init(server.gpa);
    defer arena.deinit();
    const rules = server.originRules(arena.allocator()) catch return .other;
    return origin.classify(&server.vfs, rules, server.vfs.path(file), in_project);
}

pub fn uriFor(server: *Server, arena: Allocator, file: Vfs.FileId) Allocator.Error![]const u8 {
    server.docs.mutex.lockUncancelable(server.io);
    defer server.docs.mutex.unlock(server.io);
    if (server.docs.open.getPtr(file)) |open| return arena.dupe(u8, open.current().uri);
    if (server.docs.last_uris.get(file)) |u| return arena.dupe(u8, u);
    return uri.fromPath(arena, server.vfs.path(file));
}

/// URIs of the files a request responds about: `uriFor` takes the document lock and encodes a URI
/// each time, which repeats for every reference in the same file
pub const UriCache = struct {
    server: *Server,
    arena: Allocator,
    uris: std.AutoHashMapUnmanaged(Vfs.FileId, []const u8) = .empty,

    pub fn get(cache: *UriCache, file: Vfs.FileId) Allocator.Error![]const u8 {
        if (cache.uris.get(file)) |u| return u;
        const u = try uriFor(cache.server, cache.arena, file);
        try cache.uris.put(cache.arena, file, u);
        return u;
    }
};

/// Maps a URI in a read request to a known file; returns
/// null for files that are not open or do not exist
pub fn lookupFile(server: *Server, arena: Allocator, document_uri: []const u8) !?Vfs.FileId {
    const path = try doc_sync.documentPath(server, arena, document_uri) orelse return null;
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

/// The file, text, line index and position of a request
pub fn textPosition(server: *Server, r: *Resolver, arena: Allocator, document_uri: []const u8, pos: types.Position) !?struct { file: Vfs.FileId, text: []const u8, lines: offsets.LineIndex, offset: u32 } {
    const file = try server.lookupFile(arena, document_uri) orelse return null;
    const lines = try sourceLines(r.ctx, file);
    return .{ .file = file, .text = lines.text, .lines = lines, .offset = @intCast(lines.offsetOf(pos, server.encoding)) };
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

pub fn dupeStrings(arena: Allocator, list: []const []const u8) Allocator.Error![]const []const u8 {
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
    if (innermostWorkspaceLocked(server, path)) |ws| if (ws.project) |*p| {
        if (p.isSet("imports_derived")) options.derived = p.imports_derived;
        if (p.isSet("imports_sort")) options.sort = p.imports_sort;
    };
    return options;
}

/// The workspace root directory containing `path`
/// (the innermost one when nested), copied into `arena`
pub fn rootOf(server: *Server, arena: Allocator, path: []const u8) Allocator.Error!?[]const u8 {
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

// ── Background tasks and warnings ────────────────────────────────────

/// Sequence number of a compile result: project builds and single-file compiles each take one when
/// storing a result; larger is newer
pub fn nextCompileGeneration(server: *Server) u64 {
    return server.compile_generation.fetchAdd(1, .monotonic) + 1;
}

pub fn isShuttingDown(server: *Server) bool {
    server.workspaces_mutex.lockUncancelable(server.io);
    defer server.workspaces_mutex.unlock(server.io);
    return server.shutting_down;
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
pub fn waitIdle(server: *Server) void {
    server.busy_mutex.lockUncancelable(server.io);
    defer server.busy_mutex.unlock(server.io);
    while (server.busy != 0) server.busy_cond.waitUncancelable(server.io, &server.busy_mutex);
}

// ── Sending ──────────────────────────────────────────────────────────

pub fn send(server: *Server, bytes: []u8) void {
    defer server.gpa.free(bytes);
    server.out.writeMessage(bytes) catch |err| log.err("failed to write message: {t}", .{err});
}

/// The bytes of a successful response; null when they could not be built (out of memory).
fn responseBytes(server: *Server, id: jsonrpc.Id, result: anytype) ?[]u8 {
    return jsonrpc.response(server.gpa, id, result) catch {
        log.err("out of memory while building response", .{});
        return null;
    };
}

/// The bytes of an error response; null when they could not be built (out of memory).
fn errorResponseBytes(server: *Server, id: ?jsonrpc.Id, code: i32, message: []const u8) ?[]u8 {
    return jsonrpc.errorResponse(server.gpa, id, code, message) catch {
        log.err("out of memory while building error response", .{});
        return null;
    };
}

fn sendResponse(server: *Server, id: jsonrpc.Id, result: anytype) void {
    if (server.responseBytes(id, result)) |bytes| server.send(bytes);
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
    if (server.errorResponseBytes(id, code, message)) |bytes| server.send(bytes);
}

/// The bytes of the error response for `err` (see `sendHandlerError`); null when it could not be
/// built (out of memory).
fn handlerErrorBytes(server: *Server, id: jsonrpc.Id, err: anyerror, canceled_by_client: bool) ?[]u8 {
    const info: struct { code: i32, message: []const u8 } = switch (err) {
        error.Canceled => if (canceled_by_client)
            .{ .code = jsonrpc.error_codes.request_cancelled, .message = "request cancelled" }
        else
            .{ .code = jsonrpc.error_codes.content_modified, .message = "content modified" },
        error.InvalidParams => .{ .code = jsonrpc.error_codes.invalid_params, .message = "invalid params" },
        error.InvalidIdentifier => .{ .code = jsonrpc.error_codes.request_failed, .message = "new name is not a valid identifier" },
        // Answered only when the wait for scans or sub-projects was cut short, by a cancellation or
        // the shutdown (see `SemanticTask`)
        error.ScanPending, error.SubProjectsPending, error.LivePending => if (canceled_by_client)
            .{ .code = jsonrpc.error_codes.request_cancelled, .message = "request cancelled" }
        else
            .{ .code = jsonrpc.error_codes.request_failed, .message = "the server is shutting down" },
        else => .{ .code = jsonrpc.error_codes.internal_error, .message = @errorName(err) },
    };
    return server.errorResponseBytes(id, info.code, info.message);
}

fn sendHandlerError(server: *Server, id: jsonrpc.Id, err: anyerror, canceled_by_client: bool) void {
    if (server.handlerErrorBytes(id, err, canceled_by_client)) |bytes| server.send(bytes);
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
    _ = slow_log;
    _ = indexing;
    _ = doc_sync;
    _ = file_changes;
    _ = config_sync;
    _ = project_set;
    _ = publishing;
    _ = file_diagnostics;
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
