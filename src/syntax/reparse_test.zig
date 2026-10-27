const std = @import("std");
const testing = std.testing;
const Parse = @import("Parse.zig");

/// Asserts that the incremental result for old → new matches a full parse; `expect_incremental`
/// asserts whether the local reparse path was taken
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
    // Balanced braces newly added inside
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
    // The outer function body node is copied; its children except the while reuse the old nodes
    const old_fn = old.root.children[0].node().?;
    const new_fn = inc.root.children[0].node().?;
    try testing.expect(old_fn != new_fn);
    try testing.expect(old_fn.children[0].node().? == new_fn.children[0].node().?); // fn_proto reused
}

test "falls back to full parse when conditions are not met" {
    const base = "fn f() void {\n    g();\n}\n";
    // Changes the braces themselves
    try expectReparse(base, "fn f() void \n    g();\n}\n", false);
    // Unbalanced braces inside
    try expectReparse(base, "fn f() void {\n    if (x) {\n    g();\n}\n", false);
    // Comment out the `}`
    try expectReparse(base, "fn f() void {\n    g(); //}\n}\n", true);
    try expectReparse(base, "fn f() void {\n    g();\n//}\n", false);
    // Top-level edit
    try expectReparse(base, "const x = 1;\nfn f() void {\n    g();\n}\n", false);
    // Text unchanged
    try expectReparse(base, base, false);
}

test "outer errors are kept and shifted after incremental parse" {
    // The error on the first line is before the block, the one on the last line after it
    try expectReparse("const a = ;\nfn f() void {\n    g();\n}\nconst b = ;\n", "const a = ;\nfn f() void {\n    g(1, 2, 3);\n}\nconst b = ;\n", true);
    // `1 {}` is an initializer list; once a `;` appears in it, the block grammar cannot fully
    // consume the function body braces, so it falls back to a full parse
    try expectReparse("fn f() void {\n    x = 1 {}\n}\n", "fn f() void {\n    x = 1 { y(); }\n}\n", false);
}

test "ref counting: old result stays valid until the incremental result is freed" {
    const old = try Parse.create(testing.allocator, "fn f() void {\n    g();\n}\n");
    const inc = (try Parse.reparseBlock(testing.allocator, old, "fn f() void {\n    h();\n}\n")).?;
    old.destroy(); // the query engine frees the old value
    // The reused fn_proto node is still accessible
    try testing.expectEqualStrings("fn", inc.root.children[0].node().?.children[0].node().?.children[0].unpack().token.text);
    inc.destroy();
}

/// Like `expectReparse`, but checks the top-level local reparse
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
    // Typing in the comment at the end of the file
    try expectTopLevel(base, "const a = 1;\nconst b = 2;\nfn f() void {}\nconst c = 3;\n// endx\n", true);
    // Insert a new declaration between declarations, introducing syntax errors
    try expectTopLevel(base, "const a = 1;\nconst b = 2;\nfn f() void {}\nconst x = ;\nconst c = 3;\n// end\n", true);
    try expectTopLevel(base, "const a = 1;\nconst b = 2;\nfn f() void {}\nconst c = 3\n// end\n", true);
    // Fewer than two members before the edit: full parse
    try expectTopLevel(base, "const a = 10;\nconst b = 2;\nfn f() void {}\nconst c = 3;\n// end\n", false);
    // `//!` in the fragment: full parse
    try expectTopLevel(base, "const a = 1;\nconst b = 2;\nfn f() void {}\nconst c = 3;\n//! doc\n", false);
}

test "top-level reparse falls back when an earlier error sits at the cut" {
    // `const b = 2` lacks `;`; the error is reported at the start of the next member `const c`
    const old_text = "const a = 1;\nconst b = 2\nconst c = 3;\nconst d = 4;\nconst e = 5;\n";
    // Cut point at `const d`: local reparse as usual
    try expectTopLevel(old_text, "const a = 1;\nconst b = 2\nconst c = 3;\nconst d = 4;\nconst e = 5;\nconst f = 6;\n", true);
    // Cut point at `const c`, exactly where that error is: full parse
    try expectTopLevel(old_text, "const a = 1;\nconst b = 2\nconst c = 3;\nconst d = 4;\nconst e = 50;\n", false);
}

/// The incremental result (`Parse.reparse`) matches a full parse
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
