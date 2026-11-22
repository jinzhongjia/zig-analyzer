//! Rename requests: `textDocument/prepareRename` and `textDocument/rename`, and the checked
//! rename edits that code actions reuse.

const std = @import("std");
const Allocator = std.mem.Allocator;
const za = @import("../../zig_analyzer.zig");
const types = za.lsp.types;
const Vfs = za.base.Vfs;
const ide = za.ide;
const origin = @import("../origin.zig");
const Resolver = za.names.resolve.Resolver;

const Server = @import("../Server.zig");
const references = @import("references.zig");
const HandlerError = Server.HandlerError;
const Outcome = Server.Outcome;
const RangeMapper = references.RangeMapper;

/// Why `symbol` cannot be renamed, or null when it can: the user's own code (see
/// `origin.Origin.user`) and unsaved documents can be renamed. In a file outside the workspace
/// folders (`origin.Origin.outside`), only what its own file alone can refer to can be renamed
/// (see `ownFileOnly`): which other files use the rest is not known. That includes files outside
/// the workspace folders that a project's module graph includes (modules added by path, such as a
/// library a workspace folder depends on by `.path`): the library's other users (its tests, its
/// other dependents) are not in the workspace either.
pub fn renameRefusal(server: *Server, r: *Resolver, symbol: za.ide_db.search.Symbol) !?[]const u8 {
    const file = switch (symbol) {
        .def => |def| switch (def) {
            .item => |it| it.file,
            .local => |l| l.file,
            // `@import` and its path string lead to a file, which is not a name in the code
            .file => return "cannot rename: the cursor is on the import of a file, and files cannot be renamed",
        },
        .label => |l| l.file,
        .error_name => |e| e.file,
        .zon_field => |z| blk: {
            if (try ide.manifest.active(r, z.literal.file)) return "cannot rename a field of build.zig.zon: its names are defined by the package format";
            break :blk z.literal.file;
        },
    };
    if (try za.ide_db.search.symbolName(r, symbol) == null) return "cannot rename: there is no name here";
    const rules = try server.originRules(r.arena);
    return switch (origin.classify(&server.vfs, rules, server.vfs.path(file), false)) {
        // Unsaved documents (`untitled:` etc.) exist only in the editor
        .virtual, .user => null,
        .outside => if (try references.ownFileOnly(r, symbol))
            null
        else if (symbol == .error_name)
            "cannot rename an error name in a file outside the workspace folders: error names are global, and the files that use it are not known"
        else
            "cannot rename a public declaration or field of a file outside the workspace folders: the files that use it are not known",
        .zig_lib, .generated, .package, .other => "cannot rename a symbol defined outside the workspace",
    };
}

pub fn prepareRename(server: *Server, r: *Resolver, arena: Allocator, params: types.PrepareRenameParams) HandlerError!Outcome(types.ResultType("textDocument/prepareRename")) {
    const at = try server.textPosition(r, arena, params.textDocument.uri, params.position) orelse return .{ .ok = null };
    const tok = try ide.definition.tokenAt(r, at.file, at.offset) orelse return .{ .ok = null };
    if (tok.kind != .identifier) return .{ .ok = null };
    const symbol = try ide.definition.symbolAt(r, at.file, at.offset) orelse return .{ .ok = null };
    if (try renameRefusal(server, r, symbol)) |reason| return .{ .failed = reason };
    if (symbol == .def) if (try ide.rename.stdRootLookup(r, symbol.def)) |p| {
        const prefix = try std.fmt.allocPrint(arena, "cannot rename `{s}`", .{za.syntax.ast.identName(tok.text)});
        return .{ .failed = try fixProblem(server, r, arena, prefix, p.file, p.offset, p.message) };
    };
    const lines = at.lines;
    return .{ .ok = .{ .PrepareRenamePlaceholder = .{
        .range = lines.range(tok.offset, tok.offset + @as(u32, @intCast(tok.text.len)), server.encoding),
        .placeholder = za.syntax.ast.identName(tok.text),
    } } };
}

