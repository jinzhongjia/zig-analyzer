//! 文件索引：文件中出现的标识符名字与 `@import` 字符串。
//!
//! 引用查找、调用点种子与 workspace symbol 先用它粗筛候选文件，再在候选文件中精确解析。
//! 名字已去掉 `@"..."` 的引号；只依赖语法树，内容不变（名字与 import 都相同）时下游不重算。

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const Vfs = @import("../base/Vfs.zig");
const syntax = @import("../syntax/queries.zig");
const ast = @import("../syntax/ast.zig");
const SyntaxNode = ast.SyntaxNode;
const deepEql = @import("../util/deep_eql.zig").deepEql;
const mem = @import("../util/mem.zig");

const FileIndex = @This();

arena: std.heap.ArenaAllocator.State,
/// 去重并按字典序排列
names: []const []const u8,
/// `@import("...")` 的字符串（已解码），按出现顺序
imports: []const []const u8,

pub fn contains(index: *const FileIndex, name: []const u8) bool {
    return std.sort.binarySearch([]const u8, index.names, name, struct {
        fn order(n: []const u8, x: []const u8) std.math.Order {
            return std.mem.order(u8, n, x);
        }
    }.order) != null;
}

pub fn build(gpa: Allocator, root: SyntaxNode) Allocator.Error!FileIndex {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer names.deinit(gpa);
    var imports: std.ArrayList([]const u8) = .empty;
    try walk(gpa, a, root, &names, &imports);

    const sorted = try a.alloc([]const u8, names.count());
    for (names.keys(), sorted) |k, *s| s.* = try a.dupe(u8, k);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return .{ .arena = arena.state, .names = sorted, .imports = imports.items };
}

fn walk(gpa: Allocator, a: Allocator, node: SyntaxNode, names: *std.StringArrayHashMapUnmanaged(void), imports: *std.ArrayList([]const u8)) Allocator.Error!void {
    if (ast.cast(ast.BuiltinCall, node)) |call| if (call.name()) |n| if (std.mem.eql(u8, n.text, "@import")) {
        var args = call.args();
        if (args.next()) |arg| if (arg.firstToken()) |t| if (t.kind == .string_literal) {
            if (std.zig.string_literal.parseAlloc(a, t.text)) |s| try imports.append(a, s) else |_| {}
        };
    };
    var it = node.children();
    while (it.next()) |e| switch (e) {
        .token => |t| if (t.kind == .identifier) try names.put(gpa, try ast.identNameAlloc(a, t.text), {}),
        .node => |c| try walk(gpa, a, c, names, imports),
    };
}

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
        result.* = try build(gpa, parse.rootNode());
        return result;
    }

    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a.names, b.names) and deepEql(a.imports, b.imports);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        const i: *FileIndex = @constCast(v.*);
        i.deinit(gpa);
        gpa.destroy(i);
    }
};

test build {
    const Parse = @import("../syntax/Parse.zig");
    const p = try Parse.create(std.testing.allocator,
        \\const std = @import("std");
        \\const lib = @import("lib/a.zig");
        \\fn f(@"x y": u8, z: u8) void { _ = .{ @"x y", z, std.mem }; }
    );
    defer p.destroy();
    var index = try build(std.testing.allocator, p.rootNode());
    defer index.deinit(std.testing.allocator);
    try std.testing.expect(index.contains("mem"));
    try std.testing.expect(index.contains("x y"));
    try std.testing.expect(!index.contains("import"));
    try std.testing.expectEqual(2, index.imports.len);
    try std.testing.expectEqualStrings("lib/a.zig", index.imports[1]);
}
