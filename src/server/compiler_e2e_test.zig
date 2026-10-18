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
    try testing.expect(anyContains(try shownMessages(&h), "projects with build.zig get no compiler diagnostics"));
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

    // 打开：启动项目并发布编译器诊断
    try h.notify("workspace/didChangeConfiguration", .{ .settings = try jsonValue(&h,
        \\{"build": {"enable": true, "args": ["-Dbad=true"]}}
    ) });
    try waitIdle(&h);
    try testing.expectEqual(1, h.server.workspaces.items.len);
    try expectDiagnostics(try h.diagnostics(), "main.zig", &.{"3:23 zig: expected type 'u32'"});

    // 再关闭：项目停止，其诊断被清除
    try h.notify("workspace/didChangeConfiguration", .{ .settings = try jsonValue(&h,
        \\{"build": {"enable": false}}
    ) });
    try waitIdle(&h);
    try testing.expectEqual(0, h.server.workspaces.items.len);
    try expectDiagnostics(try h.diagnostics(), "main.zig", &.{});
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
