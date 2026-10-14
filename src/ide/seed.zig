//! 调用点种子（设计 §9.4）：泛型函数体内没有具体实例时（抽象参数、未知），取一个调用点的实例
//! 推导，hover 注明所依据的调用点。按源码顺序取同一文件中第一个能求出具体实例的调用，结果确定、
//! 可复现；跨文件查找调用点依赖引用索引（M6）。

const std = @import("std");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const database = @import("../database.zig");
const hir = database.hir;
const queries = @import("../sema/queries.zig");
const infer = @import("../sema/infer.zig");
const eval = @import("../sema/eval.zig");
const value = @import("../sema/value.zig");
const InternPool = @import("../sema/InternPool.zig");
const Index = InternPool.Index;
const TypedValue = InternPool.TypedValue;
const FileId = @import("../base/Vfs.zig").FileId;

pub const Seed = struct {
    /// 成员 `item` 在调用点实例下的推导结果
    res: *const infer.Result,
    /// 调用表达式的位置
    file: FileId,
    offset: u32,
};

/// 成员 `item`（位于某个泛型函数内）以同一文件中第一个调用点的实例推导的结果
pub fn find(r: *Resolver, file: FileId, item: u32) resolve.Error!?Seed {
    const ip = r.ctx.db.env.ip;
    const root = try genericRoot(r, file, item) orelse return null;
    const tree = try r.itemTree(file);
    const root_key = try r.ownerKey(file, root);
    for (tree.items, 0..) |_, i| {
        // 泛型函数自身体内的调用（递归）也是抽象的
        if (try enclosedBy(r, file, @intCast(i), root)) continue;
        const owner = try r.ownerKey(file, @intCast(i));
        const body = try r.ctx.get(hir.ItemBody, owner);
        const res = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full });
        if (res.exprs.len != body.exprs.len) continue;
        for (body.exprs, 0..) |e, ei| {
            const c = switch (e) {
                .call => |c| c,
                else => continue,
            };
            const callee = res.exprs[@backingInt(c.callee)];
            const fv = switch (ip.key(callee.val orelse continue)) {
                .fn_value => |v| v,
                else => continue,
            };
            if (fv.file != root_key.file or fv.decl != root_key.item) continue;
            const f = switch (ip.key(callee.ty)) {
                .fn_type => |f| f,
                else => continue,
            };
            const g = try infer.genericCallee(r, r.arena, callee, f) orelse continue;
            // 方法调用：接收者是第一个实参
            const receiver: ?TypedValue = switch (body.expr(c.callee)) {
                .field_access => |fa| if (!res.exprs[@backingInt(fa.lhs)].isType()) res.exprs[@backingInt(fa.lhs)] else null,
                else => null,
            };
            const skip: usize = @intFromBool(receiver != null);
            const args = try r.arena.alloc(TypedValue, g.body.params.len);
            for (args, 0..) |*a, ai| a.* = if (ai < skip) receiver.? else if (ai - skip < c.args.len) res.exprs[@backingInt(c.args[ai - skip])] else .unknown;
            const inst = try infer.instanceOf(r, r.arena, g, f, args);
            if (!value.isConcrete(ip, inst)) continue;
            const node = try r.itemNode(file, @intCast(i)) orelse continue;
            const seeded = try r.ctx.get(queries.Infer, .{ .owner = try r.ownerKey(file, item), .mode = .full, .inst = try queries.normalizeInst(r, file, item, inst) });
            return .{ .res = seeded, .file = file, .offset = node.offset + body.range(@fromBackingInt(@as(u32, @intCast(ei)))).start };
        }
    }
    return null;
}

/// 包含成员 `item` 的最内层泛型函数（成员自身，或经由体内定义的容器的外层函数）
fn genericRoot(r: *Resolver, file: FileId, item: u32) resolve.Error!?u32 {
    const tree = try r.itemTree(file);
    var cur: ?u32 = item;
    while (cur) |it| : (cur = tree.containers[tree.items[it].container].parent_item) {
        if (tree.items[it].kind == .@"fn" and try isGeneric(r, file, it)) return it;
    }
    return null;
}

/// 有 comptime（含隐式的）或 anytype 参数，或返回 comptime-only 类型的函数
fn isGeneric(r: *Resolver, file: FileId, item: u32) resolve.Error!bool {
    const owner = try r.ownerKey(file, item);
    const body = try r.ctx.get(hir.ItemBody, owner);
    for (body.params) |p| {
        const b = body.binding(p);
        if (b.is_comptime or b.ty == null) return true;
    }
    const decl = try r.ctx.get(queries.DeclType, .{ .owner = owner });
    const f = switch (r.ctx.db.env.ip.key(decl.ty)) {
        .fn_type => |f| f,
        else => return false,
    };
    for (f.params) |p| if (try eval.isComptimeOnly(r, p)) return true;
    return eval.isComptimeOnly(r, f.ret);
}

fn enclosedBy(r: *Resolver, file: FileId, item: u32, root: u32) resolve.Error!bool {
    const tree = try r.itemTree(file);
    var cur: ?u32 = item;
    while (cur) |it| : (cur = tree.containers[tree.items[it].container].parent_item) {
        if (it == root) return true;
    }
    return false;
}

/// 类型中含抽象参数或未知部分：值得以调用点的实例重新推导
pub fn wanted(ip: *InternPool, tv: TypedValue) bool {
    if (tv.ty == .unknown or !value.isConcrete(ip, tv.ty)) return true;
    if (tv.ty == .type_type) return tv.val == null or !value.isConcrete(ip, tv.val.?);
    return false;
}
