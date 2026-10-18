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
        return @sizeOf(Owned) + mem.arenaBytes(v.arena);
    }

    /// Body 与降级它的成员源码：文本不变时下一次计算直接沿用（引用计数，与 `ParseFile` 沿用旧结果相同）
    const Owned = struct {
        body: Body,
        refs: std.atomic.Value(u32) = .init(1),
        source_hash: u64,
        field_is_name: bool,

        fn of(v: Value) *Owned {
            return @alignCast(@fieldParentPtr("body", @constCast(v)));
        }
    };

    /// 文件中任何编辑都使 `FileAstIdMap` 变化（按指针比较），各成员的 Body 随之重算：成员的源码文本与降级
    /// 参数未变时沿用上一次的 Body（降级只读取成员自身的语法树，位置相对成员起点），不再重新降级。
    /// 非活动代码等需要文件中全部成员的功能，在大文件上每次编辑都要重新降级上千个成员
    pub fn computeIncremental(ctx: anytype, key: Key, prev: ?Value) engine.Error!Value {
        const map = try ctx.get(syntax.FileAstIdMap, key.file);
        const parse = try ctx.get(syntax.ParseFile, key.file);
        // 找不到时（成员已被删除）降级根节点：不是成员，得到空 Body
        const node = map.get(key.item) orelse parse.rootNode();
        const field_is_name = try fieldIsName(ctx, key, node);
        const source_hash = std.hash.Wyhash.hash(0, node.text(parse.source));
        if (prev) |p| {
            const o = Owned.of(p);
            if (o.source_hash == source_hash and o.field_is_name == field_is_name) {
                _ = o.refs.fetchAdd(1, .monotonic);
                return p;
            }
        }
        const gpa = ctx.db.gpa;
        const result = try gpa.create(Owned);
        errdefer gpa.destroy(result);
        result.* = .{ .body = try lower(gpa, node, field_is_name), .source_hash = source_hash, .field_is_name = field_is_name };
        return &result.body;
    }

    pub fn eql(a: Value, b: Value) bool {
        return a == b or a.eql(b);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        const o = Owned.of(v.*);
        if (o.refs.fetchSub(1, .acq_rel) != 1) return;
        o.body.deinit(gpa);
        gpa.destroy(o);
    }
};

/// 参数的形式：有无类型标注（`anytype`）与是否 comptime
pub const ParamForm = enum(u8) { typed, comptime_typed, any, comptime_any };

/// 成员（函数）各参数的形式。调用处据此判断是否为泛型调用：只改函数体时值不变，调用者不随之重算
/// （直接依赖 `ItemBody` 时，改被调函数的函数体会使它的全部调用者失效）
pub const ParamForms = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = OwnerKey;
    pub const Value = []const ParamForm;

    pub fn compute(ctx: anytype, key: Key) engine.Error!Value {
        const body = try ctx.get(ItemBody, key);
        const forms = try ctx.db.gpa.alloc(ParamForm, body.params.len);
        for (body.params, forms) |p, *f| {
            const b = body.binding(p);
            f.* = if (b.ty == null)
                (if (b.is_comptime) .comptime_any else .any)
            else if (b.is_comptime) .comptime_typed else .typed;
        }
        return forms;
    }

    pub fn eql(a: Value, b: Value) bool {
        return std.mem.eql(ParamForm, a, b);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        gpa.free(v.*);
    }
};
