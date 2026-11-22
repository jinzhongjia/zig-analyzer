//! Inspection requests (`zig-analyzer/status`, `fileStatus`, `packages`, `syntaxTree`, and
//! `moduleGraph`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const za = @import("../../zig_analyzer.zig");
const types = za.lsp.types;
const database = @import("../../database.zig");
const Db = database.Db;
const syntax_q = database.syntax;
const package_manifest = za.project.manifest;
const dependency_packages = za.project.packages;
const Workspace = @import("../Workspace.zig");
const origin = @import("../origin.zig");
const ModuleGraph = za.names.ModuleGraph;

const Server = @import("../Server.zig");
const FileContext = Server.FileContext;
const HandlerError = Server.HandlerError;

const StatusResult = struct {
    /// Version of the server executable (as in `serverInfo.version` and `--version`)
    version: []const u8,
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
    /// Memory held by the release allocator (null in builds that do not use it)
    allocator: ?za.util.PagedAllocator.Stats,
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
    /// Cumulative counts of incomplete results by cause (cycles, stack depth, unavailable tools)
    incomplete_causes: struct { cycle: u64, stack: u64, unavailable: u64 },
};

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

/// The packages of each workspace root: the `build.zig.zon` fields, and for each dependency
/// whether its directory is on disk and where its manifest and build script are
const PackagesResult = struct {
    projects: []const Project,

    const Project = struct {
        root: []const u8,
        manifest: []const u8,
        name: ?[]const u8,
        version: ?[]const u8,
        fingerprint: ?[]const u8,
        minimum_zig_version: ?[]const u8,
        /// `[""]` means every file is included
        paths: []const []const u8,
        dependencies: []const Dependency,
        /// Why the manifest could not be read; the other fields are then empty
        parse_error: ?[]const u8,
    };

    const Dependency = struct {
        name: []const u8,
        kind: enum { url, path, none },
        url: ?[]const u8,
        path: ?[]const u8,
        hash: ?[]const u8,
        lazy: ?bool,
        /// Where the dependency is expected: the `.path` resolved against the project, or the
        /// package directory entry of a `.hash`
        root: ?[]const u8,
        exists: bool,
        manifest: ?[]const u8,
        build_zig: ?[]const u8,
    };
};

