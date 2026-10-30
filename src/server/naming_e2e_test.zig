//! End-to-end: naming check hints (on/off switch, exceptions, project configuration, updates after
//! edits) and rename fixes (`codeAction/resolve`, conflicts and references that cannot be
//! confirmed, the confirmation annotation for public names, and the project still building after
//! they are applied).

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

/// Naming hints last published for a file (last segment of the URI): "line:column code message"
fn namingHints(h: *Harness, name: []const u8) ![]const u8 {
    const a = h.arena.allocator();
    var last: ?[]const std.json.Value = null;
    for (try h.notifications("textDocument/publishDiagnostics")) |m| {
        const params = m.object.get("params").?.object;
        const uri = params.get("uri").?.string;
        if (std.mem.endsWith(u8, uri, name)) last = params.get("diagnostics").?.array.items;
    }
    var out: std.ArrayList(u8) = .empty;
    for (last orelse return error.NotPublished) |d| {
        const code = d.object.get("code") orelse continue;
        if (!std.mem.startsWith(u8, code.string, "naming.")) continue;
        const start = d.object.get("range").?.object.get("start").?.object;
        try out.print(a, "{d}:{d} {s} {s}\n", .{ start.get("line").?.integer, start.get("character").?.integer, code.string, d.object.get("message").?.string });
    }
    return out.items;
}

/// Number of compiler diagnostics (source zig) last published for a file
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

/// Code action whose title starts with `prefix`
fn actionWithTitle(actions: []const std.json.Value, prefix: []const u8) ?std.json.Value {
    for (actions) |x| if (std.mem.startsWith(u8, x.object.get("title").?.string, prefix)) return x;
    return null;
}

/// Applies a WorkspaceEdit (`changes` or `documentChanges`) to `texts` (URI -> text) and returns
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

const sample =
    \\const packet_type = struct { value: u32 };
    \\fn MakePacket() packet_type { return .{ .value = 1 }; }
    \\fn packetFactory(comptime T: type) type { return struct { value: T }; }
    \\const FactoryAlias = packetFactory;
    \\const Empty = struct {};
    \\pub fn main() void {
    \\    const localValue = MakePacket();
    \\    const marker: Empty = .{};
    \\    _ = localValue;
    \\    _ = marker;
    \\    _ = packetFactory(u32);
    \\    _ = FactoryAlias(u8);
    \\}
    \\
;

