//! Goto requests: definition, declaration, and type definition.

const std = @import("std");
const Allocator = std.mem.Allocator;
const za = @import("../../zig_analyzer.zig");
const types = za.lsp.types;
const uri = za.base.uri;
const ide = za.ide;
const Resolver = za.names.resolve.Resolver;

const Server = @import("../Server.zig");
const HandlerError = Server.HandlerError;

pub fn definition(server: *Server, r: *Resolver, arena: Allocator, params: types.DefinitionParams) HandlerError!types.ResultType("textDocument/definition") {
    const locs = try gotoTargets(server, r, arena, params.textDocument.uri, params.position, ide.definition.definitionTargets);
    return switch (locs.len) {
        0 => null,
        1 => .{ .Definition = .{ .Location = locs[0] } },
        else => .{ .Definition = .{ .array_of_Location = locs } },
    };
}

pub fn declaration(server: *Server, r: *Resolver, arena: Allocator, params: types.DeclarationParams) HandlerError!types.ResultType("textDocument/declaration") {
    const locs = try gotoTargets(server, r, arena, params.textDocument.uri, params.position, ide.definition.declarationTargets);
    return switch (locs.len) {
        0 => null,
        1 => .{ .Declaration = .{ .Location = locs[0] } },
        else => .{ .Declaration = .{ .array_of_Location = locs } },
    };
}

pub fn typeDefinition(server: *Server, r: *Resolver, arena: Allocator, params: types.TypeDefinitionParams) HandlerError!types.ResultType("textDocument/typeDefinition") {
    const at = try server.textPosition(r, arena, params.textDocument.uri, params.position) orelse return null;
    const targets = try ide.definition.typeDefinitionTargets(r, at.file, at.offset);
    const locs = try arena.alloc(types.Location, targets.len);
    for (targets, locs) |t, *loc| loc.* = try targetLocation(server, r, arena, t);
    return switch (locs.len) {
        0 => null,
        1 => .{ .Definition = .{ .Location = locs[0] } },
        else => .{ .Definition = .{ .array_of_Location = locs } },
    };
}

/// All goto targets at the cursor, computed with `find`. A path in `build.zig.zon` goes to the start
/// of the file it points to, without interning that file
fn gotoTargets(server: *Server, r: *Resolver, arena: Allocator, document_uri: []const u8, pos: types.Position, comptime find: anytype) ![]const types.Location {
    const at = try server.textPosition(r, arena, document_uri, pos) orelse return &.{};
    if (try ide.definition.manifestPath(r, at.file, at.offset)) |path| {
        const target_uri = if (try server.vfs.lookup(path)) |f| try server.uriFor(arena, f) else try uri.fromPath(arena, path);
        return arena.dupe(types.Location, &.{.{ .uri = target_uri, .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } } }});
    }
    const targets = try find(r, at.file, at.offset);
    const locs = try arena.alloc(types.Location, targets.len);
    for (targets, locs) |t, *loc| loc.* = try targetLocation(server, r, arena, t);
    return locs;
}

fn targetLocation(server: *Server, r: *Resolver, arena: Allocator, t: ide.definition.Target) !types.Location {
    const target_uri = try server.uriFor(arena, t.file);
    // The start of a file (the target of an import or of a path in `build.zig.zon`) needs no read
    // of the file: a path can point to a file of any size and content
    if (t.start == 0 and t.end == 0) return .{ .uri = target_uri, .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } } };
    const lines = try Server.sourceLines(r.ctx, t.file);
    return .{ .uri = target_uri, .range = lines.range(t.start, t.end, server.encoding) };
}
