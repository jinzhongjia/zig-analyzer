//! Organizing top-level imports (`source.organizeImports`), and the position of a new import
//! added by auto-import. Only the syntax tree and the source text are examined.
//!
//! An organizable block consists of consecutive top-level import declarations and derived
//! declarations:
//! - import declaration: `const x = @import("...");`, optionally with a member access
//!   (`const T = @import("x.zig").T;`);
//! - derived declaration: the right-hand side is a member access starting with an import or
//!   derived declaration of the same file (`const Allocator = std.mem.Allocator;`).
//!
//! Only blank lines may separate declarations; comments directly above a declaration and its
//! trailing comment belong to it. A comment separated from the next declaration by a blank line,
//! or any other declaration, ends a block.
//! Each declaration must occupy whole lines by itself; otherwise it belongs to no block.
//!
//! Within a block, declarations are arranged in groups separated by one blank line:
//! `std` / `builtin` / `root` (fixed order), dependency modules, files. A derived declaration
//! directly follows the declaration it depends on (`with_import`), or derived declarations form a
//! group of their own after all imports (`separate`); a derived declaration whose dependency is
//! not in the same block always goes in the last group. Within a group, entries are sorted by
//! what they reference (`sort = .path`: module name, file path, the expanded access path of a
//! derived declaration) or by declaration name (`.name`), comparing each segment with rustfmt's
//! version sort; nearer file paths come first (same directory and subdirectories, `../`, `../../`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../syntax/ast.zig");
const Parse = @import("../syntax/Parse.zig");
const SyntaxNode = @import("../syntax/tree.zig").SyntaxNode;
const SyntaxKind = @import("../syntax/kind.zig").SyntaxKind;

/// The `imports.*` configuration
pub const Options = struct {
    derived: Derived = .with_import,
    sort: Sort = .path,

    pub const Derived = enum { with_import, separate };
    pub const Sort = enum { path, name };
};

pub const Edit = struct { start: u32, end: u32, text: []const u8 };

pub const Block = struct {
    /// Start of the line of the first declaration (including the comments above it)
    start: u32,
    /// End of the line of the last declaration (excluding the newline)
    end: u32,
    entries: []const Entry,
};

pub const Entry = struct {
    /// Same granularity as the range of a block: from the start of the line of the comments above
    /// to the end of the line of the declaration
    start: u32,
    end: u32,
    /// Start of the declaration node
    decl: u32,
    name: []const u8,
    what: What,
};

pub const What = union(enum) {
    /// `member` is the member access following `@import(...)` (`Service.Index`; empty if none)
    import: struct { spec: []const u8, member: []const u8 },
    /// `root` is the name at the start of the right-hand side; `path` is the full access path
    /// expanded up to the name of the import declaration (`std.mem.Allocator`)
    derived: struct { root: []const u8, path: []const u8 },
};

pub const Result = struct { blocks: []const Block, edits: []const Edit };

/// Organizes all blocks in the file: blocks that are already organized get no edits. Does not
/// organize when there are syntax errors.
pub fn organize(a: Allocator, parse: *const Parse, opts: Options) Allocator.Error!Result {
    if (parse.errors.len != 0) return .{ .blocks = &.{}, .edits = &.{} };
    const all = try blocks(a, parse);
    var edits: std.ArrayList(Edit) = .empty;
    for (all) |b| {
        const text = try render(a, parse.source, b.entries, null, newline(parse.source, b), opts);
        if (!std.mem.eql(u8, text, parse.source[b.start..b.end])) try edits.append(a, .{ .start = b.start, .end = b.end, .text = text });
    }
    return .{ .blocks = all, .edits = edits.items };
}

