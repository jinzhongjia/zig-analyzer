const std = @import("std");
const testing = std.testing;
const resolve = @import("../names/resolve.zig");
const World = @import("../names/resolve_test.zig").World;
const code_actions = @import("code_actions.zig");

/// 在 `<|>` 处（或 `«...»` 选区上）取标题为 `title` 的修复，返回应用后的文本
fn apply(text: []const u8, title_prefix: []const u8) ![]const u8 {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    // 选区：去掉 `«` `»` 标记
    var start: ?u32 = null;
    var end: u32 = 0;
    const plain = blk: {
        const open = std.mem.indexOf(u8, text, "«") orelse break :blk text;
        const close = std.mem.indexOf(u8, text, "»").?;
        start = @intCast(open);
        end = @intCast(close - "«".len);
        break :blk try std.mem.concat(w.arena.allocator(), u8, &.{ text[0..open], text[open + "«".len .. close], text[close + "»".len ..] });
    };
    const added = try w.add("/p/main.zig", plain);
    var ctx = w.db.beginRead(w.arena.allocator());
    defer ctx.end();
    var r: resolve.Resolver = .{ .ctx = &ctx, .arena = w.arena.allocator() };
    const clean = (try ctx.get(@import("../database.zig").syntax.SourceText, added.file)).text;
    const actions = try code_actions.codeActions(&r, added.file, start orelse added.cursor, if (start != null) end else added.cursor);
    for (actions) |a| {
        if (!std.mem.startsWith(u8, a.title, title_prefix)) continue;
        var out: std.ArrayList(u8) = .empty;
        var pos: u32 = 0;
        for (a.edits) |e| {
            try out.appendSlice(testing.allocator, clean[pos..e.start]);
            try out.appendSlice(testing.allocator, e.text);
            pos = e.end;
        }
        try out.appendSlice(testing.allocator, clean[pos..]);
        return out.toOwnedSlice(testing.allocator);
    }
    return testing.allocator.dupe(u8, "no action");
}

