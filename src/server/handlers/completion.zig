//! Completion requests: `textDocument/completion` and `completionItem/resolve`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const za = @import("../../zig_analyzer.zig");
const types = za.lsp.types;
const offsets = za.util.offsets;
const Vfs = za.base.Vfs;
const database = @import("../../database.zig");
const FileText = database.inputs.FileText;
const ide = za.ide;
const ModuleGraph = za.names.ModuleGraph;
const Resolver = za.names.resolve.Resolver;

const Server = @import("../Server.zig");
const indexing = @import("../indexing.zig");
const HandlerError = Server.HandlerError;

/// A completion item kind the client supports (see `clientSymbolKind`)
/// (the initial kinds are `Text` to `Reference`)
fn clientCompletionKind(listed: bool, kind: types.CompletionItemKind) types.CompletionItemKind {
    if (listed or @backingInt(kind) <= @backingInt(types.CompletionItemKind.Reference)) return kind;
    return switch (kind) {
        .Struct, .TypeParameter => .Class,
        .EnumMember => .Enum,
        .Constant => .Variable,
        .Folder => .File,
        else => .Text,
    };
}

pub fn completion(server: *Server, r: *Resolver, arena: Allocator, params: types.CompletionParams) HandlerError!types.ResultType("textDocument/completion") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    if (try r.ctx.get(FileText, file) == null) return null;
    // With `FileText`, the `SourceText` is that text
    const lines = try Server.sourceLines(r.ctx, file);
    const text = lines.text;
    const line = lines.lineAt(params.position.line);
    const offset: u32 = @intCast(if (line) |l| l.offset(params.position.character, server.encoding) else text.len);
    const auto_import = indexing.autoImportEnabled(server);
    // Auto-imports are not offered until the index has been built for the current module graph, and
    // the result is marked incomplete: the client requests again as the user types, and they are
    // offered then. Indexing starts when a Zig document opens (with auto-import on; see
    // `requestAutoImportIndex`) or, for a document opened before that, at the first completion
    // where a name could be imported. If the index is still not built and no indexing is in
    // progress (the previous round failed, or the task could not start), it starts again.
    const imports_ready = auto_import and
        server.index.imports_basis.load(.acquire) == indexing.importsBasis(try r.ctx.get(ModuleGraph.Input, {}));
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
        .snippets = server.caps.snippet_support and snippets,
        .argument_placeholders = placeholders,
        .paths_only = path_trigger,
    });
    const imports_waiting = auto_import and !imports_ready and result.import_position;
    if (imports_waiting) {
        const first = !server.index.imports_wanted.swap(true, .acq_rel);
        if (first or !server.index.rerun.running.load(.acquire)) indexing.scheduleIndexingFromRead(server);
    }
    const out = try arena.alloc(types.CompletionItem, result.items.len);
    var ranges: CompletionRanges = .{ .text = text, .line = line, .encoding = server.encoding, .lines = lines };
    for (result.items, out) |it, *o| {
        o.* = .{
            .label = it.label,
            .kind = clientCompletionKind(server.caps.completion_kinds, switch (it.kind) {
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
            }),
            .documentation = if (it.doc) |d| .{ .MarkupContent = try Server.markup(arena, server.caps.completion_markdown, d) } else null,
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
            o.textEdit = if (server.caps.insert_replace_support) .{ .InsertReplaceEdit = .{
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
pub fn completionResolve(server: *Server, r: *Resolver, arena: Allocator, params: types.CompletionItem) HandlerError!types.ResultType("completionItem/resolve") {
    var item = params;
    const data = switch (params.data orelse return item) {
        .object => |o| o,
        else => return item,
    };
    const from = dataFile(server, data, "from") orelse return item;
    const file = dataFile(server, data, "file") orelse return item;
    const target: za.ide_db.imports.Target = if (data.get("item")) |v| blk: {
        if (v != .integer or v.integer < 0 or v.integer > std.math.maxInt(u32)) return item;
        const def = try ide.context.defOfKey(r, .{ .file = file, .item = @fromBackingInt(@as(u32, @intCast(v.integer))) }) orelse return item;
        break :blk .{ .decl = .{ .file = file, .item = def.item.item } };
    } else .{ .file = file };
    const description = try ide.completion.describe(r, from, target);
    item.detail = description.detail;
    item.documentation = .{ .MarkupContent = try Server.markup(arena, server.caps.completion_markdown, description.doc) };
    return item;
}

/// The file named by `key` in `data`; null if it is not a file of the current session
fn dataFile(server: *Server, data: std.json.ObjectMap, key: []const u8) ?Vfs.FileId {
    const v = data.get(key) orelse return null;
    if (v != .integer or v.integer < 0 or v.integer >= server.vfs.count()) return null;
    return @fromBackingInt(@as(u32, @intCast(v.integer)));
}