pub fn rename(server: *Server, r: *Resolver, arena: Allocator, params: types.RenameParams) HandlerError!Outcome(types.ResultType("textDocument/rename")) {
    _ = try identifierText(arena, params.newName, false);
    const at = try server.textPosition(r, arena, params.textDocument.uri, params.position) orelse return .{ .ok = null };
    const symbol = try ide.definition.symbolAt(r, at.file, at.offset) orelse return .{ .ok = null };
    if (try renameRefusal(server, r, symbol)) |reason| return .{ .failed = reason };
    const old = (try za.ide_db.search.symbolName(r, symbol)).?;
    const outcome = switch (symbol) {
        .def => |def| try checkedRename(server, r, arena, def, old, params.newName),
        .label => |l| try checkedLabelRename(server, r, arena, l, old, params.newName),
        .error_name => |e| try checkedErrorRename(server, r, arena, e.file, old, params.newName),
        .zon_field => |z| try checkedZonFieldRename(server, r, arena, z, old, params.newName),
    };
    const checked = switch (outcome) {
        .ok => |checked| checked,
        .failed => |reason| return .{ .failed = reason },
    };
    return .{ .ok = try renameEdit(server, r, arena, checked.refs, checked.text, null) };
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
pub fn checkedRename(server: *Server, r: *Resolver, arena: Allocator, def: za.names.resolve.Def, old: []const u8, new: []const u8) !Outcome(CheckedRename) {
    const refs = switch (try renameReferences(server, r, arena, .{ .def = def }, old, new)) {
        .ok => |refs| refs,
        .failed => |reason| return .{ .failed = reason },
    };
    const name = try decodedName(arena, new);
    if (try ide.rename.declarationConflict(r, def, name)) |p| return .{ .failed = try renameProblem(server, r, arena, old, new, p.file, p.offset, p.message) };
    if (try ide.rename.resolutionConflict(r, def, name)) |p| return .{ .failed = try renameProblem(server, r, arena, old, new, p.file, p.offset, p.message) };
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
    if (try ide.rename.verifyAstGen(r, def_file, edits.items)) |p| return .{ .failed = try renameProblem(server, r, arena, old, new, p.file, p.offset, p.message) };
    // Strings (`@field`, `@hasDecl`, `@fieldParentPtr`, serialization keys) can name only
    // container members, and one without `pub` only in its own file
    if (def == .item) {
        const files = if (try za.ide_db.search.visibleOutsideFile(r, def)) try za.ide_db.search.candidateFilesFor(r, def_file, try server.searchScope(r)) else try arena.dupe(Vfs.FileId, &.{def_file});
        if (try ide.rename.stringReference(r, files, old)) |p| return .{ .failed = try renameProblem(server, r, arena, old, new, p.file, p.offset, p.message) };
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
    const refs = switch (try renameReferences(server, r, arena, .{ .label = label }, old, new)) {
        .ok => |refs| refs,
        .failed => |reason| return .{ .failed = reason },
    };
    const text = try identifierText(arena, new, false);
    const edits = try arena.alloc(ide.rename.Edit, refs.len);
    for (refs, edits) |ref, *e| e.* = .{ .start = ref.start, .end = ref.end, .text = text };
    if (try ide.rename.verifyAstGen(r, label.file, edits)) |p| return .{ .failed = try renameProblem(server, r, arena, old, new, p.file, p.offset, p.message) };
    return .{ .ok = .{ .refs = refs, .text = text } };
}

/// The references of a field of a `.zon` file and the source text of its new name (see
/// `checkedRename`). AstGen confirms the `.zon` file (a field name must be unique in its literal), and
/// strings may name the field (`@field`, `@hasField`).
fn checkedZonFieldRename(server: *Server, r: *Resolver, arena: Allocator, field: za.ide_db.search.ZonField, old: []const u8, new: []const u8) !Outcome(CheckedRename) {
    const refs = switch (try renameReferences(server, r, arena, .{ .zon_field = field }, old, new)) {
        .ok => |refs| refs,
        .failed => |reason| return .{ .failed = reason },
    };
    const text = try identifierText(arena, new, true);
    const file = field.literal.file;
    var edits: std.ArrayList(ide.rename.Edit) = .empty;
    for (refs) |ref| if (ref.file == file) try edits.append(arena, .{ .start = ref.start, .end = ref.end, .text = text });
    if (try ide.rename.verifyAstGen(r, file, edits.items)) |p| return .{ .failed = try renameProblem(server, r, arena, old, new, p.file, p.offset, p.message) };
    const files = try za.ide_db.search.candidateFilesFor(r, file, try server.searchScope(r));
    if (try ide.rename.stringReference(r, files, old)) |p| return .{ .failed = try renameProblem(server, r, arena, old, new, p.file, p.offset, p.message) };
    return .{ .ok = .{ .refs = refs, .text = text } };
}

/// The uses of the error `old`, found in `file`, and the source text of its new name (see
/// `checkedRename`). Error names are global, so the uses in all files compiled together with
/// `file` are renamed: each must be confirmed and editable (see `renameReferences`), no file that
/// is not renamed may use `old`, and `new` must not already be an error name (see
/// `rename.errorNameConflict`); `@errorName` results may be compared with a string of the name,
/// and AstGen confirms each renamed file.
fn checkedErrorRename(server: *Server, r: *Resolver, arena: Allocator, file: Vfs.FileId, old: []const u8, new: []const u8) !Outcome(CheckedRename) {
    const refs = switch (try renameReferences(server, r, arena, .{ .error_name = .{ .file = file, .name = old } }, old, new)) {
        .ok => |refs| refs,
        .failed => |reason| return .{ .failed = reason },
    };
    const scope = try server.searchScope(r);
    if (try ide.rename.errorNameConflict(r, file, scope, old, try decodedName(arena, new))) |p| return .{ .failed = try renameProblem(server, r, arena, old, new, p.file, p.offset, p.message) };
    const files = try za.ide_db.search.candidateFilesFor(r, file, scope);
    if (try ide.rename.stringReference(r, files, old)) |p| return .{ .failed = try renameProblem(server, r, arena, old, new, p.file, p.offset, p.message) };
    // Error names may be names of primitive types (`error.u8`)
    const text = try identifierText(arena, new, true);
    var i: usize = 0;
    while (i < refs.len) {
        const f = refs[i].file;
        var edits: std.ArrayList(ide.rename.Edit) = .empty;
        while (i < refs.len and refs[i].file == f) : (i += 1) try edits.append(arena, .{ .start = refs[i].start, .end = refs[i].end, .text = text });
        if (try ide.rename.verifyAstGen(r, f, edits.items)) |p| return .{ .failed = try renameProblem(server, r, arena, old, new, p.file, p.offset, p.message) };
    }
    return .{ .ok = .{ .refs = refs, .text = text } };
}

/// All references of `symbol` for renaming it from `old` to `new`, or why they cannot all be
/// confirmed, in which case renaming would leave a partially renamed result: the standard library
/// looks the declaration up by name in the root source file (see `rename.stdRootLookup`), the
/// search scope is still incomplete (see `scopeIncomplete`), a reference is ambiguous in a generic
/// function, goes through a member access of unknown type, or depends on instances that grow
/// without bound, is in a `.zon` file whose import sites give result types that cannot be named
/// (`search.Options.zon_import`), or
/// a file that mentions the name has syntax errors.
fn renameReferences(server: *Server, r: *Resolver, arena: Allocator, symbol: za.ide_db.search.Symbol, old: []const u8, new: []const u8) !Outcome([]const za.ide_db.search.Reference) {
    if (symbol == .def) if (try ide.rename.stdRootLookup(r, symbol.def)) |p| return .{ .failed = try renameProblem(server, r, arena, old, new, p.file, p.offset, p.message) };
    if (try references.scopeIncompleteFor(server, r, symbol, .edit)) |reason| return .{ .failed = try std.fmt.allocPrint(arena, "cannot rename `{s}` to `{s}`: {s}", .{ old, new, reason }) };
    const scope = try server.searchScope(r);
    var ambiguous: ?za.ide_db.search.Reference = null;
    var uncertain: ?za.ide_db.search.Reference = null;
    var incomplete: ?za.ide_db.search.Reference = null;
    var zon_import: ?za.ide_db.search.Reference = null;
    var syntax_error: ?Vfs.FileId = null;
    const refs = try za.ide_db.search.symbolReferences(r, symbol, .{
        .scope = scope,
        .ambiguous = &ambiguous,
        .uncertain = &uncertain,
        .incomplete = &incomplete,
        .zon_import = &zon_import,
        .syntax_error = &syntax_error,
    });
    if (zon_import) |z| return .{ .failed = try renameProblem(server, r, arena, old, new, z.file, z.start, za.ide_db.search.zon_import_message) };
    if (syntax_error) |file| return .{ .failed = try renameProblem(server, r, arena, old, new, file, null, "the file has syntax errors, so references in it may be missed") };
    if (ambiguous) |a| return .{ .failed = try renameProblem(server, r, arena, old, new, a.file, a.start, za.ide_db.search.ambiguous_message) };
    if (uncertain) |u| return .{ .failed = try renameProblem(server, r, arena, old, new, u.file, u.start, if (symbol == .error_name)
        "the type here is unknown, so whether this is the same error cannot be confirmed"
    else
        "the type here is unknown, so whether this refers to the same declaration cannot be confirmed") };
    if (incomplete) |u| return .{ .failed = try renameProblem(server, r, arena, old, new, u.file, u.start, "this reference depends on instantiations of a generic function that grow without bound, so not all of them can be checked") };
    const rules = try server.originRules(arena);
    for (refs, 0..) |ref, i| {
        // Sorted by file: check each file once
        if (i > 0 and refs[i - 1].file == ref.file) continue;
        if (!editable(server, rules, ref.file)) return .{ .failed = try renameProblem(server, r, arena, old, new, ref.file, ref.start, not_editable) };
    }
    return .{ .ok = refs };
}

/// Why an edit that a rename or fix needs in a file that is not `editable` is refused
pub const not_editable = "this use is in a dependency library (the Zig installation, a fetched package, a generated file) or a stale copy of one, which must not be edited";

/// Whether renames and fixes may edit `file`: the user's own code (see `origin.Origin`). A
/// fetched package is restored from its hash on other machines, the Zig installation is shared by
/// every project, and generated files are overwritten by builds.
pub fn editable(server: *Server, rules: origin.Rules, file: Vfs.FileId) bool {
    return switch (origin.classify(&server.vfs, rules, server.vfs.path(file), server.inProject(file))) {
        .virtual, .user, .outside => true,
        .zig_lib, .generated, .package, .other => false,
    };
}

/// Edits that change the references (sorted by file and position, including the declaration) to
/// `new_text`. When `confirm` is not null, the edits carry an annotation with it as the label
/// that requires user confirmation (see `workspaceEdit`).
pub fn renameEdit(server: *Server, r: *Resolver, arena: Allocator, refs: []const za.ide_db.search.Reference, new_text: []const u8, confirm: ?[]const u8) !types.WorkspaceEdit {
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
    return workspaceEdit(server, r, arena, files.items, if (confirm) |label| .{
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
pub fn workspaceEdit(server: *Server, r: *Resolver, arena: Allocator, files: []const ide.rename.FileEdits, confirm: ?Confirmation) !types.WorkspaceEdit {
    const annotated = confirm != null and server.caps.change_annotations;
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

/// Explanation of why a name cannot be renamed:
/// "cannot rename `a` to `b`: reason (file:line:column)"; only the file when the position is null
pub fn renameProblem(server: *Server, r: *Resolver, arena: Allocator, old: []const u8, new: []const u8, file: Vfs.FileId, offset: ?u32, reason: []const u8) ![]const u8 {
    return fixProblem(server, r, arena, try std.fmt.allocPrint(arena, "cannot rename `{s}` to `{s}`", .{ old, new }), file, offset, reason);
}

/// Why a fix cannot be applied: "<prefix>: reason (file:line:column)"; only the file when the
/// position is null
pub fn fixProblem(server: *Server, r: *Resolver, arena: Allocator, prefix: []const u8, file: Vfs.FileId, offset: ?u32, reason: []const u8) ![]const u8 {
    const shown = server.vfs.shownPath(try server.rootsAlloc(arena), server.vfs.path(file));
    const at = offset orelse return std.fmt.allocPrint(arena, "{s}: {s} ({s})", .{ prefix, reason, shown });
    const pos = (try Server.sourceLines(r.ctx, file)).position(at, server.encoding);
    return std.fmt.allocPrint(arena, "{s}: {s} ({s}:{d}:{d})", .{ prefix, reason, shown, pos.line + 1, pos.character + 1 });
}
