//! goto definition / declaration / type definition：名字、成员访问、初始化中的字段名、标签、`@import` 字符串。
//!
//! declaration 跳到名字直接解析到的声明；definition 再沿容器级的别名（`const A = std.mem.Allocator;`）
//! 追到最终的定义；type definition 跳到光标处符号的类型（剥去指针、optional、数组、错误联合）的定义。

const std = @import("std");
const database = @import("../database.zig");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Def = resolve.Def;
const ast = @import("../syntax/ast.zig");
const SyntaxToken = ast.SyntaxToken;
const Body = @import("../hir/Body.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const context = @import("context.zig");
const queries = @import("../sema/queries.zig");
const InternPool = @import("../sema/InternPool.zig");
const TypedValue = InternPool.TypedValue;
const Index = InternPool.Index;
const eval = @import("../sema/eval.zig");
const infer = @import("../sema/infer.zig");
const FileIndex = @import("../syntax/FileIndex.zig");
const ErrorSets = @import("../syntax/ErrorSets.zig");

pub const Target = struct { file: FileId, start: u32, end: u32 };

pub fn definition(r: *Resolver, file: FileId, offset: u32) resolve.Error!?Target {
    if (try labelTarget(r, file, offset)) |t| return t;
    if (try errorMemberTarget(r, file, offset)) |t| return t;
    if (try errorValueDecl(r, file, offset, true)) |d| return d.target;
    if (try defAt(r, file, offset)) |def| return target(r, try r.aliasTarget(def));
    if (try reifiedFieldTarget(r, file, offset)) |t| return t;
    return selfTarget(r, file, offset);
}

pub fn declaration(r: *Resolver, file: FileId, offset: u32) resolve.Error!?Target {
    if (try labelTarget(r, file, offset)) |t| return t;
    if (try errorMemberTarget(r, file, offset)) |t| return t;
    if (try errorValueDecl(r, file, offset, true)) |d| return d.target;
    if (try defAt(r, file, offset)) |def| return target(r, def);
    if (try reifiedFieldTarget(r, file, offset)) |t| return t;
    return selfTarget(r, file, offset);
}

/// definition 的全部目标：光标在 `@import("name")` 上、文件所属的多个模块以 `name` import 不同的模块时为
/// 这些模块的根文件（按模块的优先级）；其余情况为 `definition` 的结果。第一个即 `definition` 的结果
pub fn definitionTargets(r: *Resolver, file: FileId, offset: u32) resolve.Error![]const Target {
    if (try importTargetsAt(r, file, offset)) |targets| return targets;
    return single(r, try definition(r, file, offset));
}

/// declaration 的全部目标：同 `definitionTargets`，其余情况为 `declaration` 的结果
pub fn declarationTargets(r: *Resolver, file: FileId, offset: u32) resolve.Error![]const Target {
    if (try importTargetsAt(r, file, offset)) |targets| return targets;
    return single(r, try declaration(r, file, offset));
}

fn single(r: *Resolver, t: ?Target) resolve.Error![]const Target {
    return r.arena.dupe(Target, if (t) |x| &.{x} else &.{});
}

/// 光标在 `@import(...)` 或其字符串上时 import 的全部目标（文件开头）。这类 token 不是名字，
/// `definition` / `declaration` 对它们只经 `defAt` 取 import 的第一个目标
fn importTargetsAt(r: *Resolver, file: FileId, offset: u32) resolve.Error!?[]const Target {
    const tok = try tokenAt(r, file, offset) orelse return null;
    if (tok.kind == .identifier) return null;
    const item = try r.ownerAt(file, tok.offset, false) orelse return null;
    const node = try r.itemNode(file, item) orelse return null;
    const b = try r.body(file, item);
    const e = b.exprAt(tok.offset - node.offset) orelse return null;
    const call = importCall(b, e) orelse return null;
    const files = try r.importTargets(file, b, call.args);
    const targets = try r.arena.alloc(Target, files.len);
    for (files, targets) |f, *t| t.* = .{ .file = f, .start = 0, .end = 0 };
    return targets;
}

/// 本身就是声明处、但不是成员或局部绑定的名字：错误集 `error{ Foo }` 中的 `Foo`，没有结果类型的
/// 匿名初始化 `.{ .x = 1 }` 中的字段名（定义了匿名结构体的字段）。与在声明的名字上跳转一样返回自身
fn selfTarget(r: *Resolver, file: FileId, offset: u32) resolve.Error!?Target {
    const tok = try tokenAt(r, file, offset) orelse return null;
    if (tok.kind != .identifier) return null;
    const span: Target = .{ .file = file, .start = tok.offset, .end = tok.offset + @as(u32, @intCast(tok.text.len)) };
    const root = (try r.ctx.get(database.syntax.ParseFile, file)).rootNode();
    const path = try root.coveringPath(r.arena, tok.offset);
    if (path.len > 0 and path[path.len - 1].kind() == .error_set_decl) return span;

    const item = try r.ownerAt(file, tok.offset, false) orelse return null;
    const node = try r.itemNode(file, item) orelse return null;
    const b = try r.body(file, item);
    const rel = tok.offset - node.offset;
    const e = b.exprAt(rel) orelse return null;
    const x = switch (b.expr(e)) {
        .init => |x| x,
        else => return null,
    };
    if (x.ty != null) return null;
    for (x.fields) |fi| {
        if (fi.name == null or rel < fi.name_range.start or rel >= fi.name_range.end) continue;
        // 有结果类型（字段解析不出时）不是声明处
        const a = try context.atSeeded(r, file, tok.offset, false) orelse return null;
        if (a.literalExpected(e) != null) return null;
        return span;
    }
    return null;
}

/// 构造的类型（`@Struct`、`@Enum`、`@Union`）的成员：字段访问 `x.name`、经类型访问的 `E.name` 与枚举字面量 `.name`。
/// 名字是 comptime 求出的字符串，跳到它在源码中的来源：字符串字面量（如 zig-clap 的帮助文本），或 `@typeInfo(X)`
/// 给出的 X 的同名成员
fn reifiedFieldTarget(r: *Resolver, file: FileId, offset: u32) resolve.Error!?Target {
    const tok = try tokenAt(r, file, offset) orelse return null;
    if (tok.kind != .identifier) return null;
    const item = try r.ownerAt(file, tok.offset, false) orelse return null;
    const node = try r.itemNode(file, item) orelse return null;
    const b = try r.body(file, item);
    const rel = tok.offset - node.offset;
    const e = b.exprAt(rel) orelse return null;
    const a = try context.atSeeded(r, file, tok.offset, false) orelse return null;
    if (a.member(e) != null) return null;
    const ip = r.ctx.db.env.ip;
    var via_type = false;
    const name: []const u8, const t: Index = switch (b.expr(e)) {
        .field_access => |fa| blk: {
            if (rel < b.range(fa.lhs).end) return null;
            const lhs = a.exprType(fa.lhs);
            if (lhs.asType()) |ty| {
                via_type = true;
                break :blk .{ fa.field orelse return null, ty };
            }
            var ty = lhs.ty;
            switch (ip.key(ty)) {
                .ptr_type => |p| if (p.size == .one) {
                    ty = p.child;
                },
                else => {},
            }
            break :blk .{ fa.field orelse return null, ty };
        },
        .enum_literal => |n| blk: {
            // 结果类型为 `?E`、`E!T` 时取 E；传给 anytype 形参的字面量取被调函数中转换成的类型
            var ty = a.exprType(e).ty;
            if (ty == .enum_literal_type) ty = a.literalExpected(e) orelse return null;
            while (true) switch (ip.key(ty)) {
                .optional_type => |child| ty = child,
                .error_union_type => |eu| ty = eu.payload,
                else => break,
            };
            break :blk .{ n, ty };
        },
        else => return null,
    };
    const rt = switch (ip.key(t)) {
        .reified_type => |x| x,
        // `union(enum)` 的标签枚举：成员是 union 的字段
        .union_tag_type => |u| switch (ip.key(u)) {
            .reified_type => |x| x,
            else => return null,
        },
        else => return null,
    };
    // 经类型访问的只有枚举成员（结构体与 union 的类型上只有声明）
    if (via_type and rt.kind != .@"enum") return null;
    for (rt.names) |n| {
        if (std.mem.eql(u8, n, name)) break;
    } else return null;
    // 名字的字符串字面量先在使用处找，再到构造类型的成员（含其中的局部常量，如 `blk: { const extra = .{...}; ... }`）所在的文件中找
    if (try literalOrigin(r, file, .{ .item = item, .body = b, .at = a }, rt, name)) |found| return found;
    const owner = try ownerLocal(r, rt);
    if (rt.file != file or owner == null or owner.?.item != item) if (try literalOrigin(r, rt.file, owner, rt, name)) |found| return found;
    if (try constructionOrigin(r, rt, name)) |found| return found;
    if (try typeInfoOrigin(r, rt, name)) |found| return found;
    return constructionSite(r, rt);
}

/// 名字的来源追不到具体字符时（如由单个字节 `@as(*const [1]u8, &c)` 构成的名字）：成员定义在构造类型的调用处
fn constructionSite(r: *Resolver, rt: InternPool.Reified) resolve.Error!?Target {
    const tree = try r.itemTree(rt.file);
    const item: u32 = for (tree.items, 0..) |it, i| {
        if (it.ast_id == rt.owner) break @intCast(i);
    } else return null;
    const node = try r.itemNode(rt.file, item) orelse return null;
    const body = try r.body(rt.file, item);
    if (rt.expr >= body.exprs.len) return null;
    const range = body.range(@fromBackingInt(rt.expr));
    return .{ .file = rt.file, .start = node.offset + range.start, .end = node.offset + range.end };
}

/// 构造类型的成员（`rt.owner`）：其中的局部绑定也是名字来源的候选
fn ownerLocal(r: *Resolver, rt: InternPool.Reified) resolve.Error!?Local {
    const tree = try r.itemTree(rt.file);
    const item: u32 = for (tree.items, 0..) |it, i| {
        if (it.ast_id == rt.owner) break @intCast(i);
    } else return null;
    const node = try r.itemNode(rt.file, item) orelse return null;
    const at = try context.at(r, rt.file, node.offset, false) orelse return null;
    if (at.item != item) return null;
    return .{ .item = item, .body = at.body, .at = at, .inst = rt.inst };
}

/// 局部绑定也是候选的成员：使用处所在的成员，或构造类型的成员（在其实例 `inst` 下求值）
const Local = struct { item: u32, body: *const Body, at: context.At, inst: ?Index = null };

/// 名字 `name` 在文件 `file` 中的字符串字面量来源。候选是初始化表达式含有该字面量（或经由含有它的常量）的常量，
/// 以及 `local` 中的局部绑定：求出它们的值并在其中找到这个字符串，再以跟踪字面量来源的方式重新求值
fn literalOrigin(r: *Resolver, file: FileId, local: ?Local, rt: InternPool.Reified, name: []const u8) resolve.Error!?Target {
    const ip = r.ctx.db.env.ip;
    const Candidate = struct { item: u32, body: *const Body, expr: Body.ExprId, value: Index };
    var cands: std.ArrayList(Candidate) = .empty;
    const tree = try r.itemTree(file);
    // 初始化表达式中直接含有该名字的字符串字面量的常量（名字），以及经由它们的常量
    var holders: std.ArrayList([]const u8) = .empty;
    for (tree.items, 0..) |it, i| {
        if (it.kind != .@"const" and it.kind != .@"var") continue;
        const ib = try r.body(file, @intCast(i));
        const v = ib.value orelse continue;
        if (literalWithin(ib, v, name)) try holders.append(r.arena, it.name orelse continue);
    }
    for (tree.items, 0..) |it, i| {
        if (it.kind != .@"const" and it.kind != .@"var") continue;
        const ib = try r.body(file, @intCast(i));
        const v = ib.value orelse continue;
        if (!literalWithin(ib, v, name) and !nameRefWithin(ib, v, holders.items)) continue;
        const tv = try queries.defType(r, .{ .item = .{ .file = file, .item = @intCast(i) } }, null, null);
        try cands.append(r.arena, .{ .item = @intCast(i), .body = ib, .expr = v, .value = tv.val orelse continue });
    }
    if (local) |l| for (l.body.bindings, 0..) |binding, bi| {
        const init = binding.init orelse continue;
        if (!literalWithin(l.body, init, name) and !nameRefWithin(l.body, init, holders.items)) continue;
        // 推导不为字符串生成值（如块中的 `const extra = [_][]const u8{"a"};`）：求不出时按 comptime 求值
        const v = l.at.bindingType(@fromBackingInt(@intCast(bi))).val orelse
            (try eval.exprValue(r, file, l.item, l.body, init, l.inst, l.at.res.bindings, null, eval.bodyQuota(r, l.body, l.at.res.exprs))).val orelse continue;
        try cands.append(r.arena, .{ .item = l.item, .body = l.body, .expr = init, .value = v });
    };

    var chosen: ?struct { cand: Candidate, path: []const u32 } = null;
    var found: u32 = 0;
    var shared: u32 = 0;
    // 值相同的候选（`const nodes = node_kinds;`）是同一个来源，只计一次，取先出现的
    var seen: std.ArrayList(Index) = .empty;
    for (cands.items) |c| {
        if (std.mem.indexOfScalar(Index, seen.items, c.value) != null) continue;
        try seen.append(r.arena, c.value);
        var path: std.ArrayList(u32) = .empty;
        var chain: std.ArrayList(Index) = .empty;
        if (!try eval.findString(ip, r.arena, c.value, name, &path, &chain)) continue;
        found += 1;
        const share = if (rt.inst) |inst| sharesValue(ip, inst, chain.items) else false;
        if (share) shared += 1;
        // 与实例实参共有值的候选优先；都没有时只有唯一的候选才取
        if (share or (shared == 0 and chosen == null)) chosen = .{ .cand = c, .path = path.items };
    }
    const pick = chosen orelse return null;
    if (shared > 1 or (shared == 0 and found > 1)) return null;

    const origin = try eval.stringOrigin(r, file, pick.cand.item, pick.cand.body, pick.cand.expr, pick.path) orelse return null;
    return originTarget(r, origin, name);
}

/// 字符串来源 `origin` 对应源码中的字面量区间
fn originTarget(r: *Resolver, origin: eval.StringOrigin, name: []const u8) resolve.Error!?Target {
    const lit_node = try r.itemNode(origin.file, origin.item) orelse return null;
    const lit_body = try r.body(origin.file, origin.item);
    const range = lit_body.range(origin.expr);
    const source = (try r.ctx.get(database.syntax.ParseFile, origin.file)).source;
    const lit_start = lit_node.offset + range.start;
    const src = source[lit_start .. lit_node.offset + range.end];
    const start = Body.literalSourceOffset(src, origin.offset) orelse return null;
    const end = Body.literalSourceOffset(src, origin.offset + name.len) orelse return null;
    return .{ .file = origin.file, .start = lit_start + @as(u32, @intCast(start)), .end = lit_start + @as(u32, @intCast(end)) };
}

/// 名字切片直接写在构造调用中（`@Enum(..., &.{"fast", "slow"}, ...)`）时的来源：
/// 求出构造的第 3 个实参（名字切片），在其中找到 `name`，再沿字符串来源跟踪到字面量
fn constructionOrigin(r: *Resolver, rt: InternPool.Reified, name: []const u8) resolve.Error!?Target {
    const local = (try ownerLocal(r, rt)) orelse return null;
    const e: Body.ExprId = @fromBackingInt(rt.expr);
    const args = switch (local.body.expr(e)) {
        .builtin_call => |c| c.args,
        else => return null,
    };
    if (args.len < 3) return null;
    const names_e = args[2];
    const ip = r.ctx.db.env.ip;
    const tv = try eval.exprValue(r, rt.file, local.item, local.body, names_e, local.inst, local.at.res.bindings, null, eval.bodyQuota(r, local.body, local.at.res.exprs));
    const value = tv.val orelse return null;
    var path: std.ArrayList(u32) = .empty;
    var chain: std.ArrayList(Index) = .empty;
    if (!try eval.findString(ip, r.arena, value, name, &path, &chain)) return null;
    const origin = try eval.stringOrigin(r, rt.file, local.item, local.body, names_e, path.items) orelse return null;
    return originTarget(r, origin, name);
}

/// 构造类型的成员名来自 `@typeInfo(X)`（如 `@typeInfo(Tag).@"enum".field_names`）时，X 中的同名成员：
/// 在构造所在的成员中找 `@typeInfo` 的实参，取第一个有这个成员的类型
fn typeInfoOrigin(r: *Resolver, rt: InternPool.Reified, name: []const u8) resolve.Error!?Target {
    const tree = try r.itemTree(rt.file);
    const owner_item: u32 = for (tree.items, 0..) |it, i| {
        if (it.ast_id == rt.owner) break @intCast(i);
    } else return null;
    const owner = try r.ownerKey(rt.file, owner_item);
    const body = try r.ctx.get(database.hir.ItemBody, owner);
    const res = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full, .inst = rt.inst });
    if (res.exprs.len != body.exprs.len) return null;
    for (body.exprs) |x| switch (x) {
        .builtin_call => |call| {
            if (!std.mem.eql(u8, call.name, "@typeInfo") or call.args.len != 1) continue;
            const t = res.exprs[@backingInt(call.args[0])].asType() orelse continue;
            const ns = try queries.namespaceOfType(r, t) orelse continue;
            const f = infer.fieldItem(try r.itemTree(ns.file), ns.container, name) orelse continue;
            return target(r, .{ .item = .{ .file = ns.file, .item = f } });
        },
        else => {},
    };
    return null;
}

