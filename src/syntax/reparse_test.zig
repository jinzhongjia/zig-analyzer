const std = @import("std");
const testing = std.testing;
const Parse = @import("Parse.zig");
const green = @import("green.zig");

/// Asserts that the incremental result for old → new matches a full parse; `expect_incremental`
/// asserts whether the local reparse path was taken
fn expectReparse(old_text: []const u8, new_text: []const u8, expect_incremental: bool) !void {
    const old = try Parse.create(testing.allocator, old_text, .zig);
    defer old.destroy();
    const full = try Parse.create(testing.allocator, new_text, .zig);
    defer full.destroy();
    const inc = try Parse.reparseBlock(testing.allocator, old, new_text);
    try testing.expectEqual(expect_incremental, inc != null);
    if (inc) |p| {
        defer p.destroy();
        try testing.expect(p.sameAs(full));
        try testing.expectEqualStrings(new_text, p.source);
    }
}

test "a chain of block reparses does not keep a copy of the text per edit" {
    // Each result used to copy the whole text into its arena, which the results built on it keep:
    // a large file reached the chain limit after a few edits and was parsed in full again
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "fn g() void {\n    _ = 0;\n}\n");
    for (0..40) |i| {
        try text.print(testing.allocator, "fn f{d}() void {{\n", .{i});
        for (0..100) |k| try text.print(testing.allocator, "    _ = {d};\n", .{k});
        try text.appendSlice(testing.allocator, "}\n");
    }
    var chain = try Parse.create(testing.allocator, text.items, .zig);
    defer chain.destroy();
    const at = std.mem.indexOf(u8, text.items, "_ = 0;").?;
    const edits = 10;
    for (0..edits) |_| {
        try text.insert(testing.allocator, at, 'x');
        const inc = try Parse.reparse(testing.allocator, chain, text.items);
        chain.destroy();
        chain = inc;
        try testing.expect(chain.base != null);
    }
    try testing.expect((chain.chain_bytes - chain.full_bytes) / edits < text.items.len / 2);
    try testing.expectEqualStrings(text.items, chain.source);
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
    const old = try Parse.create(testing.allocator, "fn f() void {\n    while (true) {\n        a();\n    }\n}\n", .zig);
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

test "a line comment that runs over the block's old `}` falls back to a full parse" {
    // In the block's own text the comment ends at the block's old `}`: a local reparse would keep
    // the code after it (` else { c(); }`) live
    const one_line = "fn f(x: bool) void {\n    if (x) { a(); b(); } else { c(); }\n}\n";
    const one_line_new = "fn f(x: bool) void {\n    if (x) { a(); } // b(); } else { c(); }\n}\n";
    try expectReparse(one_line, one_line_new, false);
    const multi_line = "fn f(x: bool) void {\n    if (x) {\n        a();\n    } else {\n        c();\n    }\n}\n";
    const multi_line_new = "fn f(x: bool) void {\n    if (x) {\n        a();\n    } // } else {\n        c();\n    }\n}\n";
    try expectReparse(multi_line, multi_line_new, false);
    for ([_][2][]const u8{ .{ one_line, one_line_new }, .{ multi_line, multi_line_new } }) |c| {
        const old = try Parse.create(testing.allocator, c[0], .zig);
        defer old.destroy();
        try expectConsistent(old, c[1]);
    }
}

test "outer errors are kept and shifted after incremental parse" {
    // The error on the first line is before the block, the one on the last line after it
    try expectReparse("const a = ;\nfn f() void {\n    g();\n}\nconst b = ;\n", "const a = ;\nfn f() void {\n    g(1, 2, 3);\n}\nconst b = ;\n", true);
    // `1 {}` is an initializer list; once a `;` appears in it, the block grammar cannot fully
    // consume the function body braces, so it falls back to a full parse
    try expectReparse("fn f() void {\n    x = 1 {}\n}\n", "fn f() void {\n    x = 1 { y(); }\n}\n", false);
}

test "ref counting: old result stays valid until the incremental result is freed" {
    const old = try Parse.create(testing.allocator, "fn f() void {\n    g();\n}\n", .zig);
    const inc = (try Parse.reparseBlock(testing.allocator, old, "fn f() void {\n    h();\n}\n")).?;
    old.destroy(); // the query engine frees the old value
    // The reused fn_proto node is still accessible
    try testing.expectEqualStrings("fn", inc.root.children[0].node().?.children[0].node().?.children[0].unpack().token.text);
    inc.destroy();
}

/// Like `expectReparse`, but checks the top-level local reparse
fn expectTopLevel(old_text: []const u8, new_text: []const u8, expect_incremental: bool) !void {
    const old = try Parse.create(testing.allocator, old_text, .zig);
    defer old.destroy();
    const full = try Parse.create(testing.allocator, new_text, .zig);
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
    // Fewer than two members before the edit: reparses from the start of the file
    try expectTopLevel(base, "const a = 10;\nconst b = 2;\nfn f() void {}\nconst c = 3;\n// end\n", true);
    try expectTopLevel("//! doc\n" ++ base, "//! doc\n" ++ "const a = 10;\nconst b = 2;\nfn f() void {}\nconst c = 3;\n// end\n", true);
    // `//!` in the fragment: full parse
    try expectTopLevel(base, "const a = 1;\nconst b = 2;\nfn f() void {}\nconst c = 3;\n//! doc\n", false);
}

