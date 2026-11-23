//! The diagnostics of a file: compiler results combined with live diagnostics, naming, unused
//! names, lint, inactive code, and suppression comments.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const za = @import("../zig_analyzer.zig");
const types = za.lsp.types;
const transport = za.lsp.transport;
const offsets = za.util.offsets;
const never = za.util.assert.never;
const uri = za.base.uri;
const Vfs = za.base.Vfs;
const database = @import("../database.zig");
const Db = database.Db;
const FileText = database.inputs.FileText;
const syntax_q = database.syntax;
const live = database.live;
const ide = za.ide;
const compiler = za.diagnostics.compiler;
const Workspace = @import("Workspace.zig");
const origin = @import("origin.zig");
const dependency_packages = za.project.packages;
const Resolver = za.names.resolve.Resolver;
const Config = @import("../Config.zig");

const Server = @import("Server.zig");
const file_changes = @import("file_changes.zig");
const project_set = @import("project_set.zig");
const publishing = @import("publishing.zig");

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

/// The state one diagnostic publish reads from the projects: classifying the origin and finding
/// the innermost workspace both take the workspace locks, so they are computed once and shared by
/// the compiler result and the analyzer-owned checks
const PublishContext = struct {
    origin: origin.Origin,
    file_context: project_set.FileContext,
    hints_eligible: bool,
    /// The innermost workspace containing the file (see `Server.innermostWorkspace`), with a
    /// reference held; null when no workspace contains it or when hints are not eligible
    workspace: ?*Workspace = null,

    fn init(server: *Server, file: Vfs.FileId, text: ?[]const u8) PublishContext {
        const in_project = server.inProject(file);
        const file_origin = server.originOf(file, in_project);
        var self: PublishContext = .{
            .origin = file_origin,
            .file_context = project_set.fileContextWithOrigin(server, file, file_origin, in_project),
            .hints_eligible = false,
        };
        if (text) |t| self.hints_eligible = hintsEligibleFor(server, file, file_origin, t);
        if (self.hints_eligible) self.workspace = server.innermostWorkspace(server.vfs.path(file));
        return self;
    }

    fn deinit(self: *PublishContext) void {
        if (self.workspace) |ws| ws.release();
    }
};