/// `e` 的范围内有内容含有 `name` 的字符串字面量
fn literalWithin(b: *const Body, e: Body.ExprId, name: []const u8) bool {
    const range = b.range(e);
    for (b.exprs, 0..) |x, i| switch (x) {
        .literal => |text| {
            if (text.len == 0 or (text[0] != '"' and text[0] != '\\')) continue;
            const ri = b.expr_ranges[i];
            if (ri.start >= range.start and ri.end <= range.end and std.mem.indexOf(u8, text, name) != null) return true;
        },
        else => {},
    };
    return false;
}

/// `e` 的范围内引用了 `names` 中的名字
fn nameRefWithin(b: *const Body, e: Body.ExprId, names: []const []const u8) bool {
    const range = b.range(e);
    for (b.exprs, 0..) |x, i| switch (x) {
        .name_ref => |n| {
            const ri = b.expr_ranges[i];
            if (ri.start < range.start or ri.end > range.end) continue;
            for (names) |want| if (std.mem.eql(u8, n, want)) return true;
        },
        else => {},
    };
    return false;
}

/// 实例 `inst`（及其所在的实例）的实参中含有 `values` 中的某个值
fn sharesValue(ip: *InternPool, inst: Index, values: []const Index) bool {
    if (values.len == 0) return false;
    var budget: u32 = 4096;
    var cur: ?Index = inst;
    while (cur) |x| {
        const ins = switch (ip.key(x)) {
            .instance => |v| v,
            else => return false,
        };
        for (ins.args) |arg| if (containsValue(ip, arg, values, &budget, 0)) return true;
        cur = ins.parent;
    }
    return false;
}

