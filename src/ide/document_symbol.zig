//! textDocument/documentSymbol: builds the document outline from the ItemTree; for a ZON file,
//! lists the field tree of the root expression.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const offsets = @import("../util/offsets.zig");
const ItemTree = @import("../syntax/ItemTree.zig");
const SyntaxNode = @import("../syntax/tree.zig").SyntaxNode;
const ast = @import("../syntax/ast.zig");

/// Maximum nesting depth of symbols; deeper containers are not listed. Each symbol level nests
/// two levels in JSON (the symbol and `children`), and `std.json.Stringify` panics when nesting
/// exceeds 256 levels in builds with safety checks
pub const max_levels = 100;

pub fn documentSymbols(
    arena: Allocator,
    items: *const ItemTree,
    map: *const ItemTree.AstIdMap,
    lines: offsets.LineIndex,
    enc: offsets.Encoding,
) Allocator.Error![]const types.DocumentSymbol {
    var b: Builder = .{ .arena = arena, .items = items, .map = map, .lines = lines, .enc = enc };
    return b.container(0, 1);
}

const Builder = struct {
    arena: Allocator,
    items: *const ItemTree,
    map: *const ItemTree.AstIdMap,
    lines: offsets.LineIndex,
    enc: offsets.Encoding,

    /// `level` is the level of the members (1 for the top level)
    fn container(b: *Builder, index: u32, level: u32) Allocator.Error![]const types.DocumentSymbol {
        const kind = b.items.containers[index].kind;
        var out: std.ArrayList(types.DocumentSymbol) = .empty;
        var fields: u32 = 0;
        for (b.items.containerMembers(index)) |i| {
            const item = b.items.items[i];
            if (item.kind == .@"comptime" or item.kind == .zon) continue;
            const field_index = fields;
            if (item.kind == .field) fields += 1;
            const node = b.map.get(item.ast_id) orelse continue;
            const name_tok = ast.memberName(node, ItemTree.bareFieldNames(kind));
            const children = if (level < max_levels) try b.childrenOf(i, level + 1) else &.{};
            const r = node.range();
            const sel = if (name_tok) |t| t.range() else r;
            try out.append(b.arena, .{
                .name = try displayName(b.arena, item, field_index),
                .kind = symbolKind(b.items, i, kind),
                .range = b.lines.range(r.start, r.end, b.enc),
                .selectionRange = b.lines.range(sel.start, sel.end, b.enc),
                .children = if (children.len == 0) null else children,
            });
        }
        return out.items;
    }

    /// Containers defined inside a member (such as the fields of `const S = struct {...}`) become
    /// child symbols of that member
    fn childrenOf(b: *Builder, item: u32, level: u32) Allocator.Error![]const types.DocumentSymbol {
        var out: std.ArrayList(types.DocumentSymbol) = .empty;
        for (b.items.containers, 0..) |c, ci| {
            if (c.parent_item == item) try out.appendSlice(b.arena, try b.container(@intCast(ci), level));
        }
        return out.items;
    }
};

/// The outline of a ZON file: the field tree of the initializer lists in the root expression. Named
/// fields are listed by name and tuple elements by index (the same as the name in `t.@"0"`); the
/// fields of a value that is an initializer list are child symbols
pub fn zonSymbols(arena: Allocator, root: SyntaxNode, lines: offsets.LineIndex, enc: offsets.Encoding) Allocator.Error![]const types.DocumentSymbol {
    const value = ItemTree.zonRoot(root) orelse return &.{};
    return zonFields(arena, value, lines, enc, 1);
}

/// The fields of `value` when it is an initializer list (at level `level`)
fn zonFields(arena: Allocator, value: SyntaxNode, lines: offsets.LineIndex, enc: offsets.Encoding, level: u32) Allocator.Error![]const types.DocumentSymbol {
    if (value.kind() != .init_expr) return &.{};
    var out: std.ArrayList(types.DocumentSymbol) = .empty;
    var index: u32 = 0;
    var it = (ast.InitExpr{ .syntax = value }).items();
    while (it.next()) |n| {
        if (n.kind() == .error_node) continue;
        var name: []const u8 = undefined;
        var sel = n.range();
        var field_value: ?SyntaxNode = n;
        if (n.kind() == .field_init) {
            const field: ast.FieldInit = .{ .syntax = n };
            const tok = field.name() orelse continue;
            name = try ast.identNameAlloc(arena, tok.text);
            sel = tok.range();
            field_value = field.value();
        } else {
            name = try std.fmt.allocPrint(arena, "{d}", .{index});
            index += 1;
        }
        const children = if (level < max_levels) if (field_value) |v| try zonFields(arena, v, lines, enc, level + 1) else &.{} else &.{};
        const r = n.range();
        try out.append(arena, .{
            .name = name,
            .kind = .Field,
            .range = lines.range(r.start, r.end, enc),
            .selectionRange = lines.range(sel.start, sel.end, enc),
            .children = if (children.len == 0) null else children,
        });
    }
    return out.items;
}

/// Members without a name: a tuple field is shown as its index (`field_index` is its position
/// among the container's fields, the same as the name in `t.@"0"`); the others are unnamed
/// `test {}`
fn displayName(arena: Allocator, item: ItemTree.Item, field_index: u32) Allocator.Error![]const u8 {
    const name = item.name orelse return if (item.kind == .field) std.fmt.allocPrint(arena, "{d}", .{field_index}) else "test";
    if (item.kind == .@"test" and name.len >= 2 and name[0] == '"') return name[1 .. name.len - 1];
    return name;
}

