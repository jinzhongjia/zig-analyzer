//! IDE 功能的公共部分：光标所在的成员、Body 与推导结果；定义的签名与文档。

const std = @import("std");
const database = @import("../database.zig");
const hir = database.hir;
const sema = database.sema;
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Def = resolve.Def;
const ast = @import("../syntax/ast.zig");
const SyntaxNode = ast.SyntaxNode;
const Body = @import("../hir/Body.zig");
const infer = @import("../sema/infer.zig");
const render = @import("../sema/render.zig");
const TypedValue = @import("../sema/InternPool.zig").TypedValue;
const FileId = @import("../base/Vfs.zig").FileId;

pub const At = struct {
    file: FileId,
    item: u32,
    node: SyntaxNode,
    owner: hir.OwnerKey,
    body: *const Body,
    res: *const infer.Result,
    /// 相对成员起点的位置
    rel: u32,

    pub fn exprType(a: At, e: Body.ExprId) TypedValue {
        const i = @backingInt(e);
        return if (i < a.res.exprs.len) a.res.exprs[i] else .unknown;
    }

    pub fn bindingType(a: At, b: Body.BindingId) TypedValue {
        const i = @backingInt(b);
        return if (i < a.res.bindings.len) a.res.bindings[i] else .unknown;
    }

    pub fn member(a: At, e: Body.ExprId) ?hir.OwnerKey {
        const i = @backingInt(e);
        return if (i < a.res.members.len) a.res.members[i] else null;
    }
};

pub fn at(r: *Resolver, file: FileId, offset: u32, inclusive_end: bool) resolve.Error!?At {
    const item = try r.ownerAt(file, offset, inclusive_end) orelse return null;
    const node = try r.itemNode(file, item) orelse return null;
    const owner = try r.ownerKey(file, item);
    return .{
        .file = file,
        .item = item,
        .node = node,
        .owner = owner,
        .body = try r.ctx.get(hir.ItemBody, owner),
        .res = try r.ctx.get(sema.Infer, .{ .owner = owner, .mode = .full }),
        .rel = offset - node.offset,
    };
}

/// 推导结果中记录的成员（按 AstId）对应的定义
pub fn defOfKey(r: *Resolver, key: hir.OwnerKey) resolve.Error!?Def {
    const tree = try r.itemTree(key.file);
    for (tree.items, 0..) |it, i| if (it.ast_id == key.item) return .{ .item = .{ .file = key.file, .item = @intCast(i) } };
    return null;
}

pub fn doc(r: *Resolver, def: Def) resolve.Error!?[]const u8 {
    return switch (def) {
        .item => |it| (try r.itemTree(it.file)).items[it.item].doc,
        else => null,
    };
}

/// 节点源码，空白折叠为单个空格（用于签名显示）
pub fn collapsedText(r: *Resolver, file: FileId, node: SyntaxNode) resolve.Error![]const u8 {
    const text = (try r.ctx.get(database.syntax.SourceText, file)).text;
    const range = node.range();
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (text[range.start..range.end]) |c| {
        if (std.ascii.isWhitespace(c)) {
            space = out.items.len != 0;
            continue;
        }
        if (space) try out.append(r.arena, ' ');
        space = false;
        try out.append(r.arena, c);
    }
    return out.items;
}

/// 定义的签名：函数为原型源码，其他为 `const name: T = v` 形式
pub fn signature(r: *Resolver, def: Def, tv: TypedValue) resolve.Error![]const u8 {
    const ip = r.ctx.db.env.ip;
    switch (def) {
        .item => |it| {
            const tree = try r.itemTree(it.file);
            const item = tree.items[it.item];
            const node = try r.itemNode(it.file, it.item) orelse return render.typeAlloc(r, tv.ty);
            if (item.kind == .@"fn") if (ast.cast(ast.FnDecl, node)) |f| if (f.proto()) |p| {
                const proto = try collapsedText(r, it.file, p.syntax);
                return if (item.flags.is_pub) std.fmt.allocPrint(r.arena, "pub {s}", .{proto}) else proto;
            };
            const keyword = switch (item.kind) {
                .@"const" => "const ",
                .@"var" => "var ",
                else => "",
            };
            const name = if (item.name) |n| (if (std.zig.isValidId(n)) n else try std.fmt.allocPrint(r.arena, "{f}", .{std.zig.fmtId(n)})) else "_";
            // 容器定义：`const S = struct`
            if (tv.asType()) |t| switch (ip.key(t)) {
                .container_type => |c| if (c.kind != .file) return std.fmt.allocPrint(r.arena, "{s}{s} = {t}", .{ keyword, name, c.kind }),
                else => {},
            };
            return std.fmt.allocPrint(r.arena, "{s}{s}: {s}", .{ keyword, name, try render.typedValueAlloc(r, tv) });
        },
        .local => |l| {
            const b = (try r.body(l.file, l.item)).binding(l.binding);
            const keyword = switch (b.kind) {
                .local_const => "const ",
                .local_var => "var ",
                .param, .capture => "",
            };
            return std.fmt.allocPrint(r.arena, "{s}{s}: {s}", .{ keyword, b.name, try render.typedValueAlloc(r, tv) });
        },
        .file => |f| return std.fmt.allocPrint(r.arena, "@import(\"{s}\")", .{std.fs.path.basename(r.ctx.db.env.vfs.path(f))}),
    }
}

/// 调用的目标函数：返回函数声明与是否为方法调用（跳过 self 参数）
pub fn callee(r: *Resolver, a: At, callee_e: Body.ExprId) resolve.Error!?struct { def: Def, bound: bool } {
    const b = a.body;
    switch (b.expr(callee_e)) {
        .name_ref => |name| {
            const def = try r.resolveName(a.file, a.item, b, b.expr_scopes[@backingInt(callee_e)], name) orelse return null;
            return .{ .def = def, .bound = false };
        },
        .field_access => |fa| {
            const key = a.member(callee_e) orelse return null;
            const def = try defOfKey(r, key) orelse return null;
            // 左侧是值（不是类型）时为方法调用
            return .{ .def = def, .bound = !a.exprType(fa.lhs).isType() };
        },
        .enum_literal => {
            const key = a.member(callee_e) orelse return null;
            return .{ .def = try defOfKey(r, key) orelse return null, .bound = false };
        },
        else => return null,
    }
}

/// 函数声明的参数节点（按顺序）
pub fn fnParams(r: *Resolver, def: Def) resolve.Error![]const ast.Param {
    const it = switch (def) {
        .item => |x| x,
        else => return &.{},
    };
    const node = try r.itemNode(it.file, it.item) orelse return &.{};
    const proto = (ast.cast(ast.FnDecl, node) orelse return &.{}).proto() orelse return &.{};
    var out: std.ArrayList(ast.Param) = .empty;
    var params = proto.params();
    while (params.next()) |p| try out.append(r.arena, ast.cast(ast.Param, p).?);
    return out.items;
}

test {
    _ = @import("ide_test.zig");
}
