//! 端到端：Server + 真实的构建系统协议，校验发布的诊断与编译器一致，以及构建进度通知。

const std = @import("std");
const testing = std.testing;
const za = @import("../zig_analyzer.zig");
const fixture = za.project.fixture;
const Harness = @import("test_harness.zig").Harness;
const live = @import("../database.zig").live;

/// 空对象（`.{}` 是空元组，会被序列化为 `[]`）
const Empty = struct {};

const Diagnostics = std.StringArrayHashMapUnmanaged([]const []const u8);

fn expectDiagnostics(map: Diagnostics, file: []const u8, expected: []const []const u8) !void {
    const actual = map.get(file) orelse {
        std.debug.print("{s}: no diagnostics published\n", .{file});
        return error.TestUnexpectedResult;
    };
    if (actual.len != expected.len) {
        std.debug.print("{s} diagnostics:\n", .{file});
        for (actual) |l| std.debug.print("  {s}\n", .{l});
        return error.TestUnexpectedResult;
    }
    for (expected, actual) |e, a| {
        if (std.mem.indexOf(u8, a, e) == null) {
            std.debug.print("expected to contain \"{s}\", got \"{s}\"\n", .{ e, a });
            return error.TestUnexpectedResult;
        }
    }
}

fn expectNoErrors(h: *Harness, document_uri: []const u8) !void {
    for (try h.notifications("textDocument/publishDiagnostics")) |message| {
        const params = message.object.get("params").?.object;
        if (!std.mem.eql(u8, params.get("uri").?.string, document_uri)) continue;
        for (params.get("diagnostics").?.array.items) |diagnostic| {
            const severity = diagnostic.object.get("severity") orelse continue;
            try testing.expect(severity.integer != 1);
        }
    }
}

fn initialize(h: *Harness, root: []const u8, progress: bool) !void {
    return initializeWith(h, root, progress, null);
}

fn initializeWith(h: *Harness, root: []const u8, progress: bool, options: ?std.json.Value) !void {
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = .{ .window = .{ .workDoneProgress = progress } }, .initializationOptions = options });
    try h.notify("initialized", Empty{});
}

fn jsonValue(h: *Harness, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), text, .{});
}

fn open(h: *Harness, path: []const u8, text: []const u8) ![]const u8 {
    const uri = try za.base.uri.fromPath(h.arena.allocator(), path);
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    return uri;
}

fn waitIdle(h: *Harness) !void {
    _ = try h.request("zig-analyzer/waitIdle", {});
}

fn shutdown(h: *Harness) !void {
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

/// 所有 begin 进度的标题
fn progressTitles(h: *Harness) ![]const []const u8 {
    var titles: std.ArrayList([]const u8) = .empty;
    for (try h.notifications("$/progress")) |m| {
        const value = m.object.get("params").?.object.get("value").?.object;
        if (std.mem.eql(u8, value.get("kind").?.string, "begin")) try titles.append(h.arena.allocator(), value.get("title").?.string);
    }
    return titles.items;
}

test "compiler diagnostics: build, remap of unsaved edits, rebuild on save, build progress" {
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    const a = testing.allocator;

    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, true);

    const main_path = try project.path(h.arena.allocator(), "src/main.zig");
    const main_text = fixture.basic[1].text;
    const main_uri = try open(&h, main_path, main_text);
    try waitIdle(&h);

    // 1. 打开后：缓冲区与磁盘一致，main.zig 只有编译器的 Sema 错误；未打开的文件也有编译器诊断
    var diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{"2:19 zig: expected type 'u32'"});
    try expectDiagnostics(diags, "lib.zig", &.{"1:8 zig: unused local variable"});
    try expectDiagnostics(diags, "orphan.zig", &.{"1:8 zig: unused local variable"});
    try testing.expect(diags.get("unrelated.zig") == null);

    // 2. 未保存修改：Sema 错误随插入的一行下移
    const edited = try std.mem.concat(a, u8, &.{ "// 新的一行\n", main_text });
    defer a.free(edited);
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = main_uri, .version = 2 }, .contentChanges = &.{.{ .text = edited }} });
    try waitIdle(&h);
    diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{"3:19 zig: expected type 'u32'"});

    // 3. 修复错误、写入磁盘并保存：重建后 main.zig 的诊断被清空。编译器得以继续分析到 lib.hello()，
    //    在 lib.zig 中多报出一个 Sema 错误（与直接运行 zig build check 的结果相同）
    const fixed = try std.mem.replaceOwned(u8, a, edited, "const x: u32 = \"不是数字\";", "const x: u32 = 1;");
    defer a.free(fixed);
    try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "src/main.zig", .data = fixed });
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = main_uri, .version = 3 }, .contentChanges = &.{.{ .text = fixed }} });
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = main_uri } });
    try waitIdle(&h);
    diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{});
    try expectDiagnostics(diags, "lib.zig", &.{
        "1:8 zig: unused local variable",
        "1:8 zig: variable of type 'comptime_int' must be const or comptime",
    });
    try shutdown(&h);

    // 4. 进度：项目加载与两次构建，每个都有 begin 与 end；构建有百分比
    const titles = try progressTitles(&h);
    var ends: usize = 0;
    var percentages: usize = 0;
    for (try h.notifications("$/progress")) |m| {
        const value = m.object.get("params").?.object.get("value").?.object;
        const kind = value.get("kind").?.string;
        if (std.mem.eql(u8, kind, "end")) ends += 1;
        if (std.mem.eql(u8, kind, "report") and value.get("percentage") != null) percentages += 1;
    }
    try testing.expect(titles.len >= 3);
    try testing.expect(std.mem.startsWith(u8, titles[0], "Loading project"));
    var builds: usize = 0;
    for (titles) |t| {
        if (std.mem.eql(u8, t, "zig build check")) builds += 1;
    }
    // maker 崩溃自动重启时会多一次构建
    try testing.expect(builds >= 2);
    if (titles.len != ends) {
        for (try h.notifications("$/progress")) |m| {
            const params = m.object.get("params").?.object;
            const value = params.get("value").?.object;
            std.debug.print("  {s} {s} {s}\n", .{ params.get("token").?.string, value.get("kind").?.string, if (value.get("title")) |t| t.string else if (value.get("message")) |x| (if (x == .string) x.string else "") else "" });
        }
    }
    try testing.expectEqual(titles.len, ends);
    try testing.expect(percentages >= 2);
}

test "compiler diagnostics: a save while the finished build is being published starts another build" {
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    const a = testing.allocator;

    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, true);
    const main_path = try project.path(h.arena.allocator(), "src/main.zig");
    const main_text = fixture.basic[1].text;
    const main_uri = try open(&h, main_path, main_text);
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "main.zig", &.{"2:19 zig: expected type 'u32'"});

    // 构建进度一结束就保存修复后的文件：服务器此时还在发布这一轮的结果与重算编译集合
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = main_uri } });
    var build_token: ?[]const u8 = null;
    while (true) {
        const msg = try h.next();
        const method = msg.object.get("method") orelse continue;
        if (!std.mem.eql(u8, method.string, "$/progress")) continue;
        const params = msg.object.get("params").?.object;
        const token = params.get("token").?.string;
        const value = params.get("value").?.object;
        const kind = value.get("kind").?.string;
        if (std.mem.eql(u8, kind, "begin") and std.mem.startsWith(u8, value.get("title").?.string, "zig build")) build_token = token;
        if (std.mem.eql(u8, kind, "end") and build_token != null and std.mem.eql(u8, token, build_token.?)) break;
    }
    const fixed = try std.mem.replaceOwned(u8, a, main_text, "const x: u32 = \"不是数字\";", "const x: u32 = 1;");
    defer a.free(fixed);
    try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "src/main.zig", .data = fixed });
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = main_uri, .version = 2 }, .contentChanges = &.{.{ .text = fixed }} });
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = main_uri } });
    try waitIdle(&h);
    // 这次保存的构建请求丢失时，main.zig 仍挂着已修复的错误
    try expectDiagnostics(try h.diagnostics(), "main.zig", &.{});
    try shutdown(&h);
}

