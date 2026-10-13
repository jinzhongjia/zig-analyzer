//! goto definition：名字、成员访问、`@import` 字符串。

const std = @import("std");
const database = @import("../database.zig");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Def = resolve.Def;
const ast = @import("../syntax/ast.zig");
const SyntaxToken = ast.SyntaxToken;
const Body = @import("../hir/Body.zig");
const FileId = @import("../base/Vfs.zig").FileId;

pub const Target = struct { file: FileId, start: u32, end: u32 };

pub fn definition(r: *Resolver, file: FileId, offset: u32) resolve.Error!?Target {
    const def = try defAt(r, file, offset) orelse return null;
    const loc = try r.location(def) orelse return null;
    return .{ .file = loc.file, .start = loc.start, .end = loc.end };
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
            const ns = try r.evalNamespace(file, item, b, fa.lhs) orelse return null;
            return r.memberDef(ns, fa.field orelse return null);
        },
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

fn importDef(r: *Resolver, file: FileId, b: *const Body, call: @FieldType(Body.Expr, "builtin_call")) resolve.Error!?Def {
    if (!std.mem.eql(u8, call.name, "@import")) return null;
    return .{ .file = try r.importTarget(file, b, call.args) orelse return null };
}
