//! Generates the documentation of the `build.zig.zon` fields from a pinned version of the official
//! Zig documentation `doc/build.zig.zon.md`; does not access the network.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const official = @import("zig_source.zig");
const Metadata = official.Metadata;

// The fields in the documentation must match these: when the fields change, also check the schema
// rules in `src/ide/manifest.zig` (mutually exclusive fields, fields whose value is a path)
const top_level_fields = [_][]const u8{ "name", "fingerprint", "version", "minimum_zig_version", "dependencies", "paths" };
const dependency_fields = [_][]const u8{ "url", "hash", "path", "lazy" };

fn invalid(comptime fmt: []const u8, args: anytype) error{InvalidOfficialSource} {
    // Tests construct invalid input on purpose; printing to stderr would put a misleading
    // `failed command` in the build output
    if (!@import("builtin").is_test) std.debug.print("manifest documentation: " ++ fmt ++ "\n", args);
    return error.InvalidOfficialSource;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const Field = struct { name: []const u8, doc: []const u8 };
const Fields = struct { top_level: []const Field, dependency: []const Field };

const Section = struct { level: usize, title: []const u8, body: []const u8 };

/// Splits by Markdown headings; lines in code blocks that start with `#` are not headings
fn sections(a: Allocator, input: []const u8) ![]const Section {
    var out: std.ArrayList(Section) = .empty;
    var current: ?Section = null;
    var body_start: usize = 0;
    var fence = false;
    var pos: usize = 0;
    while (pos < input.len) {
        const end = std.mem.indexOfScalarPos(u8, input, pos, '\n') orelse input.len;
        const line = std.mem.trimEnd(u8, input[pos..end], "\r");
        if (std.mem.startsWith(u8, line, "```")) fence = !fence;
        if (!fence) if (heading(line)) |h| {
            if (current) |*c| {
                c.body = input[body_start..pos];
                try out.append(a, c.*);
            }
            current = .{ .level = h.level, .title = h.title, .body = "" };
            body_start = @min(end + 1, input.len);
        };
        pos = end + 1;
    }
    if (fence) return invalid("unterminated code block", .{});
    if (current) |*c| {
        c.body = input[body_start..];
        try out.append(a, c.*);
    }
    return out.items;
}

fn heading(line: []const u8) ?struct { level: usize, title: []const u8 } {
    var level: usize = 0;
    while (level < line.len and line[level] == '#') level += 1;
    if (level == 0 or level == line.len or line[level] != ' ') return null;
    return .{ .level = level, .title = std.mem.trim(u8, line[level + 1 ..], " \t") };
}

/// Level-3 headings under `## Top-Level Fields` are the top-level fields, and level-4 headings
/// under `dependencies` are the fields of each dependency; the documentation of a field is the
/// content between its heading and the next heading
fn parseFields(a: Allocator, input: []const u8) !Fields {
    var top: std.ArrayList(Field) = .empty;
    var dep: std.ArrayList(Field) = .empty;
    var in_fields = false;
    var parent: ?[]const u8 = null;
    for (try sections(a, input)) |s| {
        if (s.level <= 2) {
            in_fields = s.level == 2 and eql(s.title, "Top-Level Fields");
            parent = null;
            continue;
        }
        if (!in_fields) return invalid("unexpected section outside the top-level fields: {s}", .{s.title});
        const name = fieldName(s.title) orelse return invalid("unexpected field heading: {s}", .{s.title});
        const field: Field = .{ .name = name, .doc = try document(a, name, s.body) };
        switch (s.level) {
            3 => {
                parent = name;
                try top.append(a, field);
            },
            4 => {
                const p = parent orelse "";
                if (!eql(p, "dependencies")) return invalid("unexpected field `{s}` nested under `{s}`", .{ name, p });
                try dep.append(a, field);
            },
            else => return invalid("unexpected heading level {d}: {s}", .{ s.level, s.title }),
        }
    }
    try expectNames(a, top.items, &top_level_fields, "top-level");
    try expectNames(a, dep.items, &dependency_fields, "dependency");
    return .{ .top_level = top.items, .dependency = dep.items };
}

fn fieldName(title: []const u8) ?[]const u8 {
    if (title.len < 3 or title[0] != '`' or title[title.len - 1] != '`') return null;
    const name = title[1 .. title.len - 1];
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    return name;
}

/// Trims trailing whitespace from each line, then leading and trailing blank lines
fn document(a: Allocator, name: []const u8, body: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        try out.appendSlice(a, std.mem.trimEnd(u8, line, " \t\r"));
        try out.append(a, '\n');
    }
    const doc = std.mem.trim(u8, out.items, "\n");
    if (doc.len == 0) return invalid("field `{s}` has no documentation", .{name});
    return doc;
}

fn expectNames(a: Allocator, fields: []const Field, expected: []const []const u8, what: []const u8) !void {
    const same = fields.len == expected.len and for (fields, expected) |f, e| {
        if (!eql(f.name, e)) break false;
    } else true;
    if (same) return;
    var got: Writer.Allocating = .init(a);
    for (fields, 0..) |f, i| try got.writer.print("{s}{s}", .{ if (i == 0) "" else ", ", f.name });
    return invalid("{s} fields do not match the schema in src/ide/manifest.zig: got {s}", .{ what, got.written() });
}

