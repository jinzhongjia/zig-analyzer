//! Reads a `build.zig.zon` manifest: the fields the package view shows, and the source spans
//! needed to edit a dependency's `.hash`. Only the parts the server uses are decoded; everything
//! else (including fields of dependency entries that are not `url`, `path`, `hash` or `lazy`) is
//! ignored. A manifest with syntax or ZON errors gives null, as it has no stable spans to edit.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Zoir = std.zig.Zoir;

/// Byte range in the manifest text
pub const Span = struct {
    start: u32,
    end: u32,
};

pub const Dependency = struct {
    name: []const u8,
    url: ?[]const u8 = null,
    path: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    lazy: ?bool = null,
    /// The entry, from the dot before its name to the end of its value
    span: Span,
    /// The string literal of `.url`, quotes included
    url_span: ?Span = null,
    /// The string literal of `.hash`, quotes included
    hash_span: ?Span = null,
};

pub const Manifest = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    /// The source text of the value (`0x...` for a fingerprint)
    fingerprint: ?[]const u8 = null,
    minimum_zig_version: ?[]const u8 = null,
    paths: []const []const u8 = &.{},
    dependencies: []const Dependency = &.{},
};

/// Parses `text`; all results are allocated from `a`, which must live as long as they are used.
/// Returns null when the text is empty or is not a ZON struct.
pub fn parse(a: Allocator, text: []const u8) Allocator.Error!?Manifest {
    if (text.len == 0) return null;
    const source = try a.dupeSentinel(u8, text, 0);
    const ast = try Ast.parse(a, source, .{ .mode = .zon });
    if (ast.errors.len != 0) return null;
    const zoir = try std.zig.ZonGen.generate(a, ast, .{});
    if (zoir.hasCompileErrors()) return null;
    const root = switch (Zoir.Node.Index.root.get(&zoir)) {
        .struct_literal => |s| s,
        else => return null,
    };
    var manifest: Manifest = .{};
    for (root.names, 0..) |raw_name, i| {
        const name = raw_name.get(&zoir);
        const index = root.vals.at(@intCast(i));
        const node = index.get(&zoir);
        const ast_node = index.getAstNode(&zoir);
        if (std.mem.eql(u8, name, "name")) {
            manifest.name = literal(node, &zoir);
        } else if (std.mem.eql(u8, name, "version")) {
            manifest.version = literal(node, &zoir);
        } else if (std.mem.eql(u8, name, "fingerprint")) {
            manifest.fingerprint = ast.tokenSlice(ast.nodeMainToken(ast_node));
        } else if (std.mem.eql(u8, name, "minimum_zig_version")) {
            manifest.minimum_zig_version = literal(node, &zoir);
        } else if (std.mem.eql(u8, name, "paths")) {
            switch (node) {
                .array_literal => |array| {
                    var paths: std.ArrayList([]const u8) = .empty;
                    for (0..array.len) |j| {
                        const element = array.at(@intCast(j)).get(&zoir);
                        try paths.append(a, literal(element, &zoir) orelse continue);
                    }
                    manifest.paths = paths.items;
                },
                else => {},
            }
        } else if (std.mem.eql(u8, name, "dependencies")) {
            switch (node) {
                .struct_literal => |entries| {
                    const dependencies = try a.alloc(Dependency, entries.names.len);
                    for (entries.names, 0..) |raw_dep_name, j| {
                        const dep_index = entries.vals.at(@intCast(j));
                        dependencies[j] = dependency(&ast, &zoir, raw_dep_name.get(&zoir), dep_index);
                    }
                    manifest.dependencies = dependencies;
                },
                else => {},
            }
        }
    }
    return manifest;
}

