//! The result of one parse: a copy of the source, the green tree, and the syntax errors, all
//! allocated in its own arena.
//!
//! Incremental reparse (`reparse`) reuses unchanged green nodes of the previous tree, so the new
//! result holds a reference to the old one (`base`), and the old arena is not freed while any
//! result still references it. To keep the chain from growing without bound, a full parse is done
//! instead once the memory accumulated along the chain exceeds twice that of the base full parse.

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

/// Whether source text is treated as Zig or as ZON
pub const Mode = enum { zig, zon };

/// `.zon` files are treated as ZON, all others as Zig
pub fn modeOf(path: []const u8) Mode {
    return if (std.mem.endsWith(u8, path, ".zon")) .zon else .zig;
}

arena: std.heap.ArenaAllocator,
gpa: Allocator,
mode: Mode,
source: [:0]const u8,
root: *const green.GreenNode,
errors: []const parser.Error,
/// Reference count: the query engine holds one; each incremental result built on this one holds one
refs: std.atomic.Value(u32) = .init(1),
/// The previous result whose nodes the incremental reparse reused
base: ?*Parse = null,
/// Total capacity of all arenas along the chain (including this one)
chain_bytes: usize,
/// Arena capacity of the full parse at the bottom of the chain
full_bytes: usize,

pub fn create(gpa: Allocator, text: []const u8, mode: Mode) Allocator.Error!*Parse {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const source = try a.dupeSentinel(u8, text, 0);
    const tokens = try lexer.tokenize(gpa, source);
    defer gpa.free(tokens);
    const events = switch (mode) {
        .zig => try runParser(gpa, source, tokens, grammar.sourceFile),
        .zon => try runParser(gpa, source, tokens, grammar.zonFile),
    };
    defer gpa.free(events.events);
    defer gpa.free(events.errors);

    var builder: green.Builder = .{ .arena = a, .gpa = gpa };
    defer builder.deinit();
    try parser.buildTree(&builder, source, tokens, events.events);
    const root = builder.finish();
    const errors = try a.dupe(parser.Error, events.errors);
    sortErrors(errors);

    const result = try a.create(Parse);
    result.* = .{
        .arena = undefined,
        .gpa = gpa,
        .mode = mode,
        .source = source,
        .root = root,
        .errors = errors,
        .chain_bytes = 0,
        .full_bytes = 0,
    };
    result.arena = arena;
    result.full_bytes = result.arena.queryCapacity();
    result.chain_bytes = result.full_bytes;
    return result;
}

/// Adds a reference (paired with `destroy`)
pub fn retain(self: *Parse) *Parse {
    _ = self.refs.fetchAdd(1, .monotonic);
    return self;
}

/// Releases a reference; the last release destroys the arena and releases the reference to base.
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

/// Parses new text based on `old`, in the same mode: when a local reparse is possible, reparses
/// only the affected block; otherwise does a full parse.
/// The result is exactly the same as `create(gpa, text, old.mode)`. A ZON file holds a single
/// expression and is usually small, so it is always parsed in full
pub fn reparse(gpa: Allocator, old: *Parse, text: []const u8) Allocator.Error!*Parse {
    if (old.mode == .zon) return create(gpa, text, .zon);
    if (try reparseBlock(gpa, old, text)) |p| return p;
    if (try reparseTopLevel(gpa, old, text)) |p| return p;
    return create(gpa, text, old.mode);
}

/// Whether two parse results have exactly the same mode, syntax tree and errors (used to verify
/// that incremental results match full ones)
pub fn sameAs(a: *const Parse, b: *const Parse) bool {
    if (a.mode != b.mode or !greenEql(a.root, b.root)) return false;
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

/// Sorts errors stably by offset so that full and incremental results are comparable
fn sortErrors(errors: []parser.Error) void {
    std.mem.sort(parser.Error, errors, {}, struct {
        fn lessThan(_: void, x: parser.Error, y: parser.Error) bool {
            return x.offset < y.offset;
        }
    }.lessThan);
}

// ── Local reparse ────────────────────────────────────────────────────

const Events = struct {
    events: []parser.Event,
    errors: []parser.Error,
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
        // The local reparse entry did not consume all tokens: let the caller treat it as a failure
        try p.errors.append(gpa, .{ .offset = p.currentOffset(), .message = unconsumed });
    }
    const events = try p.events.toOwnedSlice(gpa);
    errdefer gpa.free(events);
    return .{ .events = events, .errors = try p.errors.toOwnedSlice(gpa) };
}

const unconsumed = "block reparse: unconsumed tokens";

/// Nodes that can be reparsed on their own: the edit must lie strictly between their `{` and `}`
fn isReparsable(kind: SyntaxKind) bool {
    return kind == .block or kind == .container_decl;
}