pub fn symbolKind(items: *const ItemTree, index: u32, container_kind: ItemTree.Container.Kind) types.SymbolKind {
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
        .zon => .Object,
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
    const parse = try Parse.create(testing.allocator, text, .zig);
    defer parse.destroy();
    var items = try ItemTree.build(testing.allocator, parse.rootNode(), .zig);
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
    // selectionRange points at the name
    try testing.expectEqual(types.Position{ .line = 0, .character = 6 }, syms[0].selectionRange.start);
    try testing.expectEqual(types.Position{ .line = 3, .character = 2 }, syms[0].range.end);
}

test "document symbols stop at the nesting limit" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "const S = struct {\n");
    for (0..150) |_| try text.appendSlice(testing.allocator, "a: struct {\n");
    for (0..150) |_| try text.appendSlice(testing.allocator, "},\n");
    try text.appendSlice(testing.allocator, "};\n");
    const parse = try Parse.create(testing.allocator, text.items, .zig);
    defer parse.destroy();
    var items = try ItemTree.build(testing.allocator, parse.rootNode(), .zig);
    defer items.deinit(testing.allocator);
    var map = try ItemTree.AstIdMap.build(testing.allocator, &items, parse.rootNode());
    defer map.deinit(testing.allocator);
    var lines = try offsets.LineIndex.init(testing.allocator, text.items);
    defer lines.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var syms = try documentSymbols(arena.allocator(), &items, &map, lines, .utf16);
    var levels: usize = 0;
    while (syms.len > 0) : (syms = syms[0].children orelse &.{}) levels += 1;
    try testing.expectEqual(max_levels, levels);
}

test "tuple fields are named by their index" {
    const text =
        \\const T = struct { u32, u8 };
        \\const P = struct { x: u32, y: u32 };
        \\test {}
    ;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parse = try Parse.create(a, text, .zig);
    var items = try ItemTree.build(a, parse.rootNode(), .zig);
    var map = try ItemTree.AstIdMap.build(a, &items, parse.rootNode());
    const lines = try offsets.LineIndex.init(a, text);

    const syms = try documentSymbols(a, &items, &map, lines, .utf16);
    try testing.expectEqual(3, syms.len);
    const tuple = syms[0].children.?;
    try testing.expectEqualStrings("0", tuple[0].name);
    try testing.expectEqualStrings("1", tuple[1].name);
    try testing.expectEqual(types.SymbolKind.Field, tuple[1].kind);
    try testing.expectEqualStrings("y", syms[1].children.?[1].name);
    // An unnamed test is still shown as `test`
    try testing.expectEqualStrings("test", syms[2].name);
}

fn writeOutline(w: *std.Io.Writer, syms: []const types.DocumentSymbol, depth: usize) !void {
    for (syms) |s| {
        try w.splatByteAll(' ', depth * 2);
        try w.print("{s}\n", .{s.name});
        try writeOutline(w, s.children orelse &.{}, depth + 1);
    }
}

test "zon files list the field tree" {
    const text =
        \\.{
        \\    .name = .demo,
        \\    .@"min-version" = "0.1.0",
        \\    .dependencies = .{
        \\        .foo = .{
        \\            .url = "https://example.com/foo.tar.gz",
        \\            .hash = "...",
        \\        },
        \\    },
        \\    .paths = .{ "build.zig", .{ .x = 1 } },
        \\}
    ;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parse = try Parse.create(a, text, .zon);
    const lines = try offsets.LineIndex.init(a, text);

    const syms = try zonSymbols(a, parse.rootNode(), lines, .utf16);
    var out: std.Io.Writer.Allocating = .init(a);
    try writeOutline(&out.writer, syms, 0);
    try testing.expectEqualStrings(
        \\name
        \\min-version
        \\dependencies
        \\  foo
        \\    url
        \\    hash
        \\paths
        \\  0
        \\  1
        \\    x
        \\
    , out.written());
    try testing.expectEqual(types.SymbolKind.Field, syms[0].kind);
    // The selectionRange of a field is its name and its range includes the value; both are the
    // element itself for a tuple element
    try testing.expectEqual(types.Position{ .line = 1, .character = 5 }, syms[0].selectionRange.start);
    try testing.expectEqual(types.Position{ .line = 1, .character = 17 }, syms[0].range.end);
    const elem = syms[3].children.?[0];
    try testing.expectEqual(types.Position{ .line = 9, .character = 16 }, elem.selectionRange.start);
    try testing.expectEqual(types.Position{ .line = 9, .character = 27 }, elem.range.end);

    // No symbols when the root is not an initializer list
    const scalar = try Parse.create(a, "1", .zon);
    try testing.expectEqual(0, (try zonSymbols(a, scalar.rootNode(), try offsets.LineIndex.init(a, "1"), .utf16)).len);
}

test "zon document symbols stop at the nesting limit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    for (0..150) |_| try text.appendSlice(a, ".{ .a = ");
    try text.appendSlice(a, "1");
    for (0..150) |_| try text.appendSlice(a, " }");
    const parse = try Parse.create(a, text.items, .zon);
    var syms = try zonSymbols(a, parse.rootNode(), try offsets.LineIndex.init(a, text.items), .utf16);
    var levels: usize = 0;
    while (syms.len > 0) : (syms = syms[0].children orelse &.{}) levels += 1;
    try testing.expectEqual(max_levels, levels);
}
