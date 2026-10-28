//! Safety checks for renaming (for finding references, see `search.findReferences`): conflicts
//! of the new name with existing names, and reflection that refers to names by string.
//!
//! Zig does not allow a local name to shadow outer local names or declarations, and members of
//! one container (declarations and fields) cannot share a name either: such renames make AstGen
//! report errors, which `declarationConflict` detects in advance and `verifyAstGen` confirms on
//! the renamed text. A declaration in a container, however, may share its name with a declaration
//! of an outer container (the inner one takes precedence); such a rename causes no error, but the
//! name silently refers to another declaration, which `resolutionConflict` checks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const database = @import("../database.zig");
const live = @import("../diagnostics/live.zig");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Def = resolve.Def;
const ItemTree = @import("../syntax/ItemTree.zig");
const Body = @import("../hir/Body.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const deepEql = @import("../util/deep_eql.zig").deepEql;

/// Reason a rename is not possible
pub const Problem = struct {
    file: FileId,
    /// Location of the problem (byte offset)
    offset: u32,
    message: []const u8,
};

/// Replacement of the text in `[start, end)`
pub const Edit = struct { start: u32, end: u32, text: []const u8 };

/// Edits in one file, sorted by position and non-overlapping
pub const FileEdits = struct { file: FileId, edits: []const Edit };

/// An error reported by AstGen: position (byte offset) and message text
pub const AstGenError = struct { start: u32, message: []const u8 };

/// Conflicts at the declaration (AstGen reports an error after renaming to `new`): the same
/// container already has a member named `new`; a local name matches a name visible where it is
/// declared (shadowing an outer one) or a local name deeper within its scope (being shadowed); a
/// declaration in a container inside a function body matches a local name visible in the function
pub fn declarationConflict(r: *Resolver, def: Def, new: []const u8) resolve.Error!?Problem {
    switch (def) {
        .file => return null,
        .item => |it| {
            const tree = try r.itemTree(it.file);
            for (tree.containerMembers(tree.items[it.item].container)) |m| {
                if (m == it.item) continue;
                switch (tree.items[m].kind) {
                    .@"test", .@"comptime" => continue,
                    else => {},
                }
                const name = tree.items[m].name orelse continue;
                if (std.mem.eql(u8, name, new)) return try problemAt(r, .{ .item = .{ .file = it.file, .item = m } }, "`{s}` is already declared in the same container", new);
            }
            // Fields are not names in a scope
            if (tree.items[it.item].kind == .field) return null;
            if (try r.resolveContainerName(it.file, it.item, new)) |d| if (d == .local) {
                return try problemAt(r, d, "the new name `{s}` would shadow this local", new);
            };
            return null;
        },
        .local => |l| {
            const b = try r.body(l.file, l.item);
            const scope = scopeOf(b, l.binding) orelse return null;
            if (b.lookup(scope, new)) |other| if (other != l.binding) {
                return try problemAt(r, .{ .local = .{ .file = l.file, .item = l.item, .binding = other } }, "`{s}` is already declared in this scope", new);
            };
            if (try r.resolveContainerName(l.file, l.item, new)) |d| return try problemAt(r, d, "the new name `{s}` would shadow this declaration", new);
            for (b.bindings, 0..) |other, i| {
                const id: Body.BindingId = @fromBackingInt(@as(u32, @intCast(i)));
                if (id == l.binding or !std.mem.eql(u8, other.name, new)) continue;
                if (within(b, scopeOf(b, id) orelse continue, scope)) {
                    return try problemAt(r, .{ .local = .{ .file = l.file, .item = l.item, .binding = id } }, "this `{s}` would shadow the renamed name", new);
                }
            }
            return null;
        },
    }
}

/// After a declaration in a container is renamed to `new`, name references inside the container
/// change their target (AstGen reports no error):
/// - A reference to it already sees a closer `new` (a declaration or local name inside the
///   container): after the rename, the reference is captured by that name
/// - A reference inside the container that used to refer to a `new` outside the container: after
///   the rename, it refers to the renamed declaration
pub fn resolutionConflict(r: *Resolver, def: Def, new: []const u8) resolve.Error!?Problem {
    const it = switch (def) {
        .item => |it| it,
        else => return null,
    };
    const tree = try r.itemTree(it.file);
    switch (tree.items[it.item].kind) {
        .@"fn", .@"const", .@"var" => {},
        else => return null,
    }
    const old = tree.items[it.item].name orelse return null;
    const container = tree.items[it.item].container;
    for (0..tree.items.len) |i| {
        const index: u32 = @intCast(i);
        if (!inside(tree, index, container)) continue;
        if (!try r.mayMention(it.file, index, old) and !try r.mayMention(it.file, index, new)) continue;
        const body = try r.body(it.file, index);
        const base = try r.itemOffset(it.file, index) orelse continue;
        for (body.exprs, body.expr_scopes, body.expr_ranges, 0..) |e, scope, range, k| {
            const name = switch (e) {
                .name_ref => |n| n,
                else => continue,
            };
            if (body.nameRefIsBuiltin(@fromBackingInt(@as(u32, @intCast(k))))) continue;
            if (std.mem.eql(u8, name, old)) {
                const d = try r.resolveName(it.file, index, body, scope, old) orelse continue;
                if (!deepEql(d, def)) continue;
                const other = try r.resolveName(it.file, index, body, scope, new) orelse continue;
                if (try definedInside(r, other, it.file, container)) return .{
                    .file = it.file,
                    .offset = base + range.start,
                    .message = try std.fmt.allocPrint(r.arena, "this reference would refer to another `{s}` declared closer to it", .{new}),
                };
            } else if (std.mem.eql(u8, name, new)) {
                const d = try r.resolveName(it.file, index, body, scope, new) orelse continue;
                if (!try definedInside(r, d, it.file, container)) return .{
                    .file = it.file,
                    .offset = base + range.start,
                    .message = try std.fmt.allocPrint(r.arena, "this `{s}` refers to another declaration, which the renamed declaration would shadow", .{new}),
                };
            }
        }
    }
    return null;
}

/// First occurrence of the name as a string literal: reflection (`@field(x, "name")`,
/// `@hasDecl(T, "name")`) and serialization refer to names by string, and renaming cannot update
/// these strings
pub fn stringReference(r: *Resolver, files: []const FileId, name: []const u8) resolve.Error!?Problem {
    const quoted = try std.fmt.allocPrint(r.arena, "\"{s}\"", .{name});
    for (files) |f| {
        const text = (try r.ctx.get(database.syntax.SourceText, f)).text;
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, quoted)) |pos| : (from = pos + 1) {
            // Skip occurrences in comments and identifiers of the form `@"name"`
            const root = (try r.ctx.get(database.syntax.ParseFile, f)).rootNode();
            const tok = root.tokenAtOffset(@intCast(pos)) orelse continue;
            if (tok.kind != .string_literal or tok.offset != pos or tok.text.len != quoted.len) continue;
            return .{
                .file = f,
                .offset = @intCast(pos),
                .message = try std.fmt.allocPrint(r.arena, "`{s}` appears in a string literal, which may refer to it by name (as `@field` and serialization do) and would not be updated", .{name}),
            };
        }
    }
    return null;
}

