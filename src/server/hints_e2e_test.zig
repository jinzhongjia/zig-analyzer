//! End-to-end: unused-declaration hints (opt-in, updated after edits) and suppression comments,
//! which remove analyzer-owned hints but never compiler diagnostics.

const std = @import("std");
const testing = std.testing;
const za = @import("../zig_analyzer.zig");
const fixture = za.project.fixture;
const Harness = @import("test_harness.zig").Harness;

const Empty = struct {};
/// A non-empty client capability object: an empty one serializes as `[]`
const literal_actions = .{ .codeAction = .{ .codeActionLiteralSupport = .{ .codeActionKind = .{ .valueSet = &[_][]const u8{ "quickfix", "refactor", "source" } } } } };

fn jsonValue(h: *Harness, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), text, .{});
}

/// Diagnostics last published for a file
fn lastDiagnostics(h: *Harness, name: []const u8) ![]const std.json.Value {
    var last: ?[]const std.json.Value = null;
    for (try h.notifications("textDocument/publishDiagnostics")) |m| {
        const params = m.object.get("params").?.object;
        if (std.mem.endsWith(u8, params.get("uri").?.string, name)) last = params.get("diagnostics").?.array.items;
    }
    return last orelse error.NotPublished;
}

/// Analyzer-owned hints last published for a file: "line:character code message"
fn hints(h: *Harness, name: []const u8) ![]const u8 {
    const a = h.arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    for (try lastDiagnostics(h, name)) |d| {
        const source = d.object.get("source") orelse continue;
        if (!std.mem.eql(u8, source.string, "zig-analyzer")) continue;
        const code = d.object.get("code") orelse continue;
        const start = d.object.get("range").?.object.get("start").?.object;
        try out.print(a, "{d}:{d} {s} {s}\n", .{
            start.get("line").?.integer,
            start.get("character").?.integer,
            code.string,
            d.object.get("message").?.string,
        });
    }
    return out.items;
}

fn compilerDiagnostics(h: *Harness, name: []const u8) !usize {
    var n: usize = 0;
    for (try lastDiagnostics(h, name)) |d| {
        const source = d.object.get("source") orelse continue;
        if (!std.mem.startsWith(u8, source.string, "zig")) continue;
        if (std.mem.eql(u8, source.string, "zig-analyzer")) continue;
        n += 1;
    }
    return n;
}

fn initialize(project: *fixture.Project, h: *Harness, settings: []const u8) !void {
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{
        .rootUri = root_uri,
        .capabilities = .{ .textDocument = literal_actions },
        .initializationOptions = try jsonValue(h, settings),
    });
    try h.notify("initialized", Empty{});
}

fn open(h: *Harness, project: *fixture.Project, name: []const u8, text: []const u8) ![]const u8 {
    const uri = try za.base.uri.fromPath(h.arena.allocator(), try project.path(h.arena.allocator(), name));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    return uri;
}

fn publishCount(h: *Harness, name: []const u8) !usize {
    var n: usize = 0;
    for (try h.notifications("textDocument/publishDiagnostics")) |m| {
        if (std.mem.endsWith(u8, m.object.get("params").?.object.get("uri").?.string, name)) n += 1;
    }
    return n;
}

/// Reads messages until a diagnostics notification for the file arrives after the `before`-th
fn waitPublish(h: *Harness, name: []const u8, before: usize) !void {
    while (try publishCount(h, name) <= before) _ = try h.next();
}

fn change(h: *Harness, uri: []const u8, version: i64, text: []const u8) !void {
    const before = try publishCount(h, "main.zig");
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .text = text }} });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try waitPublish(h, "main.zig", before);
}

const base = "{\"build\": {\"enable\": false}, \"diagnostics\": {\"compiler\": false}}";
const unused_on = "{\"build\": {\"enable\": false}, \"diagnostics\": {\"compiler\": false}, \"unused\": {\"enable\": true}}";