/// Position of a new import added by auto-import. When the block containing the last import
/// declaration is already organized, the import is placed where it belongs by the same rules;
/// otherwise (the block is not organized, or there are no imports yet) it goes after the last
/// import declaration, or after the `//!` docs and the comment header at the top of the file.
pub const Inserter = struct {
    source: []const u8,
    opts: Options,
    /// The already organized block containing the last import declaration
    block: ?Block,
    /// Insertion position in the other cases (start of a line)
    fallback: u32,

    pub fn init(a: Allocator, parse: *const Parse, opts: Options) Allocator.Error!Inserter {
        const source = parse.source;
        var ins: Inserter = .{ .source = source, .opts = opts, .block = null, .fallback = fallbackOffset(parse) };
        const last = lastImport(parse) orelse return ins;
        for (try blocks(a, parse)) |b| for (b.entries) |e| {
            if (e.decl != last) continue;
            const text = try render(a, source, b.entries, null, newline(source, b), opts);
            if (std.mem.eql(u8, text, source[b.start..b.end])) ins.block = b;
            return ins;
        };
        return ins;
    }

    /// Edit that inserts `const {name} = @import("{spec}"){.member};` (`decl` is the text of this
    /// line, without the newline)
    pub fn edit(ins: Inserter, a: Allocator, name: []const u8, spec: []const u8, member: []const u8, decl: []const u8) Allocator.Error!Edit {
        const b = ins.block orelse {
            const offset = ins.fallback;
            const lead: []const u8 = if (offset > 0 and ins.source[offset - 1] != '\n') "\n" else "";
            return .{ .start = offset, .end = offset, .text = try std.fmt.allocPrint(a, "{s}{s}\n", .{ lead, decl }) };
        };
        const nl = newline(ins.source, b);
        const extra: Entry = .{ .start = 0, .end = 0, .decl = 0, .name = name, .what = .{ .import = .{ .spec = spec, .member = member } } };
        const text = try render(a, ins.source, b.entries, .{ .entry = extra, .text = decl }, nl, ins.opts);
        return lineDiff(a, ins.source, b, text, nl);
    }
};

/// `@import(...)` or a member access on it (possibly parenthesized): the initializer expression
/// of an import declaration
pub fn isImportInit(node: SyntaxNode) bool {
    if (node.kind() == .builtin_call) {
        const name = node.childToken(.builtin) orelse return false;
        return std.mem.eql(u8, name.text, "@import");
    }
    if (node.kind() == .field_access or node.kind() == .paren_expr) {
        var children = node.children();
        return isImportInit(children.nextNode() orelse return false);
    }
    return false;
}

/// Start of the last top-level import declaration (including ones that belong to no block)
fn lastImport(parse: *const Parse) ?u32 {
    var last: ?u32 = null;
    var children = parse.rootNode().children();
    while (children.nextNode()) |node| if (importDecl(node)) {
        last = node.range().start;
    };
    return last;
}

fn importDecl(node: SyntaxNode) bool {
    if (node.kind() != .var_decl or node.childToken(.keyword_const) == null) return false;
    const init = (ast.VarDecl{ .syntax = node }).initExpr() orelse return false;
    return isImportInit(init);
}

/// Start of the line after the last import declaration (keeping a comment on the same line);
/// without imports, after the `//!` docs and the comment header (such as a license) at the top of
/// the file (after the UTF-8 BOM). A comment followed by a blank line is a header; one directly
/// above a declaration belongs to the declaration
fn fallbackOffset(parse: *const Parse) u32 {
    const source = parse.source;
    var last: ?u32 = null;
    var children = parse.rootNode().children();
    while (children.nextNode()) |node| if (importDecl(node)) {
        last = node.range().end;
    };
    if (last) |end| {
        var pos: usize = end;
        while (pos < source.len and (source[pos] == ' ' or source[pos] == '\t' or source[pos] == '\r')) : (pos += 1) {}
        if (std.mem.startsWith(u8, source[pos..], "//")) while (pos < source.len and source[pos] != '\n') : (pos += 1) {};
        if (pos < source.len and source[pos] == '\n') pos += 1;
        return @intCast(pos);
    }
    // A BOM is only allowed at the start of the file; an import must not be inserted before it,
    // otherwise the BOM moves to the second line and becomes an invalid token
    const start: usize = bomLen(source);
    var pos: usize = start;
    var docs_end: usize = start;
    // Comment lines since the last blank line or `//!` doc line
    var in_comment = false;
    while (pos < source.len) {
        const end = if (std.mem.indexOfScalarPos(u8, source, pos, '\n')) |e| e + 1 else source.len;
        const line = std.mem.trim(u8, source[pos..end], " \t\r\n");
        if (std.mem.startsWith(u8, line, "//!")) {
            docs_end = end;
            in_comment = false;
        } else if (line.len == 0) {
            if (in_comment) docs_end = end;
            in_comment = false;
        } else if (std.mem.startsWith(u8, line, "//")) {
            in_comment = true;
        } else break;
        pos = end;
    }
    return @intCast(docs_end);
}

fn bomLen(source: []const u8) usize {
    return if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) 3 else 0;
}

// ── Blocks ───────────────────────────────────────────────────────────

/// Import or derived declaration parsed from a top-level const declaration (for a derived
/// declaration, the name it starts with is checked in `blocks`)
const Candidate = struct { node: SyntaxNode, name: []const u8, what: What };

