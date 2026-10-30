const std = @import("std");
const testing = std.testing;
const Parse = @import("Parse.zig");
const ItemTree = @import("ItemTree.zig");

const Built = struct { parse: *Parse, items: ItemTree };

fn buildTree(source: []const u8) !Built {
    return buildTreeIn(.zig, source);
}

fn buildTreeIn(mode: Parse.Mode, source: []const u8) !Built {
    const parse = try Parse.create(testing.allocator, source, mode);
    errdefer parse.destroy();
    return .{ .parse = parse, .items = try ItemTree.build(testing.allocator, parse.rootNode(), mode) };
}

/// Describes an ItemTree as text for assertions
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
    return expectItemsIn(.zig, source, expected);
}

fn expectItemsIn(mode: Parse.Mode, source: []const u8, expected: []const u8) !void {
    var r = try buildTreeIn(mode, source);
    defer r.parse.destroy();
    defer r.items.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try describe(&r.items, &out.writer, 0, 0);
    try testing.expectEqualStrings(expected, out.written());
}

test "collects top-level and nested container members" {
    try expectItems(
        \\/// A point
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
        \\const Point pub doc="A point"
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
    return treesEqualIn(.zig, a, b);
}

fn treesEqualIn(mode: Parse.Mode, a: []const u8, b: []const u8) !bool {
    var x = try buildTreeIn(mode, a);
    defer x.parse.destroy();
    defer x.items.deinit(testing.allocator);
    var y = try buildTreeIn(mode, b);
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
        \\// A new comment
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
    var b = try buildTree("// A comment and a declaration inserted in front\nconst Z = 0;\nconst A = 1;\nfn f() void { _ = 1; }\n");
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

test "zon root expression is the only item" {
    try expectItemsIn(.zon,
        \\.{ .a = 1, .b = .{ .c = struct { x: u8 } } }
    ,
        \\zon _
        \\  <struct>
        \\    field x
        \\
    );
    // Tokens outside the root expression belong to error nodes, not members
    try expectItemsIn(.zon, "1 2", "zon _\n");
    try expectItemsIn(.zon, "// only a comment\n", "");
}

test "zon AstIdMap maps the root item to the root expression" {
    var r = try buildTreeIn(.zon, "// c\n.{ .s = struct { x: u8 } }\n");
    defer r.parse.destroy();
    defer r.items.deinit(testing.allocator);
    var map = try ItemTree.AstIdMap.build(testing.allocator, &r.items, r.parse.rootNode());
    defer map.deinit(testing.allocator);
    try testing.expectEqual(.init_expr, map.get(r.items.items[0].ast_id).?.kind());
    try testing.expectEqual(.container_decl, map.get(r.items.containers[1].ast_id).?.kind());
    try testing.expectEqual(.container_field, map.get(r.items.items[1].ast_id).?.kind());
}

test "zon ItemTree unchanged by value edits" {
    try testing.expect(try treesEqualIn(.zon, ".{ .a = 1 }", ".{ .a = 2, .b = .{ \"x\" } }"));
    try testing.expect(try treesEqualIn(.zon, ".{ .a = 1 }", "1"));
}

test "an unclosed list does not take the declarations after it" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "const std = @import(\nconst mem = std.mem;\n", "const std\nconst mem\n" },
        .{ "const std = @import(\"std\"\nconst mem = std.mem;\n", "const std\nconst mem\n" },
        .{ "const a = f(1,\nvar b = 2;\n", "const a\nvar b\n" },
        .{ "const a = .{ .x = 1,\npub const b = 2;\n", "const a\nconst b pub\n" },
        .{ "const a = [_]u8{ 1,\nexport const b = 2;\n", "const a\nconst b\n" },
        .{ "const E = error{ A,\ntest {}\n", "const E\ntest _\n" },
        .{ "fn f(a: u32,\nthreadlocal var b: u32 = 0;\n", "fn f\nvar b\n" },
        .{ "extern fn f(a: u32,\nextern fn g() void;\n", "fn f\nfn g\n" },
        .{ "const aaa = @import(\"aaa.zig\"\nfn helper(n: u32) u32 {\n    return n;\n}\n", "const aaa\nfn helper\n" },
        .{ "const aaa = @import(\"aaa.zig\"\npub fn helper(n: u32) u32 {\n    return n;\n}\n", "const aaa\nfn helper pub\n" },
    };
    for (cases) |c| expectItems(c[0], c[1]) catch |err| {
        std.debug.print("source: `{s}`\n", .{c[0]});
        return err;
    };
}
