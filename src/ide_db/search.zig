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
//! when that fails.

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
const FileId = @import("../base/Vfs.zig").FileId;
const deepEql = @import("../util/deep_eql.zig").deepEql;
const seed = @import("seed.zig");
const InternPool = @import("../sema/InternPool.zig");

pub const Reference = struct {
    file: FileId,
    start: u32,
    end: u32,
    /// Name at the definition site
    is_decl: bool = false,
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
    /// When not null, records the first ambiguous reference: a member access in a generic function
    /// body that refers to `def` under some call-site instances and to other definitions under
    /// others (renaming would break the other instances, so it should be refused)
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
};

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
    var finder: Finder = .{ .r = r, .def = def, .is_field = is_field, .name = name, .out = &out, .ambiguous = opts.ambiguous, .uncertain = opts.uncertain, .incomplete = opts.incomplete };
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

    std.mem.sort(Reference, out.items, {}, struct {
        fn lt(_: void, a: Reference, b: Reference) bool {
            if (a.file != b.file) return @backingInt(a.file) < @backingInt(b.file);
            return a.start < b.start;
        }
    }.lt);
    // The definition site may also show up as an expression (e.g. several resolution paths at the
    // same position): deduplicate
    var n: usize = 0;
    for (out.items) |ref| {
        if (n > 0 and out.items[n - 1].file == ref.file and out.items[n - 1].start == ref.start) {
            out.items[n - 1].is_decl = out.items[n - 1].is_decl or ref.is_decl;
            continue;
        }
        out.items[n] = ref;
        n += 1;
    }
    return out.items[0..n];
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
    var seen: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty;
    for (reach) |f| {
        try keep.put(r.arena, f, {});
        try seen.put(r.arena, f, {});
    }
    var i: usize = 0;
    while (i < seen.count()) : (i += 1) {
        const f = seen.keys()[i];
        const index = try r.ctx.get(FileIndex.Query, f);
        // Every module the file belongs to may import a different file under a name
        for (index.imports) |s| for (try r.resolveImportTargets(f, s)) |to| try seen.put(r.arena, to, {});
    }
    var out: std.ArrayList(FileId) = .empty;
    for (seen.keys()) |f| if (keep.contains(f)) try out.append(r.arena, f);
    return out.items;
}

