//! 未使用的函数参数（AstGen 的 `unused function parameter`）的快速修复：删除参数，同时删除全部调用处对应的实参。
//!
//! 只给出完整而正确的编辑。函数的每一处引用都必须是直接调用（`f(...)`、`x.f(...)`、`S.f(...)`、`.f(...)`），
//! 实参与参数一一对应；以其他方式使用函数（作为值传递、取地址、`@call`、`@TypeOf`）、引用无法确认（歧义、类型
//! 未知、有语法错误的文件）、名字以字符串出现（反射）、删除的实参有副作用时都不改。方法的接收者、`export` /
//! `extern` 函数与可变参数函数不提供。删除之后以 AstGen 确认各个文件没有新的错误（如调用处的局部名字不再被使用）。

const std = @import("std");
const Allocator = std.mem.Allocator;
const database = @import("../database.zig");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Def = resolve.Def;
const Body = @import("../hir/Body.zig");
const ast = @import("../syntax/ast.zig");
const tree = @import("../syntax/tree.zig");
const SyntaxNode = tree.SyntaxNode;
const SyntaxToken = tree.SyntaxToken;
const TextRange = tree.TextRange;
const kind_mod = @import("../syntax/kind.zig");
const InternPool = @import("../sema/InternPool.zig");
const TypedValue = InternPool.TypedValue;
const FileId = @import("../base/Vfs.zig").FileId;
const search = @import("../ide_db/search.zig");
const seed = @import("../ide_db/seed.zig");
const rename = @import("rename.zig");
const code_actions = @import("code_actions.zig");
const builtins = @import("builtins.zig");

pub const unused_message = "unused function parameter";

/// 可以删除的参数
pub const Target = struct {
    file: FileId,
    /// 函数（`ItemTree.items` 下标）
    item: u32,
    /// 参数在参数列表中的下标
    index: u32,
    /// 参数的名字（去掉 `@"..."` 的引号）
    name: []const u8,
    /// 参数名 token 的位置（即诊断的位置）
    start: u32,
    end: u32,
    /// 函数是 pub 的：其他文件可能调用它
    public: bool,
};

/// 不能删除的原因
pub const Problem = struct {
    file: FileId,
    /// 问题所在的位置（字节偏移）；为 null 时问题在整个文件
    offset: ?u32,
    message: []const u8,
};

pub const Outcome = union(enum) {
    /// 各文件的编辑，按文件排列
    ok: []const rename.FileEdits,
    failed: Problem,
};

/// `[start, end]` 区间内的未使用的参数中可以删除的
pub fn targets(r: *Resolver, file: FileId, start: u32, end: u32) resolve.Error![]const Target {
    var out: std.ArrayList(Target) = .empty;
    const check = try r.ctx.get(database.live.AstCheck, file);
    for (check.items) |d| {
        if (d.end < start or d.start > end) continue;
        if (!std.mem.eql(u8, d.message, unused_message)) continue;
        if (try target(r, file, d.start)) |t| try out.append(r.arena, t);
    }
    return out.items;
}

/// 名字位于 `offset` 处的参数：函数须有函数体，不是 `export` / `extern` / 可变参数函数，参数不是方法的接收者
pub fn target(r: *Resolver, file: FileId, offset: u32) resolve.Error!?Target {
    const item = try r.ownerAt(file, offset, false) orelse return null;
    const it = (try r.itemTree(file)).items[item];
    if (it.kind != .@"fn" or it.flags.is_export or it.flags.is_extern or it.flags.varargs) return null;
    const decl = ast.cast(ast.FnDecl, try r.itemNode(file, item) orelse return null) orelse return null;
    if (decl.body() == null) return null;
    var params = (decl.proto() orelse return null).params();
    var index: u32 = 0;
    const tok = while (params.next()) |p| : (index += 1) {
        const name = (ast.Param{ .syntax = p }).name() orelse continue;
        if (name.offset == offset) break name;
    } else return null;
    if (index == 0 and try isReceiver(r, file, item)) return null;
    return .{
        .file = file,
        .item = item,
        .index = index,
        .name = ast.identName(tok.text),
        .start = tok.offset,
        .end = tok.offset + @as(u32, @intCast(tok.text.len)),
        .public = it.flags.is_pub,
    };
}

