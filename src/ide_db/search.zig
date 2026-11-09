//! Find references: coarsely filter candidate files by name, then confirm each occurrence by
//! precise resolution.
//!
//! Candidate files: the files in scope that can be compiled together with the file containing
//! the definition (see `candidateFiles`): the files that can reach it through an `@import` chain,
//! and the files those reach (generic code can access the members of the file containing the
//! definition without importing it, through an `anytype` value or a comptime type parameter),
//! provided that the file index contains the name. A local name is searched for only in its
//! enclosing member (and the members of containers defined in its body).
//! Only members in which the name occurs are resolved; name references use name resolution, and
//! field accesses prefer namespace evaluation, reading the member's type inference result only
//! when that fails. Labels are searched only in the member that contains them, and error names,
//! which are global, in the files compiled together with the file where the name was found (see
//! `Symbol`).

const std = @import("std");
const database = @import("../database.zig");
const hir = database.hir;
const sema = database.sema;
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Def = resolve.Def;
const Body = @import("../hir/Body.zig");
const ast = @import("../syntax/ast.zig");
const infer = @import("../sema/infer.zig");
const FileIndex = @import("../syntax/FileIndex.zig");
const ErrorSets = @import("../syntax/ErrorSets.zig");
const Vfs = @import("../base/Vfs.zig");
const FileId = Vfs.FileId;
const deepEql = @import("../util/deep_eql.zig").deepEql;
const seed = @import("seed.zig");
const InternPool = @import("../sema/InternPool.zig");
const value = @import("../sema/value.zig");

pub const Reference = struct {
    file: FileId,
    start: u32,
    end: u32,
    /// Name at the definition site
    is_decl: bool = false,
    /// Written to: the target of an assignment (`x = v`, `x += v`) or of a destructuring
    /// assignment (`a, b = v`)
    is_write: bool = false,
};

/// Name of the definition; null when it has no referenceable name (files, test and comptime blocks)
pub fn defName(r: *Resolver, def: Def) resolve.Error!?[]const u8 {
    switch (def) {
        .item => |it| {
            const item = (try r.itemTree(it.file)).items[it.item];
            return switch (item.kind) {
                .@"test", .@"comptime" => null,
                else => item.name,
            };
        },
        .local => |l| return (try r.body(l.file, l.item)).binding(l.binding).name,
        .file => return null,
    }
}

/// Whether code in other files can refer to the definition: `pub` declarations and fields (members
/// without `pub` and local names are visible only in their own file)
pub fn visibleOutsideFile(r: *Resolver, def: Def) resolve.Error!bool {
    return switch (def) {
        .item => |it| blk: {
            const item = (try r.itemTree(it.file)).items[it.item];
            break :blk item.flags.is_pub or item.kind == .field;
        },
        .local => false,
        .file => true,
    };
}

pub const Options = struct {
    /// Search scope (files in the project); always includes the file containing the definition.
    /// Not used with `only_file`
    scope: []const FileId,
    /// Search only in this file (document highlight)
    only_file: ?FileId = null,
    /// When not null, records the first ambiguous reference: a member access that refers to `def`
    /// under some call-site instances of its generic function, iterations of its loop or `inline`
    /// prong, or build configurations of its namespace, and to other definitions under others
    /// (renaming would break the others, so it should be refused; see `ambiguous_message`)
    ambiguous: ?*?Reference = null,
    /// When not null, records the first member access with the same name that cannot be confirmed
    /// (field access, enum literal, field in an initializer): the type of the left-hand side or the
    /// expected type is unknown or abstract, and no call-site instance determines the member
    /// either, so it may be a reference
    uncertain: ?*?Reference = null,
    /// When not null, records the first file that has syntax errors and also contains this name:
    /// the code at an error is not necessarily lowered to HIR, so references in it may be missed
    syntax_error: ?*?FileId = null,
    /// When not null, records the first member access that has to be decided per call-site instance
    /// while the instances are incomplete (truncated because instantiation grows without bound; see
    /// `seed.AllInstances`): it may or may not be a reference in the other instances
    incomplete: ?*?Reference = null,
    /// When not null, records the first name in a `.zon` file whose import sites give result types
    /// that cannot be named (see `sema.ZonImports`): the name may refer to the field under some of
    /// them and not under others, and renaming would break them; see `zon_import_message`
    zon_import: ?*?Reference = null,
};

/// Why a reference recorded in `Options.zon_import` prevents a rename
pub const zon_import_message = "this `.zon` file is imported with different or generic result types, so its uses cannot all be confirmed";

/// Why an ambiguous reference (see `Options.ambiguous`) prevents a rename or fix
pub const ambiguous_message = "this reference also refers to other declarations in other instantiations of its generic function or `inline` prong, iterations of its loop, or build configurations";

/// All references to `def` (including the definition itself), sorted by file and position
pub fn findReferences(r: *Resolver, def: Def, opts: Options) resolve.Error![]Reference {
    const name = try defName(r, def) orelse return &.{};
    var out: std.ArrayList(Reference) = .empty;
    if (try r.location(def)) |loc| {
        if (opts.only_file == null or opts.only_file.? == loc.file) try out.append(r.arena, .{ .file = loc.file, .start = loc.start, .end = loc.end, .is_decl = true });
    }
    const def_file = switch (def) {
        .item => |it| it.file,
        .local => |l| l.file,
        .file => unreachable,
    };

    const is_field = switch (def) {
        .item => |it| (try r.itemTree(it.file)).items[it.item].kind == .field,
        else => false,
    };
    var finder: Finder = .{ .r = r, .def = def, .is_field = is_field, .name = name, .out = &out, .ambiguous = opts.ambiguous, .uncertain = opts.uncertain, .incomplete = opts.incomplete, .zon_import = opts.zon_import };
    switch (def) {
        .local => |l| {
            if (opts.only_file) |f| if (f != l.file) return out.items;
            try noteSyntaxError(r, opts.syntax_error, l.file);
            // Local name: the enclosing member and the members of containers defined in its body
            const tree = try r.itemTree(l.file);
            for (0..tree.items.len) |i| {
                if (try sema.enclosedBy(r, l.file, @intCast(i), tree.items[l.item].ast_id)) try finder.item(l.file, @intCast(i));
            }
        },
        .item => {
            // Only whether the one file can reach the definition matters (document highlight)
            const reach = if (opts.only_file) |f|
                (if (f == def_file or try reaches(r, f, def_file)) try r.arena.dupe(FileId, &.{f}) else &.{})
            else
                try importers(r, def_file, opts.scope);
            for (reach) |f| try finder.importing.put(r.arena, f, {});
            const files = if (opts.only_file) |f| try r.arena.dupe(FileId, &.{f}) else try candidateFiles(r, reach, opts.scope);
            for (files) |f| {
                const index = try r.ctx.get(FileIndex.Query, f);
                if (!index.contains(name)) continue;
                try noteSyntaxError(r, opts.syntax_error, f);
                const tree = try r.itemTree(f);
                for (0..tree.items.len) |i| try finder.item(f, @intCast(i));
            }
        },
        .file => unreachable,
    }

    return sortUnique(out.items);
}

