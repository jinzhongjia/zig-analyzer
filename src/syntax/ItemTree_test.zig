const std = @import("std");
const testing = std.testing;
const Parse = @import("Parse.zig");
const ItemTree = @import("ItemTree.zig");

fn buildTree(source: []const u8) !struct { parse: *Parse, items: ItemTree } {
    const parse = try Parse.create(testing.allocator, source);
    errdefer parse.destroy();
    return .{ .parse = parse, .items = try ItemTree.build(testing.allocator, parse.rootNode()) };
}

/// 以文本形式描述 ItemTree，便于断言
fn describe(t: *const ItemTree, w: *std.Io.Writer, container: u32, depth: usize) !void {
    for (t.containerMembers(container)) |i| {
        const item = t.items[i];
        try w.splatByteAll(' ', depth * 2);
        try w.print("{t} {s}", .{ item.kind, item.name orelse "_" });
        if (item.flags.is_pub) try w.writeAll(" pub");
        if (item.doc) |d| try w.print(" doc=\"{s}\"", .{d});
        try w.writeAll("\n");
        for (t.containers, 0..) |c, ci| {
            if (c.parent_item == i) {
                try w.splatByteAll(' ', depth * 2 + 2);
                try w.print("<{t}>\n", .{c.kind});
                try describe(t, w, @intCast(ci), depth + 2);
            }
        }
    }
}

fn expectItems(source: []const u8, expected: []const u8) !void {
    var r = try buildTree(source);
    defer r.parse.destroy();
    defer r.items.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try describe(&r.items, &out.writer, 0, 0);
    try testing.expectEqualStrings(expected, out.written());
}

test "collects top-level and nested container members" {
    try expectItems(
        \\/// 点
        \\pub const Point = struct {
        \\    x: i32,
        \\    y: i32 = 0,
        \\    pub fn len(self: Point) f64 { return 0; }
        \\};
        \\fn List(comptime T: type) type {
        \\    return struct { items: []T };
        \\}
        \\test "a" {}
        \\comptime {}
        \\const Tuple = struct { u32, u8 };
    ,
        \\const Point pub doc="点"
        \\  <struct>
        \\    field x
        \\    field y
        \\    fn len pub
        \\fn List
        \\  <struct>
        \\    field items
        \\test "a"
        \\comptime _
        \\const Tuple
        \\  <struct>
        \\    field _
        \\    field _
        \\
    );
}

fn treesEqual(a: []const u8, b: []const u8) !bool {
    var x = try buildTree(a);
    defer x.parse.destroy();
    defer x.items.deinit(testing.allocator);
    var y = try buildTree(b);
    defer y.parse.destroy();
    defer y.items.deinit(testing.allocator);
    return x.items.eql(&y.items);
}

test "ItemTree unchanged by body, comment or whitespace edits" {
    const base =
        \\const S = struct { a: u32 };
        \\fn f(x: u32) u32 { return x + 1; }
    ;
    try testing.expect(try treesEqual(base,
        \\// 新增注释
        \\const S = struct { a: u32 };
        \\
        \\fn f(x: u32) u32 {
        \\    const y = x * 2;
        \\    return y;
        \\}
    ));
}

test "ItemTree changes when signatures, fields or members change" {
    const base = "const S = struct { a: u32 };\nfn f(x: u32) u32 { return x; }";
    try testing.expect(!try treesEqual(base, "const S = struct { a: u64 };\nfn f(x: u32) u32 { return x; }"));
    try testing.expect(!try treesEqual(base, "const S = struct { a: u32, b: u8 };\nfn f(x: u32) u32 { return x; }"));
    try testing.expect(!try treesEqual(base, "const S = struct { a: u32 };\nfn f(x: u64) u32 { return x; }"));
    try testing.expect(!try treesEqual(base, "const S = struct { a: u32 };\npub fn f(x: u32) u32 { return x; }"));
    try testing.expect(!try treesEqual(base, "const S = union { a: u32 };\nfn f(x: u32) u32 { return x; }"));
}

test "AstId stable across edits, AstIdMap finds the node" {
    var a = try buildTree("const A = 1;\nfn f() void {}\n");
    defer a.parse.destroy();
    defer a.items.deinit(testing.allocator);
    var b = try buildTree("// 前面插入注释与声明\nconst Z = 0;\nconst A = 1;\nfn f() void { _ = 1; }\n");
    defer b.parse.destroy();
    defer b.items.deinit(testing.allocator);

    const f_a = a.items.items[1];
    const f_b = b.items.items[2];
    try testing.expectEqualStrings("f", f_b.name.?);
    try testing.expectEqual(f_a.ast_id, f_b.ast_id);

    var map = try ItemTree.AstIdMap.build(testing.allocator, &b.items, b.parse.rootNode());
    defer map.deinit(testing.allocator);
    const node = map.get(f_b.ast_id).?;
    try testing.expectEqual(.fn_decl, node.kind());
    try testing.expect(std.mem.startsWith(u8, node.text(b.parse.source), "fn f()"));
}

test "same-name members are distinguished by index" {
    var r = try buildTree("test {}\ntest {}\ncomptime {}\ncomptime {}");
    defer r.parse.destroy();
    defer r.items.deinit(testing.allocator);
    try testing.expect(r.items.items[0].ast_id != r.items.items[1].ast_id);
    try testing.expect(r.items.items[2].ast_id != r.items.items[3].ast_id);
}
