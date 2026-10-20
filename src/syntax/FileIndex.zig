//! 文件索引：文件中出现的标识符名字与 `@import` 字符串。
//!
//! 引用查找、调用点种子与 workspace symbol 先用它粗筛候选文件，再在候选文件中精确解析。
//! 名字已去掉 `@"..."` 的引号；只依赖语法树，内容不变（名字、没有分析的名字与 import 都相同）时下游不重算。

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const Vfs = @import("../base/Vfs.zig");
const syntax = @import("queries.zig");
const ast = @import("ast.zig");
const SyntaxNode = ast.SyntaxNode;
const TextRange = @import("tree.zig").TextRange;
const deepEql = @import("../util/deep_eql.zig").deepEql;
const mem = @import("../util/mem.zig");

const FileIndex = @This();

arena: std.heap.ArenaAllocator.State,
/// 去重并按字典序排列
names: []const []const u8,
/// 出现在嵌套超过上限、没有语法结构的代码中（`Parse.flattened`）的名字，排列同 `names`。
/// 这些位置是否引用了某个声明无法判断
unanalyzed: []const []const u8,
/// `@import("...")` 的字符串（已解码），按出现顺序
imports: []const []const u8,

pub fn contains(index: *const FileIndex, name: []const u8) bool {
    return sortedContains(index.names, name);
}

/// 名字出现在没有分析的代码中（见 `unanalyzed`）
pub fn containsUnanalyzed(index: *const FileIndex, name: []const u8) bool {
    return sortedContains(index.unanalyzed, name);
}

fn sortedContains(names: []const []const u8, name: []const u8) bool {
    return std.sort.binarySearch([]const u8, names, name, struct {
        fn order(n: []const u8, x: []const u8) std.math.Order {
            return std.mem.order(u8, n, x);
        }
    }.order) != null;
}

/// `flattened` 为解析结果中没有语法结构的区间（`Parse.flattened`）
pub fn build(gpa: Allocator, root: SyntaxNode, flattened: []const TextRange) Allocator.Error!FileIndex {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var w: Walker = .{ .gpa = gpa, .a = a, .flattened = flattened };
    defer w.names.deinit(gpa);
    defer w.unanalyzed.deinit(gpa);
    try w.walk(root);
    const names = try sortedCopy(a, w.names.keys());
    const unanalyzed = try sortedCopy(a, w.unanalyzed.keys());
    return .{ .arena = arena.state, .names = names, .unanalyzed = unanalyzed, .imports = w.imports.items };
}

fn sortedCopy(a: Allocator, keys: []const []const u8) Allocator.Error![]const []const u8 {
    const sorted = try a.alloc([]const u8, keys.len);
    for (keys, sorted) |k, *s| s.* = try a.dupe(u8, k);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return sorted;
}

const Walker = struct {
    gpa: Allocator,
    a: Allocator,
    flattened: []const TextRange,
    /// `flattened` 中第一个不在已访问 token 之前结束的区间（token 按位置依次访问）
    next_flattened: usize = 0,
    names: std.StringArrayHashMapUnmanaged(void) = .empty,
    unanalyzed: std.StringArrayHashMapUnmanaged(void) = .empty,
    imports: std.ArrayList([]const u8) = .empty,

    fn walk(w: *Walker, node: SyntaxNode) Allocator.Error!void {
        if (ast.cast(ast.BuiltinCall, node)) |call| if (call.name()) |n| if (std.mem.eql(u8, n.text, "@import")) {
            var args = call.args();
            if (args.next()) |arg| if (arg.firstToken()) |t| if (t.kind == .string_literal) {
                if (std.zig.string_literal.parseAlloc(w.a, t.text)) |s| try w.imports.append(w.a, s) else |_| {}
            };
        };
        var it = node.children();
        while (it.next()) |e| switch (e) {
            .token => |t| if (t.kind == .identifier) {
                const name = try ast.identNameAlloc(w.a, t.text);
                try w.names.put(w.gpa, name, {});
                if (w.inFlattened(t.offset)) try w.unanalyzed.put(w.gpa, name, {});
            },
            .node => |c| try w.walk(c),
        };
    }

    fn inFlattened(w: *Walker, offset: u32) bool {
        while (w.next_flattened < w.flattened.len and w.flattened[w.next_flattened].end <= offset) w.next_flattened += 1;
        return w.next_flattened < w.flattened.len and w.flattened[w.next_flattened].contains(offset);
    }
};

pub fn deinit(index: *FileIndex, gpa: Allocator) void {
    var arena = index.arena.promote(gpa);
    arena.deinit();
    index.* = undefined;
}

pub const Query = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Vfs.FileId;
    pub const Value = *const FileIndex;

    pub fn bytes(v: Value) usize {
        return @sizeOf(FileIndex) + mem.arenaBytes(v.arena);
    }

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        const parse = try ctx.get(syntax.ParseFile, file);
        const gpa = ctx.db.gpa;
        const result = try gpa.create(FileIndex);
        errdefer gpa.destroy(result);
        result.* = try build(gpa, parse.rootNode(), parse.flattened);
        return result;
    }

    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a.names, b.names) and deepEql(a.unanalyzed, b.unanalyzed) and deepEql(a.imports, b.imports);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        const i: *FileIndex = @constCast(v.*);
        i.deinit(gpa);
        gpa.destroy(i);
    }
};

test build {
    const Parse = @import("Parse.zig");
    const p = try Parse.create(std.testing.allocator,
        \\const std = @import("std");
        \\const lib = @import("lib/a.zig");
        \\fn f(@"x y": u8, z: u8) void { _ = .{ @"x y", z, std.mem }; }
    );
    defer p.destroy();
    var index = try build(std.testing.allocator, p.rootNode(), p.flattened);
    defer index.deinit(std.testing.allocator);
    try std.testing.expect(index.contains("mem"));
    try std.testing.expect(index.contains("x y"));
    try std.testing.expect(!index.contains("import"));
    try std.testing.expectEqual(2, index.imports.len);
    try std.testing.expectEqualStrings("lib/a.zig", index.imports[1]);
}

test "names in code nested beyond the depth limit are unanalyzed" {
    const Parse = @import("Parse.zig");
    const a = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    // 左结合的运算链每项深一层：最左边的若干项在深度上限之外
    try src.appendSlice(a, "const one: u32 = 1;\nconst sum = one");
    for (0..1100) |_| try src.appendSlice(a, " + one");
    try src.appendSlice(a, ";\nfn f() u32 {\n    return sum;\n}\n");
    const p = try Parse.create(a, src.items);
    defer p.destroy();
    var index = try build(a, p.rootNode(), p.flattened);
    defer index.deinit(a);
    try std.testing.expect(index.contains("one"));
    try std.testing.expect(index.containsUnanalyzed("one"));
    try std.testing.expect(index.contains("sum"));
    try std.testing.expect(!index.containsUnanalyzed("sum"));
    try std.testing.expect(!index.containsUnanalyzed("f"));
}
