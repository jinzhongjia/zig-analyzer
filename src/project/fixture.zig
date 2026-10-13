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
