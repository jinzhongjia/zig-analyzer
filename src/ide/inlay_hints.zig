//! inlay hints：没有类型标注的局部变量的类型；调用处的参数名。

const std = @import("std");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const context = @import("context.zig");
const render = @import("../sema/render.zig");
const Body = @import("../hir/Body.zig");
const FileId = @import("../base/Vfs.zig").FileId;

pub const Hint = struct {
    offset: u32,
    label: []const u8,
    kind: enum { type, parameter },
};

/// `[start, end)` 范围内的提示
pub fn inlayHints(r: *Resolver, file: FileId, start: u32, end: u32) resolve.Error![]const Hint {
    var out: std.ArrayList(Hint) = .empty;
    const tree = try r.itemTree(file);
    for (tree.items, 0..) |_, i| {
        const node = try r.itemNode(file, @intCast(i)) orelse continue;
        const range = node.range();
        if (range.end < start or range.start > end) continue;
        const a = try context.at(r, file, range.start, false) orelse continue;
        // 嵌套的成员各自处理：只处理以本成员为最内层 owner 的提示
        if (a.item != i) continue;
        try bodyHints(r, a, start, end, &out);
    }
    std.mem.sort(Hint, out.items, {}, struct {
        fn lt(_: void, x: Hint, y: Hint) bool {
            return x.offset < y.offset;
        }
    }.lt);
    return out.items;
}

fn bodyHints(r: *Resolver, a: context.At, start: u32, end: u32, out: *std.ArrayList(Hint)) resolve.Error!void {
    const b = a.body;
    const base = a.node.offset;
    for (b.bindings, 0..) |binding, i| {
        if (binding.kind != .local_const and binding.kind != .local_var) continue;
        if (binding.ty != null or binding.name.len == 0) continue;
        const at = base + binding.range.end;
        if (at < start or at > end) continue;
        const tv = a.bindingType(@fromBackingInt(@as(u32, @intCast(i))));
        // 未知的类型与值为类型的常量（`const T = u8`）不提示
        if (tv.ty == .unknown or tv.ty == .type_type) continue;
        try out.append(r.arena, .{ .offset = at, .label = try std.fmt.allocPrint(r.arena, ": {s}", .{try render.typeAlloc(r, tv.ty)}), .kind = .type });
    }
    for (b.exprs, 0..) |e, i| {
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
            switch (b.expr(arg)) {
                .name_ref => |n| if (std.mem.eql(u8, n, name)) continue,
                .field_access => |fa| if (fa.field) |f| if (std.mem.eql(u8, f, name)) continue,
                else => {},
            }
            try out.append(r.arena, .{ .offset = base + b.range(arg).start, .label = try std.fmt.allocPrint(r.arena, "{s}:", .{name}), .kind = .parameter });
        }
    }
}