/// Whether the top-level child `from_end` places from the end is the old one reused as is (the
/// members after the edit were not parsed again); the result matches a full parse either way
fn expectTailReused(old_text: []const u8, new_text: []const u8, from_end: usize, reused: bool) !void {
    const old = try Parse.create(testing.allocator, old_text, .zig);
    defer old.destroy();
    const full = try Parse.create(testing.allocator, new_text, .zig);
    defer full.destroy();
    const inc = (try Parse.reparseTopLevel(testing.allocator, old, new_text)).?;
    defer inc.destroy();
    try testing.expect(inc.sameAs(full));
    const x = old.root.children[old.root.children.len - from_end];
    const y = inc.root.children[inc.root.children.len - from_end];
    try testing.expectEqual(reused, x.ptr == y.ptr);
}

test "top-level edits reuse the members after the edit" {
    const base = "const a = 1;\nconst b = 2;\nfn f() void {}\nconst c = 3;\nconst d = 4;\nconst e = 5;\n";
    // The last member is reused after an edit at the start, in the middle, and with new errors
    try expectTailReused(base, "const a = 10;\nconst b = 2;\nfn f() void {}\nconst c = 3;\nconst d = 4;\nconst e = 5;\n", 2, true);
    try expectTailReused(base, "const a = 1;\nconst b = 2;\nfn g() void {}\nconst c = 3;\nconst d = 4;\nconst e = 5;\n", 2, true);
    try expectTailReused(base, "const a = 1;\nconst b = 2;\nfn f() void {}\nconst x = ;\nconst c = 3;\nconst d = 4;\nconst e = 5;\n", 2, true);
    // An unclosed `{`: the members after it become statements of the function body
    try expectTailReused(base, "const a = 1;\nconst b = 2;\nfn f() void {\nconst c = 3;\nconst d = 4;\nconst e = 5;\n", 2, false);
    // Errors of the reused members are kept, shifted
    try expectTailReused("const a = 1;\nconst b = 2;\nconst c = 3;\nconst d = 4;\nconst e = 5\nconst f = 6;\n", "const a = 11;\nconst b = 2;\nconst c = 3;\nconst d = 4;\nconst e = 5\nconst f = 6;\n", 2, true);
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
    const full = try Parse.create(testing.allocator, new_text, .zig);
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
    const old = try Parse.create(a, src.items, .zig);
    defer old.destroy();
    const edited = try std.mem.replaceOwned(u8, a, src.items, "a();", "{{{{{{{{{{a();}}}}}}}}}}");
    defer a.free(edited);
    const inc = try Parse.reparseBlock(a, old, edited) orelse return error.TestUnexpectedResult;
    defer inc.destroy();
    try expectConsistent(old, edited);
}

test "an edit inside a block is parsed in full once the chain is over the limit" {
    // Memory reclamation past the chain limit does not depend on where the edit lies
    const a = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    try text.appendSlice(a, "fn f() void {\n    g();\n}\n");
    const at = std.mem.indexOf(u8, text.items, "g();").?;
    var chain = try Parse.create(a, text.items, .zig);
    defer chain.destroy();
    var exceeded = false;
    for (0..64) |_| {
        try text.insert(a, at, ' ');
        const inc = try Parse.reparseBlock(a, chain, text.items) orelse {
            try testing.expect(chain.chain_bytes > 2 * chain.full_bytes);
            exceeded = true;
            break;
        };
        chain.destroy();
        chain = inc;
    }
    try testing.expect(exceeded);
    // The edit that the block reparse declined is parsed in full, as any other fallback
    const full = try Parse.create(a, text.items, .zig);
    defer full.destroy();
    const inc = try Parse.reparse(a, chain, text.items);
    defer inc.destroy();
    try testing.expect(inc.base == null);
    try testing.expect(inc.sameAs(full));
}

test "zon files keep the zon mode and are always parsed in full" {
    const old_text = ".{\n    .a = .{\n        .b = 1,\n    },\n}\n";
    const old = try Parse.create(testing.allocator, old_text, .zon);
    defer old.destroy();
    const edits = [_][]const u8{
        // An edit inside braces: Zig mode would reparse the block locally
        ".{\n    .a = .{\n        .b = 2,\n        .c = 3,\n    },\n}\n",
        // Top-level edits: Zig mode would reparse them as container members
        ".{\n    .a = .{\n        .b = 1,\n    },\n}\n\n",
        ".{\n    .a = .{\n        .b = 1,\n    },\n}\n.{}",
    };
    for (edits) |new_text| {
        const full = try Parse.create(testing.allocator, new_text, .zon);
        defer full.destroy();
        const inc = try Parse.reparse(testing.allocator, old, new_text);
        defer inc.destroy();
        try testing.expectEqual(.zon, inc.mode);
        try testing.expect(inc.base == null);
        try testing.expect(inc.sameAs(full));
        try testing.expect(inc.rootNode().childNode(.init_expr) != null);
        try testing.expect(inc.rootNode().childNode(.container_field) == null);
    }
}

