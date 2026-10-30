const std = @import("std");
const testing = std.testing;
const Parse = @import("Parse.zig");
const tree = @import("tree.zig");

fn dumpTree(source: []const u8) ![]u8 {
    return dumpTreeIn(.zig, source);
}

fn dumpTreeIn(mode: Parse.Mode, source: []const u8) ![]u8 {
    const parse = try Parse.create(testing.allocator, source, mode);
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

fn expectZonTree(source: []const u8, expected: []const u8) !void {
    const actual = try dumpTreeIn(.zon, source);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

/// Lossless: the root node's text equals the source
fn expectLossless(source: []const u8) !void {
    return expectLosslessIn(.zig, source);
}

fn expectLosslessIn(mode: Parse.Mode, source: []const u8) !void {
    const parse = try Parse.create(testing.allocator, source, mode);
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
    const parse = try Parse.create(testing.allocator, source, .zig);
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

test "recovery: an element being typed above a line starting with `.name` ends there" {
    // `.b = 2` stays a field initializer beside a nameless literal element (parsed as one
    // expression)
    try expectZonTree(".{ .a = 1, .\n .b = 2 }",
        \\source_file@0..22
        \\  init_expr@0..22
        \\    period "."
        \\    init_list@1..22
        \\      l_brace "{"
        \\      field_init@3..9
        \\        period "."
        \\        identifier "a"
        \\        equal "="
        \\        literal@8..9
        \\          number_literal "1"
        \\      comma ","
        \\      enum_literal@11..12
        \\        period "."
        \\      field_init@14..20
        \\        period "."
        \\        identifier "b"
        \\        equal "="
        \\        literal@19..20
        \\          number_literal "2"
        \\      r_brace "}"
        \\error@14: expected identifier
        \\error@14: expected ','
        \\
    );
    // `.c` stays the case item of the first prong, `.blue => {}` is a prong of its own
    try expectZonTree("switch (x) {\n .c\n .blue => {},\n}",
        \\source_file@0..32
        \\  switch_expr@0..32
        \\    keyword_switch "switch"
        \\    l_paren "("
        \\    name_ref@8..9
        \\      identifier "x"
        \\    r_paren ")"
        \\    l_brace "{"
        \\    switch_prong@14..16
        \\      switch_case@14..16
        \\        enum_literal@14..16
        \\          period "."
        \\          identifier "c"
        \\    switch_prong@18..29
        \\      switch_case@18..23
        \\        enum_literal@18..23
        \\          period "."
        \\          identifier "blue"
        \\      equal_angle_bracket_right "=>"
        \\      block@27..29
        \\        l_brace "{"
        \\        r_brace "}"
        \\    comma ","
        \\    r_brace "}"
        \\error@18: expected '=>'
        \\error@18: expected ',' after switch prong
        \\
    );
}

test "recovery: unwinding deep unclosed nesting and long else-if chains" {
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    // At the error, unclosed nesting unwinds level by level, each level peeking at tokens without
    // consuming them (panics if the peek limit is too small)
    for ([_][]const u8{ "f(", ".{", "a[", "(" }) |open| {
        src.clearRetainingCapacity();
        try src.appendSlice(a, "const x = ");
        for (0..1000) |_| try src.appendSlice(a, open);
        try src.appendSlice(a, "\nconst y = 1;\n");
        try expectLossless(src.items);
    }
    // Valid code: an expression-form else-if chain unwinds level by level at the end
    src.clearRetainingCapacity();
    try src.appendSlice(a, "fn f(x: u32) u32 {\n    return ");
    for (0..1000) |i| try src.print(a, "if (x == {d}) {d} else ", .{ i, i });
    try src.appendSlice(a, "0;\n}\n");
    try expectNoErrors(src.items);
    try expectLossless(src.items);
}

/// Depth of the syntax tree (computed iteratively)
fn treeDepth(n: @import("tree.zig").SyntaxNode) !usize {
    const Entry = struct { node: @import("tree.zig").SyntaxNode, depth: usize };
    var stack: std.ArrayList(Entry) = .empty;
    defer stack.deinit(testing.allocator);
    try stack.append(testing.allocator, .{ .node = n, .depth = 1 });
    var max: usize = 0;
    while (stack.pop()) |e| {
        max = @max(max, e.depth);
        var it = e.node.children();
        while (it.nextNode()) |c| try stack.append(testing.allocator, .{ .node = c, .depth = e.depth + 1 });
    }
    return max;
}

test "deep nesting keeps the full structure" {
    const a = testing.allocator;
    const Case = struct { head: []const u8, repeat: []const u8, middle: []const u8, close: []const u8, tail: []const u8 };
    const cases = [_]Case{
        .{ .head = "const x = ", .repeat = "(", .middle = "1", .close = ")", .tail = ";\n" },
        .{ .head = "const x = ", .repeat = "!", .middle = "y", .close = "", .tail = ";\n" },
        .{ .head = "const T = ", .repeat = "?", .middle = "u8", .close = "", .tail = ";\n" },
        .{ .head = "fn f() void ", .repeat = "{", .middle = "", .close = "}", .tail = "\n" },
        .{ .head = "fn f(x: u32) void {\n    if (x == 0) {}", .repeat = " else if (x == 1) {}", .middle = " else {}", .close = "", .tail = "\n}\n" },
        .{ .head = "const x = ", .repeat = "1 + ", .middle = "1", .close = "", .tail = ";\n" },
        .{ .head = "const x = a", .repeat = ".b", .middle = "", .close = "", .tail = ";\n" },
        .{ .head = "const x = ", .repeat = "f(", .middle = "x", .close = ")", .tail = ";\n" },
    };
    const n = 1500;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    for (cases) |c| {
        src.clearRetainingCapacity();
        try src.appendSlice(a, c.head);
        for (0..n) |_| try src.appendSlice(a, c.repeat);
        try src.appendSlice(a, c.middle);
        for (0..n) |_| try src.appendSlice(a, c.close);
        try src.appendSlice(a, c.tail);
        const parse = try Parse.create(a, src.items, .zig);
        defer parse.destroy();
        try testing.expectEqual(0, parse.errors.len);
        try testing.expect(try treeDepth(parse.rootNode()) > n);
        try expectLossless(src.items);
    }
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

test "unclosed escaped identifiers retain syntax roles and invalid token diagnostics" {
    const Kind = @import("kind.zig").SyntaxKind;
    const cases = [_]struct { source: []const u8, parent: Kind }{
        .{ .source = "const value = @\"EdgeWidg", .parent = .name_ref },
        .{ .source = "fn main() void { _ = @\"EdgeWidg\n}", .parent = .name_ref },
        .{ .source = "const @\"EdgeWidg", .parent = .var_decl },
        .{ .source = "fn @\"EdgeWidg", .parent = .fn_proto },
        .{ .source = "const value = object.@\"EdgeWidg", .parent = .field_access },
        .{ .source = "const value = .@\"EdgeWidg", .parent = .enum_literal },
        .{ .source = "const value = error.@\"EdgeWidg", .parent = .error_value },
        .{ .source = "fn main() void { break :@\"EdgeWidg", .parent = .break_label },
        .{ .source = "fn main() void { for (items) |@\"EdgeWidg", .parent = .payload },
    };
    const Parent = struct {
        fn at(node: tree.SyntaxNode, offset: u32) Kind {
            var children = node.children();
            while (children.next()) |child| {
                if (!child.range().contains(offset)) continue;
                return switch (child) {
                    .node => |inner| at(inner, offset),
                    .token => node.kind(),
                };
            }
            return node.kind();
        }
    };
    for (cases) |case| {
        const parse = try Parse.create(testing.allocator, case.source, .zig);
        defer parse.destroy();
        const offset: u32 = @intCast(std.mem.indexOf(u8, case.source, "@\"").?);
        const root = parse.rootNode();
        const token = root.tokenAtOffset(offset).?;
        try testing.expectEqual(.invalid, token.kind);
        try testing.expectEqual(case.parent, Parent.at(root, offset));
        try testing.expectEqual(offset, parse.errors[0].offset);
        try expectLossless(case.source);
    }
}

test "zon file is a single expression" {
    try expectZonTree(".{\n    .name = .demo,\n    .paths = .{\"src\"},\n}\n",
        \\source_file@0..47
        \\  init_expr@0..46
        \\    period "."
        \\    init_list@1..46
        \\      l_brace "{"
        \\      field_init@7..20
        \\        period "."
        \\        identifier "name"
        \\        equal "="
        \\        enum_literal@15..20
        \\          period "."
        \\          identifier "demo"
        \\      comma ","
        \\      field_init@26..43
        \\        period "."
        \\        identifier "paths"
        \\        equal "="
        \\        init_expr@35..43
        \\          period "."
        \\          init_list@36..43
        \\            l_brace "{"
        \\            literal@37..42
        \\              string_literal "\"src\""
        \\            r_brace "}"
        \\      comma ","
        \\      r_brace "}"
        \\
    );
}

test "zon tokens around the expression are errors" {
    try expectZonTree("//! doc\n.{}\n.{}",
        \\source_file@0..15
        \\  error_node@0..7
        \\    container_doc_comment "//! doc"
        \\  init_expr@8..11
        \\    period "."
        \\    init_list@9..11
        \\      l_brace "{"
        \\      r_brace "}"
        \\  error_node@12..15
        \\    period "."
        \\    l_brace "{"
        \\    r_brace "}"
        \\error@0: expected expression
        \\error@12: expected end of file
        \\
    );
    try expectZonTree("",
        \\source_file@0..0
        \\error@0: expected expression
        \\
    );
    try expectZonTree("// c\n",
        \\source_file@0..5
        \\error@5: expected expression
        \\
    );
}

test "zon files are lossless" {
    const cases = [_][]const u8{
        ".{ .a = inf, .b = -inf, .c = nan }",
        ".{ .a = 1, . }",
        "/// doc\n/// doc\n.{ .x = 1 } }\n;",
        ".{\n    .s = \\\\multi\n    ,\n}",
        "}",
    };
    for (cases) |source| try expectLosslessIn(.zon, source);
}
