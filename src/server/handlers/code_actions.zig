//! Code action requests (`textDocument/codeAction`, `codeAction/resolve`) and the commands
//! they carry (`workspace/executeCommand`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;
const za = @import("../../zig_analyzer.zig");
const types = za.lsp.types;
const uri = za.base.uri;
const Vfs = za.base.Vfs;
const ide = za.ide;
const package_manifest = za.project.manifest;
const Resolver = za.names.resolve.Resolver;

const Server = @import("../Server.zig");
const config_sync = @import("../config_sync.zig");
const doc_sync = @import("../doc_sync.zig");
const file_diagnostics = @import("../file_diagnostics.zig");
const references = @import("references.zig");
const rename = @import("rename.zig");
const HandlerError = Server.HandlerError;
const Outcome = Server.Outcome;
const apply_edit_prefix = Server.apply_edit_prefix;
const fetch_hash_command = Server.fetch_hash_command;
const not_editable = rename.not_editable;

const log = std.log.scoped(.server);

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

pub fn codeAction(server: *Server, r: *Resolver, arena: Allocator, params: types.CodeActionParams) HandlerError!types.ResultType("textDocument/codeAction") {
    // Every action is a `CodeAction` literal: most carry an edit, and the dependency hash action
    // carries a command
    if (!server.caps.code_action_literals) return null;
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const lines = try Server.sourceLines(r.ctx, file);
    const text = lines.text;
    const start, const end = server.rangeOffsets(lines, params.range);
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
    // Applies to the whole file regardless of the range, so it is left out of the unfiltered menu
    if (only != null and wantsKind(only, types.CodeActionKind.SourceFixAll)) {
        if (try ide.code_actions.fixAll(r, file)) |a| try actions.append(arena, a);
    }
    const doc_uri = try server.uriFor(arena, file);
    const Item = CodeActionItem;
    var out: std.ArrayList(Item) = .empty;
    for (actions.items) |a| {
        const kind = switch (a.kind) {
            .quickfix => types.CodeActionKind.QuickFix,
            .refactor_extract => types.CodeActionKind.RefactorExtract,
            .refactor_rewrite => types.CodeActionKind.RefactorRewrite,
            .source_organize_imports => types.CodeActionKind.SourceOrganizeImports,
            .source_fix_all => types.CodeActionKind.SourceFixAll,
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
            if (try removeParamAction(server, r, arena, doc_uri, range, t, params.context.diagnostics)) |action| try out.append(arena, .{ .CodeAction = action });
        }
    }
    if (wantsKind(only, types.CodeActionKind.QuickFix)) if (try file_diagnostics.namingFor(server, arena, file, text)) |settings| {
        for (try ide.naming.findings(r, file, .{ .start = start, .end = end })) |f| {
            if (!settings.allows(f)) continue;
            const range = lines.range(f.start, f.end, server.encoding);
            if (try namingAction(server, r, arena, doc_uri, range, f, params.context.diagnostics)) |action| try out.append(arena, .{ .CodeAction = action });
        }
    };
    if (wantsKind(only, types.CodeActionKind.QuickFix)) if (file_diagnostics.lintFor(server, file, text)) |rules| {
        for (try ide.lint.findings(r, file, .{ .start = start, .end = end })) |f| {
            if (!file_diagnostics.lintAllows(rules, f.rule)) continue;
            const fix = f.fix orelse continue;
            const range = lines.range(f.start, f.end, server.encoding);
            var action: types.CodeAction = .{
                .title = try std.fmt.allocPrint(arena, "remove `{s}`", .{text[f.start .. std.mem.indexOfScalarPos(u8, text, f.start, '(') orelse f.start]}),
                .kind = types.CodeActionKind.QuickFix,
                .isPreferred = true,
            };
            // Link the same hint sent by the client
            for (params.context.diagnostics) |d| {
                const c = d.code orelse continue;
                if (c == .string and std.mem.eql(u8, c.string, f.rule.code()) and std.meta.eql(d.range, range)) {
                    action.diagnostics = try arena.dupe(types.Diagnostic, &.{d});
                    break;
                }
            }
            var changes: std.json.ArrayHashMap([]const types.TextEdit) = .{};
            try changes.map.put(arena, doc_uri, try arena.dupe(types.TextEdit, &.{.{
                .range = lines.range(fix.start, fix.end, server.encoding),
                .newText = fix.text,
            }}));
            action.edit = .{ .changes = changes };
            try out.append(arena, .{ .CodeAction = action });
        }
    };
    if (server.caps.apply_edit and wantsKind(only, types.CodeActionKind.QuickFix)) try dependencyHashActions(server, arena, file, doc_uri, text, start, end, &out);
    return out.items;
}