fn countRequests(h: *Harness, method: []const u8) usize {
    var n: usize = 0;
    for (h.received.items) |m| {
        if (m.object.get("id") == null) continue;
        const mm = m.object.get("method") orelse continue;
        if (std.mem.eql(u8, mm.string, method)) n += 1;
    }
    return n;
}

test "progress: nothing is sent when the client rejects the token" {
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    h.reject_requests = true;
    try initialize(&h, project.root, true);
    try waitIdle(&h);
    try shutdown(&h);
    try testing.expectEqual(0, (try h.notifications("$/progress")).len);
    try testing.expect(countRequests(&h, "window/workDoneProgress/create") >= 2);
}

test "progress: no create request when the client does not support it" {
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, false);
    try waitIdle(&h);
    try shutdown(&h);
    try testing.expectEqual(0, countRequests(&h, "window/workDoneProgress/create"));
}

const simple_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const exe = b.addExecutable(.{ .name = "t", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("main.zig"),
    \\        .target = b.graph.host,
    \\    }) });
    \\    b.installArtifact(exe);
    \\}
    \\
;

/// 只打开项目、等待构建，返回各文件最后一次发布的诊断
fn runProject(h: *Harness, project: *fixture.Project) !Diagnostics {
    try initialize(h, project.root, false);
    try waitIdle(h);
    try shutdown(h);
    return h.diagnostics();
}

test "compile errors in build.zig itself are published on build.zig" {
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const x: u32 = "s";
        \\    _ = x;
        \\    _ = b;
        \\}
        \\
        },
        .{ .path = "main.zig", .text = "pub fn main() void {}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const diags = try runProject(&h, &project);
    try expectDiagnostics(diags, "build.zig", &.{"2:19 zig: expected type 'u32'"});
}

const scripts_build =
    \\const std = @import("std");
    \\const helper = @import("build/helper.zig");
    \\pub fn build(b: *std.Build) void {
    \\    const exe = b.addExecutable(.{ .name = helper.name(), .root_module = b.createModule(.{
    \\        .root_source_file = b.path("main.zig"),
    \\        .target = b.graph.host,
    \\    }) });
    \\    b.installArtifact(exe);
    \\}
    \\
;
const scripts_helper = "pub fn name() []const u8 {\n    return \"demo\";\n}\n";
const scripts_zon = ".{\n    .name = .demo,\n    .version = \"0.0.0\",\n    .fingerprint = 0xd642dfa0858809cc,\n    .paths = .{\"\"},\n}\n";

fn change(h: *Harness, uri: []const u8, version: i64, text: []const u8) !void {
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = &.{.{ .text = text }} });
}

test "build scripts: live diagnostics in build.zig, build.zig.zon and files build.zig imports, changes to them reconfigure" {
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = scripts_build },
        .{ .path = "build/helper.zig", .text = scripts_helper },
        .{ .path = "build.zig.zon", .text = scripts_zon },
        .{ .path = "main.zig", .text = "pub fn main() void {}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initialize(&h, project.root, false);
    const build_uri = try open(&h, try project.path(a, "build.zig"), scripts_build);
    const helper_path = try project.path(a, "build/helper.zig");
    const helper_uri = try open(&h, helper_path, scripts_helper);
    const zon_path = try project.path(a, "build.zig.zon");
    const zon_uri = try open(&h, zon_path, scripts_zon);
    try waitIdle(&h);
    try testing.expect(h.server.workspaces.items[0].compile_set != null);

    // 未保存的语法错误：与编译集合中的文件一样有 live 诊断
    try change(&h, build_uri, 2, try std.mem.replaceOwned(u8, a, scripts_build, "@import(\"std\");", "@import(\"std\")"));
    try change(&h, helper_uri, 2, try std.mem.replaceOwned(u8, a, scripts_helper, "\"demo\";", "\"demo\""));
    try change(&h, zon_uri, 2, try std.mem.replaceOwned(u8, a, scripts_zon, "\"0.0.0\",", "\"0.0.0\""));
    try waitIdle(&h);
    const diags = try h.diagnostics();
    try expectDiagnostics(diags, "build.zig", &.{"zig ast-check: expected ';' after declaration"});
    try expectDiagnostics(diags, "helper.zig", &.{"zig ast-check: expected ';' after statement"});
    try expectDiagnostics(diags, "build.zig.zon", &.{"zig ast-check: expected ',' after initializer"});
    try change(&h, build_uri, 3, scripts_build);
    try change(&h, zon_uri, 3, scripts_zon);

    // 保存 build.zig 导入的文件：重新配置，构建程序的编译错误发布在这个文件上
    const bad_helper = try std.mem.replaceOwned(u8, a, scripts_helper, "\"demo\"", "42");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = helper_path, .data = bad_helper });
    try change(&h, helper_uri, 3, bad_helper);
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = helper_uri } });
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "helper.zig", &.{"zig: expected type '[]const u8', found 'comptime_int'"});

    // 编辑器之外改动它：同样重新配置
    try h.notify("textDocument/didClose", .{ .textDocument = .{ .uri = helper_uri } });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = helper_path, .data = try std.mem.replaceOwned(u8, a, scripts_helper, "\"demo\"", "true") });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = helper_uri, .type = 2 }} });
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "helper.zig", &.{"zig: expected type '[]const u8', found 'bool'"});

    // build.zig.zon 的错误不在 maker 发来的错误中：提示用户
    const bad_zon = try std.mem.replaceOwned(u8, a, scripts_zon, "0xd642dfa0858809cc", "0x1");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = zon_path, .data = bad_zon });
    try change(&h, zon_uri, 4, bad_zon);
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = zon_uri } });
    try waitIdle(&h);
    try testing.expect(anyContains(try shownMessages(&h), "zig build cannot load"));
    try shutdown(&h);
}

test "columns are UTF-16 when multi-byte characters precede the error" {
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = simple_build },
        .{ .path = "main.zig", .text =
        \\pub fn main() void {
        \\    const s = "中文😀"; const x: u32 = s;
        \\    _ = x;
        \\}
        \\
        },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const diags = try runProject(&h, &project);
    // `s` 位于字节列 43、UTF-16 列 37（中、文各 3 字节 1 单位，😀 4 字节 2 单位）
    try expectDiagnostics(diags, "main.zig", &.{"1:37 zig: expected type 'u32'"});
}

/// 在项目目录写出包装用户 zig 的脚本 zigw：除 `env` 外的命令先等待 2 秒。返回使用它的初始化选项
fn slowZig(h: *Harness, project: *fixture.Project) !std.json.Value {
    const zig = project.env.zig_exe;
    const script = try std.fmt.allocPrint(h.arena.allocator(),
        \\#!/bin/sh
        \\if [ "$1" = env ]; then exec "{s}" "$@"; fi
        \\sleep 2
        \\exec "{s}" "$@"
        \\
    , .{ zig, zig });
    try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "zigw", .data = script, .flags = .{ .permissions = .executable_file } });
    return jsonValue(h, try std.fmt.allocPrint(h.arena.allocator(), "{{\"zig\": {{\"path\": \"{s}/zigw\"}}}}", .{project.root}));
}

