//! sema query（设计 §9.2）：声明类型与 Body 的类型推导。

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const database = @import("../database.zig");
const Db = database.Db;
const hir = database.hir;
const InternPool = @import("InternPool.zig");
const Index = InternPool.Index;
const TypedValue = InternPool.TypedValue;
const infer = @import("infer.zig");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Namespace = resolve.Namespace;
const ast = @import("../syntax/ast.zig");
const ItemTree = @import("../syntax/ItemTree.zig");
const FileId = @import("../base/Vfs.zig").FileId;

pub const InferKey = struct {
    owner: hir.OwnerKey,
    mode: infer.Mode,
};

/// BodyOwner 的类型推导结果。签名模式不读取函数体与初始化表达式，
/// 只改这些内容时依赖签名的 query 不必重算
pub const Infer = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = InferKey;
    pub const Value = *const infer.Result;

    pub fn compute(ctx: *Db.Ctx, key: Key) engine.Error!Value {
        const gpa = ctx.db.gpa;
        const result = try gpa.create(infer.Result);
        errdefer gpa.destroy(result);
        result.* = try infer.run(ctx, key.owner, key.mode);
        return result;
    }

    pub fn cycleFallback(_: Key) Value {
        return &empty_result;
    }

    pub fn eql(a: Value, b: Value) bool {
        return a.eql(b);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        if (v.* == &empty_result) return;
        const r: *infer.Result = @constCast(v.*);
        r.deinit(gpa);
        gpa.destroy(r);
    }
};

const empty_result: infer.Result = .{ .arena = .{}, .exprs = &.{}, .bindings = &.{}, .members = &.{} };

/// 声明的类型；const 的值 comptime 已知时附带值（如 `const S = struct {...}` 的值为类型 S）
pub const DeclType = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = hir.OwnerKey;
    pub const Value = TypedValue;

    pub fn compute(ctx: *Db.Ctx, key: Key) engine.Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        const ip = ctx.db.env.ip;
        const tree = try r.itemTree(key.file);
        const item: u32 = for (tree.items, 0..) |it, i| {
            if (it.ast_id == key.item) break @intCast(i);
        } else return .unknown;
        const b = try ctx.get(hir.ItemBody, key);
        switch (tree.items[item].kind) {
            .@"fn" => {
                const res = try ctx.get(Infer, .{ .owner = key, .mode = .signature });
                if (res.exprs.len == 0) return .unknown;
                const node = try r.itemNode(key.file, item) orelse return .unknown;
                const proto = (ast.cast(ast.FnDecl, node) orelse return .unknown).proto() orelse return .unknown;
                // 按语法中的参数个数（含 anytype 与无名参数）
                var params: std.ArrayList(Index) = .empty;
                var it = proto.params();
                var named: usize = 0;
                while (it.next()) |p| {
                    const param = ast.cast(ast.Param, p).?;
                    if (param.name() != null and named < b.params.len) {
                        try params.append(r.arena, res.bindings[@backingInt(b.params[named])].ty);
                        named += 1;
                    } else try params.append(r.arena, .unknown);
                }
                var ret: Index = if (b.type_expr) |t| res.exprs[@backingInt(t)].asType() orelse .unknown else .unknown;
                // 推导的错误集暂以 anyerror 表示（由函数体推导属于后续工作）
                if (proto.inferredErrorSet() and ret != .unknown) ret = try ip.get(.{ .error_union_type = .{ .err = .anyerror_type, .payload = ret } });
                const ty = try ip.get(.{ .fn_type = .{ .params = params.items, .ret = ret } });
                return .{ .ty = ty, .val = try ip.get(.{ .fn_value = .{ .ty = ty, .file = key.file, .decl = key.item } }) };
            },
            .@"const", .@"var" => {
                const res = try ctx.get(Infer, .{ .owner = key, .mode = .full });
                if (res.exprs.len == 0) return .unknown;
                const annotation: ?Index = if (b.type_expr) |t| res.exprs[@backingInt(t)].asType() orelse .unknown else null;
                const value: TypedValue = if (b.value) |v| res.exprs[@backingInt(v)] else .unknown;
                const is_const = tree.items[item].kind == .@"const";
                if (annotation) |t| return .{ .ty = t, .val = if (is_const and value.ty == t) value.val else null };
                return if (is_const) value else .{ .ty = value.ty };
            },
            .field => {
                const container = tree.items[item].container;
                if (tree.containers[container].kind == .@"enum") {
                    const ty = try containerType(&r, .{ .file = key.file, .container = container });
                    return .{ .ty = ty, .val = try ip.get(.{ .enum_tag = .{ .ty = ty, .name = tree.items[item].name orelse "" } }) };
                }
                const res = try ctx.get(Infer, .{ .owner = key, .mode = .signature });
                if (res.exprs.len == 0) return .unknown;
                return .{ .ty = if (b.type_expr) |t| res.exprs[@backingInt(t)].asType() orelse .unknown else .unknown };
            },
            .@"test", .@"comptime" => return .{ .ty = .void_type },
        }
    }

    pub fn cycleFallback(_: Key) Value {
        return .unknown;
    }
};

/// 推导进行中的局部绑定（同一 owner 内直接读取，避免循环）
pub const LocalScope = struct {
    file: FileId,
    item: u32,
    bindings: []const TypedValue,
};

/// 名字解析结果的类型
pub fn defType(r: *Resolver, def: resolve.Def, current: ?LocalScope) resolve.Error!TypedValue {
    switch (def) {
        .item => |it| {
            const tree = try r.itemTree(it.file);
            return r.ctx.get(DeclType, .{ .file = it.file, .item = tree.items[it.item].ast_id });
        },
        .local => |l| {
            if (current) |c| if (c.file == l.file and c.item == l.item) return c.bindings[@backingInt(l.binding)];
            const res = try r.ctx.get(Infer, .{ .owner = try r.ownerKey(l.file, l.item), .mode = .full });
            if (@backingInt(l.binding) >= res.bindings.len) return .unknown;
            return res.bindings[@backingInt(l.binding)];
        },
        .file => |f| return TypedValue.ofType(try containerType(r, .{ .file = f, .container = 0 })),
    }
}

/// 命名空间（文件中的容器）对应的容器类型
pub fn containerType(r: *Resolver, ns: Namespace) resolve.Error!Index {
    const tree = try r.itemTree(ns.file);
    const c = tree.containers[ns.container];
    return r.ctx.db.env.ip.get(.{ .container_type = .{ .file = ns.file, .ast_id = c.ast_id, .kind = switch (c.kind) {
        .file => .file,
        .@"struct" => .@"struct",
        .@"enum" => .@"enum",
        .@"union" => .@"union",
        .@"opaque" => .@"opaque",
    } } });
}

pub fn namespaceOfType(r: *Resolver, t: Index) resolve.Error!?Namespace {
    const c = switch (r.ctx.db.env.ip.key(t)) {
        .container_type => |c| c,
        else => return null,
    };
    const tree = try r.itemTree(c.file);
    for (tree.containers, 0..) |x, i| if (x.ast_id == c.ast_id) return .{ .file = c.file, .container = @intCast(i) };
    return null;
}

test {
    _ = @import("sema_test.zig");
}
