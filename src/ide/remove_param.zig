//! Quick fix for an unused function parameter (AstGen's `unused function parameter`): removes the
//! parameter together with the matching argument at every call site.
//!
//! Only complete and correct edits are offered. Every reference to the function must be a direct
//! call (`f(...)`, `x.f(...)`, `S.f(...)`, `.f(...)`) whose arguments match the parameters one to
//! one; nothing is changed when the function is used in other ways (passing it as a value, taking
//! its address, `@call`, `@TypeOf`), a reference cannot be confirmed (ambiguity, an unknown type, a
//! file with syntax errors), the name appears as a string (reflection), or a removed argument has
//! side effects. The fix is not offered for method receivers, `export` / `extern` functions, or
//! variadic functions. After the removal, AstGen is used to confirm that no file has new errors
//! (such as a local name at a call site that is no longer used).

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

/// A parameter that can be removed
pub const Target = struct {
    file: FileId,
    /// The function (index into `ItemTree.items`)
    item: u32,
    /// Index of the parameter in the parameter list
    index: u32,
    /// Name of the parameter (with the `@"..."` quoting removed)
    name: []const u8,
    /// Position of the parameter name token (that is, the position of the diagnostic)
    start: u32,
    end: u32,
    /// The function is pub: other files may call it
    public: bool,
};

/// Reason why the parameter cannot be removed
pub const Problem = struct {
    file: FileId,
    /// Position of the problem (byte offset); null when the problem concerns the whole file
    offset: ?u32,
    message: []const u8,
};

pub const Outcome = union(enum) {
    /// Edits of each file, sorted by file
    ok: []const rename.FileEdits,
    failed: Problem,
};

/// The unused parameters within `[start, end]` that can be removed
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

/// The parameter whose name is at `offset`: the function must have a body and not be an
/// `export` / `extern` / variadic function, and the parameter must not be a method receiver
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

