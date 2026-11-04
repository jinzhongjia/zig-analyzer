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

/// A value of an enum setting, or `true` / `false`
pub const Value = struct {
    name: []const u8,
    /// markdown
    doc: ?[]const u8 = null,
};

/// The comment above a setting in the default settings:
///
///     // Description, over any number of lines.
///     //   .tag: What this value of an enum does,
///     //     continuing with a deeper indent.
///     // Example:
///     //   .setting = .tag,
const Comment = struct {
    text: []const u8,
    values: []const Value,
    /// What can be written at the position of the setting, on several lines
    example: ?[]const u8,
};

fn parseComment(a: std.mem.Allocator, lines: []const []const u8) std.mem.Allocator.Error!Comment {
    var text: std.ArrayList(u8) = .empty;
    var values: std.ArrayList(Value) = .empty;
    var example: ?[]const u8 = null;
    for (lines, 0..) |line, i| {
        if (std.mem.eql(u8, line, "Example:")) {
            const code = try a.dupe([]const u8, lines[i + 1 ..]);
            for (code) |*c| {
                if (std.mem.startsWith(u8, c.*, "  ")) c.* = c.*[2..];
            }
            example = try std.mem.join(a, "\n", code);
            break;
        }
        if (std.mem.startsWith(u8, line, "    ") and values.items.len > 0) {
            const last = &values.items[values.items.len - 1];
            last.doc = try std.fmt.allocPrint(a, "{s} {s}", .{ last.doc.?, std.mem.trim(u8, line, " ") });
        } else if (valueLine(line)) |v| {
            try values.append(a, v);
        } else {
            if (text.items.len > 0) try text.append(a, ' ');
            try text.appendSlice(a, line);
        }
    }
    return .{ .text = text.items, .values = values.items, .example = example };
}

/// The value described by a line `  .tag: text`
fn valueLine(line: []const u8) ?Value {
    if (!std.mem.startsWith(u8, line, "  .")) return null;
    const colon = std.mem.indexOf(u8, line, ": ") orelse return null;
    const name = line[3..colon];
    if (name.len == 0) return null;
    for (name) |c| if (!isName(c)) return null;
    return .{ .name = name, .doc = line[colon + 2 ..] };
}

const Setting = struct {
    comment: Comment,
    /// The value in the default settings, when it is a single value
    default: ?[]const u8,
};

/// The setting at `path` in the default settings; null when it is not there or has no comment
fn settingAt(a: std.mem.Allocator, path: []const []const u8) std.mem.Allocator.Error!?Setting {
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
        const line = std.mem.trimStart(u8, default_config[start..end], " ");
        if (!std.mem.startsWith(u8, line, "//")) break;
        const content = line[2..];
        try lines.append(a, if (std.mem.startsWith(u8, content, " ")) content[1..] else content);
        if (start == 0) break;
        end = start - 1;
    }
    if (lines.items.len == 0) return null;
    std.mem.reverse([]const u8, lines.items);
    var buf: [2]Ast.Node.Index = undefined;
    return .{
        .comment = try parseComment(a, lines.items),
        .default = if (tree.fullStructInit(&buf, node) != null) null else tree.getNodeSource(node),
    };
}

/// The description of the field at `path` in the default settings: its comment, the values of an
/// enum, its default when that is a single value, and an example; null when the field has no comment
pub fn docAt(a: std.mem.Allocator, path: []const []const u8) std.mem.Allocator.Error!?[]const u8 {
    const setting = try settingAt(a, path) orelse return null;
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    write: {
        w.writeAll(setting.comment.text) catch break :write;
        if (setting.comment.values.len > 0) w.writeAll("\n") catch break :write;
        for (setting.comment.values) |v| w.print("\n- `.{s}`: {s}", .{ v.name, v.doc.? }) catch break :write;
        if (setting.default) |d| w.print("\n\nDefault: `{s}`", .{d}) catch break :write;
        if (setting.comment.example) |e| w.print("\n\nExample:\n\n```zig\n{s}\n```", .{e}) catch break :write;
        return out.written();
    }
    return error.OutOfMemory;
}

/// The description of the value `name` of the enum setting at `path`
fn valueDocAt(a: std.mem.Allocator, path: []const []const u8, name: []const u8) std.mem.Allocator.Error!?[]const u8 {
    const setting = try settingAt(a, path) orelse return null;
    for (setting.comment.values) |v| if (std.mem.eql(u8, v.name, name)) return v.doc;
    return null;
}

/// The names of the field or element position of `slots`; null when it goes through a tuple element
fn names(a: std.mem.Allocator, slots: []const ?[]const u8) std.mem.Allocator.Error!?[]const []const u8 {
    const out = try a.alloc([]const u8, slots.len);
    for (slots, out) |slot, *o| o.* = slot orelse return null;
    return out;
}