/// Attempts only a local reparse; returns null when the conditions are not met (used by tests
/// and corpus cross-checks).
pub fn reparseBlock(gpa: Allocator, old: *Parse, text: []const u8) Allocator.Error!?*Parse {
    const old_text = old.source;
    // Edit range: the part outside the common prefix and suffix
    const prefix = std.mem.indexOfDiff(u8, old_text, text) orelse return null; // texts are identical
    var suffix: usize = 0;
    const max_suffix = @min(old_text.len, text.len) - prefix;
    while (suffix < max_suffix and old_text[old_text.len - 1 - suffix] == text[text.len - 1 - suffix]) suffix += 1;
    const edit_start: u32 = @intCast(prefix);
    const edit_end_old: u32 = @intCast(old_text.len - suffix);

    // Find the deepest reparsable node containing the edit range, and record the path from the
    // root to it (for the replacement)
    var path: std.ArrayList(PathEntry) = .empty;
    defer path.deinit(gpa);
    const target = try findTarget(gpa, old.rootNode(), edit_start, edit_end_old, &path) orelse return null;

    const delta: i64 = @as(i64, @intCast(text.len)) - @as(i64, @intCast(old_text.len));
    const old_range = target.range();
    const new_end: usize = @intCast(@as(i64, old_range.end) + delta);
    const node_text = text[old_range.start..new_end];

    // Memory reclamation: do a full parse instead when the chain gets too long
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
    if (!ok or !singleRoot(events.events, target.kind())) {
        arena.deinit();
        return null;
    }

    var builder: green.Builder = .{ .arena = a, .gpa = gpa };
    defer builder.deinit();
    try parser.buildTree(&builder, sub_source, tokens, events.events);
    var new_node = builder.finish();

    // Copy the ancestors on the path bottom-up, replacing the target node
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

    // Errors: errors inside the node can only lie within (start, end) (the node's first token
    // and `}` have both been consumed), so old errors at <= start or >= end come from outer
    // levels and are kept (shifted if after the node); inner ones are replaced by the new errors
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
        .mode = old.mode,
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

/// Edits at the top level (between declarations, comments at the end of the file, etc., not
/// inside any `{}`): reparses from the second top-level member before the edit position to the
/// end of the file, reusing the earlier top-level children as is. Top-level members are parsed
/// independently one by one, looking ahead at most one or two tokens; backing up one extra member
/// keeps every token seen by lookahead before the edit. Returns null when the conditions are not
/// met (the result is the same as a full parse). Does not apply to ZON, whose top level is one
/// expression rather than container members
pub fn reparseTopLevel(gpa: Allocator, old: *Parse, text: []const u8) Allocator.Error!?*Parse {
    if (old.mode == .zon) return null;
    const old_text = old.source;
    const edit_start: u32 = @intCast(std.mem.indexOfDiff(u8, old_text, text) orelse return null);
    if (old.chain_bytes > 2 * old.full_bytes) return null;

    // Top-level member nodes: start two members before the first one that ends after the edit
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
    // An earlier member's error may be reported at the cut point (e.g. a missing `;` is reported
    // at the next token): the reparse would not produce it again
    for (old.errors) |e| if (e.offset == from.start) return null;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const sub_source = try a.dupeSentinel(u8, text[from.start..], 0);
    const tokens = try lexer.tokenize(gpa, sub_source);
    defer gpa.free(tokens);
    // `//!` is a container doc comment only at the start of the file: the start of the fragment
    // is not the start of the file
    for (tokens) |t| if (t.kind == .container_doc_comment) {
        arena.deinit();
        return null;
    };
    const events = try runParser(gpa, sub_source, tokens, grammar.sourceFile);
    defer gpa.free(events.events);
    defer gpa.free(events.errors);

    var builder: green.Builder = .{ .arena = a, .gpa = gpa };
    defer builder.deinit();
    try parser.buildTree(&builder, sub_source, tokens, events.events);
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
        .mode = old.mode,
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

/// Deepest reparsable node with the edit strictly after its `{` and before its `}`
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
    // `}` must be the last token of the node (unclosed blocks are not eligible for local reparse)
    if (c.range().end != node.range().end) return false;
    return o.range().end <= start and end <= c.offset;
}

/// After the first `{` opens, the braces do not balance until the last token (which must be `}`)
fn bracesBalanced(tokens: []const lexer.Token) bool {
    var depth: i32 = 0;
    var opened = false;
    var last: ?lexer.Token = null;
    for (tokens) |t| {
        if (kind_mod.isTrivia(t.kind)) continue;
        if (opened and depth == 0) return false; // tokens remain after the braces balance
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

/// The event stream forms exactly one root node of the given kind
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
