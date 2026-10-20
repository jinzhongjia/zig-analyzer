//! 事件式解析器核心。
//!
//! 语法函数（grammar.zig）只产出事件：开始节点、消费 token、结束节点；不直接构造树。
//! 这使得「先解析左操作数，再发现它是二元表达式的一部分」可以通过 `CompletedMarker.precede`
//! 事后包一层父节点，而无需回溯。事件最终由 `buildTree` 转换为绿树，并挂上 trivia。

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const kind_mod = @import("kind.zig");
const SyntaxKind = kind_mod.SyntaxKind;
const lexer = @import("lexer.zig");
const green = @import("green.zig");
const TextRange = @import("tree.zig").TextRange;

pub const Event = union(enum) {
    start: struct {
        /// null 表示被放弃（tombstone）
        kind: ?SyntaxKind,
        /// 非 0 时表示事后为本节点包了父节点：父节点的 start 事件位于 `本事件下标 + forward_parent`
        forward_parent: u32 = 0,
    },
    finish,
    /// 消费下一个非 trivia token
    token,
};

pub const Error = struct {
    /// 出错位置的字节偏移
    offset: u32,
    message: []const u8,
};

/// 语法树的最大深度。更深的节点在构造绿树时展平：其 token 直接挂在这一层的节点下，这一层的节点改为
/// 错误节点（见 `buildTree`）。沿树递归的各处（HIR 降级、ItemTree、推导等）的递归深度因此有上限
pub const max_depth = 1024;
/// 解析器的递归上限，以未结束的节点个数计。未结束而之后被放弃的节点每层至多一个，到这里时所在位置
/// 在树中至少 `max_depth` 层深，不再递归解析的结构反正会被展平（见 `Parser.skipNested`）
pub const nesting_limit = 2 * max_depth;