test "single-file mode: compile one file without build.zig, with progress" {
    const text =
        \\pub fn main() void {
        \\    const x: u32 = "s";
        \\    _ = x;
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{.{ .path = "one.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, true);
    try waitIdle(&h);
    _ = try open(&h, try project.path(h.arena.allocator(), "one.zig"), text);
    try waitIdle(&h);
    try shutdown(&h);
    try expectDiagnostics(try h.diagnostics(), "one.zig", &.{"1:19 zig: expected type 'u32'"});
    const titles = try progressTitles(&h);
    try testing.expect(titles.len >= 1);
    try testing.expectEqualStrings("Compiling one.zig", titles[0]);
}

test "single-file mode: disabling compiler diagnostics during a compile drops its result" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const text =
        \\pub fn main() void {
        \\    const x: u32 = "s";
        \\    _ = x;
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{.{ .path = "one.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initializeWith(&h, project.root, true, try slowZig(&h, &project));
    const uri = try open(&h, try project.path(h.arena.allocator(), "one.zig"), text);
    // 等到编译器任务开始（包装脚本随后还会睡眠 2 秒）
    while (true) {
        const m = try h.next();
        const method = if (m.object.get("method")) |x| x.string else continue;
        if (!std.mem.eql(u8, method, "$/progress")) continue;
        const value = m.object.get("params").?.object.get("value").?.object;
        if (!std.mem.eql(u8, value.get("kind").?.string, "begin")) continue;
        if (std.mem.eql(u8, value.get("title").?.string, "Compiling one.zig")) break;
    }
    // 编译结束前关闭编译器诊断：旧任务的结果必须被丢弃
    try h.notify("workspace/didChangeConfiguration", .{ .settings = try jsonValue(&h,
        \\{"zig-analyzer": {"diagnostics": {"compiler": false}}}
    ) });
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "one.zig", &.{});
    try expectNoErrors(&h, uri);
    try shutdown(&h);
}

test "single-file mode: closing a file without errors drops its result" {
    const text = "pub fn main() void {}\n";
    var project = try fixture.Project.create(&.{.{ .path = "one.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, false);
    try waitIdle(&h);
    const uri = try open(&h, try project.path(h.arena.allocator(), "one.zig"), text);
    try waitIdle(&h);
    {
        h.server.single_mutex.lockUncancelable(testing.io);
        defer h.server.single_mutex.unlock(testing.io);
        try testing.expectEqual(1, h.server.single.count());
    }
    try h.notify("textDocument/didClose", .{ .textDocument = .{ .uri = uri } });
    try waitIdle(&h);
    {
        h.server.single_mutex.lockUncancelable(testing.io);
        defer h.server.single_mutex.unlock(testing.io);
        try testing.expectEqual(0, h.server.single.count());
    }
    try shutdown(&h);
}

test "inactive hints are not published inside compiler errors" {
    const text =
        \\const builtin = @import("builtin");
        \\export fn entry() u32 {
        \\    if (builtin.is_test) {
        \\        return 0;
        \\    } else {
        \\        const x: u32 = "oops";
        \\        return x;
        \\    }
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{.{ .path = "one.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, false);
    try waitIdle(&h);
    const uri = try open(&h, try project.path(h.arena.allocator(), "one.zig"), text);
    try waitIdle(&h);
    var last: ?[]const std.json.Value = null;
    for (try h.notifications("textDocument/publishDiagnostics")) |message| {
        const params = message.object.get("params").?.object;
        if (!std.mem.eql(u8, params.get("uri").?.string, uri)) continue;
        last = params.get("diagnostics").?.array.items;
    }
    var saw_compiler_error = false;
    for (last orelse return error.NoDiagnostics) |d| {
        const source = d.object.get("source").?.string;
        if (std.mem.eql(u8, source, "zig")) saw_compiler_error = true;
        try testing.expect(!std.mem.eql(u8, source, "zig-analyzer") or
            std.mem.indexOf(u8, d.object.get("message").?.string, "code is inactive") == null);
    }
    try testing.expect(saw_compiler_error);
    try shutdown(&h);
}

test "files of the zig installation are not standalone compilation roots during startup or save" {
    const text =
        \\pub fn main() void {
        \\    const x: u32 = "s";
        \\    _ = x;
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{.{ .path = "one.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const std_path = try std.fs.path.join(a, &.{ project.env.std_dir, "std.zig" });
    const std_text = try std.Io.Dir.cwd().readFileAlloc(testing.io, std_path, a, .limited(2 * 1024 * 1024));
    try initialize(&h, project.root, true);
    const std_uri = try open(&h, std_path, std_text);
    try waitIdle(&h);
    try expectNoErrors(&h, std_uri);
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = std_uri } });
    // 标准库以外的文件同样只作为依赖参与编译：单独编译它们缺少构建系统提供的模块与 builtin 成员
    var lib_uris: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "configurer.zig", "test_runner.zig" }) |name| {
        const path = try std.fs.path.join(a, &.{ project.env.lib_dir, "compiler", name });
        const lib_text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(2 * 1024 * 1024));
        try lib_uris.append(a, try open(&h, path, lib_text));
    }
    _ = try open(&h, try project.path(a, "one.zig"), text);
    try waitIdle(&h);
    const diags = try h.diagnostics();
    try expectNoErrors(&h, std_uri);
    for (lib_uris.items) |u| try expectNoErrors(&h, u);
    try expectDiagnostics(diags, "one.zig", &.{"1:19 zig: expected type 'u32'"});
    try shutdown(&h);
    for (try progressTitles(&h)) |title| {
        if (std.mem.startsWith(u8, title, "Compiling ")) try testing.expectEqualStrings("Compiling one.zig", title);
    }
}

test "single-file mode: errors a root reports in the standard library are published there, also once a project is added" {
    const bad =
        \\const std = @import("std");
        \\pub fn main() void {
        \\    std.debug.print("{d}\n", .{});
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{
        .{ .path = "scratch/one.zig", .text = bad },
        .{ .path = "proj/build.zig", .text = simple_build },
        .{ .path = "proj/main.zig", .text = "pub fn main() void {}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initialize(&h, try project.path(a, "scratch"), false);
    const one_path = try project.path(a, "scratch/one.zig");
    const one_uri = try open(&h, one_path, bad);
    try waitIdle(&h);
    // 错误的位置在标准库中，one.zig 自身没有错误：发布在标准库的文件上
    var diags = try h.diagnostics();
    try expectDiagnostics(diags, "one.zig", &.{});
    try expectDiagnostics(diags, "Writer.zig", &.{"zig: too few arguments"});

    // 加入一个项目：标准库也在它的编译集合中，单文件编译的结果仍然用于标准库的文件
    const proj_uri = try za.base.uri.fromPath(a, try project.path(a, "proj"));
    try h.notify("workspace/didChangeWorkspaceFolders", .{ .event = .{ .added = &.{.{ .uri = proj_uri, .name = "proj" }}, .removed = &[_]Empty{} } });
    try waitIdle(&h);
    try testing.expectEqual(1, h.server.workspaces.items.len);
    try expectDiagnostics(try h.diagnostics(), "Writer.zig", &.{"zig: too few arguments"});

    // 修复并保存 one.zig：标准库中的错误随之清除
    const fixed = try std.mem.replaceOwned(u8, a, bad, ".{});", ".{1});");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = one_path, .data = fixed });
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = one_uri, .version = 2 }, .contentChanges = &.{.{ .text = fixed }} });
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = one_uri } });
    try waitIdle(&h);
    diags = try h.diagnostics();
    try expectDiagnostics(diags, "one.zig", &.{});
    try expectDiagnostics(diags, "Writer.zig", &.{});
    try shutdown(&h);
}

/// 构建根目录（project）之外的模块：dep.zig 按名字 import support，只有在项目的模块图中才能解析
const outside_root = [_]fixture.File{
    .{ .path = "project/build.zig", .text =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const support = b.createModule(.{ .root_source_file = .{ .cwd_relative = "../dependency/support.zig" } });
    \\    const dep = b.createModule(.{
    \\        .root_source_file = .{ .cwd_relative = "../dependency/dep.zig" },
    \\        .imports = &.{.{ .name = "support", .module = support }},
    \\    });
    \\    const root = b.createModule(.{
    \\        .root_source_file = b.path("main.zig"),
    \\        .target = b.graph.host,
    \\        .imports = &.{.{ .name = "dep", .module = dep }},
    \\    });
    \\    b.step("check", "Check").dependOn(&b.addObject(.{ .name = "probe", .root_module = root }).step);
    \\}
    \\
    },
    .{ .path = "project/main.zig", .text = "export fn entry() u32 {\n    return @import(\"dep\").value();\n}\n" },
    .{ .path = "dependency/dep.zig", .text = dep_good },
    .{ .path = "dependency/support.zig", .text = support_text },
};
const dep_good = "const support = @import(\"support\");\npub fn value() u32 {\n    return support.answer;\n}\n";
const dep_bad = "const support = @import(\"support\");\npub fn value() u32 {\n    _ = support.answer;\n    return \"bad\";\n}\n";
const support_text = "pub const answer: u32 = 1;\n";

fn countTitles(titles: []const []const u8, title: []const u8) usize {
    var n: usize = 0;
    for (titles) |t| {
        if (std.mem.eql(u8, t, title)) n += 1;
    }
    return n;
}

/// 保存文件：写入磁盘，同步缓冲区，再通知保存
fn save(h: *Harness, path: []const u8, file_uri: []const u8, version: i64, text: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = text });
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = file_uri, .version = version }, .contentChanges = &.{.{ .text = text }} });
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = file_uri } });
}

