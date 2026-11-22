//! Inlay hint requests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const za = @import("../../zig_analyzer.zig");
const types = za.lsp.types;
const ide = za.ide;
const Resolver = za.names.resolve.Resolver;

const Server = @import("../Server.zig");
const HandlerError = Server.HandlerError;

pub fn inlayHint(server: *Server, r: *Resolver, arena: Allocator, params: types.InlayHintParams) HandlerError!types.ResultType("textDocument/inlayHint") {
    const file = try server.lookupFile(arena, params.textDocument.uri) orelse return null;
    const lines = try Server.sourceLines(r.ctx, file);
    const start, const end = server.rangeOffsets(lines, params.range);
    const opts: ide.inlay_hints.Options = blk: {
        server.config_mutex.lockUncancelable(server.io);
        defer server.config_mutex.unlock(server.io);
        const c = &server.config;
        break :blk .{
            .types = c.inlay_types,
            .capture_types = c.inlay_capture_types,
            .field_types = c.inlay_field_types,
            .anonymous_containers = c.inlay_anonymous_containers,
            .parameters = c.inlay_parameters,
            .builtin_parameters = c.inlay_builtin_parameters,
            .exclude_single_argument = c.inlay_exclude_single_argument,
            .hide_redundant_param_names = c.hide_redundant_param_names,
            .max_length = c.inlay_max_length,
        };
    };
    const hints = try ide.inlay_hints.inlayHints(r, file, start, end, opts);
    const out = try arena.alloc(types.InlayHint, hints.len);
    for (hints, out) |h, *o| o.* = .{
        .position = lines.position(h.offset, server.encoding),
        .label = .{ .string = h.label },
        .kind = switch (h.kind) {
            .type => .Type,
            .parameter => .Parameter,
        },
        .paddingRight = if (h.kind == .parameter) true else null,
        .tooltip = if (h.tooltip) |t| .{ .string = t } else null,
    };
    return out;
}