/// Sorts references by file and position and drops duplicates: the definition site may also show up
/// as an expression (e.g. several resolution paths at the same position)
fn sortUnique(refs: []Reference) []Reference {
    std.mem.sort(Reference, refs, {}, struct {
        fn lt(_: void, a: Reference, b: Reference) bool {
            if (a.file != b.file) return @backingInt(a.file) < @backingInt(b.file);
            return a.start < b.start;
        }
    }.lt);
    var n: usize = 0;
    for (refs) |ref| {
        if (n > 0 and refs[n - 1].file == ref.file and refs[n - 1].start == ref.start) {
            refs[n - 1].is_decl = refs[n - 1].is_decl or ref.is_decl;
            refs[n - 1].is_write = refs[n - 1].is_write or ref.is_write;
            continue;
        }
        refs[n] = ref;
        n += 1;
    }
    return refs[0..n];
}

/// A label: the labeled block, loop or switch `expr` of member `item`. A label is visible only
/// inside the expression it labels, so all its references are in that member
pub const Label = struct {
    file: FileId,
    item: u32,
    expr: Body.ExprId,
};

/// What find references, document highlight and rename work on
pub const Symbol = union(enum) {
    /// A declaration or a local name
    def: Def,
    label: Label,
    /// An error name found in `file`. Error names are global: `error.X`, the `X` of `error{ X }`
    /// and the member `X` of an error set type are one error in a compilation, whichever error set
    /// they are written in, so the files compiled together with `file` are searched
    error_name: struct { file: FileId, name: []const u8 },
    zon_field: ZonField,
};

/// A field of a struct literal in a `.zon` file, the definition of the name when the file has no
/// result type. As in the compiler, each literal has a type of its own, which identifies it
/// wherever the value goes (see `InternPool.ZonLiteral`)
pub const ZonField = struct {
    literal: InternPool.ZonLiteral,
    name: []const u8,
};

/// Where a `ZonField` is written
pub const ZonFieldSite = struct {
    file: FileId,
    item: u32,
    /// The initializer expression of the literal, and the index of the field in it
    init: Body.ExprId,
    index: u32,
    start: u32,
    end: u32,
};

/// The name of `field` in its `.zon` file; null when the literal has no such field
pub fn zonFieldSite(r: *Resolver, field: ZonField) resolve.Error!?ZonFieldSite {
    const file = field.literal.file;
    const tree = try r.itemTree(file);
    const item: u32 = for (tree.items, 0..) |it, i| {
        if (it.kind == .zon) break @intCast(i);
    } else return null;
    const base = try r.itemOffset(file, item) orelse return null;
    const b = try r.body(file, item);
    var e = b.value orelse return null;
    for (field.literal.path) |i| e = switch (b.expr(e)) {
        .init => |x| if (i < x.fields.len) x.fields[i].value else return null,
        else => return null,
    };
    const fields = switch (b.expr(e)) {
        .init => |x| x.fields,
        else => return null,
    };
    for (fields, 0..) |fi, k| if (fi.name != null and std.mem.eql(u8, fi.name.?, field.name)) {
        return .{ .file = file, .item = item, .init = e, .index = @intCast(k), .start = base + fi.name_range.start, .end = base + fi.name_range.end };
    };
    return null;
}

/// The declaration that the field at `site` refers to, when its file has a result type
pub fn typedZonField(r: *Resolver, site: ZonFieldSite) resolve.Error!?Def {
    if ((try r.ctx.get(database.sema.ZonImports, site.file)).result_type == null) return null;
    const res = try r.ctx.get(sema.Infer, .{ .owner = try r.ownerKey(site.file, site.item), .mode = .full });
    for (res.field_refs) |fr| if (fr.init == site.init and fr.index == site.index) return keyDef(r, fr.member);
    return null;
}

/// The result types the import sites of a `.zon` file give it, under each instance where a site is in
/// a generic function. `complete` is false when a site's type could not be determined, or there may
/// be instances that are not listed.
fn zonSiteTypes(r: *Resolver, file: FileId) resolve.Error!struct { types: []const InternPool.Index, complete: bool } {
    const ip = r.ctx.db.env.ip;
    var types: std.AutoArrayHashMapUnmanaged(InternPool.Index, void) = .empty;
    var complete = true;
    for (try database.sema.ZonImports.owners(r, file)) |owner| {
        var results: std.ArrayList(*const infer.Result) = .empty;
        try results.append(r.arena, try r.ctx.get(sema.Infer, .{ .owner = owner.key, .mode = .full }));
        const all = try seed.allInstances(r, owner.file, owner.item);
        if (!all.complete) complete = false;
        for (all.insts) |inst| try results.append(r.arena, try r.ctx.get(sema.Infer, .{ .owner = owner.key, .mode = .full, .inst = inst }));
        for (results.items, 0..) |res, i| for (res.zon_imports) |site| {
            if (site.file != file) continue;
            if (value.isConcrete(ip, site.ty)) {
                try types.put(r.arena, site.ty, {});
            } else if (i > 0 or all.insts.len == 0) {
                // The abstract inference of a generic function leaves the type to its instances
                complete = false;
            }
        };
    }
    return .{ .types = types.keys(), .complete = complete };
}

/// The `.zon` file literal of the type `ty`, through a single-item pointer
pub fn zonLiteralOfType(ip: *InternPool, ty: InternPool.Index) ?InternPool.ZonLiteral {
    const t = switch (ip.key(ty)) {
        .ptr_type => |p| if (p.size == .one) p.child else ty,
        else => ty,
    };
    return switch (ip.key(t)) {
        .anon_struct_type => |s| s.origin,
        else => null,
    };
}

/// The `.zon` file literals that the value of `e` (at `rel` in the member) has the type of: from the
/// abstract inference `res`, or under each call-site instance and iteration when that does not
/// determine the type, each literal once. A written or expected type counts for an initializer
pub fn zonLiteralsOf(r: *Resolver, file: FileId, item: u32, body: *const Body, res: *const infer.Result, e: Body.ExprId, rel: u32) resolve.Error![]const InternPool.ZonLiteral {
    const ip = r.ctx.db.env.ip;
    var out: std.ArrayList(InternPool.ZonLiteral) = .empty;
    const add = struct {
        fn add(rr: *Resolver, list: *std.ArrayList(InternPool.ZonLiteral), pool: *InternPool, b: *const Body, from: *const infer.Result, x: Body.ExprId) resolve.Error!void {
            const i = @backingInt(x);
            if (i >= from.exprs.len) return;
            var ty = from.exprs[i].ty;
            if (b.expr(x) == .init) {
                const init = b.expr(x).init;
                if (init.ty) |te| {
                    if (@backingInt(te) < from.exprs.len) ty = from.exprs[@backingInt(te)].asType() orelse return;
                } else for (from.literal_expected) |le| if (le.expr == x) {
                    ty = le.ty;
                };
            }
            const literal = zonLiteralOfType(pool, ty) orelse return;
            for (list.items) |o| if (o.file == literal.file and std.mem.eql(u32, o.path, literal.path)) return;
            try list.append(rr.arena, literal);
        }
    }.add;
    try add(r, &out, ip, body, res, e);
    const i = @backingInt(e);
    if (out.items.len == 0 and (i >= res.exprs.len or seed.wanted(ip, res.exprs[i]))) {
        for (try seed.allSeeds(r, file, item, body, res, rel)) |s| try add(r, &out, ip, body, s.res, e);
    }
    return out.items;
}