/// The description of the setting whose name is the token `tok`, or of the enum value that it names
pub fn fieldDoc(r: *Resolver, file: FileId, tok: SyntaxToken) resolve.Error!?[]const u8 {
    if (tok.kind != .identifier or !try active(r, file)) return null;
    if (try enumValueOwner(r, file, tok)) |owner| {
        const slots = try manifest.tokenSlots(r, file, owner) orelse return null;
        const path = try names(r.arena, slots) orelse return null;
        return switch (valueAt(path) orelse return null) {
            .tags => try valueDocAt(r.arena, path, try ast.identNameAlloc(r.arena, tok.text)),
            else => null,
        };
    }
    const slots = try manifest.tokenSlots(r, file, tok) orelse return null;
    const path = try names(r.arena, slots) orelse return null;
    if (valueAt(path) == null) return null;
    return docAt(r.arena, path);
}

/// The name of the field whose value is the enum literal named by `tok`
fn enumValueOwner(r: *Resolver, file: FileId, tok: SyntaxToken) resolve.Error!?SyntaxToken {
    const root = (try r.ctx.get(database.syntax.ParseFile, file)).rootNode();
    const nodes = try root.coveringPath(r.arena, tok.offset);
    if (nodes.len < 2 or nodes[nodes.len - 1].kind() != .enum_literal or nodes[nodes.len - 2].kind() != .field_init) return null;
    return (ast.FieldInit{ .syntax = nodes[nodes.len - 2] }).name();
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
    values: []const Value,
    /// `values` are the names of an enum, following a `.`
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
        .tags => |tags| {
            if (!dot) return null;
            const values = try r.arena.alloc(Value, tags.len);
            for (tags, values) |tag, *v| v.* = .{ .name = tag, .doc = try valueDocAt(r.arena, path, tag) };
            return .{ .values = values, .tags = true };
        },
        .bool => if (dot) null else .{ .values = &.{ .{ .name = "true" }, .{ .name = "false" } }, .tags = false },
        else => null,
    };
}

fn isName(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const testing = std.testing;

/// The settings text that holds `example` at the position of the setting at `path`
fn wrapExample(a: std.mem.Allocator, path: []const []const u8, example: []const u8) std.mem.Allocator.Error![]const u8 {
    var text: []const u8 = example;
    var i = path.len - 1;
    while (i > 0) {
        i -= 1;
        text = try std.fmt.allocPrint(a, ".{s} = .{{ {s} }},", .{ path[i], text });
    }
    return std.fmt.allocPrint(a, ".{{ {s} }}", .{text});
}

test "every setting of the project configuration has a description and a valid example in the default settings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const check = struct {
        fn walk(a: std.mem.Allocator, prefix: []const []const u8, fields: []const Config.SchemaField) anyerror!void {
            for (fields) |f| {
                const path = try std.mem.concat(a, []const u8, &.{ prefix, &.{f.name} });
                errdefer std.debug.print("in the comment of `{s}`\n", .{std.mem.join(a, ".", path) catch ""});
                const setting = try settingAt(a, path) orelse return error.NoDescription;
                try testing.expect(setting.comment.text.len > 0);
                const example = setting.comment.example orelse return error.NoExample;
                try testing.expect(std.mem.startsWith(u8, example, try std.fmt.allocPrint(a, ".{s} =", .{f.name})));
                var config = try Config.parseProject(testing.allocator, try wrapExample(a, path, example));
                defer config.deinit(testing.allocator);
                try testing.expectEqual(0, config.warnings.len);
                switch (f.value) {
                    .fields => |inner| try walk(a, path, inner),
                    .tags => |tags| {
                        try testing.expectEqual(tags.len, setting.comment.values.len);
                        for (tags) |tag| try testing.expect(try valueDocAt(a, path, tag) != null);
                    },
                    else => try testing.expectEqual(0, setting.comment.values.len),
                }
            }
        }
    }.walk;
    try check(arena.allocator(), &.{}, Config.project_schema);
}

test "the description of a setting has its values, default and example" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        \\Order within a group.
        \\
        \\- `.path`: By what is imported: module name, file path with nearer files first, the full access path of derived declarations.
        \\- `.name`: By declaration name.
        \\
        \\Default: `.path`
        \\
        \\Example:
        \\
        \\```zig
        \\.sort = .name,
        \\```
    , (try docAt(arena.allocator(), &.{ "imports", "sort" })).?);
    try testing.expectEqualStrings(
        \\How projects are built.
        \\
        \\Example:
        \\
        \\```zig
        \\.build = .{
        \\    .args = .{"-Dtarget=aarch64-linux"},
        \\},
        \\```
    , (try docAt(arena.allocator(), &.{"build"})).?);
}

test "the default settings are a valid project configuration" {
    var config = try Config.parseProject(testing.allocator, default_config);
    defer config.deinit(testing.allocator);
    try testing.expectEqual(0, config.warnings.len);
}
