//! 端到端：Server + 真实的构建系统协议，校验发布的诊断与编译器一致（设计 §11），以及构建进度通知。

const std = @import("std");
const testing = std.testing;
const za = @import("../zig_analyzer.zig");
const fixture = za.project.fixture;
const Harness = @import("test_harness.zig").Harness;

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
    try testing.expectEqual(titles.len, ends);
    try testing.expect(percentages >= 2);
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
