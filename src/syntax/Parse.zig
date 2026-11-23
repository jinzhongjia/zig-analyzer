//! The result of one parse: the source, the green tree, and the syntax errors, all in its own
//! arena; the source is a copy in the arena or a retained buffer of the file text.
//!
//! Incremental reparse (`reparse`) reuses unchanged green nodes of the previous tree, so the new
//! result holds a reference to the old one (`base`), and the old arena is not freed while any
//! result still references it. To keep the chain from growing without bound, a full parse is done
//! instead once the memory accumulated along the chain exceeds twice that of the base full parse.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Text = @import("../util/Text.zig");
const vector = @import("../util/vector.zig");
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

/// The rules that differ between the supported Zig versions: syntax here, type layouts in
/// `InternPool.Target`, and the versions named in builtin documentation in `builtins.documentation`
pub const Dialect = enum {
    /// Accepts doc comments on the variadic marker `...`
    zig_0_17_0,
    zig_0_17_1,

    pub const latest: Dialect = .zig_0_17_1;

    /// The dialect of a zig version; any other version than those above follows the latest
    pub fn of(version: []const u8) Dialect {
        return if (std.mem.eql(u8, version, "0.17.0")) .zig_0_17_0 else .latest;
    }
};

arena: std.heap.ArenaAllocator,
gpa: Allocator,
mode: Mode,
dialect: Dialect,
source: [:0]const u8,
root: *const green.GreenNode,
errors: []const parser.Error,
/// Reference count: the query engine holds one; each incremental result built on this one holds one
refs: std.atomic.Value(u32) = .init(1),
/// The references that may read `source` (all but those of the results built on this one)
users: std.atomic.Value(u32) = .init(1),
/// `source` is freed with the last user instead of with the arena: the tokens of an incremental
/// result point into the reparsed fragments, never into `source`, so the results built on it
/// need only its arena. Otherwise every result along a chain would keep a copy of the whole text.
/// A full parse's tokens point into its `source`, which then lives as long as the arena
owns_source: bool = false,
/// The file text buffer `source` points into, retained; null when `source` is in the arena
shared: ?*Text = null,
/// The previous result whose nodes the incremental reparse reused
base: ?*Parse = null,
/// Total capacity of all arenas along the chain (including this one)
chain_bytes: usize,
/// Bytes of the shared text buffer of the full parse at the bottom of the chain: the results built
/// on it keep that buffer alive until the arena is destroyed (see `release`), while their own
/// sources are freed with their last user
base_source_bytes: usize = 0,
/// Arena capacity of the full parse at the bottom of the chain
full_bytes: usize,
/// Unique among all parse results of the process (never reused), so that a value derived from one
/// result can tell whether that result is still alive in another result's chain (see `inChain`)
id: u64,

var next_id: std.atomic.Value(u64) = .init(1);

fn newId() u64 {
    return next_id.fetchAdd(1, .monotonic);
}

/// The result with id `id` among `self` and the results it was built on (`base`), which it keeps
/// alive: the green nodes of that result can be compared with those of `self` by pointer. Only
/// its tree may be read: the `source` of a result built on may already be freed
pub fn inChain(self: *const Parse, id: u64) ?*const Parse {
    var p: ?*const Parse = self;
    while (p) |x| : (p = x.base) if (x.id == id) return x;
    return null;
}

pub fn create(gpa: Allocator, text: []const u8, mode: Mode) Allocator.Error!*Parse {
    return createIn(gpa, text, mode, .latest);
}

pub fn createIn(gpa: Allocator, text: []const u8, mode: Mode, dialect: Dialect) Allocator.Error!*Parse {
    return createSource(gpa, .{ .copy = text }, mode, dialect);
}

/// A parse of `text` that shares the buffer of the file text instead of copying it: the result
/// retains the buffer until it is destroyed
pub fn createInShared(gpa: Allocator, text: *Text, mode: Mode, dialect: Dialect) Allocator.Error!*Parse {
    return createSource(gpa, .{ .shared = text }, mode, dialect);
}