test "naming hints are opt-in and follow settings and edits" {
    var project = try fixture.Project.create(&.{.{ .path = "main.zig", .text = sample }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    const base_settings =
        \\"build": {"enable": false}, "diagnostics": {"compiler": false, "inactive_code": false}
    ;
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{}, .initializationOptions = try jsonValue(&h, "{" ++ base_settings ++ "}") });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = sample } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    // Off by default, and no fixes either
    try testing.expectEqualStrings("", try namingHints(&h, "main.zig"));
    try testing.expectEqual(null, actionWithTitle(try codeActions(&h, uri, sample, "localValue ="), "rename"));

    try h.notify("workspace/didChangeConfiguration", .{ .settings = try jsonValue(&h, "{" ++ base_settings ++ ", \"naming\": {\"enable\": true}}") });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings(
        \\0:6 naming.type `packet_type` is a type and should be TitleCase: `PacketType`
        \\1:3 naming.function `MakePacket` is a function and should be camelCase: `makePacket`
        \\2:3 naming.type_function `packetFactory` returns a type and should be TitleCase: `PacketFactory`
        \\6:10 naming.value `localValue` should be snake_case: `local_value`
        \\
    , try namingHints(&h, "main.zig"));
    // Low-severity hints with a link to the official rules
    for ((try h.notifications("textDocument/publishDiagnostics"))[0..]) |m| {
        for (m.object.get("params").?.object.get("diagnostics").?.array.items) |d| {
            try testing.expectEqual(4, d.object.get("severity").?.integer);
            try testing.expectEqualStrings(za.ide.naming.guide_url, d.object.get("codeDescription").?.object.get("href").?.string);
        }
    }

    // The client does not support `codeAction/resolve`: the edit is computed on the spot
    {
        const actions = try codeActions(&h, uri, sample, "localValue =");
        const fix = actionWithTitle(actions, "rename `localValue` to `local_value`").?;
        try testing.expectEqual(null, fix.object.get("isPreferred"));
        var texts: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        try texts.put(a, uri, sample);
        try testing.expectEqual(1, try applyEdit(&h, &texts, fix.object.get("edit").?));
        try testing.expect(std.mem.indexOf(u8, texts.get(uri).?, "const local_value = MakePacket();\n    const marker: Empty = .{};\n    _ = local_value;") != null);
    }

    // Exceptions for names and rules
    try h.notify("workspace/didChangeConfiguration", .{ .settings = try jsonValue(&h, "{" ++ base_settings ++
        \\, "naming": {"enable": true, "ignore": ["Make*"], "rules": {"value": false}}}
    ) });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings(
        \\0:6 naming.type `packet_type` is a type and should be TitleCase: `PacketType`
        \\2:3 naming.type_function `packetFactory` returns a type and should be TitleCase: `PacketFactory`
        \\
    , try namingHints(&h, "main.zig"));

    // Updated after edits
    const edited = try std.mem.replaceOwned(u8, a, sample, "packet_type", "PacketType");
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = 2 }, .contentChanges = &.{.{ .text = edited }} });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings(
        \\2:3 naming.type_function `packetFactory` returns a type and should be TitleCase: `PacketFactory`
        \\
    , try namingHints(&h, "main.zig"));

    // Turn it off
    try h.notify("workspace/didChangeConfiguration", .{ .settings = try jsonValue(&h, "{" ++ base_settings ++ "}") });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("", try namingHints(&h, "main.zig"));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

const lib_text =
    \\const packet_type = struct { value: u32 };
    \\pub fn MakePacket() packet_type {
    \\    return .{ .value = 1 };
    \\}
    \\pub fn MakeThing() void {}
    \\fn makeThing() void {}
    \\pub const Shape = struct { FieldName: u32 };
    \\pub fn readField(p: anytype) u32 {
    \\    return p.FieldName;
    \\}
    \\test {
    \\    makeThing();
    \\    MakeThing();
    \\}
    \\
;
const main_text =
    \\const lib = @import("lib");
    \\pub fn main() void {
    \\    const packet = lib.MakePacket();
    \\    _ = packet.value;
    \\}
    \\
;
const gen_text =
    \\const not_checked = struct { x: u32 };
    \\
;