/// All references to the field: the name in the `.zon` file, field accesses on values of the type
/// of its literal, and the field names of initializers of that type. Found in the files that can
/// reach the `.zon` file and the files those reach, like the members of a file (see
/// `findReferences`): a value travels through generic code without an import.
fn zonFieldReferences(r: *Resolver, field: ZonField, opts: Options) resolve.Error![]Reference {
    var out: std.ArrayList(Reference) = .empty;
    const site = try zonFieldSite(r, field) orelse return &.{};
    const decl: Reference = .{ .file = site.file, .start = site.start, .end = site.end, .is_decl = true };
    if (opts.only_file == null or opts.only_file.? == site.file) try out.append(r.arena, decl);
    if ((try r.ctx.get(database.sema.ZonImports, site.file)).unresolved) if (opts.zon_import) |slot| if (slot.* == null) {
        slot.* = decl;
    };
    try noteSyntaxError(r, opts.syntax_error, site.file);
    const reach = if (opts.only_file) |f|
        (if (f == site.file or try reaches(r, f, site.file)) try r.arena.dupe(FileId, &.{f}) else &.{})
    else
        try importers(r, site.file, opts.scope);
    const files = if (opts.only_file) |f| try r.arena.dupe(FileId, &.{f}) else try candidateFiles(r, reach, opts.scope);
    // The name of `Finder.def` is what this looks for; its other uses are not reached from here
    var finder: Finder = .{ .r = r, .def = .{ .file = site.file }, .is_field = true, .name = field.name, .out = &out, .ambiguous = opts.ambiguous, .uncertain = opts.uncertain, .incomplete = opts.incomplete, .zon_import = opts.zon_import };
    for (files) |f| {
        if (f == site.file) continue;
        const index = try r.ctx.get(FileIndex.Query, f);
        if (!index.contains(field.name)) continue;
        // Nothing in another `.zon` file refers to the field unless the file is parsed as this type
        if (r.isZon(f) and (try r.ctx.get(database.sema.ZonImports, f)).result_type == null) continue;
        try noteSyntaxError(r, opts.syntax_error, f);
        const tree = try r.itemTree(f);
        for (0..tree.items.len) |i| try finder.zonFieldUses(f, @intCast(i), field.literal);
    }
    return sortUnique(out.items);
}

/// Name of the symbol (see `defName`)
pub fn symbolName(r: *Resolver, symbol: Symbol) resolve.Error!?[]const u8 {
    return switch (symbol) {
        .def => |def| defName(r, def),
        .label => |l| labelName(try r.body(l.file, l.item), l.expr),
        .error_name => |e| e.name,
        .zon_field => |z| z.name,
    };
}

fn labelName(b: *const Body, e: Body.ExprId) ?[]const u8 {
    for (b.scopes) |s| if (s.label) |l| if (l.expr == e) return l.name;
    return null;
}

/// All references to the symbol, sorted by file and position (see `findReferences`,
/// `labelReferences` and `findErrorReferences`)
pub fn symbolReferences(r: *Resolver, symbol: Symbol, opts: Options) resolve.Error![]Reference {
    switch (symbol) {
        .def => |def| return findReferences(r, def, opts),
        .label => |l| {
            if (opts.only_file) |f| if (f != l.file) return &.{};
            try noteSyntaxError(r, opts.syntax_error, l.file);
            return labelReferences(r, l);
        },
        .error_name => |e| return findErrorReferences(r, e.name, e.file, opts),
        .zon_field => |z| return zonFieldReferences(r, z, opts),
    }
}

/// References to a label: the label itself and the `break :l` / `continue :l` that target it,
/// sorted by position
pub fn labelReferences(r: *Resolver, label: Label) resolve.Error![]Reference {
    const b = try r.body(label.file, label.item);
    const node = try r.itemNode(label.file, label.item) orelse return &.{};
    const name = labelName(b, label.expr) orelse return &.{};
    var out: std.ArrayList(Reference) = .empty;
    // The labeled expression starts at its label
    const def = node.tokenAtOffset(node.offset + b.range(label.expr).start) orelse return &.{};
    try out.append(r.arena, .{ .file = label.file, .start = def.offset, .end = def.range().end, .is_decl = true });
    for (b.exprs, 0..) |e, i| {
        const l = switch (e) {
            .@"break" => |x| x.label,
            .@"continue" => |x| x.label,
            else => null,
        } orelse continue;
        const id: Body.ExprId = @fromBackingInt(@as(u32, @intCast(i)));
        if (!std.mem.eql(u8, l, name) or b.labelTarget(id, l) != label.expr) continue;
        // The keyword is a token of the `break` / `continue` node itself
        const path = try node.coveringPath(r.arena, node.offset + b.expr_ranges[i].start);
        const jump = path[path.len - 1];
        if (jump.kind() != .break_expr and jump.kind() != .continue_expr) continue;
        const tok = (ast.BreakExpr{ .syntax = jump }).label() orelse continue;
        try out.append(r.arena, .{ .file = label.file, .start = tok.offset, .end = tok.range().end });
    }
    return sortUnique(out.items);
}

/// All uses of the error named `name` in the files of `opts.scope` compiled together with `file`
/// (see `Symbol.error_name`), or in `opts.only_file`, sorted by file and position: the members of
/// error set declarations (`is_decl`), `error.X`, and member accesses `E.X` on error set types. A
/// member access whose left-hand side cannot be determined is recorded as uncertain, and one whose
/// left-hand side is an error set in some call-site instances only as ambiguous (`opts`)
pub fn findErrorReferences(r: *Resolver, name: []const u8, file: FileId, opts: Options) resolve.Error![]Reference {
    var out: std.ArrayList(Reference) = .empty;
    const files = if (opts.only_file) |f| try r.arena.dupe(FileId, &.{f}) else try candidateFiles(r, try importers(r, file, opts.scope), opts.scope);
    for (files) |f| {
        if (!(try r.ctx.get(FileIndex.Query, f)).contains(name)) continue;
        try noteSyntaxError(r, opts.syntax_error, f);
        try errorUses(r, f, name, true, true, &out, opts);
    }
    return sortUnique(out.items);
}

/// Position of the first use of the error named `name` in `file` (see `findErrorReferences`); with
/// `accesses`, member accesses `E.X` count too, including those whose left-hand side cannot be
/// determined. Every error name of a compilation is written in an `error{ ... }` or an `error.X`
/// somewhere (unless built by reflection), so without `accesses` a file that declares or writes
/// the name is found. Without `tests`, uses in `test` blocks do not count: the tests of a module
/// other than the root module (the standard library, packages) are not compiled.
pub fn errorUse(r: *Resolver, file: FileId, name: []const u8, accesses: bool, tests: bool) resolve.Error!?u32 {
    if (!(try r.ctx.get(FileIndex.Query, file)).contains(name)) return null;
    var out: std.ArrayList(Reference) = .empty;
    var uncertain: ?Reference = null;
    var ambiguous: ?Reference = null;
    try errorUses(r, file, name, accesses, tests, &out, .{ .scope = &.{}, .uncertain = &uncertain, .ambiguous = &ambiguous });
    var first: ?u32 = if (uncertain) |u| u.start else null;
    for (out.items) |ref| if (first == null or ref.start < first.?) {
        first = ref.start;
    };
    return first;
}

