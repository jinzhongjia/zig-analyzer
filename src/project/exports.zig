//! 项目导出的模块（`b.addModule`）。
//!
//! 构建图只包含 step 可达的模块：只导出模块、由使用方编译的库（测试由外部工具运行，或者根本没有
//! compile step）的构建图中没有模块，项目中的文件得不到模块归属，依赖的 import 都无法解析。
//! 这时在项目的本地缓存中生成一个探针包，以项目为 path 依赖，为项目导出的每个模块添加 object step，
//! 从探针包的构建图中读出这些模块及其 import 表。

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ProjectModel = @import("../base/ProjectModel.zig");
const ZigEnv = @import("ZigEnv.zig");
const bsp = @import("bsp.zig");
const configuration = @import("configuration.zig");

const log = std.log.scoped(.exports);

/// 探针包相对于构建根目录的位置；build.zig.zon 中以 `../../..` 引用项目
const probe_sub_path = ".zig-cache/zig-analyzer/exports";

const probe_name = "zig_analyzer_exports";

/// 导出的模块常常不指定目标（由使用方决定），而 compile step 的根模块必须有目标：这时按本机目标。
/// 模块名可能含有 `/`，不能作为产物名
const build_zig =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const step = b.step("exports", "Modules exported by the project");
    \\    const project = b.dependency("project", .{});
    \\    for (project.builder.modules.values()) |module| {
    \\        if (module.resolved_target == null) module.resolved_target = b.graph.host;
    \\        step.dependOn(&b.addObject(.{ .name = "export", .root_module = module }).step);
    \\    }
    \\}
    \\
;

/// 校验和须与包名一致（见 `zig init` 生成的 fingerprint）
const fingerprint: u64 = @as(u64, std.hash.Crc32.hash(probe_name)) << 32 | 1;

const build_zig_zon = std.fmt.comptimePrint(
    \\.{{
    \\    .name = .{s},
    \\    .version = "0.0.0",
    \\    .fingerprint = 0x{x},
    \\    .dependencies = .{{ .project = .{{ .path = "../../.." }} }},
    \\    .paths = .{{""}},
    \\}}
    \\
, .{ probe_name, fingerprint });

/// 读取项目 `root` 导出的模块，结果的构建根目录是探针包。探针失败（构建脚本出错、依赖缺失等）时
/// 返回 null。`build_args` 中只有指定包位置的参数会转发：`-D` 选项属于项目而不是探针包
pub fn load(gpa: Allocator, io: Io, env: *const ZigEnv, root: []const u8, build_args: []const []const u8) Allocator.Error!?ProjectModel {
    const probe_root = try std.fs.path.join(gpa, &.{ root, probe_sub_path });
    defer gpa.free(probe_root);
    writeProbe(io, root) catch |err| {
        log.info("{s}: cannot create the package probing exported modules: {t}", .{ root, err });
        return null;
    };

    var args_arena: std.heap.ArenaAllocator = .init(gpa);
    defer args_arena.deinit();
    const args = try probeArgs(args_arena.allocator(), root, build_args);

    const client = bsp.Client.start(gpa, io, env.zig_exe, probe_root, args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.info("{s}: cannot start zig build to probe exported modules: {t}", .{ root, err });
            return null;
        },
    };
    defer client.deinit();
    while (true) {
        var event = client.next() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.info("{s}: probing exported modules failed: {t}", .{ root, err });
                return null;
            },
        };
        defer event.deinit(gpa);
        switch (event) {
            .configuration => |path| return configuration.load(gpa, io, probe_root, path, env) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.info("{s}: cannot read the build graph of exported modules: {t}", .{ root, err });
                    return null;
                },
            },
            .configuration_failed => {
                log.info("{s}: build script failed while probing exported modules", .{root});
                return null;
            },
            else => {},
        }
    }
}

fn writeProbe(io: Io, root: []const u8) !void {
    var root_dir = try Io.Dir.cwd().openDir(io, root, .{});
    defer root_dir.close(io);
    var dir = try root_dir.createDirPathOpen(io, probe_sub_path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "build.zig", .data = build_zig });
    try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = build_zig_zon });
}

/// 指定包位置的参数（相对路径按项目根目录解析）；没有指定时使用项目的 `zig-pkg`，
/// 依赖的文件与项目自身的构建使用同一份
fn probeArgs(a: Allocator, root: []const u8, build_args: []const []const u8) Allocator.Error![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    var has_pkg_dir = false;
    var i: usize = 0;
    while (i < build_args.len) : (i += 1) {
        const arg = build_args[i];
        if (std.mem.cutPrefix(u8, arg, "--fork=")) |path| {
            try args.append(a, try std.fmt.allocPrint(a, "--fork={s}", .{try std.fs.path.resolveAlloc(a, &.{ root, path })}));
            continue;
        }
        const takes_path = for ([_][]const u8{ "--pkg-dir", "--system", "--fork" }) |flag| {
            if (std.mem.eql(u8, arg, flag)) break true;
        } else false;
        if (!takes_path or i + 1 >= build_args.len) continue;
        if (!std.mem.eql(u8, arg, "--fork")) has_pkg_dir = true;
        i += 1;
        try args.appendSlice(a, &.{ arg, try std.fs.path.resolveAlloc(a, &.{ root, build_args[i] }) });
    }
    if (!has_pkg_dir) try args.appendSlice(a, &.{ "--pkg-dir", try std.fs.path.join(a, &.{ root, "zig-pkg" }) });
    return args.items;
}

test probeArgs {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = if (@import("builtin").os.tag == .windows) "C:\\p" else "/p";
    const join = struct {
        fn f(x: Allocator, parts: []const []const u8) []const u8 {
            return std.fs.path.join(x, parts) catch unreachable;
        }
    }.f;

    const plain = try probeArgs(a, root, &.{ "-Dtarget=wasm32-freestanding", "--release=fast" });
    try std.testing.expectEqual(2, plain.len);
    try std.testing.expectEqualStrings("--pkg-dir", plain[0]);
    try std.testing.expectEqualStrings(join(a, &.{ root, "zig-pkg" }), plain[1]);

    const system = try probeArgs(a, root, &.{ "--system", "pkgs", "-Dx", "--fork=../f", "--fork", "g" });
    try std.testing.expectEqual(5, system.len);
    try std.testing.expectEqualStrings("--system", system[0]);
    try std.testing.expectEqualStrings(join(a, &.{ root, "pkgs" }), system[1]);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "--fork={s}", .{try std.fs.path.resolveAlloc(a, &.{ root, "..", "f" })}), system[2]);
    try std.testing.expectEqualStrings("--fork", system[3]);
    try std.testing.expectEqualStrings(join(a, &.{ root, "g" }), system[4]);
}