/// 函数的第一个参数是否为方法的接收者：类型为函数所在的容器，或指向它的单项指针
fn isReceiver(r: *Resolver, file: FileId, item: u32) resolve.Error!bool {
    const items = try r.itemTree(file);
    const container = items.items[item].container;
    const b = try r.body(file, item);
    if (b.params.len == 0) return false;
    // 按名字求出容器（`@This()`、`Self`）；求不出时（类型函数的结果等）看推导出的签名
    if (b.binding(b.params[0]).ty) |ty| {
        const e = switch (b.expr(ty)) {
            .ptr_type => |p| if (p.size == .one) p.child else ty,
            else => ty,
        };
        if (try r.evalNamespace(file, item, b, e)) |ns| return ns.file == file and ns.container == container;
    }
    const ip = r.ctx.db.env.ip;
    const tv = try r.ctx.get(database.sema.DeclType, .{ .owner = try r.ownerKey(file, item) });
    const signature = switch (ip.key(tv.ty)) {
        .fn_type => |f| f,
        else => return false,
    };
    if (signature.params.len == 0) return false;
    const receiver = switch (ip.key(signature.params[0])) {
        .ptr_type => |p| if (p.size == .one) p.child else signature.params[0],
        else => signature.params[0],
    };
    return switch (ip.key(receiver)) {
        .container_type => |c| c.file == file and c.ast_id == items.containers[container].ast_id,
        else => false,
    };
}

/// 删除参数 `t` 与全部调用处对应的实参的编辑。`scope` 为查找引用的范围（项目中的文件）
pub fn edits(r: *Resolver, t: Target, scope: []const FileId) resolve.Error!Outcome {
    const def: Def = .{ .item = .{ .file = t.file, .item = t.item } };
    var ambiguous: ?search.Reference = null;
    var uncertain: ?search.Reference = null;
    var incomplete: ?search.Reference = null;
    var syntax_error: ?FileId = null;
    const refs = try search.findReferences(r, def, .{
        .scope = scope,
        .ambiguous = &ambiguous,
        .uncertain = &uncertain,
        .incomplete = &incomplete,
        .syntax_error = &syntax_error,
    });
    if (syntax_error) |f| return fail(f, null, "the file has syntax errors, so calls in it may be missed");
    if (ambiguous) |a| return fail(a.file, a.start, "this reference inside a generic function also refers to other declarations in some instantiations");
    if (uncertain) |u| return fail(u.file, u.start, "the type here is unknown, so whether this refers to the function cannot be confirmed");
    if (incomplete) |u| return fail(u.file, u.start, "this reference depends on instantiations of a generic function that grow without bound, so not all of them can be checked");
    // 不是 pub 的函数只能在所在的文件中访问
    const files = if (t.public) try search.importers(r, t.file, scope) else try r.arena.dupe(FileId, &.{t.file});
    const fn_name = (try r.itemTree(t.file)).items[t.item].name orelse return fail(t.file, t.start, "the function has no name");
    if (try rename.stringReference(r, files, fn_name)) |p| return fail(p.file, p.offset, p.message);

    const decl = ast.cast(ast.FnDecl, try r.itemNode(t.file, t.item) orelse return fail(t.file, t.start, "the function could not be found")).?;
    const proto = decl.proto() orelse return fail(t.file, t.start, "the function could not be found");
    const param_list = proto.syntax.childNode(.param_list) orelse return fail(t.file, t.start, "the parameter list could not be found");
    var param_count: u32 = 0;
    var params = proto.params();
    while (params.next()) |_| param_count += 1;

    var by_file: std.AutoArrayHashMapUnmanaged(FileId, std.ArrayList(rename.Edit)) = .empty;
    const param_text = (try r.ctx.get(database.syntax.SourceText, t.file)).text;
    const param_edit = try removeItem(r.arena, param_text, param_list, t.index) orelse return fail(t.file, t.start, "the parameter list could not be edited");
    try addEdit(r.arena, &by_file, t.file, param_edit);
    for (refs) |ref| {
        if (ref.is_decl) continue;
        switch (try callSite(r, ref, t.index, param_count)) {
            .skip => {},
            .edit => |e| try addEdit(r.arena, &by_file, ref.file, e),
            .failed => |p| return .{ .failed = p },
        }
    }

    const out = try r.arena.alloc(rename.FileEdits, by_file.count());
    for (by_file.keys(), by_file.values(), out) |file, *list, *o| {
        std.mem.sort(rename.Edit, list.items, {}, struct {
            fn lt(_: void, a: rename.Edit, b: rename.Edit) bool {
                return a.start < b.start;
            }
        }.lt);
        // 删除的实参中的调用（类型函数）随之删除：去掉位于其他编辑之内的编辑
        var kept: std.ArrayList(rename.Edit) = .empty;
        for (list.items) |e| {
            if (kept.items.len > 0) {
                const prev = kept.items[kept.items.len - 1];
                if (e.start >= prev.start and e.end <= prev.end) continue;
                if (e.start < prev.end) return fail(file, e.start, "the edits here overlap");
            }
            try kept.append(r.arena, e);
        }
        o.* = .{ .file = file, .edits = kept.items };
    }
    std.mem.sort(rename.FileEdits, out, {}, struct {
        fn lt(_: void, a: rename.FileEdits, b: rename.FileEdits) bool {
            return @backingInt(a.file) < @backingInt(b.file);
        }
    }.lt);

    for (out) |fe| if (try verify(r, t, param_list.range(), fe)) |p| return .{ .failed = p };
    return .{ .ok = out };
}