test "modules outside the build root: never compiled alone, saving them rebuilds the project, renamable" {
    var project = try fixture.Project.create(&outside_root);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initialize(&h, try project.path(a, "project"), true);
    // 项目加载期间打开：此时还不知道 dep.zig 属于项目，单文件编译推迟到加载结束，届时它已归入项目
    const dep_path = try project.path(a, "dependency/dep.zig");
    const dep_uri = try open(&h, dep_path, dep_good);
    try waitIdle(&h);
    // 加载之后打开
    _ = try open(&h, try project.path(a, "dependency/support.zig"), support_text);
    try waitIdle(&h);
    const builds = countTitles(try progressTitles(&h), "zig build check");
    try testing.expect(builds >= 1);

    // 只保存 dep.zig：项目重新构建，在真实的模块图中报告错误（而不是找不到 support）
    try save(&h, dep_path, dep_uri, 2, dep_bad);
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "dep.zig", &.{"3:11 zig: expected type 'u32'"});
    try testing.expect(countTitles(try progressTitles(&h), "zig build check") > builds);

    // 根目录外、属于项目的用户代码可以重命名
    const prepared = try h.request("textDocument/prepareRename", .{ .textDocument = .{ .uri = dep_uri }, .position = .{ .line = 1, .character = 8 } });
    try testing.expect(prepared.object.get("error") == null);
    try testing.expect(prepared.object.get("result").? != .null);

    // 修复后同样只保存 dep.zig：错误被清除
    try save(&h, dep_path, dep_uri, 3, dep_good);
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "dep.zig", &.{});
    try shutdown(&h);
    for (try progressTitles(&h)) |title| try testing.expect(!std.mem.startsWith(u8, title, "Compiling"));
}

/// 以绝对路径（相对于构建根目录）共用 shared/x.zig 的项目
const shared_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const shared = b.createModule(.{ .root_source_file = .{ .cwd_relative = "../shared/x.zig" } });
    \\    const root = b.createModule(.{
    \\        .root_source_file = b.path("main.zig"),
    \\        .target = b.graph.host,
    \\        .imports = &.{.{ .name = "shared", .module = shared }},
    \\    });
    \\    b.step("check", "Check").dependOn(&b.addObject(.{ .name = "probe", .root_module = root }).step);
    \\}
    \\
;
const shared_good = "pub fn fine() u32 {\n    return 1;\n}\npub fn broken() u32 {\n    return 2;\n}\n";
const shared_bad = "pub fn fine() u32 {\n    return 1;\n}\npub fn broken() u32 {\n    return \"x\";\n}\n";

test "a module shared by two projects: saving it rebuilds both, the errors of either build are published" {
    var project = try fixture.Project.create(&.{
        // b 不调用 broken：它的构建不分析其中的错误
        .{ .path = "b/build.zig", .text = shared_build },
        .{ .path = "b/main.zig", .text = "export fn entry() u32 {\n    return @import(\"shared\").fine();\n}\n" },
        .{ .path = "a/build.zig", .text = shared_build },
        .{ .path = "a/main.zig", .text = "export fn entry() u32 {\n    return @import(\"shared\").broken();\n}\n" },
        .{ .path = "shared/x.zig", .text = shared_good },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    const folders = [_]struct { uri: []const u8, name: []const u8 }{
        .{ .uri = try za.base.uri.fromPath(a, try project.path(a, "b")), .name = "b" },
        .{ .uri = try za.base.uri.fromPath(a, try project.path(a, "a")), .name = "a" },
    };
    _ = try h.request("initialize", .{ .capabilities = .{ .window = .{ .workDoneProgress = true } }, .workspaceFolders = &folders });
    try h.notify("initialized", Empty{});
    const x_path = try project.path(a, "shared/x.zig");
    const x_uri = try open(&h, x_path, shared_good);
    try waitIdle(&h);
    try testing.expectEqual(2, h.server.workspaces.items.len);
    try testing.expect(std.mem.endsWith(u8, h.server.workspaces.items[0].root, "b"));
    const builds = countTitles(try progressTitles(&h), "zig build check");

    // 只有 a 的构建报告 x.zig 中的错误；包含 x.zig 的第一个项目是 b
    try save(&h, x_path, x_uri, 2, shared_bad);
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "x.zig", &.{"4:11 zig: expected type 'u32'"});
    try testing.expect(countTitles(try progressTitles(&h), "zig build check") >= builds + 2);

    try save(&h, x_path, x_uri, 3, shared_good);
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "x.zig", &.{});
    try shutdown(&h);
    for (try progressTitles(&h)) |title| try testing.expect(!std.mem.startsWith(u8, title, "Compiling"));
}

/// 按哈希获取的依赖包（伪造：包目录中已经有它时 maker 不再获取）。项目用 `--pkg-dir` 把包目录放在构建根目录之外
const fetched_hash = "foo-0.0.1-OjQ08eFlFQAb4BLnwZNNE3R5Dx2TI67EIpAsy2h0ZyoC";
const fetched_package = [_]fixture.File{
    .{ .path = "proj/build.zig.zon", .text = ".{ .name = .proj, .version = \"0.0.0\", .fingerprint = 0x520c3c90be36badb, .paths = .{\"\"}, " ++
        ".dependencies = .{ .foo = .{ .url = \"https://example.invalid/foo.tar.gz\", .hash = \"" ++ fetched_hash ++ "\" } } }\n" },
    .{ .path = "proj/build.zig", .text =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const foo = b.dependency("foo", .{});
    \\    const root = b.createModule(.{
    \\        .root_source_file = b.path("main.zig"),
    \\        .target = b.graph.host,
    \\        .imports = &.{.{ .name = "foo", .module = foo.module("foo") }},
    \\    });
    \\    b.step("check", "Check").dependOn(&b.addObject(.{ .name = "probe", .root_module = root }).step);
    \\}
    \\
    },
    .{ .path = "proj/main.zig", .text = "export fn entry() u32 {\n    return @import(\"foo\").answer();\n}\n" },
    .{ .path = "proj/zig-analyzer.json", .text = "{\"build\": {\"args\": [\"--pkg-dir\", \"../pkgs\"]}}" },
    .{ .path = "pkgs/" ++ fetched_hash ++ "/build.zig.zon", .text = ".{ .name = .foo, .version = \"0.0.1\", .fingerprint = 0x8c736521e67512df, .paths = .{\"\"} }\n" },
    .{ .path = "pkgs/" ++ fetched_hash ++ "/build.zig", .text =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    _ = b.addModule("foo", .{ .root_source_file = b.path("src/root.zig") });
    \\}
    \\
    },
    .{ .path = "pkgs/" ++ fetched_hash ++ "/src/root.zig", .text = fetched_root },
    // 没有被任何模块用到的文件
    .{ .path = "pkgs/" ++ fetched_hash ++ "/src/unused.zig", .text = "const x: u32 = \"s\";\ncomptime {\n    _ = x;\n}\n" },
};
const fetched_root = "pub fn answer() u32 {\n    return 42;\n}\n";