fn candidate(a: Allocator, node: SyntaxNode) Allocator.Error!?Candidate {
    if (node.kind() != .var_decl or node.childToken(.keyword_const) == null) return null;
    for ([_]SyntaxKind{ .keyword_extern, .keyword_export, .keyword_threadlocal, .keyword_comptime }) |k| {
        if (node.childToken(k) != null) return null;
    }
    const decl: ast.VarDecl = .{ .syntax = node };
    const name = decl.name() orelse return null;
    var e = decl.initExpr() orelse return null;
    // Member accesses, from the outside in
    var members: std.ArrayList([]const u8) = .empty;
    while (true) switch (e.kind()) {
        .field_access => {
            const fa: ast.FieldAccess = .{ .syntax = e };
            try members.append(a, ast.identName((fa.name() orelse return null).text));
            e = fa.lhs() orelse return null;
        },
        .paren_expr => {
            var children = e.children();
            e = children.nextNode() orelse return null;
        },
        else => break,
    };
    std.mem.reverse([]const u8, members.items);
    const member = try std.mem.join(a, ".", members.items);
    switch (e.kind()) {
        .builtin_call => {
            const call: ast.BuiltinCall = .{ .syntax = e };
            if (!std.mem.eql(u8, (call.name() orelse return null).text, "@import")) return null;
            var args = call.args();
            const arg = args.next() orelse return null;
            if (args.next() != null) return null;
            const literal = if (arg.kind() == .literal) arg.childToken(.string_literal) else null;
            const text = (literal orelse return null).text;
            const spec = std.zig.string_literal.parseAlloc(a, text) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidLiteral => return null,
            };
            return .{ .node = node, .name = ast.identName(name.text), .what = .{ .import = .{ .spec = spec, .member = member } } };
        },
        .name_ref => {
            if (member.len == 0) return null;
            const root = (ast.NameRef{ .syntax = e }).name() orelse return null;
            return .{ .node = node, .name = ast.identName(name.text), .what = .{ .derived = .{ .root = ast.identName(root.text), .path = member } } };
        },
        else => return null,
    }
}

/// Organizable blocks in the file
pub fn blocks(a: Allocator, parse: *const Parse) Allocator.Error![]const Block {
    const source = parse.source;
    const root = parse.rootNode();
    var cands: std.ArrayList(Candidate) = .empty;
    var by_name: std.StringHashMapUnmanaged(usize) = .empty;
    var children = root.children();
    while (children.nextNode()) |node| if (try candidate(a, node)) |c| {
        const gop = try by_name.getOrPut(a, c.name);
        if (!gop.found_existing) gop.value_ptr.* = cands.items.len;
        try cands.append(a, c);
    };
    // A derived declaration must trace back to an import declaration through its leading name;
    // full paths are expanded in the order of confirmation (a dependency is always confirmed first)
    const valid = try a.alloc(bool, cands.items.len);
    for (cands.items, valid) |c, *v| v.* = c.what == .import;
    var changed = true;
    while (changed) {
        changed = false;
        for (cands.items, valid) |*c, *v| {
            if (v.*) continue;
            const d = c.what.derived;
            const i = by_name.get(d.root) orelse continue;
            if (!valid[i]) continue;
            const prefix = switch (cands.items[i].what) {
                .import => cands.items[i].name,
                .derived => |p| p.path,
            };
            c.what.derived.path = try std.fmt.allocPrint(a, "{s}.{s}", .{ prefix, d.path });
            v.* = true;
            changed = true;
        }
    }

    var out: std.ArrayList(Block) = .empty;
    var current: std.ArrayList(Entry) = .empty;
    var index: usize = 0;
    children = root.children();
    while (children.next()) |el| {
        const node = switch (el) {
            .token => |t| {
                if (t.kind != .whitespace and t.kind != .line_comment) try close(a, &out, &current);
                continue;
            },
            .node => |n| n,
        };
        const entry: ?Entry = blk: {
            if (index >= cands.items.len or cands.items[index].node.offset != node.offset) break :blk null;
            const c = cands.items[index];
            index += 1;
            if (!valid[index - 1]) break :blk null;
            break :blk lineEntry(source, node, c);
        };
        const e = entry orelse {
            try close(a, &out, &current);
            continue;
        };
        if (current.items.len != 0) {
            const gap = source[current.items[current.items.len - 1].end..e.start];
            if (std.mem.trim(u8, gap, " \t\r\n").len != 0) try close(a, &out, &current);
        }
        try current.append(a, e);
    }
    try close(a, &out, &current);
    return out.items;
}