/// Files in `scope` that can reach `target` through an `@import` chain (including `target`
/// itself). The chain may pass through files outside the scope (project → `std.zig` → `mem.zig`,
/// or a closed file that is not in the scope): all files reachable from the files in scope are
/// collected by following imports, and reverse edges are built over them; files outside the scope
/// other than `target` are not in the result
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
        for (index.imports) |s| {
            const to = try r.resolveImport(f, s) orelse continue;
            const gop = try reverse.getOrPut(r.arena, to);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(r.arena, f);
            try nodes.put(r.arena, to, {});
        }
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
/// actual dependencies.
pub const ProjectImporters = struct {
    pub const kind: @import("../db/engine.zig").Kind = .derived;
    pub const Key = FileId;
    pub const Value = []const FileId;

    pub fn compute(ctx: *database.Db.Ctx, target: Key) @import("../db/engine.zig").Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        return ctx.db.gpa.dupe(FileId, try importers(&r, target, try searchFiles(&r)));
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
        // comes from the files that import it (see `sema.ZonResultType`); without one, nothing in
        // it refers to a declaration
        if (f.def == .item and !f.importing.contains(file)) {
            if ((try r.itemTree(file)).items[item_index].kind == .zon) {
                if (try r.ctx.get(database.sema.ZonResultType, file) == null) return;
            } else if (try seed.genericRoot(r, file, item_index) == null) return;
        }
        const base = try r.itemOffset(file, item_index) orelse return;
        var res: ?*const infer.Result = null;
        for (body.exprs, 0..) |e, i| {
            const id: Body.ExprId = @fromBackingInt(@as(u32, @intCast(i)));
            const range = body.expr_ranges[i];
            switch (e) {
                .name_ref => |n| if (std.mem.eql(u8, n, f.name)) {
                    const d = try r.resolveName(file, item_index, body, body.expr_scopes[i], n) orelse continue;
                    if (deepEql(d, f.def)) try f.add(file, base + range.start, base + range.end);
                },
                .field_access => |fa| if (fa.field != null and std.mem.eql(u8, fa.field.?, f.name)) {
                    const at: Reference = .{ .file = file, .start = base + range.start, .end = base + range.end };
                    // Namespace declarations are compared directly; other members (field tags of
                    // tagged unions, declarations in other targets' branches) come from inference
                    const ns_def = if (try r.evalNamespace(file, item_index, body, fa.lhs)) |ns| try r.memberDef(ns, f.name) else null;
                    const target: Target = if (ns_def) |d| (if (deepEql(d, f.def)) .hit else .miss) else try f.refersTo(&res, file, item_index, .{ .e = id }, at);
                    switch (target) {
                        .hit => try f.addLastToken(file, base + range.end),
                        .miss => {},
                        .unknown => try f.noteUncertain(&res, file, item_index, fa.lhs, at),
                    }
                },
                .enum_literal => |n| if (std.mem.eql(u8, n, f.name)) {
                    const at: Reference = .{ .file = file, .start = base + range.start, .end = base + range.end };
                    switch (try f.refersTo(&res, file, item_index, .{ .e = id }, at)) {
                        .hit => try f.addLastToken(file, base + range.end),
                        .miss => {},
                        .unknown => try f.noteUncertain(&res, file, item_index, id, at),
                    }
                },
                .init => |x| if (f.is_field) for (x.fields, 0..) |fi, k| {
                    const n = fi.name orelse continue;
                    if (!std.mem.eql(u8, n, f.name)) continue;
                    const at: Reference = .{ .file = file, .start = base + fi.name_range.start, .end = base + fi.name_range.end };
                    switch (try f.refersTo(&res, file, item_index, .{ .e = id, .field = k }, at)) {
                        .hit => try f.add(file, at.start, at.end),
                        .miss => {},
                        .unknown => try f.noteUncertain(&res, file, item_index, id, at),
                    }
                },
                else => {},
            }
        }
    }

    fn inferred(f: *Finder, res: *?*const infer.Result, file: FileId, item_index: u32) resolve.Error!*const infer.Result {
        if (res.*) |x| return x;
        const x = try f.r.ctx.get(sema.Infer, .{ .owner = try f.r.ownerKey(file, item_index), .mode = .full });
        res.* = x;
        return x;
    }

    /// Whether the member recorded in the inference result (field, method, decl literal, enum
    /// member, initializer field) is `def`.
    /// When abstract inference inside a generic function body cannot determine it, all call-site
    /// instances are checked: it is a reference if any instance refers to `def`; if other instances
    /// refer to other definitions as well, it is recorded as ambiguous (`at`). The result
    /// is `unknown` when neither abstract inference nor any instance determines the member.
    fn refersTo(f: *Finder, res: *?*const infer.Result, file: FileId, item_index: u32, l: Lookup, at: Reference) resolve.Error!Target {
        if (l.member(try f.inferred(res, file, item_index))) |m| {
            const d = try keyDef(f.r, m) orelse return .miss;
            return if (deepEql(d, f.def)) .hit else .miss;
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
        if (!all.complete) if (f.incomplete) |slot| if (slot.* == null) {
            slot.* = at;
        };
        if (hit and miss) if (f.ambiguous) |a| if (a.* == null) {
            a.* = at;
        };
        if (hit) return .hit;
        return if (miss) .miss else .unknown;
    }

    /// An access whose member cannot be determined: when the type that determines the member (the
    /// left-hand side of a field access, the enum literal or initializer expression itself) is
    /// unknown or abstract, it is recorded as uncertain (when a concrete type has no such member,
    /// it is not a reference, e.g. `len` of a slice)
    fn noteUncertain(f: *Finder, res: *?*const infer.Result, file: FileId, item_index: u32, e: Body.ExprId, at: Reference) resolve.Error!void {
        const slot = f.uncertain orelse return;
        if (slot.* != null) return;
        const exprs = (try f.inferred(res, file, item_index)).exprs;
        const i = @backingInt(e);
        if (i >= exprs.len or seed.wanted(f.r.ctx.db.env.ip, exprs[i])) slot.* = at;
    }

    fn instances(f: *Finder, file: FileId, item_index: u32) resolve.Error!struct { list: []const InternPool.Index, complete: bool } {
        if (f.cached) |c| if (c.file == file and c.item == item_index) return .{ .list = c.list, .complete = c.complete };
        const all = try seed.allInstances(f.r, file, item_index);
        f.cached = .{ .file = file, .item = item_index, .list = all.insts, .complete = all.complete };
        return .{ .list = all.insts, .complete = all.complete };
    }

    fn add(f: *Finder, file: FileId, start: u32, end: u32) resolve.Error!void {
        try f.out.append(f.r.arena, .{ .file = file, .start = start, .end = end });
    }

    /// Uses the name at the end of the expression (field name, name of an enum literal) as the
    /// reference position. Scans backward over the source text directly instead of relying on the
    /// parse result (which may have been evicted).
    fn addLastToken(f: *Finder, file: FileId, end: u32) resolve.Error!void {
        const text = (try f.r.ctx.get(database.syntax.SourceText, file)).text;
        const start = lastNameStart(text, end) orelse return;
        try f.add(file, start, end);
    }
};

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