/// A code action result item (`CodeAction` or `Command`)
const CodeActionItem = @typeInfo(@typeInfo(types.ResultType("textDocument/codeAction")).optional.child).pointer.child;

/// Code actions that fetch the hash of a `build.zig.zon` dependency with `zig fetch`. Each action
/// carries the command that runs the fetch, so the network request starts only when the user picks
/// it; the edit is computed from the manifest as it is then (see `executeCommand`).
fn dependencyHashActions(
    server: *Server,
    arena: Allocator,
    file: Vfs.FileId,
    doc_uri: []const u8,
    text: []const u8,
    start: u32,
    end: u32,
    out: *std.ArrayList(CodeActionItem),
) !void {
    if (!std.mem.eql(u8, std.fs.path.basename(server.vfs.path(file)), "build.zig.zon")) return;
    const manifest = (try package_manifest.parse(arena, text)) orelse return;
    const dep = package_manifest.dependencyAt(&manifest, start, end) orelse return;
    const url = dep.url orelse return;
    const title = if (dep.hash != null)
        try std.fmt.allocPrint(arena, "update hash for `{s}`", .{dep.name})
    else
        try std.fmt.allocPrint(arena, "fetch hash for `{s}`", .{dep.name});
    const arguments: std.json.ObjectMap = try .init(arena, &.{ "uri", "dependency", "url" }, &.{
        .{ .string = doc_uri },
        .{ .string = dep.name },
        .{ .string = url },
    });
    try out.append(arena, .{ .CodeAction = .{
        .title = title,
        .kind = types.CodeActionKind.QuickFix,
        .command = .{
            .title = title,
            .command = fetch_hash_command,
            .arguments = try arena.dupe(types.LSPAny, &.{.{ .object = arguments }}),
        },
    } });
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
        if (!server.caps.code_action_disabled) return null;
        action.disabled = .{ .reason = try rename.renameProblem(server, r, arena, f.name, f.suggestion, p.file, p.offset, p.message) };
        return action;
    }
    if (server.caps.code_action_resolve) {
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
    switch (try namingEdit(server, r, arena, f)) {
        .ok => |edit| action.edit = edit,
        .failed => |reason| {
            if (!server.caps.code_action_disabled) return null;
            action.disabled = .{ .reason = reason };
        },
    }
    return action;
}

/// Fills in the edits of naming fixes and parameter removals; other code actions are already
/// complete from `textDocument/codeAction` and are returned unchanged
pub fn codeActionResolve(server: *Server, r: *Resolver, arena: Allocator, params: types.CodeAction) HandlerError!Outcome(types.CodeAction) {
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
        switch (try namingEdit(server, r, arena, found)) {
            .ok => |edit| action.edit = edit,
            .failed => |reason| return .{ .failed = reason },
        }
    } else if (data.remove_param) |d| {
        const at = try server.textPosition(r, arena, d.uri, .{ .line = d.line, .character = d.character }) orelse
            return .{ .failed = "cannot remove parameter: the document is no longer available" };
        const found = for (try ide.remove_param.targets(r, at.file, at.offset, at.offset)) |t| {
            if (t.start == at.offset and std.mem.eql(u8, t.name, d.name)) break t;
        } else return .{ .failed = "cannot remove parameter: the parameter has changed since the fix was offered" };
        switch (try removeParamEdit(server, r, arena, found)) {
            .ok => |edit| action.edit = edit,
            .failed => |reason| return .{ .failed = reason },
        }
    }
    return .{ .ok = action };
}

/// The argument of `fetch_hash_command`: the manifest and the dependency the action was offered on
const FetchHashArgs = struct {
    uri: []const u8,
    dependency: []const u8,
    url: []const u8,
};