fn close(a: Allocator, out: *std.ArrayList(Block), current: *std.ArrayList(Entry)) Allocator.Error!void {
    if (current.items.len == 0) return;
    const entries = try a.dupe(Entry, current.items);
    try out.append(a, .{ .start = entries[0].start, .end = entries[entries.len - 1].end, .entries = entries });
    current.clearRetainingCapacity();
}

/// Entry for a declaration that occupies whole lines by itself: only indentation (or the BOM at
/// the start of the file) before it, and only whitespace and a trailing comment after it; `//`
/// comment lines directly above it are included as well, unless they start the file (a file
/// header such as a license notice, which stays first)
fn lineEntry(source: []const u8, node: SyntaxNode, c: Candidate) ?Entry {
    const range = node.range();
    const file_start = bomLen(source);
    const decl_line: usize = if (std.mem.lastIndexOfScalar(u8, source[0..range.start], '\n')) |i| i + 1 else file_start;
    if (std.mem.trim(u8, source[decl_line..range.start], " \t").len != 0) return null;
    const line_end = std.mem.indexOfScalarPos(u8, source, range.end, '\n') orelse source.len;
    const rest = std.mem.trim(u8, source[range.end..line_end], " \t\r");
    if (rest.len != 0 and !std.mem.startsWith(u8, rest, "//")) return null;
    var line_start = decl_line;
    while (line_start > file_start) {
        const prev_end = line_start - 1;
        const prev_start = if (std.mem.lastIndexOfScalar(u8, source[0..prev_end], '\n')) |i| i + 1 else file_start;
        const line = std.mem.trim(u8, source[prev_start..prev_end], " \t\r");
        if (!std.mem.startsWith(u8, line, "//") or std.mem.startsWith(u8, line, "//!")) break;
        line_start = prev_start;
    }
    if (line_start == file_start) line_start = decl_line;
    const end = if (line_end > range.end and source[line_end - 1] == '\r') line_end - 1 else line_end;
    return .{ .start = @intCast(line_start), .end = @intCast(end), .decl = range.start, .name = c.name, .what = c.what };
}

/// Newline sequence used in the block
fn newline(source: []const u8, b: Block) []const u8 {
    const line_end = std.mem.indexOfScalarPos(u8, source, b.entries[0].decl, '\n') orelse return "\n";
    return if (line_end > 0 and source[line_end - 1] == '\r') "\r\n" else "\n";
}

// ── Sorting ──────────────────────────────────────────────────────────

const Group = enum { std, module, file, derived };

fn groupOf(e: Entry) Group {
    return switch (e.what) {
        .import => |i| if (stdRank(i.spec) != null)
            .std
        else if (std.mem.endsWith(u8, i.spec, ".zig") or std.mem.endsWith(u8, i.spec, ".zon"))
            .file
        else
            .module,
        .derived => .derived,
    };
}

fn stdRank(spec: []const u8) ?u8 {
    for ([_][]const u8{ "std", "builtin", "root" }, 0..) |name, i| if (std.mem.eql(u8, spec, name)) return @intCast(i);
    return null;
}

/// Entry added by auto-import: `text` is its source
const Extra = struct { entry: Entry, text: []const u8 };

/// Organized text of the block (plus `extra`)
fn render(a: Allocator, source: []const u8, entries: []const Entry, extra: ?Extra, nl: []const u8, opts: Options) Allocator.Error![]const u8 {
    var all: std.ArrayList(Entry) = .empty;
    try all.appendSlice(a, entries);
    if (extra) |x| try all.append(a, x.entry);
    const items = all.items;
    const texts = try a.alloc([]const u8, items.len);
    for (items, texts, 0..) |e, *t, i| t.* = if (extra != null and i == items.len - 1) extra.?.text else source[e.start..e.end];

    // Parent of a derived declaration: when the declaration it depends on is in the same block
    const parent = try a.alloc(?usize, items.len);
    for (items, parent) |e, *p| p.* = switch (e.what) {
        .import => null,
        .derived => |d| for (items, 0..) |other, j| {
            if (std.mem.eql(u8, other.name, d.root)) break j;
        } else null,
    };

    const ctx: SortCtx = .{ .items = items, .opts = opts };
    var groups: [4]std.ArrayList(usize) = @splat(.empty);
    for (items, parent, 0..) |e, p, i| {
        const g = groupOf(e);
        // A derived declaration that follows its parent is emitted by the parent
        if (g == .derived and opts.derived == .with_import and p != null) continue;
        try groups[@backingInt(g)].append(a, i);
    }
    // One blank line between groups
    var out: std.ArrayList(u8) = .empty;
    for (&groups) |*group| {
        if (group.items.len == 0) continue;
        std.mem.sort(usize, group.items, ctx, SortCtx.less);
        if (out.items.len != 0) try out.appendSlice(a, nl);
        for (group.items) |i| try emit(a, &out, ctx, texts, parent, i, nl);
    }
    return out.items;
}

