//! 整理顶层 import（`source.organizeImports`），以及自动导入时新 import 的位置。只看语法树与源码文本。
//!
//! 可整理的块由连续的顶层 import 声明与派生声明组成：
//! - import 声明：`const x = @import("...");`，可以带成员访问（`const T = @import("x.zig").T;`）；
//! - 派生声明：右侧是以同一文件的 import 或派生声明开头的成员访问（`const Allocator = std.mem.Allocator;`）。
//!
//! 声明之间只能有空行；紧贴在声明上方的注释与行尾注释属于它。与下一条声明之间隔着空行的注释、其他声明结束一个块。
//! 每条声明须独占若干整行，否则不属于任何块。
//!
//! 块内按组排列，组之间空一行：`std` / `builtin` / `root`（固定顺序）、依赖模块、文件。派生声明紧跟在它依赖的声明之后
//! （`with_import`），或在所有 import 之后单独成一组（`separate`）；依赖的声明不在同一块中的派生声明总是在最后一组。
//! 组内按引用的东西（`sort = .path`：模块名、文件路径、派生声明展开后的访问路径）或声明名（`.name`）排序，每段用
//! rustfmt 的 version sort 比较；文件路径中离得近的在前（同目录与子目录、`../`、`../../`）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../syntax/ast.zig");
const Parse = @import("../syntax/Parse.zig");
const SyntaxNode = @import("../syntax/tree.zig").SyntaxNode;
const SyntaxKind = @import("../syntax/kind.zig").SyntaxKind;

/// 配置 `imports.*`
pub const Options = struct {
    derived: Derived = .with_import,
    sort: Sort = .path,

    pub const Derived = enum { with_import, separate };
    pub const Sort = enum { path, name };
};

pub const Edit = struct { start: u32, end: u32, text: []const u8 };

pub const Block = struct {
    /// 首条声明（含上方的注释）所在行的开头
    start: u32,
    /// 末条声明所在行的行尾（不含换行）
    end: u32,
    entries: []const Entry,
};

pub const Entry = struct {
    /// 与块的范围相同的粒度：上方注释所在行的开头到声明所在行的行尾
    start: u32,
    end: u32,
    /// 声明节点的起点
    decl: u32,
    name: []const u8,
    what: What,
};

pub const What = union(enum) {
    /// `member` 为 `@import(...)` 之后的成员访问（`Service.Index`，没有时为空）
    import: struct { spec: []const u8, member: []const u8 },
    /// `root` 为右侧开头的名字，`path` 为展开到 import 声明名的完整访问路径（`std.mem.Allocator`）
    derived: struct { root: []const u8, path: []const u8 },
};

pub const Result = struct { blocks: []const Block, edits: []const Edit };

/// 整理文件中的全部块：已经整理好的块没有编辑。有语法错误时不整理
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

/// 自动导入的新 import 的位置。包含最后一条 import 声明的块已经整理好时，按同样的规则放到它应在的位置；否则（块没有
/// 整理好、还没有 import）放在最后一条 import 声明之后，或文件头的 `//!` 文档之后
pub const Inserter = struct {
    source: []const u8,
    opts: Options,
    /// 包含最后一条 import 声明、已经整理好的块
    block: ?Block,
    /// 其他情况下的插入位置（行首）
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

    /// 插入 `const {name} = @import("{spec}"){.member};`（`decl` 为这一行的文本，不含换行）的编辑
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

/// `@import(...)` 或它的成员访问（可加括号）：import 声明的初始化表达式
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

/// 最后一条顶层 import 声明（含不属于任何块的）的起点
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

/// 最后一条 import 声明所在行的下一行行首（保留同行的注释）；没有 import 时为文件头 `//!` 文档之后（UTF-8 BOM 之后）
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
    // BOM 只允许在文件开头；import 不能插到它前面，否则 BOM 移到第二行成为非法 token
    const start: usize = bomLen(source);
    var pos: usize = start;
    var docs_end: usize = start;
    while (pos < source.len) {
        const end = if (std.mem.indexOfScalarPos(u8, source, pos, '\n')) |e| e + 1 else source.len;
        const line = std.mem.trim(u8, source[pos..end], " \t\r\n");
        if (std.mem.startsWith(u8, line, "//!")) {
            docs_end = end;
        } else if (line.len != 0 and !std.mem.startsWith(u8, line, "//")) break;
        pos = end;
    }
    return @intCast(docs_end);
}

fn bomLen(source: []const u8) usize {
    return if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) 3 else 0;
}

// ── 块 ───────────────────────────────────────────────────────────────

/// 顶层 const 声明解析出的 import 或派生声明（派生声明在 `blocks` 中检查它开头的名字）
const Candidate = struct { node: SyntaxNode, name: []const u8, what: What };

