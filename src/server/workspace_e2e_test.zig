//! 端到端：磁盘上的外部改动、工作区文件夹的增减、未保存的文档（`untitled:`）。

const std = @import("std");
const testing = std.testing;
const za = @import("../zig_analyzer.zig");
const fixture = za.project.fixture;
const Harness = @import("test_harness.zig").Harness;

const Empty = struct {};

fn position(text: []const u8, needle: []const u8) struct { line: u32, character: u32 } {
    const offset = std.mem.indexOf(u8, text, needle).? + needle.len;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..offset], '\n')) |i| i + 1 else 0;
    return .{ .line = @intCast(std.mem.count(u8, text[0..offset], "\n")), .character = @intCast(offset - line_start) };
}

fn completionLabels(h: *Harness, uri: []const u8, text: []const u8, after: []const u8) ![]const u8 {
    const resp = try h.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = position(text, after) });
    var labels: std.ArrayList([]const u8) = .empty;
    const result = resp.object.get("result").?;
    if (result == .array) for (result.array.items) |item| try labels.append(h.arena.allocator(), item.object.get("label").?.string);
    return std.mem.join(h.arena.allocator(), " ", labels.items);
}

fn open(h: *Harness, uri: []const u8, text: []const u8) !void {
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
}

/// `uri` 最后一次发布的诊断文案
fn lastDiagnostics(h: *Harness, uri: []const u8) !?[]const []const u8 {
    var last: ?[]const []const u8 = null;
    for (try h.notifications("textDocument/publishDiagnostics")) |m| {
        const params = m.object.get("params").?.object;
        if (!std.mem.eql(u8, params.get("uri").?.string, uri)) continue;
        var messages: std.ArrayList([]const u8) = .empty;
        for (params.get("diagnostics").?.array.items) |d| try messages.append(h.arena.allocator(), d.object.get("message").?.string);
        last = messages.items;
    }
    return last;
}

