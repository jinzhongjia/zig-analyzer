//! 官方解析器与 AstGen 递归深度的上界估计：live 诊断与格式化据此决定是否调用官方实现、在哪个线程上调用。

const std = @import("std");
const Allocator = std.mem.Allocator;

/// 不超过它时可以在当前线程调用官方实现（逐层递归，Debug 构建中每层约用 16 KB 栈）
pub const inline_depth = 256;
/// 不超过它时在专用的大栈线程上做解析与 AstGen（live 诊断），更深的文本不做。按常见的嵌套形式（else-if
/// 链、if 表达式链、括号、调用、初始化、运算符链）标定：比它更深时 `zig ast-check`（主线程栈 46 MiB）同样耗尽栈
pub const thread_depth = 102400;
/// 不超过它时在专用的大栈线程上格式化（解析与渲染），更深的文本不格式化。按常见的嵌套形式标定：比它更深时
/// `zig fmt`（主线程栈 46 MiB）同样耗尽栈，只有连续的前缀运算符（`!`、`?`、`try` 等）它能格式化得更深
pub const format_depth = 36864;
/// 专用线程的栈大小：Debug 构建中也足以做到 `thread_depth` 的 AstGen 与 `format_depth` 的格式化
pub const thread_stack_size = 2 * 1024 * 1024 * 1024;

/// 官方解析器与 AstGen 递归深度的上界估计。每层括号算一层；同一层括号内，以 `;` 或 `,` 分隔的一段中
/// 每个 token 与括号对都可能使嵌套再深一层（运算符链、前缀与后缀、else-if 链）。`}` 之后接着的是新的
/// 语句或声明（标识符、字面量、else 等之外的关键字）时，这一段重新计数。超过 `limit` 时提前返回
pub fn estimate(gpa: Allocator, source: [:0]const u8, limit: u32) Allocator.Error!u32 {
    var segments: std.ArrayList(u32) = .empty;
    defer segments.deinit(gpa);
    try segments.append(gpa, 0);
    var tokenizer: std.zig.Tokenizer = .init(source);
    var total: u32 = 0;
    var max: u32 = 0;
    var after_brace = false;
    while (true) {
        const tag = tokenizer.next().tag;
        if (tag == .eof) return max;
        const top = &segments.items[segments.items.len - 1];
        if (after_brace and startsStatement(tag)) {
            total -= top.*;
            top.* = 0;
        }
        after_brace = false;
        switch (tag) {
            .l_paren, .l_bracket, .l_brace => {
                top.* += 1;
                total += 2;
                try segments.append(gpa, 0);
            },
            .r_paren, .r_bracket, .r_brace => {
                if (segments.items.len > 1) total -= 1 + segments.pop().?;
                after_brace = tag == .r_brace;
            },
            .semicolon, .comma => {
                total -= top.*;
                top.* = 0;
            },
            else => {
                top.* += 1;
                total += 1;
            },
        }
        max = @max(max, total);
        if (max > limit) return max;
    }
}

/// `}` 之后的这个 token 不能接续表达式，只能开始新的语句或声明
fn startsStatement(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .keyword_else, .keyword_orelse, .keyword_catch, .keyword_and, .keyword_or => false,
        .identifier, .builtin, .number_literal, .string_literal, .multiline_string_literal_line, .char_literal, .doc_comment, .container_doc_comment => true,
        else => std.zig.Token.keywords.has(tag.lexeme() orelse return false),
    };
}