/// Whether the first parameter of the function is a method receiver: its type is the container
/// the function is in, or a single-item pointer to it
fn isReceiver(r: *Resolver, file: FileId, item: u32) resolve.Error!bool {
    const items = try r.itemTree(file);
    const container = items.items[item].container;
    const b = try r.body(file, item);
    if (b.params.len == 0) return false;
    // Evaluate the container by name (`@This()`, `Self`); when that fails (the result of a type
    // function, etc.), check the inferred signature
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

/// Edits that remove parameter `t` and the matching argument at every call site. `scope` is the
/// search scope for references (files in the project).
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
    if (ambiguous) |a| return fail(a.file, a.start, search.ambiguous_message);
    if (uncertain) |u| return fail(u.file, u.start, "the type here is unknown, so whether this refers to the function cannot be confirmed");
    if (incomplete) |u| return fail(u.file, u.start, "this reference depends on instantiations of a generic function that grow without bound, so not all of them can be checked");
    // A function that is not pub can only be accessed in its own file
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
        // Calls inside removed arguments (type functions) are removed with them: drop edits that
        // lie within other edits
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

/// After the edits are applied, the file must have no new AstGen errors (matched against the
/// errors before the edits by position and message). The only exception is another parameter in
/// the parameter list becoming unused as a result (removing `x` from `comptime T: type, x: T`
/// leaves `T` unused): this is equivalent to the error before the removal, and that parameter
/// can be removed next.
fn verify(r: *Resolver, t: Target, param_list: TextRange, fe: rename.FileEdits) resolve.Error!?Problem {
    const errors = try rename.astGenErrors(r, fe.file, fe.edits);
    for (try rename.newAstGenErrors(r.arena, errors.before, errors.after)) |a| {
        if (fe.file == t.file and std.mem.eql(u8, a.message, unused_message) and param_list.contains(a.start)) continue;
        return .{ .file = fe.file, .offset = a.start, .message = try std.fmt.allocPrint(r.arena, "the edit would cause an error here: {s}", .{a.message}) };
    }
    return null;
}

const Site = union(enum) {
    /// A reference that does not depend on the signature (the name of a decltest)
    skip,
    edit: rename.Edit,
    failed: Problem,
};

/// The edit that removes the argument from the call at reference `ref`. `index` is the index of
/// the parameter, and `param_count` the number of parameters.
fn callSite(r: *Resolver, ref: search.Reference, index: u32, param_count: u32) resolve.Error!Site {
    const root = (try r.ctx.get(database.syntax.ParseFile, ref.file)).rootNode();
    const path = try root.coveringPath(r.arena, ref.start);
    var top = path.len - 1;
    switch (path[top].kind()) {
        .test_decl => return .skip,
        .name_ref, .field_access, .enum_literal => {},
        else => return siteFail(ref.file, ref.start, not_call),
    }
    // Parentheses do not change the call: `(f)(x)`
    while (top > 0 and path[top - 1].kind() == .paren_expr) top -= 1;
    if (top == 0) return siteFail(ref.file, ref.start, not_call);
    const call = ast.cast(ast.CallExpr, path[top - 1]) orelse return siteFail(ref.file, ref.start, not_call);
    const callee = call.callee() orelse return siteFail(ref.file, ref.start, not_call);
    if (callee.offset != path[top].offset or callee.kind() != path[top].kind()) return siteFail(ref.file, ref.start, not_call);

    // HIR of the member containing the call: to recognize method calls and to check the
    // arguments for side effects
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

/// The expression of kind `tag` at `[start, end)` (relative to the start of the member)
fn exprAt(b: *const Body, tag: std.meta.Tag(Body.Expr), start: u32, end: u32) ?Body.ExprId {
    for (b.exprs, b.expr_ranges, 0..) |e, range, i| {
        if (e == tag and range.start == start and range.end == end) return @fromBackingInt(@as(u32, @intCast(i)));
    }
    return null;
}

/// Whether `lhs.f(...)` passes `lhs` as the first argument (a method call): it does when `lhs`
/// is a value, and does not when it is a type or a namespace. In a generic function this is
/// decided over all call-site instances; null when the instances disagree or none of them
/// determines it.
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

/// For a left-hand side of type `tv`: false when it is a type, true when it is a value of a
/// concrete type, null when it is unknown or abstract
fn boundness(ip: *InternPool, tv: TypedValue) ?bool {
    if (tv.ty == .type_type) return false;
    if (seed.wanted(ip, tv)) return null;
    return true;
}

/// Whether the argument at `[start, end)` (relative to the start of the member) has side effects:
/// calls (except calls to type functions whose result is a type), assignments, control flow
/// (`try`, `return`, `break`, `continue`, `unreachable`), builtins that have side effects or are
/// unrecognized, inline assembly, etc.
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

/// Builtins without side effects (other than those in `code_actions.pure_builtins`)
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

/// An item of a list
const ListItem = struct {
    start: u32,
    end: u32,
    /// The comma after it
    comma: ?TextRange = null,
    /// Starts or ends with a multiline string literal: the comma after it must go on a new line
    multiline: bool,
};

/// The edit that removes the item at `index` from the parameter or argument list `list`,
/// preserving the layout:
/// - An item on lines of its own (an item of a multiline list, possibly with a trailing
///   comment): those lines are removed
/// - An item sharing a line with other items is removed together with one comma: the comma
///   before it for the last item, the comma after it for the others. Next to a multiline string
///   literal, only the text up to the comma is removed, keeping the line breaks before and
///   after the multiline string literal
/// - A `//` comment after the separator before the item (`(` or the previous comma) on the same
///   line belongs to the previous item or to the call, and is kept with its line break
/// - When only whitespace is left between the parentheses after the removal, everything between
///   them is removed: `f()`
///
/// null when the structure of the list is incomplete (missing parentheses or commas)
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
            // A node starts and ends with significant tokens (trivia before and after it belongs
            // to the list)
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
    if (ownLines(text, x, limit)) |lines| return removal(text, l, r, lines);
    const kept = separatorComment(text, if (index == 0) l else all[index - 1].comma.?.end, x.start);
    // With a kept comment, the removal starts after the indentation of the line following it
    const after_kept = if (kept) |nl| indentEnd(text, nl + 1) else null;
    if (index + 1 == n and n > 1) {
        // The comma before the last item goes too; the comment stays, and the closing parenthesis
        // goes on the next line with the indentation of the line where the list starts
        const comma = all[index - 1].comma.?;
        const nl = kept orelse return removal(text, l, r, .{ comma.start, r });
        const list_line = lineStart(text, l - 1);
        const indent = text[list_line..indentEnd(text, list_line)];
        return .{ .start = comma.start, .end = r, .text = try std.mem.concat(arena, u8, &.{ text[comma.end .. nl + 1], indent }) };
    }
    const span: [2]u32 = if (n == 1)
        .{ after_kept orelse l, r }
    else if (index == 0)
        .{ after_kept orelse l, if (all[1].multiline) x.comma.?.end else all[1].start }
    else if (x.multiline or all[index + 1].multiline)
        .{ after_kept orelse all[index - 1].comma.?.end, x.comma.?.end }
    else
        .{ x.start, all[index + 1].start };
    return removal(text, l, r, span);
}

/// The edit that removes `span` from the list between `l` and `r`, or everything between the
/// parentheses when only whitespace would be left
fn removal(text: []const u8, l: u32, r: u32, span: [2]u32) rename.Edit {
    if (isBlank(text[l..span[0]]) and isBlank(text[span[1]..r])) return .{ .start = l, .end = r, .text = "" };
    return .{ .start = span[0], .end = span[1], .text = "" };
}

/// When the line of the separator ending at `sep_end` continues with a `//` comment before the
/// item at `item_start`, the offset of the line break ending that line
fn separatorComment(text: []const u8, sep_end: u32, item_start: u32) ?u32 {
    const nl = std.mem.indexOfScalarPos(u8, text[0..item_start], sep_end, '\n') orelse return null;
    if (std.mem.indexOf(u8, text[sep_end..nl], "//") == null) return null;
    return @intCast(nl);
}

fn lineStart(text: []const u8, pos: u32) u32 {
    var i = pos;
    while (i > 0 and text[i - 1] != '\n') i -= 1;
    return i;
}

/// The end of the indentation of the line starting at `line_start`
fn indentEnd(text: []const u8, line_start: u32) u32 {
    var i = line_start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return i;
}

/// When item `x` is on lines of its own, the range of those lines (including the final newline):
/// on its line only indentation comes before it, and after it (after the comma) there is only
/// whitespace and a comment. The range does not extend past `limit`, the start of the next item
/// (the doc comment of the next item may immediately follow the comma).
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

/// The last significant token of the node
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
