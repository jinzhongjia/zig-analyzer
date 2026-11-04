//! `zig-analyzer.zon`: completion and documentation of the settings a project can set. What can be
//! set comes from `Config.project_schema`, and the descriptions from the comments in
//! `zig-analyzer.default.zon`, the same text users read there. Used only when no import site gives
//! the file a result type (`ZonResultType` is null).

const std = @import("std");
const Ast = std.zig.Ast;
const database = @import("../database.zig");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const ast = @import("../syntax/ast.zig");
const SyntaxToken = ast.SyntaxToken;
const Body = @import("../hir/Body.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const Config = @import("../server/Config.zig");
const manifest = @import("manifest.zig");

const default_config: [:0]const u8 = @embedFile("default_config");

pub const Entry = struct {
    name: []const u8,
    value: Config.SchemaValue,
    /// markdown
    doc: ?[]const u8,
};

/// Whether `file` is handled by the schema: its name is `zig-analyzer.zon` and no import site gives
/// a result type
pub fn active(r: *Resolver, file: FileId) resolve.Error!bool {
    if (!std.mem.eql(u8, std.fs.path.basename(r.ctx.db.env.vfs.path(file)), Config.project_file)) return false;
    return try r.ctx.get(database.sema.ZonResultType, file) == null;
}

/// The fields at `path` in the schema, from the top level; null when the path leaves the schema
fn fieldsAt(path: []const []const u8) ?[]const Config.SchemaField {
    var fields = Config.project_schema;
    for (path) |name| {
        const f = for (fields) |f| {
            if (std.mem.eql(u8, f.name, name)) break f;
        } else return null;
        fields = switch (f.value) {
            .fields => |x| x,
            else => return null,
        };
    }
    return fields;
}

fn valueAt(path: []const []const u8) ?Config.SchemaValue {
    if (path.len == 0) return null;
    for (fieldsAt(path[0 .. path.len - 1]) orelse return null) |f| {
        if (std.mem.eql(u8, f.name, path[path.len - 1])) return f.value;
    }
    return null;
}

/// The comment lines right above the field at `path` in the default settings, with its default
/// value when that is a single value; null when the field has no comment
pub fn docAt(a: std.mem.Allocator, path: []const []const u8) std.mem.Allocator.Error!?[]const u8 {
    var tree = try Ast.parse(a, default_config, .{ .mode = .zon });
    defer tree.deinit(a);
    var node = tree.rootDecls()[0];
    for (path) |name| {
        var buf: [2]Ast.Node.Index = undefined;
        const init = tree.fullStructInit(&buf, node) orelse return null;
        node = for (init.ast.fields) |field| {
            if (std.mem.eql(u8, ast.identName(tree.tokenSlice(tree.firstToken(field) - 2)), name)) break field;
        } else return null;
    }
    const dot = tree.tokenStart(tree.firstToken(node) - 3);
    var lines: std.ArrayList([]const u8) = .empty;
    var end = std.mem.lastIndexOfScalar(u8, default_config[0..dot], '\n') orelse return null;
    while (end > 0) {
        const start = if (std.mem.lastIndexOfScalar(u8, default_config[0..end], '\n')) |i| i + 1 else 0;
        const line = std.mem.trim(u8, default_config[start..end], " ");
        if (!std.mem.startsWith(u8, line, "//")) break;
        try lines.append(a, std.mem.trim(u8, line[2..], " "));
        if (start == 0) break;
        end = start - 1;
    }
    if (lines.items.len == 0) return null;
    std.mem.reverse([]const u8, lines.items);
    const text = try std.mem.join(a, " ", lines.items);
    var buf: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&buf, node) != null) return text;
    return try std.fmt.allocPrint(a, "{s}\n\nDefault: `{s}`", .{ text, tree.getNodeSource(node) });
}

/// The names of the field or element position of `slots`; null when it goes through a tuple element
fn names(a: std.mem.Allocator, slots: []const ?[]const u8) std.mem.Allocator.Error!?[]const []const u8 {
    const out = try a.alloc([]const u8, slots.len);
    for (slots, out) |slot, *o| o.* = slot orelse return null;
    return out;
}

/// The description of the setting whose name is the token `tok`
pub fn fieldDoc(r: *Resolver, file: FileId, tok: SyntaxToken) resolve.Error!?[]const u8 {
    if (tok.kind != .identifier or !try active(r, file)) return null;
    const slots = try manifest.tokenSlots(r, file, tok) orelse return null;
    const path = try names(r.arena, slots) orelse return null;
    if (valueAt(path) == null) return null;
    return docAt(r.arena, path);
}

