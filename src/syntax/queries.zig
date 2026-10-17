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
const ast = @import("ast.zig");
const mem = @import("../util/mem.zig");

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
/// 解析结果占内存最多（约为源码的十几倍）：只保留最近使用的若干个，其余淘汰后按需重新解析
pub const parse_lru = 64;

pub const ParseFile = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = *Parse;
    pub const lru = parse_lru;

    /// 增量解析的结果共享未变的节点，同一文件的新旧结果会重复计入
    pub fn bytes(v: Value) usize {
        return @sizeOf(Parse) + v.arena.queryCapacity() + v.source.len;
    }

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
    /// 约束长时间会话的内存：每个访问过的文件都有一份，大项目（Zig 编译器源码与标准库）中可达 50 MB。
    /// 被淘汰的按需重建；依赖未变时沿用原 changed_at，下游不重算
    pub const lru = 16 * 1024;
    pub const lru_bytes = 32 * 1024 * 1024;

    pub fn bytes(v: Value) usize {
        return @sizeOf(ItemTree) + mem.arenaBytes(v.arena);
    }

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
/// 成员的摘要：位置与可能提到的名字
pub const ItemSummary = struct {
    /// 成员节点在文件中的起始位置；找不到节点时为 null
    offset: ?u32,
    /// 名字 token 在文件中的起始位置与长度；没有名字（或找不到节点）时长度为 0
    name_offset: u32 = 0,
    name_len: u32 = 0,
    /// 成员节点内出现的标识符（含嵌套成员）的布隆过滤器：判断「可能提到某个名字」，
    /// 有假阳性、无假阴性
    names: [4]u64 = @splat(0),

    pub fn mayMention(s: ItemSummary, name: []const u8) bool {
        const bits = bloomBits(name);
        return s.names[bits[0] / 64] & bitMask(bits[0]) != 0 and s.names[bits[1] / 64] & bitMask(bits[1]) != 0;
    }

    fn add(s: *ItemSummary, name: []const u8) void {
        for (bloomBits(name)) |b| s.names[b / 64] |= bitMask(b);
    }

    fn bloomBits(name: []const u8) [2]u8 {
        const h = std.hash.Wyhash.hash(0, name);
        return .{ @truncate(h), @truncate(h >> 8) };
    }

    fn bitMask(b: u8) u64 {
        return @as(u64, 1) << @intCast(b % 64);
    }
};

/// 文件中各成员与容器的摘要（与 `ItemTree.items` / `containers` 一一对应）。值很小且不淘汰：
/// 只需要位置或只需判断成员是否提到某个名字的场景（引用查找、调用点种子、定位体内的容器、workspace symbol），
/// 不必为已被淘汰的解析结果重新解析，也不必为不相关的成员生成 Body。
/// 单独作为一个 query，不放进 ItemTree：函数体内的编辑会改变它，而 ItemTree 必须保持不变
pub const ItemSummaries = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = *const Summaries;

    pub fn bytes(v: Value) usize {
        return @sizeOf(Summaries) + v.items.len * @sizeOf(ItemSummary) + v.container_offsets.len * @sizeOf(?u32);
    }

    pub const Summaries = struct {
        items: []ItemSummary,
        /// 容器节点在文件中的起始位置；找不到节点时为 null
        container_offsets: []?u32,
    };

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        const items = try ctx.get(FileItemTree, file);
        const map = try ctx.get(FileAstIdMap, file);
        const gpa = ctx.db.gpa;
        const out = try gpa.create(Summaries);
        errdefer gpa.destroy(out);
        out.items = try gpa.alloc(ItemSummary, items.items.len);
        errdefer gpa.free(out.items);
        out.container_offsets = try gpa.alloc(?u32, items.containers.len);
        for (items.items, out.items) |it, *o| {
            const node = map.get(it.ast_id) orelse {
                o.* = .{ .offset = null };
                continue;
            };
            o.* = .{ .offset = node.offset };
            if (ast.memberName(node, ItemTree.bareFieldNames(items.containers[it.container].kind))) |t| {
                o.name_offset = t.offset;
                o.name_len = @intCast(t.text.len);
            }
            collectNames(node, o);
        }
        for (items.containers, out.container_offsets) |c, *o| o.* = if (map.get(c.ast_id)) |n| n.offset else null;
        return out;
    }

    fn collectNames(node: ast.SyntaxNode, s: *ItemSummary) void {
        var it = node.children();
        while (it.next()) |e| switch (e) {
            .token => |t| if (t.kind == .identifier) {
                var buf: [256]u8 = undefined;
                s.add(ast.identNameBuf(t.text, &buf));
            },
            .node => |c| collectNames(c, s),
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        return std.mem.eql(u8, std.mem.sliceAsBytes(a.items), std.mem.sliceAsBytes(b.items)) and
            std.mem.eql(?u32, a.container_offsets, b.container_offsets);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        const s: *Summaries = @constCast(v.*);
        gpa.free(s.items);
        gpa.free(s.container_offsets);
        gpa.destroy(s);
    }
};

/// 值中的节点指向解析结果：持有其一份引用，`ParseFile` 的值被淘汰后仍然有效
pub const FileAstIdMap = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = *const ItemTree.AstIdMap;
    pub const lru = parse_lru;

    pub fn bytes(v: Value) usize {
        return v.bytes();
    }

    const Owned = struct {
        map: ItemTree.AstIdMap,
        parse: *Parse,
    };

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        const parse = try ctx.get(ParseFile, file);
        const items = try ctx.get(FileItemTree, file);
        const gpa = ctx.db.gpa;
        const result = try gpa.create(Owned);
        errdefer gpa.destroy(result);
        result.* = .{ .map = try ItemTree.AstIdMap.build(gpa, items, parse.rootNode()), .parse = parse.retain() };
        return &result.map;
    }

    pub fn eql(a: Value, b: Value) bool {
        return a == b;
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        const owned: *Owned = @alignCast(@fieldParentPtr("map", @constCast(v.*)));
        owned.map.deinit(gpa);
        owned.parse.destroy();
        gpa.destroy(owned);
    }
};

test {
    _ = @import("queries_test.zig");
}