/// Appends the uses of the error named `name` in `file` (see `findErrorReferences`); member
/// accesses only with `accesses`, and uses in `test` blocks only with `tests`
fn errorUses(r: *Resolver, file: FileId, name: []const u8, accesses: bool, tests: bool, out: *std.ArrayList(Reference), opts: Options) resolve.Error!void {
    const tree = try r.itemTree(file);
    var skipped: std.ArrayList(Body.Range) = .empty;
    if (!tests) for (tree.items, 0..) |it, i| if (it.kind == .@"test") if (try r.itemNode(file, @intCast(i))) |n| {
        try skipped.append(r.arena, .{ .start = n.range().start, .end = n.range().end });
    };
    for ((try r.ctx.get(ErrorSets.Query, file)).sets) |set| for (set.members) |m| {
        if (!std.mem.eql(u8, m.name, name) or inRanges(skipped.items, m.start)) continue;
        try out.append(r.arena, .{ .file = file, .start = m.start, .end = m.end, .is_decl = true });
    };
    const text = (try r.ctx.get(database.syntax.SourceText, file)).text;
    for (0..tree.items.len) |i| {
        const item: u32 = @intCast(i);
        if (!try r.mayMention(file, item, name)) continue;
        const base = try r.itemOffset(file, item) orelse continue;
        if (inRanges(skipped.items, base)) continue;
        const body = try r.body(file, item);
        var res: ?*const infer.Result = null;
        for (body.exprs, body.expr_ranges) |e, range| switch (e) {
            .error_value => |n| if (std.mem.eql(u8, n, name)) {
                const end = base + range.end;
                if (lastNameStart(text, end)) |start| try out.append(r.arena, .{ .file = file, .start = start, .end = end });
            },
            .field_access => |fa| if (accesses and fa.field != null and std.mem.eql(u8, fa.field.?, name)) {
                const at: Reference = .{ .file = file, .start = base + range.start, .end = base + range.end };
                switch (try errorSetAccess(r, &res, file, item, fa.lhs, at, opts)) {
                    .hit => if (lastNameStart(text, at.end)) |start| try out.append(r.arena, .{ .file = file, .start = start, .end = at.end }),
                    .miss => {},
                    .unknown => if (opts.uncertain) |slot| if (slot.* == null) {
                        slot.* = at;
                    },
                }
            },
            else => {},
        };
    }
}

fn inRanges(ranges: []const Body.Range, offset: u32) bool {
    for (ranges) |rg| if (rg.start <= offset and offset < rg.end) return true;
    return false;
}

/// Whether the left-hand side `lhs` of a member access in member `item` is an error set type, which
/// makes the member an error name: by the inference of the member, else by its call-site instances
/// (as `Finder.refersTo` decides members)
fn errorSetAccess(r: *Resolver, res: *?*const infer.Result, file: FileId, item: u32, lhs: Body.ExprId, at: Reference, opts: Options) resolve.Error!Target {
    const ip = r.ctx.db.env.ip;
    const owner = try r.ownerKey(file, item);
    const abstract = res.* orelse blk: {
        const x = try r.ctx.get(sema.Infer, .{ .owner = owner, .mode = .full });
        res.* = x;
        break :blk x;
    };
    if (errorSetType(ip, abstract, lhs)) |is| return if (is) .hit else .miss;
    var hit = false;
    var miss = false;
    const all = try seed.allInstances(r, file, item);
    for (all.insts) |inst| {
        const is = errorSetType(ip, try r.ctx.get(sema.Infer, .{ .owner = owner, .mode = .full, .inst = inst }), lhs) orelse continue;
        if (is) hit = true else miss = true;
    }
    if (!all.complete) if (opts.incomplete) |slot| if (slot.* == null) {
        slot.* = at;
    };
    if (hit and miss) if (opts.ambiguous) |a| if (a.* == null) {
        a.* = at;
    };
    if (hit) return .hit;
    return if (miss) .miss else .unknown;
}

/// Whether the value of `e` in the inference result is an error set type; null when it is unknown
/// or abstract
fn errorSetType(ip: *InternPool, res: *const infer.Result, e: Body.ExprId) ?bool {
    const i = @backingInt(e);
    if (i >= res.exprs.len or seed.wanted(ip, res.exprs[i])) return null;
    const t = res.exprs[i].asType() orelse return false;
    return switch (ip.key(t)) {
        .error_set_type, .inferred_error_set => true,
        else => false,
    };
}

fn noteSyntaxError(r: *Resolver, slot: ?*?FileId, file: FileId) resolve.Error!void {
    const s = slot orelse return;
    if (s.* == null and (try r.ctx.get(database.syntax.ParseFile, file)).errors.len != 0) s.* = file;
}

/// Project files in the module graph (excluding the standard library)
pub fn projectFiles(r: *Resolver) resolve.Error![]const FileId {
    const graph = try r.ctx.get(database.ModuleGraph.Input, {}) orelse return &.{};
    var out: std.ArrayList(FileId) = .empty;
    for (graph.files) |f| if (f.module != database.ModuleGraph.std_module) try out.append(r.arena, f.file);
    return out.items;
}

/// Files whose references are searched: the project files in the module graph and the user's
/// source files under the workspace roots (see `inputs.WorkspaceFiles`), which include files in
/// no build graph (single-file mode, build scripts, examples)
pub fn searchFiles(r: *Resolver) resolve.Error![]const FileId {
    var set: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty;
    for (try projectFiles(r)) |f| try set.put(r.arena, f, {});
    for (try r.ctx.get(database.inputs.WorkspaceFiles, {})) |f| try set.put(r.arena, f, {});
    return set.keys();
}

/// `files` ordered by path: an order that follows the source tree, not the order in which the
/// files were interned (which depends on the order the client opened them)
pub fn byPath(r: *Resolver, files: []const FileId) resolve.Error![]const FileId {
    const out = try r.arena.dupe(FileId, files);
    std.mem.sort(FileId, out, r.ctx.db.env.vfs, struct {
        fn lt(vfs: *Vfs, a: FileId, b: FileId) bool {
            return std.mem.lessThan(u8, vfs.path(a), vfs.path(b));
        }
    }.lt);
    return out;
}

/// Candidate files that may reference definitions in a file whose importers (see `importers`) are
/// `reach`: the files in `scope` reachable from `reach` through `@import` chains (through any
/// files), and `reach` itself. Every compilation that contains the definition has a root that
/// reaches it, so a file that no importer reaches is never compiled together with the definition.
/// Generic code in the reachable files can access the members of the file containing the
/// definition without importing it: through the value of an `anytype` parameter (`x.foo()`, where
/// the type of `x` in an instance comes from that file) or a comptime type parameter (`M.foo`)
pub fn candidateFiles(r: *Resolver, reach: []const FileId, scope: []const FileId) resolve.Error![]const FileId {
    var keep: std.AutoHashMapUnmanaged(FileId, void) = .empty;
    for (scope) |f| try keep.put(r.arena, f, {});
    for (reach) |f| try keep.put(r.arena, f, {});
    var out: std.ArrayList(FileId) = .empty;
    for (try reachable(r, reach)) |f| if (keep.contains(f)) try out.append(r.arena, f);
    return out.items;
}

/// Files reachable from `from` through `@import` chains (through any files, including the
/// standard library and packages), and `from` itself
pub fn reachable(r: *Resolver, from: []const FileId) resolve.Error![]const FileId {
    var seen: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty;
    for (from) |f| try seen.put(r.arena, f, {});
    var i: usize = 0;
    while (i < seen.count()) : (i += 1) {
        const f = seen.keys()[i];
        const index = try r.ctx.get(FileIndex.Query, f);
        // Every module the file belongs to may import a different file under a name
        for (index.imports) |s| for (try r.resolveImportTargets(f, s)) |to| try seen.put(r.arena, to, {});
    }
    return seen.keys();
}

