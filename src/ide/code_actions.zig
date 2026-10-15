//! textDocument/codeAction 的快速修复：
//! - 未使用的局部名字（AstGen 的 `unused ...` 诊断）：插入 `_ = name;`
//! - 多余的丢弃（`pointless discard of ...`）：删除 `_ = name;`
//! - switch 缺少的枚举 / 联合分支：补上 `.name => {},`
//! - 结构体初始化缺少的字段（没有默认值的）：补上 `.name = undefined`
//!
//! 以及重构：选中的表达式提取为局部常量。

const std = @import("std");
const Allocator = std.mem.Allocator;
const database = @import("../database.zig");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Def = resolve.Def;
const Body = @import("../hir/Body.zig");
const ast = @import("../syntax/ast.zig");
const queries = @import("../sema/queries.zig");
const InternPool = @import("../sema/InternPool.zig");
const Index = InternPool.Index;
const FileId = @import("../base/Vfs.zig").FileId;
const definition = @import("definition.zig");

pub const Edit = struct { start: u32, end: u32, text: []const u8 };

pub const Action = struct {
    title: []const u8,
    kind: Kind = .quickfix,
    edits: []const Edit,
    /// 所修复的诊断（`live.AstCheck` 的位置）；没有对应诊断时为 null
    diagnostic: ?struct { start: u32, end: u32 } = null,

    pub const Kind = enum { quickfix, refactor_extract };
};

/// `[start, end]` 区间内可用的快速修复
pub fn codeActions(r: *Resolver, file: FileId, start: u32, end: u32) resolve.Error![]const Action {
    var out: std.ArrayList(Action) = .empty;
    const text = (try r.ctx.get(database.syntax.SourceText, file)).text;
    const check = try r.ctx.get(database.live.AstCheck, file);
    for (check.items) |d| {
        if (d.end < start or d.start > end) continue;
        const edit = if (std.mem.startsWith(u8, d.message, "unused ") and !std.mem.endsWith(u8, d.message, " label"))
            try discard(r, file, text, d.start)
        else if (std.mem.startsWith(u8, d.message, "pointless discard of "))
            removeDiscard(text, d.start)
        else
            null;
        const e = edit orelse continue;
        const name = ast.identName(text[d.start..d.end]);
        try out.append(r.arena, .{
            .title = try std.fmt.allocPrint(r.arena, "{s} `{s}`", .{ if (e.text.len == 0) "remove discard of" else "discard", name }),
            .edits = try r.arena.dupe(Edit, &.{e}),
            .diagnostic = .{ .start = d.start, .end = d.end },
        });
    }
    if (try missingProngs(r, file, text, start)) |a| try out.append(r.arena, a);
    if (try missingFields(r, file, text, start)) |a| try out.append(r.arena, a);
    if (try extractVariable(r, file, text, start, end)) |a| try out.append(r.arena, a);
    return out.items;
}

