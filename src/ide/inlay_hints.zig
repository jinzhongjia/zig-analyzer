//! inlay hints：没有类型标注的局部变量的类型；调用处的参数名。

const std = @import("std");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const context = @import("context.zig");
const seed = @import("../ide_db/seed.zig");
const render = @import("../sema/render.zig");
const Body = @import("../hir/Body.zig");
const FileId = @import("../base/Vfs.zig").FileId;

pub const Hint = struct {
    offset: u32,
    label: []const u8,
    kind: enum { type, parameter },
    /// 类型取自调用点的实例时说明所依据的调用
    tooltip: ?[]const u8 = null,
};

/// 配置 `inlay_hints.*`
pub const Options = struct {
    types: bool = true,
    parameters: bool = true,
    /// 实参是同名的变量（或以形参名结尾的字段访问）时不提示形参名
    hide_redundant_param_names: bool = true,
};

/// `[start, end)` 范围内的提示
pub fn inlayHints(r: *Resolver, file: FileId, start: u32, end: u32, opts: Options) resolve.Error![]const Hint {
    var out: std.ArrayList(Hint) = .empty;
    const tree = try r.itemTree(file);
    for (tree.items, 0..) |_, i| {
        const node = try r.itemNode(file, @intCast(i)) orelse continue;
        const range = node.range();
        if (range.end < start or range.start > end) continue;
        const a = try context.atSeeded(r, file, range.start, false) orelse continue;
        // 嵌套的成员各自处理：只处理以本成员为最内层 owner 的提示
        if (a.item != i) continue;
        try bodyHints(r, a, start, end, opts, &out);
    }
    std.mem.sort(Hint, out.items, {}, struct {
        fn lt(_: void, x: Hint, y: Hint) bool {
            return x.offset < y.offset;
        }
    }.lt);
    return out.items;
}

fn bodyHints(r: *Resolver, a: context.At, start: u32, end: u32, opts: Options, out: *std.ArrayList(Hint)) resolve.Error!void {
    const b = a.body;
    const base = a.node.offset;
    if (opts.types) for (b.bindings, 0..) |binding, i| {
        if (binding.kind != .local_const and binding.kind != .local_var) continue;
        if (binding.ty != null or binding.name.len == 0) continue;
        const at = base + binding.range.end;
        if (at < start or at > end) continue;
        // 泛型函数体内抽象的类型（如 `T`）照常显示，只有未知时才取调用点的实例
        const abstract = a.res.bindings[i];
        const tv = if (abstract.ty == .unknown) a.bindingType(@fromBackingInt(@as(u32, @intCast(i)))) else abstract;
        // 未知的类型与值为类型的常量（`const T = u8`）不提示
        if (tv.ty == .unknown or tv.ty == .type_type) continue;
        const tooltip: ?[]const u8 = if (abstract.ty == .unknown) if (a.seeded) |s| try seedNote(r, s) else null else null;
        try out.append(r.arena, .{ .offset = at, .label = try std.fmt.allocPrint(r.arena, ": {s}", .{try render.typeAlloc(r, tv.ty)}), .kind = .type, .tooltip = tooltip });
    };
    if (opts.parameters) for (b.exprs, 0..) |e, i| {
        if (e != .call) continue;
        const range = b.expr_ranges[i];
        if (base + range.end < start or base + range.start > end) continue;
        const target = try context.callee(r, a, e.call.callee) orelse continue;
        const params = try context.fnParams(r, target.def);
        const skip: usize = if (target.bound) 1 else 0;
        for (e.call.args, 0..) |arg, ai| {
            if (ai + skip >= params.len) break;
            const name = (params[ai + skip].name() orelse continue).text;
            if (std.mem.eql(u8, name, "_")) continue;
            // 实参就是同名变量时不提示
            if (opts.hide_redundant_param_names) switch (b.expr(arg)) {
                .name_ref => |n| if (std.mem.eql(u8, n, name)) continue,
                .field_access => |fa| if (fa.field) |f| if (std.mem.eql(u8, f, name)) continue,
                else => {},
            };
            try out.append(r.arena, .{ .offset = base + b.range(arg).start, .label = try std.fmt.allocPrint(r.arena, "{s}:", .{name}), .kind = .parameter });
        }
    };
}

/// 「inferred from the call at file.zig:123」
fn seedNote(r: *Resolver, s: seed.Seed) resolve.Error![]const u8 {
    const text = (try r.ctx.get(@import("../database.zig").syntax.SourceText, s.file)).text;
    const line = std.mem.count(u8, text[0..@min(s.offset, text.len)], "\n") + 1;
    return std.fmt.allocPrint(r.arena, "inferred from the call at {s}:{d}", .{ std.fs.path.basename(r.ctx.db.env.vfs.path(s.file)), line });
}