/// Files in `scope` that can reach `target` through an `@import` chain (including `target`
/// itself), in any of the modules each file belongs to. The chain may pass through files outside
/// the scope (project → `std.zig` → `mem.zig`, or a closed file that is not in the scope): all
/// files reachable from the files in scope are collected by following imports, and reverse edges
/// are built over them; files outside the scope other than `target` are not in the result
pub fn importers(r: *Resolver, target: FileId, scope: []const FileId) resolve.Error![]const FileId {
    // Files in scope come first (indices below `scope_len`), followed by the reachable files
    // outside the scope
    var nodes: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty;
    for (scope) |f| try nodes.put(r.arena, f, {});
    const scope_len = nodes.count();
    // Reverse edges: imported file → the files importing it
    var reverse: std.AutoHashMapUnmanaged(FileId, std.ArrayList(FileId)) = .empty;
    var n: usize = 0;
    while (n < nodes.count()) : (n += 1) {
        const f = nodes.keys()[n];
        const index = try r.ctx.get(FileIndex.Query, f);
        // Every module the file belongs to may import a different file under a name
        for (index.imports) |s| for (try r.resolveImportTargets(f, s)) |to| {
            const gop = try reverse.getOrPut(r.arena, to);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(r.arena, f);
            try nodes.put(r.arena, to, {});
        };
    }
    var seen: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty;
    try seen.put(r.arena, target, {});
    var i: usize = 0;
    while (i < seen.count()) : (i += 1) {
        const f = seen.keys()[i];
        const from = reverse.get(f) orelse continue;
        for (from.items) |x| try seen.put(r.arena, x, {});
    }
    var out: std.ArrayList(FileId) = .empty;
    for (seen.keys()) |f| {
        if (f == target or nodes.getIndex(f).? < scope_len) try out.append(r.arena, f);
    }
    return out.items;
}

/// Whether `from` can reach `target` through an `@import` chain (through any files)
pub fn reaches(r: *Resolver, from: FileId, target: FileId) resolve.Error!bool {
    var seen: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty;
    try seen.put(r.arena, from, {});
    var i: usize = 0;
    while (i < seen.count()) : (i += 1) {
        const f = seen.keys()[i];
        const index = try r.ctx.get(FileIndex.Query, f);
        for (index.imports) |s| {
            const to = try r.resolveImport(f, s) orelse continue;
            if (to == target) return true;
            try seen.put(r.arena, to, {});
        }
    }
    return false;
}

/// The reverse import closure over the searched files (see `searchFiles`) is shared between the
/// seed lookups of all members; the file indexes and the module configuration are still the
/// actual dependencies. Files at the same import distance from the target come in path order
/// (see `byPath`), so the first call site found does not depend on the interning order.
pub const ProjectImporters = struct {
    pub const kind: @import("../db/engine.zig").Kind = .derived;
    pub const Key = FileId;
    pub const Value = []const FileId;

    pub fn compute(ctx: *database.Db.Ctx, target: Key) @import("../db/engine.zig").Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        return ctx.db.gpa.dupe(FileId, try importers(&r, target, try byPath(&r, try searchFiles(&r))));
    }

    pub fn eql(a: Value, b: Value) bool {
        return std.mem.eql(FileId, a, b);
    }

    pub fn deinit(v: *Value, gpa: std.mem.Allocator) void {
        gpa.free(v.*);
    }
};