fn containsValue(ip: *InternPool, v: Index, values: []const Index, budget: *u32, depth: u32) bool {
    if (budget.* == 0 or depth > 12) return false;
    budget.* -= 1;
    if (std.mem.indexOfScalar(Index, values, v) != null) return true;
    switch (ip.key(v)) {
        .ptr_value => |p| return containsValue(ip, p.pointee, values, budget, depth + 1),
        .aggregate => |agg| for (agg.elems) |x| if (containsValue(ip, x, values, budget, depth + 1)) return true,
        else => {},
    }
    return false;
}

/// 具名错误集的成员：`Error.Foo` 跳到声明 `const Error = error{ Foo, ... }` 中的 `Foo`（声明是别名时沿别名查找）
fn errorMemberTarget(r: *Resolver, file: FileId, offset: u32) resolve.Error!?Target {
    const tok = try tokenAt(r, file, offset) orelse return null;
    if (tok.kind != .identifier) return null;
    const item = try r.ownerAt(file, tok.offset, false) orelse return null;
    const node = try r.itemNode(file, item) orelse return null;
    const b = try r.body(file, item);
    const rel = tok.offset - node.offset;
    const e = b.exprAt(rel) orelse return null;
    const fa = switch (b.expr(e)) {
        .field_access => |x| x,
        else => return null,
    };
    if (rel < b.range(fa.lhs).end) return null;
    const name = fa.field orelse return null;
    const lhs_def: Def = switch (b.expr(fa.lhs)) {
        .name_ref => |n| try r.resolveName(file, item, b, b.expr_scopes[@backingInt(fa.lhs)], n) orelse return null,
        .field_access => blk: {
            const a = try context.atSeeded(r, file, tok.offset, false) orelse return null;
            break :blk try context.defOfKey(r, a.member(fa.lhs) orelse return null) orelse return null;
        },
        else => return null,
    };
    for ([_]Def{ lhs_def, try r.aliasTarget(lhs_def) }) |def| {
        const it = switch (def) {
            .item => |x| x,
            else => continue,
        };
        const decl = try r.itemNode(it.file, it.item) orelse continue;
        if (try findErrorName(r.arena, decl, name, 0)) |at| return .{ .file = it.file, .start = at.start, .end = at.end };
    }
    return null;
}

