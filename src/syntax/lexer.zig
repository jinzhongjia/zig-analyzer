//! 无损词法分析：复用 `std.zig.Tokenizer` 得到与编译器一致的 token，
//! 再把 token 之间的空隙切分为 trivia（空白、普通注释），保证所有 token 拼接后等于原文。

const std = @import("std");
const Allocator = std.mem.Allocator;
const kind_mod = @import("kind.zig");
const SyntaxKind = kind_mod.SyntaxKind;

pub const Token = struct {
    kind: SyntaxKind,
    start: u32,
    len: u32,

    pub fn text(t: Token, source: []const u8) []const u8 {
        return source[t.start..][0..t.len];
    }
};

/// 返回全部 token（含 trivia，不含 eof），调用方拥有内存。
pub fn tokenize(gpa: Allocator, source: [:0]const u8) Allocator.Error![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(gpa);
    // 经验值：每 8 字节约一个 token，trivia 约占一半
    try tokens.ensureTotalCapacity(gpa, source.len / 4 + 16);

    var tokenizer: std.zig.Tokenizer = .init(source);
    var pos: usize = 0;
    while (true) {
        const tok = tokenizer.next();
        try splitTrivia(gpa, &tokens, source, pos, tok.loc.start);
        if (tok.tag == .eof) {
            pos = tok.loc.start;
            break;
        }
        try tokens.append(gpa, .{
            .kind = kind_mod.fromTokenTag(tok.tag),
            .start = @intCast(tok.loc.start),
            .len = @intCast(tok.loc.end - tok.loc.start),
        });
        pos = tok.loc.end;
    }
    // 源码中间出现 0 字节时 tokenizer 会提前结束，剩余部分作为 unknown 保留
    if (pos < source.len) try tokens.append(gpa, .{ .kind = .unknown, .start = @intCast(pos), .len = @intCast(source.len - pos) });
    return tokens.toOwnedSlice(gpa);
}

fn splitTrivia(gpa: Allocator, tokens: *std.ArrayList(Token), source: []const u8, start: usize, end: usize) Allocator.Error!void {
    var i = start;
    while (i < end) {
        const begin = i;
        const kind: SyntaxKind = if (isSpace(source[i])) blk: {
            while (i < end and isSpace(source[i])) i += 1;
            break :blk .whitespace;
        } else if (std.mem.startsWith(u8, source[i..end], "//")) blk: {
            i = std.mem.indexOfScalarPos(u8, source[0..end], i, '\n') orelse end;
            break :blk .line_comment;
        } else blk: {
            while (i < end and !isSpace(source[i]) and !std.mem.startsWith(u8, source[i..end], "//")) i += 1;
            break :blk .unknown;
        };
        try tokens.append(gpa, .{ .kind = kind, .start = @intCast(begin), .len = @intCast(i - begin) });
    }
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

const testing = std.testing;

fn expectLossless(source: [:0]const u8) !void {
    const tokens = try tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var pos: u32 = 0;
    for (tokens) |t| {
        try testing.expectEqual(pos, t.start);
        pos += t.len;
    }
    try testing.expectEqual(source.len, pos);
}

test "trivia splitting" {
    const source = "const a = 1; // hi\n/// doc\nfn f() void {}\n";
    const tokens = try tokenize(testing.allocator, source);
    defer testing.allocator.free(tokens);
    var kinds: std.ArrayList(SyntaxKind) = .empty;
    defer kinds.deinit(testing.allocator);
    for (tokens) |t| try kinds.append(testing.allocator, t.kind);
    try testing.expectEqualSlices(SyntaxKind, &.{
        .keyword_const,  .whitespace, .identifier, .whitespace,   .equal,      .whitespace,
        .number_literal, .semicolon,  .whitespace, .line_comment, .whitespace, .doc_comment,
        .whitespace,     .keyword_fn, .whitespace, .identifier,   .l_paren,    .r_paren,
        .whitespace,     .identifier, .whitespace, .l_brace,      .r_brace,    .whitespace,
    }, kinds.items);
}

test "lossless: BOM, invalid characters, embedded NUL, CRLF" {
    try expectLossless("\xEF\xBB\xBFconst x = 1;");
    try expectLossless("const x = $;\r\n// c\r\n");
    try expectLossless("a\x00b c");
    try expectLossless("\"unterminated\nnext");
    try expectLossless("");
}
