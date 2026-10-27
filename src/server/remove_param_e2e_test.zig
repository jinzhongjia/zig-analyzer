//! End-to-end: removing an unused parameter (finding call sites in `codeAction/resolve`, removing
//! arguments across files, the confirmation annotation for public functions, the reason when a
//! parameter cannot be removed, computing the edit at once for clients without resolve support,
//! and the project still building after the edits are applied).

const std = @import("std");
const testing = std.testing;
const za = @import("../zig_analyzer.zig");
const fixture = za.project.fixture;
const Harness = @import("test_harness.zig").Harness;

const Empty = struct {};

fn jsonValue(h: *Harness, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), text, .{});
}

fn position(text: []const u8, needle: []const u8) struct { line: u32, character: u32 } {
    const offset = std.mem.indexOf(u8, text, needle).?;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..offset], '\n')) |i| i + 1 else 0;
    return .{ .line = @intCast(std.mem.count(u8, text[0..offset], "\n")), .character = @intCast(offset - line_start) };
}

/// Number of compiler diagnostics (whose source is zig) last published for the file
fn compilerErrors(h: *Harness, name: []const u8) !usize {
    var last: ?[]const std.json.Value = null;
    for (try h.notifications("textDocument/publishDiagnostics")) |m| {
        const params = m.object.get("params").?.object;
        if (std.mem.endsWith(u8, params.get("uri").?.string, name)) last = params.get("diagnostics").?.array.items;
    }
    var n: usize = 0;
    for (last orelse return 0) |d| {
        if (std.mem.eql(u8, d.object.get("source").?.string, "zig")) n += 1;
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

/// Applies a WorkspaceEdit (`changes` or `documentChanges`) to `texts` (URI → text) and returns
/// the number of URIs changed
fn applyEdit(h: *Harness, texts: *std.StringArrayHashMapUnmanaged([]const u8), edit: std.json.Value) !usize {
    const a = h.arena.allocator();
    const Doc = struct { uri: []const u8, edits: []const std.json.Value };
    var docs: std.ArrayList(Doc) = .empty;
    if (edit.object.get("changes")) |changes| {
        var it = changes.object.iterator();
        while (it.next()) |kv| try docs.append(a, .{ .uri = kv.key_ptr.*, .edits = kv.value_ptr.array.items });
    }
    if (edit.object.get("documentChanges")) |changes| for (changes.array.items) |c| {
        try docs.append(a, .{ .uri = c.object.get("textDocument").?.object.get("uri").?.string, .edits = c.object.get("edits").?.array.items });
    };
    for (docs.items) |doc| {
        const old = texts.get(doc.uri).?;
        const Span = struct { start: usize, end: usize, text: []const u8 };
        var spans: std.ArrayList(Span) = .empty;
        for (doc.edits) |e| {
            const range = e.object.get("range").?.object;
            try spans.append(a, .{ .start = offsetOf(old, range.get("start").?), .end = offsetOf(old, range.get("end").?), .text = e.object.get("newText").?.string });
        }
        std.mem.sort(Span, spans.items, {}, struct {
            fn lt(_: void, x: Span, y: Span) bool {
                return x.start < y.start;
            }
        }.lt);
        var out: std.ArrayList(u8) = .empty;
        var pos: usize = 0;
        for (spans.items) |sp| {
            try out.appendSlice(a, old[pos..sp.start]);
            try out.appendSlice(a, sp.text);
            pos = sp.end;
        }
        try out.appendSlice(a, old[pos..]);
        try texts.put(a, doc.uri, out.items);
    }
    return docs.items.len;
}

fn offsetOf(text: []const u8, pos: std.json.Value) usize {
    var line: i64 = 0;
    var i: usize = 0;
    while (line < pos.object.get("line").?.integer) : (i += 1) {
        if (text[i] == '\n') line += 1;
    }
    return i + @as(usize, @intCast(pos.object.get("character").?.integer));
}

/// Sends the texts in `texts` to the server (the editor has applied the edits)
fn sync(h: *Harness, texts: *const std.StringArrayHashMapUnmanaged([]const u8), version: i64) !void {
    for (texts.keys(), texts.values()) |u, text| {
        try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = u, .version = version }, .contentChanges = &.{.{ .text = text }} });
    }
    _ = try h.request("zig-analyzer/waitIdle", {});
}

