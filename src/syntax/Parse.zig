//! 一次解析的结果：源码副本、绿树与语法错误，全部分配在自己的 arena 中。
//!
//! 增量重解析（`reparse`）会复用上一棵树中未改动的绿节点，因此新结果持有旧结果的引用
//! （`base`），旧 arena 在没有任何结果引用它之前不会释放。为避免链条无限增长，
//! 链上累计内存超过基准全量解析的 2 倍时改做全量解析。

const std = @import("std");
const Allocator = std.mem.Allocator;

const kind_mod = @import("kind.zig");
const SyntaxKind = kind_mod.SyntaxKind;
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const grammar = @import("grammar.zig");
const green = @import("green.zig");
const tree = @import("tree.zig");

const Parse = @This();

arena: std.heap.ArenaAllocator,
gpa: Allocator,
source: [:0]const u8,
root: *const green.GreenNode,
errors: []const parser.Error,
/// 引用计数：查询引擎持有一份，每个以本结果为基础的增量结果各持有一份
refs: std.atomic.Value(u32) = .init(1),
/// 增量重解析时复用了其节点的上一个结果
base: ?*Parse = null,
/// 链上（含自身）所有 arena 的容量之和
chain_bytes: usize,
/// 链底全量解析的 arena 容量
full_bytes: usize,
/// 解析触及了深度上限：有结构没有递归解析（`Parser.skipNested`），或构造时展平了节点。
/// 这样的结果与局部重解析的结果无法保证一致，之后的编辑都做全量解析
deep: bool = false,
/// 收纳了展平内容的错误节点的区间（见 `parser.buildTree`），按位置排序。其中的代码没有语法结构，
/// 名字解析与类型推导都看不到
flattened: []const tree.TextRange = &.{},

pub fn create(gpa: Allocator, text: []const u8) Allocator.Error!*Parse {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const source = try a.dupeSentinel(u8, text, 0);
    const tokens = try lexer.tokenize(gpa, source);
    defer gpa.free(tokens);
    const events = try runParser(gpa, source, tokens, grammar.sourceFile);
    defer gpa.free(events.events);
    defer gpa.free(events.errors);

    var builder: green.Builder = .{ .arena = a, .gpa = gpa };
    defer builder.deinit();
    const flattened = try parser.buildTree(&builder, source, tokens, events.events, 0);
    const root = builder.finish();
    const errors = try a.dupe(parser.Error, events.errors);
    sortErrors(errors);

    const result = try a.create(Parse);
    result.* = .{
        .arena = undefined,
        .gpa = gpa,
        .source = source,
        .root = root,
        .errors = errors,
        .chain_bytes = 0,
        .full_bytes = 0,
        .deep = events.limited or flattened.len != 0,
        .flattened = flattened,
    };
    result.arena = arena;
    result.full_bytes = result.arena.queryCapacity();
    result.chain_bytes = result.full_bytes;
    return result;
}

/// 增加一份引用（与 `destroy` 配对）
pub fn retain(self: *Parse) *Parse {
    _ = self.refs.fetchAdd(1, .monotonic);
    return self;
}

/// 释放一份引用；最后一份引用释放时销毁 arena 并释放对 base 的引用。
pub fn destroy(self: *Parse) void {
    if (self.refs.fetchSub(1, .acq_rel) != 1) return;
    const base = self.base;
    var arena = self.arena;
    arena.deinit();
    if (base) |b| b.destroy();
}

pub fn rootNode(self: *const Parse) tree.SyntaxNode {
    return .{ .green = self.root, .offset = 0 };
}

/// 以 `old` 为基础解析新文本：能局部重解析时只重解析受影响的代码块，否则全量解析。
/// 结果与 `create(gpa, text)` 完全相同。
pub fn reparse(gpa: Allocator, old: *Parse, text: []const u8) Allocator.Error!*Parse {
    if (try reparseBlock(gpa, old, text)) |p| return p;
    if (try reparseTopLevel(gpa, old, text)) |p| return p;
    return create(gpa, text);
}

/// 两个解析结果的语法树与错误完全相同（用于校验增量结果与全量结果一致）
pub fn sameAs(a: *const Parse, b: *const Parse) bool {
    if (!greenEql(a.root, b.root)) return false;
    if (a.errors.len != b.errors.len) return false;
    for (a.errors, b.errors) |x, y| {
        if (x.offset != y.offset or !std.mem.eql(u8, x.message, y.message)) return false;
    }
    return true;
}

