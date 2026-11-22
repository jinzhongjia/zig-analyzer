//! Semantic token requests (full, delta, and range).

const std = @import("std");
const Allocator = std.mem.Allocator;
const za = @import("../../zig_analyzer.zig");
const types = za.lsp.types;
const Vfs = za.base.Vfs;
const database = @import("../../database.zig");
const Db = database.Db;
const ide = za.ide;
const Resolver = za.names.resolve.Resolver;
const SemanticCache = @import("../semantic_cache.zig");

const Server = @import("../Server.zig");
const HandlerError = Server.HandlerError;

pub fn semanticTokensFull(server: *Server, r: *Resolver, arena: Allocator, params: types.SemanticTokensParams) HandlerError!types.ResultType("textDocument/semanticTokens/full") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const lines = try Server.fileLines(r.ctx, arena, file);
    const data = try ide.semantic_tokens.semanticTokens(r, file, lines, server.encoding, null, semanticTokensOptions(server));
    const result = try semanticTokensResult(server, r.ctx, arena, file, data, null);
    return result.SemanticTokens;
}

pub fn semanticTokensDelta(server: *Server, r: *Resolver, arena: Allocator, params: types.SemanticTokensDeltaParams) HandlerError!types.ResultType("textDocument/semanticTokens/full/delta") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const lines = try Server.fileLines(r.ctx, arena, file);
    const data = try ide.semantic_tokens.semanticTokens(r, file, lines, server.encoding, null, semanticTokensOptions(server));
    return try semanticTokensResult(server, r.ctx, arena, file, data, params.previousResultId);
}

fn semanticTokensOptions(server: *Server) ide.semantic_tokens.Options {
    const config = server.config.load(.acquire);
    return .{ .partial = config.semantic_tokens_mode == .partial, .global_var = config.semantic_tokens_global_var };
}

fn semanticTokensResult(server: *Server, ctx: *Db.Ctx, arena: Allocator, file: Vfs.FileId, data: []const u32, previous_id: ?[]const u8) HandlerError!SemanticCache.Result {
    const is_open = blk: {
        server.docs.mutex.lockUncancelable(server.io);
        defer server.docs.mutex.unlock(server.io);
        break :blk server.docs.open.contains(file);
    };
    try ctx.checkCanceled();
    // The read transaction guarantees that closing the document first waits for this request to
    // exit; for a document that is not open, only the data is returned, and no snapshot reusable
    // across sessions of the document is saved.
    if (!is_open) return .{ .SemanticTokens = .{ .data = data } };
    return try server.semantic_cache.update(server.io, server.gpa, arena, file, data, previous_id);
}

pub fn semanticTokensRange(server: *Server, r: *Resolver, arena: Allocator, params: types.SemanticTokensRangeParams) HandlerError!types.ResultType("textDocument/semanticTokens/range") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const lines = try Server.fileLines(r.ctx, arena, file);
    return .{ .data = try ide.semantic_tokens.semanticTokens(r, file, lines, server.encoding, params.range, semanticTokensOptions(server)) };
}
