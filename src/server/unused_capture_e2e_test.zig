//! End-to-end: fixing unused captures (removing the capture or renaming it to `_`). After the fix
//! for each form of capture is applied in turn, the file has no diagnostics and the project still
//! builds (Sema accepts the rewritten conditions and captures as well).

const std = @import("std");
const testing = std.testing;
const za = @import("../zig_analyzer.zig");
const fixture = za.project.fixture;
const Harness = @import("test_harness.zig").Harness;

const Empty = struct {};
/// Code action literal support, without which no code actions are returned (each carries an edit)
const literal_actions = .{ .codeAction = .{ .codeActionLiteralSupport = .{ .codeActionKind = .{ .valueSet = &[_][]const u8{ "quickfix", "refactor", "source" } } } } };

fn position(text: []const u8, needle: []const u8) struct { line: u32, character: u32 } {
    const offset = std.mem.indexOf(u8, text, needle).?;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..offset], '\n')) |i| i + 1 else 0;
    return .{ .line = @intCast(std.mem.count(u8, text[0..offset], "\n")), .character = @intCast(offset - line_start) };
}

/// Number of diagnostics with source `source` (any source when null) last published for the file
fn diagnosticCount(h: *Harness, name: []const u8, source: ?[]const u8) !usize {
    var last: ?[]const std.json.Value = null;
    for (try h.notifications("textDocument/publishDiagnostics")) |m| {
        const params = m.object.get("params").?.object;
        if (std.mem.endsWith(u8, params.get("uri").?.string, name)) last = params.get("diagnostics").?.array.items;
    }
    var n: usize = 0;
    for (last orelse return 0) |d| {
        if (source == null or std.mem.eql(u8, d.object.get("source").?.string, source.?)) n += 1;
    }
    return n;
}

fn codeActions(h: *Harness, uri: []const u8, text: []const u8, needle: []const u8) ![]const std.json.Value {
    const p = position(text, needle);
    const resp = try h.request("textDocument/codeAction", .{
        .textDocument = .{ .uri = uri },
        .range = .{ .start = p, .end = p },
        .context = .{ .diagnostics = &[_]Empty{} },
    });
    return resp.object.get("result").?.array.items;
}

/// The code action whose title starts with `prefix`
fn actionWithTitle(actions: []const std.json.Value, prefix: []const u8) ?std.json.Value {
    for (actions) |x| if (std.mem.startsWith(u8, x.object.get("title").?.string, prefix)) return x;
    return null;
}