/// 选中的表达式（两端空白不计）提取为所在语句之前的局部常量，原处替换为它的名字。
/// 赋值的左侧、取地址的操作数与控制流表达式不提取（提取后语义改变或不合法）
fn extractVariable(r: *Resolver, file: FileId, text: []const u8, sel_start: u32, sel_end: u32) resolve.Error!?Action {
    var start = sel_start;
    var end = @min(sel_end, @as(u32, @intCast(text.len)));
    while (start < end and std.ascii.isWhitespace(text[start])) start += 1;
    while (end > start and std.ascii.isWhitespace(text[end - 1])) end -= 1;
    if (start == end) return null;

    const item = try r.ownerAt(file, start, false) orelse return null;
    const base = try r.itemOffset(file, item) orelse return null;
    const b = try r.body(file, item);
    if (start < base) return null;
    const rel_start = start - base;
    const rel_end = end - base;
    var expr: ?Body.ExprId = null;
    for (b.expr_ranges, 0..) |range, i| if (range.start == rel_start and range.end == rel_end) {
        expr = @fromBackingInt(@as(u32, @intCast(i)));
    };
    const e = expr orelse return null;
    switch (b.expr(e)) {
        .missing, .@"return", .@"break", .@"continue", .@"unreachable", .assign, .block, .loop, .container => return null,
        else => {},
    }
    const within = struct {
        fn f(body: *const Body, outer: Body.ExprId, rs: u32, re: u32) bool {
            const range = body.range(outer);
            return range.start <= rs and re <= range.end;
        }
    }.f;
    for (b.exprs) |x| switch (x) {
        .assign => |a| if (a.lhs == e) return null,
        .prefix => |p| if (p.op == .ampersand and p.operand == e) return null,
        // 循环的条件与 `: (cont)` 每轮都会求值，提取到循环之前只求值一次
        .loop => |l| if (l.kind == .@"while") {
            for (l.inputs) |in| if (within(b, in, rel_start, rel_end)) return null;
            if (l.cont) |c| if (within(b, c, rel_start, rel_end)) return null;
        },
        else => {},
    };

    // 所在语句：块的直接子节点
    const root = (try r.ctx.get(database.syntax.ParseFile, file)).rootNode();
    const path = try root.coveringPath(r.arena, start);
    var stmt: ?ast.SyntaxNode = null;
    for (path[1..], 1..) |n, i| {
        if (path[i - 1].kind() == .block and n.range().end >= end) stmt = n;
    }
    const s = stmt orelse return null;

    // 名字：Zig 不允许遮蔽，选一个在此处不可见、本成员中也没有绑定的名字
    var buf: [16]u8 = undefined;
    const name = for (0..100) |n| {
        const candidate = if (n == 0) "value" else std.fmt.bufPrint(&buf, "value{d}", .{n}) catch unreachable;
        if (try r.resolveName(file, item, b, b.expr_scopes[@backingInt(e)], candidate) != null) continue;
        for (b.bindings) |binding| {
            if (std.mem.eql(u8, binding.name, candidate)) break;
        } else break try r.arena.dupe(u8, candidate);
    } else return null;

    const indent = lineIndent(text, s.offset);
    const new_text = try std.fmt.allocPrint(r.arena, "const {s} = {s};\n{s}{s}{s}", .{ name, text[start..end], indent, text[s.offset..start], name });
    return .{
        .title = "extract to local constant",
        .kind = .refactor_extract,
        .edits = try r.arena.dupe(Edit, &.{.{ .start = s.offset, .end = end, .text = new_text }}),
    };
}

/// 在名字 `offset` 处的局部绑定之后（局部变量的语句之后、参数或捕获所在块的开头）插入 `_ = name;`
fn discard(r: *Resolver, file: FileId, text: []const u8, offset: u32) resolve.Error!?Edit {
    const def = try definition.defAt(r, file, offset) orelse return null;
    const l = switch (def) {
        .local => |l| l,
        else => return null,
    };
    const b = try r.body(file, l.item);
    const base = (try r.itemNode(file, l.item) orelse return null).offset;
    const binding = b.binding(l.binding);
    const line = try std.fmt.allocPrint(r.arena, "_ = {s};", .{text[offset .. offset + tokenLen(text, offset)]});
    switch (binding.kind) {
        .local_const, .local_var => {
            const s = localStmt(b, l.binding) orelse return null;
            const at = base + s.end;
            return .{ .start = at, .end = at, .text = try std.fmt.allocPrint(r.arena, "\n{s}{s}", .{ lineIndent(text, base + binding.range.start), line }) };
        },
        .param => return blockStart(r, text, base, b, b.value orelse return null, line),
        .capture => return blockStart(r, text, base, b, captureBody(b, l.binding) orelse return null, line),
    }
}

/// 名字 token 的长度（含 `@"..."`）
fn tokenLen(text: []const u8, offset: u32) u32 {
    if (std.mem.startsWith(u8, text[offset..], "@\"")) {
        const close = std.mem.indexOfScalarPos(u8, text, offset + 2, '"') orelse return 0;
        return @intCast(close + 1 - offset);
    }
    var i = offset;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) i += 1;
    return i - offset;
}

/// 在块表达式 `e` 的 `{` 之后插入一行
fn blockStart(r: *Resolver, text: []const u8, base: u32, b: *const Body, e: Body.ExprId, line: []const u8) resolve.Error!?Edit {
    if (b.expr(e) != .block) return null;
    const range = b.range(e);
    const brace = std.mem.indexOfScalarPos(u8, text[0 .. base + range.end], base + range.start, '{') orelse return null;
    const at: u32 = @intCast(brace + 1);
    return .{ .start = at, .end = at, .text = try std.fmt.allocPrint(r.arena, "\n{s}    {s}", .{ lineIndent(text, at - 1), line }) };
}

