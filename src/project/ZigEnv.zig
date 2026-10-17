//! 定位 zig 可执行文件并读取 `zig env`：标准库路径、全局缓存目录与版本。
//!
//! 版本检查决定两件事：
//! - 进程内 AstGen 只有在用户 zig 与 zig-analyzer 编译时的标准库版本完全相同时才与编译器一致；
//! - 构建系统协议的 `Configuration` 二进制格式由标准库定义，版本不同时不能加载。

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const ZigEnv = @This();

arena: std.heap.ArenaAllocator.State,
zig_exe: []const u8,
lib_dir: []const u8,
std_dir: []const u8,
global_cache_dir: []const u8,
version: []const u8,

pub fn deinit(env: *ZigEnv, gpa: Allocator) void {
    var arena = env.arena.promote(gpa);
    arena.deinit();
    env.* = undefined;
}

/// 用户 zig 与 zig-analyzer 编译时所用 zig 的版本完全相同（含预发布与构建号）
pub fn matchesBuiltin(env: *const ZigEnv) bool {
    return std.mem.eql(u8, env.version, builtin.zig_version_string);
}

pub const QueryError = error{ ZigNotFound, ZigEnvFailed } || Allocator.Error || Io.Cancelable;

/// 运行 `<zig_exe> env` 并解析结果。`zig_exe` 为 null 时从 PATH 查找 `zig`。
pub fn query(gpa: Allocator, io: Io, zig_exe: ?[]const u8) QueryError!ZigEnv {
    const exe = zig_exe orelse "zig";
    const result = std.process.run(gpa, io, .{
        .argv = &.{ exe, "env" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        error.FileNotFound, error.AccessDenied, error.InvalidExe => return error.ZigNotFound,
        else => return error.ZigEnvFailed,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ZigEnvFailed,
        else => return error.ZigEnvFailed,
    }
    const cwd = Io.Dir.cwd().realPathFileAlloc(io, ".", gpa) catch return error.ZigEnvFailed;
    defer gpa.free(cwd);
    return fromOutput(gpa, result.stdout, cwd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return error.ZigEnvFailed,
    };
}

/// 解析 `zig env` 的输出。`zig env` 原样输出 ZIG_GLOBAL_CACHE_DIR 等环境变量，可能是相对路径：
/// 按当前目录 `cwd` 转为绝对路径
fn fromOutput(gpa: Allocator, text: []const u8, cwd: []const u8) error{ OutOfMemory, ParseZon }!ZigEnv {
    var env = try parse(gpa, text);
    errdefer env.deinit(gpa);
    // arena 的状态须在 `return env` 复制返回值之前写回：defer 在复制之后才执行
    {
        var arena = env.arena.promote(gpa);
        defer env.arena = arena.state;
        inline for (.{ "lib_dir", "std_dir", "global_cache_dir" }) |field| {
            @field(env, field) = try absolute(arena.allocator(), cwd, @field(env, field));
        }
    }
    return env;
}

fn absolute(a: Allocator, cwd: []const u8, path: []const u8) Allocator.Error![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    return std.fs.path.resolveAlloc(a, &.{ cwd, path });
}

test absolute {
    const a = std.testing.allocator;
    const cwd = if (builtin.os.tag == .windows) "C:\\work" else "/work";
    const rel = try absolute(a, cwd, ".zig-cache");
    defer a.free(rel);
    try std.testing.expect(std.fs.path.isAbsolute(rel));
    try std.testing.expect(std.mem.endsWith(u8, rel, ".zig-cache"));
    try std.testing.expectEqualStrings(cwd, try absolute(a, "/elsewhere", cwd));
}

/// 解析 `zig env` 的 ZON 输出
pub fn parse(gpa: Allocator, text: []const u8) error{ OutOfMemory, ParseZon }!ZigEnv {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const source = try a.dupeSentinel(u8, text, 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const Raw = struct {
        zig_exe: []const u8,
        lib_dir: []const u8,
        std_dir: []const u8,
        global_cache_dir: []const u8,
        version: []const u8,
    };
    const raw = try std.zon.parse.fromSlice(Raw, .{
        .gpa = gpa,
        .arena = a,
        .source = source,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    });
    return .{
        .arena = arena.state,
        .zig_exe = raw.zig_exe,
        .lib_dir = raw.lib_dir,
        .std_dir = raw.std_dir,
        .global_cache_dir = raw.global_cache_dir,
        .version = raw.version,
    };
}

test parse {
    const text =
        \\.{
        \\    .zig_exe = "/opt/zig/zig",
        \\    .lib_dir = "/opt/zig/lib",
        \\    .std_dir = "/opt/zig/lib/std",
        \\    .global_cache_dir = "C:\\Users\\u\\AppData\\Local\\zig",
        \\    .version = "0.17.0",
        \\    .target = "x86_64-linux",
        \\    .env = .{ .ZIG_LIB_DIR = null },
        \\}
    ;
    var env = try parse(std.testing.allocator, text);
    defer env.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/opt/zig/lib/std", env.std_dir);
    try std.testing.expectEqualStrings("C:\\Users\\u\\AppData\\Local\\zig", env.global_cache_dir);
    try std.testing.expectEqualStrings("0.17.0", env.version);
}

test fromOutput {
    // 防止返回的环境带着转换路径之前的 arena 状态：分配器不能原地扩大时，绝对路径所在的内存块在释放时泄漏
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .resize_fail_index = 0 });
    const gpa = failing.allocator();
    // 足够长的当前目录使绝对路径放不进 arena 已有的内存块
    const root = if (builtin.os.tag == .windows) "C:\\" else "/";
    const cwd = try std.testing.allocator.alloc(u8, root.len + 8192);
    defer std.testing.allocator.free(cwd);
    @memcpy(cwd[0..root.len], root);
    @memset(cwd[root.len..], 'w');
    var env = try fromOutput(gpa,
        \\.{ .zig_exe = "zig", .lib_dir = "lib", .std_dir = "lib/std", .global_cache_dir = ".cache", .version = "0.17.0" }
    , cwd);
    defer env.deinit(gpa);
    try std.testing.expect(std.fs.path.isAbsolute(env.std_dir));
    try std.testing.expect(std.mem.startsWith(u8, env.global_cache_dir, cwd));
}

test "query local zig (skipped when zig is not in PATH)" {
    var env = query(std.testing.allocator, std.testing.io, null) catch |err| switch (err) {
        error.ZigNotFound => return error.SkipZigTest,
        else => |e| return e,
    };
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.std_dir.len > 0);
    // 本仓库的 CI 与开发环境都使用与编译时相同的 zig
    try std.testing.expect(env.matchesBuiltin());
}
