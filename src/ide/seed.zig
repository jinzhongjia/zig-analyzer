//! 调用点种子（设计 §9.4）：泛型函数体内没有具体实例时（抽象参数、未知），取一个调用点的实例
//! 推导，hover 注明所依据的调用点。先按源码顺序找同一文件，再经由文件索引找其他文件，取第一个
//! 能求出具体实例的调用，结果确定、可复现。

const std = @import("std");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const database = @import("../database.zig");
const hir = database.hir;
const Body = @import("../hir/Body.zig");
const queries = @import("../sema/queries.zig");
const infer = @import("../sema/infer.zig");
const eval = @import("../sema/eval.zig");
const value = @import("../sema/value.zig");
const InternPool = @import("../sema/InternPool.zig");
const Index = InternPool.Index;
const TypedValue = InternPool.TypedValue;
const FileId = @import("../base/Vfs.zig").FileId;
const ast = @import("../syntax/ast.zig");
const search = @import("../ide_db/search.zig");
const FileIndex = @import("../ide_db/FileIndex.zig");

pub const Seed = struct {
    /// 成员 `item` 在调用点实例下的推导结果
    res: *const infer.Result,
    /// 调用表达式的位置
    file: FileId,
    offset: u32,
};

/// 成员 `item`（位于某个泛型函数内）以第一个调用点的实例推导的结果：先找同一文件，再按文件顺序找
/// 项目中其他能引用到该函数的文件
pub fn find(r: *Resolver, file: FileId, item: u32) resolve.Error!?Seed {
    const root = try genericRoot(r, file, item) orelse return null;
    const files = try search.importers(r, file, try search.projectFiles(r));
    const names = try callNames(r, file, root, files);
    if (try findIn(r, file, file, item, root, names)) |s| return s;
    for (files) |f| {
        if (f == file or !try containsAny(r, f, names)) continue;
        if (try findIn(r, f, file, item, root, names)) |s| return s;
    }
    return null;
}

/// 调用泛型函数 `root` 可能使用的名字：函数名，以及 `files` 中指向它的容器级别名
/// （`const biggest = lib.max;`，含别名的别名）。只检查文件索引中出现这些名字的文件
fn callNames(r: *Resolver, file: FileId, root: u32, files: []const FileId) resolve.Error![]const []const u8 {
    const target: resolve.Def = .{ .item = .{ .file = file, .item = root } };
    var names: std.ArrayList([]const u8) = .empty;
    try names.append(r.arena, (try r.itemTree(file)).items[root].name orelse return &.{});
    var changed = true;
    while (changed) {
        changed = false;
        for (files) |f| {
            if (!try containsAny(r, f, names.items)) continue;
            const tree = try r.itemTree(f);
            for (tree.items, 0..) |it, i| {
                if (it.kind != .@"const") continue;
                const name = it.name orelse continue;
                if (contains(names.items, name)) continue;
                if (!try mayMentionAny(r, f, @intCast(i), names.items)) continue;
                if (!mentionsAny(try r.body(f, @intCast(i)), names.items)) continue;
                const def = try r.aliasTarget(.{ .item = .{ .file = f, .item = @intCast(i) } });
                if (!std.meta.eql(def, target)) continue;
                try names.append(r.arena, name);
                changed = true;
            }
        }
    }
    return names.items;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn containsAny(r: *Resolver, f: FileId, names: []const []const u8) resolve.Error!bool {
    const index = try r.ctx.get(FileIndex.Query, f);
    for (names) |n| if (index.contains(n)) return true;
    return false;
}

/// 先用成员摘要粗筛，避免为不相关的成员生成 Body
fn mayMentionAny(r: *Resolver, f: FileId, item: u32, names: []const []const u8) resolve.Error!bool {
    for (names) |n| if (try r.mayMention(f, item, n)) return true;
    return false;
}

fn mentionsAny(body: *const Body, names: []const []const u8) bool {
    for (names) |n| if (search.mentions(body, n)) return true;
    return false;
}

/// 在文件 `in` 中查找泛型函数 `root`（位于 `file`）的调用点。
/// 只推导提到 `names`（函数名与别名）的成员：推导整个成员代价较高
fn findIn(r: *Resolver, in: FileId, file: FileId, item: u32, root: u32, names: []const []const u8) resolve.Error!?Seed {
    const ip = r.ctx.db.env.ip;
    const tree = try r.itemTree(in);
    const root_key = try r.ownerKey(file, root);
    for (tree.items, 0..) |_, i| {
        // 泛型函数自身体内的调用（递归）也是抽象的
        if (in == file and try enclosedBy(r, file, @intCast(i), root)) continue;
        if (!try mayMentionAny(r, in, @intCast(i), names)) continue;
        const owner = try r.ownerKey(in, @intCast(i));
        const body = try r.ctx.get(hir.ItemBody, owner);
        if (!mentionsAny(body, names)) continue;
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
            const node = try r.itemNode(in, @intCast(i)) orelse continue;
            const seeded = try r.ctx.get(queries.Infer, .{ .owner = try r.ownerKey(file, item), .mode = .full, .inst = try queries.normalizeInst(r, file, item, inst) });
            return .{ .res = seeded, .file = in, .offset = node.offset + body.range(@fromBackingInt(@as(u32, @intCast(ei)))).start };
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