fn addEdit(arena: Allocator, by_file: *std.AutoArrayHashMapUnmanaged(FileId, std.ArrayList(rename.Edit)), file: FileId, e: rename.Edit) Allocator.Error!void {
    const gop = try by_file.getOrPut(arena, file);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(arena, e);
}

fn fail(file: FileId, offset: ?u32, message: []const u8) Outcome {
    return .{ .failed = .{ .file = file, .offset = offset, .message = message } };
}

/// 文件应用编辑之后不能有新的 AstGen 错误（按位置与文案对应编辑之前的错误）。唯一的例外是参数列表中的
/// 其他参数因此不再被使用（`comptime T: type, x: T` 删除 `x` 后 `T` 未使用）：这与删除前的错误相当，可以再删除它
fn verify(r: *Resolver, t: Target, param_list: TextRange, fe: rename.FileEdits) resolve.Error!?Problem {
    const errors = try rename.astGenErrors(r, fe.file, fe.edits);
    const matched = try r.arena.alloc(bool, errors.before.len);
    @memset(matched, false);
    next: for (errors.after) |a| {
        for (errors.before, matched) |b, *m| {
            if (!m.* and b.start == a.start and std.mem.eql(u8, b.message, a.message)) {
                m.* = true;
                continue :next;
            }
        }
        if (fe.file == t.file and std.mem.eql(u8, a.message, unused_message) and param_list.contains(a.start)) continue;
        return .{ .file = fe.file, .offset = a.start, .message = try std.fmt.allocPrint(r.arena, "the edit would cause an error here: {s}", .{a.message}) };
    }
    return null;
}

const Site = union(enum) {
    /// 不依赖签名的引用（decltest 的名字）
    skip,
    edit: rename.Edit,
    failed: Problem,
};