/// Applies the edits for `uri` in a WorkspaceEdit to the text
fn applyEdit(a: std.mem.Allocator, text: []const u8, edit: std.json.Value, uri: []const u8) ![]const u8 {
    const edits = edit.object.get("changes").?.object.get(uri).?.array.items;
    const Span = struct { start: usize, end: usize, text: []const u8 };
    var spans: std.ArrayList(Span) = .empty;
    for (edits) |e| {
        const range = e.object.get("range").?.object;
        try spans.append(a, .{ .start = offsetOf(text, range.get("start").?), .end = offsetOf(text, range.get("end").?), .text = e.object.get("newText").?.string });
    }
    std.mem.sort(Span, spans.items, {}, struct {
        fn lt(_: void, x: Span, y: Span) bool {
            return x.start < y.start;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    for (spans.items) |sp| {
        try out.appendSlice(a, text[pos..sp.start]);
        try out.appendSlice(a, sp.text);
        pos = sp.end;
    }
    try out.appendSlice(a, text[pos..]);
    return out.items;
}

fn offsetOf(text: []const u8, pos: std.json.Value) usize {
    var line: i64 = 0;
    var i: usize = 0;
    while (line < pos.object.get("line").?.integer) : (i += 1) {
        if (text[i] == '\n') line += 1;
    }
    return i + @as(usize, @intCast(pos.object.get("character").?.integer));
}

const lib_text =
    \\pub const U = union(enum) { a: u32, b: u8 };
    \\fn next(i: *u32) ?u32 {
    \\    i.* += 1;
    \\    return if (i.* < 3) i.* else null;
    \\}
    \\fn nextErr(i: *u32) error{End}!u32 {
    \\    i.* += 1;
    \\    if (i.* > 3) return error.End;
    \\    return i.*;
    \\}
    \\fn fail(fails: bool) !u32 {
    \\    if (fails) return error.Failed;
    \\    return 1;
    \\}
    \\pub fn run(o: ?u32, e: anyerror!u32, xs: []const u32, u: U) u32 {
    \\    var n: u32 = 0;
    \\    var po = o;
    \\    if (o) |v1| n += 1;
    \\    if (po) |*v2| {
    \\        n += 1;
    \\    }
    \\    if (o orelse po) |v3| n += 1;
    \\    if (e) |v4| n += 1 else |err| n += @intFromError(err);
    \\    if (e) |v| n += v else |err1| n += 1;
    \\    var i: u32 = 0;
    \\    while (next(&i)) |v5| : (n += 1) {}
    \\    i = 0;
    \\    while (nextErr(&i)) |v6| {} else |err2| {}
    \\    n += fail(false) catch |err3| 0;
    \\    for (xs, 0..) |x, k1| n += x;
    \\    for (0.., xs) |k2, x| n += x;
    \\    for (xs) |x1| n += 1;
    \\    for (xs, 0..xs.len) |x, k3| n += x;
    \\    for (0..n) |k4| {}
    \\    switch (u) {
    \\        .a => |p1| {},
    \\        .b => {},
    \\    }
    \\    switch (u) {
    \\        inline else => |p2, tag1| n += @sizeOf(@TypeOf(p2)),
    \\    }
    \\    switch (u) {
    \\        inline else => |_, tag2| {},
    \\    }
    \\    switch (u) {
    \\        inline else => |p3, tag3| n += @intFromEnum(tag3),
    \\    }
    \\    po = null;
    \\    return n;
    \\}
    \\
;
const main_text =
    \\const lib = @import("lib");
    \\pub fn main() void {
    \\    _ = lib.run(1, 2, &.{ 1, 2 }, .{ .a = 1 });
    \\}
    \\
;

test "unused captures: every fix leaves no diagnostics and the project still builds" {
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = fixture.basic[0].text },
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/lib.zig", .text = lib_text },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = .{ .textDocument = literal_actions } });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(a, try project.path(a, "src/lib.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = lib_text } });
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = uri } });
    _ = try h.request("zig-analyzer/waitIdle", {});

    // With a block body, the discard is preferred; otherwise no discard can be inserted and
    // removing the capture is preferred
    {
        const actions = try codeActions(&h, uri, lib_text, "v2|");
        try testing.expect(actionWithTitle(actions, "discard `v2`").?.object.get("isPreferred").?.bool);
        try testing.expectEqual(null, actionWithTitle(actions, "remove capture `v2`").?.object.get("isPreferred"));
        const only = try codeActions(&h, uri, lib_text, "v1|");
        try testing.expectEqual(null, actionWithTitle(only, "discard"));
        try testing.expect(actionWithTitle(only, "remove capture `v1`").?.object.get("isPreferred").?.bool);
    }

    const fixes = [_]struct { []const u8, []const u8 }{
        .{ "v1|", "remove capture `v1`" },
        .{ "v2|", "remove capture `v2`" },
        .{ "v3|", "remove capture `v3`" },
        .{ "v4|", "rename `v4` to `_`" },
        .{ "err1|", "rename `err1` to `_`" },
        .{ "v5|", "remove capture `v5`" },
        .{ "v6|", "rename `v6` to `_`" },
        .{ "err2|", "rename `err2` to `_`" },
        .{ "err3|", "remove capture `err3`" },
        .{ "k1|", "remove capture `k1`" },
        .{ "k2,", "remove capture `k2`" },
        .{ "x1|", "rename `x1` to `_`" },
        .{ "k3|", "rename `k3` to `_`" },
        .{ "k4|", "rename `k4` to `_`" },
        .{ "p1|", "remove capture `p1`" },
        .{ "tag1|", "remove capture `tag1`" },
        .{ "tag2|", "remove capture `tag2`" },
        .{ "p3,", "rename `p3` to `_`" },
    };
    // The compiler reports one error for each capture
    try testing.expectEqual(fixes.len, try diagnosticCount(&h, "lib.zig", "zig"));
    var text: []const u8 = lib_text;
    for (fixes, 2..) |f, version| {
        const action = actionWithTitle(try codeActions(&h, uri, text, f[0]), f[1]) orelse {
            std.debug.print("no code action `{s}` at `{s}`\n", .{ f[1], f[0] });
            return error.TestUnexpectedResult;
        };
        text = try applyEdit(a, text, action.object.get("edit").?, uri);
        try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = @as(i64, @intCast(version)) }, .contentChanges = &.{.{ .text = text }} });
        _ = try h.request("zig-analyzer/waitIdle", {});
    }
    try testing.expectEqualStrings(
        \\pub const U = union(enum) { a: u32, b: u8 };
        \\fn next(i: *u32) ?u32 {
        \\    i.* += 1;
        \\    return if (i.* < 3) i.* else null;
        \\}
        \\fn nextErr(i: *u32) error{End}!u32 {
        \\    i.* += 1;
        \\    if (i.* > 3) return error.End;
        \\    return i.*;
        \\}
        \\fn fail(fails: bool) !u32 {
        \\    if (fails) return error.Failed;
        \\    return 1;
        \\}
        \\pub fn run(o: ?u32, e: anyerror!u32, xs: []const u32, u: U) u32 {
        \\    var n: u32 = 0;
        \\    var po = o;
        \\    if (o != null) n += 1;
        \\    if (po != null) {
        \\        n += 1;
        \\    }
        \\    if ((o orelse po) != null) n += 1;
        \\    if (e) |_| n += 1 else |err| n += @intFromError(err);
        \\    if (e) |v| n += v else |_| n += 1;
        \\    var i: u32 = 0;
        \\    while (next(&i) != null) : (n += 1) {}
        \\    i = 0;
        \\    while (nextErr(&i)) |_| {} else |_| {}
        \\    n += fail(false) catch 0;
        \\    for (xs) |x| n += x;
        \\    for (xs) |x| n += x;
        \\    for (xs) |_| n += 1;
        \\    for (xs, 0..xs.len) |x, _| n += x;
        \\    for (0..n) |_| {}
        \\    switch (u) {
        \\        .a => {},
        \\        .b => {},
        \\    }
        \\    switch (u) {
        \\        inline else => |p2| n += @sizeOf(@TypeOf(p2)),
        \\    }
        \\    switch (u) {
        \\        inline else => {},
        \\    }
        \\    switch (u) {
        \\        inline else => |_, tag3| n += @intFromEnum(tag3),
        \\    }
        \\    po = null;
        \\    return n;
        \\}
        \\
    , text);
    try testing.expectEqual(0, try diagnosticCount(&h, "lib.zig", null));

    // Save the modified file: the project still builds
    try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "src/lib.zig", .data = text });
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = uri } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(0, try diagnosticCount(&h, "lib.zig", null));
    try testing.expectEqual(0, try diagnosticCount(&h, "main.zig", null));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}
