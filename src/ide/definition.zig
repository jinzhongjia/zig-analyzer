//! Goto definition / declaration / type definition: names, member access, field names in
//! initializers, labels, `@import` strings, and paths to files in `build.zig.zon`.
//!
//! Declaration jumps to the declaration that a name resolves to directly; definition additionally
//! follows container-level aliases (`const A = std.mem.Allocator;`) to the final definition; type
//! definition jumps to the definition of the type of the symbol at the cursor (with pointers,
//! optionals, arrays, and error unions stripped).

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
const seed = @import("../ide_db/seed.zig");
const infer = @import("../sema/infer.zig");
const FileIndex = @import("../syntax/FileIndex.zig");
const ErrorSets = @import("../syntax/ErrorSets.zig");
const manifest = @import("manifest.zig");

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

/// All targets of definition: when the cursor is on `@import("name")` and the modules the file
/// belongs to import different modules as `name`, the root files of those modules (in module
/// priority order); otherwise the result of `definition`. The first one is the result of
/// `definition`.
pub fn definitionTargets(r: *Resolver, file: FileId, offset: u32) resolve.Error![]const Target {
    if (try importTargetsAt(r, file, offset)) |targets| return targets;
    return single(r, try definition(r, file, offset));
}

/// All targets of declaration: like `definitionTargets`, but otherwise the result of `declaration`
pub fn declarationTargets(r: *Resolver, file: FileId, offset: u32) resolve.Error![]const Target {
    if (try importTargetsAt(r, file, offset)) |targets| return targets;
    return single(r, try declaration(r, file, offset));
}

fn single(r: *Resolver, t: ?Target) resolve.Error![]const Target {
    return r.arena.dupe(Target, if (t) |x| &.{x} else &.{});
}

/// A path string in `build.zig.zon` that points to a file (an element of `.paths`, the `.path` of
/// a dependency): the absolute path of that file, whose start is the target of definition and
/// declaration (see `manifest.pathTarget`)
pub fn manifestPath(r: *Resolver, file: FileId, offset: u32) resolve.Error!?[]const u8 {
    const tok = try tokenAt(r, file, offset) orelse return null;
    return manifest.pathTarget(r, file, tok);
}

/// All targets of the import (start of each file) when the cursor is on `@import(...)` or its
/// string. These tokens are not names; for them, `definition` / `declaration` take only the first
/// target of the import, via `defAt`.
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

/// Names that are themselves declaration sites but are not members or local bindings: `Foo` in the
/// error set `error{ Foo }`, and field names in an anonymous initializer `.{ .x = 1 }` without a
/// result type (they define the fields of an anonymous struct). As when jumping from the name of a
/// declaration, returns the name itself.
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
        // With a result type (when the field cannot be resolved), it is not a declaration site
        const a = try context.atSeeded(r, file, tok.offset, false) orelse return null;
        if (a.literalExpected(e) != null) return null;
        return span;
    }
    return null;
}

/// Members of constructed types (`@Struct`, `@Enum`, `@Union`): field access `x.name`, `E.name`
/// accessed via the type, and enum literals `.name`. The name is a string computed at comptime;
/// jumps to its origin in the source: a string literal (such as the help text of zig-clap), or the
/// member of the same name in X given by `@typeInfo(X)`.
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
            // When the result type is `?E` or `E!T`, take E; for a literal passed to an anytype
            // parameter, take the type the callee converts it to
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
        // Tag enum of a `union(enum)`: its members are the fields of the union
        .union_tag_type => |u| switch (ip.key(u)) {
            .reified_type => |x| x,
            else => return null,
        },
        else => return null,
    };
    // Only enum members are accessible via the type (struct and union types have only declarations)
    if (via_type and rt.kind != .@"enum") return null;
    for (rt.names) |n| {
        if (std.mem.eql(u8, n, name)) break;
    } else return null;
    // Look for the string literal of the name first at the use site, then in the file of the member
    // that constructs the type (including its local constants, such as
    // `blk: { const extra = .{...}; ... }`)
    if (try literalOrigin(r, file, .{ .item = item, .body = b, .at = a }, rt, name)) |found| return found;
    const owner = try ownerLocal(r, rt);
    if (rt.file != file or owner == null or owner.?.item != item) if (try literalOrigin(r, rt.file, owner, rt, name)) |found| return found;
    if (try constructionOrigin(r, rt, name)) |found| return found;
    var visited: std.AutoHashMapUnmanaged(Index, void) = .empty;
    if (rt.inst) |inst| if (try callSiteOrigin(r, inst, name, &visited)) |found| return found;
    if (try typeInfoOrigin(r, rt, name)) |found| return found;
    return constructionSite(r, rt);
}

