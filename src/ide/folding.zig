//! textDocument/foldingRange：代码块、容器、参数与初始化列表、连续注释、多行字符串。

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const offsets = @import("../util/offsets.zig");
const tree = @import("../syntax/tree.zig");
const SyntaxNode = tree.SyntaxNode;
const SyntaxKind = @import("../syntax/kind.zig").SyntaxKind;

pub fn foldingRanges(arena: Allocator, root: SyntaxNode, lines: offsets.LineIndex) Allocator.Error![]const types.FoldingRange {
    var b: Builder = .{ .arena = arena, .lines = lines };
    try b.visit(root);
    try b.flushRun();
    return b.out.items;
}

const Builder = struct {
    arena: Allocator,
    lines: offsets.LineIndex,
    out: std.ArrayList(types.FoldingRange) = .empty,
    /// 当前连续注释 / 多行字符串的起止行
    run: ?struct { kind: Run, start: u32, end: u32 } = null,

    const Run = enum { comment, string };

    fn add(b: *Builder, start_line: u32, end_line: u32, kind: ?[]const u8) Allocator.Error!void {
        if (end_line <= start_line) return;
        try b.out.append(b.arena, .{ .startLine = start_line, .endLine = end_line, .kind = kind });
    }

    fn visit(b: *Builder, node: SyntaxNode) Allocator.Error!void {
        // 括号类结构：从开括号所在行折叠到闭括号的前一行，使闭括号保持可见
        const open_close: ?[2]SyntaxKind = switch (node.kind()) {
            .block, .container_decl, .init_list, .switch_expr, .error_set_decl => .{ .l_brace, .r_brace },
            .arg_list, .param_list, .asm_expr => .{ .l_paren, .r_paren },
            else => null,
        };
        if (open_close) |oc| {
            const open = node.childToken(oc[0]);
            const close = lastChildToken(node, oc[1]);
            if (open != null and close != null) {
                try b.add(b.lines.lineOf(open.?.offset), b.lines.lineOf(close.?.offset) -| 1, null);
            }
        }

        var it = node.children();
        while (it.next()) |e| switch (e) {
            .node => |c| try b.visit(c),
            .token => |t| switch (t.kind) {
                .whitespace => {},
                .line_comment, .doc_comment, .container_doc_comment => try b.extend(.comment, t),
                .multiline_string_literal_line => try b.extend(.string, t),
                else => try b.flushRun(),
            },
        };
    }

    fn extend(b: *Builder, kind: Run, t: tree.SyntaxToken) Allocator.Error!void {
        const line = b.lines.lineOf(t.offset);
        if (b.run) |*r| {
            if (r.kind == kind and r.end + 1 == line) {
                r.end = line;
                return;
            }
        }
        try b.flushRun();
        b.run = .{ .kind = kind, .start = line, .end = line };
    }

    fn flushRun(b: *Builder) Allocator.Error!void {
        const r = b.run orelse return;
        b.run = null;
        try b.add(r.start, r.end, if (r.kind == .comment) types.FoldingRangeKind.Comment else null);
    }
};

fn lastChildToken(node: SyntaxNode, kind: SyntaxKind) ?tree.SyntaxToken {
    var result: ?tree.SyntaxToken = null;
    var it = node.children();
    while (it.next()) |e| if (e == .token and e.token.kind == kind) {
        result = e.token;
    };
    return result;
}

const testing = std.testing;
const Parse = @import("../syntax/Parse.zig");

test foldingRanges {
    const text =
        \\// a
        \\// b
        \\fn f(
        \\    x: u32,
        \\) void {
        \\    const s =
        \\        \\l1
        \\        \\l2
        \\    ;
        \\}
    ;
    const parse = try Parse.create(testing.allocator, text);
    defer parse.destroy();
    var lines = try offsets.LineIndex.init(testing.allocator, text);
    defer lines.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const ranges = try foldingRanges(arena.allocator(), parse.rootNode(), lines);
    var found: [4]bool = @splat(false);
    for (ranges) |r| {
        if (r.startLine == 0 and r.endLine == 1) found[0] = std.mem.eql(u8, r.kind.?, "comment");
        if (r.startLine == 2 and r.endLine == 3) found[1] = true; // 参数列表
        if (r.startLine == 4 and r.endLine == 8) found[2] = true; // 函数体
        if (r.startLine == 6 and r.endLine == 7) found[3] = true; // 多行字符串
    }
    try testing.expectEqual([4]bool{ true, true, true, true }, found);
}
