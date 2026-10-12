//! 语法层 query。
//!
//! `compute` 的 ctx 参数为 `anytype`，使这些 query 可以注册到不同的 Db 类型中（例如测试专用的 Db）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const Vfs = @import("../base/Vfs.zig");
const inputs = @import("../base/inputs.zig");
const Parse = @import("Parse.zig");
const ItemTree = @import("ItemTree.zig");

/// 文件的语法树。文本变化后总是视为已变化（不做 cutoff），由 ItemTree 截断变化的传播。
pub const ParseFile = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = *Parse;

    /// 有上一次的结果时尝试局部重解析（结果与全量解析相同，见 `Parse.reparse`）
    pub fn computeIncremental(ctx: anytype, file: Key, prev: ?Value) engine.Error!Value {
        const text = try ctx.get(inputs.FileText, file) orelse "";
        if (prev) |old| return Parse.reparse(ctx.db.gpa, old, text);
        return Parse.create(ctx.db.gpa, text);
    }

    pub fn eql(a: Value, b: Value) bool {
        return a == b;
    }

    pub fn deinit(v: *Value, _: Allocator) void {
        v.*.destroy();
    }
};

/// 文件的声明骨架，最重要的 early cutoff 点。
pub const FileItemTree = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = *const ItemTree;

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        const parse = try ctx.get(ParseFile, file);
        const gpa = ctx.db.gpa;
        const result = try gpa.create(ItemTree);
        errdefer gpa.destroy(result);
        result.* = try ItemTree.build(gpa, parse.rootNode());
        return result;
    }

    pub fn eql(a: Value, b: Value) bool {
        return a.eql(b);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        const t: *ItemTree = @constCast(v.*);
        t.deinit(gpa);
        gpa.destroy(t);
    }
};

/// AstId → 当前语法树节点。随每次解析重建，只在读取时使用，不应作为其他缓存结果的一部分。
pub const FileAstIdMap = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = *const ItemTree.AstIdMap;

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        const parse = try ctx.get(ParseFile, file);
        const items = try ctx.get(FileItemTree, file);
        const gpa = ctx.db.gpa;
        const result = try gpa.create(ItemTree.AstIdMap);
        errdefer gpa.destroy(result);
        result.* = try ItemTree.AstIdMap.build(gpa, items, parse.rootNode());
        return result;
    }

    pub fn eql(a: Value, b: Value) bool {
        return a == b;
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        const m: *ItemTree.AstIdMap = @constCast(v.*);
        m.deinit(gpa);
        gpa.destroy(m);
    }
};

test {
    _ = @import("queries_test.zig");
}
