//! textDocument/semanticTokens：纯语法分类。
//!
//! 只为能从语法确定的 token 着色：关键字、注释、字面量、builtin、各类声明处的名字、
//! 字段访问与枚举字面量、标签、原始类型。引用处的普通名字需要语义信息，不着色。

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const offsets = @import("../util/offsets.zig");
const tree = @import("../syntax/tree.zig");
const SyntaxNode = tree.SyntaxNode;
const kind_mod = @import("../syntax/kind.zig");
const SyntaxKind = kind_mod.SyntaxKind;

pub const TokenType = enum(u32) {
    type,
    parameter,
    variable,
    property,
    enumMember,
    function,
    keyword,
    comment,
    string,
    number,
    label,
};

pub const Modifier = struct {
    pub const declaration: u32 = 1 << 0;
    pub const readonly: u32 = 1 << 1;
    pub const documentation: u32 = 1 << 2;
    pub const defaultLibrary: u32 = 1 << 3;
};

pub const legend: types.SemanticTokensLegend = .{
    .tokenTypes = blk: {
        const names = @typeInfo(TokenType).@"enum".field_names;
        var out: [names.len][]const u8 = undefined;
        for (names, 0..) |n, i| out[i] = n;
        const final = out;
        break :blk &final;
    },
    .tokenModifiers = &.{ "declaration", "readonly", "documentation", "defaultLibrary" },
};

pub fn semanticTokens(arena: Allocator, root: SyntaxNode, lines: offsets.LineIndex, enc: offsets.Encoding) Allocator.Error![]const u32 {
    var b: Builder = .{ .arena = arena, .lines = lines, .enc = enc };
    try b.visit(root, false);
    return b.data.items;
}

const Builder = struct {
    arena: Allocator,
    lines: offsets.LineIndex,
    enc: offsets.Encoding,
    data: std.ArrayList(u32) = .empty,
    prev: types.Position = .{ .line = 0, .character = 0 },
    /// 上一次换算的偏移与位置：token 按偏移递增，同一行内从这里继续计数
    cursor_offset: usize = 0,
    cursor: types.Position = .{ .line = 0, .character = 0 },

    fn visit(b: *Builder, node: SyntaxNode, in_enum: bool) Allocator.Error!void {
        const child_in_enum = if (node.kind() == .container_decl) node.childToken(.keyword_enum) != null and node.childToken(.keyword_union) == null else in_enum;
        const is_const = node.kind() == .var_decl and node.childToken(.keyword_const) != null;
        var it = node.children();
        while (it.next()) |e| switch (e) {
            .node => |c| try b.visit(c, child_in_enum),
            .token => |t| if (classify(t, node.kind(), child_in_enum, is_const)) |c| try b.emit(t, c.type, c.mods),
        };
    }

    fn emit(b: *Builder, t: tree.SyntaxToken, token_type: TokenType, mods: u32) Allocator.Error!void {
        const start = b.position(t.offset);
        const end = b.position(t.offset + t.text.len);
        // 跨行 token（理论上不会出现）不输出
        if (end.line != start.line) return;
        const delta_line = start.line - b.prev.line;
        const delta_char = if (delta_line == 0) start.character - b.prev.character else start.character;
        try b.data.appendSlice(b.arena, &.{ delta_line, delta_char, end.character - start.character, @backingInt(token_type), mods });
        b.prev = start;
    }

    fn position(b: *Builder, offset: usize) types.Position {
        b.cursor = b.lines.positionAfter(b.cursor_offset, b.cursor, offset, b.enc);
        b.cursor_offset = offset;
        return b.cursor;
    }
};

const Class = struct { type: TokenType, mods: u32 = 0 };