/// Emits one line; with `with_import`, then emits the derived declarations that follow it
fn emit(a: Allocator, out: *std.ArrayList(u8), ctx: SortCtx, texts: []const []const u8, parent: []const ?usize, i: usize, nl: []const u8) Allocator.Error!void {
    if (out.items.len != 0) try out.appendSlice(a, nl);
    try out.appendSlice(a, texts[i]);
    if (ctx.opts.derived != .with_import) return;
    var kids: std.ArrayList(usize) = .empty;
    for (parent, 0..) |p, j| if (p == i) try kids.append(a, j);
    std.mem.sort(usize, kids.items, ctx, SortCtx.less);
    for (kids.items) |j| try emit(a, out, ctx, texts, parent, j, nl);
}

const SortCtx = struct {
    items: []const Entry,
    opts: Options,

    fn less(ctx: SortCtx, x: usize, y: usize) bool {
        return ctx.order(ctx.items[x], ctx.items[y]) == .lt;
    }

    /// Order of two entries in the same group (the `std` group always uses the fixed order)
    fn order(ctx: SortCtx, x: Entry, y: Entry) std.math.Order {
        if (ctx.opts.sort == .name and groupOf(x) != .std) {
            const o = versionOrder(x.name, y.name);
            if (o != .eq) return o;
        }
        const o = switch (x.what) {
            .import => |i| importOrder(i.spec, i.member, y.what.import.spec, y.what.import.member),
            .derived => |d| segmentsOrder(d.path, y.what.derived.path, '.'),
        };
        return if (o != .eq) o else versionOrder(x.name, y.name);
    }
};

fn importOrder(spec_x: []const u8, member_x: []const u8, spec_y: []const u8, member_y: []const u8) std.math.Order {
    const o: std.math.Order = if (stdRank(spec_x)) |rx|
        std.math.order(rx, stdRank(spec_y).?)
    else if (std.mem.endsWith(u8, spec_x, ".zig") or std.mem.endsWith(u8, spec_x, ".zon"))
        pathOrder(spec_x, spec_y)
    else
        versionOrder(spec_x, spec_y);
    return if (o != .eq) o else segmentsOrder(member_x, member_y, '.');
}

/// File paths: fewer `../` (nearer) first, then compared segment by segment
fn pathOrder(x: []const u8, y: []const u8) std.math.Order {
    const rx = stripUps(x);
    const ry = stripUps(y);
    if (rx.ups != ry.ups) return std.math.order(rx.ups, ry.ups);
    return segmentsOrder(rx.rest, ry.rest, '/');
}

fn stripUps(path: []const u8) struct { ups: usize, rest: []const u8 } {
    var rest = path;
    var ups: usize = 0;
    while (true) {
        if (std.mem.startsWith(u8, rest, "../")) {
            ups += 1;
            rest = rest[3..];
        } else if (std.mem.startsWith(u8, rest, "./")) {
            rest = rest[2..];
        } else return .{ .ups = ups, .rest = rest };
    }
}

/// Compares segment by segment; when the leading segments are equal, the one with fewer
/// segments comes first
fn segmentsOrder(x: []const u8, y: []const u8, sep: u8) std.math.Order {
    var ix = std.mem.splitScalar(u8, x, sep);
    var iy = std.mem.splitScalar(u8, y, sep);
    if (x.len == 0 or y.len == 0) return std.math.order(x.len, y.len);
    while (true) {
        const sx = ix.next();
        const sy = iy.next();
        if (sx == null) return if (sy == null) .eq else .lt;
        if (sy == null) return .gt;
        const o = versionOrder(sx.?, sy.?);
        if (o != .eq) return o;
    }
}

const Chunk = union(enum) { underscore, str: []const u8, num: []const u8 };

