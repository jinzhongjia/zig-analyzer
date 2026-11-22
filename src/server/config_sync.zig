//! Configuration: `workspace/didChangeConfiguration`, pulling settings with
//! `workspace/configuration`, and applying a new configuration.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const za = @import("../zig_analyzer.zig");
const types = za.lsp.types;
const database = @import("../database.zig");
const Db = database.Db;
const compiler = za.diagnostics.compiler;
const Config = @import("../Config.zig");

const Server = @import("Server.zig");
const file_changes = @import("file_changes.zig");
const indexing = @import("indexing.zig");
const project_set = @import("project_set.zig");
const publishing = @import("publishing.zig");

const log = std.log.scoped(.server);

/// Stops waiting for the client's replies to configuration requests (on shutdown, or when the
/// main loop ends)
pub fn abandonConfigRequests(server: *Server) void {
    server.startup_pending = false;
    endConfigPull(server);
    while (server.config_outstanding > 0) : (server.config_outstanding -= 1) server.busyEnd();
}

pub fn didChangeConfiguration(server: *Server, _: Allocator, params: types.DidChangeConfigurationParams) !void {
    // Clients that only notify "the configuration has changed" without contents (such as VS Code):
    // pull the configuration from the client
    if (params.settings == .null) {
        if (server.caps.pull_config) requestConfig(server);
        return;
    }
    const fresh = Config.parse(server.gpa, params.settings) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidConfig => return server.showWarning("invalid zig-analyzer settings, keeping the previous ones"),
    };
    try applyConfig(server, fresh);
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
    const unused_changed = server.config.unused_enable != new.unused_enable;
    const lint_changed = !server.config.sameLint(&new);
    const build_was_enabled = server.config.build_enable;
    const sub_projects_changed = server.config.build_sub_projects != new.build_sub_projects;
    const watcher_changed = server.config.files_watcher != new.files_watcher;
    const inlay_changed = server.config.inlay_types != new.inlay_types or server.config.inlay_capture_types != new.inlay_capture_types or
        server.config.inlay_field_types != new.inlay_field_types or
        server.config.inlay_anonymous_containers != new.inlay_anonymous_containers or
        server.config.inlay_parameters != new.inlay_parameters or server.config.inlay_builtin_parameters != new.inlay_builtin_parameters or
        server.config.inlay_exclude_single_argument != new.inlay_exclude_single_argument or
        server.config.hide_redundant_param_names != new.hide_redundant_param_names or server.config.inlay_max_length != new.inlay_max_length or
        server.config.callsite_seeding != new.callsite_seeding;
    const compiler_disabled = server.config.compiler_diagnostics and !new.compiler_diagnostics;
    const log_file_changed = !eqlOptionalStr(server.config.log_file, new.log_file);
    applyLogging(server, &new, log_file_changed);
    applyCacheLimits(server, &new);
    server.config.deinit(server.gpa);
    server.config = new;
    server.config_mutex.unlock(server.io);
    project_set.wakeProjectWaiters(server);
    if (inactive_changed or naming_changed or unused_changed or lint_changed) publishing.publishOpenFiles(server);
    if (watcher_changed) file_changes.resyncWatcher(server);

    if (zig_changed and server.started) server.showWarning("zig.path takes effect after restarting zig-analyzer");
    // Before startup, the startup phase applies them with the current configuration
    if (zig_paths_changed and server.started) {
        server.busyBegin();
        Server.spawn(server.io, &server.bg_group, project_set.reloadZigPathsTask, .{server});
    }
    if (compiler_disabled) server.single.clear();
    if (inlay_changed) server.requestInlayRefresh();
    if (semantic_changed) server.requestSemanticRefresh();
    if (imports_enabled) {
        if (server.index.imports_wanted.load(.acquire)) indexing.scheduleIndexing(server);
        indexing.requestAutoImportIndex(server);
    }
    if (build_changed) {
        if (!new.build_enable) {
            // Build system integration turned off: stop the projects; their files are handled
            // in single-file mode instead
            project_set.stopProjects(server);
        } else if (!build_was_enabled) {
            if (project_set.zigEnv(server) != null) project_set.startProjectsForRoots(server);
        } else {
            const list = try project_set.workspaceList(server, server.gpa);
            defer project_set.releaseList(server, server.gpa, list);
            if (list.len != 0) log.info("build settings changed, restarting projects", .{});
            for (list) |ws| project_set.restartWorkspace(server, ws, 0);
        }
        // Files' compile contexts may have changed, and compiler diagnostics may be re-enabled
        server.single.reconcile();
    }
    if (sub_projects_changed and new.build_enable) {
        // Off: the projects of sub-projects stop, and their open files get the unloaded-project
        // hint. On: those that contain open documents start.
        if (project_set.stopStrayProjects(server)) indexing.updateModuleGraph(server);
        project_set.startOpenSubProjects(server);
        publishing.publishOpenFiles(server);
        server.single.reconcile();
    }
}

/// Whether build system integration and compiler diagnostics are enabled
pub fn buildFlags(server: *Server) struct { build: bool, compiler: bool } {
    server.config_mutex.lockUncancelable(server.io);
    defer server.config_mutex.unlock(server.io);
    return .{ .build = server.config.build_enable, .compiler = server.config.compiler_diagnostics };
}

/// Log level and slow request threshold; with `reopen_file`, reopens the log file as configured
pub fn applyLogging(server: *Server, config: *const Config, reopen_file: bool) void {
    za.util.log.setLevel(config.log_level);
    server.slow_request_ms.store(config.slow_request_ms, .monotonic);
    server.debounce_ms.store(config.debounce_ms, .monotonic);
    server.max_intern_pool_mb.store(config.max_intern_pool_mb, .monotonic);
    server.callsite_seeding.store(config.callsite_seeding, .monotonic);
    server.sub_projects_enabled.store(config.build_sub_projects, .release);
    if (!reopen_file) return;
    za.util.log.setFile(config.log_file) catch |err| {
        log.warn("cannot open log file {s}: {t}", .{ config.log_file.?, err });
        server.showWarning("cannot open log.file, logging to stderr only");
    };
}

/// Cache capacity: settings in `cache.queries` take precedence; the number of syntax trees
/// (`ParseFile` and `FileAstIdMap`) defaults to `cache.capacity`
pub fn applyCacheLimits(server: *Server, config: *const Config) void {
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

pub fn eqlOptionalStr(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

pub const config_request_prefix = "zig-analyzer/configuration/";

/// Pulls the `zig-analyzer` configuration section from the client; the response is handled by
/// `handleConfigResponse`
pub fn requestConfig(server: *Server) void {
    var buf: [64]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, config_request_prefix ++ "{d}", .{server.config_requests}) catch unreachable;
    server.config_requests += 1;
    server.config_outstanding += 1;
    server.busyBegin();
    server.sendRequest(.{ .string = id }, "workspace/configuration", types.ConfigurationParams{ .items = &.{.{ .section = "zig-analyzer" }} });
}

pub fn handleConfigResponse(server: *Server, id: []const u8, result: json.Value, failed: bool) Allocator.Error!void {
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
        project_set.startProjects(server);
        endConfigPull(server);
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
    try applyConfig(server, fresh);
}

/// A copy of the current configuration (freed by the caller)
pub fn configSnapshot(server: *Server) Allocator.Error!Config {
    server.config_mutex.lockUncancelable(server.io);
    defer server.config_mutex.unlock(server.io);
    return server.config.clone(server.gpa);
}

fn endConfigPull(server: *Server) void {
    server.config_pulling.store(false, .release);
    project_set.wakeProjectWaiters(server);
}
