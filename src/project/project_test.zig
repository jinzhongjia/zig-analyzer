const std = @import("std");
const testing = std.testing;
const bsp = @import("bsp.zig");
const configuration = @import("configuration.zig");
const fixture = @import("fixture.zig");

test "build system protocol: read build graph and get compile errors" {
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    const gpa = testing.allocator;

    const client = try bsp.Client.start(gpa, testing.io, &project.env, project.root, &.{});
    defer client.deinit();

    var model: ?@import("../base/ProjectModel.zig") = null;
    defer if (model) |*m| m.deinit(gpa);
    var errors: std.ArrayList([]u8) = .empty;
    defer {
        for (errors.items) |e| gpa.free(e);
        errors.deinit(gpa);
    }

    while (true) {
        var event = try client.next();
        defer event.deinit(gpa);
        switch (event) {
            .handshake => |h| try testing.expectEqual(bsp.protocol_version, h.version),
            .configuration => |path| {
                model = try configuration.load(gpa, testing.io, project.root, path, &project.env);
                // 回归：模型中最后分配的字段曾在复制 arena 状态之后分配，新开的 arena 块随模型释放时被漏掉
                // （是否新开块取决于路径长度，CI 上偶发）。超长的标准库路径保证新开块
                var long_env = project.env;
                const long_dir = try gpa.alloc(u8, 64 * 1024);
                defer gpa.free(long_dir);
                @memset(long_dir, 'a');
                long_env.std_dir = long_dir;
                var long_model = try configuration.load(gpa, testing.io, project.root, path, &long_env);
                long_model.deinit(gpa);
                try client.buildSteps(model.?.diagnostics_steps);
            },
            .step_completed => |sc| if (sc.errors.errorMessageCount() != 0) {
                const eb = sc.errors;
                for (eb.getMessages()) |mi| {
                    const msg = eb.getErrorMessage(mi);
                    const loc = eb.getSourceLocation(msg.src_loc);
                    try errors.append(gpa, try std.fmt.allocPrint(gpa, "{s}:{d}: {s}", .{
                        eb.nullTerminatedString(loc.src_path), loc.line + 1, eb.nullTerminatedString(msg.msg),
                    }));
                }
            },
            .build_completed => break,
            else => {},
        }
    }

    // 构建图：check step → compile step → 根模块 main.zig，import "lib" → lib.zig
    const m = &model.?;
    try testing.expectEqual(1, m.diagnostics_steps.len);
    try testing.expectEqualStrings("check", m.steps[m.diagnostics_steps[0]].name);
    const compiles = try m.compileStepsOf(gpa, m.diagnostics_steps);
    defer gpa.free(compiles);
    try testing.expectEqual(1, compiles.len);
    const root = m.modules[m.steps[compiles[0]].kind.compile.root_module];
    try testing.expect(std.mem.endsWith(u8, root.root_file.?, "main.zig"));
    try testing.expectEqualStrings("lib", root.imports[0].name);
    try testing.expect(std.mem.endsWith(u8, m.modules[root.imports[0].module].root_file.?, "lib.zig"));
    try testing.expect(std.fs.path.isAbsolute(root.root_file.?));

    // 编译错误：AstGen 错误（含从未调用的函数中导入的文件）与 Sema 错误；未导入的文件没有错误
    std.mem.sort([]u8, errors.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    try testing.expectEqual(3, errors.items.len);
    try testing.expect(std.mem.indexOf(u8, errors.items[0], "lib.zig:2: unused local variable") != null);
    try testing.expect(std.mem.indexOf(u8, errors.items[1], "main.zig:3: expected type 'u32'") != null);
    try testing.expect(std.mem.indexOf(u8, errors.items[2], "orphan.zig:2: unused local variable") != null);
}

fn stopAfter(io: std.Io, client: *bsp.Client, fired: *bool) std.Io.Cancelable!void {
    try io.sleep(.fromSeconds(20), .awake);
    fired.* = true;
    client.terminate();
}

test "build system protocol: zig build and the processes it started end when the server goes away" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var project = try fixture.Project.create(&fixture.slow);
    defer project.deinit();
    const gpa = testing.allocator;
    const io = testing.io;

    const client = try bsp.Client.start(gpa, io, &project.env, project.root, &.{});
    var deinited = false;
    defer if (!deinited) client.deinit();
    const pgid = client.group.pgid;
    var model: ?@import("../base/ProjectModel.zig") = null;
    defer if (model) |*m| m.deinit(gpa);
    // 等到运行 sleep 的 step 开始
    while (true) {
        var event = try client.next();
        defer event.deinit(gpa);
        switch (event) {
            .configuration => |path| {
                model = try configuration.load(gpa, io, project.root, path, &project.env);
                try client.buildSteps(model.?.diagnostics_steps);
            },
            .step_started => |step| if (std.mem.indexOf(u8, model.?.steps[step].name, "sleep") != null) break,
            else => {},
        }
    }

    // 服务器进程退出时（不论如何退出）操作系统关闭看门狗输入的写端
    const watchdog = &client.group.watchdog.?;
    watchdog.stdin.?.close(io);
    watchdog.stdin = null;
    // 看门狗没有结束进程组时由这里结束：测试失败而不是等构建跑完
    var fired = false;
    var fallback = try io.concurrent(stopAfter, .{ io, client, &fired });
    while (true) {
        var event = client.next() catch |err| {
            try testing.expectEqual(error.EndOfStream, err);
            break;
        };
        event.deinit(gpa);
    }
    fallback.cancel(io) catch {};
    try testing.expect(!fired);
    client.deinit();
    deinited = true;
    // maker 启动的 sleep 也已结束
    try fixture.expectGroupGone(pgid);
}
