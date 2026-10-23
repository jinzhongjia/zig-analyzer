const std = @import("std");
const testing = std.testing;
const Parse = @import("Parse.zig");

/// 断言 old → new 的增量结果与全量解析一致；`expect_incremental` 断言是否走了局部重解析
fn expectReparse(old_text: []const u8, new_text: []const u8, expect_incremental: bool) !void {
    const old = try Parse.create(testing.allocator, old_text);
    defer old.destroy();
    const full = try Parse.create(testing.allocator, new_text);
    defer full.destroy();
    const inc = try Parse.reparseBlock(testing.allocator, old, new_text);
    try testing.expectEqual(expect_incremental, inc != null);
    if (inc) |p| {
        defer p.destroy();
        try testing.expect(p.sameAs(full));
        try testing.expectEqualStrings(new_text, p.source);
    }
}

test "edits inside a function body use block reparse" {
    const base = "const a = 1;\nfn f() void {\n    g();\n}\nconst b = 2;\n";
    try expectReparse(base, "const a = 1;\nfn f() void {\n    g(1, 2);\n}\nconst b = 2;\n", true);
    try expectReparse(base, "const a = 1;\nfn f() void {\n    g();\n    var x = y.;\n}\nconst b = 2;\n", true);
    try expectReparse(base, "const a = 1;\nfn f() void {\n}\nconst b = 2;\n", true);
    // 内部新增配平的花括号
    try expectReparse(base, "const a = 1;\nfn f() void {\n    if (x) { g(); }\n}\nconst b = 2;\n", true);
}

test "edits inside a container use block reparse" {
    try expectReparse("const S = struct {\n    a: u32,\n};\n", "const S = struct {\n    a: u32,\n    b: u8,\n};\n", true);
    try expectReparse("const S = struct {\n    a: u32,\n};\n", "const S = struct {\n    a: u32 = ,\n};\n", true);
}

test "picks the deepest block" {
    const old = try Parse.create(testing.allocator, "fn f() void {\n    while (true) {\n        a();\n    }\n}\n");
    defer old.destroy();
    const inc = (try Parse.reparseBlock(testing.allocator, old, "fn f() void {\n    while (true) {\n        b();\n    }\n}\n")).?;
    defer inc.destroy();
    // 外层函数体节点被复制，其中的 while 之外的子节点复用旧节点
    const old_fn = old.root.children[0].node().?;
    const new_fn = inc.root.children[0].node().?;
    try testing.expect(old_fn != new_fn);
    try testing.expect(old_fn.children[0].node().? == new_fn.children[0].node().?); // fn_proto 复用
}

test "falls back to full parse when conditions are not met" {
    const base = "fn f() void {\n    g();\n}\n";
    // 改动了花括号本身
    try expectReparse(base, "fn f() void \n    g();\n}\n", false);
    // 内部花括号不配平
    try expectReparse(base, "fn f() void {\n    if (x) {\n    g();\n}\n", false);
    // 把 `}` 注释掉
    try expectReparse(base, "fn f() void {\n    g(); //}\n}\n", true);
    try expectReparse(base, "fn f() void {\n    g();\n//}\n", false);
    // 顶层编辑
    try expectReparse(base, "const x = 1;\nfn f() void {\n    g();\n}\n", false);
    // 文本未变
    try expectReparse(base, base, false);
}

test "outer errors are kept and shifted after incremental parse" {
    // 第一行的错误在块之前，最后一行的错误在块之后
    try expectReparse("const a = ;\nfn f() void {\n    g();\n}\nconst b = ;\n", "const a = ;\nfn f() void {\n    g(1, 2, 3);\n}\nconst b = ;\n", true);
    // `1 {}` 是初始化列表；其中出现 `;` 后函数体花括号无法由块语法消费完，回退全量解析
    try expectReparse("fn f() void {\n    x = 1 {}\n}\n", "fn f() void {\n    x = 1 { y(); }\n}\n", false);
}