/// Runs `zig fetch <url>` for a dependency and applies the hash to the manifest with
/// `workspace/applyEdit`. Runs on a background task, outside any read transaction, because the
/// download can take a long time; the edit is computed after it, against the manifest as it is then.
pub fn executeCommand(server: *Server, arena: Allocator, params: types.ExecuteCommandParams) HandlerError!types.ResultType("workspace/executeCommand") {
    if (!std.mem.eql(u8, params.command, fetch_hash_command)) return error.InvalidParams;
    const arguments = params.arguments orelse return error.InvalidParams;
    if (arguments.len == 0) return error.InvalidParams;
    const args = std.json.parseFromValueLeaky(FetchHashArgs, arena, arguments[0], .{ .ignore_unknown_fields = true }) catch return error.InvalidParams;
    if (!server.caps.apply_edit) return error.InvalidParams;
    const path = (try doc_sync.documentPath(server, arena, args.uri)) orelse return error.InvalidParams;
    const dir = std.fs.path.dirname(path) orelse return error.InvalidParams;

    const title = try std.fmt.allocPrint(arena, "fetching hash for `{s}`", .{args.dependency});
    var progress = server.progress.begin(server, title, false);
    defer if (progress) |p| server.progress.end(server, p, "failed");

    const config = server.config.load(.acquire);
    const argv = [_][]const u8{ config.zig_path orelse "zig", "fetch", args.url };
    const result = std.process.run(server.gpa, server.io, .{
        .argv = &argv,
        .cwd = .{ .path = dir },
        .environ_map = server.zig_environ.load(.acquire),
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        // A wrapper script (asdf, mise) or a large download may take a while; a hung one must end
        .timeout = .{ .duration = .{ .raw = Io.Duration.fromSeconds(120), .clock = .awake } },
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        try warnFetch(server, arena, args.dependency, switch (err) {
            error.FileNotFound, error.AccessDenied, error.InvalidExe => "the zig executable cannot be run",
            error.Timeout => "zig fetch timed out",
            else => @errorName(err),
        });
        return null;
    };
    defer server.gpa.free(result.stdout);
    defer server.gpa.free(result.stderr);
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => {
            try warnFetch(server, arena, args.dependency, "zig fetch ended without an exit code");
            return null;
        },
    };
    if (code != 0) {
        try warnFetch(server, arena, args.dependency, errorLine(result.stderr) orelse "zig fetch failed");
        return null;
    }
    const hash = fetchedHash(result.stdout) orelse {
        try warnFetch(server, arena, args.dependency, "zig fetch printed no hash");
        return null;
    };

    const edit = blk: {
        var ctx = server.db.beginRead(arena);
        defer ctx.end();
        const file = (try server.lookupFile(arena, args.uri)) orelse try server.vfs.intern(path);
        const lines = try Server.sourceLines(&ctx, file);
        const manifest = (try package_manifest.parse(arena, lines.text)) orelse break :blk null;
        const hash_edit = (try package_manifest.hashEdit(arena, &manifest, args.dependency, args.url, hash)) orelse break :blk null;
        break :blk .{ .range = lines.range(hash_edit.start, hash_edit.end, server.encoding), .newText = hash_edit.text };
    } orelse {
        try warnFetch(server, arena, args.dependency, "the dependency changed since the action was offered");
        return null;
    };

    var changes: std.json.ArrayHashMap([]const types.TextEdit) = .{};
    try changes.map.put(arena, args.uri, try arena.dupe(types.TextEdit, &.{.{ .range = edit.range, .newText = edit.newText }}));
    const label = try std.fmt.allocPrint(arena, "zig-analyzer: hash of `{s}`", .{args.dependency});
    const id = try std.fmt.allocPrint(arena, "{s}{d}", .{ apply_edit_prefix, server.next_apply_edit.fetchAdd(1, .monotonic) });
    server.sendRequest(.{ .string = id }, "workspace/applyEdit", types.ApplyWorkspaceEditParams{
        .label = label,
        .edit = .{ .changes = changes },
    });
    server.progress.end(server, progress, "fetched");
    progress = null;
    return null;
}

/// Reports why a dependency hash could not be computed or applied
fn warnFetch(server: *Server, arena: Allocator, dependency: []const u8, reason: []const u8) Allocator.Error!void {
    server.showWarning(try std.fmt.allocPrint(arena, "cannot fetch the hash of `{s}`: {s}", .{ dependency, reason }));
}

/// The hash `zig fetch` prints: its last non-empty line, when it has no whitespace or quote
fn fetchedHash(stdout: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    var last: ?[]const u8 = null;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len != 0) last = trimmed;
    }
    const hash = last orelse return null;
    for (hash) |c| if (std.ascii.isWhitespace(c) or c == '"' or c == '\\') return null;
    return hash;
}

/// The last non-empty line of `stderr`, as the reason shown to the user
fn errorLine(stderr: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    var last: ?[]const u8 = null;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len != 0) last = trimmed;
    }
    return last;
}