test "fetched packages outside the build root are libraries: never compiled alone, not renamable" {
    var project = try fixture.Project.create(&fetched_package);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initialize(&h, try project.path(a, "proj"), true);
    try waitIdle(&h);
    {
        const ws = h.server.workspaces.items[0];
        ws.mutex.lockUncancelable(testing.io);
        defer ws.mutex.unlock(testing.io);
        const roots = ws.model.?.package_roots;
        try testing.expectEqual(1, roots.len);
        try testing.expectEqualStrings(try std.fs.path.join(a, &.{ project.root, "pkgs", fetched_hash }), roots[0]);
    }
    const pkg = "pkgs/" ++ fetched_hash ++ "/src/";
    const root_uri = try open(&h, try project.path(a, pkg ++ "root.zig"), fetched_root);
    const unused_path = try project.path(a, pkg ++ "unused.zig");
    const unused_text = try std.Io.Dir.cwd().readFileAlloc(testing.io, unused_path, a, .limited(1024));
    const unused_uri = try open(&h, unused_path, unused_text);
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = unused_uri } });
    try waitIdle(&h);
    try expectNoErrors(&h, unused_uri);
    const prepared = try h.request("textDocument/prepareRename", .{ .textDocument = .{ .uri = root_uri }, .position = .{ .line = 0, .character = 9 } });
    try testing.expect(prepared.object.get("error") != null);
    try shutdown(&h);
    for (try progressTitles(&h)) |title| try testing.expect(!std.mem.startsWith(u8, title, "Compiling"));
}

test "single-file mode: errors in imported files are published on them and cleared after a fix" {
    const a_text =
        \\const b = @import("b.zig");
        \\export fn entry() u32 {
        \\    return b.foo(1);
        \\}
        \\
    ;
    const b_text =
        \\const T = u32;
        \\comptime {
        \\    _ = @as(T, "x");
        \\}
        \\pub fn foo(x: u32) u32 {
        \\    const y: T = "s";
        \\    _ = y;
        \\    return x;
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{ .{ .path = "a.zig", .text = a_text }, .{ .path = "b.zig", .text = b_text } });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, false);
    try waitIdle(&h);
    const arena = h.arena.allocator();

    // 编译 a.zig 时报告在 b.zig 中的错误发布在 b.zig 上（b.zig 尚未打开）
    const a_path = try project.path(arena, "a.zig");
    const a_uri = try open(&h, a_path, a_text);
    try waitIdle(&h);
    var diags = try h.diagnostics();
    try expectDiagnostics(diags, "a.zig", &.{});
    try expectDiagnostics(diags, "b.zig", &.{ "2:15 zig: expected type 'u32'", "5:17 zig: expected type 'u32'" });

    // 打开 b.zig：单独编译 b.zig 只报告 comptime 块中的错误，与 a.zig 的编译结果合并（相同的错误只保留一条）
    const b_path = try project.path(arena, "b.zig");
    const b_uri = try open(&h, b_path, b_text);
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "b.zig", &.{ "2:15 zig: expected type 'u32'", "5:17 zig: expected type 'u32'" });

    // 在错误位置之外修复并保存 b.zig：在 b.zig 中报告过错误的 a.zig 随之重新编译，错误全部被清除
    const fixed = try std.mem.replaceOwned(u8, arena, b_text, "T = u32", "T = []const u8");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = b_path, .data = fixed });
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = b_uri, .version = 2 }, .contentChanges = &.{.{ .text = fixed }} });
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = b_uri } });
    try waitIdle(&h);
    diags = try h.diagnostics();
    try expectDiagnostics(diags, "a.zig", &.{});
    try expectDiagnostics(diags, "b.zig", &.{});

    // 再把错误改回去并保存：a.zig 上一次编译读取过 b.zig（虽然没有在其中报告错误），同样重新编译
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = b_path, .data = b_text });
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = b_uri, .version = 3 }, .contentChanges = &.{.{ .text = b_text }} });
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = b_uri } });
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "b.zig", &.{ "2:15 zig: expected type 'u32'", "5:17 zig: expected type 'u32'" });

    // 关闭 a.zig 并在编辑器之外删除它：丢弃它的编译结果，b.zig 上只剩单独编译 b.zig 报告的错误
    try h.notify("textDocument/didClose", .{ .textDocument = .{ .uri = a_uri } });
    try std.Io.Dir.cwd().deleteFile(testing.io, a_path);
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = a_uri, .type = 3 }} });
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "b.zig", &.{"2:15 zig: expected type 'u32'"});

    // 重新创建并打开 a.zig（自身也有错误），先在编辑器之外删除再关闭：删除时 a.zig 仍打开着，
    // 关闭时同样丢弃它的编译结果
    const a_bad = a_text ++ "comptime {\n    _ = @as(u8, 300);\n}\n";
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = a_path, .data = a_bad });
    _ = try open(&h, a_path, a_bad);
    try waitIdle(&h);
    diags = try h.diagnostics();
    try expectDiagnostics(diags, "a.zig", &.{"5:16 zig: type 'u8' cannot represent integer value '300'"});
    try expectDiagnostics(diags, "b.zig", &.{ "2:15 zig: expected type 'u32'", "5:17 zig: expected type 'u32'" });
    try std.Io.Dir.cwd().deleteFile(testing.io, a_path);
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = a_uri, .type = 3 }} });
    try h.notify("textDocument/didClose", .{ .textDocument = .{ .uri = a_uri } });
    try waitIdle(&h);
    diags = try h.diagnostics();
    try expectDiagnostics(diags, "a.zig", &.{});
    try expectDiagnostics(diags, "b.zig", &.{"2:15 zig: expected type 'u32'"});
    try shutdown(&h);
}

