//! 端到端：磁盘上的外部改动、工作区文件夹的增减、未保存的文档（`untitled:`）、项目的启动、重启与停止。

const std = @import("std");
const testing = std.testing;
const za = @import("../zig_analyzer.zig");
const fixture = za.project.fixture;
const Harness = @import("test_harness.zig").Harness;
const Server = @import("Server.zig");
const Workspace = @import("Workspace.zig");

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

test "without file watching from the client, the server polls for changes on disk" {
    const main_text = "const lib = @import(\"lib.zig\");\npub fn main() void {\n    lib.\n}\n";
    var project = try fixture.Project.create(&.{
        .{ .path = "main.zig", .text = main_text },
        .{ .path = "lib.zig", .text = "pub fn hello() void {}\n" },
        .{ .path = "geo.zig", .text = "pub const name = \"geo\";\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    h.server.poll_interval_ms.store(20, .monotonic);
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    // 客户端不能动态注册文件监听
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try open(&h, main_uri, main_text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("hello", try completionLabels(&h, main_uri, main_text, "    lib."));

    // 编辑器之外改写未打开的 lib.zig，没有任何通知
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try project.path(a, "lib.zig"), .data = "pub fn goodbye() void {}\n" });
    for (0..400) |_| {
        _ = try h.request("zig-analyzer/waitIdle", {});
        if (std.mem.eql(u8, try completionLabels(&h, main_uri, main_text, "    lib."), "goodbye")) break;
        try testing.io.sleep(.fromMilliseconds(25), .awake);
    } else return error.ChangeNotNoticed;

    // 编辑器之外新建 build.zig：启动项目；删除：停止项目
    const build_path = try project.path(a, "build.zig");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = build_path, .data = named_module_build });
    try waitProjects(&h, 1);
    try std.Io.Dir.cwd().deleteFile(testing.io, build_path);
    try waitProjects(&h, 0);

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

/// 等到项目列表中有 `n` 个项目
fn waitProjects(h: *Harness, n: usize) !void {
    for (0..400) |_| {
        _ = try h.request("zig-analyzer/waitIdle", {});
        h.server.workspaces_mutex.lockUncancelable(testing.io);
        const count = h.server.workspaces.items.len;
        h.server.workspaces_mutex.unlock(testing.io);
        if (count == n) return;
        try testing.io.sleep(.fromMilliseconds(25), .awake);
    }
    return error.ChangeNotNoticed;
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

test "live diagnostics in a library whose default step compiles nothing" {
    // 只有 addModule 与 addTest：默认的 install step 为空，编译集合改用构建图中所有的编译 step
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const mod = b.addModule("lib", .{ .root_source_file = b.path("lib.zig"), .target = b.graph.host });
        \\    const tests = b.addTest(.{ .root_module = mod });
        \\    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
        \\}
        \\
        },
        .{ .path = "lib.zig", .text = "pub const a = 1;\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(h.arena.allocator(), try project.path(h.arena.allocator(), "lib.zig"));
    try open(&h, uri, "pub const a = 1;\n");
    _ = try h.request("zig-analyzer/waitIdle", {});
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = 2 }, .contentChanges = &.{.{ .text = "pub const a = 1;\n@@\n" }} });
    _ = try h.request("zig-analyzer/waitIdle", {});

    const diags = (try lastDiagnostics(&h, uri)) orelse return error.NoDiagnostics;
    try testing.expectEqual(1, diags.len);
    try testing.expect(std.mem.indexOf(u8, diags[0], "invalid token") != null);
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "files reachable only from non-default steps resolve module imports" {
    // 默认的 install 只编译 app；t.zig 只在 test step 的模块中，经由它 import 了模块 lib
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const lib = b.addModule("lib", .{ .root_source_file = b.path("lib.zig"), .target = b.graph.host });
        \\    const app = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{ .root_source_file = b.path("app.zig"), .target = b.graph.host }) });
        \\    b.installArtifact(app);
        \\    const tests = b.addTest(.{ .root_module = b.createModule(.{
        \\        .root_source_file = b.path("t.zig"),
        \\        .target = b.graph.host,
        \\        .imports = &.{.{ .name = "lib", .module = lib }},
        \\    }) });
        \\    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
        \\}
        \\
        },
        .{ .path = "app.zig", .text = "pub fn main() void {}\n" },
        .{ .path = "lib.zig", .text = "pub fn answer() u32 {\n    return 42;\n}\n" },
        .{ .path = "t.zig", .text = "const lib = @import(\"lib\");\ntest {\n    _ = lib.answer();\n}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const text = "const lib = @import(\"lib\");\ntest {\n    _ = lib.answer();\n}\n";
    const uri = try za.base.uri.fromPath(h.arena.allocator(), try project.path(h.arena.allocator(), "t.zig"));
    try open(&h, uri, text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("answer", try completionLabels(&h, uri, text, "lib."));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "files of a package that only exports modules resolve module imports" {
    // 构建图中没有 compile step：lib 只由使用方编译，模块归属来自导出的模块
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const dep = b.createModule(.{ .root_source_file = b.path("dep.zig") });
        \\    _ = b.addModule("lib", .{ .root_source_file = b.path("lib.zig"), .imports = &.{.{ .name = "dep", .module = dep }} });
        \\}
        \\
        },
        .{ .path = "dep.zig", .text = "pub fn answer() u32 {\n    return 42;\n}\n" },
        .{ .path = "lib.zig", .text = "const dep = @import(\"dep\");\npub fn f() void {\n    _ = dep.answer();\n}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const text = "const dep = @import(\"dep\");\npub fn f() void {\n    _ = dep.answer();\n}\n";
    const uri = try za.base.uri.fromPath(h.arena.allocator(), try project.path(h.arena.allocator(), "lib.zig"));
    try open(&h, uri, text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("answer", try completionLabels(&h, uri, text, "dep."));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "a project whose background task cannot be started does not leave the server busy" {
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    // 不允许并发任务：项目的后台任务启动失败
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var writer: za.lsp.transport.Writer = .{ .io = testing.io, .inner = &out.writer };
    var server: Server = undefined;
    try server.init(threaded.io(), testing.allocator, &writer);
    defer server.deinit();
    server.zig_env = try za.project.ZigEnv.query(testing.allocator, testing.io, project.env.zig_exe);

    try testing.expectError(error.ConcurrencyUnavailable, Workspace.start(&server, project.root, 0));
    const busy = server.busy;
    // 计数泄漏时 deinit 中的 waitIdle 永远等待：先归零，让失败的测试正常结束
    server.busy = 0;
    try testing.expectEqual(0, busy);
}

/// 等到某个进度报告的文案包含 `needle`
fn waitProgress(h: *Harness, needle: []const u8) !void {
    while (true) {
        const msg = try h.next();
        const method = msg.object.get("method") orelse continue;
        if (!std.mem.eql(u8, method.string, "$/progress")) continue;
        const value = msg.object.get("params").?.object.get("value").?.object;
        const text = value.get("message") orelse value.get("title") orelse continue;
        if (text == .string and std.mem.indexOf(u8, text.string, needle) != null) return;
    }
}

/// 等到服务器发来 `method` 请求（由 `Harness.next` 回复）
fn waitRequest(h: *Harness, method: []const u8) !void {
    while (true) {
        const msg = try h.next();
        if (msg.object.get("id") == null) continue;
        const m = msg.object.get("method") orelse continue;
        if (std.mem.eql(u8, m.string, method)) return;
    }
}

/// 项目当前的 maker 所在的进程组
fn makerGroup(h: *Harness) std.posix.pid_t {
    h.server.workspaces_mutex.lockUncancelable(testing.io);
    defer h.server.workspaces_mutex.unlock(testing.io);
    const ws = h.server.workspaces.items[0];
    ws.mutex.lockUncancelable(testing.io);
    defer ws.mutex.unlock(testing.io);
    return ws.client.?.group.pgid;
}

test "shutdown during a build ends zig build and its child processes without waiting for the build" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var project = try fixture.Project.create(&fixture.slow);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = .{ .window = .{ .workDoneProgress = true } } });
    try h.notify("initialized", Empty{});
    // 构建进行到 60 秒的 sleep：maker 要等构建结束才读取下一条消息
    try waitProgress(&h, "run sleep");
    const pgid = makerGroup(&h);

    const t0 = std.Io.Clock.awake.now(testing.io);
    _ = try h.request("shutdown", {});
    const elapsed = t0.durationTo(std.Io.Clock.awake.now(testing.io));
    try testing.expect(elapsed.toSeconds() < 10);
    try fixture.expectGroupGone(pgid);
    try h.notify("exit", {});
}

/// 项目当前的 maker 的进程号
fn makerPid(h: *Harness) std.posix.pid_t {
    h.server.workspaces_mutex.lockUncancelable(testing.io);
    defer h.server.workspaces_mutex.unlock(testing.io);
    const ws = h.server.workspaces.items[0];
    ws.mutex.lockUncancelable(testing.io);
    defer ws.mutex.unlock(testing.io);
    return ws.client.?.child.id.?;
}

/// 第 `from` 条诊断通知之后，`uri` 至少发布过一次诊断，且每次都含有 `needle`
fn expectEveryPublishContains(h: *Harness, from: usize, uri: []const u8, needle: []const u8) !void {
    var count: usize = 0;
    for ((try h.notifications("textDocument/publishDiagnostics"))[from..]) |m| {
        const params = m.object.get("params").?.object;
        if (!std.mem.eql(u8, params.get("uri").?.string, uri)) continue;
        count += 1;
        const found = for (params.get("diagnostics").?.array.items) |d| {
            if (std.mem.indexOf(u8, d.object.get("message").?.string, needle) != null) break true;
        } else false;
        if (!found) {
            std.debug.print("publish #{d} of {s} lacks \"{s}\"\n", .{ count, uri, needle });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expect(count >= 1);
}

/// 被替换的实例在其后台任务结束后释放：存活的实例数在几秒内回到 `expected`
fn expectLiveWorkspaces(h: *Harness, expected: usize) !void {
    for (0..100) |_| {
        if (h.server.live_workspaces.load(.monotonic) == expected) return;
        try testing.io.sleep(.fromMilliseconds(50), .awake);
    }
    try testing.expectEqual(expected, h.server.live_workspaces.load(.monotonic));
}

test "restarting a project keeps the previous compiler diagnostics until the new instance has built" {
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = .{ .window = .{ .workDoneProgress = true } } });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    try open(&h, main_uri, fixture.basic[1].text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    const before = (try lastDiagnostics(&h, main_uri)) orelse return error.NoDiagnostics;
    try testing.expectEqual(1, before.len);
    try testing.expect(std.mem.indexOf(u8, before[0], "expected type 'u32'") != null);

    // 保存 build.zig：以新实例重启。新实例首次构建完成前，打开的文件不能失去编译器诊断
    var from = (try h.notifications("textDocument/publishDiagnostics")).len;
    const build_uri = try za.base.uri.fromPath(a, try project.path(a, "build.zig"));
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = build_uri } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try expectEveryPublishContains(&h, from, main_uri, "expected type 'u32'");

    // maker 崩溃：自动重启，同样保留。新实例申请了进度 token 之后再等待空闲（此前服务器可能还没发现崩溃）
    if (@import("builtin").os.tag != .windows) {
        from = (try h.notifications("textDocument/publishDiagnostics")).len;
        try std.posix.kill(makerPid(&h), .KILL);
        try waitRequest(&h, "window/workDoneProgress/create");
        _ = try h.request("zig-analyzer/waitIdle", {});
        try expectEveryPublishContains(&h, from, main_uri, "expected type 'u32'");
    }

    // 被替换的实例都已释放
    try expectLiveWorkspaces(&h, 1);
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "restarting a project during a build stops the old build system first" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var project = try fixture.Project.create(&fixture.slow);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = .{ .window = .{ .workDoneProgress = true } } });
    try h.notify("initialized", Empty{});
    try waitProgress(&h, "run sleep");
    const old = makerGroup(&h);

    // 构建进行中保存 build.zig：旧的构建立即结束，不与新实例的构建同时进行
    const build_uri = try za.base.uri.fromPath(a, try project.path(a, "build.zig"));
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = build_uri } });
    try fixture.expectGroupGone(old);
    try waitProgress(&h, "run sleep");
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

