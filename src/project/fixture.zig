//! Sample projects for integration tests: files are written to a temporary directory and
//! `zig build --listen=-` is actually run. Runs only in `zig build test-all` and `test-stress`;
//! skipped when there is no zig in PATH or its version differs from the one used at compile time
//! (both CI and the development environment satisfy this).

const std = @import("std");
const builtin = @import("builtin");
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

    /// The absolute path of `sub` (separated by `/`), with the native separators
    pub fn path(p: *const Project, a: Allocator, sub: []const u8) ![]u8 {
        const joined = try std.fs.path.join(a, &.{ p.root, sub });
        std.mem.replaceScalar(u8, joined, '/', std.fs.path.sep);
        return joined;
    }
};

/// `text` with each `/` replaced by the native path separator: for expected messages that contain
/// relative paths
pub inline fn separators(comptime text: []const u8) []const u8 {
    comptime {
        var out = text[0..text.len].*;
        std.mem.replaceScalar(u8, &out, '/', std.fs.path.sep);
        const final = out;
        return &final;
    }
}

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
    \\    const x: u32 = "not a number";
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

/// All processes in process group `pgid` have ended within a few seconds. On Linux, ended
/// processes not reaped yet (zombies) count as ended: they stay in the group until their parent
/// reaps them, and the parent of orphans, init, may not do so for a long time (in a container
/// whose PID 1 does not reap orphans, never).
pub fn expectGroupGone(pgid: std.posix.pid_t) !void {
    for (0..100) |_| {
        std.posix.kill(-pgid, @fromBackingInt(@intCast(0))) catch |err| switch (err) {
            error.ProcessNotFound => return,
            // macOS: returns EPERM when only zombie processes not yet reaped remain in the group;
            // keep waiting for them to be reaped
            error.PermissionDenied => {},
            else => return err,
        };
        if (builtin.os.tag == .linux and !try groupHasLiveProcess(pgid)) return;
        try testing.io.sleep(.fromMilliseconds(50), .awake);
    }
    return error.ProcessGroupStillAlive;
}

/// Linux: process group `pgid` has a process that is not a zombie (read from `/proc/<pid>/stat`)
fn groupHasLiveProcess(pgid: std.posix.pid_t) !bool {
    var proc = try std.Io.Dir.cwd().openDir(testing.io, "/proc", .{ .iterate = true });
    defer proc.close(testing.io);
    var it = proc.iterate();
    var path_buf: [64]u8 = undefined;
    var stat_buf: [4096]u8 = undefined;
    while (try it.next(testing.io)) |entry| {
        _ = std.fmt.parseInt(std.posix.pid_t, entry.name, 10) catch continue;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/stat", .{entry.name});
        // The process may have been reaped since the directory was listed
        const stat = proc.readFile(testing.io, path, &stat_buf) catch continue;
        // `pid (comm) state ppid pgrp ...`, where comm may contain spaces and parentheses
        const comm_end = std.mem.lastIndexOfScalar(u8, stat, ')') orelse continue;
        var fields = std.mem.tokenizeScalar(u8, stat[comm_end + 1 ..], ' ');
        const state = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const pgrp = std.fmt.parseInt(std.posix.pid_t, fields.next() orelse continue, 10) catch continue;
        if (pgrp == pgid and !std.mem.eql(u8, state, "Z") and !std.mem.eql(u8, state, "X")) return true;
    }
    return false;
}

test "expectGroupGone: a group whose only members are zombies is gone" {
    // Guards against reporting a leak when the ended processes are zombies that their parent
    // (in a container, a PID 1 that does not reap orphans) has not reaped yet
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // The child leads its own process group, and exits once its stdin is closed; it then stays a
    // zombie until this process reaps it
    var child = try std.process.spawn(testing.io, .{ .argv = &.{ "/bin/sh", "-c", "read line" }, .pgid = 0, .stdin = .pipe, .stdout = .ignore, .stderr = .ignore });
    defer _ = child.wait(testing.io) catch {};
    const pgid = child.id.?;
    try testing.expect(try groupHasLiveProcess(pgid));
    child.stdin.?.close(testing.io);
    child.stdin = null;
    try expectGroupGone(pgid);
}
