//! Upper-bound estimate of the recursion depth of the official parser and AstGen: live
//! diagnostics and formatting use it to decide whether to call the official implementation,
//! and on which thread.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// At or below this depth, the official implementation can be called on the current thread
/// (it recurses level by level, using about 16 KB of stack per level in Debug builds)
pub const inline_depth = 256;
/// Address space is plentiful on 64-bit platforms: the dedicated thread's stack and the two
/// depth limits below are scaled up 4x
const scale = if (@sizeOf(usize) >= 8) 4 else 1;
/// At or below this depth, parsing and AstGen (live diagnostics) run on a dedicated large-stack
/// thread; deeper text is skipped. Calibrated on common nesting forms (else-if chains,
/// if-expression chains, parentheses, calls, initializers, operator chains): `zig ast-check`
/// (46 MiB main-thread stack) can check up to 102400 levels; 4x that on 64-bit platforms
pub const thread_depth = 102400 * scale;
/// At or below this depth, formatting (parsing and rendering) runs on a dedicated large-stack
/// thread; deeper text is not formatted. Calibrated on common nesting forms: `zig fmt` (46 MiB
/// main-thread stack) can format up to 36864 levels (it formats deeper only for consecutive
/// prefix operators such as `!`, `?`, and `try`); 4x that on 64-bit platforms
pub const format_depth = 36864 * scale;
/// Upper limit of the dedicated thread's stack: enough, even in Debug builds, for AstGen at
/// `thread_depth` and formatting at `format_depth`
pub const thread_stack_size = 2 * 1024 * 1024 * 1024 * scale;

/// Stack of the dedicated thread for nesting depth `depth` (at most `limit`, i.e. `thread_depth`
/// or `format_depth`): proportional to `depth`, with `limit` mapping to `thread_stack_size`, and
/// at least 64 MiB. Shallower text does not map a huge stack: large mappings fail on systems
/// that do not allow memory overcommit. Rounded up to a multiple of the page size: macOS rejects
/// other stack sizes
pub fn threadStackSize(depth: u32, limit: u32) usize {
    const size = @max(64 * 1024 * 1024, @as(usize, thread_stack_size) / limit * depth);
    return std.mem.alignForward(usize, size, std.heap.page_size_max);
}

/// Upper-bound estimate of the recursion depth of the official parser and AstGen. Each level
/// of brackets counts as one level; within one bracket level, each token and bracket pair in a
/// segment separated by `;` or `,` may nest one level deeper (operator chains, prefixes and
/// suffixes, else-if chains). When `}` is followed by a new statement or declaration (an
/// identifier, a literal, or a keyword other than else and the like), the segment's count
/// restarts. Returns early once `limit` is exceeded
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

/// This token after `}` cannot continue an expression, only start a new statement or declaration
fn startsStatement(tag: std.zig.Token.Tag) bool {
    return switch (tag) {
        .keyword_else, .keyword_orelse, .keyword_catch, .keyword_and, .keyword_or => false,
        .identifier, .builtin, .number_literal, .string_literal, .multiline_string_literal_line, .char_literal, .doc_comment, .container_doc_comment => true,
        else => std.zig.Token.keywords.has(tag.lexeme() orelse return false),
    };
}

test "thread stack sizes are multiples of the page size, up to thread_stack_size" {
    for ([_]u32{ thread_depth, format_depth }) |limit| {
        var depth: u32 = 1;
        while (depth <= limit) : (depth += 997) {
            const size = threadStackSize(depth, limit);
            try std.testing.expect(std.mem.isAligned(size, std.heap.page_size_max));
            try std.testing.expect(size <= thread_stack_size);
        }
        try std.testing.expect(std.mem.isAligned(threadStackSize(limit, limit), std.heap.page_size_max));
    }
}