fn nextChunk(s: []const u8, i: *usize) ?Chunk {
    if (i.* >= s.len) return null;
    const start = i.*;
    if (s[start] == '_') {
        i.* += 1;
        return .underscore;
    }
    const digits = std.ascii.isDigit(s[start]);
    var end = start;
    while (end < s.len and s[end] != '_' and std.ascii.isDigit(s[end]) == digits) end += 1;
    i.* = end;
    return if (digits) .{ .num = s[start..end] } else .{ .str = s[start..end] };
}

/// rustfmt's version sort (the Sorting section of the Rust Style Guide): strings are split into
/// runs of digits and non-digits; digit runs are compared by numeric value (on equal values, the
/// side with more leading zeros at the first such difference is remembered, and it comes first if
/// everything else is equal), other runs are compared bytewise (uppercase letters before
/// lowercase), and `_` sorts before every other character
pub fn versionOrder(x: []const u8, y: []const u8) std.math.Order {
    var ix: usize = 0;
    var iy: usize = 0;
    var zeros: std.math.Order = .eq;
    while (true) {
        const cx = nextChunk(x, &ix) orelse return if (nextChunk(y, &iy) == null) zeros else .lt;
        const cy = nextChunk(y, &iy) orelse return .gt;
        switch (cx) {
            .underscore => if (cy != .underscore) return .lt,
            .num => |nx| switch (cy) {
                .underscore => return .gt,
                .num => |ny| {
                    const tx = std.mem.trimStart(u8, nx, "0");
                    const ty = std.mem.trimStart(u8, ny, "0");
                    if (tx.len != ty.len) return std.math.order(tx.len, ty.len);
                    const o = std.mem.order(u8, tx, ty);
                    if (o != .eq) return o;
                    if (zeros == .eq and nx.len != ny.len) zeros = if (nx.len > ny.len) .lt else .gt;
                },
                .str => |sy| {
                    const o = std.mem.order(u8, nx, sy);
                    if (o != .eq) return o;
                },
            },
            .str => |sx| switch (cy) {
                .underscore => return .gt,
                .num, .str => |sy| {
                    const o = std.mem.order(u8, sx, sy);
                    if (o != .eq) return o;
                },
            },
        }
    }
}

// ── Insertion edits ──────────────────────────────────────────────────

/// The organized block becomes `text` (with only the new entry and possibly a blank line added):
/// compares line by line and replaces only the lines that differ
fn lineDiff(a: Allocator, source: []const u8, b: Block, text: []const u8, nl: []const u8) Allocator.Error!Edit {
    var old_lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitSequence(u8, source[b.start..b.end], nl);
    while (it.next()) |l| try old_lines.append(a, l);
    var new_lines: std.ArrayList([]const u8) = .empty;
    it = std.mem.splitSequence(u8, text, nl);
    while (it.next()) |l| try new_lines.append(a, l);
    const old = old_lines.items;
    const new = new_lines.items;
    var p: usize = 0;
    while (p < old.len and p < new.len and std.mem.eql(u8, old[p], new[p])) p += 1;
    var s: usize = 0;
    while (s < old.len - p and s < new.len - p and std.mem.eql(u8, old[old.len - 1 - s], new[new.len - 1 - s])) s += 1;
    // Start of line i (relative to the source)
    var starts = try a.alloc(u32, old.len + 1);
    starts[0] = b.start;
    for (old, 0..) |l, i| starts[i + 1] = starts[i] + @as(u32, @intCast(l.len + nl.len));
    var out: std.ArrayList(u8) = .empty;
    const middle = new[p .. new.len - s];
    if (p + s == old.len and s == 0) {
        // Appended at the end of the block: insert at the start of the next line; when the file
        // ends with the block and has no newline, add one
        if (b.end < source.len) {
            for (middle) |l| {
                try out.appendSlice(a, l);
                try out.appendSlice(a, nl);
            }
            const at: u32 = b.end + @as(u32, @intCast(nl.len));
            return .{ .start = at, .end = at, .text = out.items };
        }
        for (middle) |l| {
            try out.appendSlice(a, nl);
            try out.appendSlice(a, l);
        }
        return .{ .start = b.end, .end = b.end, .text = out.items };
    }
    if (s == 0) {
        for (middle, 0..) |l, i| {
            if (i != 0) try out.appendSlice(a, nl);
            try out.appendSlice(a, l);
        }
        return .{ .start = starts[p], .end = b.end, .text = out.items };
    }
    for (middle) |l| {
        try out.appendSlice(a, l);
        try out.appendSlice(a, nl);
    }
    return .{ .start = starts[p], .end = starts[old.len - s], .text = out.items };
}

test {
    _ = @import("organize_imports_test.zig");
}