fn dependency(
    ast: *const Ast,
    zoir: *const Zoir,
    name: []const u8,
    index: Zoir.Node.Index,
) Dependency {
    const ast_node = index.getAstNode(zoir);
    // The field name of `.name = value`: the token before `=`
    const name_token = ast.firstToken(ast_node) - 2;
    const name_span = tokenSpan(ast, name_token);
    const start = if (name_span.start > 0 and ast.source[name_span.start - 1] == '.') name_span.start - 1 else name_span.start;
    var dep: Dependency = .{
        .name = name,
        .span = .{ .start = start, .end = tokenSpan(ast, ast.lastToken(ast_node)).end },
    };
    const fields = switch (index.get(zoir)) {
        .struct_literal => |s| s,
        else => return dep,
    };
    for (fields.names, 0..) |raw_field, i| {
        const field = raw_field.get(zoir);
        const field_index = fields.vals.at(@intCast(i));
        const field_node = field_index.get(zoir);
        const field_node_ast = field_index.getAstNode(zoir);
        switch (field_node) {
            .string_literal => |value| {
                const span = tokenSpan(ast, ast.nodeMainToken(field_node_ast));
                if (std.mem.eql(u8, field, "url")) {
                    dep.url = value;
                    dep.url_span = span;
                } else if (std.mem.eql(u8, field, "path")) {
                    dep.path = value;
                } else if (std.mem.eql(u8, field, "hash")) {
                    dep.hash = value;
                    dep.hash_span = span;
                }
            },
            .true => if (std.mem.eql(u8, field, "lazy")) {
                dep.lazy = true;
            },
            .false => if (std.mem.eql(u8, field, "lazy")) {
                dep.lazy = false;
            },
            else => {},
        }
    }
    return dep;
}

/// A decoded string or enum literal; null for other values
fn literal(node: Zoir.Node, zoir: *const Zoir) ?[]const u8 {
    return switch (node) {
        .string_literal => |s| s,
        .enum_literal => |s| s.get(zoir),
        else => null,
    };
}

fn tokenSpan(ast: *const Ast, token: Ast.TokenIndex) Span {
    const start = ast.tokenStart(token);
    return .{ .start = start, .end = start + @as(u32, @intCast(ast.tokenSlice(token).len)) };
}

/// The dependency whose entry intersects `[start, end]`; a point (start == end) selects the entry
/// it lies in, including its first and last byte
pub fn dependencyAt(manifest: *const Manifest, start: u32, end: u32) ?*const Dependency {
    for (manifest.dependencies) |*dep| {
        if (start == end) {
            if (dep.span.start <= start and start <= dep.span.end) return dep;
        } else if (dep.span.start < end and start < dep.span.end) return dep;
    }
    return null;
}

pub const HashEdit = struct {
    start: u32,
    end: u32,
    text: []const u8,
};

/// The edit that gives the dependency `name` (whose `.url` must still be `url`) the hash `hash`:
/// it replaces the string literal of `.hash`, or inserts `.hash` after `.url` when there is none
pub fn hashEdit(
    a: Allocator,
    manifest: *const Manifest,
    name: []const u8,
    url: []const u8,
    hash: []const u8,
) Allocator.Error!?HashEdit {
    if (std.mem.indexOfAny(u8, hash, "\"\\") != null) return null;
    for (manifest.dependencies) |*dep| {
        if (!std.mem.eql(u8, dep.name, name)) continue;
        const dep_url = dep.url orelse return null;
        if (!std.mem.eql(u8, dep_url, url)) return null;
        if (dep.hash_span) |span| {
            return .{ .start = span.start, .end = span.end, .text = try std.fmt.allocPrint(a, "\"{s}\"", .{hash}) };
        }
        const url_span = dep.url_span orelse return null;
        return .{ .start = url_span.end, .end = url_span.end, .text = try std.fmt.allocPrint(a, ", .hash = \"{s}\"", .{hash}) };
    }
    return null;
}

const testing = std.testing;

const sample =
    \\.{
    \\    .name = .pkg,
    \\    .version = "1.2.3",
    \\    .fingerprint = 0x1234567890abcdef,
    \\    .minimum_zig_version = "0.17.0",
    \\    .dependencies = .{
    \\        .lib = .{
    \\            .url = "https://example.com/lib.tar.gz",
    \\            .hash = "lib-0.1.0-AAAA",
    \\            .lazy = true,
    \\        },
    \\        .local = .{ .path = "local" },
    \\    },
    \\    .paths = .{ "src", "build.zig" },
    \\}
;

