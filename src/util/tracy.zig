//! Integration of the tracy profiler: active with `zig build -Dtracy=<tracy source directory>`,
//! otherwise everything is a no-op.
//!
//! Zone granularity: each query computation (labeled with the query name, with the key attached)
//! and each request (labeled with the method name).

const std = @import("std");
const options = @import("build_options");

pub const enabled = options.tracy;

const SourceLocation = extern struct {
    name: ?[*:0]const u8,
    function: [*:0]const u8,
    file: [*:0]const u8,
    line: u32,
    color: u32,
};

const ZoneContext = extern struct {
    id: u32,
    active: c_int,
};

pub const Zone = struct {
    ctx: if (enabled) ZoneContext else void,

    pub inline fn end(z: Zone) void {
        if (enabled) ___tracy_emit_zone_end(z.ctx);
    }

    /// Text attached to the zone (such as the query key)
    pub inline fn text(z: Zone, s: []const u8) void {
        if (enabled) ___tracy_emit_zone_text(z.ctx, s.ptr, s.len);
    }
};

/// Starts a zone labeled `name`; call `end` when it is done
pub inline fn zone(comptime src: std.builtin.SourceLocation, comptime name: []const u8) Zone {
    if (!enabled) return .{ .ctx = {} };
    const S = struct {
        const loc: SourceLocation = .{
            .name = (name ++ "\x00")[0..name.len :0],
            .function = src.fn_name,
            .file = src.file,
            .line = src.line,
            .color = 0,
        };
    };
    return .{ .ctx = ___tracy_emit_zone_begin(&S.loc, 1) };
}

extern fn ___tracy_emit_zone_begin(srcloc: *const SourceLocation, active: c_int) ZoneContext;
extern fn ___tracy_emit_zone_end(ctx: ZoneContext) void;
extern fn ___tracy_emit_zone_text(ctx: ZoneContext, txt: [*]const u8, size: usize) void;
