const std = @import("std");
const testing = std.testing;
const Parse = @import("Parse.zig");

fn dumpTree(source: []const u8) ![]u8 {
    const parse = try Parse.create(testing.allocator, source);
    defer parse.destroy();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try parse.rootNode().dump(&out.writer, .{});
    for (parse.errors) |e| try out.writer.print("error@{d}: {s}\n", .{ e.offset, e.message });
    return out.toOwnedSlice();
}

fn expectTree(source: []const u8, expected: []const u8) !void {
    const actual = try dumpTree(source);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

/// 无损：根节点文本等于原文
fn expectLossless(source: []const u8) !void {
    const parse = try Parse.create(testing.allocator, source);
    defer parse.destroy();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeText(parse.rootNode(), &out.writer);
    try testing.expectEqualStrings(source, out.written());
    try testing.expectEqual(source.len, parse.root.text_len);
}

fn writeText(n: @import("tree.zig").SyntaxNode, w: *std.Io.Writer) !void {
    var it = n.children();
    while (it.next()) |e| switch (e) {
        .node => |c| try writeText(c, w),
        .token => |t| try w.writeAll(t.text),
    };
}

fn expectNoErrors(source: []const u8) !void {
    const parse = try Parse.create(testing.allocator, source);
    defer parse.destroy();
    if (parse.errors.len != 0) {
        const tree_text = try dumpTree(source);
        defer testing.allocator.free(tree_text);
        std.debug.print("{s}\n", .{tree_text});
        return error.TestUnexpectedResult;
    }
}

test "variable declarations and trivia attachment" {
    try expectTree("// c\nconst a: u32 = 1 + 2 * 3;\n",
        \\source_file@0..31
        \\  var_decl@5..30
        \\    keyword_const "const"
        \\    identifier "a"
        \\    colon ":"
        \\    name_ref@14..17
        \\      identifier "u32"
        \\    equal "="
        \\    binary_expr@20..29
        \\      literal@20..21
        \\        number_literal "1"
        \\      plus "+"
        \\      binary_expr@24..29
        \\        literal@24..25
        \\          number_literal "2"
        \\        asterisk "*"
        \\        literal@28..29
        \\          number_literal "3"
        \\    semicolon ";"
        \\
    );
}

test "function declarations, parameters and statements" {
    try expectTree(
        \\/// doc
        \\pub fn add(a: i32, comptime T: type) !T {
        \\    var x = a;
        \\    x += 1;
        \\    return x;
        \\}
    ,
        \\source_file@0..92
        \\  fn_decl@0..92
        \\    doc_comment "/// doc"
        \\    keyword_pub "pub"
        \\    fn_proto@12..47
        \\      keyword_fn "fn"
        \\      identifier "add"
        \\      param_list@18..44
        \\        l_paren "("
        \\        param@19..25
        \\          identifier "a"
        \\          colon ":"
        \\          name_ref@22..25
        \\            identifier "i32"
        \\        comma ","
        \\        param@27..43
        \\          keyword_comptime "comptime"
        \\          identifier "T"
        \\          colon ":"
        \\          name_ref@39..43
        \\            identifier "type"
        \\        r_paren ")"
        \\      bang "!"
        \\      name_ref@46..47
        \\        identifier "T"
        \\    block@48..92
        \\      l_brace "{"
        \\      var_decl@54..64
        \\        keyword_var "var"
        \\        identifier "x"
        \\        equal "="
        \\        name_ref@62..63
        \\          identifier "a"
        \\        semicolon ";"
        \\      expr_stmt@69..76
        \\        assign_expr@69..75
        \\          name_ref@69..70
        \\            identifier "x"
        \\          plus_equal "+="
        \\          literal@74..75
        \\            number_literal "1"
        \\        semicolon ";"
        \\      expr_stmt@81..90
        \\        return_expr@81..89
        \\          keyword_return "return"
        \\          name_ref@88..89
        \\            identifier "x"
        \\        semicolon ";"
        \\      r_brace "}"
        \\
    );
}

test "recovery: incomplete field access keeps structure" {
    try expectTree(
        \\fn f() void {
        \\    list.
        \\}
    ,
        \\source_file@0..25
        \\  fn_decl@0..25
        \\    fn_proto@0..11
        \\      keyword_fn "fn"
        \\      identifier "f"
        \\      param_list@4..6
        \\        l_paren "("
        \\        r_paren ")"
        \\      name_ref@7..11
        \\        identifier "void"
        \\    block@12..25
        \\      l_brace "{"
        \\      expr_stmt@18..23
        \\        field_access@18..23
        \\          name_ref@18..22
        \\            identifier "list"
        \\          period "."
        \\      r_brace "}"
        \\error@24: expected field name
        \\error@24: expected ';'
        \\
    );
}

test "recovery: garbage tokens in a statement do not affect later statements" {
    try expectTree(
        \\fn f() void {
        \\    ) ;
        \\    g();
        \\}
    ,
        \\source_file@0..32
        \\  fn_decl@0..32
        \\    fn_proto@0..11
        \\      keyword_fn "fn"
        \\      identifier "f"
        \\      param_list@4..6
        \\        l_paren "("
        \\        r_paren ")"
        \\      name_ref@7..11
        \\        identifier "void"
        \\    block@12..32
        \\      l_brace "{"
        \\      error_node@18..19
        \\        r_paren ")"
        \\      error_node@20..21
        \\        semicolon ";"
        \\      expr_stmt@26..30
        \\        call_expr@26..29
        \\          name_ref@26..27
        \\            identifier "g"
        \\          arg_list@27..29
        \\            l_paren "("
        \\            r_paren ")"
        \\        semicolon ";"
        \\      r_brace "}"
        \\error@18: expected statement
        \\error@20: expected statement
        \\
    );
}