/// `error.Foo` 中的 `Foo` 在错误集声明中的位置与文档
pub const ErrorDecl = struct { target: Target, doc: ?[]const u8 };

/// `error.Foo`：错误名不必先声明，同名的错误也可以出现在多个错误集中。在 `error{ ... }` 声明中查找：成员与
/// 期望的错误集完全相同的优先，其次是期望错误集的一部分（`A || B` 中的 `A`），再次是任何含这个名字的。
/// 先查当前文件；`imports` 时再查沿 import 可达的文件（以文件索引按名字筛选），直到找到不会被取代的：有期望的
/// 错误集时为完全相同的；没有时各声明同样符合，取第一个
pub fn errorValueDecl(r: *Resolver, file: FileId, offset: u32, imports: bool) resolve.Error!?ErrorDecl {
    const tok = try tokenAt(r, file, offset) orelse return null;
    if (tok.kind != .identifier) return null;
    const item = try r.ownerAt(file, tok.offset, false) orelse return null;
    const node = try r.itemNode(file, item) orelse return null;
    const b = try r.body(file, item);
    const e = b.exprAt(tok.offset - node.offset) orelse return null;
    const name = switch (b.expr(e)) {
        .error_value => |n| ast.identName(n),
        else => return null,
    };
    if (name.len == 0) return null;
    const expected = try expectedErrorNames(r, file, tok.offset, e);
    const enough: @FieldType(ErrorCandidate, "rank") = if (expected != null) .exact else .any;
    var best: ?ErrorCandidate = null;
    try findErrorDecl(r, file, name, expected, &best);
    if (!imports) return if (best) |c| c.decl else null;
    var files: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty;
    try files.put(r.arena, file, {});
    var i: usize = 0;
    while (i < files.count() and (best == null or best.?.rank != enough)) : (i += 1) {
        const f = files.keys()[i];
        const index = try r.ctx.get(FileIndex.Query, f);
        if (i > 0 and index.contains(name)) try findErrorDecl(r, f, name, expected, &best);
        for (index.imports) |s| if (try r.resolveImport(f, s)) |to| try files.put(r.arena, to, {});
    }
    return if (best) |c| c.decl else null;
}