fn greenEql(a: *const green.GreenNode, b: *const green.GreenNode) bool {
    if (a == b) return true;
    if (a.kind != b.kind or a.text_len != b.text_len or a.children.len != b.children.len) return false;
    for (a.children, b.children) |x, y| switch (x.unpack()) {
        .node => |n| if (y.node() == null or !greenEql(n, y.node().?)) return false,
        .token => |t| if (y.is_node or t.kind != y.kind() or !std.mem.eql(u8, t.text, y.unpack().token.text)) return false,
    };
    return true;
}

/// 错误按偏移稳定排序，使全量与增量结果可比较
fn sortErrors(errors: []parser.Error) void {
    std.mem.sort(parser.Error, errors, {}, struct {
        fn lessThan(_: void, x: parser.Error, y: parser.Error) bool {
            return x.offset < y.offset;
        }
    }.lessThan);
}

// ── 局部重解析 ───────────────────────────────────────────────────────

const Events = struct {
    events: []parser.Event,
    errors: []parser.Error,
    /// 见 `Parser.limited`
    limited: bool,
    /// 见 `Parser.peak_open`
    peak_open: u32,
};

fn runParser(gpa: Allocator, source: []const u8, tokens: []const lexer.Token, comptime entry: anytype) Allocator.Error!Events {
    var significant: std.ArrayList(u32) = .empty;
    defer significant.deinit(gpa);
    for (tokens, 0..) |t, i| {
        if (!kind_mod.isTrivia(t.kind)) try significant.append(gpa, @intCast(i));
    }
    var p: parser.Parser = .{ .gpa = gpa, .source = source, .tokens = tokens, .significant = significant.items };
    defer p.deinit();
    try entry(&p);
    if (!p.atEof()) {
        // 局部重解析入口未消费全部 token：交由调用方判定失败
        try p.errors.append(gpa, .{ .offset = p.currentOffset(), .message = unconsumed });
    }
    const events = try p.events.toOwnedSlice(gpa);
    errdefer gpa.free(events);
    return .{ .events = events, .errors = try p.errors.toOwnedSlice(gpa), .limited = p.limited, .peak_open = p.peak_open };
}

const unconsumed = "block reparse: unconsumed tokens";

/// 可以独立重解析的节点：编辑必须严格位于其 `{` 与 `}` 之间
fn isReparsable(kind: SyntaxKind) bool {
    return kind == .block or kind == .container_decl;
}

/// 只尝试局部重解析，不满足条件时返回 null（测试与语料对拍使用）。
pub fn reparseBlock(gpa: Allocator, old: *Parse, text: []const u8) Allocator.Error!?*Parse {
    if (old.deep) return null;
    const old_text = old.source;
    // 编辑区间：公共前缀与后缀之外的部分
    const prefix = std.mem.indexOfDiff(u8, old_text, text) orelse return null; // 文本相同
    var suffix: usize = 0;
    const max_suffix = @min(old_text.len, text.len) - prefix;
    while (suffix < max_suffix and old_text[old_text.len - 1 - suffix] == text[text.len - 1 - suffix]) suffix += 1;
    const edit_start: u32 = @intCast(prefix);
    const edit_end_old: u32 = @intCast(old_text.len - suffix);

    // 找到包含编辑区间的最深可重解析节点，并记录根到它的路径（用于替换）
    var path: std.ArrayList(PathEntry) = .empty;
    defer path.deinit(gpa);
    const target = try findTarget(gpa, old.rootNode(), edit_start, edit_end_old, &path) orelse return null;

    const delta: i64 = @as(i64, @intCast(text.len)) - @as(i64, @intCast(old_text.len));
    const old_range = target.range();
    const new_end: usize = @intCast(@as(i64, old_range.end) + delta);
    const node_text = text[old_range.start..new_end];

    // 内存回收：链条过长时改做全量解析
    if (old.chain_bytes > 2 * old.full_bytes) return null;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const sub_source = try a.dupeSentinel(u8, node_text, 0);
    const tokens = try lexer.tokenize(gpa, sub_source);
    defer gpa.free(tokens);
    if (!bracesBalanced(tokens)) {
        arena.deinit();
        return null;
    }

    const events = switch (target.kind()) {
        .block => try runParser(gpa, sub_source, tokens, entryBlock),
        .container_decl => try runParser(gpa, sub_source, tokens, entryContainer),
        else => unreachable,
    };
    defer gpa.free(events.events);
    defer gpa.free(events.errors);
    const ok = for (events.errors) |e| {
        if (e.message.ptr == unconsumed.ptr) break false;
    } else true;
    // 嵌套接近上限：全量解析时目标节点外层还有未结束的节点（每个祖先至多再带一个之后放弃的节点），
    // 可能在这里触及上限而得到不同的结果
    const near_limit = events.limited or events.peak_open + 2 * path.items.len >= parser.nesting_limit;
    if (!ok or near_limit or !singleRoot(events.events, target.kind())) {
        arena.deinit();
        return null;
    }

    var builder: green.Builder = .{ .arena = a, .gpa = gpa };
    defer builder.deinit();
    if ((try parser.buildTree(&builder, sub_source, tokens, events.events, path.items.len)).len != 0) {
        arena.deinit();
        return null;
    }
    var new_node = builder.finish();

    // 自底向上复制路径上的祖先，替换目标节点
    var i = path.items.len;
    while (i > 0) {
        i -= 1;
        const entry = path.items[i];
        const children = try a.dupe(green.GreenElement, entry.node.children);
        children[entry.child] = .initNode(new_node);
        const copy = try a.create(green.GreenNode);
        copy.* = .{
            .kind = entry.node.kind,
            .text_len = @intCast(@as(i64, entry.node.text_len) + delta),
            .children = children,
        };
        new_node = copy;
    }

    // 错误：节点内部的错误只可能位于 (start, end) 之间（节点首个 token 与 `}` 都已消费），
    // 因此 <= start 与 >= end 的旧错误来自外层，保留（之后的平移）；内部的换成新错误
    var errors: std.ArrayList(parser.Error) = .empty;
    for (old.errors) |e| {
        if (e.offset <= old_range.start) {
            try errors.append(a, e);
        } else if (e.offset >= old_range.end) {
            try errors.append(a, .{ .offset = @intCast(@as(i64, e.offset) + delta), .message = e.message });
        }
    }
    for (events.errors) |e| try errors.append(a, .{ .offset = e.offset + old_range.start, .message = e.message });
    sortErrors(errors.items);

    const result = try a.create(Parse);
    result.* = .{
        .arena = undefined,
        .gpa = gpa,
        .source = try a.dupeSentinel(u8, text, 0),
        .root = new_node,
        .errors = errors.items,
        .base = old,
        .chain_bytes = 0,
        .full_bytes = old.full_bytes,
    };
    result.arena = arena;
    result.chain_bytes = old.chain_bytes + result.arena.queryCapacity();
    _ = old.retain();
    return result;
}

