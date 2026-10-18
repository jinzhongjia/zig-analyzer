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
const InternPool = @import("../sema/InternPool.zig");
const TypedValue = InternPool.TypedValue;
const Index = InternPool.Index;
const seed = @import("../ide_db/seed.zig");
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
    ip: *InternPool,
    /// 成员位于泛型函数内时以调用点的实例推导的结果（见 `atSeeded`）：`res` 中含抽象参数或
    /// 未知的部分取自这里
    seeded: ?seed.Seed = null,

    pub fn exprType(a: At, e: Body.ExprId) TypedValue {
        return a.better(a.res.exprs, if (a.seeded) |s| s.res.exprs else &.{}, @backingInt(e));
    }

    pub fn bindingType(a: At, b: Body.BindingId) TypedValue {
        return a.better(a.res.bindings, if (a.seeded) |s| s.res.bindings else &.{}, @backingInt(b));
    }

    fn better(a: At, abstract: []const TypedValue, seeded: []const TypedValue, i: u32) TypedValue {
        const tv: TypedValue = if (i < abstract.len) abstract[i] else .unknown;
        if (i < seeded.len and seed.wanted(a.ip, tv) and !seed.wanted(a.ip, seeded[i])) return seeded[i];
        return tv;
    }

    /// 枚举字面量的期望类型（没有期望类型时为 null）
    pub fn literalExpected(a: At, e: Body.ExprId) ?Index {
        for (a.res.literal_expected) |x| if (x.expr == e) return x.ty;
        if (a.seeded) |s| for (s.res.literal_expected) |x| if (x.expr == e) return x.ty;
        return null;
    }

    /// 初始化表达式 `init` 中第 `index` 个字段名解析到的字段
    pub fn fieldRef(a: At, init: Body.ExprId, index: u32) ?hir.OwnerKey {
        for (a.res.field_refs) |f| if (f.init == init and f.index == index) return f.member;
        if (a.seeded) |s| for (s.res.field_refs) |f| if (f.init == init and f.index == index) return f.member;
        return null;
    }

    pub fn member(a: At, e: Body.ExprId) ?hir.OwnerKey {
        const i = @backingInt(e);
        if (i < a.res.members.len) if (a.res.members[i]) |m| return m;
        if (a.seeded) |s| if (i < s.res.members.len) return s.res.members[i];
        return null;
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
        .ip = r.ctx.db.env.ip,
    };
}

/// 同 `at`；成员位于泛型函数内时附带调用点实例的推导结果（`At.seeded`），实例须使该位置的代码会执行、
/// 该处的表达式能求出类型（见 `subjectAt`）
pub fn atSeeded(r: *Resolver, file: FileId, offset: u32, inclusive_end: bool) resolve.Error!?At {
    var a = try at(r, file, offset, inclusive_end) orelse return null;
    const subject = subjectAt(a.body, a.rel, inclusive_end);
    a.seeded = try seed.findAt(r, a.file, a.item, a.rel, subject);
    // 遍历类型列表的循环中：按一次迭代推导
    const base = if (a.seeded) |s| s.res else a.res;
    if (try seed.loopAt(r, a.owner, a.body, base, if (a.seeded) |s| s.inst else null, a.node.offset, a.rel, subject)) |s| a.seeded = s;
    return a;
}

/// 位置处须能求出类型的表达式：位于成员访问的成员名处时取左侧，否则取所在的表达式。`inclusive_end` 时位置在
/// 刚输入的内容之后（补全），取前一个字符所在的表达式（如 `a.` 的 `.`）
fn subjectAt(b: *const Body, rel: u32, inclusive_end: bool) ?seed.Subject {
    const at_ = if (inclusive_end and rel > 0) rel - 1 else rel;
    const e = b.exprAt(at_) orelse return null;
    return switch (b.expr(e)) {
        .field_access => |fa| .{ .expr = if (at_ >= b.range(fa.lhs).end) fa.lhs else e },
        else => .{ .expr = e },
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
            return .{ .def = try fnDecl(r, a, callee_e, def), .bound = false };
        },
        .field_access => |fa| {
            const key = a.member(callee_e) orelse return null;
            const def = try defOfKey(r, key) orelse return null;
            // 左侧是值（不是类型）时为方法调用
            return .{ .def = try fnDecl(r, a, callee_e, def), .bound = !a.exprType(fa.lhs).isType() };
        },
        .enum_literal => {
            const key = a.member(callee_e) orelse return null;
            return .{ .def = try fnDecl(r, a, callee_e, try defOfKey(r, key) orelse return null), .bound = false };
        },
        else => return null,
    }
}

/// 被调用的名字是别名（`const assert = std.debug.assert;`，含局部常量）时取它指向的函数声明：
/// 先沿容器成员的别名链，仍不是函数时取推导出的函数值的声明
fn fnDecl(r: *Resolver, a: At, callee_e: Body.ExprId, def: Def) resolve.Error!Def {
    const target = try r.aliasTarget(def);
    switch (target) {
        .item => |it| if ((try r.itemTree(it.file)).items[it.item].kind == .@"fn") return target,
        .local, .file => {},
    }
    const v = a.exprType(callee_e).val orelse return target;
    return switch (r.ctx.db.env.ip.key(v)) {
        .fn_value => |f| try defOfKey(r, .{ .file = f.file, .item = f.decl }) orelse target,
        else => target,
    };
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
