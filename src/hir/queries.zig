//! HIR query。

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const Vfs = @import("../base/Vfs.zig");
const ItemTree = @import("../syntax/ItemTree.zig");
const syntax = @import("../syntax/queries.zig");
const ast = @import("../syntax/ast.zig");
const Body = @import("Body.zig");
const lower = @import("lower.zig").lower;
const mem = @import("../util/mem.zig");

/// enum 成员与 union 中只写名字的字段（没有 `:`）：类型表达式的位置是名字。元组式结构体的字段同样
/// 没有 `:`，那里是类型，因此须由 ItemTree 得到所在容器的种类
fn fieldIsName(ctx: anytype, key: OwnerKey, node: ast.SyntaxNode) engine.Error!bool {
    if (node.kind() != .container_field or (ast.ContainerField{ .syntax = node }).name() != null) return false;
    const tree = try ctx.get(syntax.FileItemTree, key.file);
    for (tree.items) |it| if (it.ast_id == key.item) {
        const kind = tree.containers[it.container].kind;
        return kind == .@"enum" or kind == .@"union";
    };
    return false;
}

/// BodyOwner：文件中的一个容器成员（按稳定的 AstId 标识）
pub const OwnerKey = struct {
    file: Vfs.FileId,
    item: ItemTree.AstId,
};

/// 成员的 HIR。Body 内容（位置相对 owner）不变时视为未变化，下游不重算
pub const ItemBody = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = OwnerKey;
    pub const Value = *const Body;
    /// 约束长时间会话的内存：被淘汰的 Body 按需重新降级
    pub const lru = 16 * 1024;
    /// 值的大小差别很大（长函数的 HIR / 推导结果可达数百 KB），同时按字节数限制
    pub const lru_bytes = 48 * 1024 * 1024;

    pub fn bytes(v: Value) usize {
        return @sizeOf(Body) + mem.arenaBytes(v.arena);
    }

    pub fn compute(ctx: anytype, key: Key) engine.Error!Value {
        const map = try ctx.get(syntax.FileAstIdMap, key.file);
        const gpa = ctx.db.gpa;
        const result = try gpa.create(Body);
        errdefer gpa.destroy(result);
        // 找不到时（成员已被删除）降级根节点：不是成员，得到空 Body
        const node = map.get(key.item) orelse (try ctx.get(syntax.ParseFile, key.file)).rootNode();
        result.* = try lower(gpa, node, try fieldIsName(ctx, key, node));
        return result;
    }

    pub fn eql(a: Value, b: Value) bool {
        return a.eql(b);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        const b: *Body = @constCast(v.*);
        b.deinit(gpa);
        gpa.destroy(b);
    }
};