test "ref counting: old result stays valid until the incremental result is freed" {
    const old = try Parse.create(testing.allocator, "fn f() void {\n    g();\n}\n");
    const inc = (try Parse.reparseBlock(testing.allocator, old, "fn f() void {\n    h();\n}\n")).?;
    old.destroy(); // 查询引擎释放旧值
    // 复用的 fn_proto 节点仍可访问
    try testing.expectEqualStrings("fn", inc.root.children[0].node().?.children[0].node().?.children[0].unpack().token.text);
    inc.destroy();
}

/// 同 `expectReparse`，校验顶层的局部重解析
fn expectTopLevel(old_text: []const u8, new_text: []const u8, expect_incremental: bool) !void {
    const old = try Parse.create(testing.allocator, old_text);
    defer old.destroy();
    const full = try Parse.create(testing.allocator, new_text);
    defer full.destroy();
    const inc = try Parse.reparseTopLevel(testing.allocator, old, new_text);
    try testing.expectEqual(expect_incremental, inc != null);
    if (inc) |p| {
        defer p.destroy();
        try testing.expect(p.sameAs(full));
        try testing.expectEqualStrings(new_text, p.source);
    }
}

test "top-level edits reparse from shortly before the edit" {
    const base = "const a = 1;\nconst b = 2;\nfn f() void {}\nconst c = 3;\n// end\n";
    // 文件末尾的注释中输入
    try expectTopLevel(base, "const a = 1;\nconst b = 2;\nfn f() void {}\nconst c = 3;\n// endx\n", true);
    // 声明之间插入新的声明、制造语法错误
    try expectTopLevel(base, "const a = 1;\nconst b = 2;\nfn f() void {}\nconst x = ;\nconst c = 3;\n// end\n", true);
    try expectTopLevel(base, "const a = 1;\nconst b = 2;\nfn f() void {}\nconst c = 3\n// end\n", true);
    // 编辑之前不足两个成员：全量解析
    try expectTopLevel(base, "const a = 10;\nconst b = 2;\nfn f() void {}\nconst c = 3;\n// end\n", false);
    // 片段中有 `//!`：全量解析
    try expectTopLevel(base, "const a = 1;\nconst b = 2;\nfn f() void {}\nconst c = 3;\n//! doc\n", false);
}

test "top-level reparse falls back when an earlier error sits at the cut" {
    // `const b = 2` 缺少 `;`，错误报在下一个成员 `const c` 的开头
    const old_text = "const a = 1;\nconst b = 2\nconst c = 3;\nconst d = 4;\nconst e = 5;\n";
    // 切点在 `const d`：照常局部重解析
    try expectTopLevel(old_text, "const a = 1;\nconst b = 2\nconst c = 3;\nconst d = 4;\nconst e = 5;\nconst f = 6;\n", true);
    // 切点在 `const c`，正是该错误的位置：全量解析
    try expectTopLevel(old_text, "const a = 1;\nconst b = 2\nconst c = 3;\nconst d = 4;\nconst e = 50;\n", false);
}

/// 增量结果（`Parse.reparse`）与全量解析一致
fn expectConsistent(old: *Parse, new_text: []const u8) !void {
    const inc = try Parse.reparse(testing.allocator, old, new_text);
    defer inc.destroy();
    const full = try Parse.create(testing.allocator, new_text);
    defer full.destroy();
    try testing.expect(inc.sameAs(full));
}

test "deep nesting: edits in the innermost block reparse locally" {
    const a = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "fn f() void ");
    for (0..1500) |_| try src.append(a, '{');
    try src.appendSlice(a, "a();");
    for (0..1500) |_| try src.append(a, '}');
    try src.append(a, '\n');
    const old = try Parse.create(a, src.items);
    defer old.destroy();
    const edited = try std.mem.replaceOwned(u8, a, src.items, "a();", "{{{{{{{{{{a();}}}}}}}}}}");
    defer a.free(edited);
    const inc = try Parse.reparseBlock(a, old, edited) orelse return error.TestUnexpectedResult;
    defer inc.destroy();
    try expectConsistent(old, edited);
}
