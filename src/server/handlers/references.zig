//! Find references, document highlight, and workspace symbol requests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const za = @import("../../zig_analyzer.zig");
const types = za.lsp.types;
const offsets = za.util.offsets;
const Vfs = za.base.Vfs;
const ide = za.ide;
const Resolver = za.names.resolve.Resolver;

const Server = @import("../Server.zig");
const HandlerError = Server.HandlerError;
const Outcome = Server.Outcome;
const ScopeUse = Server.ScopeUse;

/// The symbols at the cursor (see `definition.symbolsAt`); null when there is none
fn symbolsAtPosition(server: *Server, r: *Resolver, arena: Allocator, document_uri: []const u8, pos: types.Position) !?struct { symbols: []const za.ide_db.search.Symbol, file: Vfs.FileId } {
    const at = try server.textPosition(r, arena, document_uri, pos) orelse return null;
    const symbols = try ide.definition.symbolsAt(r, at.file, at.offset);
    if (symbols.len == 0) return null;
    return .{ .symbols = symbols, .file = at.file };
}

/// Why the references of `symbol` cannot all be found now (see `scopeIncomplete` and
/// `subProjectGap`); null also when only its own file can refer to it
pub fn scopeIncompleteFor(server: *Server, r: *Resolver, symbol: za.ide_db.search.Symbol, use: ScopeUse) !?[]const u8 {
    if (try ownFileOnly(r, symbol)) return null;
    if (try server.scopeIncomplete()) |reason| return reason;
    const name = try za.ide_db.search.symbolName(r, symbol) orelse return null;
    return server.subProjectGap(r, name, use);
}

/// Whether only the file of `symbol` can refer to it: local names, labels, and declarations without
/// `pub` other than fields. Error names are global.
pub fn ownFileOnly(r: *Resolver, symbol: za.ide_db.search.Symbol) !bool {
    return switch (symbol) {
        .def => |def| !try za.ide_db.search.visibleOutsideFile(r, def),
        .label => true,
        .error_name, .zon_field => false,
    };
}

/// Converts reference positions to LSP ranges (caching the line index per file)
pub const RangeMapper = struct {
    server: *Server,
    r: *Resolver,
    file: ?Vfs.FileId = null,
    lines: offsets.LineIndex = undefined,

    pub fn range(m: *RangeMapper, file: Vfs.FileId, start: u32, end: u32) !types.Range {
        if (m.file != file) {
            m.lines = try Server.sourceLines(m.r.ctx, file);
            m.file = file;
        }
        return m.lines.range(start, end, m.server.encoding);
    }
};

pub fn references(server: *Server, r: *Resolver, arena: Allocator, params: types.ReferenceParams) HandlerError!Outcome(types.ResultType("textDocument/references")) {
    const found = try symbolsAtPosition(server, r, arena, params.textDocument.uri, params.position) orelse return .{ .ok = null };
    for (found.symbols) |symbol| if (try scopeIncompleteFor(server, r, symbol, .find)) |reason| return .{ .failed = try std.fmt.allocPrint(arena, "cannot find all references: {s}", .{reason}) };
    const refs = try za.ide_db.search.symbolsReferences(r, found.symbols, .{ .scope = try server.searchScope(r) });
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
pub fn documentHighlight(server: *Server, r: *Resolver, arena: Allocator, params: types.DocumentHighlightParams) HandlerError!types.ResultType("textDocument/documentHighlight") {
    const found = try symbolsAtPosition(server, r, arena, params.textDocument.uri, params.position) orelse return null;
    const refs = try za.ide_db.search.symbolsReferences(r, found.symbols, .{ .scope = &.{}, .only_file = found.file });
    const out = try arena.alloc(types.DocumentHighlight, refs.len);
    var m: RangeMapper = .{ .server = server, .r = r };
    for (refs, out) |ref, *o| o.* = .{ .range = try m.range(ref.file, ref.start, ref.end), .kind = if (ref.is_decl or ref.is_write) .Write else .Read };
    return out;
}

pub fn workspaceSymbol(server: *Server, r: *Resolver, arena: Allocator, params: types.WorkspaceSymbolParams) HandlerError!types.ResultType("workspace/symbol") {
    const scope = try server.symbolScope(r);
    const limit = server.config.load(.acquire).workspace_symbol_limit;
    const syms = try ide.workspace_symbol.search(r, scope, params.query, if (limit == 0) std.math.maxInt(usize) else limit);
    const out = try arena.alloc(types.WorkspaceSymbol, syms.len);
    var m: RangeMapper = .{ .server = server, .r = r };
    for (syms, out) |s, *o| o.* = .{
        .name = s.name,
        .kind = Server.clientSymbolKind(server.caps.workspace_symbol_kinds, s.kind),
        .containerName = s.container,
        .location = .{ .Location = .{ .uri = try server.uriFor(arena, s.file), .range = try m.range(s.file, s.start, s.end) } },
    };
    return .{ .array_of_WorkspaceSymbol = out };
}