fn candidate(a: Allocator, node: SyntaxNode) Allocator.Error!?Candidate {
    if (node.kind() != .var_decl or node.childToken(.keyword_const) == null) return null;
    for ([_]SyntaxKind{ .keyword_extern, .keyword_export, .keyword_threadlocal, .keyword_comptime }) |k| {
        if (node.childToken(k) != null) return null;
    }
    const decl: ast.VarDecl = .{ .syntax = node };
    const name = decl.name() orelse return null;
    var e = decl.initExpr() orelse return null;
    // 成员访问由外向内
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

/// 文件中可整理的块
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
    // 派生声明须沿开头的名字追溯到 import 声明；按确认的顺序展开完整路径（依赖的声明总是先确认）
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

/// 声明独占整行时的条目：前面只有缩进（或文件开头的 BOM），后面只有空白与行尾注释；上方紧贴的 `//` 注释行一并归入
fn lineEntry(source: []const u8, node: SyntaxNode, c: Candidate) ?Entry {
    const range = node.range();
    var line_start: usize = if (std.mem.lastIndexOfScalar(u8, source[0..range.start], '\n')) |i| i + 1 else bomLen(source);
    if (std.mem.trim(u8, source[line_start..range.start], " \t").len != 0) return null;
    const line_end = std.mem.indexOfScalarPos(u8, source, range.end, '\n') orelse source.len;
    const rest = std.mem.trim(u8, source[range.end..line_end], " \t\r");
    if (rest.len != 0 and !std.mem.startsWith(u8, rest, "//")) return null;
    while (line_start > 0) {
        const prev_end = line_start - 1;
        const prev_start = if (std.mem.lastIndexOfScalar(u8, source[0..prev_end], '\n')) |i| i + 1 else 0;
        const line = std.mem.trim(u8, source[prev_start..prev_end], " \t\r");
        if (!std.mem.startsWith(u8, line, "//") or std.mem.startsWith(u8, line, "//!")) break;
        line_start = prev_start;
    }
    const end = if (line_end > range.end and source[line_end - 1] == '\r') line_end - 1 else line_end;
    return .{ .start = @intCast(line_start), .end = @intCast(end), .decl = range.start, .name = c.name, .what = c.what };
}

/// 块中使用的换行
fn newline(source: []const u8, b: Block) []const u8 {
    const line_end = std.mem.indexOfScalarPos(u8, source, b.entries[0].decl, '\n') orelse return "\n";
    return if (line_end > 0 and source[line_end - 1] == '\r') "\r\n" else "\n";
}

// ── 排序 ─────────────────────────────────────────────────────────────

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

/// 自动导入加入的一条：`text` 为它的源码
const Extra = struct { entry: Entry, text: []const u8 };

/// 块（加上 `extra`）整理后的文本
fn render(a: Allocator, source: []const u8, entries: []const Entry, extra: ?Extra, nl: []const u8, opts: Options) Allocator.Error![]const u8 {
    var all: std.ArrayList(Entry) = .empty;
    try all.appendSlice(a, entries);
    if (extra) |x| try all.append(a, x.entry);
    const items = all.items;
    const texts = try a.alloc([]const u8, items.len);
    for (items, texts, 0..) |e, *t, i| t.* = if (extra != null and i == items.len - 1) extra.?.text else source[e.start..e.end];

    // 派生声明的上级：依赖的声明在同一块中时
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
        // 跟在上级之后的派生声明由上级带出
        if (g == .derived and opts.derived == .with_import and p != null) continue;
        try groups[@backingInt(g)].append(a, i);
    }
    // 组之间空一行
    var out: std.ArrayList(u8) = .empty;
    for (&groups) |*group| {
        if (group.items.len == 0) continue;
        std.mem.sort(usize, group.items, ctx, SortCtx.less);
        if (out.items.len != 0) try out.appendSlice(a, nl);
        for (group.items) |i| try emit(a, &out, ctx, texts, parent, i, nl);
    }
    return out.items;
}

/// 输出一行，`with_import` 时随后输出跟在它之后的派生声明
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

    /// 同一组中的两条（`std` 组总是按固定顺序）
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

/// 文件路径：`../` 少的（离得近的）在前，然后逐段比较
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

/// 逐段比较，前面各段相同时段少的在前
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

/// rustfmt 的 version sort（Rust Style Guide 的 Sorting 一节）：按连续的数字与非数字分段，数字段按数值比较（数值相同时
/// 记下第一处前导零多的一方，其余都相同时它在前），其他段按字节比较（大写字母在小写字母之前），`_` 排在一切字符之前
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

// ── 插入的编辑 ───────────────────────────────────────────────────────

/// 整理好的块变为 `text`（只多出新的一条与可能的空行）：按行比较，只替换不同的行
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
    // 第 i 行的行首（相对源码）
    var starts = try a.alloc(u32, old.len + 1);
    starts[0] = b.start;
    for (old, 0..) |l, i| starts[i + 1] = starts[i] + @as(u32, @intCast(l.len + nl.len));
    var out: std.ArrayList(u8) = .empty;
    const middle = new[p .. new.len - s];
    if (p + s == old.len and s == 0) {
        // 追加在块末尾：插在下一行行首；文件以块结尾、没有换行时补上换行
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