pub const Parser = struct {
    gpa: Allocator,
    source: []const u8,
    tokens: []const lexer.Token,
    /// 非 trivia token 在 `tokens` 中的下标
    significant: []const u32,
    pos: u32 = 0,
    events: std.ArrayList(Event) = .empty,
    errors: std.ArrayList(Error) = .empty,
    /// 两次消费 token 之间查看 token 的次数上限：防止语法函数在不消费 token 的情况下无限循环
    fuel: u32 = max_fuel,
    /// 未结束的节点（已开始、尚未 complete 或 abandon 的 Marker）个数，语法函数的递归深度与之相当
    open: u32 = 0,
    /// 解析过程中 `open` 的最大值
    peak_open: u32 = 0,
    /// 有结构因嵌套超过 `nesting_limit` 而没有递归解析（见 `skipNested`）
    limited: bool = false,

    /// 在出错处逐层退出嵌套结构时，每层都会查看 token 而不消费，上限须远高于嵌套层数与每层查看次数之积
    const max_fuel = 1 << 24;

    pub fn deinit(p: *Parser) void {
        p.events.deinit(p.gpa);
        p.errors.deinit(p.gpa);
    }

    // ── 查看 token ──────────────────────────────────────────────────────

    /// 第 n 个尚未消费的非 trivia token 的种类；越界时为 eof。
    pub fn nth(p: *Parser, n: u32) SyntaxKind {
        if (p.fuel == 0) std.debug.panic("parser stuck at offset {d}", .{p.currentOffset()});
        p.fuel -= 1;
        const i = p.pos + n;
        if (i >= p.significant.len) return .eof;
        return p.tokens[p.significant[i]].kind;
    }

    pub fn peek(p: *Parser) SyntaxKind {
        return p.nth(0);
    }

    pub fn at(p: *Parser, kind: SyntaxKind) bool {
        return p.peek() == kind;
    }

    pub fn atAny(p: *Parser, kinds: []const SyntaxKind) bool {
        const k = p.peek();
        for (kinds) |candidate| if (k == candidate) return true;
        return false;
    }

    pub fn nthText(p: *Parser, n: u32) []const u8 {
        const i = p.pos + n;
        if (i >= p.significant.len) return "";
        return p.tokens[p.significant[i]].text(p.source);
    }

    pub fn atEof(p: *Parser) bool {
        return p.pos >= p.significant.len;
    }

    pub fn currentOffset(p: *const Parser) u32 {
        if (p.pos >= p.significant.len) return @intCast(p.source.len);
        return p.tokens[p.significant[p.pos]].start;
    }

    // ── 消费 token ──────────────────────────────────────────────────────

    pub fn bump(p: *Parser) Allocator.Error!void {
        assert(!p.atEof());
        p.pos += 1;
        p.fuel = max_fuel;
        try p.events.append(p.gpa, .token);
    }

    pub fn eat(p: *Parser, kind: SyntaxKind) Allocator.Error!bool {
        if (!p.at(kind)) return false;
        try p.bump();
        return true;
    }

    /// 期望当前 token 为 `kind`；不是时记录错误但不消费任何 token。
    pub fn expect(p: *Parser, comptime kind: SyntaxKind) Allocator.Error!bool {
        if (try p.eat(kind)) return true;
        try p.err(comptime expectedMessage(kind));
        return false;
    }

    pub fn err(p: *Parser, message: []const u8) Allocator.Error!void {
        try p.errors.append(p.gpa, .{ .offset = p.currentOffset(), .message = message });
    }

    /// 记录错误并把当前 token 包进 `error_node`（保证前进）。
    pub fn errBump(p: *Parser, message: []const u8) Allocator.Error!void {
        try p.err(message);
        if (p.atEof()) return;
        const m = try p.start();
        try p.bump();
        _ = try m.complete(p, .error_node);
    }

    /// 嵌套已达 `nesting_limit`：语法函数不再递归，改用 `skipNested`
    pub fn tooDeep(p: *const Parser) bool {
        return p.open >= nesting_limit;
    }

    /// 不递归地消费所在的结构：括号配平地前进到同一层的 `;`、`,` 或未配对的右括号之前（当前 token 是
    /// 左括号时到与它配对的右括号为止），包进一个错误节点。没有可消费的 token 时返回 null
    pub fn skipNested(p: *Parser) Allocator.Error!?CompletedMarker {
        p.limited = true;
        try p.err("nesting too deep");
        const group = isOpenBracket(p.peek());
        var m: ?Marker = null;
        var depth: u32 = 0;
        while (!p.atEof()) {
            const k = p.peek();
            if (isOpenBracket(k)) {
                depth += 1;
            } else if (k == .r_paren or k == .r_bracket or k == .r_brace) {
                if (depth == 0) break;
                depth -= 1;
            } else if (depth == 0 and (k == .semicolon or k == .comma)) break;
            if (m == null) m = try p.start();
            try p.bump();
            if (group and depth == 0) break;
        }
        return if (m) |marker| try marker.complete(p, .error_node) else null;
    }

    // ── Marker ──────────────────────────────────────────────────────────

    pub fn start(p: *Parser) Allocator.Error!Marker {
        const index: u32 = @intCast(p.events.items.len);
        try p.events.append(p.gpa, .{ .start = .{ .kind = null } });
        p.open += 1;
        p.peak_open = @max(p.peak_open, p.open);
        return .{ .index = index };
    }
};

fn isOpenBracket(kind: SyntaxKind) bool {
    return kind == .l_paren or kind == .l_bracket or kind == .l_brace;
}

pub const Marker = struct {
    index: u32,

    pub fn complete(m: Marker, p: *Parser, kind: SyntaxKind) Allocator.Error!CompletedMarker {
        p.events.items[m.index].start.kind = kind;
        try p.events.append(p.gpa, .finish);
        p.open -= 1;
        return .{ .index = m.index, .kind = kind };
    }

    /// 放弃本节点：已产生的子事件保留，直接成为外层节点的子元素。
    pub fn abandon(m: Marker, p: *Parser) void {
        p.open -= 1;
        if (m.index == p.events.items.len - 1) {
            _ = p.events.pop();
        } else {
            p.events.items[m.index] = .{ .start = .{ .kind = null } };
        }
    }
};

pub const CompletedMarker = struct {
    index: u32,
    kind: SyntaxKind,

    /// 在已完成的节点外面包一层新的父节点（返回父节点的 Marker）。
    pub fn precede(cm: CompletedMarker, p: *Parser) Allocator.Error!Marker {
        const parent = try p.start();
        p.events.items[cm.index].start.forward_parent = parent.index - cm.index;
        return parent;
    }
};