const lib_text =
    \\pub fn scale(x: u32, factor: u32) u32 {
    \\    return x * 2;
    \\}
    \\pub const Counter = struct {
    \\    n: u32,
    \\    fn add(self: *Counter, by: u32, note: []const u8) void {
    \\        self.n += by;
    \\    }
    \\    pub fn bump(self: *Counter) void {
    \\        self.add(1, "one");
    \\    }
    \\};
    \\pub fn handler(a: u32, b: u32) u32 {
    \\    return a;
    \\}
    \\pub const table = [_]*const fn (u32, u32) u32{&handler};
    \\
;
const main_text =
    \\const lib = @import("lib");
    \\pub fn main() void {
    \\    var c: lib.Counter = .{ .n = 0 };
    \\    c.bump();
    \\    _ = lib.scale(1, 2) + lib.scale(
    \\        3,
    \\        4,
    \\    );
    \\    _ = lib.table;
    \\}
    \\
;

test "remove parameter: resolve, calls in other files, refusals and the project still builds" {
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
    _ = try h.request("initialize", .{
        .rootUri = root_uri,
        .capabilities = .{
            .textDocument = .{ .codeAction = .{ .dataSupport = true, .disabledSupport = true, .resolveSupport = .{ .properties = &[_][]const u8{"edit"} } } },
            .workspace = .{ .workspaceEdit = .{ .documentChanges = true, .changeAnnotationSupport = Empty{} } },
        },
    });
    try h.notify("initialized", Empty{});
    const lib_uri = try za.base.uri.fromPath(a, try project.path(a, "src/lib.zig"));
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = lib_uri, .languageId = "zig", .version = 1, .text = lib_text } });
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = main_uri, .languageId = "zig", .version = 1, .text = main_text } });
    _ = try h.request("zig-analyzer/waitIdle", {});

    var texts: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try texts.put(a, lib_uri, lib_text);
    try texts.put(a, main_uri, main_text);

    // A function used as a function pointer: refused with the reason; discarding is still the
    // preferred fix
    {
        const actions = try codeActions(&h, lib_uri, lib_text, "b: u32) u32 {");
        try testing.expect(actionWithTitle(actions, "discard `b`").?.object.get("isPreferred").?.bool);
        const fix = actionWithTitle(actions, "remove parameter `b`").?;
        try testing.expectEqual(null, fix.object.get("isPreferred"));
        try testing.expectEqual(null, fix.object.get("edit"));
        const resp = try h.request("codeAction/resolve", fix);
        const message = resp.object.get("error").?.object.get("message").?.string;
        const at = position(lib_text, "handler}");
        try testing.expectEqualStrings(try std.fmt.allocPrint(a, "cannot remove parameter `b`: the function is used here other than in a call, so this use cannot be updated (src/lib.zig:{d}:{d})", .{ at.line + 1, at.character + 1 }), message);
        try testing.expectEqual(1, try applyEdit(&h, &texts, actionWithTitle(actions, "discard `b`").?.object.get("edit").?));
        try sync(&h, &texts, 2);
    }
    // A public function: the arguments at call sites in other files are removed, and the edit
    // carries an annotation that needs confirmation
    {
        const fix = actionWithTitle(try codeActions(&h, lib_uri, texts.get(lib_uri).?, "factor"), "remove parameter `factor`").?;
        // Call sites are looked up only after the action is selected
        try testing.expectEqual(null, fix.object.get("edit"));
        const resp = try h.request("codeAction/resolve", fix);
        const edit = resp.object.get("result").?.object.get("edit").?;
        const annotation = edit.object.get("changeAnnotations").?.object.get("zig-analyzer.remove-param-public").?.object;
        try testing.expect(annotation.get("needsConfirmation").?.bool);
        try testing.expectEqualStrings("Remove parameter `factor` of public `scale`", annotation.get("label").?.string);
        try testing.expectEqual(2, try applyEdit(&h, &texts, edit));
        try sync(&h, &texts, 3);
    }
    // A method: in calls of the form `x.f()` the receiver is not an argument; for a function that
    // is not public, only its own file is edited
    {
        const fix = actionWithTitle(try codeActions(&h, lib_uri, texts.get(lib_uri).?, "note"), "remove parameter `note`").?;
        const resp = try h.request("codeAction/resolve", fix);
        const edit = resp.object.get("result").?.object.get("edit").?;
        try testing.expectEqual(null, edit.object.get("changeAnnotations"));
        try testing.expectEqual(1, try applyEdit(&h, &texts, edit));
    }
    try testing.expectEqualStrings(
        \\pub fn scale(x: u32) u32 {
        \\    return x * 2;
        \\}
        \\pub const Counter = struct {
        \\    n: u32,
        \\    fn add(self: *Counter, by: u32) void {
        \\        self.n += by;
        \\    }
        \\    pub fn bump(self: *Counter) void {
        \\        self.add(1);
        \\    }
        \\};
        \\pub fn handler(a: u32, b: u32) u32 {
        \\    _ = b;
        \\    return a;
        \\}
        \\pub const table = [_]*const fn (u32, u32) u32{&handler};
        \\
    , texts.get(lib_uri).?);
    try testing.expectEqualStrings(
        \\const lib = @import("lib");
        \\pub fn main() void {
        \\    var c: lib.Counter = .{ .n = 0 };
        \\    c.bump();
        \\    _ = lib.scale(1) + lib.scale(
        \\        3,
        \\    );
        \\    _ = lib.table;
        \\}
        \\
    , texts.get(main_uri).?);

    // Save the modified files: the project still builds
    for ([_][]const u8{ "src/lib.zig", "src/main.zig" }, [_][]const u8{ lib_uri, main_uri }) |path, u| {
        const text = texts.get(u).?;
        try project.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = text });
        try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = u, .version = 4 }, .contentChanges = &.{.{ .text = text }} });
        try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = u } });
    }
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(0, try compilerErrors(&h, "lib.zig"));
    try testing.expectEqual(0, try compilerErrors(&h, "main.zig"));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