/// First AstGen error that appears after applying `edits` (sorted by position, non-overlapping)
/// to the file and was not there before: duplicate names, shadowing, and references in the file
/// missed by the rename (which no longer resolve to the declaration) are all reported. The
/// position is mapped back to the text before the rename
pub fn verifyAstGen(r: *Resolver, file: FileId, edits: []const Edit) resolve.Error!?Problem {
    const errors = try astGenErrors(r, file, edits);
    // Errors are matched by message text; errors that existed before the rename do not count.
    // Counts are not compared: a new error may keep AstGen from reporting an existing one
    var known: std.StringHashMapUnmanaged(u32) = .empty;
    for (errors.before) |d| {
        const gop = try known.getOrPut(r.arena, d.message);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }
    for (errors.after) |d| {
        if (known.getPtr(d.message)) |n| if (n.* > 0) {
            n.* -= 1;
            continue;
        };
        return .{ .file = file, .offset = d.start, .message = d.message };
    }
    return null;
}

/// AstGen errors of the file before and after applying `edits` (sorted by position,
/// non-overlapping). Positions of the errors after are mapped back to the text before applying.
pub fn astGenErrors(r: *Resolver, file: FileId, edits: []const Edit) resolve.Error!struct { before: []const AstGenError, after: []const AstGenError } {
    const ctx = r.ctx;
    const gpa = ctx.db.gpa;
    const text = (try ctx.get(database.syntax.SourceText, file)).text;
    var edited: std.ArrayList(u8) = .empty;
    var pos: u32 = 0;
    for (edits) |e| {
        try edited.appendSlice(r.arena, text[pos..e.start]);
        try edited.appendSlice(r.arena, e.text);
        pos = e.end;
    }
    try edited.appendSlice(r.arena, text[pos..]);
    const backend = try ctx.get(live.LiveBackend, {});
    const mode = live.modeOf(ctx.db.env.vfs.path(file));
    // Result for the current text: for open files it has already been computed when publishing
    // diagnostics (`AstCheck` reads `FileText`)
    var own_before: ?*live.Result = null;
    defer if (own_before) |b| b.destroy(gpa);
    const before = if (try ctx.get(database.inputs.FileText, file) != null) try ctx.get(live.AstCheck, file) else blk: {
        own_before = try live.checkWith(gpa, ctx.db.io, backend, text, mode);
        break :blk own_before.?;
    };
    const after = try live.checkWith(gpa, ctx.db.io, backend, edited.items, mode);
    defer after.destroy(gpa);
    const out_before = try r.arena.alloc(AstGenError, before.items.len);
    for (before.items, out_before) |d, *o| o.* = .{ .start = d.start, .message = try r.arena.dupe(u8, d.message) };
    const out_after = try r.arena.alloc(AstGenError, after.items.len);
    for (after.items, out_after) |d, *o| o.* = .{ .start = mapBack(edits, d.start), .message = try r.arena.dupe(u8, d.message) };
    return .{ .before = out_before, .after = out_after };
}

