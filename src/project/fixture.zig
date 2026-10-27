//! Sample projects for integration tests: files are written to a temporary directory and
//! `zig build --listen=-` is actually run. Runs only in `zig build test-all` and `test-stress`;
//! skipped when there is no zig in PATH or its version differs from the one used at compile time
//! (both CI and the development environment satisfy this).

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ZigEnv = @import("ZigEnv.zig");

pub const File = struct { path: []const u8, text: []const u8 };

pub const Project = struct {
    tmp: testing.TmpDir,
    /// Absolute path
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

/// Sample project with one AstGen error, one Sema error, two modules, and a check step
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

/// Sample project whose build runs a 60-second external command (POSIX `sleep`, started by the
/// maker); the diagnostics step is check.
/// sleep starts only after the exe is compiled and is the last step to start before check: when
/// the client activates the progress token later than that, the deferred begin also carries
/// "run sleep" (only the latest report is kept before activation)
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

/// All processes in process group `pgid` (reaped by init after being ended) are gone within a
/// few seconds
pub fn expectGroupGone(pgid: std.posix.pid_t) !void {
    for (0..100) |_| {
        std.posix.kill(-pgid, @fromBackingInt(@intCast(0))) catch |err| switch (err) {
            error.ProcessNotFound => return,
            // macOS: returns EPERM when only zombie processes not yet reaped remain in the group;
            // keep waiting for them to be reaped
            error.PermissionDenied => {},
            else => return err,
        };
        try testing.io.sleep(.fromMilliseconds(50), .awake);
    }
    return error.ProcessGroupStillAlive;
}