const single_text =
    \\fn area(w: u32, h: u32, unit: []const u8) u32 {
    \\    return w * h;
    \\}
    \\fn pick(n: u32, skip: bool) u32 {
    \\    return n;
    \\}
    \\pub fn main() void {
    \\    _ = area(2, 3, "m");
    \\    _ = pick(1, true);
    \\    const p = &pick;
    \\    _ = p;
    \\}
    \\
;

test "remove parameter: clients without resolve support get the edit at once" {
    var project = try fixture.Project.create(&.{.{ .path = "main.zig", .text = single_text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{}, .initializationOptions = try jsonValue(&h,
        \\{"build": {"enable": false}, "diagnostics": {"compiler": false, "inactive_code": false}}
    ) });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = single_text } });
    _ = try h.request("zig-analyzer/waitIdle", {});

    const fix = actionWithTitle(try codeActions(&h, uri, single_text, "unit"), "remove parameter `unit`").?;
    try testing.expectEqual(null, fix.object.get("data"));
    var texts: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try texts.put(a, uri, single_text);
    try testing.expectEqual(1, try applyEdit(&h, &texts, fix.object.get("edit").?));
    try testing.expect(std.mem.indexOf(u8, texts.get(uri).?, "fn area(w: u32, h: u32) u32 {") != null);
    try testing.expect(std.mem.indexOf(u8, texts.get(uri).?, "_ = area(2, 3);") != null);
    // Cannot be removed, and the client does not support `disabled` either: not offered
    try testing.expectEqual(null, actionWithTitle(try codeActions(&h, uri, single_text, "skip"), "remove parameter"));
    try testing.expect(actionWithTitle(try codeActions(&h, uri, single_text, "skip"), "discard `skip`") != null);
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}
