//! goto definition / declaration / type definition：名字、成员访问、初始化中的字段名、标签、`@import` 字符串。
//!
//! declaration 跳到名字直接解析到的声明；definition 再沿容器级的别名（`const A = std.mem.Allocator;`）
//! 追到最终的定义；type definition 跳到光标处符号的类型（剥去指针、optional、数组、错误联合）的定义。

const std = @import("std");
const database = @import("../database.zig");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Def = resolve.Def;
const ast = @import("../syntax/ast.zig");
const SyntaxToken = ast.SyntaxToken;
const Body = @import("../hir/Body.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const context = @import("context.zig");
const queries = @import("../sema/queries.zig");
const TypedValue = @import("../sema/InternPool.zig").TypedValue;

pub const Target = struct { file: FileId, start: u32, end: u32 };

pub fn definition(r: *Resolver, file: FileId, offset: u32) resolve.Error!?Target {
    if (try labelTarget(r, file, offset)) |t| return t;
    const def = try defAt(r, file, offset) orelse return null;
    return target(r, try r.aliasTarget(def));
}

pub fn declaration(r: *Resolver, file: FileId, offset: u32) resolve.Error!?Target {
    if (try labelTarget(r, file, offset)) |t| return t;
    return target(r, try defAt(r, file, offset) orelse return null);
}

/// 标签：`break :l` / `continue :l` 中的 `l` 跳到带标签的块或循环的标签处，标签自身返回自身
fn labelTarget(r: *Resolver, file: FileId, offset: u32) resolve.Error!?Target {
    const tok = try tokenAt(r, file, offset) orelse return null;
    if (tok.kind != .identifier) return null;
    const item = try r.ownerAt(file, tok.offset, false) orelse return null;
    const node = try r.itemNode(file, item) orelse return null;
    const b = try r.body(file, item);
    const rel = tok.offset - node.offset;
    const e = b.exprAt(rel) orelse return null;
    const name = tok.text;
    const self_target: Target = .{ .file = file, .start = tok.offset, .end = tok.offset + @as(u32, @intCast(name.len)) };
    // 标签自身（块或循环的范围从标签开始）
    switch (b.expr(e)) {
        .block => |blk| if (blk.label) |l| if (b.range(e).start == rel and std.mem.eql(u8, l, name)) return self_target,
        .loop => |lp| if (lp.label) |l| if (b.range(e).start == rel and std.mem.eql(u8, l, name)) return self_target,
        else => {},
    }
    const label = switch (b.expr(e)) {
        .@"break" => |x| x.label,
        .@"continue" => |x| x.label,
        else => null,
    } orelse return null;
    // 光标在标签上，而不在 break 的值中
    const prev = (try r.ctx.get(database.syntax.ParseFile, file)).source[tok.offset - 1];
    if (!std.mem.eql(u8, label, name) or prev != ':') return null;
    var scope: ?Body.ScopeId = b.expr_scopes[@backingInt(e)];
    while (scope) |sc| : (scope = b.scopes[@backingInt(sc)].parent) {
        const l = b.scopes[@backingInt(sc)].label orelse continue;
        if (!std.mem.eql(u8, l.name, label)) continue;
        const start = node.offset + b.range(l.expr).start;
        return .{ .file = file, .start = start, .end = start + @as(u32, @intCast(label.len)) };
    }
    return null;
}

fn target(r: *Resolver, def: Def) resolve.Error!?Target {
    const loc = try r.location(def) orelse return null;
    return .{ .file = loc.file, .start = loc.start, .end = loc.end };
}

/// 光标处符号的类型的定义：声明与局部变量取其类型，表达式取推导出的类型；值本身是类型时取该类型。
/// 指针、optional、数组、切片、错误联合取其元素 / 载荷类型
pub fn typeDefinition(r: *Resolver, file: FileId, offset: u32) resolve.Error!?Target {
    const tok = try tokenAt(r, file, offset) orelse return null;
    const a = try context.atSeeded(r, file, tok.offset, false) orelse return null;
    const rel = tok.offset - a.node.offset;
    const tv: TypedValue = blk: {
        if (ast.memberName(a.node, try r.inEnum(file, a.item))) |name| if (name.offset == tok.offset) {
            break :blk try r.ctx.get(queries.DeclType, .{ .owner = a.owner });
        };
        for (a.body.bindings, 0..) |binding, i| if (binding.range.start == rel) break :blk a.bindingType(@fromBackingInt(@as(u32, @intCast(i))));
        break :blk a.exprType(a.body.exprAt(rel) orelse return null);
    };
    const ip = r.ctx.db.env.ip;
    var t = if (tv.ty == .type_type) tv.asType() orelse return null else tv.ty;
    for (0..8) |_| t = switch (ip.key(t)) {
        .ptr_type => |p| p.child,
        .optional_type => |c| c,
        .array_type => |arr| arr.child,
        .vector_type => |v| v.child,
        .error_union_type => |eu| eu.payload,
        else => break,
    };
    const ns = try queries.namespaceOfType(r, t) orelse return null;
    // 文件即容器：跳到文件开头
    if (ns.container == 0) return .{ .file = ns.file, .start = 0, .end = 0 };
    const tree = try r.itemTree(ns.file);
    // `const S = struct {...}`：跳到声明的名字；其他（如泛型函数返回的容器）跳到容器本身
    if (tree.containers[ns.container].parent_item) |p| if (tree.items[p].kind == .@"const") {
        if (try r.containerRel(ns)) |rel_c| if ((try r.body(ns.file, p)).value) |v| if ((try r.body(ns.file, p)).range(v).start == rel_c) {
            return target(r, .{ .item = .{ .file = ns.file, .item = p } });
        };
    };
    const start = try r.containerOffset(ns) orelse return null;
    return .{ .file = ns.file, .start = start, .end = start };
}

/// 光标处 token：优先取可跳转的 token，光标紧跟在标识符之后时取它
pub fn tokenAt(r: *Resolver, file: FileId, offset: u32) resolve.Error!?SyntaxToken {
    const root = (try r.ctx.get(database.syntax.ParseFile, file)).rootNode();
    if (root.tokenAtOffset(offset)) |t| if (isTarget(t)) return t;
    if (offset > 0) if (root.tokenAtOffset(offset - 1)) |t| if (isTarget(t)) return t;
    return null;
}

fn isTarget(t: SyntaxToken) bool {
    return t.kind == .identifier or t.kind == .builtin or t.kind == .string_literal;
}

pub fn defAt(r: *Resolver, file: FileId, offset: u32) resolve.Error!?Def {
    const tok = try tokenAt(r, file, offset) orelse return null;
    const item = try r.ownerAt(file, tok.offset, false) orelse return null;
    const node = try r.itemNode(file, item) orelse return null;
    // 成员自身的名字
    if (ast.memberName(node, try r.inEnum(file, item))) |name| if (name.offset == tok.offset) return .{ .item = .{ .file = file, .item = item } };

    const b = try r.body(file, item);
    const rel = tok.offset - node.offset;
    // 局部绑定自身的名字
    for (b.bindings, 0..) |binding, i| {
        if (binding.range.start == rel) return .{ .local = .{ .file = file, .item = item, .binding = @fromBackingInt(@as(u32, @intCast(i))) } };
    }
    const e = b.exprAt(rel) orelse return null;
    switch (b.expr(e)) {
        .name_ref => |name| return r.resolveName(file, item, b, b.expr_scopes[@backingInt(e)], name),
        .field_access => |fa| {
            // 光标在字段名上（不在左侧表达式内）
            if (rel < b.range(fa.lhs).end) return null;
            if (try r.evalNamespace(file, item, b, fa.lhs)) |ns| {
                if (try r.memberDef(ns, fa.field orelse return null)) |def| return def;
            }
            // 经由类型：字段、方法
            return memberViaTypes(r, file, tok.offset, e);
        },
        // decl literal（`.init(...)`、`.empty`）
        .enum_literal => return memberViaTypes(r, file, tok.offset, e),
        // 初始化中的字段名（`.{ .x = 1 }`、`S{ .x = 1 }`）：推导时按结果类型解析
        .init => |x| for (x.fields, 0..) |fi, k| {
            if (fi.name == null or rel < fi.name_range.start or rel >= fi.name_range.end) continue;
            const a = try context.atSeeded(r, file, tok.offset, false) orelse return null;
            return context.defOfKey(r, a.fieldRef(e, @intCast(k)) orelse return null);
        } else return null,
        .builtin_call => |call| return importDef(r, file, b, call),
        .literal => {
            // `@import("...")` 的字符串
            for (b.exprs) |other| switch (other) {
                .builtin_call => |call| if (std.mem.indexOfScalar(Body.ExprId, call.args, e) != null) return importDef(r, file, b, call),
                else => {},
            };
            return null;
        },
        else => return null,
    }
}

fn memberViaTypes(r: *Resolver, file: FileId, offset: u32, e: Body.ExprId) resolve.Error!?Def {
    // 泛型函数体内取调用点的实例
    const a = try context.atSeeded(r, file, offset, false) orelse return null;
    const key = a.member(e) orelse return null;
    return context.defOfKey(r, key);
}

fn importDef(r: *Resolver, file: FileId, b: *const Body, call: @FieldType(Body.Expr, "builtin_call")) resolve.Error!?Def {
    if (!std.mem.eql(u8, call.name, "@import")) return null;
    return .{ .file = try r.importTarget(file, b, call.args) orelse return null };
}
