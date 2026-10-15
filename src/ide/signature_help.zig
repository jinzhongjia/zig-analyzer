//! signature help：光标所在调用的函数签名与当前参数。

const std = @import("std");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const context = @import("context.zig");
const Body = @import("../hir/Body.zig");
const FileId = @import("../base/Vfs.zig").FileId;

pub const Signature = struct {
    label: []const u8,
    /// 参数的源码（label 中的子串）
    params: []const []const u8,
    active: u32,
    doc: ?[]const u8,
};

pub fn signatureHelp(r: *Resolver, file: FileId, offset: u32) resolve.Error!?Signature {
    // 泛型函数体内取调用点的实例
    const a = try context.atSeeded(r, file, offset, true) orelse return null;
    const b = a.body;
    // 光标在参数括号内的最内层调用
    var best: ?Body.ExprId = null;
    var best_len: u32 = std.math.maxInt(u32);
    for (b.exprs, b.expr_ranges, 0..) |e, range, i| {
        if (e != .call) continue;
        const open = b.range(e.call.callee).end;
        if (!(open < a.rel and a.rel <= range.end)) continue;
        // 已闭合的调用：光标在 `)` 之后不算
        if (a.rel == range.end and range.end > open and isClosed(r, file, a.node.offset + range.end) catch false) continue;
        if (range.end - range.start < best_len) {
            best = @fromBackingInt(@as(u32, @intCast(i)));
            best_len = range.end - range.start;
        }
    }
    const call_e = best orelse return null;
    const call = b.expr(call_e).call;
    const target = try context.callee(r, a, call.callee) orelse return null;
    const params = try context.fnParams(r, target.def);
    if (params.len == 0 and target.def != .item) return null;

    const it = target.def.item;
    const node = try r.itemNode(it.file, it.item) orelse return null;
    const proto = (@import("../syntax/ast.zig").cast(@import("../syntax/ast.zig").FnDecl, node) orelse return null).proto() orelse return null;
    const label = try context.collapsedText(r, it.file, proto.syntax);
    const texts = try r.arena.alloc([]const u8, params.len);
    for (params, texts) |p, *t| t.* = try context.collapsedText(r, it.file, p.syntax);

    // 当前参数：光标之前已结束的实参个数
    var active: u32 = 0;
    for (call.args) |arg| {
        if (b.range(arg).end < a.rel) active += 1;
    }
    if (active > 0 and active <= call.args.len and b.range(call.args[active - 1]).end >= a.rel) active -= 1;
    if (target.bound) active += 1;
    return .{ .label = label, .params = texts, .active = active, .doc = try context.doc(r, target.def) };
}

/// `end` 前一个非空白字符是否为 `)`
fn isClosed(r: *Resolver, file: FileId, end: u32) resolve.Error!bool {
    const text = (try r.ctx.get(@import("../database.zig").syntax.SourceText, file)).text;
    var i = end;
    while (i > 0) {
        i -= 1;
        if (!std.ascii.isWhitespace(text[i])) return text[i] == ')';
    }
    return false;
}
