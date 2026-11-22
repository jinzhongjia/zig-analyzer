//! Hover and signature help requests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const za = @import("../../zig_analyzer.zig");
const types = za.lsp.types;
const offsets = za.util.offsets;
const Vfs = za.base.Vfs;
const ide = za.ide;
const Resolver = za.names.resolve.Resolver;

const Server = @import("../Server.zig");
const project_set = @import("../project_set.zig");
const HandlerError = Server.HandlerError;

/// Shown under a hover answered while a project is pending, so that a less precise type or an
/// `unknown` is not taken for the final result
const hover_loading_note = "The project is still loading, so this result may be incomplete.";

pub fn hover(server: *Server, r: *Resolver, arena: Allocator, params: types.HoverParams) HandlerError!types.ResultType("textDocument/hover") {
    const at = try server.textPosition(r, arena, params.textDocument.uri, params.position) orelse return null;
    // Checked before computing: a load that ends during the computation cancels this read
    const incomplete = project_set.projectsPending(server);
    const info = try ide.hover.hoverWith(r, at.file, at.offset, .{
        .roots = try server.rootsAlloc(arena),
        .instances = server.config.hover_instances,
        .layout = server.config.hover_layout,
        .fqn = server.config.hover_fqn,
        // Links to source locations open the file at the line in the client; plain text has none
        .links = if (server.caps.hover_markdown) .{ .ctx = server, .uri = hoverUri } else null,
    }) orelse return null;
    const lines = at.lines;
    const text = if (!incomplete) info.text else try std.mem.concat(arena, u8, &.{ info.text, if (server.caps.hover_markdown) "\n\n---\n\n_" ++ hover_loading_note ++ "_" else "\n\n" ++ hover_loading_note });
    return .{
        .contents = .{ .MarkupContent = try Server.markup(arena, server.caps.hover_markdown, text) },
        .range = lines.range(info.start, info.end, server.encoding),
    };
}

/// The URI of `file` for a link in hover (see `ide.hover.Links`)
fn hoverUri(ctx: *anyopaque, arena: Allocator, file: Vfs.FileId) Allocator.Error![]const u8 {
    const server: *Server = @ptrCast(@alignCast(ctx));
    return server.uriFor(arena, file);
}

pub fn signatureHelp(server: *Server, r: *Resolver, arena: Allocator, params: types.SignatureHelpParams) HandlerError!types.ResultType("textDocument/signatureHelp") {
    const at = try server.textPosition(r, arena, params.textDocument.uri, params.position) orelse return null;
    const sig = try ide.signature_help.signatureHelp(r, at.file, at.offset) orelse return null;
    const ps = try arena.alloc(types.ParameterInformation, sig.params.len);
    for (sig.params, sig.ranges, ps) |p, range, *o| o.* = .{ .label = if (server.caps.signature_label_offsets) .{ .tuple = .{
        offsets.unitCount(sig.label[0..range[0]], server.encoding),
        offsets.unitCount(sig.label[0..range[1]], server.encoding),
    } } else .{ .string = p } };
    const info = try arena.alloc(types.SignatureInformation, 1);
    info[0] = .{
        .label = sig.label,
        .parameters = ps,
        .activeParameter = if (ps.len == 0) null else sig.active,
        .documentation = if (sig.doc) |d| .{ .MarkupContent = try Server.markup(arena, server.caps.signature_markdown, d) } else null,
    };
    return .{ .signatures = info, .activeSignature = 0, .activeParameter = if (ps.len == 0) null else sig.active };
}