const Finder = struct {
    r: *Resolver,
    def: Def,
    /// `def` is a field: a field name in an initializer (`.{ .x = v }`) can only refer to a field
    /// and is never a reference to another definition
    is_field: bool,
    name: []const u8,
    out: *std.ArrayList(Reference),
    ambiguous: ?*?Reference,
    uncertain: ?*?Reference,
    incomplete: ?*?Reference,
    zon_import: ?*?Reference,
    /// Files that can reach the file containing the definition through an `@import` chain (`.item`
    /// definitions). In other files, only code in generic functions may reference the definition
    importing: std.AutoHashMapUnmanaged(FileId, void) = .empty,
    /// Call-site instances of the most recent member (`instances`)
    cached: ?struct { file: FileId, item: u32, list: []const InternPool.Index, complete: bool } = null,

    /// Checks member `item` in file `file`
    fn item(f: *Finder, file: FileId, item_index: u32) resolve.Error!void {
        const r = f.r;
        // The name of a decltest is not in the Body: the identifier in `test helper` is a
        // reference to helper
        if (try r.itemNode(file, item_index)) |node| if (node.kind() == .test_decl) if (node.childToken(.identifier)) |t| {
            const name = try ast.identNameAlloc(r.arena, t.text);
            if (std.mem.eql(u8, name, f.name)) {
                if (try r.resolveContainerName(file, item_index, name)) |def| if (deepEql(def, f.def)) {
                    try f.add(file, t.offset, t.offset + @as(u32, @intCast(t.text.len)));
                };
            }
        };
        if (!try r.mayMention(file, item_index, f.name)) return;
        const body = try r.body(file, item_index);
        if (!mentions(body, f.name)) return;
        // In a file that does not import the file containing the definition, code outside generic
        // functions can neither reference the definition by name nor obtain its containing type.
        // The root expression of a `.zon` file is an exception when it has a result type, which
        // comes from the files that import it (see `sema.ZonImports`); without one, nothing in it
        // refers to a declaration, unless the sites give result types that cannot be named
        if (f.def == .item and !f.importing.contains(file)) {
            if ((try r.itemTree(file)).items[item_index].kind == .zon) {
                const imports = try r.ctx.get(database.sema.ZonImports, file);
                if (imports.result_type == null) {
                    if (imports.unresolved and f.is_field) try f.zonFieldsUnderSites(file, item_index, body);
                    return;
                }
            } else if (try seed.genericRoot(r, file, item_index) == null) return;
        }
        const base = try r.itemOffset(file, item_index) orelse return;
        var res: ?*const infer.Result = null;
        var written: ?[]const bool = null;
        for (body.exprs, 0..) |e, i| {
            const id: Body.ExprId = @fromBackingInt(@as(u32, @intCast(i)));
            const range = body.expr_ranges[i];
            switch (e) {
                // A bare primitive name (`f32`, `null`) is the primitive even where a declaration
                // written `@"f32"` is in scope
                .name_ref => |n| if (std.mem.eql(u8, n, f.name) and !body.nameRefIsBuiltin(id)) {
                    const d = try r.resolveName(file, item_index, body, body.expr_scopes[i], n) orelse continue;
                    if (deepEql(d, f.def)) try f.addAccess(file, base + range.start, base + range.end, try isWritten(r, &written, body, id));
                },
                .field_access => |fa| if (fa.field != null and std.mem.eql(u8, fa.field.?, f.name)) {
                    const at: Reference = .{ .file = file, .start = base + range.start, .end = base + range.end };
                    // Namespace declarations are compared directly; other members (field tags of
                    // tagged unions, declarations in other targets' branches) come from inference.
                    // Either way, a namespace chosen per build configuration has the member of
                    // each choice
                    const ns_def = if (try r.evalNamespace(file, item_index, body, fa.lhs)) |ns| try r.memberDef(ns, f.name) else null;
                    var current: Target = if (ns_def) |d| try f.matches(file, d, at) else try f.refersTo(&res, file, item_index, .{ .e = id }, at);
                    if (current == .unknown) current = try f.importedMember(file, item_index, body, fa.lhs, at);
                    if (current != .hit and f.is_field and try f.zonFieldIsDef(file, item_index, body, try f.inferred(&res, file, item_index), fa.lhs, range.start)) current = .hit;
                    const target = if (current == .unknown) current else try f.configurations(file, item_index, body, fa.lhs, current == .hit, at);
                    switch (target) {
                        .hit => try f.addLastToken(file, base + range.end, try isWritten(r, &written, body, id)),
                        .miss => {},
                        .unknown => try f.noteUncertain(&res, file, item_index, fa.lhs, at),
                    }
                },
                .enum_literal => |n| if (std.mem.eql(u8, n, f.name)) {
                    const at: Reference = .{ .file = file, .start = base + range.start, .end = base + range.end };
                    switch (try f.refersTo(&res, file, item_index, .{ .e = id }, at)) {
                        .hit => try f.addLastToken(file, base + range.end, false),
                        .miss => {},
                        .unknown => try f.noteUncertainLiteral(&res, file, item_index, id, at),
                    }
                },
                .init => |x| if (f.is_field) for (x.fields, 0..) |fi, k| {
                    const n = fi.name orelse continue;
                    if (!std.mem.eql(u8, n, f.name)) continue;
                    const at: Reference = .{ .file = file, .start = base + fi.name_range.start, .end = base + fi.name_range.end };
                    var current = try f.refersTo(&res, file, item_index, .{ .e = id, .field = k }, at);
                    if (current != .hit and try f.zonFieldIsDef(file, item_index, body, try f.inferred(&res, file, item_index), id, range.start)) current = .hit;
                    switch (current) {
                        .hit => try f.add(file, at.start, at.end),
                        .miss => {},
                        .unknown => try f.noteUncertainLiteral(&res, file, item_index, id, at),
                    }
                },
                else => {},
            }
        }
    }

    /// Adds the uses in a member of the field named `f.name` of the `.zon` file literal `literal`
    fn zonFieldUses(f: *Finder, file: FileId, item_index: u32, literal: InternPool.ZonLiteral) resolve.Error!void {
        const r = f.r;
        if (!try r.mayMention(file, item_index, f.name)) return;
        const body = try r.body(file, item_index);
        if (!mentions(body, f.name)) return;
        const base = try r.itemOffset(file, item_index) orelse return;
        var res: ?*const infer.Result = null;
        var written: ?[]const bool = null;
        for (body.exprs, 0..) |e, i| {
            const id: Body.ExprId = @fromBackingInt(@as(u32, @intCast(i)));
            const range = body.expr_ranges[i];
            switch (e) {
                .field_access => |fa| if (fa.field != null and std.mem.eql(u8, fa.field.?, f.name)) {
                    const at: Reference = .{ .file = file, .start = base + range.start, .end = base + range.end };
                    const literals = try zonLiteralsOf(r, file, item_index, body, try f.inferred(&res, file, item_index), fa.lhs, range.start);
                    switch (f.literalMatch(literals, literal, at)) {
                        .hit => try f.addLastToken(file, base + range.end, try isWritten(r, &written, body, id)),
                        .miss => {},
                        .unknown => try f.noteUncertain(&res, file, item_index, fa.lhs, at),
                    }
                },
                .init => |x| for (x.fields) |fi| {
                    const n = fi.name orelse continue;
                    if (!std.mem.eql(u8, n, f.name)) continue;
                    const at: Reference = .{ .file = file, .start = base + fi.name_range.start, .end = base + fi.name_range.end };
                    const literals = try zonLiteralsOf(r, file, item_index, body, try f.inferred(&res, file, item_index), id, range.start);
                    switch (f.literalMatch(literals, literal, at)) {
                        .hit => try f.add(file, at.start, at.end),
                        .miss => {},
                        .unknown => try f.noteUncertainLiteral(&res, file, item_index, id, at),
                    }
                },
                else => {},
            }
        }
    }

    /// Whether `literals`, the literals a use may refer to, include `literal`; when they also include
    /// others, the use is recorded as ambiguous (`at`)
    fn literalMatch(f: *Finder, literals: []const InternPool.ZonLiteral, literal: InternPool.ZonLiteral, at: Reference) Target {
        if (literals.len == 0) return .unknown;
        var hit = false;
        var miss = false;
        for (literals) |l| {
            if (l.file == literal.file and std.mem.eql(u32, l.path, literal.path)) hit = true else miss = true;
        }
        if (hit and miss) if (f.ambiguous) |a| if (a.* == null) {
            a.* = at;
        };
        return if (hit) .hit else .miss;
    }

    /// Whether the field named like `def` of the `.zon` file literal that `e` has the type of is
    /// `def`, which it is when the file has a result type: the value is used through its own
    /// anonymous type at import sites without a result type, and renaming must follow
    fn zonFieldIsDef(f: *Finder, file: FileId, item_index: u32, body: *const Body, res: *const infer.Result, e: Body.ExprId, rel: u32) resolve.Error!bool {
        for (try zonLiteralsOf(f.r, file, item_index, body, res, e, rel)) |literal| {
            const site = try zonFieldSite(f.r, .{ .literal = literal, .name = f.name }) orelse continue;
            if (try typedZonField(f.r, site)) |d| if (deepEql(d, f.def)) return true;
            if ((try f.r.ctx.get(database.sema.ZonImports, site.file)).unresolved) {
                const owner = try f.r.ownerKey(site.file, site.item);
                if (try f.underSites(owner, (try zonSiteTypes(f.r, site.file)).types, .{ .e = site.init, .field = site.index })) return true;
            }
        }
        return false;
    }

    /// The uses of `def` in the root expression of a `.zon` file whose import sites give several
    /// result types: the names that refer to it under one of those types. Each is also recorded in
    /// `zon_import`, since renaming it would break the sites of the other types, and so is any name
    /// like it when a site's type could not be determined.
    fn zonFieldsUnderSites(f: *Finder, file: FileId, item_index: u32, body: *const Body) resolve.Error!void {
        const r = f.r;
        const base = try r.itemOffset(file, item_index) orelse return;
        const sites = try zonSiteTypes(r, file);
        const owner = try r.ownerKey(file, item_index);
        for (body.exprs, 0..) |e, i| {
            const id: Body.ExprId = @fromBackingInt(@as(u32, @intCast(i)));
            switch (e) {
                .enum_literal => |n| if (std.mem.eql(u8, n, f.name)) {
                    const range = body.expr_ranges[i];
                    const at: Reference = .{ .file = file, .start = base + range.start, .end = base + range.end };
                    if (try f.underSites(owner, sites.types, .{ .e = id })) {
                        try f.addLastToken(file, at.end, false);
                        f.noteZonImport(at);
                    } else if (!sites.complete) f.noteZonImport(at);
                },
                .init => |x| for (x.fields, 0..) |fi, k| {
                    const n = fi.name orelse continue;
                    if (!std.mem.eql(u8, n, f.name)) continue;
                    const at: Reference = .{ .file = file, .start = base + fi.name_range.start, .end = base + fi.name_range.end };
                    if (try f.underSites(owner, sites.types, .{ .e = id, .field = k })) {
                        try f.add(file, at.start, at.end);
                        f.noteZonImport(at);
                    } else if (!sites.complete) f.noteZonImport(at);
                },
                else => {},
            }
        }
    }

    /// Whether `l` in the root expression `owner` of a `.zon` file is `def` under one of `types`
    fn underSites(f: *Finder, owner: hir.OwnerKey, types: []const InternPool.Index, l: Lookup) resolve.Error!bool {
        for (types) |ty| {
            const res = try f.r.ctx.get(sema.Infer, .{ .owner = owner, .mode = .full, .zon_type = ty });
            const m = l.member(res) orelse continue;
            if (try keyDef(f.r, m)) |d| if (deepEql(d, f.def)) return true;
        }
        return false;
    }

    fn noteZonImport(f: *Finder, at: Reference) void {
        if (f.zon_import) |slot| if (slot.* == null) {
            slot.* = at;
        };
    }

    fn inferred(f: *Finder, res: *?*const infer.Result, file: FileId, item_index: u32) resolve.Error!*const infer.Result {
        if (res.*) |x| return x;
        const x = try f.r.ctx.get(sema.Infer, .{ .owner = try f.r.ownerKey(file, item_index), .mode = .full });
        res.* = x;
        return x;
    }

    /// Whether the member named like `def` of the namespace `lhs` is `def` under some build
    /// configuration (`here`: under the current one). A namespace that a declaration chooses per
    /// configuration (`const Impl = if (builtin.os.tag == .windows) @import("win.zig") else
    /// @import("posix.zig")`) has the member of each choice: the access refers to `def` if any of
    /// them is `def`, and is recorded as ambiguous when others are not (renaming one would break
    /// the build for the other configurations)
    fn configurations(f: *Finder, file: FileId, item_index: u32, body: *const Body, lhs: Body.ExprId, here: bool, at: Reference) resolve.Error!Target {
        if (here and f.ambiguous == null) return .hit;
        var hit = here;
        var miss = !here;
        for (try f.alternatives(file, item_index, body, lhs)) |t| {
            const ns = try sema.namespaceOfType(f.r, t) orelse continue;
            const d = try f.r.memberDef(ns, f.name) orelse continue;
            if (deepEql(d, f.def)) hit = true else miss = true;
        }
        if (hit and miss) if (f.ambiguous) |a| if (a.* == null) {
            a.* = at;
        };
        return if (hit) .hit else .miss;
    }

    /// The containers the namespace `lhs` may be under the build configurations that the
    /// declaration it names chooses between (see `infer.declAlternatives`)
    fn alternatives(f: *Finder, file: FileId, item_index: u32, body: *const Body, lhs: Body.ExprId) resolve.Error![]const InternPool.Index {
        const r = f.r;
        const decl: Def = switch (body.expr(lhs)) {
            .name_ref => |n| try r.resolveName(file, item_index, body, body.expr_scopes[@backingInt(lhs)], n) orelse return &.{},
            .field_access => |fa| blk: {
                const ns = try r.evalNamespace(file, item_index, body, fa.lhs) orelse return &.{};
                break :blk try r.memberDef(ns, fa.field orelse return &.{}) orelse return &.{};
            },
            else => return &.{},
        };
        if (decl != .item) return &.{};
        return infer.declAlternatives(r, r.arena, decl);
    }

    /// Whether the member `f.name` of `lhs` is `def` through an import that only navigation
    /// resolves (see `Resolver.unresolvedImportMembers`): `unknown` when there is no such import;
    /// ambiguous (`at`) when the targets have different members
    fn importedMember(f: *Finder, file: FileId, item_index: u32, body: *const Body, lhs: Body.ExprId, at: Reference) resolve.Error!Target {
        const defs = try f.r.unresolvedImportMembers(file, item_index, body, lhs, f.name);
        if (defs.len == 0) return .unknown;
        var hit = false;
        var miss = false;
        for (defs) |d| if (deepEql(d, f.def)) {
            hit = true;
        } else {
            miss = true;
        };
        if (hit and miss) if (f.ambiguous) |a| if (a.* == null) {
            a.* = at;
        };
        return if (hit) .hit else .miss;
    }

    /// Whether `d`, which a use in `file` resolves to, is `def` in some module of `file`: `def`
    /// itself, or its counterpart in another module that `file` imports under the same name (see
    /// `Resolver.moduleAlternatives`). When it refers to `def` in some modules and to other
    /// definitions in others, it is recorded as ambiguous (`at`): renaming it would break the
    /// build of those modules.
    fn matches(f: *Finder, file: FileId, d: Def, at: Reference) resolve.Error!Target {
        var hit = deepEql(d, f.def);
        var miss = !hit;
        for (try f.r.moduleAlternatives(file, d)) |alt| {
            if (deepEql(alt, f.def)) hit = true else miss = true;
        }
        if (hit and miss) if (f.ambiguous) |a| if (a.* == null) {
            a.* = at;
        };
        return if (hit) .hit else .miss;
    }

    /// Whether the member recorded in the inference result (field, method, decl literal, enum
    /// member, initializer field) is `def`.
    /// When abstract inference inside a generic function body cannot determine it, all call-site
    /// instances are checked: it is a reference if any instance refers to `def`; if other instances
    /// refer to other definitions as well, it is recorded as ambiguous (`at`). In a loop or an
    /// `inline` prong inferred per iteration (a heterogeneous `inline for`), each iteration is
    /// checked the same way. The result is `unknown` when none of them determines the member.
    fn refersTo(f: *Finder, res: *?*const infer.Result, file: FileId, item_index: u32, l: Lookup, at: Reference) resolve.Error!Target {
        const abstract = try f.inferred(res, file, item_index);
        if (l.member(abstract)) |m| {
            const d = try keyDef(f.r, m) orelse return .miss;
            return f.matches(file, d, at);
        }
        const owner = try f.r.ownerKey(file, item_index);
        var hit = false;
        var miss = false;
        const all = try f.instances(file, item_index);
        for (all.list) |inst| {
            const m = l.member(try f.r.ctx.get(sema.Infer, .{ .owner = owner, .mode = .full, .inst = inst })) orelse continue;
            const d = try keyDef(f.r, m) orelse continue;
            if (deepEql(d, f.def)) hit = true else miss = true;
        }
        if (!hit and !miss) {
            const body = try f.r.body(file, item_index);
            const rel = body.range(l.e).start;
            try f.iterationMembers(owner, body, abstract, null, rel, l, &hit, &miss);
            for (all.list) |inst| {
                const inst_res = try f.r.ctx.get(sema.Infer, .{ .owner = owner, .mode = .full, .inst = inst });
                try f.iterationMembers(owner, body, inst_res, inst, rel, l, &hit, &miss);
            }
        }
        if (!all.complete) if (f.incomplete) |slot| if (slot.* == null) {
            slot.* = at;
        };
        if (hit and miss) if (f.ambiguous) |a| if (a.* == null) {
            a.* = at;
        };
        if (hit) return .hit;
        return if (miss) .miss else .unknown;
    }

    /// Compares the member of `l` in each combination of iterations of the per-iteration regions
    /// containing `rel` (see `seed.iterationResults`) with `def`
    fn iterationMembers(f: *Finder, owner: hir.OwnerKey, body: *const Body, res: *const infer.Result, inst: ?InternPool.Index, rel: u32, l: Lookup, hit: *bool, miss: *bool) resolve.Error!void {
        if (res.exprs.len != body.exprs.len) return;
        for (try seed.iterationResults(f.r, owner, body, res, inst, rel)) |iteration| {
            const m = l.member(iteration) orelse continue;
            const d = try keyDef(f.r, m) orelse continue;
            if (deepEql(d, f.def)) hit.* = true else miss.* = true;
        }
    }

    /// A field access whose member cannot be determined: when the type of the left-hand side is
    /// unknown or abstract, it is recorded as uncertain (when a concrete type has no such member,
    /// it is not a reference, e.g. `len` of a slice)
    fn noteUncertain(f: *Finder, res: *?*const infer.Result, file: FileId, item_index: u32, e: Body.ExprId, at: Reference) resolve.Error!void {
        const slot = f.uncertain orelse return;
        if (slot.* != null) return;
        const exprs = (try f.inferred(res, file, item_index)).exprs;
        const i = @backingInt(e);
        if (i >= exprs.len or seed.wanted(f.r.ctx.db.env.ip, exprs[i])) slot.* = at;
    }

    /// A literal whose member cannot be determined (an enum literal, including the callee of a decl
    /// literal call, or a field of an anonymous initializer): its members come from its result type,
    /// and when that is unknown or abstract it is recorded as uncertain. The literal itself keeps
    /// its own type when it cannot be coerced (`@EnumLiteral()`, an anonymous struct), so the
    /// result type is read from the inference result (`literal_expected`, `unknown_expected`)
    fn noteUncertainLiteral(f: *Finder, res: *?*const infer.Result, file: FileId, item_index: u32, e: Body.ExprId, at: Reference) resolve.Error!void {
        const slot = f.uncertain orelse return;
        if (slot.* != null) return;
        const result = try f.inferred(res, file, item_index);
        const ip = f.r.ctx.db.env.ip;
        const i = @backingInt(e);
        if (i >= result.exprs.len or seed.wanted(ip, result.exprs[i]) or std.mem.indexOfScalar(Body.ExprId, result.unknown_expected, e) != null) {
            slot.* = at;
            return;
        }
        for (result.literal_expected) |x| if (x.expr == e and seed.wanted(ip, .{ .ty = x.ty })) {
            slot.* = at;
            return;
        };
    }

    fn instances(f: *Finder, file: FileId, item_index: u32) resolve.Error!struct { list: []const InternPool.Index, complete: bool } {
        if (f.cached) |c| if (c.file == file and c.item == item_index) return .{ .list = c.list, .complete = c.complete };
        const all = try seed.allInstances(f.r, file, item_index);
        f.cached = .{ .file = file, .item = item_index, .list = all.insts, .complete = all.complete };
        return .{ .list = all.insts, .complete = all.complete };
    }

    fn add(f: *Finder, file: FileId, start: u32, end: u32) resolve.Error!void {
        try f.addAccess(file, start, end, false);
    }

    fn addAccess(f: *Finder, file: FileId, start: u32, end: u32, write: bool) resolve.Error!void {
        try f.out.append(f.r.arena, .{ .file = file, .start = start, .end = end, .is_write = write });
    }

    /// Uses the name at the end of the expression (field name, name of an enum literal) as the
    /// reference position. Scans backward over the source text directly instead of relying on the
    /// parse result (which may have been evicted).
    fn addLastToken(f: *Finder, file: FileId, end: u32, write: bool) resolve.Error!void {
        const text = (try f.r.ctx.get(database.syntax.SourceText, file)).text;
        const start = lastNameStart(text, end) orelse return;
        try f.addAccess(file, start, end, write);
    }
};