/// The client's answer to `workspace/applyEdit`: says so when it did not apply the edit
pub fn applyEditResponse(server: *Server, result: json.Value, failed: bool) void {
    if (failed) {
        log.warn("the client rejected workspace/applyEdit", .{});
        server.showWarning("cannot apply the dependency hash: the client rejected the edit");
        return;
    }
    if (result != .object) return;
    const applied = result.object.get("applied") orelse return;
    if (applied == .bool and applied.bool) return;
    const reason = if (result.object.get("failureReason")) |r| switch (r) {
        .string => |s| s,
        else => "the client did not apply the edit",
    } else "the client did not apply the edit";
    var buf: [1024]u8 = undefined;
    server.showWarning(std.fmt.bufPrint(&buf, "cannot apply the dependency hash: {s}", .{reason}) catch "cannot apply the dependency hash");
}

/// Renames a name that violates the naming conventions to the suggested spelling. Returns only
/// complete and safe edits, as rename does (see `checkedRename`): nothing is renamed when some
/// reference cannot be confirmed, the new name conflicts with an existing one, or the name appears
/// in a string (reflection).
fn namingEdit(server: *Server, r: *Resolver, arena: Allocator, f: ide.naming.Located) !Outcome(types.WorkspaceEdit) {
    const def = f.def;
    if (try rename.renameRefusal(server, r, .{ .def = def })) |reason| return .{ .failed = reason };
    const checked = switch (try rename.checkedRename(server, r, arena, def, f.name, f.suggestion)) {
        .ok => |checked| checked,
        .failed => |reason| return .{ .failed = reason },
    };
    const confirm = if (f.public) try std.fmt.allocPrint(arena, "Rename public `{s}` to `{s}`", .{ f.name, f.suggestion }) else null;
    return .{ .ok = try rename.renameEdit(server, r, arena, checked.refs, checked.text, confirm) };
}

/// Removes an unused parameter together with the matching argument at each call site, applied
/// only when the user selects it (not marked preferred). Calls in the whole workspace have to be
/// found: when the client supports `codeAction/resolve`, only the title and `data` are given, and
/// the edits are computed after selection; otherwise they are computed right away. When the
/// parameter cannot be removed, the reason is attached if the client supports `disabled`;
/// otherwise the action is not offered.
fn removeParamAction(server: *Server, r: *Resolver, arena: Allocator, doc_uri: []const u8, range: types.Range, t: ide.remove_param.Target, client_diagnostics: []const types.Diagnostic) !?types.CodeAction {
    if (try rename.renameRefusal(server, r, .{ .def = .{ .item = .{ .file = t.file, .item = t.item } } }) != null) return null;
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
    if (server.caps.code_action_resolve) {
        const inner: std.json.ObjectMap = try .init(arena, &.{ "uri", "line", "character", "name" }, &.{
            .{ .string = doc_uri },
            .{ .integer = range.start.line },
            .{ .integer = range.start.character },
            .{ .string = t.name },
        });
        action.data = .{ .object = try .init(arena, &.{"remove_param"}, &.{.{ .object = inner }}) };
        return action;
    }
    switch (try removeParamEdit(server, r, arena, t)) {
        .ok => |edit| action.edit = edit,
        .failed => |reason| {
            if (!server.caps.code_action_disabled) return null;
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
    if (try references.scopeIncompleteFor(server, r, .{ .def = .{ .item = .{ .file = t.file, .item = t.item } } }, .edit)) |reason|
        return .{ .failed = try std.fmt.allocPrint(arena, "cannot remove parameter `{s}`: {s}", .{ t.name, reason }) };
    const prefix = try std.fmt.allocPrint(arena, "cannot remove parameter `{s}`", .{t.name});
    switch (try ide.remove_param.edits(r, t, try server.searchScope(r))) {
        .ok => |files| {
            const rules = try server.originRules(arena);
            for (files) |fe| if (!rename.editable(server, rules, fe.file)) {
                return .{ .failed = try rename.fixProblem(server, r, arena, prefix, fe.file, if (fe.edits.len != 0) fe.edits[0].start else null, not_editable) };
            };
            return .{ .ok = try rename.workspaceEdit(server, r, arena, files, if (t.public) .{
                .id = "zig-analyzer.remove-param-public",
                .label = try std.fmt.allocPrint(arena, "Remove parameter `{s}` of public `{s}`", .{ t.name, fn_name }),
                .description = "code outside this workspace that calls the function is not updated",
            } else null) };
        },
        .failed => |p| return .{ .failed = try rename.fixProblem(server, r, arena, prefix, p.file, p.offset, p.message) },
    }
}