test "single-file mode: a root deleted while it compiles leaves no diagnostics" {
    const text =
        \\comptime {
        \\    _ = @as(u8, 300);
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{.{ .path = "a.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, true);
    try waitIdle(&h);
    const path = try project.path(h.arena.allocator(), "a.zig");
    const a_uri = try open(&h, path, text);
    // 编译开始（请求创建进度）后在编辑器之外删除 a.zig 再关闭：这次编译的结果不再发布
    while (true) {
        const msg = try h.next();
        const method = msg.object.get("method") orelse continue;
        if (std.mem.eql(u8, method.string, "window/workDoneProgress/create")) break;
    }
    try std.Io.Dir.cwd().deleteFile(testing.io, path);
    try h.notify("textDocument/didClose", .{ .textDocument = .{ .uri = a_uri } });
    try waitIdle(&h);
    try shutdown(&h);
    try expectDiagnostics(try h.diagnostics(), "a.zig", &.{});
}

test "generated module roots: resolved from build results, including modules check does not depend on" {
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const opts = b.addOptions();
        \\    opts.addOption(u32, "answer", 42);
        \\    const exe = b.addExecutable(.{ .name = "t", .root_module = b.createModule(.{
        \\        .root_source_file = b.path("main.zig"),
        \\        .target = b.graph.host,
        \\        .imports = &.{.{ .name = "build_options", .module = opts.createModule() }},
        \\    }) });
        \\    b.step("check", "Check").dependOn(&exe.step);
        \\
        \\    const test_opts = b.addOptions();
        \\    test_opts.addOption(bool, "in_test", true);
        \\    const tests = b.addTest(.{ .root_module = b.createModule(.{
        \\        .root_source_file = b.path("t.zig"),
        \\        .target = b.graph.host,
        \\        .imports = &.{.{ .name = "test_options", .module = test_opts.createModule() }},
        \\    }) });
        \\    b.step("test", "Test").dependOn(&b.addRunArtifact(tests).step);
        \\}
        \\
        },
        .{ .path = "main.zig", .text =
        \\const opts = @import("build_options");
        \\pub fn main() void {
        \\    const x: bool = opts.answer;
        \\    _ = x;
        \\}
        \\
        },
        .{ .path = "t.zig", .text = "const o = @import(\"test_options\");\ntest {\n    const x: u8 = o.in_test;\n    _ = x;\n}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, false);
    try waitIdle(&h);

    // 编译器诊断与 zig build check 一致：只有 main.zig 的错误，test step 的 t.zig 没有诊断
    const diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{"2:20 zig: expected type 'bool', found 'u32'"});
    try testing.expect(diags.get("t.zig") == null);

    const ws = h.server.workspaces.items[0];
    ws.mutex.lockUncancelable(testing.io);
    defer ws.mutex.unlock(testing.io);
    // 两个生成的模块根文件（包括 check 不依赖的 test_options）都已得知路径
    var generated: usize = 0;
    for (ws.model.?.modules) |m| {
        if (m.generated_root == null) continue;
        generated += 1;
        try testing.expect(std.mem.endsWith(u8, m.root_file.?, "options.zig"));
        try testing.expect(std.fs.path.isAbsolute(m.root_file.?));
    }
    try testing.expectEqual(2, generated);
    // 编译集合只含 check 用到的生成文件
    var in_set: usize = 0;
    for (ws.compile_set.?.files.keys()) |f| {
        if (std.mem.endsWith(u8, h.server.vfs.path(f), "options.zig")) in_set += 1;
    }
    try testing.expectEqual(1, in_set);
}

/// 以生成的 options 模块为 `build_options` 的项目
const options_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const opts = b.addOptions();
    \\    opts.addOption(u32, "answer", 42);
    \\    const exe = b.addExecutable(.{ .name = "t", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("main.zig"),
    \\        .target = b.graph.host,
    \\        .imports = &.{.{ .name = "build_options", .module = opts.createModule() }},
    \\    }) });
    \\    b.step("check", "Check").dependOn(&exe.step);
    \\}
    \\
;
const options_main =
    \\const opts = @import("build_options");
    \\pub fn main() void {
    \\    _ = opts.answer;
    \\}
    \\
;

// 防止本地缓存目录固定按 `<构建根>/.zig-cache` 计算：`--cache-dir`（或 `ZIG_LOCAL_CACHE_DIR`）把生成文件放到
// 别处时，生成的模块根文件的路径不存在，模块中的名字全部无法解析
test "generated module roots: local cache directory moved with --cache-dir" {
    const main_text = options_main;
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = options_build },
        .{ .path = "main.zig", .text = main_text },
        // 相对路径相对于构建根目录
        .{ .path = "zig-analyzer.json", .text = "{\"build\": {\"args\": [\"--cache-dir\", \"altcache\"]}}" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, false);
    try waitIdle(&h);
    const a = h.arena.allocator();
    {
        const ws = h.server.workspaces.items[0];
        ws.mutex.lockUncancelable(testing.io);
        defer ws.mutex.unlock(testing.io);
        const cache = try project.path(a, "altcache");
        try testing.expectEqualStrings(cache, ws.model.?.local_cache_root);
        var generated: usize = 0;
        for (ws.model.?.modules) |m| {
            if (m.generated_root == null) continue;
            generated += 1;
            try testing.expect(std.mem.startsWith(u8, m.root_file.?, cache));
            try std.Io.Dir.cwd().access(testing.io, m.root_file.?, .{});
        }
        try testing.expectEqual(1, generated);
    }
    const uri = try open(&h, try project.path(a, "main.zig"), main_text);
    try waitIdle(&h);
    const resp = try h.request("textDocument/hover", .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 2, .character = 14 } });
    const result = resp.object.get("result").?;
    try testing.expect(result == .object);
    const value = result.object.get("contents").?.object.get("value").?.string;
    try testing.expect(std.mem.indexOf(u8, value, "answer: u32 = 42") != null);
    // 生成文件位于构建根目录下的 altcache 中，不能重命名（maker 会覆盖改动）
    const rename_at = .{ .textDocument = .{ .uri = uri }, .position = .{ .line = 2, .character = 14 } };
    try testing.expect((try h.request("textDocument/prepareRename", rename_at)).object.get("error") != null);
    const rename = .{ .textDocument = rename_at.textDocument, .position = rename_at.position, .newName = "answer2" };
    try testing.expect((try h.request("textDocument/rename", rename)).object.get("error") != null);
    try shutdown(&h);
}

test "generated files in a local cache directory outside the build root: never compiled alone, not renamable" {
    var project = try fixture.Project.create(&.{
        .{ .path = "proj/build.zig", .text = options_build },
        .{ .path = "proj/main.zig", .text = options_main },
        .{ .path = "proj/zig-analyzer.json", .text = "{\"build\": {\"args\": [\"--cache-dir\", \"../cache\"]}}" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initialize(&h, try project.path(a, "proj"), true);
    try waitIdle(&h);
    const cache = try std.fs.path.join(a, &.{ project.root, "cache" });
    const generated = blk: {
        const ws = h.server.workspaces.items[0];
        ws.mutex.lockUncancelable(testing.io);
        defer ws.mutex.unlock(testing.io);
        try testing.expectEqualStrings(cache, ws.model.?.local_cache_root);
        for (ws.model.?.modules) |m| if (m.generated_root != null) break :blk try a.dupe(u8, m.root_file.?);
        return error.TestUnexpectedResult;
    };
    try testing.expect(std.mem.startsWith(u8, generated, cache));

    // 打开、保存生成的 options.zig：它只作为项目的依赖参与编译
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, generated, a, .limited(1024 * 1024));
    const uri = try open(&h, generated, text);
    try waitIdle(&h);
    try h.notify("textDocument/didSave", .{ .textDocument = .{ .uri = uri } });
    try waitIdle(&h);
    try expectNoErrors(&h, uri);
    // 其中的定义由 maker 生成，不能重命名
    const offset = std.mem.indexOf(u8, text, "answer").?;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..offset], '\n')) |i| i + 1 else 0;
    const position = .{ .line = std.mem.count(u8, text[0..offset], "\n"), .character = offset - line_start + 1 };
    try testing.expect((try h.request("textDocument/prepareRename", .{ .textDocument = .{ .uri = uri }, .position = position })).object.get("error") != null);
    try shutdown(&h);
    for (try progressTitles(&h)) |title| try testing.expect(!std.mem.startsWith(u8, title, "Compiling"));
}

/// 配置测试的项目：`-Dbad=true` 时 main.zig 中被屏蔽的错误出现；`unit` step 编译 t.zig（有错误）
const settings_project: []const fixture.File = &.{
    .{ .path = "build.zig", .text =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const opts = b.addOptions();
    \\    opts.addOption(bool, "bad", b.option(bool, "bad", "inject an error") orelse false);
    \\    const exe = b.addExecutable(.{ .name = "t", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("main.zig"),
    \\        .target = b.graph.host,
    \\        .imports = &.{.{ .name = "build_options", .module = opts.createModule() }},
    \\    }) });
    \\    b.step("check", "Check").dependOn(&exe.step);
    \\    const tests = b.addTest(.{ .root_module = b.createModule(.{
    \\        .root_source_file = b.path("t.zig"),
    \\        .target = b.graph.host,
    \\    }) });
    \\    b.step("unit", "Unit tests").dependOn(&tests.step);
    \\}
    \\
    },
    .{ .path = "main.zig", .text =
    \\const o = @import("build_options");
    \\pub fn main() void {
    \\    if (o.bad) {
    \\        const x: u32 = "s";
    \\        _ = x;
    \\    }
    \\}
    \\
    },
    .{ .path = "t.zig", .text = "test {\n    const y: u8 = \"t\";\n    _ = y;\n}\n" },
};