/// 引用 `ref` 处的调用中删除实参的编辑。`index` 为参数的下标，`param_count` 为参数的个数
fn callSite(r: *Resolver, ref: search.Reference, index: u32, param_count: u32) resolve.Error!Site {
    const root = (try r.ctx.get(database.syntax.ParseFile, ref.file)).rootNode();
    const path = try root.coveringPath(r.arena, ref.start);
    var top = path.len - 1;
    switch (path[top].kind()) {
        .test_decl => return .skip,
        .name_ref, .field_access, .enum_literal => {},
        else => return siteFail(ref.file, ref.start, not_call),
    }
    // 括号不改变调用：`(f)(x)`
    while (top > 0 and path[top - 1].kind() == .paren_expr) top -= 1;
    if (top == 0) return siteFail(ref.file, ref.start, not_call);
    const call = ast.cast(ast.CallExpr, path[top - 1]) orelse return siteFail(ref.file, ref.start, not_call);
    const callee = call.callee() orelse return siteFail(ref.file, ref.start, not_call);
    if (callee.offset != path[top].offset or callee.kind() != path[top].kind()) return siteFail(ref.file, ref.start, not_call);

    // 调用所在的成员的 HIR：区分方法调用，检查实参的副作用
    const item = try r.ownerAt(ref.file, ref.start, false) orelse return siteFail(ref.file, ref.start, not_analyzed);
    const b = try r.body(ref.file, item);
    const base = try r.itemOffset(ref.file, item) orelse return siteFail(ref.file, ref.start, not_analyzed);
    const call_range = call.syntax.range();
    if (call_range.start < base) return siteFail(ref.file, ref.start, not_analyzed);
    const call_expr = exprAt(b, .call, call_range.start - base, call_range.end - base) orelse return siteFail(ref.file, ref.start, not_analyzed);
    const c = b.expr(call_expr).call;
    const bound = switch (b.expr(c.callee)) {
        .name_ref, .enum_literal => false,
        .field_access => |fa| try isBound(r, ref.file, item, b, fa.lhs) orelse
            return siteFail(ref.file, ref.start, "the type here is unknown, so whether the call passes the value before `.` as the first argument cannot be confirmed"),
        else => return siteFail(ref.file, ref.start, not_analyzed),
    };
    if (bound and index == 0) return siteFail(ref.file, ref.start, "this method call passes the value before `.` as the parameter");
    if (c.args.len + @intFromBool(bound) != param_count) return siteFail(ref.file, ref.start, "the number of arguments here does not match the parameters of the function");

    const j = index - @intFromBool(bound);
    var args = call.args();
    var k: u32 = 0;
    const arg = while (args.next()) |a| : (k += 1) {
        if (k == j) break a;
    } else return siteFail(ref.file, ref.start, not_analyzed);
    const arg_range = arg.range();
    if (try hasSideEffects(r, ref.file, item, b, arg_range.start - base, arg_range.end - base))
        return siteFail(ref.file, arg_range.start, "removing the argument here would drop its side effects");
    const list = call.syntax.childNode(.arg_list) orelse return siteFail(ref.file, ref.start, not_analyzed);
    const text = (try r.ctx.get(database.syntax.SourceText, ref.file)).text;
    const e = try removeItem(r.arena, text, list, j) orelse return siteFail(ref.file, arg_range.start, "the argument list here could not be edited");
    return .{ .edit = e };
}

const not_call = "the function is used here other than in a call, so this use cannot be updated";
const not_analyzed = "the call here could not be analyzed";

fn siteFail(file: FileId, offset: u32, message: []const u8) Site {
    return .{ .failed = .{ .file = file, .offset = offset, .message = message } };
}

/// 位于 `[start, end)`（相对成员起点）的 `tag` 种类的表达式
fn exprAt(b: *const Body, tag: std.meta.Tag(Body.Expr), start: u32, end: u32) ?Body.ExprId {
    for (b.exprs, b.expr_ranges, 0..) |e, range, i| {
        if (e == tag and range.start == start and range.end == end) return @fromBackingInt(@as(u32, @intCast(i)));
    }
    return null;
}