/// `error.X` 的期望错误集（错误联合取其错误集）的成员
pub fn expectedErrorNames(r: *Resolver, file: FileId, offset: u32, e: Body.ExprId) resolve.Error!?[]const []const u8 {
    const set = try expectedErrorSet(r, file, offset, e) orelse return null;
    return queries.errorSetMembers(r, set);
}

pub fn expectedErrorSet(r: *Resolver, file: FileId, offset: u32, e: Body.ExprId) resolve.Error!?Index {
    const a = try context.atSeeded(r, file, offset, false) orelse return null;
    const want = a.literalExpected(e) orelse return null;
    return switch (r.ctx.db.env.ip.key(want)) {
        .error_union_type => |eu| eu.err,
        .error_set_type, .inferred_error_set => want,
        else => null,
    };
}

const ErrorCandidate = struct {
    rank: enum(u2) { any, subset, exact },
    decl: ErrorDecl,
};

/// 文件中含名为 `name` 的错误的 `error{ ... }` 声明，比 `best` 更符合期望的错误集时替换它（同样符合时取先出现的）
fn findErrorDecl(r: *Resolver, file: FileId, name: []const u8, expected: ?[]const []const u8, best: *?ErrorCandidate) resolve.Error!void {
    const sets = try r.ctx.get(ErrorSets.Query, file);
    for (sets.sets) |set| {
        const member = for (set.members) |m| {
            if (std.mem.eql(u8, m.name, name)) break m;
        } else continue;
        const rank: @FieldType(ErrorCandidate, "rank") = if (expected) |want| blk: {
            for (set.members) |x| {
                for (want) |y| {
                    if (std.mem.eql(u8, x.name, y)) break;
                } else break :blk .any;
            }
            break :blk if (set.members.len == want.len) .exact else .subset;
        } else .any;
        if (best.*) |b| if (@backingInt(rank) <= @backingInt(b.rank)) continue;
        best.* = .{ .rank = rank, .decl = .{
            .target = .{ .file = file, .start = member.start, .end = member.end },
            .doc = if (member.doc) |d| try r.arena.dupe(u8, d) else null,
        } };
    }
}

