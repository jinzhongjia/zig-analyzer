//! 符号的种类：语义着色与补全共用（着色映射为 token 类型，补全映射为 `CompletionItemKind`）。
//!
//! 由声明的种类与推导出的类型决定：值为类型的按类型分为命名空间（文件）、结构体、枚举与其他类型（union、opaque、
//! 标量等）；值为函数（或函数指针）的为函数；容器（不是文件）中第一个参数是所在容器或指向它的单指针的函数为方法。
//! 类型求不出时按声明的种类（变量）。

const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const database = @import("../database.zig");
const ItemTree = @import("../syntax/ItemTree.zig");
const Body = @import("../hir/Body.zig");
const InternPool = @import("../sema/InternPool.zig");
const FileId = @import("../base/Vfs.zig").FileId;

pub const Kind = enum { namespace, @"struct", @"enum", type, function, method, variable, field, enum_member, parameter, type_parameter };

pub const Symbol = struct {
    kind: Kind,
    /// 不可修改：`const` 声明、局部常量、参数与捕获
    readonly: bool = false,
};

/// `file` 中的成员 `item`（ItemTree 的下标）
pub fn ofDecl(r: *Resolver, file: FileId, item: u32) resolve.Error!Symbol {
    const tree = try r.itemTree(file);
    const it = tree.items[item];
    const key: database.hir.OwnerKey = .{ .file = file, .item = it.ast_id };
    const ip = r.ctx.db.env.ip;
    return switch (it.kind) {
        .@"fn" => .{ .kind = try functionKind(r, key, tree.containers[it.container]) },
        .field => .{ .kind = if (tree.containers[it.container].kind == .@"enum") .enum_member else .field },
        .@"const" => .{ .kind = ofValue(ip, try r.ctx.get(database.sema.DeclType, .{ .owner = key }), .variable), .readonly = true },
        .@"var" => .{ .kind = ofValue(ip, try r.ctx.get(database.sema.DeclType, .{ .owner = key }), .variable) },
        .@"test", .@"comptime" => .{ .kind = .variable },
    };
}

/// 函数 `key` 所在的容器为 `container`
pub fn functionKind(r: *Resolver, key: database.hir.OwnerKey, container: ItemTree.Container) resolve.Error!Kind {
    if (container.kind == .file) return .function;
    const ip = r.ctx.db.env.ip;
    const tv = try r.ctx.get(database.sema.DeclType, .{ .owner = key });
    const signature = switch (ip.key(tv.ty)) {
        .fn_type => |f| f,
        else => return .function,
    };
    if (signature.params.len == 0) return .function;
    const receiver = switch (ip.key(signature.params[0])) {
        .ptr_type => |p| if (p.size == .one) p.child else return .function,
        else => signature.params[0],
    };
    return switch (ip.key(receiver)) {
        .container_type => |c| if (c.file == key.file and c.ast_id == container.ast_id) .method else .function,
        else => .function,
    };
}

/// 值 `tv` 的种类：不是类型也不是函数时为 `fallback`
pub fn ofValue(ip: *InternPool, tv: InternPool.TypedValue, fallback: Kind) Kind {
    if (tv.isType()) {
        const ty = tv.asType() orelse return .type;
        return switch (ip.key(ty)) {
            .container_type => |c| switch (c.kind) {
                .file => .namespace,
                .@"struct" => .@"struct",
                .@"enum" => .@"enum",
                .@"union", .@"opaque" => .type,
            },
            .reified_type => |c| switch (c.kind) {
                .@"struct" => .@"struct",
                .@"enum" => .@"enum",
                .@"union" => .type,
            },
            .union_tag_type => .@"enum",
            else => .type,
        };
    }
    return switch (ip.key(tv.ty)) {
        .fn_type => .function,
        .ptr_type => |p| if (ip.key(p.child) == .fn_type) .function else fallback,
        else => fallback,
    };
}

/// 局部绑定（类型为 `tv`）：值为类型的参数为类型参数
pub fn ofBinding(ip: *InternPool, binding: Body.Binding, tv: InternPool.TypedValue) Symbol {
    if (binding.kind == .param) return .{ .kind = if (tv.isType()) .type_parameter else .parameter, .readonly = true };
    return .{ .kind = ofValue(ip, tv, .variable), .readonly = binding.kind != .local_var };
}