/// The names leading from the root expression of the file down to the initializer `init`; null when
/// it is not reached through named fields of initializers
fn initPath(a: std.mem.Allocator, b: *const Body, init: Body.ExprId) std.mem.Allocator.Error!?[]const []const u8 {
    var path: std.ArrayList([]const u8) = .empty;
    var cur = b.value orelse return null;
    const range = b.range(init);
    while (cur != init) {
        const x = switch (b.expr(cur)) {
            .init => |x| x,
            else => return null,
        };
        cur = for (x.fields) |f| {
            const child = b.range(f.value);
            if (child.start <= range.start and range.end <= child.end) {
                try path.append(a, f.name orelse return null);
                break f.value;
            }
        } else return null;
    }
    return path.items;
}

/// The settings to complete in the initializer `init` of the root expression of `file`: those at its
/// position that are not given yet
pub fn fieldCompletions(r: *Resolver, file: FileId, b: *const Body, init: Body.ExprId) resolve.Error![]const Entry {
    if (!try active(r, file)) return &.{};
    const x = switch (b.expr(init)) {
        .init => |x| x,
        else => return &.{},
    };
    const path = try initPath(r.arena, b, init) orelse return &.{};
    const fields = fieldsAt(path) orelse return &.{};
    var out: std.ArrayList(Entry) = .empty;
    fields: for (fields) |f| {
        for (x.fields) |given| if (given.name) |n| if (std.mem.eql(u8, n, f.name)) continue :fields;
        try out.append(r.arena, .{
            .name = f.name,
            .value = f.value,
            .doc = try docAt(r.arena, try std.mem.concat(r.arena, []const u8, &.{ path, &.{f.name} })),
        });
    }
    return out.items;
}

pub const Values = struct {
    names: []const []const u8,
    /// `names` are the names of an enum, following a `.`
    tags: bool,
};

/// What to complete as a value of the setting whose `=` comes before `offset`, skipping the name
/// being typed: an enum's names after a `.`, `true` and `false` otherwise. Null when `offset` is not
/// there or the setting has no such values.
pub fn valueCompletions(r: *Resolver, file: FileId, text: []const u8, offset: u32, root: ast.SyntaxNode) resolve.Error!?Values {
    if (!try active(r, file)) return null;
    var i: usize = offset;
    while (i > 0 and isName(text[i - 1])) i -= 1;
    const dot = i > 0 and text[i - 1] == '.';
    if (dot) i -= 1;
    while (i > 0 and std.ascii.isWhitespace(text[i - 1])) i -= 1;
    if (i == 0 or text[i - 1] != '=') return null;
    i -= 1;
    while (i > 0 and std.ascii.isWhitespace(text[i - 1])) i -= 1;
    if (i == 0) return null;
    const tok = root.tokenAtOffset(@intCast(i - 1)) orelse return null;
    if (tok.kind != .identifier) return null;
    const slots = try manifest.tokenSlots(r, file, tok) orelse return null;
    const path = try names(r.arena, slots) orelse return null;
    return switch (valueAt(path) orelse return null) {
        .tags => |tags| if (dot) .{ .names = tags, .tags = true } else null,
        .bool => if (dot) null else .{ .names = &.{ "true", "false" }, .tags = false },
        else => null,
    };
}

fn isName(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const testing = std.testing;

test "every setting of the project configuration has a description in the default settings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const check = struct {
        fn walk(a: std.mem.Allocator, prefix: []const []const u8, fields: []const Config.SchemaField) anyerror!void {
            for (fields) |f| {
                const path = try std.mem.concat(a, []const u8, &.{ prefix, &.{f.name} });
                if (try docAt(a, path) == null) {
                    std.debug.print("no description of `{s}`\n", .{try std.mem.join(a, ".", path)});
                    return error.NoDescription;
                }
                switch (f.value) {
                    .fields => |inner| try walk(a, path, inner),
                    else => {},
                }
            }
        }
    }.walk;
    try check(arena.allocator(), &.{}, Config.project_schema);
}

test "the default settings are a valid project configuration" {
    var config = try Config.parseProject(testing.allocator, default_config);
    defer config.deinit(testing.allocator);
    try testing.expectEqual(0, config.warnings.len);
}