const ErrorNameRange = struct { start: u32, end: u32 };

/// 节点中 `error{ ... }` 里名为 `name` 的错误的位置；名字按解码后的形式比较，区间为 token 自身
fn findErrorName(a: std.mem.Allocator, node: ast.SyntaxNode, name: []const u8, depth: u32) resolve.Error!?ErrorNameRange {
    if (depth > 16) return null;
    var it = node.children();
    while (it.next()) |child| switch (child) {
        .token => |t| if (node.kind() == .error_set_decl and t.kind == .identifier and std.mem.eql(u8, try ast.identNameAlloc(a, t.text), name))
            return .{ .start = t.offset, .end = t.offset + @as(u32, @intCast(t.text.len)) },
        .node => |n| if (try findErrorName(a, n, name, depth + 1)) |at| return at,
    };
    return null;
}

/// 标签：`break :l` / `continue :l` 中的 `l` 跳到带标签的块或循环的标签处，标签自身返回自身
fn labelTarget(r: *Resolver, file: FileId, offset: u32) resolve.Error!?Target {
    const tok = try tokenAt(r, file, offset) orelse return null;
    if (tok.kind != .identifier) return null;
    const item = try r.ownerAt(file, tok.offset, false) orelse return null;
    const node = try r.itemNode(file, item) orelse return null;
    const b = try r.body(file, item);
    const rel = tok.offset - node.offset;
    const e = b.exprAt(rel) orelse return null;
    const name = tok.text;
    const self_target: Target = .{ .file = file, .start = tok.offset, .end = tok.offset + @as(u32, @intCast(name.len)) };
    // 标签自身（块或循环的范围从标签开始）
    switch (b.expr(e)) {
        .block => |blk| if (blk.label) |l| if (b.range(e).start == rel and std.mem.eql(u8, l, name)) return self_target,
        .loop => |lp| if (lp.label) |l| if (b.range(e).start == rel and std.mem.eql(u8, l, name)) return self_target,
        else => {},
    }
    const label = switch (b.expr(e)) {
        .@"break" => |x| x.label,
        .@"continue" => |x| x.label,
        else => null,
    } orelse return null;
    // 光标在标签上，而不在 break 的值中
    const prev = (try r.ctx.get(database.syntax.ParseFile, file)).source[tok.offset - 1];
    if (!std.mem.eql(u8, label, name) or prev != ':') return null;
    var scope: ?Body.ScopeId = b.expr_scopes[@backingInt(e)];
    while (scope) |sc| : (scope = b.scopes[@backingInt(sc)].parent) {
        const l = b.scopes[@backingInt(sc)].label orelse continue;
        if (!std.mem.eql(u8, l.name, label)) continue;
        const start = node.offset + b.range(l.expr).start;
        return .{ .file = file, .start = start, .end = start + @as(u32, @intCast(label.len)) };
    }
    return null;
}