/// Where the text of a new parse comes from
const Source = union(enum) {
    /// Copied into the result's arena
    copy: []const u8,
    /// The file text buffer, retained by the result
    shared: *Text,

    fn bytes(src: Source) []const u8 {
        return switch (src) {
            .copy => |text| text,
            .shared => |text| text.bytes(),
        };
    }
};

/// The source of a result: a copy allocated with `owner` (the arena of a full parse, or the gpa
/// for an incremental result whose source is freed with its last user), or the retained buffer
fn obtainSource(owner: Allocator, src: Source) Allocator.Error!struct { source: [:0]const u8, shared: ?*Text } {
    return switch (src) {
        .copy => |text| .{ .source = try owner.dupeSentinel(u8, text, 0), .shared = null },
        .shared => |text| blk: {
            text.retain();
            break :blk .{ .source = text.source(), .shared = text };
        },
    };
}

/// Bytes of the shared buffer of the full parse at the bottom of the chain of `old`, which a result
/// built on `old` keeps alive until that arena is destroyed
fn baseSourceBytes(old: *const Parse) usize {
    if (old.base != null) return old.base_source_bytes;
    return if (old.shared != null) old.source.len + 1 else 0;
}

fn createSource(gpa: Allocator, src: Source, mode: Mode, dialect: Dialect) Allocator.Error!*Parse {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const obtained = try obtainSource(a, src);
    const source = obtained.source;
    errdefer if (obtained.shared) |text| text.release(gpa);
    const tokens = try lexer.tokenize(gpa, source);
    defer gpa.free(tokens);
    const events = switch (mode) {
        .zig => try runParser(gpa, source, tokens, dialect, grammar.sourceFile),
        .zon => try runParser(gpa, source, tokens, dialect, grammar.zonFile),
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
        .dialect = dialect,
        .source = source,
        .shared = obtained.shared,
        .root = root,
        .errors = errors,
        .chain_bytes = 0,
        .id = newId(),
        .full_bytes = 0,
    };
    result.arena = arena;
    result.full_bytes = result.arena.queryCapacity();
    result.chain_bytes = result.full_bytes;
    return result;
}

/// Adds a reference (paired with `destroy`)
pub fn retain(self: *Parse) *Parse {
    _ = self.users.fetchAdd(1, .monotonic);
    _ = self.refs.fetchAdd(1, .monotonic);
    return self;
}

/// Releases a reference; the last one frees the source of an incremental result, and the arena
/// is destroyed once the results built on this one are gone too.
pub fn destroy(self: *Parse) void {
    if (self.users.fetchSub(1, .acq_rel) == 1 and self.owns_source) {
        if (self.shared) |text| text.release(self.gpa) else self.gpa.free(self.source);
    }
    self.release();
}

/// The reference an incremental result holds on the result it was built on
fn retainBase(self: *Parse) void {
    _ = self.refs.fetchAdd(1, .monotonic);
}

/// Releases a reference; the last release destroys the arena and releases the reference to base.
/// A full parse's source outlives its arena: the green tokens copied from it point into the text.
fn release(self: *Parse) void {
    if (self.refs.fetchSub(1, .acq_rel) != 1) return;
    // The fields are read before the arena is destroyed: they live in it
    const base = self.base;
    const shared = if (self.owns_source) null else self.shared;
    const gpa = self.gpa;
    var arena = self.arena;
    arena.deinit();
    if (shared) |text| text.release(gpa);
    if (base) |b| b.release();
}

/// Bytes of the source when it is not in the arena (see `owns_source` and `shared`)
pub fn sourceBytes(self: *const Parse) usize {
    return if (self.owns_source or self.shared != null) self.source.len + 1 else 0;
}

/// Bytes of the memory a result keeps alive, apart from the `Parse` value itself: the arenas of the
/// chain, its own source when it is not in an arena, and the shared buffer of the full parse at the
/// base, which the chain keeps until that arena is destroyed
pub fn bytes(self: *const Parse) usize {
    return @sizeOf(Parse) + self.chain_bytes + self.sourceBytes() + self.base_source_bytes;
}