/// How the file is treated: origin, compile context, the modules and
/// projects it belongs to, the related single-file compiles. Used to
/// diagnose problems that users report with diagnostics or name resolution.
pub fn fileStatus(server: *Server, ctx: *Db.Ctx, arena: Allocator, params: DocumentParams) HandlerError!?FileStatusResult {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const open = blk: {
        server.docs.mutex.lockUncancelable(server.io);
        defer server.docs.mutex.unlock(server.io);
        break :blk server.docs.open.contains(file);
    };
    var modules: std.ArrayList([]const u8) = .empty;
    if (try ctx.get(ModuleGraph.Input, {})) |g| if (g.entry(file)) |e| {
        try modules.append(arena, moduleName(server, g, e.module));
        for (e.others) |m| try modules.append(arena, moduleName(server, g, m));
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
        server.single.mutex.lockUncancelable(server.io);
        defer server.single.mutex.unlock(server.io);
        for (server.single.entries.keys(), server.single.entries.values()) |root, *sf| {
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

/// The `build.zig.zon` of each workspace root, with its dependencies and the directories they
/// resolve to. The manifest text is the open buffer when there is one, the file on disk otherwise.
pub fn packagesRequest(server: *Server, ctx: *Db.Ctx, arena: Allocator, _: void) HandlerError!PackagesResult {
    const roots = try server.rootsAlloc(arena);
    const workspaces = try server.workspaceList(arena);
    defer server.releaseList(arena, workspaces);
    var projects: std.ArrayList(PackagesResult.Project) = .empty;
    const config = server.config.load(.acquire);
    const env_pkg_dir: ?[]const u8 = if (server.zig_environ.load(.acquire)) |m| m.get("ZIG_LOCAL_PKG_DIR") else server.environ.getAlloc(arena, "ZIG_LOCAL_PKG_DIR") catch null;
    for (roots) |root| {
        // A project's `zig-analyzer.zon` can set `build.args` (such as `--pkg-dir`) and its
        // environment can name the package directory
        var build_args: []const []const u8 = config.build_args;
        var pkg_env = env_pkg_dir;
        for (workspaces) |ws| if (server.vfs.samePath(ws.root, root)) {
            build_args = ws.config.build_args;
            if (ws.env.childEnviron()) |m| pkg_env = m.get("ZIG_LOCAL_PKG_DIR");
            break;
        };
        const manifest_path = try std.fs.path.join(arena, &.{ root, "build.zig.zon" });
        const known = try server.vfs.lookup(manifest_path);
        if (known == null and accessible(server.io, manifest_path) == null) continue;
        const file = known orelse try server.vfs.intern(manifest_path);
        const lines = try Server.sourceLines(ctx, file);
        var project: PackagesResult.Project = .{
            .root = root,
            .manifest = manifest_path,
            .name = null,
            .version = null,
            .fingerprint = null,
            .minimum_zig_version = null,
            .paths = &.{},
            .dependencies = &.{},
            .parse_error = null,
        };
        const manifest = try package_manifest.parse(arena, lines.text) orelse {
            project.parse_error = "cannot parse build.zig.zon";
            try projects.append(arena, project);
            continue;
        };
        project.name = manifest.name;
        project.version = manifest.version;
        project.fingerprint = manifest.fingerprint;
        project.minimum_zig_version = manifest.minimum_zig_version;
        project.paths = manifest.paths;
        const pkg_dir = try dependency_packages.packageDir(arena, root, build_args, pkg_env);
        const dependencies = try arena.alloc(PackagesResult.Dependency, manifest.dependencies.len);
        for (manifest.dependencies, dependencies) |dep, *out| {
            const kind: @FieldType(PackagesResult.Dependency, "kind") = if (dep.url != null) .url else if (dep.path != null) .path else .none;
            const resolved: ?[]const u8 = if (dep.path) |p|
                try std.fs.path.resolveAlloc(arena, &.{ root, p })
            else if (dep.url != null and dep.hash != null)
                try std.fs.path.join(arena, &.{ pkg_dir, dep.hash.? })
            else
                null;
            out.* = .{
                .name = dep.name,
                .kind = kind,
                .url = dep.url,
                .path = dep.path,
                .hash = dep.hash,
                .lazy = dep.lazy,
                .root = resolved,
                .exists = false,
                .manifest = null,
                .build_zig = null,
            };
            if (resolved) |dir| {
                out.exists = accessible(server.io, dir) != null;
                if (out.exists) {
                    out.manifest = try existingPath(server.io, arena, dir, "build.zig.zon");
                    out.build_zig = try existingPath(server.io, arena, dir, "build.zig");
                }
            }
        }
        project.dependencies = dependencies;
        try projects.append(arena, project);
    }
    return .{ .projects = projects.items };
}

fn accessible(io: Io, path: []const u8) ?void {
    Io.Dir.cwd().access(io, path, .{}) catch return null;
    return {};
}

/// `<dir>/<name>` when it exists, null otherwise
fn existingPath(io: Io, arena: Allocator, dir: []const u8, name: []const u8) Allocator.Error!?[]const u8 {
    const path = try std.fs.path.join(arena, &.{ dir, name });
    if (accessible(io, path) == null) return null;
    return path;
}

/// Syntax tree of the document: indented nodes and tokens (without trivia) with their byte ranges,
/// followed by the syntax errors. Used to diagnose problems with parsing and error recovery.
pub fn syntaxTree(server: *Server, ctx: *Db.Ctx, arena: Allocator, params: DocumentParams) HandlerError!?[]const u8 {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const parse = try ctx.get(syntax_q.ParseFile, file);
    var out: std.Io.Writer.Allocating = .init(arena);
    parse.rootNode().dump(&out.writer, .{ .token_ranges = true }) catch return error.OutOfMemory;
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
pub fn moduleGraph(server: *Server, ctx: *Db.Ctx, arena: Allocator, _: void) HandlerError!ModuleGraphResult {
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

pub fn status(server: *Server, _: *Db.Ctx, arena: Allocator, _: void) HandlerError!StatusResult {
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
        .version = za.version,
        .revision = summary.revision,
        .files = server.vfs.count(),
        .deep_verifications = summary.deep_verifications,
        .writes = summary.writes,
        .max_rss_kb = maxRssKb(),
        .intern_pool_items = server.ip.count(),
        .intern_pool_bytes = server.ip.bytes(),
        .heap_bytes = if (server.heap) |h| h.liveBytes() else 0,
        .allocator = if (server.allocator_stats) |f| try f(arena) else null,
        .queries = queries,
        .incomplete_causes = .{
            .cycle = summary.incomplete_causes.get(.cycle),
            .stack = summary.incomplete_causes.get(.stack),
            .unavailable = summary.incomplete_causes.get(.unavailable),
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