/// `lhs.f(...)` 是否以 `lhs` 为第一个实参（方法调用）：`lhs` 是值时是，是类型或命名空间时不是。泛型函数中按
/// 全部调用点实例判断，各实例不一致或都求不出时为 null
fn isBound(r: *Resolver, file: FileId, item: u32, b: *const Body, lhs: Body.ExprId) resolve.Error!?bool {
    if (try r.evalNamespace(file, item, b, lhs) != null) return false;
    const ip = r.ctx.db.env.ip;
    const owner = try r.ownerKey(file, item);
    const i = @backingInt(lhs);
    const abstract = try r.ctx.get(database.sema.Infer, .{ .owner = owner, .mode = .full });
    if (i < abstract.exprs.len) if (boundness(ip, abstract.exprs[i])) |x| return x;
    const all = try seed.allInstances(r, file, item);
    if (!all.complete) return null;
    var result: ?bool = null;
    for (all.insts) |inst| {
        const res = try r.ctx.get(database.sema.Infer, .{ .owner = owner, .mode = .full, .inst = inst });
        if (i >= res.exprs.len) continue;
        const x = boundness(ip, res.exprs[i]) orelse continue;
        if (result) |y| if (x != y) return null;
        result = x;
    }
    return result;
}

/// 类型为 `tv` 的左侧：是类型时为 false，是具体类型的值时为 true，未知或抽象时为 null
fn boundness(ip: *InternPool, tv: TypedValue) ?bool {
    if (tv.ty == .type_type) return false;
    if (seed.wanted(ip, tv)) return null;
    return true;
}

/// 位于 `[start, end)`（相对成员起点）的实参有无副作用：调用（结果是类型的类型函数除外）、赋值、控制流（`try`、
/// `return`、`break`、`continue`、`unreachable`）、有副作用或不认识的内建函数、内联汇编等
fn hasSideEffects(r: *Resolver, file: FileId, item: u32, b: *const Body, start: u32, end: u32) resolve.Error!bool {
    var res: ?*const @import("../sema/infer.zig").Result = null;
    for (b.exprs, b.expr_ranges, 0..) |e, range, i| {
        if (range.start < start or range.end > end) continue;
        switch (e) {
            .call => {
                if (res == null) res = try r.ctx.get(database.sema.Infer, .{ .owner = try r.ownerKey(file, item), .mode = .full });
                if (i < res.?.exprs.len and res.?.exprs[i].isType()) continue;
                return true;
            },
            .assign, .@"return", .@"break", .@"continue", .@"unreachable", .other => return true,
            .prefix => |p| if (p.op == .keyword_try) return true,
            .builtin_call => |c| if (!isPure(c.name)) return true,
            else => {},
        }
    }
    return false;
}

/// 没有副作用的内建函数（`code_actions.pure_builtins` 之外的）
const extra_pure_builtins = [_][]const u8{
    "@field",      "@FieldType",    "@intFromPtr",    "@ptrFromInt",     "@intFromError",   "@errorFromInt", "@errorCast",
    "@unionInit",  "@volatileCast", "@addrSpaceCast", "@fieldParentPtr", "@select",         "@shuffle",      "@reduce",
    "@sin",        "@cos",          "@tan",           "@exp",            "@exp2",           "@log",          "@log2",
    "@log10",      "@trunc",        "@divCeil",       "@backingInt",     "@fromBackingInt", "@bitOffsetOf",  "@Int",
    "@Struct",     "@Enum",         "@Union",         "@Tuple",          "@Fn",             "@Pointer",      "@EnumLiteral",
    "@inComptime",
};

comptime {
    @setEvalBranchQuota(20000);
    for (extra_pure_builtins) |name| {
        if (builtins.get(name) == null) @compileError("remove parameter: unknown builtin " ++ name);
    }
}