fn localStmt(b: *const Body, id: Body.BindingId) ?Body.Stmt {
    for (b.exprs) |e| switch (e) {
        .block => |blk| for (blk.stmts) |s| switch (s.kind) {
            .local => |x| if (x == id) return s,
            else => {},
        },
        else => {},
    };
    return null;
}

/// 捕获所在的主体表达式
fn captureBody(b: *const Body, id: Body.BindingId) ?Body.ExprId {
    const has = struct {
        fn f(list: []const Body.BindingId, x: Body.BindingId) bool {
            return std.mem.indexOfScalar(Body.BindingId, list, x) != null;
        }
    }.f;
    for (b.exprs) |e| switch (e) {
        .@"if" => |x| {
            if (has(x.capture, id)) return x.then;
            if (has(x.else_capture, id)) return x.@"else";
        },
        .loop => |x| {
            if (has(x.capture, id)) return x.body;
            if (has(x.else_capture, id)) return x.@"else";
        },
        .@"switch" => |x| for (x.prongs) |p| if (has(p.capture, id)) return p.body,
        .@"catch" => |x| if (x.capture == id) return x.rhs,
        .block => |blk| for (blk.stmts) |s| switch (s.kind) {
            .@"errdefer" => |x| if (x.capture == id) return x.body,
            else => {},
        },
        else => {},
    };
    return null;
}

/// 删除 `offset` 处的 `_ = name;` 所在行（该行只有这一条语句时删整行）
fn removeDiscard(text: []const u8, offset: u32) ?Edit {
    const line_start: u32 = @intCast(if (std.mem.lastIndexOfScalar(u8, text[0..offset], '\n')) |i| i + 1 else 0);
    const line_end: u32 = @intCast(std.mem.indexOfScalarPos(u8, text, offset, '\n') orelse text.len);
    const line = std.mem.trim(u8, text[line_start..line_end], " \t\r");
    if (!std.mem.startsWith(u8, line, "_ =") or !std.mem.endsWith(u8, line, ";") or std.mem.count(u8, line, ";") != 1) return null;
    return .{ .start = line_start, .end = @min(line_end + 1, @as(u32, @intCast(text.len))), .text = "" };
}

/// 包含 `offset` 的最内层某种表达式
fn innermost(r: *Resolver, file: FileId, offset: u32, comptime tag: std.meta.Tag(Body.Expr)) resolve.Error!?struct { item: u32, base: u32, body: *const Body, expr: Body.ExprId } {
    const item = try r.ownerAt(file, offset, true) orelse return null;
    const node = try r.itemNode(file, item) orelse return null;
    const b = try r.body(file, item);
    if (offset < node.offset) return null;
    const rel = offset - node.offset;
    var best: ?Body.ExprId = null;
    var best_len: u32 = std.math.maxInt(u32);
    for (b.exprs, b.expr_ranges, 0..) |e, range, i| {
        if (e != tag or rel < range.start or rel > range.end) continue;
        if (range.end - range.start < best_len) {
            best_len = range.end - range.start;
            best = @fromBackingInt(@as(u32, @intCast(i)));
        }
    }
    return .{ .item = item, .base = node.offset, .body = b, .expr = best orelse return null };
}

fn missingProngs(r: *Resolver, file: FileId, text: []const u8, offset: u32) resolve.Error!?Action {
    const at = try innermost(r, file, offset, .@"switch") orelse return null;
    const sw = at.body.expr(at.expr).@"switch";
    var covered: std.StringHashMapUnmanaged(void) = .empty;
    for (sw.prongs) |p| {
        if (p.is_else) return null;
        for (p.items) |i| switch (at.body.expr(i)) {
            .enum_literal => |n| try covered.put(r.arena, ast.identName(n), {}),
            // 非穷尽枚举的 `_`
            .name_ref => |n| if (std.mem.eql(u8, n, "_")) return null,
            else => {},
        };
    }
    const res = try r.ctx.get(queries.Infer, .{ .owner = try r.ownerKey(file, at.item), .mode = .full });
    if (res.exprs.len != at.body.exprs.len) return null;
    const ip = r.ctx.db.env.ip;
    var ty = res.exprs[@backingInt(sw.operand)].ty;
    if (ip.key(ty) == .union_tag_type) ty = ip.key(ty).union_tag_type;
    const kind = switch (ip.key(ty)) {
        .container_type => |c| c.kind,
        else => return null,
    };
    if (kind != .@"enum" and kind != .@"union") return null;
    const ns = try queries.namespaceOfType(r, ty) orelse return null;
    const tree = try r.itemTree(ns.file);
    var items: std.ArrayList([]const u8) = .empty;
    for (tree.containerMembers(ns.container)) |m| {
        const it = tree.items[m];
        if (it.kind != .field) continue;
        const name = it.name orelse continue;
        if (covered.contains(ast.identName(name))) continue;
        try items.append(r.arena, try std.fmt.allocPrint(r.arena, ".{s} => {{}}", .{name}));
    }
    if (items.items.len == 0) return null;
    const edit = try appendBeforeClose(r.arena, text, at.base + at.body.range(at.expr).start, at.base + at.body.range(at.expr).end, items.items, true) orelse return null;
    return .{ .title = "add missing switch prongs", .edits = try r.arena.dupe(Edit, &.{edit}) };
}