test "settings: -D build args from initializationOptions, diagnostics.step change restarts the project" {
    var project = try fixture.Project.create(settings_project);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();

    // 1. -Dbad=true：分支被分析，报错（不带参数时 o.bad 为 false，分支不会被分析）
    try initializeWith(&h, project.root, false, try jsonValue(&h,
        \\{"build": {"args": ["-Dbad=true"]}}
    ));
    try waitIdle(&h);
    var diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{"3:23 zig: expected type 'u32'"});
    try testing.expect(diags.get("t.zig") == null);

    // 2. 改为用 unit step 诊断、去掉 -D 参数：项目重启，main.zig 的旧诊断被清除，t.zig 报错
    try h.notify("workspace/didChangeConfiguration", .{ .settings = try jsonValue(&h,
        \\{"zig-analyzer": {"diagnostics": {"step": "unit"}}}
    ) });
    try waitIdle(&h);
    diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{});
    try expectDiagnostics(diags, "t.zig", &.{"1:18 zig: expected type 'u8'"});
    try shutdown(&h);
}

test "settings: pulled with workspace/configuration at startup and on change notifications without content" {
    var project = try fixture.Project.create(settings_project);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    h.configuration = try jsonValue(&h,
        \\{"build": {"args": ["-Dbad=true"]}}
    );
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = .{ .workspace = .{
        .configuration = true,
        .didChangeConfiguration = .{ .dynamicRegistration = true },
    } } });
    try h.notify("initialized", Empty{});
    try waitIdle(&h);
    // 启动前拉取到的构建参数生效
    var diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{"3:23 zig: expected type 'u32'"});

    // 配置变化通知不带内容：服务器重新拉取
    h.configuration = try jsonValue(&h,
        \\{"diagnostics": {"step": "unit"}}
    );
    try h.notify("workspace/didChangeConfiguration", .{ .settings = null });
    try waitIdle(&h);
    diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{});
    try expectDiagnostics(diags, "t.zig", &.{"1:18 zig: expected type 'u8'"});
    try shutdown(&h);

    try testing.expectEqual(1, countRequests(&h, "client/registerCapability"));
    try testing.expectEqual(2, countRequests(&h, "workspace/configuration"));
}

test "few CPU cores: async tasks run inline, waitIdle, progress and pulled settings still work" {
    // 模拟 CI 等核数少的机器：`async` 全部在调用方线程同步执行
    const old_limit = testing.io_instance.async_limit;
    testing.io_instance.setAsyncLimit(.nothing);
    defer testing.io_instance.setAsyncLimit(old_limit);

    var project = try fixture.Project.create(settings_project);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    h.configuration = try jsonValue(&h,
        \\{"build": {"args": ["-Dbad=true"]}}
    );
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = .{
        .window = .{ .workDoneProgress = true },
        .workspace = .{ .configuration = true },
    } });
    try h.notify("initialized", Empty{});
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "main.zig", &.{"3:23 zig: expected type 'u32'"});

    // 配置变化后重新拉取，waitIdle 等到项目重启并构建完成
    h.configuration = try jsonValue(&h,
        \\{"diagnostics": {"step": "unit"}}
    );
    try h.notify("workspace/didChangeConfiguration", .{ .settings = null });
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "t.zig", &.{"1:18 zig: expected type 'u8'"});
    try shutdown(&h);

    // 主循环没有被阻塞：create 的响应在构建结束前被处理，进度正常发送
    var builds: usize = 0;
    for (try progressTitles(&h)) |t| {
        if (std.mem.startsWith(u8, t, "zig build")) builds += 1;
    }
    try testing.expect(builds >= 2);
}

/// 在项目目录写出包装用户 zig 的脚本 zigw：`zig env` 报告另一个版本，其余命令照常执行。返回使用它的初始化选项
fn mismatchedZig(h: *Harness, project: *fixture.Project) !std.json.Value {
    const zig = project.env.zig_exe;
    const script = try std.fmt.allocPrint(h.arena.allocator(),
        \\#!/bin/sh
        \\if [ "$1" = env ]; then "{s}" env | sed 's/\.version = "[^"]*"/.version = "0.0.0-mismatch"/'; else exec "{s}" "$@"; fi
        \\
    , .{ zig, zig });
    try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "zigw", .data = script, .flags = .{ .permissions = .executable_file } });
    return jsonValue(h, try std.fmt.allocPrint(h.arena.allocator(), "{{\"zig\": {{\"path\": \"{s}/zigw\"}}}}", .{project.root}));
}

test "zig version mismatch: no build system is started, live diagnostics run zig ast-check outside the read transaction" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initializeWith(&h, project.root, true, try mismatchedZig(&h, &project));
    const lib_path = try project.path(h.arena.allocator(), "src/lib.zig");
    const lib_uri = try open(&h, lib_path, fixture.basic[2].text);
    try waitIdle(&h);

    // 不启动构建系统：没有一直不结束的加载进度，也没有编译器诊断
    try testing.expectEqual(0, h.server.workspaces.items.len);
    try expectProgressEnded(&h);
    // 提示写出两个版本以及受影响的功能
    const messages = try shownMessages(&h);
    const expected_head = "zig 0.0.0-mismatch differs from zig " ++ @import("builtin").zig_version_string ++ " that zig-analyzer was built with.";
    try testing.expect(anyContains(messages, expected_head));
    try testing.expect(anyContains(messages, "imports of named modules (dependencies, build options) are not resolved"));
    // live 诊断来自子进程 zig ast-check，在读事务之外取得
    {
        var ctx = h.server.db.beginRead(testing.allocator);
        defer ctx.end();
        try testing.expect(try ctx.get(live.LiveBackend, {}) == .subprocess);
    }
    const hits = h.server.live_prepared.hits;
    const edited = "pub fn hello() void {\n    var unused = 1;\n    var other = 2;\n}\n";
    try h.notify("textDocument/didChange", .{ .textDocument = .{ .uri = lib_uri, .version = 2 }, .contentChanges = &.{.{ .text = edited }} });
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "lib.zig", &.{ "2:8 zig ast-check: unused local variable", "1:8 zig ast-check: unused local variable" });
    try testing.expect(h.server.live_prepared.hits > hits);
    try shutdown(&h);
}

test "zig version mismatch: files under a newly created build.zig drop their single-file compile results" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const main_text = "const geo = @import(\"geo\");\npub fn main() void {\n    _ = geo.name;\n}\n";
    var project = try fixture.Project.create(&.{
        .{ .path = "main.zig", .text = main_text },
        .{ .path = "geo.zig", .text = "pub const name = \"geo\";\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const a = h.arena.allocator();
    try initializeWith(&h, project.root, false, try mismatchedZig(&h, &project));
    _ = try open(&h, try project.path(a, "main.zig"), main_text);
    try waitIdle(&h);
    try expectDiagnostics(try h.diagnostics(), "main.zig", &.{"zig: no module named 'geo'"});

    // 新建 build.zig：版本不同，不启动项目，main.zig 也不再按单文件编译，此前的结果随之失效
    const build_path = try project.path(a, "build.zig");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = build_path, .data = simple_build });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = try za.base.uri.fromPath(a, build_path), .type = 1 }} });
    try waitIdle(&h);
    try testing.expectEqual(0, h.server.workspaces.items.len);
    try expectDiagnostics(try h.diagnostics(), "main.zig", &.{});
    try shutdown(&h);
}

