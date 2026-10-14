//! HIR query。

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const Vfs = @import("../base/Vfs.zig");
const ItemTree = @import("../syntax/ItemTree.zig");
const syntax = @import("../syntax/queries.zig");
const Body = @import("Body.zig");
const lower = @import("lower.zig").lower;

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

    pub fn compute(ctx: anytype, key: Key) engine.Error!Value {
        const map = try ctx.get(syntax.FileAstIdMap, key.file);
        const gpa = ctx.db.gpa;
        const result = try gpa.create(Body);
        errdefer gpa.destroy(result);
        // 找不到时（成员已被删除）降级根节点：不是成员，得到空 Body
        const node = map.get(key.item) orelse (try ctx.get(syntax.ParseFile, key.file)).rootNode();
        result.* = try lower(gpa, node);
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