/// Compiler diagnostics of `file`: the results of the latest build of each project
/// that contains it; whether single-file compile results are used depends on the
/// file's context (see `FileContext.usesSingle`). Multiple results are merged with
/// `compiler.combine`, taking the text read by the newest compile as authoritative.
/// A reference to each result is taken under its lock and recorded in `other`; no lock is held
/// while merging.
fn compilerResult(server: *Server, arena: Allocator, file: Vfs.FileId, file_context: project_set.FileContext, other: *OtherFiles) Allocator.Error!?*const compiler.FileResult {
    const Found = struct {
        generation: u64,
        result: *const compiler.FileResult,

        fn newer(_: void, a: @This(), b: @This()) bool {
            return a.generation > b.generation;
        }
    };
    var found: std.ArrayList(Found) = .empty;
    {
        const list = try project_set.workspaceList(server, arena);
        defer project_set.releaseList(server, arena, list);
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
    if (file_context.usesSingle()) {
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

pub fn computeDiagnostics(server: *Server, ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId) !types.PublishDiagnosticsParams {
    const document_uri = try server.uriFor(arena, file);
    const text = try ctx.get(FileText, file);
    var publish = PublishContext.init(server, file, text);
    defer publish.deinit();

    // Live diagnostics: the file is loaded, and it belongs to no project or one of its projects
    // wants them (see `Workspace.liveEligible`)
    var live_result: ?*live.Result = null;
    // An open `.zon` file always: what makes it valid ZON does not depend on any build
    const is_zon = live.modeOf(server.vfs.path(file)) == .zon;
    if (text != null and (publishing.liveEligible(server, file) or (is_zon and file_changes.isOpen(server, server.vfs.path(file))))) live_result = try ctx.get(live.AstCheck, file);

    // Compiler diagnostics: errors in an imported file are
    // reported by the project or root file that compiles it
    var other: OtherFiles = .{ .server = server, .ctx = ctx };
    defer other.release();
    const fr = try compilerResult(server, arena, file, publish.file_context, &other);
    const current = text orelse if (fr) |r| r.base_text else "";
    // With `FileText`, the `SourceText` is that text, whose line table is cached
    const lines = if (text != null) try Server.sourceLines(ctx, file) else try offsets.LineIndex.init(arena, current);
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
    if (text != null) if (wantsInactiveCode(server, file)) {
        diags = try appendInactiveCode(server, ctx, arena, file, lines, diags);
    };
    if (publish.hints_eligible) {
        if (try namingForFile(server, arena, server.vfs.path(file), publish.workspace)) |settings| {
            diags = try appendNaming(server, ctx, arena, file, lines, settings, diags);
        }
        if (unusedForFile(server, publish.workspace)) {
            diags = try appendUnused(server, ctx, arena, file, lines, diags);
        }
        if (lintForFile(server, publish.workspace)) |rules| {
            diags = try appendLint(server, ctx, arena, file, lines, rules, diags);
        }
    }
    if (text != null) diags = try appendUnloadedProjectHint(server, arena, file, publish.file_context, lines, diags);
    if (text != null) diags = try appendUnfetchedDependencies(server, ctx, arena, file, publish.origin, lines, diags);
    if (text != null) if (is_zon and std.mem.eql(u8, std.fs.path.basename(server.vfs.path(file)), Config.project_file)) {
        diags = try appendProjectConfigProblems(server, arena, lines, diags);
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
    const params = try computeDiagnostics(&server, &ctx, arena, util);
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
fn appendUnloadedProjectHint(server: *Server, arena: Allocator, file: Vfs.FileId, file_context: project_set.FileContext, lines: offsets.LineIndex, diags: []const types.Diagnostic) ![]const types.Diagnostic {
    const path = server.vfs.path(file);
    if (!file_changes.isOpen(server, path) or !server.startup_done.load(.acquire) or project_set.projectsLoading(server)) return diags;
    if (file_context != .unloaded_project) return diags;
    const sub_project = try project_set.subProjectOf(server, arena, path);
    const dir = sub_project orelse project_set.projectDirOf(server, path) orelse return diags;
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

/// An `@import` in build.zig of a dependency that is not fetched (see `unfetchedImports`)
pub const UnfetchedImport = struct {
    /// The string literal
    start: u32,
    end: u32,
    name: []const u8,
    lazy: bool,
    /// Root of the project whose `zig build --fetch` fetches it
    root: []const u8,
};

/// The `@import`s in a build.zig of the dependencies its build.zig.zon gives by `.hash` that are
/// not fetched (see `Workspace.unfetchedDependencies`)
pub fn unfetchedImports(server: *Server, ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId) ![]const UnfetchedImport {
    if (!std.mem.eql(u8, std.fs.path.basename(server.vfs.path(file)), "build.zig")) return &.{};
    return unfetchedImportsWithOrigin(server, ctx, arena, file, server.fileOrigin(file));
}

/// `unfetchedImports` with the origin of the file already classified
fn unfetchedImportsWithOrigin(server: *Server, ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId, file_origin: origin.Origin) ![]const UnfetchedImport {
    const path = server.vfs.path(file);
    if (!std.mem.eql(u8, std.fs.path.basename(path), "build.zig")) return &.{};
    // A fetched package is not edited and its dependencies are fetched through the project
    if (file_origin != .user) return &.{};
    const dir = std.fs.path.dirname(path) orelse return &.{};
    var deps: []const dependency_packages.Unfetched = &.{};
    var root: []const u8 = "";
    {
        const list = try project_set.workspaceList(server, server.gpa);
        defer project_set.releaseList(server, server.gpa, list);
        for (list) |ws| {
            deps = try ws.unfetchedDependencies(arena, dir);
            if (deps.len != 0) {
                root = try arena.dupe(u8, ws.root);
                break;
            }
        }
    }
    if (deps.len == 0) return &.{};
    const parse = try ctx.get(syntax_q.ParseFile, file);
    var out: std.ArrayList(UnfetchedImport) = .empty;
    for (try za.syntax.FileIndex.importSites(arena, parse.rootNode())) |site| for (deps) |d| {
        if (!std.mem.eql(u8, site.name, d.name)) continue;
        try out.append(arena, .{ .start = site.start, .end = site.end, .name = d.name, .lazy = d.lazy, .root = root });
        break;
    };
    return out.items;
}

/// A warning on each `@import` in build.zig of a dependency that is not fetched: the import does
/// not resolve, and the configure fails, until it is fetched
fn appendUnfetchedDependencies(server: *Server, ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId, file_origin: origin.Origin, lines: offsets.LineIndex, diags: []const types.Diagnostic) ![]const types.Diagnostic {
    const found = try unfetchedImportsWithOrigin(server, ctx, arena, file, file_origin);
    if (found.len == 0) return diags;
    var out: std.ArrayList(types.Diagnostic) = .empty;
    try out.appendSlice(arena, diags);
    for (found) |u| try out.append(arena, .{
        .range = lines.range(u.start, u.end, server.encoding),
        .severity = .Warning,
        .code = .{ .string = ide.hints.unfetched_dependency_code },
        .source = ide.hints.source,
        .message = .{ .string = if (u.lazy)
            try std.fmt.allocPrint(arena, "lazy dependency `{s}` is not fetched, so this import does not resolve: zig build fetches a lazy dependency only when the build asks for it " ++
                "(`b.lazyDependency`, `b.lazyImport`); `zig build --fetch=all` fetches it", .{u.name})
        else
            try std.fmt.allocPrint(arena, "dependency `{s}` is not fetched, so this import does not resolve: `zig build --fetch` fetches it", .{u.name}) },
    });
    return out.items;
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
    const workspace = server.innermostWorkspace(path);
    defer if (workspace) |ws| ws.release();
    return namingForFile(server, arena, path, workspace);
}

/// `namingFor` for a file whose hints eligibility and innermost workspace are already known; the
/// workspace must have a reference held
fn namingForFile(server: *Server, arena: Allocator, path: []const u8, workspace: ?*Workspace) Allocator.Error!?NamingSettings {
    const config = server.config.load(.acquire);
    var enable = config.naming_enable;
    var ignore = config.naming_ignore;
    var exclude = config.naming_exclude;
    var rules = config.naming_rules;
    // `naming.exclude` paths are relative to the workspace root directory, or to the project root
    // directory when they come from `zig-analyzer.zon`
    var base = try server.rootOf(arena, path);
    if (workspace) |ws| if (ws.project) |*p| {
        if (p.isSet("naming_enable")) enable = p.naming_enable;
        if (p.isSet("naming_ignore")) ignore = try Server.dupeStrings(arena, p.naming_ignore);
        if (p.isSet("naming_rules")) rules = p.naming_rules;
        if (p.isSet("naming_exclude")) {
            exclude = try Server.dupeStrings(arena, p.naming_exclude);
            base = try arena.dupe(u8, ws.root);
        }
    };
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
    return hintsEligibleFor(server, file, server.fileOrigin(file), text);
}

/// `hintsEligible` with the origin of the file already classified
fn hintsEligibleFor(server: *Server, file: Vfs.FileId, file_origin: origin.Origin, text: []const u8) bool {
    {
        server.docs.mutex.lockUncancelable(server.io);
        defer server.docs.mutex.unlock(server.io);
        if (!server.docs.open.contains(file)) return false;
    }
    switch (file_origin) {
        .virtual, .user, .outside => {},
        .zig_lib, .generated, .package, .other => return false,
    }
    return !ide.naming.isGenerated(text);
}

/// Whether the file gets unused-declaration hints: the setting from the client or the project of
/// the file, for open user code that is not generated
fn unusedForFile(server: *Server, workspace: ?*Workspace) bool {
    var enable = server.config.load(.acquire).unused_enable;
    if (workspace) |ws| if (ws.project) |*p| {
        if (p.isSet("unused_enable")) enable = p.unused_enable;
    };
    return enable;
}

/// The lint rules the file gets, null when lint hints are off for it: the setting from the client
/// or the project of the file, for open user code that is not generated
pub fn lintFor(server: *Server, file: Vfs.FileId, text: []const u8) ?Config.LintRules {
    if (!hintsEligible(server, file, text)) return null;
    const workspace = server.innermostWorkspace(server.vfs.path(file));
    defer if (workspace) |ws| ws.release();
    return lintForFile(server, workspace);
}

/// `lintFor` for a file whose hints eligibility and innermost workspace are already known; the
/// workspace must have a reference held
fn lintForFile(server: *Server, workspace: ?*Workspace) ?Config.LintRules {
    const config = server.config.load(.acquire);
    var enable = config.lint_enable;
    var rules = config.lint_rules;
    if (workspace) |ws| if (ws.project) |*p| {
        if (p.isSet("lint_enable")) enable = p.lint_enable;
        if (p.isSet("lint_rules")) rules = p.lint_rules;
    };
    return if (enable) rules else null;
}

pub fn lintAllows(rules: Config.LintRules, rule: ide.lint.Rule) bool {
    return switch (rule) {
        inline else => |r| @field(rules, @tagName(r)),
    };
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
