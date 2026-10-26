//! textDocument/codeAction 的快速修复：
//! - 未使用的局部名字（AstGen 的 `unused ...` 诊断）：插入 `_ = name;`
//! - 多余的丢弃（`pointless discard of ...`）：删除 `_ = name;`
//! - switch 缺少的枚举 / 联合分支：补上 `.name => {},`
//! - 结构体初始化缺少的字段（没有默认值的）：补上 `.name = undefined`
//!
//! 重构：选中的表达式提取为局部常量，普通字符串与多行字符串无损互转。源码操作：整理 import（见 `ide_db/organize_imports.zig`）。

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
const render = @import("../sema/render.zig");
const organize_imports = @import("../ide_db/organize_imports.zig");
const format = @import("format.zig");

pub const Edit = struct { start: u32, end: u32, text: []const u8 };

pub const Action = struct {
    title: []const u8,
    kind: Kind = .quickfix,
    edits: []const Edit,
    /// 所修复的诊断（`live.AstCheck` 的位置）；没有对应诊断时为 null
    diagnostic: ?struct { start: u32, end: u32 } = null,

    pub const Kind = enum { quickfix, refactor_extract, refactor_rewrite, source_organize_imports };
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
    if (try convertString(r, file, text, start, end)) |a| try out.append(r.arena, a);
    return out.items;
}

/// 整理文件中的全部 import 块（`source.organizeImports`）。客户端明确要求这一类时（`requested`）总是提供，否则只在
/// `[start, end]` 与某个块相交时提供；已经整理好时不提供
pub fn organizeImports(r: *Resolver, file: FileId, start: u32, end: u32, opts: organize_imports.Options, requested: bool) resolve.Error!?Action {
    const parse = try r.ctx.get(database.syntax.ParseFile, file);
    const result = try organize_imports.organize(r.arena, parse, opts);
    if (result.edits.len == 0) return null;
    if (!requested) {
        const inside = for (result.blocks) |b| {
            if (start <= b.end and end >= b.start) break true;
        } else false;
        if (!inside) return null;
    }
    const edits = try r.arena.alloc(Edit, result.edits.len);
    for (result.edits, edits) |e, *out| out.* = .{ .start = e.start, .end = e.end, .text = e.text };
    return .{ .title = "Organize imports", .kind = .source_organize_imports, .edits = edits };
}

/// 只替换完整的字符串字面量；多行形式按 token 解码，避免把源码缩进或 CRLF 计入字符串值。排版与 `zig fmt` 一致
/// （见 `zigFmtEdit`）
fn convertString(r: *Resolver, file: FileId, text: []const u8, sel_start: u32, sel_end: u32) resolve.Error!?Action {
    var start = sel_start;
    var end = @min(sel_end, @as(u32, @intCast(text.len)));
    if (start > end) return null;
    while (start < end and std.ascii.isWhitespace(text[start])) start += 1;
    while (end > start and std.ascii.isWhitespace(text[end - 1])) end -= 1;
    const root = (try r.ctx.get(database.syntax.ParseFile, file)).rootNode();
    const path = try root.coveringPath(r.arena, start);
    var literal: ?ast.SyntaxNode = null;
    for (path) |n| if (n.kind() == .literal) {
        literal = n;
    };
    const node = literal orelse return null;
    const first = node.firstToken() orelse return null;
    const multiline = first.kind == .multiline_string_literal_line;
    if (!multiline and first.kind != .string_literal) return null;
    var last = first;
    var bytes: std.ArrayList(u8) = .empty;
    var children = node.children();
    var count: usize = 0;
    while (children.next()) |child| {
        if (child != .token) return null;
        const t = child.token;
        if (t.kind == .whitespace) continue;
        if (t.kind != first.kind) return null;
        last = t;
        if (multiline) {
            if (count != 0) try bytes.append(r.arena, '\n');
            const line = std.mem.trimEnd(u8, t.text[2..], "\r\n");
            try bytes.appendSlice(r.arena, line);
        }
        count += 1;
    }
    const literal_end = last.range().end;
    if (start < first.offset or start >= literal_end or end > literal_end) return null;
    var edit_start = first.offset;
    const replacement = if (multiline)
        try std.fmt.allocPrint(r.arena, "\"{f}\"", .{std.zig.fmtString(bytes.items)})
    else blk: {
        const value = try Body.stringLiteralValue(r.arena, first.text) orelse return null;
        // 多行字符串不支持转义，控制字节（包括 TAB、CR）与非法 UTF-8 不能原样写入源码。
        if (!std.unicode.utf8ValidateSlice(value)) return null;
        for (value) |c| if (c != '\n' and std.ascii.isControl(c)) return null;
        const indent = lineIndent(text, first.offset);
        const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..first.offset], '\n')) |i| i + 1 else 0;
        const own_line = line_start + indent.len == first.offset;
        const newline: []const u8 = if (std.mem.indexOf(u8, text, "\r\n") != null) "\r\n" else "\n";
        var out: std.ArrayList(u8) = .empty;
        if (!own_line) {
            // 字面量换到下一行：不留行尾空白
            while (edit_start > line_start and (text[edit_start - 1] == ' ' or text[edit_start - 1] == '\t')) edit_start -= 1;
            try out.appendSlice(r.arena, newline);
            try out.appendSlice(r.arena, indent);
            try out.appendSlice(r.arena, "    ");
        }
        var lines = std.mem.splitScalar(u8, value, '\n');
        var first_line = true;
        while (lines.next()) |line| {
            if (!first_line) {
                try out.appendSlice(r.arena, newline);
                try out.appendSlice(r.arena, indent);
                if (!own_line) try out.appendSlice(r.arena, "    ");
            }
            first_line = false;
            try out.appendSlice(r.arena, "\\\\");
            try out.appendSlice(r.arena, line);
        }
        // 后续分号、逗号或表达式必须位于新行，否则会成为字符串内容。
        try out.appendSlice(r.arena, newline);
        try out.appendSlice(r.arena, indent);
        break :blk out.items;
    };
    const raw: Edit = .{ .start = edit_start, .end = literal_end, .text = replacement };
    return .{
        .title = if (multiline) "convert to a string literal" else "convert to a multiline string literal",
        .kind = .refactor_rewrite,
        .edits = try r.arena.dupe(Edit, &.{try zigFmtEdit(r, file, text, raw)}),
    };
}

