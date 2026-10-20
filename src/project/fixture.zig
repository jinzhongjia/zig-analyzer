//! 集成测试用的示例项目：在临时目录中写出文件，真实运行 `zig build --listen=-`。
//! PATH 中没有 zig 或版本与编译时不同时跳过（CI 与开发环境都满足）。

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ZigEnv = @import("ZigEnv.zig");

pub const File = struct { path: []const u8, text: []const u8 };

pub const Project = struct {
    tmp: testing.TmpDir,
    /// 绝对路径
    root: [:0]u8,
    env: ZigEnv,

    pub fn create(files: []const File) !Project {
        var env = ZigEnv.query(testing.allocator, testing.io, null) catch |err| switch (err) {
            error.ZigNotFound => return error.SkipZigTest,
            else => |e| return e,
        };
        errdefer env.deinit(testing.allocator);
        if (!env.matchesBuiltin()) return error.SkipZigTest;

        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        for (files) |f| {
            if (std.fs.path.dirname(f.path)) |d| try tmp.dir.createDirPath(testing.io, d);
            try tmp.dir.writeFile(testing.io, .{ .sub_path = f.path, .data = f.text });
        }
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        return .{ .tmp = tmp, .root = root, .env = env };
    }

    pub fn deinit(p: *Project) void {
        testing.allocator.free(p.root);
        p.env.deinit(testing.allocator);
        p.tmp.cleanup();
    }

    pub fn path(p: *const Project, a: Allocator, sub: []const u8) ![]u8 {
        return std.fs.path.join(a, &.{ p.root, sub });
    }
};

/// 带一个 AstGen 错误、一个 Sema 错误、两个模块、一个 check step 的示例项目
pub const basic = [_]File{
    .{ .path = "build.zig", .text =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\    const lib = b.createModule(.{ .root_source_file = b.path("src/lib.zig"), .target = target, .optimize = optimize });
    \\    const exe = b.addExecutable(.{ .name = "demo", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\        .imports = &.{.{ .name = "lib", .module = lib }},
    \\    }) });
    \\    b.installArtifact(exe);
    \\    const check = b.step("check", "Check that everything compiles");
    \\    check.dependOn(&exe.step);
    \\}
    \\
    },
    .{ .path = "src/main.zig", .text =
    \\const lib = @import("lib");
    \\pub fn main() void {
    \\    const x: u32 = "不是数字";
    \\    _ = x;
    \\    lib.hello();
    \\}
    \\
    },
    .{ .path = "src/lib.zig", .text =
    \\pub fn hello() void {
    \\    var unused = 1;
    \\}
    \\fn neverCalled() void {
    \\    _ = @import("orphan.zig");
    \\}
    \\
    },
    .{ .path = "src/orphan.zig", .text =
    \\fn f() void {
    \\    var a = 1;
    \\}
    \\
    },
    .{ .path = "src/unrelated.zig", .text =
    \\fn g() void {
    \\    var b = 2;
    \\}
    \\
    },
};

/// 构建中运行 60 秒外部命令（POSIX 的 `sleep`，由 maker 启动）的示例项目：诊断 step 为 check。
/// sleep 在 exe 编译完成后才开始，是 check 之前最后开始的 step：客户端晚于它激活进度 token 时，补发的 begin
/// 带有的也是 "run sleep"（激活前只保留最近一次报告）
pub const slow = [_]File{
    .{ .path = "build.zig", .text =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const exe = b.addExecutable(.{ .name = "t", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("main.zig"),
    \\        .target = b.graph.host,
    \\    }) });
    \\    const sleep = b.addSystemCommand(&.{ "sleep", "60" });
    \\    sleep.step.dependOn(&exe.step);
    \\    const check = b.step("check", "Check");
    \\    check.dependOn(&sleep.step);
    \\}
    \\
    },
    .{ .path = "main.zig", .text = "pub fn main() void {}\n" },
};

/// 进程组 `pgid` 中的进程（被结束后由 init 回收）在几秒内全部消失
pub fn expectGroupGone(pgid: std.posix.pid_t) !void {
    for (0..100) |_| {
        std.posix.kill(-pgid, @fromBackingInt(@intCast(0))) catch |err| switch (err) {
            error.ProcessNotFound => return,
            // macOS：组里只剩尚未回收的僵尸进程时返回 EPERM，继续等待回收
            error.PermissionDenied => {},
            else => return err,
        };
        try testing.io.sleep(.fromMilliseconds(50), .awake);
    }
    return error.ProcessGroupStillAlive;
}