test "unused hints are opt-in and suppression comments remove them" {
    const text =
        \\const unused_const = 1;
        \\fn unusedFn() void {}
        \\fn helper() void {}
        \\pub fn run() void {
        \\    helper();
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{.{ .path = "main.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initialize(&project, &h, base);
    const before_open = try publishCount(&h, "main.zig");
    const uri = try open(&h, &project, "main.zig", text);
    try waitPublish(&h, "main.zig", before_open);
    // Off by default
    try testing.expectEqualStrings("", try hints(&h, "main.zig"));

    const before_config = try publishCount(&h, "main.zig");
    try h.notify("workspace/didChangeConfiguration", .{ .settings = try jsonValue(&h, unused_on) });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try waitPublish(&h, "main.zig", before_config);
    try testing.expectEqualStrings(
        \\0:6 unused.declaration declaration `unused_const` is never used
        \\1:3 unused.declaration declaration `unusedFn` is never used
        \\
    , try hints(&h, "main.zig"));
    // Low-severity hints, faded by the editor
    for (try lastDiagnostics(&h, "main.zig")) |d| {
        try testing.expectEqual(4, d.object.get("severity").?.integer);
        try testing.expectEqual(1, d.object.get("tags").?.array.items[0].integer);
    }

    // The next line with code is suppressed
    const edited = try std.mem.replaceOwned(u8, a, text, "fn unusedFn", "// zig-analyzer-disable-next-line: unused\nfn unusedFn");
    try change(&h, uri, 2, edited);
    try testing.expectEqualStrings(
        \\0:6 unused.declaration declaration `unused_const` is never used
        \\
    , try hints(&h, "main.zig"));

    // A range suppresses the whole family
    const edited2 = try std.mem.replaceOwned(u8, a, edited, "const unused_const", "// zig-analyzer-disable: unused\nconst unused_const");
    try change(&h, uri, 3, edited2);
    try testing.expectEqualStrings("", try hints(&h, "main.zig"));

    // Enabling ends the range, while the suppressed declaration stays inside it
    const edited3 = try std.mem.replaceOwned(u8, a, edited2, "// zig-analyzer-disable-next-line: unused\nfn unusedFn", "// zig-analyzer-enable: unused\nfn unusedFn");
    try change(&h, uri, 4, edited3);
    try testing.expectEqualStrings(
        \\3:3 unused.declaration declaration `unusedFn` is never used
        \\
    , try hints(&h, "main.zig"));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "inactive code is a hint with a code, and can be suppressed" {
    const text =
        \\const linux_only = true;
        \\fn f() void {
        \\    if (linux_only) return;
        \\    const dead = 1;
        \\    _ = dead;
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{.{ .path = "main.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initialize(&project, &h, "{\"build\": {\"enable\": false}, \"diagnostics\": {\"compiler\": false, \"inactive_code\": true}}");
    const uri = try open(&h, &project, "main.zig", text);
    try testing.expectEqualStrings(
        \\3:4 inactive code is inactive: a comptime condition excludes it under the current build configuration
        \\
    , try hints(&h, "main.zig"));

    const edited = try std.mem.replaceOwned(u8, a, text, "    const dead", "    // zig-analyzer-disable-next-line: inactive\n    const dead");
    try change(&h, uri, 2, edited);
    try testing.expectEqualStrings("", try hints(&h, "main.zig"));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "suppression comments do not remove compiler diagnostics" {
    const text =
        \\// zig-analyzer-disable
        \\const broken = ;
        \\
    ;
    var project = try fixture.Project.create(&.{.{ .path = "main.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&project, &h, base);
    const before = try publishCount(&h, "main.zig");
    _ = try open(&h, &project, "main.zig", text);
    try waitPublish(&h, "main.zig", before);
    // A live syntax error is still published: its source is not `zig-analyzer`
    try testing.expect(try compilerDiagnostics(&h, "main.zig") > 0);
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}