/// `uri` 最后一次发布的诊断中是否有含 `needle` 的
fn lastHas(h: *Harness, uri: []const u8, needle: []const u8) !bool {
    const diags = (try lastDiagnostics(h, uri)) orelse return false;
    for (diags) |d| if (std.mem.indexOf(u8, d, needle) != null) return true;
    return false;
}

/// 项目列表中唯一的实例
fn visibleInstance(h: *Harness) *Workspace {
    h.server.workspaces_mutex.lockUncancelable(testing.io);
    defer h.server.workspaces_mutex.unlock(testing.io);
    return h.server.workspaces.items[0];
}

/// 跳转结果所在的文件名（没有结果时为 "null"；请求被写事务打断、回复 ContentModified 时为 "error"）
fn gotoFile(h: *Harness, uri: []const u8, text: []const u8, needle: []const u8) ![]const u8 {
    const resp = try h.request("textDocument/definition", .{ .textDocument = .{ .uri = uri }, .position = position(text, needle) });
    const result = resp.object.get("result") orelse return "error";
    if (result == .null) return "null";
    const target = result.object.get("uri").?.string;
    return target[std.mem.lastIndexOfScalar(u8, target, '/').? + 1 ..];
}

test "fixing a build.zig that failed to compile: named modules resolve once the build graph is read, before the build ends" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // 构建中运行 60 秒的外部命令：构建在测试期间不会结束
    const fixed =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const geo = b.createModule(.{ .root_source_file = b.path("geo.zig") });
        \\    const exe = b.addExecutable(.{ .name = "t", .root_module = b.createModule(.{
        \\        .root_source_file = b.path("main.zig"),
        \\        .target = b.graph.host,
        \\        .imports = &.{.{ .name = "geo", .module = geo }},
        \\    }) });
        \\    const check = b.step("check", "Check");
        \\    check.dependOn(&exe.step);
        \\    check.dependOn(&b.addSystemCommand(&.{ "sleep", "60" }).step);
        \\}
        \\
    ;
    const main_text = "const geo = @import(\"geo\");\npub fn main() void {\n    _ = geo.name;\n}\n";
    const broken = try std.mem.replaceOwned(u8, testing.allocator, fixed, "b.graph.host", "b.graph.hots");
    defer testing.allocator.free(broken);
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = broken },
        .{ .path = "main.zig", .text = main_text },
        .{ .path = "geo.zig", .text = "pub const name = \"geo\";\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try open(&h, main_uri, main_text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    const build_path = try project.path(a, "build.zig");
    const build_uri = try za.base.uri.fromPath(a, build_path);
    try testing.expect(try lastHas(&h, build_uri, "hots"));
    try testing.expectEqualStrings("null", try gotoFile(&h, main_uri, main_text, "geo.na"));

    // 修好并保存：旧实例没有构建图可沿用，新实例读入构建图后立即替换它，不等构建结束
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = build_path, .data = fixed });
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = build_uri } });
    for (0..400) |_| {
        if (std.mem.eql(u8, try gotoFile(&h, main_uri, main_text, "geo.na"), "geo.zig")) break;
        try testing.io.sleep(.fromMilliseconds(100), .awake);
    } else return error.TestUnexpectedResult;
    // build.zig 的编译错误随旧实例清除
    for (0..100) |_| {
        if (!try lastHas(&h, build_uri, "hots")) break;
        _ = try h.request("zig-analyzer/status", {});
        try testing.io.sleep(.fromMilliseconds(100), .awake);
    } else return error.TestUnexpectedResult;
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "abandoning a restart clears the previous compiler diagnostics and keeps the build graph" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    // 包装用户的 zig：存在 hang 文件时 `zig build` 什么也不发送。`zig env` 报告包装脚本自身为 zig
    const zig = project.env.zig_exe;
    const script = try std.fmt.allocPrint(testing.allocator,
        \\#!/bin/sh
        \\case "$1" in
        \\env) "{s}" env | sed 's|\.zig_exe = "[^"]*"|.zig_exe = "{s}/zigw"|' ;;
        \\build) if [ -e "{s}/hang" ]; then exec sleep 600; fi; exec "{s}" "$@" ;;
        \\*) exec "{s}" "$@" ;;
        \\esac
        \\
    , .{ zig, project.root, project.root, zig, zig });
    defer testing.allocator.free(script);
    try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "zigw", .data = script, .flags = .{ .permissions = .executable_file } });

    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    const options = try std.fmt.allocPrint(a, "{{\"zig\": {{\"path\": \"{s}/zigw\"}}}}", .{project.root});
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{}, .initializationOptions = try std.json.parseFromSliceLeaky(std.json.Value, a, options, .{}) });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    try open(&h, main_uri, fixture.basic[1].text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expect(try lastHas(&h, main_uri, "expected type 'u32'"));

    // 保存 build.zig：新实例一直得不到结果，随后被放弃（如 maker 反复崩溃）
    try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "hang", .data = "" });
    const build_uri = try za.base.uri.fromPath(a, try project.path(a, "build.zig"));
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = build_uri } });
    const ws = visibleInstance(&h);
    const pending = for (0..100) |_| {
        h.server.workspaces_mutex.lockUncancelable(testing.io);
        const s = ws.successor;
        if (s) |p| p.acquire();
        h.server.workspaces_mutex.unlock(testing.io);
        if (s) |p| break p;
        try testing.io.sleep(.fromMilliseconds(50), .awake);
    } else return error.TestUnexpectedResult;
    pending.stop();
    h.server.abandon(pending);
    pending.release();
    _ = try h.request("zig-analyzer/waitIdle", {});
    // 旧的编译器诊断不再更新：不再显示；旧实例的构建图继续用于模块归属
    try testing.expect(!try lastHas(&h, main_uri, "expected type 'u32'"));
    try testing.expect(visibleInstance(&h) == ws);
    try testing.expect(ws.successor == null);
    try testing.expect(ws.inModuleGraph());

    // 再次保存 build.zig：重新开始
    try project.tmp.dir.deleteFile(testing.io, "hang");
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = build_uri } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expect(try lastHas(&h, main_uri, "expected type 'u32'"));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "a restart or build requested through a replaced instance applies to the project's current instance" {
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "src/main.zig"));
    try open(&h, main_uri, fixture.basic[1].text);
    _ = try h.request("zig-analyzer/waitIdle", {});
    // 调用方持有的列表快照中的实例
    const stale = visibleInstance(&h);
    stale.acquire();
    defer stale.release();
    const build_uri = try za.base.uri.fromPath(a, try project.path(a, "build.zig"));
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = build_uri } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const current = visibleInstance(&h);
    try testing.expect(current != stale);

    // 构建请求转给当前的实例：重新发布有编译器诊断的文件
    const before = (try h.notifications("textDocument/publishDiagnostics")).len;
    h.server.requestBuild(stale);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expect((try h.notifications("textDocument/publishDiagnostics")).len > before);

    // 重启当前的实例
    h.server.restartWorkspace(stale, 0);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expect(visibleInstance(&h) != current);
    try testing.expect(try lastHas(&h, main_uri, "expected type 'u32'"));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "a new instance handles build events only after the server has placed it" {
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    // 没有工作区文件夹：项目由测试启动。不运行编译器，配置完成后不再有构建
    const options = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"diagnostics\": {\"compiler\": false}}", .{});
    _ = try h.request("initialize", .{ .capabilities = Empty{}, .initializationOptions = options });
    try h.notify("initialized", Empty{});
    const main_path = try project.path(a, "src/main.zig");
    const main_uri = try za.base.uri.fromPath(a, main_path);
    try open(&h, main_uri, fixture.basic[1].text);
    _ = try h.request("zig-analyzer/waitIdle", {});

    const ws = try Workspace.start(&h.server, project.root, 0);
    // 加入列表之前不处理事件：maker 早已发来构建图
    var handled = false;
    for (0..30) |_| {
        ws.mutex.lockUncancelable(testing.io);
        handled = ws.model != null;
        ws.mutex.unlock(testing.io);
        if (handled) break;
        try testing.io.sleep(.fromMilliseconds(100), .awake);
    }
    {
        h.server.workspaces_mutex.lockUncancelable(testing.io);
        defer h.server.workspaces_mutex.unlock(testing.io);
        try h.server.workspaces.append(testing.allocator, ws);
        ws.placed.set(testing.io);
    }
    try testing.expect(!handled);
    // 加入列表后读入的构建图进入模块图
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("lib.zig", try gotoFile(&h, main_uri, fixture.basic[1].text, "lib.hel"));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

