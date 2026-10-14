//! 名字补全：`a.` 之后列出命名空间的成员，否则列出光标处可见的名字（局部名字与外层容器的声明）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Namespace = resolve.Namespace;
const ItemTree = @import("../syntax/ItemTree.zig");
const Body = @import("../hir/Body.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const context = @import("context.zig");
const queries = @import("../sema/queries.zig");
const render = @import("../sema/render.zig");
const eval = @import("../sema/eval.zig");
const InternPool = @import("../sema/InternPool.zig");
const TypedValue = InternPool.TypedValue;
const Index = InternPool.Index;

pub const Item = struct {
    label: []const u8,
    kind: Kind,
    /// 文档注释
    doc: ?[]const u8 = null,
    /// 类型
    detail: ?[]const u8 = null,

    pub const Kind = enum { param, local, capture, function, constant, variable, field, enum_member };
};

pub fn complete(r: *Resolver, file: FileId, offset: u32) resolve.Error![]const Item {
    var out: Collector = .{ .arena = r.arena };
    const item = try r.ownerAt(file, offset, true) orelse return &.{};
    const node = try r.itemNode(file, item) orelse return &.{};
    const b = try r.body(file, item);
    const rel = offset - node.offset;

    // `lhs.` / `lhs.na`：光标前一个字符在字段访问内、且不在左侧表达式内
    if (rel > 0) if (b.exprAt(rel - 1)) |e| switch (b.expr(e)) {
        .field_access => |fa| if (rel - 1 >= b.range(fa.lhs).end) {
            if (try r.evalNamespace(file, item, b, fa.lhs)) |ns| {
                try members(r, &out, ns, ns.file == file);
                return out.items.items;
            }
            // 经由类型：实例的字段与方法
            const a = try context.at(r, file, offset, true) orelse return &.{};
            try typedMembers(r, &out, a.exprType(fa.lhs), file);
            return out.items.items;
        },
        else => {},
    };

    // `.` / `.na`（枚举字面量、decl literal）：按期望类型列出成员
    if (rel > 0) if (b.exprAt(rel - 1)) |e| if (b.expr(e) == .enum_literal) {
        const a = try context.at(r, file, offset, true) orelse return &.{};
        try expectedMembers(r, &out, a.literalExpected(e) orelse return &.{}, file);
        return out.items.items;
    };

    // 作用域中的名字：光标紧跟在名字之后时取该名字所在的作用域
    const scope = if (rel > 0) if (b.exprAt(rel - 1)) |e| switch (b.expr(e)) {
        .name_ref => b.expr_scopes[@backingInt(e)],
        else => b.scopeAt(rel),
    } else b.scopeAt(rel) else b.scopeAt(rel);
    try locals(&out, b, scope);

    const tree = try r.itemTree(file);
    var container = tree.items[item].container;
    while (true) {
        try decls(&out, tree, container, true);
        const parent = tree.containers[container].parent_item orelse break;
        // 体内定义的容器：外层成员在容器位置可见的局部名字
        const owner = try r.itemNode(file, parent) orelse break;
        const c_node = try r.containerNode(.{ .file = file, .container = container }) orelse break;
        const pb = try r.body(file, parent);
        try locals(&out, pb, pb.scopeAt(c_node.offset - owner.offset));
        container = tree.items[parent].container;
    }
    return out.items.items;
}

const Collector = struct {
    arena: Allocator,
    items: std.ArrayList(Item) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,

    /// 内层的名字遮蔽外层的同名名字。不是合法标识符的名字（如 `@"struct"`）以引号形式插入
    fn add(c: *Collector, item: Item) Allocator.Error!void {
        if (item.label.len == 0) return;
        if ((try c.seen.getOrPut(c.arena, item.label)).found_existing) return;
        var out = item;
        if (!std.zig.isValidId(item.label)) out.label = try std.fmt.allocPrint(c.arena, "{f}", .{std.zig.fmtId(item.label)});
        try c.items.append(c.arena, out);
    }
};

fn locals(out: *Collector, b: *const Body, from: Body.ScopeId) Allocator.Error!void {
    var s: ?Body.ScopeId = from;
    while (s) |id| : (s = b.scope(id).parent) {
        for (b.scope(id).bindings) |bid| {
            const binding = b.binding(bid);
            try out.add(.{ .label = binding.name, .kind = switch (binding.kind) {
                .param => .param,
                .local_const, .local_var => .local,
                .capture => .capture,
            } });
        }
    }
}

fn decls(out: *Collector, tree: *const ItemTree, container: u32, private: bool) Allocator.Error!void {
    const is_enum = tree.containers[container].kind == .@"enum";
    for (tree.containerMembers(container)) |m| {
        const it = tree.items[m];
        const name = it.name orelse continue;
        const kind: Item.Kind = switch (it.kind) {
            .@"fn" => .function,
            .@"const" => .constant,
            .@"var" => .variable,
            // 字段不是作用域中的名字；枚举成员可以通过类型访问
            .field => if (is_enum and !private) .enum_member else continue,
            .@"test", .@"comptime" => continue,
        };
        if (!private and it.kind != .field and !it.flags.is_pub) continue;
        try out.add(.{ .label = name, .kind = kind, .doc = it.doc });
    }
}

/// 按类型列出成员：值为类型时列出声明；实例（含单指针）列出字段与方法；切片与数组有 len
fn typedMembers(r: *Resolver, out: *Collector, tv: TypedValue, from: FileId) resolve.Error!void {
    const ip = r.ctx.db.env.ip;
    if (tv.asType()) |t| {
        // 构造的枚举（`@Enum`、union(enum) 的标签枚举）：成员
        switch (ip.key(t)) {
            .reified_type, .union_tag_type => {
                for (try eval.enumMemberNames(r, t)) |name| try out.add(.{ .label = name, .kind = .enum_member });
                return;
            },
            else => {},
        }
        const ns = try queries.namespaceOfType(r, t) orelse return;
        return members(r, out, ns, ns.file == from);
    }
    var t = tv.ty;
    switch (ip.key(t)) {
        .ptr_type => |p| switch (p.size) {
            .one => t = p.child,
            .slice => {
                try out.add(.{ .label = "len", .kind = .field, .detail = "usize" });
                try out.add(.{ .label = "ptr", .kind = .field });
                return;
            },
            else => return,
        },
        .array_type => return out.add(.{ .label = "len", .kind = .field, .detail = "usize" }),
        // 元组、匿名结构体、构造的结构体与 union：字段
        .tuple_type, .anon_struct_type, .reified_type => {
            for (try eval.fieldNames(r, t)) |f| try out.add(.{ .label = f.name, .kind = .field, .detail = if (f.ty != .unknown) try render.typeAlloc(r, f.ty) else null });
            if (ip.key(t) == .tuple_type) try out.add(.{ .label = "len", .kind = .field, .detail = "usize" });
            return;
        },
        else => {},
    }
    const ns = try queries.namespaceOfType(r, t) orelse return;
    const tree = try r.itemTree(ns.file);
    const same_file = ns.file == from;
    for (tree.containerMembers(ns.container)) |m| {
        const it = tree.items[m];
        const name = it.name orelse continue;
        switch (it.kind) {
            .field => {
                const fty = (try r.ctx.get(queries.DeclType, .{ .owner = .{ .file = ns.file, .item = it.ast_id }, .inst = queries.instOfType(r.ctx.db.env.ip, t) })).ty;
                try out.add(.{ .label = name, .kind = .field, .doc = it.doc, .detail = if (fty != .unknown) try render.typeAlloc(r, fty) else null });
            },
            .@"fn" => if (same_file or it.flags.is_pub) try out.add(.{ .label = name, .kind = .function, .doc = it.doc }),
            else => {},
        }
    }
}

/// `.` 之后：期望类型（`?T` 取 `T`）的枚举成员、union 的字段，以及可以作为 decl literal 的声明
/// （类型为 `T` 的常量、返回 `T` 或 `!T` 的函数；类型推导不出时也列出）
fn expectedMembers(r: *Resolver, out: *Collector, ty: Index, from: FileId) resolve.Error!void {
    const ip = r.ctx.db.env.ip;
    const t = switch (ip.key(ty)) {
        .optional_type => |c| c,
        else => ty,
    };
    switch (ip.key(t)) {
        .reified_type, .union_tag_type => {
            for (try eval.enumMemberNames(r, t)) |name| try out.add(.{ .label = name, .kind = .enum_member });
            return;
        },
        .container_type => {},
        else => return,
    }
    const ns = try queries.namespaceOfType(r, t) orelse return;
    const tree = try r.itemTree(ns.file);
    const kind = tree.containers[ns.container].kind;
    const inst = queries.instOfType(ip, t);
    for (tree.containerMembers(ns.container)) |m| {
        const it = tree.items[m];
        const name = it.name orelse continue;
        switch (it.kind) {
            .field => switch (kind) {
                .@"enum" => try out.add(.{ .label = name, .kind = .enum_member, .doc = it.doc }),
                .@"union" => try out.add(.{ .label = name, .kind = .field, .doc = it.doc }),
                else => {},
            },
            .@"const", .@"fn" => {
                if (ns.file != from and !it.flags.is_pub) continue;
                const decl_ty = (try r.ctx.get(queries.DeclType, .{ .owner = .{ .file = ns.file, .item = it.ast_id }, .inst = inst })).ty;
                if (!producesType(ip, decl_ty, t, it.kind == .@"fn")) continue;
                try out.add(.{ .label = name, .kind = if (it.kind == .@"fn") .function else .constant, .doc = it.doc });
            },
            else => {},
        }
    }
}

/// 声明能否作为类型 `t` 的 decl literal：常量的类型为 `t`，函数返回 `t` 或 `!t`；类型未知时视为可以
fn producesType(ip: *InternPool, decl_ty: Index, t: Index, is_fn: bool) bool {
    if (decl_ty == .unknown) return true;
    if (!is_fn) return decl_ty == t;
    const ret = switch (ip.key(decl_ty)) {
        .fn_type => |f| f.ret,
        else => return false,
    };
    if (ret == .unknown or ret == t) return true;
    return switch (ip.key(ret)) {
        .error_union_type => |eu| eu.payload == t or eu.payload == .unknown,
        else => false,
    };
}

/// `ns.` 之后的成员；同一文件中可以访问非 pub 声明
fn members(r: *Resolver, out: *Collector, ns: Namespace, same_file: bool) resolve.Error!void {
    const tree = try r.itemTree(ns.file);
    if (ns.container >= tree.containers.len) return;
    try decls(out, tree, ns.container, same_file);
    if (same_file and tree.containers[ns.container].kind == .@"enum") {
        for (tree.containerMembers(ns.container)) |m| {
            const it = tree.items[m];
            if (it.kind == .field) if (it.name) |name| try out.add(.{ .label = name, .kind = .enum_member, .doc = it.doc });
        }
    }
}
