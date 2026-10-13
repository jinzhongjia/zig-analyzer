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

/// 文件内容：有 `FileText`（打开的文档、项目加载的文件）时用它，否则从磁盘读取。
///
/// 使名字解析与类型推导可以在查询内部访问任意文件（标准库、依赖包）。从磁盘读到的内容
/// 不会随磁盘变化而失效（没有对应的 input），只有 `FileText` 被设置时才重新计算。
pub const SourceText = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    /// `owned` 时内容由本 query 持有；否则借用 `FileText` 的值
    pub const Value = struct { text: []const u8, owned: bool };

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        if (try ctx.get(inputs.FileText, file)) |text| return .{ .text = text, .owned = false };
        // 不带 Vfs 的测试用 Db
        if (comptime @TypeOf(ctx.db.env) == void) return .{ .text = "", .owned = false };
        const vfs: *Vfs = ctx.db.env.vfs;
        const text = vfs.readFromDisk(file, ctx.db.gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            error.FileTooBig => null,
        };
        return .{ .text = text orelse "", .owned = text != null };
    }

    /// 借用的旧值可能已随 `FileText` 一起释放，不能读取：总是视为已变化
    pub fn eql(_: Value, _: Value) bool {
        return false;
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        if (v.owned) gpa.free(v.text);
    }
};

/// 文件的语法树。文本变化后总是视为已变化（不做 cutoff），由 ItemTree 截断变化的传播。
pub const ParseFile = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = *Parse;

    /// 有上一次的结果时尝试局部重解析（结果与全量解析相同，见 `Parse.reparse`）
    pub fn computeIncremental(ctx: anytype, file: Key, prev: ?Value) engine.Error!Value {
        const text = (try ctx.get(SourceText, file)).text;
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