test "naming fixes: resolve, conflicts, public names and the project still builds" {
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = fixture.basic[0].text },
        .{ .path = "src/main.zig", .text = main_text },
        .{ .path = "src/lib.zig", .text = lib_text },
        .{ .path = "src/gen.zig", .text = gen_text },
        // Project convention: enable checking and exclude one file
        .{ .path = "zig-analyzer.zon", .text =
        \\.{ .naming = .{ .enable = true, .exclude = .{"src/gen.zig"} } }
        },
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
    const gen_uri = try za.base.uri.fromPath(a, try project.path(a, "src/gen.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = lib_uri, .languageId = "zig", .version = 1, .text = lib_text } });
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = main_uri, .languageId = "zig", .version = 1, .text = main_text } });
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = gen_uri, .languageId = "zig", .version = 1, .text = gen_text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings(
        \\0:6 naming.type `packet_type` is a type and should be TitleCase: `PacketType`
        \\1:7 naming.function `MakePacket` is a function and should be camelCase: `makePacket`
        \\4:7 naming.function `MakeThing` is a function and should be camelCase: `makeThing`
        \\6:27 naming.field field `FieldName` should be snake_case: `field_name`
        \\
    , try namingHints(&h, "lib.zig"));
    try testing.expectEqualStrings("", try namingHints(&h, "gen.zig"));

    // A declaration with the new name already exists: no edit is offered, and the reason is given
    {
        const fix = actionWithTitle(try codeActions(&h, lib_uri, lib_text, "MakeThing() void"), "rename public `MakeThing`").?;
        try testing.expectEqual(null, fix.object.get("edit"));
        const reason = fix.object.get("disabled").?.object.get("reason").?.string;
        try testing.expectEqualStrings("cannot rename `MakeThing` to `makeThing`: `makeThing` is already declared in the same container (src/lib.zig:6:4)", reason);
    }
    // An access whose type is unknown may be a reference: refused, rather than returning a partial
    // edit
    {
        const fix = actionWithTitle(try codeActions(&h, lib_uri, lib_text, "FieldName: u32"), "rename field `FieldName` to `field_name`").?;
        const resp = try h.request("codeAction/resolve", fix);
        const message = resp.object.get("error").?.object.get("message").?.string;
        try testing.expectEqualStrings("cannot rename `FieldName` to `field_name`: the type here is unknown, so whether this refers to the same declaration cannot be confirmed (src/lib.zig:9:12)", message);
    }

    var texts: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try texts.put(a, lib_uri, lib_text);
    try texts.put(a, main_uri, main_text);
    // Public function: renamed across files, and the edit carries an annotation that requires
    // confirmation
    {
        const fix = actionWithTitle(try codeActions(&h, lib_uri, lib_text, "MakePacket"), "rename public `MakePacket` to `makePacket`").?;
        // The edit is computed only after the action is chosen
        try testing.expectEqual(null, fix.object.get("edit"));
        const resp = try h.request("codeAction/resolve", fix);
        const edit = resp.object.get("result").?.object.get("edit").?;
        const annotation = edit.object.get("changeAnnotations").?.object.get("zig-analyzer.rename-public").?.object;
        try testing.expect(annotation.get("needsConfirmation").?.bool);
        try testing.expectEqual(2, try applyEdit(&h, &texts, edit));
    }
    // Non-public type: renamed only in its own file
    {
        const fix = actionWithTitle(try codeActions(&h, lib_uri, lib_text, "packet_type"), "rename `packet_type` to `PacketType`").?;
        const resp = try h.request("codeAction/resolve", fix);
        const edit = resp.object.get("result").?.object.get("edit").?;
        try testing.expectEqual(null, edit.object.get("changeAnnotations"));
        try testing.expectEqual(1, try applyEdit(&h, &texts, edit));
    }
    try testing.expectEqualStrings(
        \\const PacketType = struct { value: u32 };
        \\pub fn makePacket() PacketType {
    , texts.get(lib_uri).?[0..74]);
    try testing.expectEqualStrings("    const packet = lib.makePacket();", texts.get(main_uri).?[std.mem.indexOf(u8, texts.get(main_uri).?, "    const").?..][0..36]);

    // Save the renamed files: the project still builds, and the remaining hints are updated
    // accordingly
    for ([_][]const u8{ "src/lib.zig", "src/main.zig" }, [_][]const u8{ lib_uri, main_uri }) |path, u| {
        const text = texts.get(u).?;
        try project.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = text });
        try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = u, .version = 2 }, .contentChanges = &.{.{ .text = text }} });
        try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = u } });
    }
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(0, try compilerErrors(&h, "lib.zig"));
    try testing.expectEqual(0, try compilerErrors(&h, "main.zig"));
    try testing.expectEqualStrings(
        \\4:7 naming.function `MakeThing` is a function and should be camelCase: `makeThing`
        \\6:27 naming.field field `FieldName` should be snake_case: `field_name`
        \\
    , try namingHints(&h, "lib.zig"));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "files outside the workspace folders: what only the file itself uses can be renamed" {
    const text =
        \\fn add(a: u32, unused: u32) u32 {
        \\    var total: u32 = a;
        \\    total += 1;
        \\    return total;
        \\}
        \\pub fn scale(x: u32, factor: u32) u32 {
        \\    return x * 2;
        \\}
        \\pub fn main() void {
        \\    const BadName: u32 = add(1, 2) + scale(3, 4);
        \\    _ = BadName;
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{.{ .path = "main.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    // No workspace folder at all, as editors send for a file opened on its own
    _ = try h.request("initialize", .{ .capabilities = Empty{}, .initializationOptions = try jsonValue(&h,
        \\{"build": {"enable": false}, "diagnostics": {"compiler": false}, "naming": {"enable": true}}
    ) });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    // Such files were refused even for locals, got no remove-parameter fix and no naming hints
    {
        const resp = try h.request("textDocument/rename", .{ .textDocument = .{ .uri = uri }, .position = position(text, "total"), .newName = "sum" });
        var it = resp.object.get("result").?.object.get("changes").?.object.iterator();
        try testing.expectEqual(3, it.next().?.value_ptr.array.items.len);
    }
    try testing.expect(actionWithTitle(try codeActions(&h, uri, text, "unused"), "remove parameter `unused`") != null);
    try testing.expectEqualStrings("9:10 naming.value `BadName` should be snake_case: `bad_name`\n", try namingHints(&h, "main.zig"));
    // Other files may use a `pub` declaration, and which ones is not known
    {
        const resp = try h.request("textDocument/rename", .{ .textDocument = .{ .uri = uri }, .position = position(text, "scale"), .newName = "times" });
        try testing.expectEqualStrings("cannot rename a public declaration or field of a file outside the workspace folders: the files that use it are not known", resp.object.get("error").?.object.get("message").?.string);
        try testing.expectEqual(null, actionWithTitle(try codeActions(&h, uri, text, "factor"), "remove parameter"));
    }
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "quick fixes link only the diagnostic they fix, whatever the order of the context" {
    const text =
        \\pub fn main() void {
        \\    const fooBar = 1;
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{.{ .path = "main.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    _ = try h.request("initialize", .{ .capabilities = Empty{}, .initializationOptions = try jsonValue(&h,
        \\{"build": {"enable": false}, "diagnostics": {"compiler": false}, "naming": {"enable": true}}
    ) });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    var published: ?[]const std.json.Value = null;
    for (try h.notifications("textDocument/publishDiagnostics")) |m| {
        const params = m.object.get("params").?.object;
        if (std.mem.eql(u8, params.get("uri").?.string, uri)) published = params.get("diagnostics").?.array.items;
    }
    var unused: ?std.json.Value = null;
    var hint: ?std.json.Value = null;
    for (published.?) |d| {
        if (std.mem.eql(u8, d.object.get("message").?.string, "unused local constant")) unused = d;
        if (d.object.get("code")) |c| if (std.mem.startsWith(u8, c.string, "naming.")) {
            hint = d;
        };
    }
    // Both are on `fooBar`
    const range = struct {
        fn of(d: std.json.Value) [4]i64 {
            const r = d.object.get("range").?.object;
            const s = r.get("start").?.object;
            const e = r.get("end").?.object;
            return .{ s.get("line").?.integer, s.get("character").?.integer, e.get("line").?.integer, e.get("character").?.integer };
        }
    }.of;
    try testing.expectEqual(range(unused.?), range(hint.?));
    const p = position(text, "fooBar");
    // A naming hint on the same range must never be linked as the diagnostic the discard fixes
    for ([_][]const std.json.Value{ &.{ hint.?, unused.? }, &.{ unused.?, hint.? }, &.{hint.?} }) |context| {
        const resp = try h.request("textDocument/codeAction", .{
            .textDocument = .{ .uri = uri },
            .range = .{ .start = p, .end = p },
            .context = .{ .diagnostics = context },
        });
        const fix = actionWithTitle(resp.object.get("result").?.array.items, "discard `fooBar`").?;
        if (fix.object.get("diagnostics")) |linked| {
            try testing.expectEqual(1, linked.array.items.len);
            try testing.expectEqualStrings("unused local constant", linked.array.items[0].object.get("message").?.string);
        } else try testing.expectEqual(1, context.len);
    }
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}
