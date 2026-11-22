//! Document structure requests: formatting, document symbols, folding ranges, and selection
//! ranges.

const std = @import("std");
const Allocator = std.mem.Allocator;
const za = @import("../../zig_analyzer.zig");
const types = za.lsp.types;
const database = @import("../../database.zig");
const Db = database.Db;
const syntax_q = database.syntax;
const ide = za.ide;
const Resolver = za.names.resolve.Resolver;

const Server = @import("../Server.zig");
const HandlerError = Server.HandlerError;

pub fn formatting(server: *Server, ctx: *Db.Ctx, arena: Allocator, params: types.DocumentFormattingParams) HandlerError!types.ResultType("textDocument/formatting") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const lines = try Server.fileLines(ctx, arena, file);
    const mode = za.syntax.Parse.modeOf(server.vfs.path(file));
    return ide.format.format(arena, lines, mode, server.encoding, try ctx.get(ide.format.ZigFmtRenderer, {}));
}

pub fn documentSymbol(server: *Server, r: *Resolver, arena: Allocator, params: types.DocumentSymbolParams) HandlerError!types.ResultType("textDocument/documentSymbol") {
    const ctx = r.ctx;
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const parse = try ctx.get(syntax_q.ParseFile, file);
    const lines = try Server.fileLines(ctx, arena, file);
    const symbols = if (parse.mode == .zon)
        try ide.document_symbol.zonSymbols(arena, parse.rootNode(), lines, server.encoding)
    else
        try ide.document_symbol.documentSymbolsWithResolver(arena, r, file, try ctx.get(syntax_q.FileItemTree, file), try ctx.get(syntax_q.FileAstIdMap, file), lines, server.encoding);
    if (server.caps.hierarchical_symbols) return .{ .array_of_DocumentSymbol = try clientSymbolTree(server, arena, symbols) };
    var flat: std.ArrayList(types.SymbolInformation) = .empty;
    try flattenSymbols(server, arena, params.textDocument.uri, symbols, null, &flat);
    return .{ .array_of_SymbolInformation = flat.items };
}

/// The outline with the symbol kinds the client supports
fn clientSymbolTree(server: *Server, arena: Allocator, symbols: []const types.DocumentSymbol) Allocator.Error![]const types.DocumentSymbol {
    const out = try arena.dupe(types.DocumentSymbol, symbols);
    for (out) |*s| {
        s.kind = Server.clientSymbolKind(server.caps.document_symbol_kinds, s.kind);
        if (s.children) |children| s.children = try clientSymbolTree(server, arena, children);
    }
    return out;
}

/// The outline as a flat list for clients without `hierarchicalDocumentSymbolSupport`: each symbol
/// names its parent symbol as `containerName`
fn flattenSymbols(server: *Server, arena: Allocator, doc_uri: []const u8, symbols: []const types.DocumentSymbol, container: ?[]const u8, out: *std.ArrayList(types.SymbolInformation)) Allocator.Error!void {
    for (symbols) |s| {
        try out.append(arena, .{
            .name = s.name,
            .kind = Server.clientSymbolKind(server.caps.document_symbol_kinds, s.kind),
            .containerName = container,
            .location = .{ .uri = doc_uri, .range = s.range },
        });
        try flattenSymbols(server, arena, doc_uri, s.children orelse &.{}, s.name, out);
    }
}

pub fn foldingRange(server: *Server, ctx: *Db.Ctx, arena: Allocator, params: types.FoldingRangeParams) HandlerError!types.ResultType("textDocument/foldingRange") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const parse = try ctx.get(syntax_q.ParseFile, file);
    const lines = try Server.fileLines(ctx, arena, file);
    return try ide.folding.foldingRanges(arena, parse.rootNode(), lines);
}

pub fn selectionRange(server: *Server, ctx: *Db.Ctx, arena: Allocator, params: types.SelectionRangeParams) HandlerError!types.ResultType("textDocument/selectionRange") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const parse = try ctx.get(syntax_q.ParseFile, file);
    const lines = try Server.fileLines(ctx, arena, file);
    return try ide.selection_range.selectionRanges(arena, parse.rootNode(), lines, server.encoding, params.positions);
}