fn classify(t: tree.SyntaxToken, parent: SyntaxKind, in_enum: bool, parent_is_const: bool) ?Class {
    const decl = Modifier.declaration;
    switch (t.kind) {
        .line_comment => return .{ .type = .comment },
        .doc_comment, .container_doc_comment => return .{ .type = .comment, .mods = Modifier.documentation },
        .string_literal, .char_literal, .multiline_string_literal_line => return .{ .type = .string },
        .number_literal => return .{ .type = .number },
        .builtin => return .{ .type = .function, .mods = Modifier.defaultLibrary },
        .identifier => return switch (parent) {
            .fn_proto => .{ .type = .function, .mods = decl },
            .var_decl => .{ .type = .variable, .mods = decl | (if (parent_is_const) Modifier.readonly else 0) },
            .container_field => .{ .type = if (in_enum) .enumMember else .property, .mods = decl },
            .param => .{ .type = .parameter, .mods = decl },
            .payload => .{ .type = .variable, .mods = decl },
            .field_access, .field_init => .{ .type = .property },
            .enum_literal, .error_value => .{ .type = .enumMember },
            .error_set_decl => .{ .type = .enumMember, .mods = decl },
            .label, .break_label => .{ .type = .label },
            .name_ref => if (isPrimitiveType(t.text))
                .{ .type = .type, .mods = Modifier.defaultLibrary }
            else if (isPrimitiveValue(t.text))
                .{ .type = .keyword }
            else
                null,
            else => null,
        },
        else => {
            const tag = kind_mod.toTokenTag(t.kind) orelse return null;
            if (std.mem.startsWith(u8, @tagName(tag), "keyword_")) return .{ .type = .keyword };
            return null;
        },
    }
}

fn isPrimitiveValue(name: []const u8) bool {
    const values = std.StaticStringMap(void).initComptime(.{ .{"true"}, .{"false"}, .{"null"}, .{"undefined"} });
    return values.has(name);
}

/// 与 `std.zig.primitives` 一致的原始类型名
fn isPrimitiveType(name: []const u8) bool {
    if (std.zig.primitives.isPrimitive(name)) return !isPrimitiveValue(name);
    return false;
}

const testing = std.testing;
const Parse = @import("../syntax/Parse.zig");

test semanticTokens {
    const text = "/// d\nconst a: u32 = @min(x.y, .z);\nfn f(p: bool) void {}";
    const parse = try Parse.create(testing.allocator, text);
    defer parse.destroy();
    var lines = try offsets.LineIndex.init(testing.allocator, text);
    defer lines.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const data = try semanticTokens(arena.allocator(), parse.rootNode(), lines, .utf16);
    // 还原为 (行, 列, 长度, 类型)
    var line: u32 = 0;
    var col: u32 = 0;
    var got: std.ArrayList([4]u32) = .empty;
    var i: usize = 0;
    while (i < data.len) : (i += 5) {
        if (data[i] != 0) col = 0;
        line += data[i];
        col += data[i + 1];
        try got.append(arena.allocator(), .{ line, col, data[i + 2], data[i + 3] });
    }
    const T = TokenType;
    const expected = [_][4]u32{
        .{ 0, 0, 5, @backingInt(T.comment) }, // /// d
        .{ 1, 0, 5, @backingInt(T.keyword) }, // const
        .{ 1, 6, 1, @backingInt(T.variable) }, // a
        .{ 1, 9, 3, @backingInt(T.type) }, // u32
        .{ 1, 15, 4, @backingInt(T.function) }, // @min
        .{ 1, 22, 1, @backingInt(T.property) }, // y
        .{ 1, 26, 1, @backingInt(T.enumMember) }, // z
        .{ 2, 0, 2, @backingInt(T.keyword) }, // fn
        .{ 2, 3, 1, @backingInt(T.function) }, // f
        .{ 2, 5, 1, @backingInt(T.parameter) }, // p
        .{ 2, 8, 4, @backingInt(T.type) }, // bool
        .{ 2, 14, 4, @backingInt(T.type) }, // void
    };
    try testing.expectEqualSlices([4]u32, &expected, got.items);
}
