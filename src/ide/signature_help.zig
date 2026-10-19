//! signature help：光标所在调用的函数签名与当前参数。

const std = @import("std");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const context = @import("context.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const ast = @import("../syntax/ast.zig");
const builtins = @import("builtins.zig");
const database = @import("../database.zig");

pub const Signature = struct {
    label: []const u8,
    /// 参数的源码（label 中的子串）
    params: []const []const u8,
    active: u32,
    doc: ?[]const u8,
};

pub fn signatureHelp(r: *Resolver, file: FileId, offset: u32) resolve.Error!?Signature {
    const text = (try r.ctx.get(database.syntax.SourceText, file)).text;
    if (offset > text.len) return null;
    const root = (try r.ctx.get(database.syntax.ParseFile, file)).rootNode();
    const selected = enclosingCall(root, offset, text) orelse return null;
    const active = argumentIndex(selected, offset);
    if (ast.cast(ast.BuiltinCall, selected)) |call| {
        const name = call.name() orelse return null;
        const entry = builtins.get(name.text) orelse return null;
        const label = entry.signature orelse return null;
        return .{
            .label = label,
            .params = entry.parameters,
            .active = if (entry.parameters.len == 0) 0 else @min(active, @as(u32, @intCast(entry.parameters.len - 1))),
            .doc = entry.documentation,
        };
    }

    // 只有普通调用需要推导被调用者；泛型函数体内取调用点的实例。
    const a = try context.atSeeded(r, file, offset, true) orelse return null;
    const b = a.body;
    const call = for (b.exprs, b.expr_ranges) |e, range| {
        if (e == .call and a.node.offset + range.start == selected.offset) break e.call;
    } else return null;
    const target = try context.callee(r, a, call.callee) orelse return null;
    const params = try context.fnParams(r, target.def);
    if (params.len == 0 and target.def != .item) return null;

    const it = target.def.item;
    const node = try r.itemNode(it.file, it.item) orelse return null;
    const proto = (ast.cast(ast.FnDecl, node) orelse return null).proto() orelse return null;
    const label = try context.collapsedText(r, it.file, proto.syntax);
    const texts = try r.arena.alloc([]const u8, params.len);
    for (params, texts) |p, *t| t.* = try context.collapsedText(r, it.file, p.syntax);
    return .{ .label = label, .params = texts, .active = active + @as(u32, @intFromBool(target.bound)), .doc = try context.doc(r, target.def) };
}

/// CST 的参数列表直接包含分隔逗号，嵌套表达式、注释和字符串中的逗号不参与计数。
fn argumentIndex(call: ast.SyntaxNode, offset: u32) u32 {
    const list = call.childNode(.arg_list) orelse return 0;
    var active: u32 = 0;
    var it = list.children();
    while (it.next()) |element| if (element == .token) {
        const token = element.token;
        if (token.kind == .comma and token.offset < offset) active += 1;
    };
    return active;
}

/// 在覆盖光标的路径上选择最内层调用，未完成的列表在文件末尾仍然有效。
fn enclosingCall(node: ast.SyntaxNode, offset: u32, text: []const u8) ?ast.SyntaxNode {
    if (offset < node.offset) return null;
    if (offset > node.range().end and !onlyTrivia(text[node.range().end..offset])) return null;
    var best: ?ast.SyntaxNode = null;
    if (node.kind() == .builtin_call or node.kind() == .call_expr) {
        if (node.childNode(.arg_list)) |list| {
            const open = list.childToken(.l_paren);
            const close = list.childToken(.r_paren);
            const inside = offset <= list.range().end or
                (close == null and onlyTrivia(text[list.range().end..offset]));
            if (open != null and offset > open.?.offset and inside and
                (close == null or offset <= close.?.offset)) best = node;
        }
    }
    var children = node.children();
    while (children.nextNode()) |child| {
        if (enclosingCall(child, offset, text)) |inner| best = inner;
    }
    return best;
}

/// 未闭合调用末尾的空白和行注释可能位于调用节点之外，仍属于正在编辑的参数位置。
fn onlyTrivia(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        if (std.ascii.isWhitespace(text[i])) {
            i += 1;
        } else if (std.mem.startsWith(u8, text[i..], "//")) {
            i = if (std.mem.indexOfScalarPos(u8, text, i, '\n')) |end| end + 1 else text.len;
        } else return false;
    }
    return true;
}