test "parse manifest fields and dependencies" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const manifest = (try parse(arena.allocator(), sample)).?;
    try testing.expectEqualStrings("pkg", manifest.name.?);
    try testing.expectEqualStrings("1.2.3", manifest.version.?);
    try testing.expectEqualStrings("0x1234567890abcdef", manifest.fingerprint.?);
    try testing.expectEqualStrings("0.17.0", manifest.minimum_zig_version.?);
    try testing.expectEqual(2, manifest.paths.len);
    try testing.expectEqualStrings("src", manifest.paths[0]);
    try testing.expectEqualStrings("build.zig", manifest.paths[1]);
    try testing.expectEqual(2, manifest.dependencies.len);

    const lib = manifest.dependencies[0];
    try testing.expectEqualStrings("lib", lib.name);
    try testing.expectEqualStrings("https://example.com/lib.tar.gz", lib.url.?);
    try testing.expectEqualStrings("lib-0.1.0-AAAA", lib.hash.?);
    try testing.expectEqual(true, lib.lazy.?);
    try testing.expectEqualStrings(
        "\"https://example.com/lib.tar.gz\"",
        sample[lib.url_span.?.start..lib.url_span.?.end],
    );
    try testing.expectEqualStrings("\"lib-0.1.0-AAAA\"", sample[lib.hash_span.?.start..lib.hash_span.?.end]);
    const expected =
        \\.lib = .{
        \\            .url = "https://example.com/lib.tar.gz",
        \\            .hash = "lib-0.1.0-AAAA",
        \\            .lazy = true,
        \\        }
    ;
    try testing.expectEqualStrings(expected, sample[lib.span.start..lib.span.end]);

    const local = manifest.dependencies[1];
    try testing.expectEqualStrings("local", local.name);
    try testing.expectEqualStrings("local", local.path.?);
    try testing.expectEqual(null, local.url);
    try testing.expectEqual(null, local.lazy);
    try testing.expectEqualStrings("local = .{ .path = \"local\" }", sample[local.span.start + 1 .. local.span.end]);
}

test "dependencyAt selects the entry under the cursor" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const manifest = (try parse(arena.allocator(), sample)).?;
    const lib = dependencyAt(&manifest, manifest.dependencies[0].url_span.?.start + 3, manifest.dependencies[0].url_span.?.start + 3).?;
    try testing.expectEqualStrings("lib", lib.name);
    try testing.expectEqual(null, dependencyAt(&manifest, 0, 1));
}

test "hashEdit replaces and inserts the hash" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const manifest = (try parse(a, sample)).?;

    const replaced = (try hashEdit(a, &manifest, "lib", "https://example.com/lib.tar.gz", "lib-0.1.0-BBBB")).?;
    try testing.expectEqualStrings("\"lib-0.1.0-BBBB\"", replaced.text);
    try testing.expectEqualStrings("\"lib-0.1.0-AAAA\"", sample[replaced.start..replaced.end]);

    // A dependency without a hash gets one after `.url`
    const inserted = (try hashEdit(a, &manifest, "local", "local", "local-0.1.0-CCCC"));
    try testing.expectEqual(null, inserted);
    const with_url = ".{ .dependencies = .{ .dep = .{ .url = \"https://example.com/x.tar.gz\" } } }";
    const other = (try parse(a, with_url)).?;
    const edit = (try hashEdit(a, &other, "dep", "https://example.com/x.tar.gz", "dep-0.1.0-DDDD")).?;
    try testing.expectEqualStrings(", .hash = \"dep-0.1.0-DDDD\"", edit.text);
    try testing.expectEqual(edit.start, edit.end);
    const result = try std.mem.concat(a, u8, &.{ with_url[0..edit.start], edit.text, with_url[edit.start..] });
    const reparsed = (try parse(a, result)).?;
    try testing.expectEqualStrings("dep-0.1.0-DDDD", reparsed.dependencies[0].hash.?);

    // The URL must still be the one the action was offered for
    try testing.expectEqual(null, try hashEdit(a, &manifest, "lib", "https://example.com/other.tar.gz", "x"));
    try testing.expectEqual(null, try hashEdit(a, &manifest, "missing", "https://example.com/lib.tar.gz", "x"));
}

test "parse rejects invalid or empty manifests" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(null, try parse(a, ""));
    try testing.expectEqual(null, try parse(a, ".{ .name = "));
    try testing.expectEqual(null, try parse(a, "not a zon struct"));
}
