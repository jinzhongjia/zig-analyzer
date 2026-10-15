//! tracy 性能分析器的接入（设计 §14）：`zig build -Dtracy=<tracy 源码目录>` 时生效，否则全部为空操作。
//!
//! zone 的粒度：每次 query 计算（以 query 名标注，附带 key）与每个请求（以方法名标注）。

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

    /// 附在 zone 上的文字（如 query 的 key）
    pub inline fn text(z: Zone, s: []const u8) void {
        if (enabled) ___tracy_emit_zone_text(z.ctx, s.ptr, s.len);
    }
};

/// 开始一个以 `name` 标注的 zone，结束时调用 `end`
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