/// When the origin of the name cannot be traced to specific characters (such as a name made of a
/// single byte `@as(*const [1]u8, &c)`): the member is defined at the call that constructs the type
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

/// Origin of a name that comes from an argument of the instance `inst` in which the type is
/// constructed (such as the parameter table passed in by zig-clap's
/// `clap.parse(clap.Help, &args.params, ...)` and obtained by parsing help text in another file):
/// takes the corresponding argument expression at the call sites of `inst`. When the argument is a
/// parameter of an outer generic function, continues at the call sites of the instances of the
/// outer function whose argument value is the same; otherwise evaluates the argument while tracking
/// literal origins (when the argument refers to a declaration, evaluates that declaration). Visited
/// instances are recorded in `visited` and not repeated: the result depends only on the instance,
/// and generic functions that call each other do not cycle either.
fn callSiteOrigin(r: *Resolver, inst: Index, name: []const u8, visited: *std.AutoHashMapUnmanaged(Index, void)) resolve.Error!?Target {
    if ((try visited.getOrPut(r.arena, inst)).found_existing) return null;
    const ip = r.ctx.db.env.ip;
    const ins = switch (ip.key(inst)) {
        .instance => |x| x,
        else => return null,
    };
    const fn_key: database.hir.OwnerKey = .{ .file = ins.file, .item = ins.decl };
    const fn_body = try r.ctx.get(database.hir.ItemBody, fn_key);
    const sites = try seed.allFound(r, fn_key);
    for (ins.args, 0..) |arg, k| {
        var path: std.ArrayList(u32) = .empty;
        var chain: std.ArrayList(Index) = .empty;
        if (!try eval.findString(ip, r.arena, arg, name, &path, &chain)) continue;
        for (sites) |site| {
            if (site.inst != inst) continue;
            const site_item = try itemOf(r, site.owner) orelse continue;
            const body = try r.ctx.get(database.hir.ItemBody, site.owner);
            const args = switch (body.expr(site.expr)) {
                .call => |c| c.args,
                else => continue,
            };
            // Method call: the receiver is the first parameter
            const skip = fn_body.params.len -| args.len;
            if (k < skip or k - skip >= args.len) continue;
            const arg_e = stripAddress(body, args[k - skip]);
            if (try paramOf(r, site.owner.file, site_item, body, arg_e)) |p| {
                // Parameter of an outer generic function: the instances of the outer function
                // whose argument value is the same as here
                const outer_key = try r.ownerKey(p.file, p.item);
                for (try seed.allFound(r, outer_key)) |outer| {
                    const outer_inst = outer.inst orelse continue;
                    const outer_args = switch (ip.key(outer_inst)) {
                        .instance => |x| x.args,
                        else => continue,
                    };
                    if (p.index >= outer_args.len or !sharesValue(ip, outer_inst, chain.items)) continue;
                    if (try callSiteOrigin(r, outer_inst, name, visited)) |found| return found;
                }
                continue;
            }
            const origin = if (try declOf(r, site.owner.file, site_item, body, arg_e)) |d| blk: {
                // Refers to a declaration: evaluate that declaration again
                const decl_body = try r.body(d.file, d.item);
                const value = decl_body.value orelse continue;
                break :blk try eval.stringOrigin(r, d.file, d.item, decl_body, value, path.items);
            } else try eval.stringOrigin(r, site.owner.file, site_item, body, arg_e, path.items);
            if (origin) |o| return originTarget(r, o, name);
        }
    }
    return null;
}

/// Strips address-of, parentheses, and `comptime`: `&args.params` → `args.params`
fn stripAddress(body: *const Body, e: Body.ExprId) Body.ExprId {
    var cur = e;
    while (true) switch (body.expr(cur)) {
        .prefix => |p| if (p.op == .ampersand) {
            cur = p.operand;
        } else return cur,
        .@"comptime" => |x| cur = x,
        else => return cur,
    };
}

/// When `e` is a parameter of a function (including parameters of outer functions, such as
/// `params` referenced in the container returned by a type constructor), that function and the
/// index of the parameter
fn paramOf(r: *Resolver, file: FileId, item: u32, body: *const Body, e: Body.ExprId) resolve.Error!?struct { file: FileId, item: u32, index: u32 } {
    const n = switch (body.expr(e)) {
        .name_ref => |x| x,
        else => return null,
    };
    const l = switch (try r.resolveName(file, item, body, body.expr_scopes[@backingInt(e)], n) orelse return null) {
        .local => |x| x,
        else => return null,
    };
    const owner_body = if (l.file == file and l.item == item) body else try r.body(l.file, l.item);
    const index = std.mem.indexOfScalar(Body.BindingId, owner_body.params, l.binding) orelse return null;
    return .{ .file = l.file, .item = l.item, .index = @intCast(index) };
}