/// 顶层的编辑（声明之间、文件末尾的注释等，不在任何 `{}` 之内）：从编辑位置之前第二个顶层成员起
/// 重解析到文件末尾，之前的顶层子节点原样复用。顶层成员逐个独立解析，向前看至多一两个 token；
/// 多退一个成员使被向前看到的 token 都在编辑之前。不满足条件时返回 null（结果与全量解析相同）
pub fn reparseTopLevel(gpa: Allocator, old: *Parse, text: []const u8) Allocator.Error!?*Parse {
    if (old.deep) return null;
    const old_text = old.source;
    const edit_start: u32 = @intCast(std.mem.indexOfDiff(u8, old_text, text) orelse return null);
    if (old.chain_bytes > 2 * old.full_bytes) return null;

    // 顶层的成员节点：第一个结束于编辑之后的成员之前再退两个
    const root = old.rootNode();
    var nodes: std.ArrayList(struct { child: usize, start: u32 }) = .empty;
    defer nodes.deinit(gpa);
    var first_after: ?usize = null;
    {
        var it = root.children();
        var index: usize = 0;
        while (it.next()) |e| : (index += 1) {
            if (e != .node) continue;
            const r = e.node.range();
            if (first_after == null and r.end > edit_start) first_after = nodes.items.len;
            try nodes.append(gpa, .{ .child = index, .start = r.start });
        }
    }
    const k = first_after orelse nodes.items.len;
    if (k < 2) return null;
    const from = nodes.items[k - 2];
    // 更早的成员的错误可能报在切点上（如缺少 `;` 报在下一个 token）：重解析不会再产生它
    for (old.errors) |e| if (e.offset == from.start) return null;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const sub_source = try a.dupeSentinel(u8, text[from.start..], 0);
    const tokens = try lexer.tokenize(gpa, sub_source);
    defer gpa.free(tokens);
    // `//!` 只在文件开头作为容器文档注释：片段的开头不是文件开头
    for (tokens) |t| if (t.kind == .container_doc_comment) {
        arena.deinit();
        return null;
    };
    const events = try runParser(gpa, sub_source, tokens, grammar.sourceFile);
    defer gpa.free(events.events);
    defer gpa.free(events.errors);

    var builder: green.Builder = .{ .arena = a, .gpa = gpa };
    defer builder.deinit();
    // 片段与全量解析从同一层开始，触及深度上限时结果也相同；之后的编辑仍须全量解析，这里直接放弃
    if (events.limited or (try parser.buildTree(&builder, sub_source, tokens, events.events, 0)).len != 0) {
        arena.deinit();
        return null;
    }
    const tail = builder.finish();

    const children = try a.alloc(green.GreenElement, from.child + tail.children.len);
    @memcpy(children[0..from.child], old.root.children[0..from.child]);
    @memcpy(children[from.child..], tail.children);
    const new_root = try a.create(green.GreenNode);
    new_root.* = .{ .kind = old.root.kind, .text_len = from.start + tail.text_len, .children = children };

    var errors: std.ArrayList(parser.Error) = .empty;
    for (old.errors) |e| if (e.offset < from.start) try errors.append(a, e);
    for (events.errors) |e| try errors.append(a, .{ .offset = e.offset + from.start, .message = e.message });
    sortErrors(errors.items);

    const result = try a.create(Parse);
    result.* = .{
        .arena = undefined,
        .gpa = gpa,
        .source = try a.dupeSentinel(u8, text, 0),
        .root = new_root,
        .errors = errors.items,
        .base = old,
        .chain_bytes = 0,
        .full_bytes = old.full_bytes,
    };
    result.arena = arena;
    result.chain_bytes = old.chain_bytes + result.arena.queryCapacity();
    _ = old.retain();
    return result;
}