pub fn rootNode(self: *const Parse) tree.SyntaxNode {
    return .{ .green = self.root, .offset = 0 };
}

/// Parses new text based on `old`, in the same mode and dialect: when a local reparse is possible,
/// reparses only the affected block; otherwise does a full parse.
/// The result is exactly the same as `createIn(gpa, text, old.mode, old.dialect)`. A ZON file holds
/// a single expression and is usually small, so it is always parsed in full
pub fn reparse(gpa: Allocator, old: *Parse, text: []const u8) Allocator.Error!*Parse {
    return reparseSource(gpa, old, .{ .copy = text });
}

/// `reparse` where the new text is the file text buffer, retained instead of copied
pub fn reparseShared(gpa: Allocator, old: *Parse, text: *Text) Allocator.Error!*Parse {
    return reparseSource(gpa, old, .{ .shared = text });
}

fn reparseSource(gpa: Allocator, old: *Parse, src: Source) Allocator.Error!*Parse {
    if (old.mode == .zon) return createSource(gpa, src, .zon, old.dialect);
    // The block and the top-level attempt use the same edit range: scanning for it twice costs a
    // pass over the whole text per edit when the edit is at the top level
    const edit = editRange(old.source, src.bytes()) orelse return createSource(gpa, src, old.mode, old.dialect);
    if (try reparseBlockEdit(gpa, old, src, edit)) |p| return p;
    if (try reparseTopLevelEdit(gpa, old, src, edit)) |p| return p;
    return createSource(gpa, src, old.mode, old.dialect);
}

/// Whether two parse results have exactly the same mode, dialect, syntax tree and errors (used to
/// verify that incremental results match full ones)
pub fn sameAs(a: *const Parse, b: *const Parse) bool {
    if (a.mode != b.mode or a.dialect != b.dialect or !greenEql(a.root, b.root)) return false;
    if (a.errors.len != b.errors.len) return false;
    for (a.errors, b.errors) |x, y| {
        if (x.offset != y.offset or !std.mem.eql(u8, x.message, y.message)) return false;
    }
    return true;
}