/// Asserts that every node of `a` has the same kind and summary bits as the node at the same
/// position in `b`
fn expectSameBits(a: *const green.GreenNode, b: *const green.GreenNode) !void {
    try testing.expectEqual(a.kind, b.kind);
    try testing.expectEqual(a.flags.has_container, b.flags.has_container);
    try testing.expectEqual(a.flags.has_import, b.flags.has_import);
    try testing.expectEqual(a.children.len, b.children.len);
    for (a.children, b.children) |x, y| switch (x.unpack()) {
        .node => |n| try expectSameBits(n, y.node() orelse return error.TestUnexpectedResult),
        .token => try testing.expect(!y.is_node),
    };
}

test "incremental reparse keeps the summary bits of a full parse" {
    const base =
        \\const a = @import("a");
        \\const T = struct { x: u8 };
        \\const b = 1;
        \\fn f() void {
        \\    const Local = struct { v: u8 };
        \\    _ = Local{ .v = 1 };
        \\    _ = @import("body");
        \\}
        \\const c = 2;
        \\const U = struct { y: u8 };
        \\const d = @import("d");
        \\
    ;
    const Edit = struct {
        old: []const u8,
        new: []const u8,
        /// The members after the edit are the old nodes (the tail of a top-level reparse)
        tail_reused: bool,
    };
    const edits = [_]Edit{
        // Body edit: the ancestors on the path to the root are copied by hand
        .{ .old = ".v = 1", .new = ".v = 2", .tail_reused = true },
        // Edit in a member with members after it: the new root is built from the fragment and
        // the old children after the cut
        .{ .old = "const b = 1;", .new = "const b = 10;", .tail_reused = true },
        // Edit after the last member: the new root is built from the old children before the
        // fragment and the fragment
        .{ .old = "const d = @import(\"d\");\n", .new = "const d = @import(\"d\");\nconst e = @import(\"e\");\n", .tail_reused = false },
    };
    for (edits) |edit| {
        const text = try std.mem.replaceOwned(u8, testing.allocator, base, edit.old, edit.new);
        defer testing.allocator.free(text);
        const old = try Parse.create(testing.allocator, base, .zig);
        defer old.destroy();
        const inc = try Parse.reparse(testing.allocator, old, text);
        defer inc.destroy();
        const full = try Parse.create(testing.allocator, text, .zig);
        defer full.destroy();
        try testing.expect(inc.base != null);
        try testing.expect(inc.sameAs(full));
        try expectSameBits(inc.root, full.root);
        const last_old = old.root.children[old.root.children.len - 1];
        const last_new = inc.root.children[inc.root.children.len - 1];
        try testing.expectEqual(edit.tail_reused, last_old.ptr == last_new.ptr);
    }
}

test "parses that share the file text buffer give the same results" {
    const Text = @import("../util/Text.zig");
    const a = testing.allocator;
    const old_text = "const a = 1;\nfn f() void {\n    g();\n}\nconst b = 2;\n";
    const new_text = "const a = 1;\nfn f() void {\n    g(1, 2);\n}\nconst b = 2;\n";
    const old = try Parse.create(a, old_text, .zig);
    defer old.destroy();
    const full = try Parse.create(a, new_text, .zig);
    defer full.destroy();
    const buffer: *Text = try .init(a, new_text);
    defer buffer.release(a);

    // A full parse keeps the buffer of the input and reads it from there
    const shared = try Parse.createInShared(a, buffer, .zig, .latest);
    defer shared.destroy();
    try testing.expect(shared.sameAs(full));
    try testing.expectEqual(buffer.source().ptr, shared.source.ptr);

    // An incremental result shares the buffer of the new text and gets the same tree
    const inc = try Parse.reparseShared(a, old, buffer);
    defer inc.destroy();
    try testing.expect(inc.base != null);
    try testing.expect(inc.sameAs(full));
    try testing.expectEqual(buffer.source().ptr, inc.source.ptr);
    try testing.expectEqualStrings(new_text, inc.source);
}

test "the reported bytes of a chain include the text buffers it keeps alive" {
    const Text = @import("../util/Text.zig");
    const a = testing.allocator;
    const old_text = "const a = 1;\nfn f() void {\n    g();\n}\nconst b = 2;\n";
    const new_text = "const a = 1;\nfn f() void {\n    g(1, 2);\n}\nconst b = 2;\n";
    const first: *Text = try .init(a, old_text);
    const base = try Parse.createInShared(a, first, .zig, .latest);
    defer base.destroy();
    first.release(a);
    const second: *Text = try .init(a, new_text);
    const inc = try Parse.reparseShared(a, base, second);
    defer inc.destroy();
    second.release(a);

    // The chain keeps both buffers: the head's own source and the buffer of the full parse at the
    // base, which lives until its arena is destroyed
    try testing.expect(inc.base != null);
    try testing.expectEqual(@sizeOf(Parse) + inc.chain_bytes + inc.source.len + 1 + base.source.len + 1, inc.bytes());
}