/// The declaration that `e` (a name or member access) refers to
fn declOf(r: *Resolver, file: FileId, item: u32, body: *const Body, e: Body.ExprId) resolve.Error!?@FieldType(resolve.Def, "item") {
    const def: ?resolve.Def = switch (body.expr(e)) {
        .name_ref => |n| try r.resolveName(file, item, body, body.expr_scopes[@backingInt(e)], n),
        .field_access => |fa| blk: {
            const ns = try r.evalNamespace(file, item, body, fa.lhs) orelse return null;
            break :blk try r.memberDef(ns, fa.field orelse return null);
        },
        else => null,
    };
    return switch (def orelse return null) {
        .item => |it| it,
        else => null,
    };
}

fn itemOf(r: *Resolver, key: database.hir.OwnerKey) resolve.Error!?u32 {
    for ((try r.itemTree(key.file)).items, 0..) |it, i| if (it.ast_id == key.item) return @intCast(i);
    return null;
}

/// The member that constructs the type (`rt.owner`): its local bindings are also candidates for
/// the origin of a name
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

/// A member whose local bindings are also candidates: the member containing the use site, or the
/// member that constructs the type (evaluated under its instance `inst`)
const Local = struct { item: u32, body: *const Body, at: context.At, inst: ?Index = null };

/// The string literal origin of the name `name` in the file `file`. Candidates are the constants
/// whose initializer contains the literal (directly or via a constant containing it), and the local
/// bindings in `local`: their values are computed and the string is found in them, then they are
/// evaluated again while tracking literal origins.
fn literalOrigin(r: *Resolver, file: FileId, local: ?Local, rt: InternPool.Reified, name: []const u8) resolve.Error!?Target {
    const ip = r.ctx.db.env.ip;
    const Candidate = struct { item: u32, body: *const Body, expr: Body.ExprId, value: Index };
    var cands: std.ArrayList(Candidate) = .empty;
    const tree = try r.itemTree(file);
    // Constants (names) whose initializer directly contains a string literal of the name, and
    // the constants that contain it through them
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
        // Inference produces no values for strings (such as `const extra = [_][]const u8{"a"};`
        // in a block): when there is none, evaluate it at comptime
        const v = l.at.bindingType(@fromBackingInt(@intCast(bi))).val orelse
            (try eval.exprValue(r, file, l.item, l.body, init, l.inst, l.at.res.bindings, null, eval.bodyQuota(r, l.body, l.at.res.exprs))).val orelse continue;
        try cands.append(r.arena, .{ .item = l.item, .body = l.body, .expr = init, .value = v });
    };

    var chosen: ?struct { cand: Candidate, path: []const u32 } = null;
    var found: u32 = 0;
    var shared: u32 = 0;
    // Candidates with the same value (`const nodes = node_kinds;`) are the same origin: counted
    // once, taking the one that appears first
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
        // Candidates that share a value with the instance arguments take precedence; when none
        // does, a candidate is taken only if it is the only one
        if (share or (shared == 0 and chosen == null)) chosen = .{ .cand = c, .path = path.items };
    }
    const pick = chosen orelse return null;
    if (shared > 1 or (shared == 0 and found > 1)) return null;

    const origin = try eval.stringOrigin(r, file, pick.cand.item, pick.cand.body, pick.cand.expr, pick.path) orelse return null;
    return originTarget(r, origin, name);
}

/// The range of the literal in the source that corresponds to the string origin `origin`
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

/// Origin when the name slice is written directly in the construction call
/// (`@Enum(..., &.{"fast", "slow"}, ...)`): evaluates the 3rd argument of the construction (the
/// name slice), finds `name` in it, then follows the string origin to the literal
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

/// When the member names of a constructed type come from `@typeInfo(X)` (such as
/// `@typeInfo(Tag).@"enum".field_names`), the member of the same name in X: finds the arguments of
/// `@typeInfo` in the member where the construction happens, and takes the first type that has
/// this member
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

/// The range of `e` contains a string literal whose content contains `name`
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

/// The range of `e` references a name in `names`
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

/// The arguments of the instance `inst` (and of the instances enclosing it) contain one of the
/// values in `values`
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

/// Members of named error sets: `Error.Foo` jumps to `Foo` in the declaration
/// `const Error = error{ Foo, ... }` (following the alias when the declaration is an alias)
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