fn target(r: *Resolver, def: Def) resolve.Error!?Target {
    const loc = try r.location(def) orelse return null;
    return .{ .file = loc.file, .start = loc.start, .end = loc.end };
}

/// 光标处符号的类型的定义：声明与局部变量取其类型，表达式取推导出的类型；值本身是类型时取该类型。
/// 指针、optional、数组、切片、错误联合取其元素 / 载荷类型
pub fn typeDefinition(r: *Resolver, file: FileId, offset: u32) resolve.Error!?Target {
    const tok = try tokenAt(r, file, offset) orelse return null;
    const a = try context.atSeeded(r, file, tok.offset, false) orelse return null;
    const rel = tok.offset - a.node.offset;
    const tv: TypedValue = blk: {
        if (ast.memberName(a.node, try r.inEnum(file, a.item))) |name| if (name.offset == tok.offset) {
            break :blk try r.ctx.get(queries.DeclType, .{ .owner = a.owner });
        };
        for (a.body.bindings, 0..) |binding, i| if (binding.range.start == rel) break :blk a.bindingType(@fromBackingInt(@as(u32, @intCast(i))));
        break :blk a.exprType(a.body.exprAt(rel) orelse return null);
    };
    const ip = r.ctx.db.env.ip;
    var t = if (tv.ty == .type_type) tv.asType() orelse return null else tv.ty;
    for (0..8) |_| t = switch (ip.key(t)) {
        .ptr_type => |p| p.child,
        .optional_type => |c| c,
        .array_type => |arr| arr.child,
        .vector_type => |v| v.child,
        .error_union_type => |eu| eu.payload,
        else => break,
    };
    const ns = try queries.namespaceOfType(r, t) orelse return null;
    // 文件即容器：跳到文件开头
    if (ns.container == 0) return .{ .file = ns.file, .start = 0, .end = 0 };
    const tree = try r.itemTree(ns.file);
    // `const S = struct {...}`：跳到声明的名字；其他（如泛型函数返回的容器）跳到容器本身
    if (tree.containers[ns.container].parent_item) |p| if (tree.items[p].kind == .@"const") {
        if (try r.containerRel(ns)) |rel_c| if ((try r.body(ns.file, p)).value) |v| if ((try r.body(ns.file, p)).range(v).start == rel_c) {
            return target(r, .{ .item = .{ .file = ns.file, .item = p } });
        };
    };
    const start = try r.containerOffset(ns) orelse return null;
    return .{ .file = ns.file, .start = start, .end = start };
}