/// Whether expression `e` of the body is written to (see `Reference.is_write`); `cache` keeps the
/// targets of the body once they are collected
fn isWritten(r: *Resolver, cache: *?[]const bool, body: *const Body, e: Body.ExprId) resolve.Error!bool {
    const targets = cache.* orelse blk: {
        const out = try r.arena.alloc(bool, body.exprs.len);
        @memset(out, false);
        for (body.exprs) |x| switch (x) {
            .assign => |a| out[@backingInt(a.lhs)] = true,
            .block => |blk| for (blk.stmts) |s| switch (s.kind) {
                .destructure => |d| for (d.targets) |t| switch (t) {
                    .expr => |target| out[@backingInt(target)] = true,
                    .binding => {},
                },
                else => {},
            },
            else => {},
        };
        cache.* = out;
        break :blk out;
    };
    return targets[@backingInt(e)];
}

/// Relation between the target of a member access and the definition being searched for
const Target = enum { hit, miss, unknown };

/// A member in the inference result: the member accessed by expression `e`, or the `field`-th
/// field of initializer expression `e`
const Lookup = struct {
    e: Body.ExprId,
    field: ?usize = null,

    fn member(l: Lookup, res: *const infer.Result) ?hir.OwnerKey {
        if (l.field) |k| {
            for (res.field_refs) |ref| if (ref.init == l.e and ref.index == k) return ref.member;
            return null;
        }
        const i = @backingInt(l.e);
        return if (i < res.members.len) res.members[i] else null;
    }
};