/// 把事件转换为绿树。trivia 规则：节点开始前的 trivia 挂在父节点上，
/// 因此节点总是以有效 token 开始；文件末尾的 trivia 挂在根节点上。
///
/// `base_depth` 为所构造的树的根在整棵树中的深度（局部重解析时不为 0）。深度达到 `max_depth` 的节点
/// 不开始，其内容直接挂在外层节点下。外层节点的子元素因此不再符合它的语法，改为错误节点，下游不会按
/// 原来的种类解读其中的 token。返回这些错误节点的区间（相对于 `source`，分配在 `builder.arena` 中）
pub fn buildTree(
    builder: *green.Builder,
    source: []const u8,
    tokens: []const lexer.Token,
    events: []Event,
    base_depth: usize,
) Allocator.Error![]const TextRange {
    var cursor: usize = 0;
    var parents: std.ArrayList(SyntaxKind) = .empty;
    defer parents.deinit(builder.gpa);
    // 已展平（未开始）而尚未结束的节点个数：它们总是最内层的几个
    var flattened: usize = 0;
    // 位于深度上限的未闭合节点（至多一个）的起点，以及它是否已收纳了展平的内容
    var limit_start: u32 = 0;
    var absorbing = false;
    var ranges: std.ArrayList(TextRange) = .empty;
    defer ranges.deinit(builder.gpa);

    for (events, 0..) |*event, i| switch (event.*) {
        .start => |s| {
            const kind = s.kind orelse continue;
            // 收集 forward_parent 链：最外层的父节点最先打开
            parents.clearRetainingCapacity();
            try parents.append(builder.gpa, kind);
            var idx = i;
            var fp = s.forward_parent;
            while (fp != 0) {
                idx += fp;
                const parent = &events[idx].start;
                try parents.append(builder.gpa, parent.kind.?);
                fp = parent.forward_parent;
                parent.* = .{ .kind = null };
            }
            if (builder.depth() > 0) cursor = try emitTrivia(builder, source, tokens, cursor);
            var j = parents.items.len;
            while (j > 0) {
                j -= 1;
                if (flattened > 0 or base_depth + builder.depth() >= max_depth) {
                    if (!absorbing) {
                        builder.retype(.error_node);
                        absorbing = true;
                    }
                    flattened += 1;
                } else {
                    try builder.startNode(parents.items[j]);
                    if (base_depth + builder.depth() == max_depth) limit_start = emittedEnd(source, tokens, cursor);
                }
            }
        },
        .finish => {
            if (flattened > 0) {
                flattened -= 1;
                continue;
            }
            if (builder.depth() == 1) {
                // 关闭根节点前挂上剩余的全部 token（只可能是 trivia）
                while (cursor < tokens.len) : (cursor += 1) {
                    const t = tokens[cursor];
                    try builder.token(t.kind, t.text(source));
                }
            }
            if (absorbing) {
                absorbing = false;
                try ranges.append(builder.gpa, .{ .start = limit_start, .end = emittedEnd(source, tokens, cursor) });
            }
            try builder.finishNode();
        },
        .token => {
            cursor = try emitTrivia(builder, source, tokens, cursor);
            const t = tokens[cursor];
            assert(!kind_mod.isTrivia(t.kind));
            try builder.token(t.kind, t.text(source));
            cursor += 1;
        },
    };
    return builder.arena.dupe(TextRange, ranges.items);
}

/// 已挂上的 token 在源码中的终点：token 首尾相接，即下一个 token 的起点
fn emittedEnd(source: []const u8, tokens: []const lexer.Token, cursor: usize) u32 {
    return if (cursor < tokens.len) tokens[cursor].start else @intCast(source.len);
}

fn emitTrivia(builder: *green.Builder, source: []const u8, tokens: []const lexer.Token, start: usize) Allocator.Error!usize {
    var cursor = start;
    while (cursor < tokens.len and kind_mod.isTrivia(tokens[cursor].kind)) : (cursor += 1) {
        try builder.token(tokens[cursor].kind, tokens[cursor].text(source));
    }
    return cursor;
}

fn expectedMessage(comptime kind: SyntaxKind) []const u8 {
    const lexeme = if (kind_mod.toTokenTag(kind)) |tag| tag.lexeme() else null;
    return if (lexeme) |l| "expected '" ++ l ++ "'" else "expected " ++ @tagName(kind);
}