fn generate(a: Allocator, fields: Fields, metadata: Metadata) ![:0]const u8 {
    var out: Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll("//! Generated by tools/gen_manifest_data.zig from the official MIT-licensed Zig documentation.\n");
    try w.writeAll("//! Do not edit by hand.\n");
    try w.writeAll("//! Copyright and license: see tools/zig/LICENSE; pinned sources: see tools/zig/metadata.json.\n");
    try w.writeAll("const Field = @import(\"manifest.zig\").Field;\n");
    try w.print("pub const version = \"{f}\";\n", .{std.zig.fmtString(metadata.version)});
    try w.print("pub const build_zig_zon_sha256 = \"{f}\";\n", .{std.zig.fmtString(metadata.build_zig_zon_sha256)});
    inline for (.{ "top_level", "dependency" }) |name| {
        try w.print("pub const {s} = [_]Field{{\n", .{name});
        for (@field(fields, name)) |f| try w.print(".{{ .name = \"{f}\", .doc = \"{f}\" }},\n", .{ std.zig.fmtString(f.name), std.zig.fmtString(f.doc) });
        try w.writeAll("};\n");
    }
    return out.toOwnedSliceSentinel(0);
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 4) return invalid("usage: {s} <build.zig.zon.md> <metadata.json> <output path>", .{args[0]});
    const cwd = std.Io.Dir.cwd();
    const input = try cwd.readFileAlloc(init.io, args[1], a, .limited(256 * 1024));
    const metadata_bytes = try cwd.readFileAlloc(init.io, args[2], a, .limited(16 * 1024));
    const metadata = try std.json.parseFromSliceLeaky(Metadata, a, metadata_bytes, .{});
    try official.validateMetadata(a, metadata, @import("builtin").zig_version_string);
    try official.checkHash(input, metadata.build_zig_zon_sha256, "official build.zig.zon documentation");
    const source = try generate(a, try parseFields(a, input), metadata);
    var tree = try std.zig.Ast.parse(a, source, .{});
    if (tree.errors.len != 0) {
        var stderr = std.Io.File.stderr().writer(init.io, &.{});
        for (tree.errors) |err| {
            try tree.renderError(err, &stderr.interface);
            try stderr.interface.writeAll("\n");
        }
        return invalid("generated manifest documentation is not valid Zig", .{});
    }
    try cwd.writeFile(init.io, .{ .sub_path = args[3], .data = try tree.renderAlloc(a) });
}

test "official manifest documentation covers the schema fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const metadata = try std.json.parseFromSliceLeaky(Metadata, a, @embedFile("zig/metadata.json"), .{});
    const input = @embedFile("zig/build.zig.zon.md");
    try official.checkHash(input, metadata.build_zig_zon_sha256, "official build.zig.zon documentation");
    const fields = try parseFields(a, input);
    try std.testing.expect(std.mem.startsWith(u8, fields.top_level[0].doc, "Enum literal. Required.\n\nThis is the default name"));
    const deps = fields.top_level[4];
    try std.testing.expectEqualStrings("dependencies", deps.name);
    try std.testing.expect(std.mem.endsWith(u8, deps.doc, "Each dependency must either provide a `url` and `hash`, or a `path`."));
    // Trailing whitespace is trimmed (the official documentation has "String. ")
    try std.testing.expect(std.mem.startsWith(u8, fields.dependency[0].doc, "String.\n\nWhen updating this field"));
    try std.testing.expect(std.mem.endsWith(u8, fields.top_level[5].doc, "Only files included in the package are used to compute a package's `hash`."));
}

test "manifest documentation outside the schema is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deps = "### `dependencies`\n\nStruct.\n\n#### `url`\n\nU.\n\n#### `hash`\n\nH.\n\n#### `path`\n\nP.\n\n#### `lazy`\n\nL.\n\n";
    const valid = "# T\n\nIntro.\n\n## Top-Level Fields\n\n### `name`\n\nN.\n\n### `fingerprint`\n\nF.\n\n### `version`\n\nV.\n\n" ++
        "### `minimum_zig_version`\n\nM.\n\n" ++ deps ++ "### `paths`\n\n```sh\n# not a heading\n```\n";
    const fields = try parseFields(a, valid);
    try std.testing.expectEqualStrings("```sh\n# not a heading\n```", fields.top_level[5].doc);
    try std.testing.expectEqualStrings("L.", fields.dependency[3].doc);
    // An extra field, a misplaced nested field, a missing field, empty documentation
    try std.testing.expectError(error.InvalidOfficialSource, parseFields(a, valid ++ "### `extra`\n\nE.\n"));
    try std.testing.expectError(error.InvalidOfficialSource, parseFields(a, "## Top-Level Fields\n\n### `name`\n\nN.\n\n#### `url`\n\nU.\n"));
    try std.testing.expectError(error.InvalidOfficialSource, parseFields(a, "## Top-Level Fields\n\n### `name`\n\nN.\n"));
    try std.testing.expectError(error.InvalidOfficialSource, parseFields(a, "## Top-Level Fields\n\n### `name`\n\n### `version`\n\nV.\n"));
    try std.testing.expectError(error.InvalidOfficialSource, parseFields(a, "## Top-Level Fields\n\n```\n### `name`\n"));
}