/// `raw` 替换之后按 `zig fmt` 排版：文件原本已按 `zig fmt` 格式化时，改为格式化替换后的全文、与原文的差异（按整行，
/// 只有替换附近的行，如多行字符串之后的 `;` 移到行首、元素改为每行一个的初始化列表、转换回普通字符串后合并的行）。
/// 文件没有格式化（格式化会改动无关的代码）、有语法错误或嵌套过深时保留 `raw`
fn zigFmtEdit(r: *Resolver, file: FileId, text: []const u8, raw: Edit) resolve.Error!Edit {
    const a = r.arena;
    const mode: format.Mode = if (std.mem.endsWith(u8, r.ctx.db.env.vfs.path(file), ".zon")) .zon else .zig;
    const before = try format.renderText(a, text, mode) orelse return raw;
    if (!std.mem.eql(u8, before, text)) return raw;
    const edited = try std.mem.concat(a, u8, &.{ text[0..raw.start], raw.text, text[raw.end..] });
    const after = try format.renderText(a, edited, mode) orelse return raw;
    const d = format.lineDiff(text, after);
    return .{ .start = @intCast(d.start), .end = @intCast(d.old_end), .text = after[d.start..d.new_end] };
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
    for (b.exprs) |x| switch (x) {
        .assign => |a| if (a.lhs == e) return null,
        .prefix => |p| if (p.op == .ampersand and p.operand == e) return null,
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
    // defer 等语句中的表达式不在语句处求值（或在 comptime 求值）
    switch (s.kind()) {
        .defer_stmt, .errdefer_stmt, .comptime_stmt, .suspend_stmt, .nosuspend_stmt => return null,
        else => {},
    }
    const res = try r.ctx.get(queries.Infer, .{ .owner = try r.ownerKey(file, item), .mode = .full });
    if (res.exprs.len != b.exprs.len) return null;
    const purity: Purity = .{ .r = r, .file = file, .item = item, .body = b, .res = res };
    if (s.offset < base or !try hoistable(purity, e, s.offset - base, s.range().end - base)) return null;
    // 类型取决于结果位置的表达式（`@intCast(x)` 等）：提取后显式标注原处的类型，标注不出时不提取
    const annotation: []const u8 = if (needsResultType(b, e)) blk: {
        const ty = res.exprs[@backingInt(e)].ty;
        if (!isPlainType(r.ctx.db.env.ip, ty)) return null;
        break :blk try std.fmt.allocPrint(r.arena, ": {s}", .{try render.typeAlloc(r, ty)});
    } else "";

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
    const new_text = try std.fmt.allocPrint(r.arena, "const {s}{s} = {s};\n{s}{s}{s}", .{ name, annotation, text[start..end], indent, text[s.offset..start], name });
    return .{
        .title = "extract to local constant",
        .kind = .refactor_extract,
        .edits = try r.arena.dupe(Edit, &.{.{ .start = s.offset, .end = end, .text = new_text }}),
    };
}

/// `e` 提取到所在语句（相对 owner 的 `[stmt_start, stmt_end)`）之前后，求值的条件、次数与顺序不变：
/// - `e` 不在有条件或重复求值的位置（`and` / `or` / `orelse` / `catch` 的右侧、`if` / `switch` 的分支、
///   循环的条件与循环体等）
/// - 语句中先于 `e` 求值的部分与 `e` 交换顺序不改变结果：两者之一是纯的（见 `Purity`）
fn hoistable(p: Purity, e: Body.ExprId, stmt_start: u32, stmt_end: u32) resolve.Error!bool {
    const b = p.body;
    const target = b.range(e);
    const in = struct {
        fn f(body: *const Body, child: ?Body.ExprId, t: Body.Range) bool {
            const range = body.range(child orelse return false);
            return range.start <= t.start and t.end <= range.end;
        }
    }.f;
    const e_pure = try p.pure(target);
    for (b.exprs, b.expr_ranges, 0..) |x, range, i| {
        if (i == @backingInt(e) or range.start < stmt_start or range.end > stmt_end) continue;
        if (!(range.start <= target.start and target.end <= range.end)) {
            // 先于 `e` 求值的部分有副作用（或读取可变的状态、可能提前退出），而 `e` 也不是纯的
            if (!e_pure and range.end <= target.start and try p.impure(@intCast(i))) return false;
            continue;
        }
        switch (x) {
            .binary => |bin| switch (bin.op) {
                .keyword_and, .keyword_or, .keyword_orelse => if (in(b, bin.rhs, target)) return false,
                else => {},
            },
            .@"catch" => |c| if (in(b, c.rhs, target)) return false,
            .@"if" => |f| if (in(b, f.then, target) or in(b, f.@"else", target)) return false,
            .@"switch" => |sw| for (sw.prongs) |pr| {
                if (in(b, pr.body, target)) return false;
                for (pr.items) |it| if (in(b, it, target)) return false;
            },
            .loop => |l| {
                if (in(b, l.body, target) or in(b, l.@"else", target) or in(b, l.cont, target)) return false;
                // while 的条件每轮都会求值
                if (l.kind == .@"while") for (l.inputs) |it| if (in(b, it, target)) return false;
            },
            .block, .@"comptime", .container, .other => return false,
            else => {},
        }
    }
    return true;
}

/// 表达式的纯度：纯的表达式没有副作用、不会提前退出，读取的也只有不可变的值（字面量、常量、参数、
/// 值捕获），与其他表达式交换求值顺序不改变结果（溢出等运行时检查失败的先后除外）
const Purity = struct {
    r: *Resolver,
    file: FileId,
    item: u32,
    body: *const Body,
    res: queries.Infer.Value,

    /// 区间 `range` 内的表达式都不是 `impure` 的
    fn pure(p: Purity, range: Body.Range) resolve.Error!bool {
        for (p.body.expr_ranges, 0..) |x, i| {
            if (x.start >= range.start and x.end <= range.end and try p.impure(@intCast(i))) return false;
        }
        return true;
    }

    /// 表达式自身（不含子表达式）有副作用、可能提前退出或读取可变的状态
    fn impure(p: Purity, i: u32) resolve.Error!bool {
        const b = p.body;
        const id: Body.ExprId = @fromBackingInt(i);
        return switch (b.expr(id)) {
            .call, .assign, .deref, .@"return", .@"break", .@"continue", .@"unreachable", .other => true,
            .prefix => |x| x.op == .keyword_try,
            .builtin_call => |c| for (pure_builtins) |n| {
                if (std.mem.eql(u8, c.name, n)) break false;
            } else true,
            .name_ref => |name| try p.mutableName(id, name),
            // 经由指针（含自动解引用）读取：所指向的内容可能被修改
            .field_access => |fa| p.viaPointer(fa.lhs) or try p.isVar(p.res.members[i]),
            .index => |x| p.viaPointer(x.lhs),
            else => false,
        };
    }

    fn mutableName(p: Purity, e: Body.ExprId, name: []const u8) resolve.Error!bool {
        const def = try p.r.resolveName(p.file, p.item, p.body, p.body.expr_scopes[@backingInt(e)], name) orelse
            return !(std.zig.primitives.isPrimitive(name) or for ([_][]const u8{ "_", "true", "false", "null", "undefined" }) |n| {
                if (std.mem.eql(u8, name, n)) break true;
            } else false);
        return switch (def) {
            .local => |l| (try p.r.body(l.file, l.item)).binding(l.binding).kind == .local_var,
            .item => |it| (try p.r.itemTree(it.file)).items[it.item].kind == .@"var",
            .file => false,
        };
    }

    fn viaPointer(p: Purity, lhs: Body.ExprId) bool {
        return switch (p.r.ctx.db.env.ip.key(p.res.exprs[@backingInt(lhs)].ty)) {
            .ptr_type, .unknown => true,
            else => false,
        };
    }

    fn isVar(p: Purity, member: ?database.hir.OwnerKey) resolve.Error!bool {
        const key = member orelse return false;
        const tree = try p.r.itemTree(key.file);
        for (tree.items) |it| if (it.ast_id == key.item) return it.kind == .@"var";
        return false;
    }
};

/// 没有副作用的内建函数
const pure_builtins = [_][]const u8{
    "@as",              "@sizeOf",          "@alignOf",   "@bitSizeOf",  "@TypeOf",       "@typeInfo",        "@typeName",
    "@This",            "@min",             "@max",       "@abs",        "@intFromEnum",  "@intFromBool",     "@tagName",
    "@errorName",       "@truncate",        "@intCast",   "@floatCast",  "@floatFromInt", "@intFromFloat",    "@enumFromInt",
    "@bitCast",         "@ptrCast",         "@alignCast", "@constCast",  "@splat",        "@import",          "@hasDecl",
    "@hasField",        "@offsetOf",        "@divTrunc",  "@divFloor",   "@divExact",     "@mod",             "@rem",
    "@shlExact",        "@shrExact",        "@sqrt",      "@floor",      "@ceil",         "@round",           "@clz",
    "@ctz",             "@popCount",        "@byteSwap",  "@bitReverse", "@mulAdd",       "@addWithOverflow", "@subWithOverflow",
    "@mulWithOverflow", "@shlWithOverflow", "@Vector",    "@Type",       "@embedFile",    "@src",
};

/// 类型由结果位置决定的转换（与 `Infer` 的 `casts` 一致）
const result_typed_builtins = [_][]const u8{
    "@intCast", "@truncate",  "@floatCast",     "@floatFromInt", "@intFromFloat",   "@enumFromInt", "@bitCast",
    "@ptrCast", "@alignCast", "@addrSpaceCast", "@ptrFromInt",   "@fieldParentPtr", "@errorCast",   "@splat",
};

/// 表达式的类型（或合法性）取决于结果位置：单独作为 `const` 的初始值时须标注类型
fn needsResultType(b: *const Body, e: Body.ExprId) bool {
    return switch (b.expr(e)) {
        .builtin_call => |c| for (result_typed_builtins) |n| {
            if (std.mem.eql(u8, c.name, n)) break true;
        } else false,
        .init => |i| i.ty == null,
        .enum_literal => true,
        .name_ref => |n| std.mem.eql(u8, n, "undefined") or std.mem.eql(u8, n, "null"),
        .@"if" => |f| needsResultType(b, f.then) or (if (f.@"else") |x| needsResultType(b, x) else false),
        .@"switch" => |sw| for (sw.prongs) |p| {
            if (needsResultType(b, p.body)) break true;
        } else false,
        .@"catch" => |c| needsResultType(b, c.lhs) or needsResultType(b, c.rhs),
        .binary => |bin| bin.op == .keyword_orelse and (needsResultType(b, bin.lhs) or needsResultType(b, bin.rhs)),
        .prefix => |p| p.op == .keyword_try and needsResultType(b, p.operand),
        else => false,
    };
}

/// 只由内建类型组成、在任何作用域都能原样写出的类型
fn isPlainType(ip: *InternPool, t: Index) bool {
    return switch (ip.key(t)) {
        .int_type => true,
        .simple_type => |st| switch (st) {
            .type, .noreturn, .comptime_int, .comptime_float, .null, .undefined, .enum_literal => false,
            else => true,
        },
        .ptr_type => |p| p.sentinel == null and isPlainType(ip, p.child),
        .array_type => |a| a.sentinel == null and isPlainType(ip, a.child),
        .optional_type => |c| isPlainType(ip, c),
        else => false,
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
        try items.append(r.arena, try std.fmt.allocPrint(r.arena, ".{f} => {{}}", .{std.zig.fmtIdP(ast.identName(name))}));
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
        try items.append(r.arena, try std.fmt.allocPrint(r.arena, ".{f} = undefined", .{std.zig.fmtIdP(ast.identName(name))}));
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