fn missingFields(r: *Resolver, file: FileId, text: []const u8, offset: u32) resolve.Error!?Action {
    const at = try innermost(r, file, offset, .init) orelse return null;
    const init = at.body.expr(at.expr).init;
    for (init.fields) |f| if (f.name == null) return null;
    const res = try r.ctx.get(queries.Infer, .{ .owner = try r.ownerKey(file, at.item), .mode = .full });
    if (res.exprs.len != at.body.exprs.len) return null;
    const ty = res.exprs[@backingInt(at.expr)].ty;
    switch (r.ctx.db.env.ip.key(ty)) {
        .container_type => |c| if (c.kind != .@"struct") return null,
        else => return null,
    }
    const ns = try queries.namespaceOfType(r, ty) orelse return null;
    const tree = try r.itemTree(ns.file);
    const map = try r.ctx.get(database.syntax.FileAstIdMap, ns.file);
    var items: std.ArrayList([]const u8) = .empty;
    outer: for (tree.containerMembers(ns.container)) |m| {
        const it = tree.items[m];
        if (it.kind != .field) continue;
        const name = it.name orelse continue;
        for (init.fields) |f| if (std.mem.eql(u8, ast.identName(f.name.?), ast.identName(name))) continue :outer;
        const node = map.get(it.ast_id) orelse continue;
        if (ast.cast(ast.ContainerField, node)) |cf| if (cf.defaultValue() != null) continue;
        try items.append(r.arena, try std.fmt.allocPrint(r.arena, ".{s} = undefined", .{name}));
    }
    if (items.items.len == 0) return null;
    const start = at.base + at.body.range(at.expr).start;
    const end = at.base + at.body.range(at.expr).end;
    const multiline = std.mem.indexOfScalar(u8, text[start..end], '\n') != null;
    const edit = try appendBeforeClose(r.arena, text, start, end, items.items, multiline) orelse return null;
    return .{ .title = "add missing struct fields", .edits = try r.arena.dupe(Edit, &.{edit}) };
}

/// 在 `[start, end)`（以 `}` 结尾）的 `}` 之前追加条目：多行时每条一行并带结尾逗号，
/// 单行时以 `, ` 分隔（不加结尾逗号，否则 zig fmt 会展开成多行）
fn appendBeforeClose(a: Allocator, text: []const u8, start: u32, end: u32, items: []const []const u8, multiline: bool) Allocator.Error!?Edit {
    if (end == 0 or end > text.len or text[end - 1] != '}') return null;
    const close = end - 1;
    var p = close;
    while (p > start and std.ascii.isWhitespace(text[p - 1])) p -= 1;
    const prev = text[p - 1];
    var out: std.ArrayList(u8) = .empty;
    if (prev != ',' and prev != '{') try out.append(a, ',');
    if (multiline) {
        const indent = lineIndent(text, start);
        for (items) |it| try out.print(a, "\n{s}    {s},", .{ indent, it });
        try out.print(a, "\n{s}", .{indent});
    } else {
        for (items, 0..) |it, i| try out.print(a, "{s}{s}", .{ if (i == 0) " " else ", ", it });
        try out.append(a, ' ');
    }
    return .{ .start = p, .end = close, .text = out.items };
}

/// `offset` 所在行的缩进
fn lineIndent(text: []const u8, offset: u32) []const u8 {
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..offset], '\n')) |i| i + 1 else 0;
    var i = line_start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return text[line_start..i];
}

test {
    _ = @import("code_actions_test.zig");
}