/// Whether the name `name` occurs in the Body (name reference, field access, enum literal,
/// initializer field)
pub fn mentions(body: *const Body, name: []const u8) bool {
    for (body.exprs) |e| switch (e) {
        .name_ref => |n| if (std.mem.eql(u8, n, name)) return true,
        .field_access => |fa| if (fa.field) |n| if (std.mem.eql(u8, n, name)) return true,
        .enum_literal => |n| if (std.mem.eql(u8, n, name)) return true,
        .init => |x| for (x.fields) |fi| if (fi.name) |n| if (std.mem.eql(u8, n, name)) return true,
        else => {},
    };
    return false;
}

/// Start of the name (identifier or `@"..."`) that ends at `end`
fn lastNameStart(text: []const u8, end: u32) ?u32 {
    if (end == 0 or end > text.len) return null;
    if (text[end - 1] == '"') {
        // There may be escaped quotes inside: scan forward from each `@"` on the same line by the
        // rules of string literals, and take the one that ends exactly at `end`
        const line_start = if (std.mem.lastIndexOfScalar(u8, text[0 .. end - 1], '\n')) |i| i + 1 else 0;
        var q = end - 1;
        while (q > line_start + 1) {
            q -= 1;
            if (text[q] == '"' and text[q - 1] == '@' and quotedEnd(text, q) == end) return @intCast(q - 1);
        }
        return null;
    }
    var i = end;
    while (i > 0 and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_')) i -= 1;
    return if (i == end) null else i;
}

/// End (just past the closing quote) of the string literal starting at `q` (the opening quote)
fn quotedEnd(text: []const u8, q: usize) ?usize {
    var i = q + 1;
    while (i < text.len) : (i += 1) switch (text[i]) {
        '\\' => i += 1,
        '"' => return i + 1,
        '\n' => return null,
        else => {},
    };
    return null;
}

test lastNameStart {
    try std.testing.expectEqual(4, lastNameStart("a.b.cde", 7));
    try std.testing.expectEqual(2, lastNameStart("x.@\"a b\"", 8));
    try std.testing.expectEqual(null, lastNameStart("a.", 2));
    try std.testing.expectEqual(2, lastNameStart("s.@\"a\\\"b\"", 9));
    try std.testing.expectEqual(2, lastNameStart("s.@\"a\\\\\"", 8));
}

fn keyDef(r: *Resolver, key: hir.OwnerKey) resolve.Error!?Def {
    const tree = try r.itemTree(key.file);
    for (tree.items, 0..) |it, i| if (it.ast_id == key.item) return .{ .item = .{ .file = key.file, .item = @intCast(i) } };
    return null;
}

test {
    _ = @import("search_test.zig");
}