/// Position and documentation of the `Foo` of `error.Foo` in an error set declaration
pub const ErrorDecl = struct { target: Target, doc: ?[]const u8 };

/// `error.Foo`: error names need not be declared first, and errors with the same name may appear in
/// several error sets. Searches `error{ ... }` declarations: one whose members are exactly the
/// expected error set is preferred, then one that is part of the expected error set (`A` in
/// `A || B`), then any that contains the name. Searches the current file first; with `imports`,
/// then the files reachable through imports (filtered by name with the file index), until one that
/// cannot be superseded is found: an exact match when there is an expected error set; without one,
/// all declarations match equally well and the first is taken.
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

/// Members of the expected error set of `error.X` (for an error union, its error set)
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

/// The `error{ ... }` declarations in the file that contain an error named `name`: one that
/// matches the expected error set better than `best` replaces it (on a tie, the one that appears
/// first is taken)
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

/// Location of the error named `name` inside an `error{ ... }` in the node; names are compared in
/// decoded form, and the range is the token itself
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

/// Labels: `l` in `break :l` / `continue :l` jumps to the label of the labeled block or loop; a
/// label itself returns itself
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
    // The label itself (the range of a block or loop starts at the label)
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
    // The cursor is on the label, not in the value of the break
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

/// Definition of the type of the symbol at the cursor: declarations and local variables take their
/// type, expressions take the inferred type; when the value itself is a type, that type is taken.
/// Pointers, optionals, arrays, slices, and error unions take their element / payload type.
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
    // The file is the container: jump to the start of the file
    if (ns.container == 0) return .{ .file = ns.file, .start = 0, .end = 0 };
    const tree = try r.itemTree(ns.file);
    // `const S = struct {...}`: jump to the name of the declaration; otherwise (such as a
    // container returned by a generic function) jump to the container itself
    if (tree.containers[ns.container].parent_item) |p| if (tree.items[p].kind == .@"const") {
        if (try r.containerRel(ns)) |rel_c| if ((try r.body(ns.file, p)).value) |v| if ((try r.body(ns.file, p)).range(v).start == rel_c) {
            return target(r, .{ .item = .{ .file = ns.file, .item = p } });
        };
    };
    const start = try r.containerOffset(ns) orelse return null;
    return .{ .file = ns.file, .start = start, .end = start };
}

/// The token at the cursor: a token that can be jumped from is preferred; when the cursor
/// immediately follows an identifier, that identifier is taken
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
    // The name of the member itself
    if (ast.memberName(node, try r.inEnum(file, item))) |name| if (name.offset == tok.offset) {
        // decltest: the identifier in `test helper` is a reference to helper, not the name of the
        // test itself
        if (node.kind() == .test_decl and name.kind == .identifier) return r.resolveContainerName(file, item, try ast.identNameAlloc(r.arena, name.text));
        return .{ .item = .{ .file = file, .item = item } };
    };

    const b = try r.body(file, item);
    const rel = tok.offset - node.offset;
    // The name of the local binding itself
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
            // The cursor is on the field name (not inside the left-hand expression)
            if (rel < b.range(fa.lhs).end) return null;
            if (try r.evalNamespace(file, item, b, fa.lhs)) |ns| {
                if (try r.memberDef(ns, fa.field orelse return null)) |def| return def;
            }
            // Via the type: fields, methods
            return memberViaTypes(r, file, tok.offset, e);
        },
        // Decl literal (`.init(...)`, `.empty`)
        .enum_literal => return memberViaTypes(r, file, tok.offset, e),
        // Field names in initializers (`.{ .x = 1 }`, `S{ .x = 1 }`): resolved by the result type
        // during inference
        .init => |x| for (x.fields, 0..) |fi, k| {
            if (fi.name == null or rel < fi.name_range.start or rel >= fi.name_range.end) continue;
            const a = try context.atSeeded(r, file, tok.offset, false) orelse return null;
            return context.defOfKey(r, a.fieldRef(e, @intCast(k)) orelse return null);
        } else return null,
        // `@import` and its string
        .builtin_call, .literal => {
            const call = importCall(b, e) orelse return null;
            return .{ .file = try r.importTarget(file, b, call.args) orelse return null };
        },
        else => return null,
    }
}

/// The call, when `e` is an `@import(...)` call or its argument
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
    // Inside the body of a generic function, use the instance from a call site
    const a = try context.atSeeded(r, file, offset, false) orelse return null;
    const key = a.member(e) orelse return null;
    return context.defOfKey(r, key);
}