/// The errors in `after` that were not there before: each error in `before` matches at most one
/// error in `after` with the same position and message (both from `astGenErrors`)
pub fn newAstGenErrors(arena: Allocator, before: []const AstGenError, after: []const AstGenError) Allocator.Error![]const AstGenError {
    const matched = try arena.alloc(bool, before.len);
    @memset(matched, false);
    var out: std.ArrayList(AstGenError) = .empty;
    next: for (after) |a| {
        for (before, matched) |b, *m| {
            if (!m.* and b.start == a.start and std.mem.eql(u8, b.message, a.message)) {
                m.* = true;
                continue :next;
            }
        }
        try out.append(arena, a);
    }
    return out.items;
}

/// Maps a position after applying `edits` back to the text before; a position inside replacement
/// text maps to the start of the replaced range
fn mapBack(edits: []const Edit, offset: u32) u32 {
    var delta: i64 = 0;
    for (edits) |e| {
        const start: i64 = @as(i64, e.start) + delta;
        if (offset < start) break;
        if (offset < start + @as(i64, @intCast(e.text.len))) return e.start;
        delta += @as(i64, @intCast(e.text.len)) - @as(i64, e.end - e.start);
    }
    return @intCast(@as(i64, offset) - delta);
}

fn problemAt(r: *Resolver, def: Def, comptime fmt: []const u8, new: []const u8) resolve.Error!?Problem {
    const loc = try r.location(def) orelse return null;
    return .{ .file = loc.file, .offset = loc.start, .message = try std.fmt.allocPrint(r.arena, fmt, .{new}) };
}

/// Scope that contains the binding
fn scopeOf(b: *const Body, id: Body.BindingId) ?Body.ScopeId {
    for (b.scopes, 0..) |s, i| {
        if (std.mem.indexOfScalar(Body.BindingId, s.bindings, id) != null) return @fromBackingInt(@as(u32, @intCast(i)));
    }
    return null;
}

/// Whether scope `s` is `ancestor` or lies within it
fn within(b: *const Body, s: Body.ScopeId, ancestor: Body.ScopeId) bool {
    var cur: ?Body.ScopeId = s;
    while (cur) |c| : (cur = b.scope(c).parent) {
        if (c == ancestor) return true;
    }
    return false;
}

/// Whether member `item` is inside container `container` (a direct member, or a member of a
/// container defined within its body)
fn inside(tree: *const ItemTree, item: u32, container: u32) bool {
    var c = tree.items[item].container;
    while (true) {
        if (c == container) return true;
        const parent = tree.containers[c].parent_item orelse return false;
        c = tree.items[parent].container;
    }
}

/// Whether the definition is inside container `container` of file `file`: a member of the
/// container (or of containers within it), or a local name of such a member
fn definedInside(r: *Resolver, d: Def, file: FileId, container: u32) resolve.Error!bool {
    const tree = try r.itemTree(file);
    return switch (d) {
        .item => |x| x.file == file and inside(tree, x.item, container),
        .local => |x| x.file == file and inside(tree, x.item, container),
        .file => false,
    };
}

test {
    _ = @import("rename_test.zig");
}