test "lossless: malformed inputs" {
    const inputs = [_][]const u8{
        "",
        "   \n// only comment\n",
        "fn",
        "fn (",
        "const = ;",
        "}}}",
        "pub struct {",
        "fn f() void { if (a) { } else",
        "const x = .{ .a = , };",
        "/// dangling doc",
        "test { switch (x) { 1...3, => |*v| v.*, else => {} } }",
        "\xEF\xBB\xBFconst a = 1;",
        "const s = \\\\line1\n    \\\\line2\n;",
    };
    for (inputs) |input| try expectLossless(input);
}

test "valid code has no parse errors" {
    const sources = [_][]const u8{
        \\const std = @import("std");
        \\pub const Point = extern struct {
        \\    x: i32 align(4) = 0,
        \\    y: i32,
        \\
        \\    pub fn len(self: *const Point) f64 {
        \\        return @sqrt(@as(f64, @floatFromInt(self.x * self.x + self.y * self.y)));
        \\    }
        \\};
        \\const E = enum(u8) { a, b = 2, _ };
        \\const U = union(enum) { a: u32, b: void };
        \\const Err = error{ A, B };
        \\
        ,
        \\fn f(items: []const u8, ptr: [*:0]const u8, c: [*c]u8, arr: [4:0]u8) ?*align(8) u8 {
        \\    blk: {
        \\        break :blk;
        \\    }
        \\    for (items, 0..) |item, i| {
        \\        if (item == 0) continue else _ = i;
        \\    }
        \\    var it = items;
        \\    while (it.len > 0) : (it = it[1..]) {}
        \\    const x = switch (items[0]) {
        \\        0...9 => 1,
        \\        'a', 'b' => |v| v,
        \\        else => unreachable,
        \\    };
        \\    const a, var b = .{ x, 2 };
        \\    b = a;
        \\    _ = ptr[0..1 :0];
        \\    _ = c.?;
        \\    defer {}
        \\    errdefer if (true) {};
        \\    return if (arr.len == 4) null else null;
        \\}
        \\test "t" {
        \\    comptime var i = 0;
        \\    inline for (.{ 1, 2 }) |v| i += v;
        \\    const r = foo() catch |err| return err;
        \\    const o = maybe orelse 0;
        \\    _ = .{ r, o, .enum_lit };
        \\    asm volatile ("nop" : [ret] "={x}" (-> u32) : [a] "r" (1) : .{ .memory = true });
        \\}
        \\
        ,
    };
    for (sources) |s| {
        try expectNoErrors(s);
        try expectLossless(s);
    }
}