/// 光标处 token：优先取可跳转的 token，光标紧跟在标识符之后时取它
pub fn tokenAt(r: *Resolver, file: FileId, offset: u32) resolve.Error!?SyntaxToken {
    const root = (try r.ctx.get(database.syntax.ParseFile, file)).rootNode();
    if (root.tokenAtOffset(offset)) |t| if (isTarget(t)) return t;
    if (offset > 0) if (root.tokenAtOffset(offset - 1)) |t| if (isTarget(t)) return t;
    return null;
}

fn isTarget(t: SyntaxToken) bool {
    return t.kind == .identifier or t.kind == .builtin or t.kind == .string_literal;
}

pub fn defAt(r: *Resolver, file: FileId, offset: u32) resolve.Error!?Def {
    const tok = try tokenAt(r, file, offset) orelse return null;
    const item = try r.ownerAt(file, tok.offset, false) orelse return null;
    const node = try r.itemNode(file, item) orelse return null;
    // 成员自身的名字
    if (ast.memberName(node, try r.inEnum(file, item))) |name| if (name.offset == tok.offset) {
        // decltest：`test helper` 的标识符是对 helper 的引用，不是 test 自身的名字
        if (node.kind() == .test_decl and name.kind == .identifier) return r.resolveContainerName(file, item, try ast.identNameAlloc(r.arena, name.text));
        return .{ .item = .{ .file = file, .item = item } };
    };

    const b = try r.body(file, item);
    const rel = tok.offset - node.offset;
    // 局部绑定自身的名字
    for (b.bindings, 0..) |binding, i| {
        if (binding.range.start == rel) return .{ .local = .{ .file = file, .item = item, .binding = @fromBackingInt(@as(u32, @intCast(i))) } };
    }
    const e = b.exprAt(rel) orelse return null;
    switch (b.expr(e)) {
        .name_ref => |name| {
            if (Body.nameRefIsBuiltin(b, e)) return null;
            return r.resolveName(file, item, b, b.expr_scopes[@backingInt(e)], name);
        },
        .field_access => |fa| {
            // 光标在字段名上（不在左侧表达式内）
            if (rel < b.range(fa.lhs).end) return null;
            if (try r.evalNamespace(file, item, b, fa.lhs)) |ns| {
                if (try r.memberDef(ns, fa.field orelse return null)) |def| return def;
            }
            // 经由类型：字段、方法
            return memberViaTypes(r, file, tok.offset, e);
        },
        // decl literal（`.init(...)`、`.empty`）
        .enum_literal => return memberViaTypes(r, file, tok.offset, e),
        // 初始化中的字段名（`.{ .x = 1 }`、`S{ .x = 1 }`）：推导时按结果类型解析
        .init => |x| for (x.fields, 0..) |fi, k| {
            if (fi.name == null or rel < fi.name_range.start or rel >= fi.name_range.end) continue;
            const a = try context.atSeeded(r, file, tok.offset, false) orelse return null;
            return context.defOfKey(r, a.fieldRef(e, @intCast(k)) orelse return null);
        } else return null,
        // `@import` 与它的字符串
        .builtin_call, .literal => {
            const call = importCall(b, e) orelse return null;
            return .{ .file = try r.importTarget(file, b, call.args) orelse return null };
        },
        else => return null,
    }
}

/// `e` 为 `@import(...)` 调用或它的实参时的调用
fn importCall(b: *const Body, e: Body.ExprId) ?@FieldType(Body.Expr, "builtin_call") {
    const call = switch (b.expr(e)) {
        .builtin_call => |call| call,
        .literal => for (b.exprs) |other| switch (other) {
            .builtin_call => |call| if (std.mem.indexOfScalar(Body.ExprId, call.args, e) != null) break call,
            else => {},
        } else return null,
        else => return null,
    };
    return if (std.mem.eql(u8, call.name, "@import")) call else null;
}

fn memberViaTypes(r: *Resolver, file: FileId, offset: u32, e: Body.ExprId) resolve.Error!?Def {
    // 泛型函数体内取调用点的实例
    const a = try context.atSeeded(r, file, offset, false) orelse return null;
    const key = a.member(e) orelse return null;
    return context.defOfKey(r, key);
}