test "unreadable build graph: loading ends, the build system is stopped and the user is told" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    // 假的 maker：发出指向不存在的文件的构建图，然后一直等待输入。`zig env` 报告包装脚本自身为 zig，
    // 其余命令照常执行
    const a = testing.allocator;
    {
        const missing = "missing-configuration";
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try w.writeStruct(std.zig.Server.Message.Header{ .tag = .bsp_configuration, .bytes_len = missing.len }, .little);
        try w.writeAll(missing);
        try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "configuration.bin", .data = w.buffered() });
    }
    const zig = project.env.zig_exe;
    const script = try std.fmt.allocPrint(a,
        \\#!/bin/sh
        \\case "$1" in
        \\env) "{s}" env | sed 's|\.zig_exe = "[^"]*"|.zig_exe = "{s}/zigw"|' ;;
        \\build) cat "{s}/configuration.bin"; exec cat >/dev/null ;;
        \\*) exec "{s}" "$@" ;;
        \\esac
        \\
    , .{ zig, project.root, project.root, zig });
    defer a.free(script);
    try project.tmp.dir.writeFile(testing.io, .{ .sub_path = "zigw", .data = script, .flags = .{ .permissions = .executable_file } });

    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const options = try std.fmt.allocPrint(h.arena.allocator(), "{{\"zig\": {{\"path\": \"{s}/zigw\"}}}}", .{project.root});
    try initializeWith(&h, project.root, true, try jsonValue(&h, options));
    try waitIdle(&h);

    try expectProgressEnded(&h);
    try testing.expect(anyContains(try shownMessages(&h), "cannot read the build graph"));
    // maker 被结束：后台任务读到输入结束后收尾
    const ws = h.server.workspaces.items[0];
    for (0..100) |_| {
        ws.mutex.lockUncancelable(testing.io);
        const running = ws.client != null;
        ws.mutex.unlock(testing.io);
        if (!running) break;
        try testing.io.sleep(.fromMilliseconds(50), .awake);
    } else return error.TestUnexpectedResult;
    try shutdown(&h);
}

/// 每个开始的进度都已结束
fn expectProgressEnded(h: *Harness) !void {
    var begins: usize = 0;
    var ends: usize = 0;
    for (try h.notifications("$/progress")) |m| {
        const kind = m.object.get("params").?.object.get("value").?.object.get("kind").?.string;
        if (std.mem.eql(u8, kind, "begin")) begins += 1;
        if (std.mem.eql(u8, kind, "end")) ends += 1;
    }
    try testing.expectEqual(begins, ends);
}

/// 收到的 window/showMessage 文案
fn shownMessages(h: *Harness) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try h.notifications("window/showMessage")) |m| try out.append(h.arena.allocator(), m.object.get("params").?.object.get("message").?.string);
    return out.items;
}

fn anyContains(list: []const []const u8, needle: []const u8) bool {
    for (list) |s| if (std.mem.indexOf(u8, s, needle) != null) return true;
    return false;
}

test "settings: several diagnostics steps are merged, unknown steps and settings are reported" {
    var project = try fixture.Project.create(settings_project);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initializeWith(&h, project.root, false, try jsonValue(&h,
        \\{"build": {"args": ["-Dbad=true"]}, "diagnostics": {"steps": ["check", "unit", "nope"]}, "colors": {}, "inlay_hints": {"types": "yes"}}
    ));
    try waitIdle(&h);
    const diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{"3:23 zig: expected type 'u32'"});
    try expectDiagnostics(diags, "t.zig", &.{"1:18 zig: expected type 'u8'"});
    const messages = try shownMessages(&h);
    try testing.expect(anyContains(messages, "some diagnostics.steps are not steps of"));
    try testing.expect(anyContains(messages, "unknown setting `colors`"));
    try testing.expect(anyContains(messages, "invalid value for `inlay_hints.types`, using the default"));
    try shutdown(&h);
}

test "settings: diagnostics.compiler off publishes no compiler diagnostics" {
    var project = try fixture.Project.create(settings_project);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initializeWith(&h, project.root, false, try jsonValue(&h,
        \\{"build": {"args": ["-Dbad=true"]}, "diagnostics": {"compiler": false}}
    ));
    _ = try open(&h, try project.path(h.arena.allocator(), "main.zig"), settings_project[1].text);
    try waitIdle(&h);
    const diags = try h.diagnostics();
    for (diags.get("main.zig") orelse &.{}) |d| try testing.expect(std.mem.indexOf(u8, d, "zig:") == null);
    try testing.expect(diags.get("t.zig") == null);
    try shutdown(&h);
}

test "settings: build.enable can be switched off and on at runtime" {
    var project = try fixture.Project.create(settings_project);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initializeWith(&h, project.root, false, try jsonValue(&h,
        \\{"build": {"enable": false, "args": ["-Dbad=true"]}}
    ));
    try waitIdle(&h);
    // 不启动构建系统
    try testing.expectEqual(0, h.server.workspaces.items.len);
    try testing.expect((try h.diagnostics()).get("main.zig") == null);
    const std_path = try std.fs.path.join(h.arena.allocator(), &.{ project.env.std_dir, "std.zig" });
    const std_text = try std.Io.Dir.cwd().readFileAlloc(testing.io, std_path, h.arena.allocator(), .limited(2 * 1024 * 1024));
    const std_uri = try open(&h, std_path, std_text);
    try waitIdle(&h);
    try expectNoErrors(&h, std_uri);

    // 打开：启动项目并发布编译器诊断
    try h.notify("workspace/didChangeConfiguration", .{ .settings = try jsonValue(&h,
        \\{"build": {"enable": true, "args": ["-Dbad=true"]}}
    ) });
    try waitIdle(&h);
    try testing.expectEqual(1, h.server.workspaces.items.len);
    try expectDiagnostics(try h.diagnostics(), "main.zig", &.{"3:23 zig: expected type 'u32'"});
    try expectNoErrors(&h, std_uri);

    // 再关闭：项目停止，其诊断被清除
    try h.notify("workspace/didChangeConfiguration", .{ .settings = try jsonValue(&h,
        \\{"build": {"enable": false}}
    ) });
    try waitIdle(&h);
    try testing.expectEqual(0, h.server.workspaces.items.len);
    try expectDiagnostics(try h.diagnostics(), "main.zig", &.{});
    try expectNoErrors(&h, std_uri);
    try shutdown(&h);
}

test "project zig-analyzer.json: build settings apply, a change on disk restarts the project" {
    var project = try fixture.Project.create(settings_project ++ [_]fixture.File{
        .{ .path = "zig-analyzer.json", .text =
        \\{"build": {"args": ["-Dbad=true"]}, "log": {"level": "err"}}
        },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    try initialize(&h, project.root, false);
    try waitIdle(&h);
    var diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{"3:23 zig: expected type 'u32'"});
    try testing.expect(anyContains(try shownMessages(&h), "`log.level` cannot be set in zig-analyzer.json"));

    // 编辑器之外改为用 unit step 诊断、去掉 -D 参数：项目重启
    const a = h.arena.allocator();
    const path = try project.path(a, "zig-analyzer.json");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "{\"diagnostics\": {\"steps\": [\"unit\"]}}" });
    try h.notify("workspace/didChangeWatchedFiles", .{ .changes = &.{.{ .uri = try za.base.uri.fromPath(a, path), .type = 2 }} });
    try waitIdle(&h);
    diags = try h.diagnostics();
    try expectDiagnostics(diags, "main.zig", &.{});
    try expectDiagnostics(diags, "t.zig", &.{"1:18 zig: expected type 'u8'"});
    try shutdown(&h);
}
