//! 端到端：命名检查的提示（开关、例外、项目配置、编辑后的更新）与改名修复（`codeAction/resolve`、冲突与无法确认的
//! 引用、公开名字的确认注解，应用之后项目照常编译）。

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

/// 文件（URI 的最后一段）最后一次发布的命名提示：「行:列 code 文案」
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

/// 文件最后一次发布的编译器诊断（来源为 zig）的个数
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

/// 标题以 `prefix` 开头的代码操作
fn actionWithTitle(actions: []const std.json.Value, prefix: []const u8) ?std.json.Value {
    for (actions) |x| if (std.mem.startsWith(u8, x.object.get("title").?.string, prefix)) return x;
    return null;
}

/// 对 `texts`（URI → 文本）应用 WorkspaceEdit（`changes` 或 `documentChanges`），返回改动了的 URI 数
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
    // 默认不检查，也没有修复
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
    // 低强度的提示，附官方规则的链接
    for ((try h.notifications("textDocument/publishDiagnostics"))[0..]) |m| {
        for (m.object.get("params").?.object.get("diagnostics").?.array.items) |d| {
            try testing.expectEqual(4, d.object.get("severity").?.integer);
            try testing.expectEqualStrings(za.ide.naming.guide_url, d.object.get("codeDescription").?.object.get("href").?.string);
        }
    }

    // 客户端不支持 `codeAction/resolve`：当场算出编辑
    {
        const actions = try codeActions(&h, uri, sample, "localValue =");
        const fix = actionWithTitle(actions, "rename `localValue` to `local_value`").?;
        try testing.expectEqual(null, fix.object.get("isPreferred"));
        var texts: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        try texts.put(a, uri, sample);
        try testing.expectEqual(1, try applyEdit(&h, &texts, fix.object.get("edit").?));
        try testing.expect(std.mem.indexOf(u8, texts.get(uri).?, "const local_value = MakePacket();\n    const marker: Empty = .{};\n    _ = local_value;") != null);
    }

    // 名字与规则的例外
    try h.notify("workspace/didChangeConfiguration", .{ .settings = try jsonValue(&h, "{" ++ base_settings ++
        \\, "naming": {"enable": true, "ignore": ["Make*"], "rules": {"value": false}}}
    ) });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings(
        \\0:6 naming.type `packet_type` is a type and should be TitleCase: `PacketType`
        \\2:3 naming.type_function `packetFactory` returns a type and should be TitleCase: `PacketFactory`
        \\
    , try namingHints(&h, "main.zig"));

    // 编辑之后更新
    const edited = try std.mem.replaceOwned(u8, a, sample, "packet_type", "PacketType");
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = 2 }, .contentChanges = &.{.{ .text = edited }} });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings(
        \\2:3 naming.type_function `packetFactory` returns a type and should be TitleCase: `PacketFactory`
        \\
    , try namingHints(&h, "main.zig"));

    // 关闭
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
        // 项目约定：开启检查，排除一个文件
        .{ .path = "zig-analyzer.json", .text =
        \\{"naming": {"enable": true, "exclude": ["src/gen.zig"]}}
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

    // 新名字已有同名的声明：不提供编辑，说明原因
    {
        const fix = actionWithTitle(try codeActions(&h, lib_uri, lib_text, "MakeThing() void"), "rename public `MakeThing`").?;
        try testing.expectEqual(null, fix.object.get("edit"));
        const reason = fix.object.get("disabled").?.object.get("reason").?.string;
        try testing.expectEqualStrings("cannot rename `MakeThing` to `makeThing`: `makeThing` is already declared in the same container (src/lib.zig:6:4)", reason);
    }
    // 类型未知的访问可能是引用：拒绝，不返回只改了一部分的编辑
    {
        const fix = actionWithTitle(try codeActions(&h, lib_uri, lib_text, "FieldName: u32"), "rename field `FieldName` to `field_name`").?;
        const resp = try h.request("codeAction/resolve", fix);
        const message = resp.object.get("error").?.object.get("message").?.string;
        try testing.expectEqualStrings("cannot rename `FieldName` to `field_name`: the type here is unknown, so whether this refers to the same declaration cannot be confirmed (src/lib.zig:9:12)", message);
    }

    var texts: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try texts.put(a, lib_uri, lib_text);
    try texts.put(a, main_uri, main_text);
    // 公开的函数：跨文件改名，编辑带上要求确认的注解
    {
        const fix = actionWithTitle(try codeActions(&h, lib_uri, lib_text, "MakePacket"), "rename public `MakePacket` to `makePacket`").?;
        // 选择之后才计算编辑
        try testing.expectEqual(null, fix.object.get("edit"));
        const resp = try h.request("codeAction/resolve", fix);
        const edit = resp.object.get("result").?.object.get("edit").?;
        const annotation = edit.object.get("changeAnnotations").?.object.get("zig-analyzer.rename-public").?.object;
        try testing.expect(annotation.get("needsConfirmation").?.bool);
        try testing.expectEqual(2, try applyEdit(&h, &texts, edit));
    }
    // 不公开的类型：只在所在文件中改名
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

    // 保存改名后的文件：项目照常编译，剩下的提示随之更新
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