fn expectAction(text: []const u8, title: []const u8, expected: []const u8) !void {
    const got = try apply(text, title);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "discard unused locals, parameters and captures" {
    try expectAction(
        \\fn f(<|>a: u32) void {
        \\    return;
        \\}
    , "discard `a`",
        \\fn f(a: u32) void {
        \\    _ = a;
        \\    return;
        \\}
    );
    try expectAction(
        \\fn f() void {
        \\    const <|>x = 1;
        \\}
    , "discard `x`",
        \\fn f() void {
        \\    const x = 1;
        \\    _ = x;
        \\}
    );
    try expectAction(
        \\fn f(o: ?u32) void {
        \\    if (o) |<|>v| {
        \\        return;
        \\    }
        \\}
    , "discard `v`",
        \\fn f(o: ?u32) void {
        \\    if (o) |v| {
        \\        _ = v;
        \\        return;
        \\    }
        \\}
    );
    try expectAction(
        \\fn f(a: u32) void {
        \\    _ = <|>a;
        \\    _ = a + 1;
        \\}
    , "remove discard",
        \\fn f(a: u32) void {
        \\    _ = a + 1;
        \\}
    );
}

test "add missing switch prongs" {
    try expectAction(
        \\const E = enum { a, b, c };
        \\fn f(e: E) void {
        \\    switch (e) {
        \\        .a => {},
        \\    }<|>
        \\}
    , "add missing switch prongs",
        \\const E = enum { a, b, c };
        \\fn f(e: E) void {
        \\    switch (e) {
        \\        .a => {},
        \\        .b => {},
        \\        .c => {},
        \\    }
        \\}
    );
    // 没有结尾逗号、联合
    try expectAction(
        \\const U = union(enum) { a: u8, b };
        \\fn f(u: U) void {
        \\    sw<|>itch (u) { .a => {} }
        \\}
    , "add missing switch prongs",
        \\const U = union(enum) { a: u8, b };
        \\fn f(u: U) void {
        \\    switch (u) { .a => {},
        \\        .b => {},
        \\    }
        \\}
    );
    try testing.expectEqualStrings("no action", try applyNone(
        \\const E = enum { a, b };
        \\fn f(e: E) void {
        \\    switch (e) { .a => {}, else => {} }<|>
        \\}
    ));
}

fn applyNone(text: []const u8) ![]const u8 {
    const got = try apply(text, "add missing switch prongs");
    defer testing.allocator.free(got);
    return if (std.mem.eql(u8, got, "no action")) "no action" else "action";
}

test "add missing struct fields" {
    try expectAction(
        \\const P = struct { x: i32, y: i32, z: i32 = 0 };
        \\const p: P = .{ .x = 1<|> };
    , "add missing struct fields",
        \\const P = struct { x: i32, y: i32, z: i32 = 0 };
        \\const p: P = .{ .x = 1, .y = undefined };
    );
    try expectAction(
        \\const P = struct { x: i32, y: i32 };
        \\const p = P{
        \\    .x = 1,
        \\}<|>;
    , "add missing struct fields",
        \\const P = struct { x: i32, y: i32 };
        \\const p = P{
        \\    .x = 1,
        \\    .y = undefined,
        \\};
    );
}

test "add missing fields and prongs with names that need quoting" {
    try expectAction(
        \\const S = struct { @"x y": u32, @"type": u8 };
        \\const s: S = .{<|>};
    , "add missing struct fields",
        \\const S = struct { @"x y": u32, @"type": u8 };
        \\const s: S = .{ .@"x y" = undefined, .type = undefined };
    );
    try expectAction(
        \\const E = enum { @"a b", c };
        \\fn f(e: E) void {
        \\    switch (e) {
        \\        .c => {},<|>
        \\    }
        \\}
    , "add missing switch prongs",
        \\const E = enum { @"a b", c };
        \\fn f(e: E) void {
        \\    switch (e) {
        \\        .c => {},
        \\        .@"a b" => {},
        \\    }
        \\}
    );
}

test "extract to local constant" {
    try expectAction(
        \\fn f(a: u32, b: u32) u32 {
        \\    const c = «a * b» + 1;
        \\    return c;
        \\}
    , "extract",
        \\fn f(a: u32, b: u32) u32 {
        \\    const value = a * b;
        \\    const c = value + 1;
        \\    return c;
        \\}
    );
    // 表达式位于语句开头；名字已被占用时换一个
    try expectAction(
        \\fn g(x: u32) u32 {
        \\    return x;
        \\}
        \\fn f(value: u32) void {
        \\    if (value > 0) {
        \\        _ = «g(value)»;
        \\    }
        \\}
    , "extract",
        \\fn g(x: u32) u32 {
        \\    return x;
        \\}
        \\fn f(value: u32) void {
        \\    if (value > 0) {
        \\        const value1 = g(value);
        \\        _ = value1;
        \\    }
        \\}
    );
    // 类型取决于结果位置：标注原处的类型
    try expectAction(
        \\pub fn f(x: u64) u8 {
        \\    return «@intCast(x)»;
        \\}
    , "extract",
        \\pub fn f(x: u64) u8 {
        \\    const value: u8 = @intCast(x);
        \\    return value;
        \\}
    );
    // 短路的左侧总会求值
    try expectAction(
        \\fn g() bool {
        \\    return true;
        \\}
        \\fn f(flag: bool) bool {
        \\    return «g()» and flag;
        \\}
    , "extract",
        \\fn g() bool {
        \\    return true;
        \\}
        \\fn f(flag: bool) bool {
        \\    const value = g();
        \\    return value and flag;
        \\}
    );
    // 选区是纯的：可以越过之前的调用
    try expectAction(
        \\fn g(x: u32) u32 {
        \\    return x;
        \\}
        \\fn f(a: u32, b: u32) u32 {
        \\    return g(1) + «a * b»;
        \\}
    , "extract",
        \\fn g(x: u32) u32 {
        \\    return x;
        \\}
        \\fn f(a: u32, b: u32) u32 {
        \\    const value = a * b;
        \\    return g(1) + value;
        \\}
    );
    // 之前的部分是纯的（参数、常量）：有副作用的选区可以提前
    try expectAction(
        \\const k: u32 = 2;
        \\fn g() u32 {
        \\    return 1;
        \\}
        \\fn h(a: u32, b: u32, c: u32) u32 {
        \\    return a + b + c;
        \\}
        \\fn f(n: u32) u32 {
        \\    return h(n, k * 2, «g()»);
        \\}
    , "extract",
        \\const k: u32 = 2;
        \\fn g() u32 {
        \\    return 1;
        \\}
        \\fn h(a: u32, b: u32, c: u32) u32 {
        \\    return a + b + c;
        \\}
        \\fn f(n: u32) u32 {
        \\    const value = g();
        \\    return h(n, k * 2, value);
        \\}
    );
    // 不提取：赋值的左侧、取地址的操作数、while 的条件、不是完整表达式的选区
    for ([_][]const u8{
        "fn f() void {\n    var x: u32 = 0;\n    «x» = 1;\n}",
        "fn f() void {\n    var x: u32 = 0;\n    const p = &«x»;\n    _ = p;\n}",
        "fn f(n: u32) void {\n    var i: u32 = 0;\n    while («i < n») : (i += 1) {}\n}",
        "fn f(a: u32) u32 {\n    return «a +» 1;\n}",
        // 有条件求值：短路的右侧、if 的分支、catch / orelse 的右侧、循环体
        "var hits: u32 = 0;\nfn hit() bool {\n    hits += 1;\n    return true;\n}\npub fn f(flag: bool) bool {\n    return flag and «hit()»;\n}",
        "fn g() u32 {\n    return 1;\n}\nfn f(c: bool) u32 {\n    return if (c) «g()» else 0;\n}",
        "fn g() u32 {\n    return 1;\n}\nfn f(x: ?u32) u32 {\n    return x orelse «g()»;\n}",
        "fn g() u32 {\n    return 1;\n}\nfn f(x: anyerror!u32) u32 {\n    return x catch «g()»;\n}",
        "fn g(x: u32) void {\n    _ = x;\n}\nfn f(xs: []const u32) void {\n    for (xs) |x| g(«x + 1»);\n}",
        // 顺序：选区与之前的部分都有副作用
        "fn g(x: u32) u32 {\n    return x;\n}\nfn f() u32 {\n    return g(1) + «g(2)»;\n}",
        // 顺序：之前读取的 var 可能被选区中的调用修改
        "fn g() u32 {\n    return 1;\n}\nfn f() u32 {\n    var i: u32 = 0;\n    i += 1;\n    return i + «g()»;\n}",
        // 顺序：之前的 try 可能提前返回
        "fn h() !u32 {\n    return 1;\n}\nfn g() u32 {\n    return 1;\n}\nfn f(x: anyerror!u32) !u32 {\n    return (try x) + «g()»;\n}",
        // 纯的表达式也不提出短路的保护（除零）
        "fn f(x: u32, y: u32) bool {\n    return x != 0 and «y / x» > 1;\n}",
        // defer 中的表达式在离开作用域时求值
        "fn g(x: u32) void {\n    _ = x;\n}\nfn f(a: u32) void {\n    defer g(«a + 1»);\n}",
        // 结果类型标注不出
        "const E = enum { a, b };\nfn f() E {\n    return «.a»;\n}",
    }) |text| {
        const got = try apply(text, "extract");
        defer testing.allocator.free(got);
        testing.expectEqualStrings("no action", got) catch |err| {
            std.debug.print("{s}\n", .{text});
            return err;
        };
    }
}

/// 用编译器的语法树验证编辑结果，并从字符串 token 读取字节值。
fn stringValue(source: []const u8) ![]u8 {
    const z = try testing.allocator.allocSentinel(u8, source.len, 0);
    @memcpy(z, source);
    defer testing.allocator.free(z);
    var tree = try std.zig.Ast.parse(testing.allocator, z, .{});
    defer tree.deinit(testing.allocator);
    try testing.expectEqual(0, tree.errors.len);
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(testing.allocator);
    var lines: usize = 0;
    for (tree.tokens.items(.tag), 0..) |tag, i| switch (tag) {
        .string_literal => return std.zig.string_literal.parseAlloc(testing.allocator, tree.tokenSlice(@intCast(i))),
        .multiline_string_literal_line => {
            if (lines != 0) try value.append(testing.allocator, '\n');
            const token = tree.tokenSlice(@intCast(i));
            var end = token.len;
            if (end > 0 and token[end - 1] == '\n') end -= 1;
            if (end > 0 and token[end - 1] == '\r') end -= 1;
            try value.appendSlice(testing.allocator, token[2..end]);
            lines += 1;
        },
        else => {},
    };
    try testing.expect(lines != 0);
    return value.toOwnedSlice(testing.allocator);
}

test "string conversion preserves bytes and surrounding syntax" {
    const cases = .{
        .{ "\"\"", "" },
        .{ "\"abc\"", "abc" },
        .{ "\"a\\nb\"", "a\nb" },
        .{ "\"\\n\\na\\n\\n\"", "\n\na\n\n" },
        .{ "\"\\\"\\\\\\x41\\u{4e2d}  \"", "\"\\A中  " },
    };
    const contexts = .{
        .{ "const text = ", ";" },
        .{ "fn f() void {\n    const text = ", ";\n    _ = text;\n}" },
        .{ "const text = .{ ", ", 42 };" },
        .{ "const text = call(", ");" },
        .{ "const text =\n    ", ";" },
        .{ "const text = ", "; // comment\r\n" },
    };
    inline for (cases) |case| {
        inline for (contexts) |context| {
            const source = try std.mem.concat(testing.allocator, u8, &.{ context[0], "<|>", case[0], context[1] });
            defer testing.allocator.free(source);
            const multi = try apply(source, "convert to a multiline");
            defer testing.allocator.free(multi);
            const value = try stringValue(multi);
            defer testing.allocator.free(value);
            try testing.expectEqualStrings(case[1], value);
            const marker = std.mem.indexOf(u8, multi, "\\\\").?;
            const marked = try std.mem.concat(testing.allocator, u8, &.{ multi[0..marker], "<|>", multi[marker..] });
            defer testing.allocator.free(marked);
            const ordinary = try apply(marked, "convert to a string");
            defer testing.allocator.free(ordinary);
            const roundtrip = try stringValue(ordinary);
            defer testing.allocator.free(roundtrip);
            try testing.expectEqualStrings(case[1], roundtrip);
        }
    }
}

test "multiline conversion preserves whitespace and selects the whole literal" {
    for ([_][]const u8{
        "const text =\n    \\\\<|> a  \n    \\\\b\\\\\"\n    \\\\\n;",
        "const text =\r\n    \\\\ a  \r\n    \\\\b<|>\\\\\"\r\n    \\\\\r\n;",
        "const text = «\n    \\\\ a  \n    \\\\b\\\\\"\n    \\\\\n»;",
    }) |source| {
        const converted = try apply(source, "convert to a string");
        defer testing.allocator.free(converted);
        const value = try stringValue(converted);
        defer testing.allocator.free(value);
        try testing.expectEqualStrings(" a  \nb\\\\\"\n", value);
    }
}

test "string conversion rejects unrepresentable bytes and invalid selections" {
    for ([_][]const u8{
        "const s = <|>\"\\t\";",
        "const s = <|>\"\\r\\n\";",
        "const s = <|>\"\\x00\";",
        "const s = <|>\"\\x7f\";",
        "const s = <|>\"\\xff\";",
        "const s = <|>\"\\q\";",
        "const s = <|>\"unfinished",
        "const s = @\"<|>name\";",
        "const s = '<|>x';",
        "const s = «\"a\", \"b\"»;",
    }) |source| {
        const converted = try apply(source, "convert to");
        defer testing.allocator.free(converted);
        try testing.expectEqualStrings("no action", converted);
    }
}
