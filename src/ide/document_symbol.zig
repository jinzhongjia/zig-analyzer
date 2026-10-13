//! textDocument/documentSymbol：基于 ItemTree 生成文档大纲。

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const offsets = @import("../util/offsets.zig");
const ItemTree = @import("../syntax/ItemTree.zig");
const SyntaxNode = @import("../syntax/tree.zig").SyntaxNode;
const ast = @import("../syntax/ast.zig");

pub fn documentSymbols(
    arena: Allocator,
    items: *const ItemTree,
    map: *const ItemTree.AstIdMap,
    lines: offsets.LineIndex,
    enc: offsets.Encoding,
) Allocator.Error![]const types.DocumentSymbol {
    var b: Builder = .{ .arena = arena, .items = items, .map = map, .lines = lines, .enc = enc };
    return b.container(0);
}

const Builder = struct {
    arena: Allocator,
    items: *const ItemTree,
    map: *const ItemTree.AstIdMap,
    lines: offsets.LineIndex,
    enc: offsets.Encoding,

    fn container(b: *Builder, index: u32) Allocator.Error![]const types.DocumentSymbol {
        const kind = b.items.containers[index].kind;
        var out: std.ArrayList(types.DocumentSymbol) = .empty;
        for (b.items.containerMembers(index)) |i| {
            const item = b.items.items[i];
            if (item.kind == .@"comptime") continue;
            const node = b.map.get(item.ast_id) orelse continue;
            const name_tok = ast.memberName(node, kind == .@"enum");
            const children = try b.childrenOf(i);
            const r = node.range();
            const sel = if (name_tok) |t| t.range() else r;
            try out.append(b.arena, .{
                .name = displayName(item),
                .kind = symbolKind(b.items, i, kind),
                .range = b.lines.range(r.start, r.end, b.enc),
                .selectionRange = b.lines.range(sel.start, sel.end, b.enc),
                .children = if (children.len == 0) null else children,
            });
        }
        return out.items;
    }

    /// 成员内部定义的容器（如 `const S = struct {...}` 的字段）作为该成员的子符号
    fn childrenOf(b: *Builder, item: u32) Allocator.Error![]const types.DocumentSymbol {
        var out: std.ArrayList(types.DocumentSymbol) = .empty;
        for (b.items.containers, 0..) |c, ci| {
            if (c.parent_item == item) try out.appendSlice(b.arena, try b.container(@intCast(ci)));
        }
        return out.items;
    }
};

fn displayName(item: ItemTree.Item) []const u8 {
    const name = item.name orelse return "test";
    if (item.kind == .@"test" and name.len >= 2 and name[0] == '"') return name[1 .. name.len - 1];
    return name;
}

fn symbolKind(items: *const ItemTree, index: u32, container_kind: ItemTree.Container.Kind) types.SymbolKind {
    const item = items.items[index];
    return switch (item.kind) {
        .@"fn" => if (container_kind == .file) .Function else .Method,
        .@"var" => .Variable,
        .@"const" => for (items.containers) |c| {
            if (c.parent_item == index) break switch (c.kind) {
                .@"enum" => .Enum,
                .@"union", .@"struct" => .Struct,
                .@"opaque", .file => .Object,
            };
        } else .Constant,
        .field => if (container_kind == .@"enum") .EnumMember else .Field,
        .@"test" => .Method,
        .@"comptime" => .Namespace,
    };
}

const testing = std.testing;
const Parse = @import("../syntax/Parse.zig");

test documentSymbols {
    const text =
        \\const S = struct {
        \\    a: u32,
        \\    pub fn f() void {}
        \\};
        \\const E = enum { x };
        \\test "t" {}
    ;
    const parse = try Parse.create(testing.allocator, text);
    defer parse.destroy();
    var items = try ItemTree.build(testing.allocator, parse.rootNode());
    defer items.deinit(testing.allocator);
    var map = try ItemTree.AstIdMap.build(testing.allocator, &items, parse.rootNode());
    defer map.deinit(testing.allocator);
    var lines = try offsets.LineIndex.init(testing.allocator, text);
    defer lines.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const syms = try documentSymbols(arena.allocator(), &items, &map, lines, .utf16);
    try testing.expectEqual(3, syms.len);
    try testing.expectEqualStrings("S", syms[0].name);
    try testing.expectEqual(types.SymbolKind.Struct, syms[0].kind);
    try testing.expectEqual(2, syms[0].children.?.len);
    try testing.expectEqual(types.SymbolKind.Field, syms[0].children.?[0].kind);
    try testing.expectEqual(types.SymbolKind.Method, syms[0].children.?[1].kind);
    try testing.expectEqual(types.SymbolKind.Enum, syms[1].kind);
    try testing.expectEqual(types.SymbolKind.EnumMember, syms[1].children.?[0].kind);
    try testing.expectEqualStrings("x", syms[1].children.?[0].name);
    try testing.expectEqualStrings("t", syms[2].name);
    // selectionRange 指向名字
    try testing.expectEqual(types.Position{ .line = 0, .character = 6 }, syms[0].selectionRange.start);
    try testing.expectEqual(types.Position{ .line = 3, .character = 2 }, syms[0].range.end);
}
