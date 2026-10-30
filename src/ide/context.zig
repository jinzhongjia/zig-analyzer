//! Shared parts of the IDE features: the member at the cursor, its Body and inference result;
//! signatures and documentation of definitions.

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
    /// Position relative to the start of the member
    rel: u32,
    ip: *InternPool,
    /// Inference result for a call-site instance when the member is in a generic function (see
    /// `atSeeded`): parts of `res` that contain abstract parameters or are unknown come from here
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

    /// Expected type of an enum literal (null when there is no expected type)
    pub fn literalExpected(a: At, e: Body.ExprId) ?Index {
        for (a.res.literal_expected) |x| if (x.expr == e) return x.ty;
        if (a.seeded) |s| for (s.res.literal_expected) |x| if (x.expr == e) return x.ty;
        return null;
    }

    /// Whether the expected type of an enum literal comes from peer type resolution (see
    /// `infer.Result.LiteralExpected.tags_only`): it names only tags, not declarations
    pub fn literalTagsOnly(a: At, e: Body.ExprId) bool {
        for (a.res.literal_expected) |x| if (x.expr == e) return x.tags_only;
        if (a.seeded) |s| for (s.res.literal_expected) |x| if (x.expr == e) return x.tags_only;
        return false;
    }

    /// Field that the `index`-th field name in the initializer `init` resolves to
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

/// Same as `at`; when the member is inside a generic function, also attaches the inference result
/// of a call-site instance (`At.seeded`). The instance must make the code at the position execute
/// and the expression there have a known type (see `subjectAt`)
pub fn atSeeded(r: *Resolver, file: FileId, offset: u32, inclusive_end: bool) resolve.Error!?At {
    var a = try at(r, file, offset, inclusive_end) orelse return null;
    const subject = subjectAt(a.body, a.rel, inclusive_end);
    var refiner = try seed.Refiner.init(r, a.file, a.item, a.node.offset, a.body, a.res);
    a.seeded = try refiner.at(a.rel, subject);
    return a;
}

/// Expression at the position whose type must be known: the left-hand side when the position is
/// on the member name of a member access, otherwise the expression containing it. With
/// `inclusive_end`, the position is right after just-typed text (completion), so the expression
/// at the previous character is taken (such as the `.` of `a.`)
fn subjectAt(b: *const Body, rel: u32, inclusive_end: bool) ?seed.Subject {
    const at_ = if (inclusive_end and rel > 0) rel - 1 else rel;
    const e = b.exprAt(at_) orelse return null;
    return switch (b.expr(e)) {
        .field_access => |fa| .{ .expr = if (at_ >= b.range(fa.lhs).end) fa.lhs else e },
        else => .{ .expr = e },
    };
}

/// Definition of a member recorded in an inference result (by AstId)
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

/// Signature of a definition: the prototype for functions (see `ast.FnProto.writeSignature`), the
/// `const name: T = v` form for everything else
pub fn signature(r: *Resolver, def: Def, tv: TypedValue) resolve.Error![]const u8 {
    const ip = r.ctx.db.env.ip;
    switch (def) {
        .item => |it| {
            const tree = try r.itemTree(it.file);
            const item = tree.items[it.item];
            const node = try r.itemNode(it.file, it.item) orelse return render.typeAlloc(r, tv.ty);
            if (item.kind == .@"fn") if (ast.cast(ast.FnDecl, node)) |f| if (f.proto()) |p| {
                var out: std.Io.Writer.Allocating = .init(r.arena);
                if (item.flags.is_pub) out.writer.writeAll("pub ") catch return error.OutOfMemory;
                p.writeSignature(&out.writer) catch return error.OutOfMemory;
                return out.written();
            };
            const keyword = switch (item.kind) {
                .@"const" => "const ",
                .@"var" => "var ",
                else => "",
            };
            const name = if (item.name) |n| try std.fmt.allocPrint(r.arena, "{f}", .{std.zig.fmtId(n)}) else "_";
            // Container definition: `const S = struct`
            if (tv.asType()) |t| switch (ip.key(t)) {
                .container_type => |c| if (c.kind != .file) return std.fmt.allocPrint(r.arena, "{s}{s} = {t}", .{ keyword, name, c.kind }),
                else => {},
            };
            return std.fmt.allocPrint(r.arena, "{s}{s}{s}", .{ keyword, name, try render.annotationAlloc(r, tv) });
        },
        .local => |l| {
            const b = (try r.body(l.file, l.item)).binding(l.binding);
            const keyword = switch (b.kind) {
                .local_const => "const ",
                .local_var => "var ",
                .param, .capture => "",
            };
            return std.fmt.allocPrint(r.arena, "{s}{f}{s}", .{ keyword, std.zig.fmtId(b.name), try render.annotationAlloc(r, tv) });
        },
        .file => |f| return std.fmt.allocPrint(r.arena, "@import(\"{s}\")", .{std.fs.path.basename(r.ctx.db.env.vfs.path(f))}),
    }
}

/// Target function of a call: returns the function declaration and whether it is a method call
/// (which skips the self parameter)
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
            // It is a method call only when the member is a declaration whose value is a function
            // (including an alias such as `pub const put = putImpl;`) and the left-hand side is a
            // value (not a type): fields of function type do not bind a receiver
            const method = switch (def) {
                .item => |it| switch ((try r.itemTree(it.file)).items[it.item].kind) {
                    .@"fn" => true,
                    .@"const" => a.ip.key(a.exprType(callee_e).ty) == .fn_type,
                    else => false,
                },
                else => false,
            };
            return .{ .def = try fnDecl(r, a, callee_e, def), .bound = method and !a.exprType(fa.lhs).isType() };
        },
        .enum_literal => {
            const key = a.member(callee_e) orelse return null;
            return .{ .def = try fnDecl(r, a, callee_e, try defOfKey(r, key) orelse return null), .bound = false };
        },
        else => return null,
    }
}

/// When the called name is an alias (`const assert = std.debug.assert;`, including local
/// constants), takes the function declaration it points to: first follows the alias chain of
/// container members, and when that is still not a function, takes the declaration of the
/// inferred function value
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

/// Parameter nodes of a function declaration (in order)
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
