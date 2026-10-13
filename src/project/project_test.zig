const std = @import("std");
const testing = std.testing;
const bsp = @import("bsp.zig");
const configuration = @import("configuration.zig");
const fixture = @import("fixture.zig");

test "build system protocol: read build graph and get compile errors" {
    var project = try fixture.Project.create(&fixture.basic);
    defer project.deinit();
    const gpa = testing.allocator;

    const client = try bsp.Client.start(gpa, testing.io, project.env.zig_exe, project.root, &.{});
    defer client.stop();

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
                try client.buildSteps(&.{model.?.diagnosticsStep()});
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
    try testing.expectEqualStrings("check", m.steps[m.diagnosticsStep()].name);
    const compiles = try m.compileStepsOf(gpa, m.diagnosticsStep());
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
