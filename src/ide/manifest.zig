//! The built-in schema of `build.zig.zon` (from the official Zig documentation
//! `doc/build.zig.zon.md`; `zig build gen` generates `manifest_data.zig`): completion and
//! documentation of field names, and completion and goto of the paths in the elements of `.paths`
//! and in the `.path` of dependencies. Used only when no import site gives a result type
//! (`ZonResultType` is null); with a result type, the file is inferred with that type like any
//! other `.zon` file.

const std = @import("std");
const database = @import("../database.zig");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const ast = @import("../syntax/ast.zig");
const SyntaxNode = ast.SyntaxNode;
const SyntaxToken = ast.SyntaxToken;
const Body = @import("../hir/Body.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const Vfs = @import("../base/Vfs.zig");
const data = @import("manifest_data.zig");

pub const Field = struct {
    name: []const u8,
    /// markdown
    doc: []const u8,
};

/// An object in the schema: the top level, or an entry of `.dependencies` (keyed by any dependency
/// name)
pub const Object = enum {
    top_level,
    dependency,

    pub fn fields(o: Object) []const Field {
        return switch (o) {
            .top_level => &data.top_level,
            .dependency => &data.dependency,
        };
    }
};

/// Strings whose value is a path, all relative to the build root (the directory of
/// `build.zig.zon`)
pub const PathKind = enum {
    /// An element of `.paths`: a file or directory included in the package
    included,
    /// The `.path` of a dependency: the directory of the dependency
    dependency,
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Whether `file` is handled by the built-in schema: its name is `build.zig.zon` and no import site
/// gives a result type
pub fn active(r: *Resolver, file: FileId) resolve.Error!bool {
    if (!eql(std.fs.path.basename(r.ctx.db.env.vfs.path(file)), "build.zig.zon")) return false;
    return try r.ctx.get(database.sema.ZonResultType, file) == null;
}

const Init = @FieldType(Body.Expr, "init");

/// An untyped initializer `.{ ... }`
fn untypedInit(b: *const Body, e: Body.ExprId) ?Init {
    return switch (b.expr(e)) {
        .init => |x| if (x.ty == null) x else null,
        else => null,
    };
}

/// The value of the field named `name` in the initializer `init` (the first one when the name
/// repeats)
fn fieldValue(b: *const Body, init: Body.ExprId, name: []const u8) ?Body.ExprId {
    const x = untypedInit(b, init) orelse return null;
    for (x.fields) |f| if (f.name) |n| if (eql(n, name)) return f.value;
    return null;
}

fn hasField(given: []const Body.FieldInit, name: []const u8) bool {
    for (given) |f| if (f.name) |n| if (eql(n, name)) return true;
    return false;
}

/// The entries of `.dependencies` (their values are initializer expressions)
fn dependencies(b: *const Body) ?[]const Body.FieldInit {
    const value = b.value orelse return null;
    const deps = fieldValue(b, value, "dependencies") orelse return null;
    return (untypedInit(b, deps) orelse return null).fields;
}

/// The schema object that the initializer expression `init` corresponds to
fn objectOf(b: *const Body, init: Body.ExprId) ?Object {
    if (untypedInit(b, init) == null) return null;
    if (b.value == init) return .top_level;
    for (dependencies(b) orelse return null) |dep| if (dep.name != null and dep.value == init) return .dependency;
    return null;
}

/// The field names to complete in the initializer expression `init` (in the Body `b` of the ZON
/// root expression): the schema fields not given yet. The `url` and `path` of a dependency are
/// mutually exclusive (the compiler rejects both), so once one is given the other is not offered
pub fn fieldCompletions(r: *Resolver, file: FileId, b: *const Body, init: Body.ExprId) resolve.Error![]const Field {
    if (!try active(r, file)) return &.{};
    const object = objectOf(b, init) orelse return &.{};
    const given = untypedInit(b, init).?.fields;
    var out: std.ArrayList(Field) = .empty;
    for (object.fields()) |f| {
        if (hasField(given, f.name)) continue;
        if (object == .dependency) {
            if (eql(f.name, "url") and hasField(given, "path")) continue;
            if (eql(f.name, "path") and hasField(given, "url")) continue;
        }
        try out.append(r.arena, f);
    }
    return out.items;
}

/// A position in the root value: the field names passed through from the outside in, with null for
/// tuple elements
const Slots = []const ?[]const u8;

/// The position in the root value of the last node (an init_list) of the covering path `nodes`
/// (from the root). Null unless the path goes only through untyped initializers `.{ ... }`
fn listSlots(r: *Resolver, nodes: []const SyntaxNode) resolve.Error!?Slots {
    var slots: std.ArrayList(?[]const u8) = .empty;
    var i = nodes.len;
    while (true) {
        if (i < 3 or nodes[i - 1].kind() != .init_list) return null;
        const init = ast.cast(ast.InitExpr, nodes[i - 2]) orelse return null;
        if (init.typeExpr() != null) return null;
        const parent = nodes[i - 3];
        switch (parent.kind()) {
            .source_file => break,
            .field_init => {
                const name = (ast.FieldInit{ .syntax = parent }).name() orelse return null;
                try slots.append(r.arena, try ast.identNameAlloc(r.arena, name.text));
                i -= 3;
            },
            .init_list => {
                try slots.append(r.arena, null);
                i -= 2;
            },
            else => return null,
        }
    }
    std.mem.reverse(?[]const u8, slots.items);
    return slots.items;
}

/// The position in the root value of the value or field name that holds `tok`
fn tokenSlots(r: *Resolver, file: FileId, tok: SyntaxToken) resolve.Error!?Slots {
    const root = (try r.ctx.get(database.syntax.ParseFile, file)).rootNode();
    const nodes = try root.coveringPath(r.arena, tok.offset);
    if (nodes.len < 2) return null;
    const node = nodes[nodes.len - 1];
    const parent = nodes[nodes.len - 2];
    const slot: ?[]const u8, const list: []const SyntaxNode = switch (node.kind()) {
        // A field name
        .field_init => blk: {
            const name = (ast.FieldInit{ .syntax = node }).name() orelse return null;
            if (name.offset != tok.offset) return null;
            break :blk .{ try ast.identNameAlloc(r.arena, name.text), nodes[0 .. nodes.len - 1] };
        },
        // The value of a field or an element of a tuple. An unclosed string is in an error node;
        // right after a `.name =` that lacks a value, it is the value of that field
        .literal, .error_node => switch (parent.kind()) {
            .field_init => blk: {
                const name = (ast.FieldInit{ .syntax = parent }).name() orelse return null;
                break :blk .{ try ast.identNameAlloc(r.arena, name.text), nodes[0 .. nodes.len - 2] };
            },
            .init_list => blk: {
                var prev: ?SyntaxNode = null;
                var it = parent.children();
                while (it.nextNode()) |c| {
                    if (c.offset == node.offset) break;
                    prev = c;
                }
                const field: ?ast.FieldInit = if (prev) |p| ast.cast(ast.FieldInit, p) else null;
                if (node.kind() == .error_node) if (field) |f| if (f.value() == null) {
                    const name = f.name() orelse return null;
                    break :blk .{ try ast.identNameAlloc(r.arena, name.text), nodes[0 .. nodes.len - 1] };
                };
                break :blk .{ null, nodes[0 .. nodes.len - 1] };
            },
            else => return null,
        },
        else => return null,
    };
    const outer = try listSlots(r, list) orelse return null;
    return try std.mem.concat(r.arena, ?[]const u8, &.{ outer, &.{slot} });
}

fn slotIs(slot: ?[]const u8, name: []const u8) bool {
    return if (slot) |s| eql(s, name) else false;
}

/// The schema documentation of the field name token `tok`
pub fn fieldDoc(r: *Resolver, file: FileId, tok: SyntaxToken) resolve.Error!?[]const u8 {
    if (tok.kind != .identifier or !try active(r, file)) return null;
    const slots = try tokenSlots(r, file, tok) orelse return null;
    const object: Object, const name = switch (slots.len) {
        1 => .{ .top_level, slots[0] orelse return null },
        3 => if (slotIs(slots[0], "dependencies") and slots[1] != null) .{ .dependency, slots[2] orelse return null } else return null,
        else => return null,
    };
    for (object.fields()) |f| if (eql(f.name, name)) return f.doc;
    return null;
}

/// The kind of path held by the string token `tok` (which may be unclosed)
pub fn pathKind(r: *Resolver, file: FileId, tok: SyntaxToken) resolve.Error!?PathKind {
    const string = tok.kind == .string_literal or (tok.kind == .invalid and std.mem.startsWith(u8, tok.text, "\""));
    if (!string or !try active(r, file)) return null;
    const slots = try tokenSlots(r, file, tok) orelse return null;
    if (slots.len == 2 and slotIs(slots[0], "paths") and slots[1] == null) return .included;
    if (slots.len == 3 and slotIs(slots[0], "dependencies") and slots[1] != null and slotIs(slots[2], "path")) return .dependency;
    return null;
}

/// The absolute path of the file that the path string `tok` points to (null for directories,
/// missing paths, absolute paths and unclosed strings). The file is not interned: it takes no part
/// in analysis, and interned files other than Zig sources are watched, their changes rebuilding
/// the project
pub fn pathTarget(r: *Resolver, file: FileId, tok: SyntaxToken) resolve.Error!?[]const u8 {
    if (tok.kind != .string_literal) return null;
    _ = try pathKind(r, file, tok) orelse return null;
    const value = try Body.stringLiteralValue(r.arena, tok.text) orelse return null;
    if (value.len == 0 or std.fs.path.isAbsolute(value)) return null;
    const vfs = r.ctx.db.env.vfs;
    const dir = std.fs.path.dirname(vfs.path(file)) orelse return null;
    const full = switch (vfs.style) {
        inline else => |style| try Vfs.resolve(style, r.arena, dir, value),
    } orelse return null;
    const stat = std.Io.Dir.cwd().statFile(vfs.io, full, .{}) catch return null;
    if (stat.kind != .file) return null;
    return full;
}