fn isPure(name: []const u8) bool {
    for (code_actions.pure_builtins) |n| if (std.mem.eql(u8, n, name)) return true;
    for (extra_pure_builtins) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// 列表中的一项
const ListItem = struct {
    start: u32,
    end: u32,
    /// 其后的逗号
    comma: ?TextRange = null,
    /// 以多行字符串开始或结束：其后的逗号须另起一行
    multiline: bool,
};

/// 删除参数列表或实参列表 `list` 中第 `index` 项的编辑，保持排版：
/// - 独占若干行的项（多行列表的一项，可带行尾注释）删除这些行
/// - 与其他项同行的项连同一个逗号删除：最后一项删除其前的逗号，其余删除其后的逗号。与多行字符串相邻时只删到
///   逗号为止，保留多行字符串前后的换行
/// - 删除后括号之间只剩空白时删除括号之间的全部内容：`f()`
///
/// 列表的结构不完整（缺少括号、逗号）时为 null
pub fn removeItem(arena: Allocator, text: []const u8, list: SyntaxNode, index: u32) Allocator.Error!?rename.Edit {
    var items: std.ArrayList(ListItem) = .empty;
    var open: ?u32 = null;
    var close: ?u32 = null;
    var it = list.children();
    while (it.next()) |e| switch (e) {
        .token => |t| switch (t.kind) {
            .l_paren => {
                if (open != null or items.items.len != 0) return null;
                open = t.offset + 1;
            },
            .r_paren => {
                if (close != null) return null;
                close = t.offset;
            },
            .comma => {
                if (items.items.len == 0) return null;
                const last = &items.items[items.items.len - 1];
                if (last.comma != null) return null;
                last.comma = t.range();
            },
            else => if (!kind_mod.isTrivia(t.kind)) return null,
        },
        .node => |n| {
            if (open == null or close != null) return null;
            if (items.items.len > 0 and items.items[items.items.len - 1].comma == null) return null;
            // 节点以有效 token 开始与结束（前后的 trivia 属于列表）
            const first = n.firstToken() orelse return null;
            const last = lastToken(n) orelse return null;
            const range = n.range();
            try items.append(arena, .{
                .start = range.start,
                .end = range.end,
                .multiline = first.kind == .multiline_string_literal_line or last.kind == .multiline_string_literal_line,
            });
        },
    };
    const l = open orelse return null;
    const r = close orelse return null;
    const all = items.items;
    if (index >= all.len) return null;
    const x = all[index];
    const n = all.len;
    const limit = if (index + 1 < n) all[index + 1].start else r;
    const span: [2]u32 = if (ownLines(text, x, limit)) |lines|
        lines
    else if (n == 1)
        .{ l, r }
    else if (index == 0)
        .{ l, if (all[1].multiline) x.comma.?.end else all[1].start }
    else if (index + 1 < n)
        (if (x.multiline or all[index + 1].multiline) .{ all[index - 1].comma.?.end, x.comma.?.end } else .{ x.start, all[index + 1].start })
    else
        .{ all[index - 1].comma.?.start, r };
    if (isBlank(text[l..span[0]]) and isBlank(text[span[1]..r])) return .{ .start = l, .end = r, .text = "" };
    return .{ .start = span[0], .end = span[1], .text = "" };
}

/// 项 `x` 独占若干行时这些行的区间（含末尾的换行）：所在行之前只有缩进，之后（逗号之后）只有空白与注释。
/// 区间不越过下一项的起点 `limit`（下一项的文档注释可以紧跟在逗号之后）
fn ownLines(text: []const u8, x: ListItem, limit: u32) ?[2]u32 {
    var line_start = x.start;
    while (line_start > 0 and text[line_start - 1] != '\n') line_start -= 1;
    for (text[line_start..x.start]) |ch| if (ch != ' ' and ch != '\t') return null;
    var pos = x.end;
    if (x.comma) |c| {
        if (!isBlank(text[x.end..c.start])) return null;
        pos = c.end;
    }
    while (pos < text.len and (text[pos] == ' ' or text[pos] == '\t' or text[pos] == '\r')) pos += 1;
    if (std.mem.startsWith(u8, text[pos..], "//")) pos = @intCast(std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse return null);
    if (pos >= text.len or text[pos] != '\n' or pos + 1 > limit) return null;
    return .{ line_start, pos + 1 };
}

fn isBlank(s: []const u8) bool {
    for (s) |ch| if (!std.ascii.isWhitespace(ch)) return false;
    return true;
}

/// 节点的最后一个有效 token
fn lastToken(n: SyntaxNode) ?SyntaxToken {
    var last: ?tree.SyntaxElement = null;
    var it = n.children();
    while (it.next()) |e| {
        if (e == .node or !kind_mod.isTrivia(e.token.kind)) last = e;
    }
    return switch (last orelse return null) {
        .token => |t| t,
        .node => |c| lastToken(c),
    };
}

test {
    _ = @import("remove_param_test.zig");
}