/// 只用命名模块 geo 的源文件；没有 build.zig 时按单文件编译，找不到这个模块
const named_module_main = "const geo = @import(\"geo\");\npub fn main() void {\n    const x: u32 = geo.name;\n    _ = x;\n}\n";
const named_module_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const geo = b.createModule(.{ .root_source_file = b.path("geo.zig") });
    \\    const exe = b.addExecutable(.{ .name = "t", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("main.zig"),
    \\        .target = b.graph.host,
    \\        .imports = &.{.{ .name = "geo", .module = geo }},
    \\    }) });
    \\    b.installArtifact(exe);
    \\}
    \\
;

test "a build.zig reported created and then saved: the project restarted during loading still publishes compiler diagnostics" {
    var project = try fixture.Project.create(&.{
        .{ .path = "main.zig", .text = named_module_main },
        .{ .path = "geo.zig", .text = "pub const name = \"geo\";\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{}, .initializationOptions = .{ .files = .{ .watcher = "client" } } });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try open(&h, main_uri, named_module_main);
    _ = try h.request("zig-analyzer/waitIdle", {});

    const build_path = try project.path(a, "build.zig");
    const build_uri = try za.base.uri.fromPath(a, build_path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = build_path, .data = named_module_build });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = build_uri, .type = 1 }} });
    try open(&h, build_uri, named_module_build);
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = build_uri } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(1, h.server.workspaces.items.len);
    try testing.expect(try lastHas(&h, main_uri, "expected type 'u32'"));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "creating or deleting build.zig in a workspace folder starts or stops its project" {
    var project = try fixture.Project.create(&.{
        .{ .path = "main.zig", .text = named_module_main },
        .{ .path = "geo.zig", .text = "pub const name = \"geo\";\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const root_uri = try za.base.uri.fromPath(a, project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const main_uri = try za.base.uri.fromPath(a, try project.path(a, "main.zig"));
    try open(&h, main_uri, named_module_main);
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(0, h.server.workspaces.items.len);
    try testing.expect(try lastHas(&h, main_uri, "no module named 'geo'"));

    // 编辑器之外新建 build.zig（如 zig init）：启动项目，命名模块得以解析
    const build_path = try project.path(a, "build.zig");
    const build_uri = try za.base.uri.fromPath(a, build_path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = build_path, .data = named_module_build });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = build_uri, .type = 1 }} });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(1, h.server.workspaces.items.len);
    try testing.expect(try lastHas(&h, main_uri, "expected type 'u32'"));
    try testing.expect(!try lastHas(&h, main_uri, "no module named"));

    // 删除：项目停止，打开的文件改按单文件编译
    try std.Io.Dir.cwd().deleteFile(testing.io, build_path);
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = build_uri, .type = 3 }} });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(0, h.server.workspaces.items.len);
    try testing.expect(try lastHas(&h, main_uri, "no module named 'geo'"));

    // 在编辑器中新建并保存 build.zig（没有文件监听）：同样启动项目
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = build_path, .data = named_module_build });
    try open(&h, build_uri, named_module_build);
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = build_uri } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(1, h.server.workspaces.items.len);
    try testing.expect(try lastHas(&h, main_uri, "expected type 'u32'"));

    // 关闭构建系统集成期间删除 build.zig（没有事件），再打开：按磁盘重新检查，不启动项目
    try h.notify("workspace/didChangeConfiguration", .{ .settings = .{ .@"zig-analyzer" = .{ .build = .{ .enable = false } } } });
    try std.Io.Dir.cwd().deleteFile(testing.io, build_path);
    try h.notify("workspace/didChangeConfiguration", .{ .settings = .{ .@"zig-analyzer" = .{ .build = .{ .enable = true } } } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqual(0, h.server.workspaces.items.len);

    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}