fn greenEql(a: *const green.GreenNode, b: *const green.GreenNode) bool {
    if (a == b) return true;
    // The flags are derived from the subtree, so comparing them also checks that every site that
    // builds a node computes them
    if (a.kind != b.kind or a.flags.has_container != b.flags.has_container or a.flags.has_import != b.flags.has_import or
        a.text_len != b.text_len or a.children.len != b.children.len) return false;
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

fn runParser(gpa: Allocator, source: []const u8, tokens: []const lexer.Token, dialect: Dialect, comptime entry: anytype) Allocator.Error!Events {
    var significant: std.ArrayList(u32) = .empty;
    defer significant.deinit(gpa);
    for (tokens, 0..) |t, i| {
        if (!kind_mod.isTrivia(t.kind)) try significant.append(gpa, @intCast(i));
    }
    var p: parser.Parser = .{
        .gpa = gpa,
        .source = source,
        .tokens = tokens,
        .significant = significant.items,
        .variadic_doc_comments = dialect == .zig_0_17_0,
    };
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

/// The edited part of the text: the bytes before the common prefix of the old and new text, and
/// those after their common suffix
pub const EditRange = struct {
    /// Length of the common prefix; 0 when the texts differ in their first byte
    prefix: u32,
    /// Length of the common suffix, which does not reach into the common prefix
    suffix: u32,
};

/// The edit range of `old_text` → `text`; null when the texts are identical (used by tests)
pub fn editRange(old_text: []const u8, text: []const u8) ?EditRange {
    const prefix = commonPrefix(old_text, text);
    if (prefix == old_text.len and old_text.len == text.len) return null;
    const max_suffix = @min(old_text.len, text.len) - prefix;
    const suffix = commonSuffix(old_text, text, max_suffix);
    return .{ .prefix = @intCast(prefix), .suffix = @intCast(suffix) };
}

/// Length of the common prefix of `a` and `b`: the first byte at which they differ, or the length
/// of the shorter when one starts with the other
fn commonPrefix(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    if (comptime vector.width > 0) {
        const Chunk = @Vector(vector.width, u8);
        while (i + vector.width <= n) : (i += vector.width) {
            const x: Chunk = a[i..][0..vector.width].*;
            const y: Chunk = b[i..][0..vector.width].*;
            const differs = x != y;
            if (std.simd.firstTrue(differs)) |j| return i + j;
        }
    }
    while (i < n and a[i] == b[i]) i += 1;
    return i;
}

/// Number of trailing bytes that are equal, at most `max`: it stops before the suffix would reach
/// into the prefix
fn commonSuffix(a: []const u8, b: []const u8, max: usize) usize {
    var n: usize = 0;
    if (comptime vector.width > 0) {
        const Chunk = @Vector(vector.width, u8);
        while (n + vector.width <= max) : (n += vector.width) {
            const x: Chunk = a[a.len - n - vector.width ..][0..vector.width].*;
            const y: Chunk = b[b.len - n - vector.width ..][0..vector.width].*;
            const differs = x != y;
            if (std.simd.lastTrue(differs)) |j| return n + vector.width - 1 - j;
        }
    }
    while (n < max and a[a.len - 1 - n] == b[b.len - 1 - n]) n += 1;
    return n;
}

/// Nodes that can be reparsed on their own: the edit must lie strictly between their `{` and `}`
fn isReparsable(kind: SyntaxKind) bool {
    return kind == .block or kind == .container_decl;
}

/// Attempts only a local reparse; returns null when the conditions are not met (used by tests
/// and corpus cross-checks).
pub fn reparseBlock(gpa: Allocator, old: *Parse, text: []const u8) Allocator.Error!?*Parse {
    return reparseBlockEdit(gpa, old, .{ .copy = text }, editRange(old.source, text) orelse return null);
}

/// `reparseBlock` with the edit range of `old.source` → `text` already computed
fn reparseBlockEdit(gpa: Allocator, old: *Parse, src: Source, edit: EditRange) Allocator.Error!?*Parse {
    // Memory reclamation: do a full parse instead when the chain gets too long. `chain_bytes` and
    // `full_bytes` describe `old`, so this does not depend on the edit
    if (old.chain_bytes > 2 * old.full_bytes) return null;
    const text = src.bytes();
    const old_text = old.source;
    const edit_start = edit.prefix;
    const edit_end_old: u32 = @intCast(old_text.len - edit.suffix);

    // Find the deepest reparsable node containing the edit range, and record the path from the
    // root to it (for the replacement)
    var path: std.ArrayList(PathEntry) = .empty;
    defer path.deinit(gpa);
    const target = try findTarget(gpa, old.rootNode(), edit_start, edit_end_old, &path) orelse return null;

    const delta: i64 = @as(i64, @intCast(text.len)) - @as(i64, @intCast(old_text.len));
    const old_range = target.range();
    const new_end: usize = @intCast(@as(i64, old_range.end) + delta);
    const node_text = text[old_range.start..new_end];

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
        .block => try runParser(gpa, sub_source, tokens, old.dialect, entryBlock),
        .container_decl => try runParser(gpa, sub_source, tokens, old.dialect, entryContainer),
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
            .flags = green.GreenNode.flagsOf(entry.node.kind, children),
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

    const obtained = try obtainSource(gpa, src);
    errdefer if (obtained.shared) |t| t.release(gpa) else gpa.free(obtained.source);
    const result = try a.create(Parse);
    result.* = .{
        .arena = undefined,
        .gpa = gpa,
        .mode = old.mode,
        .dialect = old.dialect,
        .source = obtained.source,
        .owns_source = true,
        .shared = obtained.shared,
        .root = new_node,
        .errors = errors.items,
        .base = old,
        .chain_bytes = 0,
        .base_source_bytes = baseSourceBytes(old),
        .id = newId(),
        .full_bytes = old.full_bytes,
    };
    result.arena = arena;
    result.chain_bytes = old.chain_bytes + result.arena.queryCapacity();
    old.retainBase();
    return result;
}

/// Edits at the top level (between declarations, comments at the end of the file, etc., not
/// inside any `{}`): reparses from the second top-level member before the edit position (the
/// start of the file when there are fewer members before it), reusing the earlier top-level
/// children as is. Top-level members are parsed independently one by one, looking ahead at most
/// one or two tokens; backing up one extra member keeps every token seen by lookahead before the
/// edit. The fragment ends after the first member that starts after the edit (see `spliceTail`);
/// the members after it are reused from `old` when that member parses the same as before,
/// otherwise the fragment runs to the end of the file. Returns null when the
/// conditions are not met (the result is the same as a full parse). Does not apply to ZON, whose
/// top level is one expression rather than container members
pub fn reparseTopLevel(gpa: Allocator, old: *Parse, text: []const u8) Allocator.Error!?*Parse {
    if (old.mode == .zon) return null;
    return reparseTopLevelEdit(gpa, old, .{ .copy = text }, editRange(old.source, text) orelse return null);
}

/// `reparseTopLevel` with the edit range of `old.source` → `text` already computed, for Zig mode
fn reparseTopLevelEdit(gpa: Allocator, old: *Parse, src: Source, edit: EditRange) Allocator.Error!?*Parse {
    if (old.chain_bytes > 2 * old.full_bytes) return null;
    const text = src.bytes();
    const old_text = old.source;
    const edit_start = edit.prefix;
    const old_edit_end: u32 = @intCast(old_text.len - edit.suffix);
    const delta: i64 = @as(i64, @intCast(text.len)) - @as(i64, @intCast(old_text.len));

    // Top-level member nodes: start two members before the first one that ends after the edit
    const root = old.rootNode();
    var nodes: std.ArrayList(TopMember) = .empty;
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
    const from: TopMember = if (k < 2) .{ .child = 0, .start = 0 } else nodes.items[k - 2];
    // An earlier member's error may be reported at the cut point (e.g. a missing `;` is reported
    // at the next token): the reparse would not produce it again
    if (from.start != 0) for (old.errors) |e| if (e.offset == from.start) return null;

    // The member `after` starts after the edit; the fragment ends where member `after + 1` starts
    const after: ?usize = for (nodes.items[k..], k..) |n, i| {
        if (n.start > old_edit_end) break i;
    } else null;
    if (after) |e| if (e + 1 < nodes.items.len) {
        if (try spliceTail(gpa, old, src, from, nodes.items[e], nodes.items[e + 1], delta)) |p| return p;
    };
    return reparseFrom(gpa, old, src, from, text.len);
}

const TopMember = struct { child: usize, start: u32 };

/// The fragment `from` .. `cut` (old positions), followed by the old top-level children from `cut`
/// on. The members after `cut` parse as before when everything up to `cut` does: the text from
/// `lookahead` on is unchanged, and when the fragment gives the same children from `lookahead` to
/// `cut` as before, with no errors there in either parse, every token the parser looked at before
/// `cut` is the same. Null when that does not hold
fn spliceTail(gpa: Allocator, old: *Parse, src: Source, from: TopMember, lookahead: TopMember, cut: TopMember, delta: i64) Allocator.Error!?*Parse {
    // An error at `cut` comes from the recovery of an earlier member, which looked past `cut`
    for (old.errors) |e| if (e.offset >= lookahead.start and e.offset <= cut.start) return null;
    const new_cut: u32 = @intCast(@as(i64, cut.start) + delta);
    const new_lookahead: u32 = @intCast(@as(i64, lookahead.start) + delta);
    const p = try reparseFrom(gpa, old, src, from, new_cut) orelse return null;
    var ok = true;
    for (p.errors) |e| if (e.offset >= new_lookahead) {
        ok = false;
        break;
    };
    const same = old.root.children[lookahead.child..cut.child];
    const tail = p.root.children[from.child..];
    if (ok and tail.len >= same.len) {
        for (tail[tail.len - same.len ..], same) |x, y| if (!elementEql(x, y)) {
            ok = false;
            break;
        };
    } else ok = false;
    if (!ok) {
        p.destroy();
        return null;
    }
    // Append the old children from `cut` on and their errors to the fragment's result
    const a = p.arena.allocator();
    const rest = old.root.children[cut.child..];
    const children = try a.alloc(green.GreenElement, p.root.children.len + rest.len);
    @memcpy(children[0..p.root.children.len], p.root.children);
    @memcpy(children[p.root.children.len..], rest);
    const new_root = try a.create(green.GreenNode);
    new_root.* = .{
        .kind = old.root.kind,
        .flags = green.GreenNode.flagsOf(old.root.kind, children),
        .text_len = @intCast(src.bytes().len),
        .children = children,
    };
    var errors: std.ArrayList(parser.Error) = .empty;
    try errors.appendSlice(a, p.errors);
    for (old.errors) |e| if (e.offset > cut.start) try errors.append(a, .{ .offset = @intCast(@as(i64, e.offset) + delta), .message = e.message });
    p.root = new_root;
    p.errors = errors.items;
    p.chain_bytes = old.chain_bytes + p.arena.queryCapacity();
    return p;
}

fn elementEql(x: green.GreenElement, y: green.GreenElement) bool {
    return switch (x.unpack()) {
        .node => |n| if (y.node()) |m| greenEql(n, m) else false,
        .token => |t| !y.is_node and t.kind == y.kind() and std.mem.eql(u8, t.text, y.unpack().token.text),
    };
}

/// Parses `text[from.start..end]` as top-level members after the old children before `from`
/// (the root of the result covers only up to `end`; the source is all of `text`); null when the
/// fragment has a `//!` doc comment that is not at the start of the file
fn reparseFrom(gpa: Allocator, old: *Parse, src: Source, from: TopMember, end: usize) Allocator.Error!?*Parse {
    const text = src.bytes();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const sub_source = try a.dupeSentinel(u8, text[from.start..end], 0);
    const tokens = try lexer.tokenize(gpa, sub_source);
    defer gpa.free(tokens);
    // `//!` is a container doc comment only at the start of the file: the start of the fragment
    // is not the start of the file
    if (from.start != 0) for (tokens) |t| if (t.kind == .container_doc_comment) {
        arena.deinit();
        return null;
    };
    const events = try runParser(gpa, sub_source, tokens, old.dialect, grammar.sourceFile);
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
    new_root.* = .{
        .kind = old.root.kind,
        .flags = green.GreenNode.flagsOf(old.root.kind, children),
        .text_len = from.start + tail.text_len,
        .children = children,
    };

    var errors: std.ArrayList(parser.Error) = .empty;
    for (old.errors) |e| if (e.offset < from.start) try errors.append(a, e);
    for (events.errors) |e| try errors.append(a, .{ .offset = e.offset + from.start, .message = e.message });
    sortErrors(errors.items);

    const obtained = try obtainSource(gpa, src);
    errdefer if (obtained.shared) |t| t.release(gpa) else gpa.free(obtained.source);
    const result = try a.create(Parse);
    result.* = .{
        .arena = undefined,
        .gpa = gpa,
        .mode = old.mode,
        .dialect = old.dialect,
        .source = obtained.source,
        .owns_source = true,
        .shared = obtained.shared,
        .root = new_root,
        .errors = errors.items,
        .base = old,
        .chain_bytes = 0,
        .base_source_bytes = baseSourceBytes(old),
        .id = newId(),
        .full_bytes = old.full_bytes,
    };
    result.arena = arena;
    result.chain_bytes = old.chain_bytes + result.arena.queryCapacity();
    old.retainBase();
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

/// After the first `{` opens, the braces do not balance until the last token, which must be `}`
/// even counting trivia: when a line comment runs to the end of the text, the node's `}` is not
/// the end of that comment in the whole file
fn bracesBalanced(tokens: []const lexer.Token) bool {
    if (tokens.len == 0 or tokens[tokens.len - 1].kind != .r_brace) return false;
    var depth: i32 = 0;
    var opened = false;
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
    }
    return opened and depth == 0;
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
    _ = @import("edit_range_fuzz.zig");
}