test "external changes on disk are picked up through didChangeWatchedFiles" {
    const main_text = "const lib = @import(\"lib.zig\");\npub fn main() void {\n    lib.\n}\n";
    var project = try fixture.Project.create(&.{
        .{ .path = "main.zig", .text = main_text },
        .{ .path = "lib.zig", .text = "pub fn hello() void {}\n" },
        .{ .path = "other.zig", .text = "pub fn first() void {}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = .{ .workspace = .{ .didChangeWatchedFiles = .{ .dynamicRegistration = true } } } });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    const lib_path = try project.path(a, "lib.zig");
    const lib_uri = try za.base.uri.fromPath(a, lib_path);
    try open(&h, main_uri, main_text);
    _ = try h.request("zig-analyzer/waitIdle", {});

    // 动态注册了文件监听
    var registered = false;
    for (h.received.items) |m| {
        const method = m.object.get("method") orelse continue;
        if (!std.mem.eql(u8, method.string, "client/registerCapability")) continue;
        for (m.object.get("params").?.object.get("registrations").?.array.items) |r| {
            if (std.mem.eql(u8, r.object.get("method").?.string, "workspace/didChangeWatchedFiles")) registered = true;
        }
    }
    try testing.expect(registered);
    try testing.expectEqualStrings("hello", try completionLabels(&h, main_uri, main_text, "    lib."));

    // 编辑器之外改写 lib.zig
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = lib_path, .data = "pub fn goodbye() void {}\n" });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = lib_uri, .type = 2 }} });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("goodbye", try completionLabels(&h, main_uri, main_text, "    lib."));

    // 删除
    try std.Io.Dir.cwd().deleteFile(testing.io, lib_path);
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = lib_uri, .type = 3 }} });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("", try completionLabels(&h, main_uri, main_text, "    lib."));

    // 打开的文件以缓冲区为准
    const other_text = "const other = @import(\"other.zig\");\ntest {\n    other.\n}\n";
    const other_path = try project.path(a, "other.zig");
    const other_uri = try za.base.uri.fromPath(a, other_path);
    const user_uri = try za.base.uri.fromPath(a, try project.path(a, "user.zig"));
    try open(&h, user_uri, other_text);
    try open(&h, other_uri, "pub fn fromBuffer() void {}\n");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = other_path, .data = "pub fn fromDisk() void {}\n" });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = other_uri, .type = 2 }} });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("fromBuffer", try completionLabels(&h, user_uri, other_text, "    other."));

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "workspace folders: added folders start a project, removed ones clear its diagnostics" {
    var first = try fixture.Project.create(&.{.{ .path = "a.zig", .text = "pub const a = 1;\n" }});
    defer first.deinit();
    var second = try fixture.Project.create(&fixture.basic);
    defer second.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const first_uri = try za.base.uri.fromPath(a, first.root);
    const second_uri = try za.base.uri.fromPath(a, second.root);
    const init = try h.request("initialize", .{ .workspaceFolders = &.{.{ .uri = first_uri, .name = "first" }}, .capabilities = Empty{} });
    const folders = init.object.get("result").?.object.get("capabilities").?.object.get("workspace").?.object.get("workspaceFolders").?.object;
    try testing.expect(folders.get("changeNotifications").?.bool);
    try h.notify("initialized", Empty{});
    _ = try h.request("zig-analyzer/waitIdle", {});

    // 加入带 build.zig 的文件夹：构建并发布编译器诊断（main.zig 未打开）
    try h.notify("workspace/didChangeWorkspaceFolders", .{ .event = .{ .added = &.{.{ .uri = second_uri, .name = "second" }}, .removed = &[_]Empty{} } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const main_uri = try za.base.uri.fromPath(a, try second.path(a, "src/main.zig"));
    const before = (try lastDiagnostics(&h, main_uri)) orelse return error.NoDiagnostics;
    try testing.expectEqual(1, before.len);
    try testing.expect(std.mem.indexOf(u8, before[0], "expected type 'u32'") != null);

    // 移除：项目停止，诊断清除
    try h.notify("workspace/didChangeWorkspaceFolders", .{ .event = .{ .added = &[_]Empty{}, .removed = &.{.{ .uri = second_uri, .name = "second" }} } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(0, (try lastDiagnostics(&h, main_uri)).?.len);

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "untitled documents: diagnostics and hover use the original URI" {
    var project = try fixture.Project.create(&.{.{ .path = "a.zig", .text = "pub const a = 1;\n" }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = "untitled:Untitled-1";
    const text = "fn f() void {\n    const y: u8 = 1;\n}\n";
    try open(&h, uri, text);
    _ = try h.request("zig-analyzer/waitIdle", {});

    const diags = (try lastDiagnostics(&h, uri)) orelse return error.NoDiagnostics;
    try testing.expectEqual(1, diags.len);
    try testing.expect(std.mem.indexOf(u8, diags[0], "unused local constant") != null);

    const p = position(text, "const ");
    const hover = try h.request("textDocument/hover", .{ .textDocument = .{ .uri = uri }, .position = p });
    const contents = hover.object.get("result").?.object.get("contents").?.object.get("value").?.string;
    try testing.expect(std.mem.indexOf(u8, contents, "const y: u8") != null);

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "completion of @import paths lists modules, files and directories" {
    const main_text = "const a = @import(\"\");\nconst b = @import(\"sub/\");\n";
    var project = try fixture.Project.create(&.{
        .{ .path = "main.zig", .text = main_text },
        .{ .path = "util.zig", .text = "" },
        .{ .path = "notes.txt", .text = "" },
        .{ .path = "sub/inner.zig", .text = "" },
        .{ .path = "sub/data.zon", .text = ".{}" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try open(&h, uri, main_text);
    _ = try h.request("zig-analyzer/waitIdle", {});

    const cases = [_]struct { []const u8, []const u8, u32 }{
        .{ "a = @import(\"", "builtin main.zig root std sub/ util.zig", 19 },
        .{ "b = @import(\"sub/", "sub/data.zon sub/inner.zig", 19 },
    };
    for (cases) |c| {
        const resp = try h.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = position(main_text, c[0]) });
        var labels: std.ArrayList([]const u8) = .empty;
        for (resp.object.get("result").?.array.items) |item| {
            try labels.append(a, item.object.get("label").?.string);
            // 替换范围从字符串内容的开头起
            const start = item.object.get("textEdit").?.object.get("range").?.object.get("start").?.object;
            try testing.expectEqual(c[2], start.get("character").?.integer);
        }
        std.mem.sort([]const u8, labels.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        try testing.expectEqualStrings(c[1], try std.mem.join(a, " ", labels.items));
    }
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}
