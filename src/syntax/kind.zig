//! CST 中 token 与节点的种类。
//!
//! token 种类与 `std.zig.Token.Tag` 一一对应（同名），另加 trivia（空白、普通注释）。

const std = @import("std");
const Tag = std.zig.Token.Tag;

pub const SyntaxKind = blk: {
    const tags = @typeInfo(Tag).@"enum".field_names;
    const extra_tokens = [_][:0]const u8{
        "whitespace",
        "line_comment",
        // 无法归类的字节（如 BOM），作为 trivia 保留以保证无损
        "unknown",
    };
    const nodes = node_kinds;
    var names: [tags.len + extra_tokens.len + nodes.len][:0]const u8 = undefined;
    var values: [names.len]u16 = undefined;
    for (tags, 0..) |name, i| names[i] = name;
    for (extra_tokens, tags.len..) |name, i| names[i] = name;
    for (nodes, tags.len + extra_tokens.len..) |name, i| names[i] = name;
    for (&values, 0..) |*v, i| v.* = i;
    break :blk @Enum(u16, .exhaustive, &names, &values);
};

/// 第一个节点种类的值；小于它的都是 token。
pub const first_node: u16 = @typeInfo(Tag).@"enum".field_names.len + 3;

pub fn isToken(kind: SyntaxKind) bool {
    return @backingInt(kind) < first_node;
}

pub fn isTrivia(kind: SyntaxKind) bool {
    return kind == .whitespace or kind == .line_comment or kind == .unknown;
}

pub fn fromTokenTag(tag: Tag) SyntaxKind {
    return @fromBackingInt(@as(u16, @backingInt(tag)));
}

/// 对应的 `std.zig.Token.Tag`；trivia 与节点种类返回 null。
pub fn toTokenTag(kind: SyntaxKind) ?Tag {
    const v = @backingInt(kind);
    if (v >= @typeInfo(Tag).@"enum".field_names.len) return null;
    return @fromBackingInt(@as(std.meta.BackingInt(Tag), @intCast(v)));
}

/// CST 节点种类。命名尽量对应 Zig 语法（langref Grammar）中的规则。
const node_kinds = [_][:0]const u8{
    // ── 顶层 / 容器 ──
    "source_file",
    "test_decl",
    "comptime_decl",
    "fn_decl",
    "var_decl",
    "container_field",
    "fn_proto",
    "param_list",
    "param",
    "align_clause",
    "addrspace_clause",
    "linksection_clause",
    "callconv_clause",

    // ── 语句 ──
    "block",
    "label",
    "expr_stmt",
    "defer_stmt",
    "errdefer_stmt",
    "suspend_stmt",
    "nosuspend_stmt",
    "comptime_stmt",
    "assign_expr",
    "destructure",

    // ── 控制流 ──
    "if_expr",
    "while_expr",
    "for_expr",
    "for_inputs",
    "for_input",
    "while_continue",
    "else_clause",
    "payload",
    "switch_expr",
    "switch_prong",
    "switch_case",
    "switch_item",
    "return_expr",
    "break_expr",
    "continue_expr",
    "break_label",
    "comptime_expr",
    "nosuspend_expr",
    "resume_expr",

    // ── 表达式 ──
    "binary_expr",
    "prefix_expr",
    "paren_expr",
    "name_ref",
    "literal",
    "builtin_call",
    "call_expr",
    "arg_list",
    "field_access",
    "index_expr",
    "slice_expr",
    "deref_expr",
    "unwrap_optional",
    "enum_literal",
    "error_value",
    "init_expr",
    "init_list",
    "field_init",
    "unreachable_expr",
    "anyframe_type",
    "anyframe_literal",

    // ── 类型表达式 ──
    "optional_type",
    "error_union_type",
    "ptr_type",
    "array_type",
    "slice_type",
    "sentinel",
    "error_set_decl",
    "container_decl",

    // ── 汇编 ──
    "asm_expr",
    "asm_output",
    "asm_input",
    "asm_clobbers",

    // 解析失败时包裹无法归类的 token
    "error_node",
};

test SyntaxKind {
    try std.testing.expect(isToken(fromTokenTag(.keyword_fn)));
    try std.testing.expectEqual(SyntaxKind.keyword_fn, fromTokenTag(.keyword_fn));
    try std.testing.expect(isToken(.unknown));
    try std.testing.expect(!isToken(.source_file));
    try std.testing.expectEqual(first_node, @backingInt(SyntaxKind.source_file));
}