const PathEntry = struct { node: *const green.GreenNode, child: usize };

/// 最深的、编辑严格位于 `{` 之后、`}` 之前的可重解析节点
fn findTarget(gpa: Allocator, root: tree.SyntaxNode, start: u32, end: u32, path: *std.ArrayList(PathEntry)) Allocator.Error!?tree.SyntaxNode {
    var best: ?tree.SyntaxNode = null;
    var best_depth: usize = 0;
    var node = root;
    outer: while (true) {
        if (isReparsable(node.kind()) and editInsideBraces(node, start, end)) {
            best = node;
            best_depth = path.items.len;
        }
        var it = node.children();
        var index: usize = 0;
        while (it.next()) |e| : (index += 1) {
            if (e != .node) continue;
            const r = e.node.range();
            if (r.start <= start and end <= r.end) {
                try path.append(gpa, .{ .node = node.green, .child = index });
                node = e.node;
                continue :outer;
            }
        }
        break;
    }
    path.shrinkRetainingCapacity(best_depth);
    return best;
}

fn editInsideBraces(node: tree.SyntaxNode, start: u32, end: u32) bool {
    var open: ?tree.SyntaxToken = null;
    var close: ?tree.SyntaxToken = null;
    var it = node.children();
    while (it.next()) |e| if (e == .token) switch (e.token.kind) {
        .l_brace => if (open == null) {
            open = e.token;
        },
        .r_brace => close = e.token,
        else => {},
    };
    const o = open orelse return false;
    const c = close orelse return false;
    // `}` 必须是节点的最后一个 token（未闭合的块不参与局部重解析）
    if (c.range().end != node.range().end) return false;
    return o.range().end <= start and end <= c.offset;
}

/// 第一个 `{` 打开后，花括号直到最后一个 token（必须是 `}`）才恰好配平
fn bracesBalanced(tokens: []const lexer.Token) bool {
    var depth: i32 = 0;
    var opened = false;
    var last: ?lexer.Token = null;
    for (tokens) |t| {
        if (kind_mod.isTrivia(t.kind)) continue;
        if (opened and depth == 0) return false; // 配平之后还有 token
        switch (t.kind) {
            .l_brace => {
                depth += 1;
                opened = true;
            },
            .r_brace => {
                depth -= 1;
                if (depth < 0) return false;
            },
            else => {},
        }
        last = t;
    }
    const l = last orelse return false;
    return opened and depth == 0 and l.kind == .r_brace;
}

/// 事件流恰好构成一个指定种类的根节点
fn singleRoot(events: []const parser.Event, kind: SyntaxKind) bool {
    if (events.len == 0) return false;
    const first = events[0];
    if (first != .start or first.start.kind != kind or first.start.forward_parent != 0) return false;
    var depth: usize = 0;
    for (events, 0..) |e, i| switch (e) {
        .start => |s| if (s.kind != null) {
            depth += 1;
        },
        .finish => {
            depth -= 1;
            if (depth == 0 and i != events.len - 1) return false;
        },
        .token => {},
    };
    return depth == 0;
}

fn entryBlock(p: *parser.Parser) Allocator.Error!void {
    _ = try grammar.blockExpr(p);
}

fn entryContainer(p: *parser.Parser) Allocator.Error!void {
    _ = try grammar.containerDecl(p);
}

test {
    _ = @import("parse_test.zig");
    _ = @import("reparse_test.zig");
    _ = @import("parse_fuzz.zig");
}
