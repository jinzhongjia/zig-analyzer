//! 定位 zig 可执行文件并读取 `zig env`：标准库路径、全局缓存目录与版本。lib 目录与全局缓存目录可以由配置覆盖
//! （`withOverrides`）。
//!
//! 版本检查决定两件事：
//! - 进程内 AstGen 只有在用户 zig 与 zig-analyzer 编译时的标准库版本完全相同时才与编译器一致；
//! - 构建系统协议的 `Configuration` 二进制格式由标准库定义，版本不同时不能加载。

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

const ZigEnv = @This();

arena: std.heap.ArenaAllocator.State,
zig_exe: []const u8,
lib_dir: []const u8,
std_dir: []const u8,
global_cache_dir: []const u8,
version: []const u8,
/// 运行 zig（`zig build`、`zig build-obj` 等）的子进程的环境变量；null 时继承当前进程的。lib 目录或全局缓存目录
/// 被覆盖时经 `ZIG_LIB_DIR`、`ZIG_GLOBAL_CACHE_DIR` 告诉 zig：`zig build` 没有指定全局缓存目录的参数
environ_map: ?Environ.Map = null,

pub fn deinit(env: *ZigEnv, gpa: Allocator) void {
    if (env.environ_map) |*m| m.deinit();
    var arena = env.arena.promote(gpa);
    arena.deinit();
    env.* = undefined;
}

/// 运行 zig 时传给 `std.process.spawn` / `run` 的 `environ_map`
pub fn childEnviron(env: *const ZigEnv) ?*const Environ.Map {
    return if (env.environ_map) |*m| m else null;
}

/// 用户 zig 与 zig-analyzer 编译时所用 zig 的版本完全相同（含预发布与构建号）
pub fn matchesBuiltin(env: *const ZigEnv) bool {
    return std.mem.eql(u8, env.version, builtin.zig_version_string);
}

pub const QueryError = error{ ZigNotFound, ZigEnvFailed } || Allocator.Error || Io.Cancelable;

/// 运行 `<zig_exe> env` 并解析结果。`zig_exe` 为 null 时从 PATH 查找 `zig`。
pub fn query(gpa: Allocator, io: Io, zig_exe: ?[]const u8) QueryError!ZigEnv {
    // `zig build test` 只运行不依赖外部工具的测试：找不到 zig，依赖它的测试跳过，服务器不启动项目与编译
    if (builtin.is_test and !@import("build_options").zig_tests) return error.ZigNotFound;
    const exe = zig_exe orelse "zig";
    const result = std.process.run(gpa, io, .{
        .argv = &.{ exe, "env" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        // 包装脚本（asdf、mise）或网络文件系统上的 zig 可能永久挂起
        .timeout = .{ .duration = .{ .raw = Io.Duration.fromSeconds(30), .clock = .awake } },
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

/// 用户配置的路径，优先于 `zig env` 给出的值；相对路径按当前目录解析
pub const Overrides = struct {
    /// lib 目录：其下须有 `std/std.zig`
    lib_dir: ?[]const u8 = null,
    /// 全局缓存目录：须是已存在的目录
    global_cache_dir: ?[]const u8 = null,
};

/// `withOverrides` 没有采用的覆盖：路径不存在或不符合要求
pub const Rejected = struct {
    lib_dir: bool = false,
    global_cache_dir: bool = false,
};

pub const OverrideError = Allocator.Error || Io.Cancelable || Environ.CreateMapError;

/// 以 `overrides` 覆盖 `base`（`zig env` 的结果）中的路径，返回新的环境（不引用 `base` 的内存）。不能采用的覆盖记入
/// `rejected`，保留 `base` 的值。有采用的覆盖时，运行 zig 的子进程的环境变量为当前进程的 `environ` 加上覆盖的路径
pub fn withOverrides(
    base: *const ZigEnv,
    gpa: Allocator,
    io: Io,
    environ: Environ,
    overrides: Overrides,
    rejected: *Rejected,
) OverrideError!ZigEnv {
    rejected.* = .{};
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var env: ZigEnv = .{
        .arena = undefined,
        .zig_exe = try a.dupe(u8, base.zig_exe),
        .lib_dir = try a.dupe(u8, base.lib_dir),
        .std_dir = try a.dupe(u8, base.std_dir),
        .global_cache_dir = try a.dupe(u8, base.global_cache_dir),
        .version = try a.dupe(u8, base.version),
    };
    var lib_dir: ?[]const u8 = null;
    if (overrides.lib_dir) |path| {
        const dir = try resolveOverride(a, io, path);
        const root = if (dir) |d| try std.fs.path.join(a, &.{ d, "std", "std.zig" }) else null;
        if (root != null and try isKind(io, root.?, .file)) {
            env.lib_dir = dir.?;
            env.std_dir = std.fs.path.dirname(root.?).?;
            lib_dir = dir.?;
        } else rejected.lib_dir = true;
    }
    var cache_dir: ?[]const u8 = null;
    if (overrides.global_cache_dir) |path| {
        const dir = try resolveOverride(a, io, path);
        if (dir != null and try isKind(io, dir.?, .directory)) {
            env.global_cache_dir = dir.?;
            cache_dir = dir.?;
        } else rejected.global_cache_dir = true;
    }
    if (lib_dir != null or cache_dir != null) {
        var map = try environ.createMap(gpa);
        errdefer map.deinit();
        if (lib_dir) |d| try map.put("ZIG_LIB_DIR", d);
        if (cache_dir) |d| try map.put("ZIG_GLOBAL_CACHE_DIR", d);
        env.environ_map = map;
    }
    env.arena = arena.state;
    return env;
}

/// 两个环境给出的路径（zig 可执行文件、lib 目录、标准库目录、全局缓存目录）相同
pub fn samePaths(a: *const ZigEnv, b: *const ZigEnv) bool {
    return std.mem.eql(u8, a.zig_exe, b.zig_exe) and std.mem.eql(u8, a.lib_dir, b.lib_dir) and
        std.mem.eql(u8, a.std_dir, b.std_dir) and std.mem.eql(u8, a.global_cache_dir, b.global_cache_dir);
}

/// 配置中的文件路径（如 `zig.builtin_path`）转为规范化的绝对路径（调用方释放），相对路径按当前目录解析。
/// 不存在或（跟随符号链接后）不是文件时为 null
pub fn resolveFile(gpa: Allocator, io: Io, path: []const u8) (Allocator.Error || Io.Cancelable)!?[]u8 {
    const resolved = try resolveOverride(gpa, io, path) orelse return null;
    if (try isKind(io, resolved, .file)) return resolved;
    gpa.free(resolved);
    return null;
}

/// 配置的路径转为规范化的绝对路径（相对路径按当前目录）；取不到当前目录时为 null
fn resolveOverride(a: Allocator, io: Io, path: []const u8) (Allocator.Error || Io.Cancelable)!?[]u8 {
    if (std.fs.path.isAbsolute(path)) return try std.fs.path.resolveAlloc(a, &.{path});
    const cwd = Io.Dir.cwd().realPathFileAlloc(io, ".", a) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return null,
    };
    defer a.free(cwd);
    return try std.fs.path.resolveAlloc(a, &.{ cwd, path });
}

/// `path` 存在且（跟随符号链接后）是 `kind` 类型的文件
fn isKind(io: Io, path: []const u8, kind: Io.File.Kind) Io.Cancelable!bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return false,
    };
    return stat.kind == kind;
}

test withOverrides {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "lib/std");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/std/std.zig", .data = "" });
    try tmp.dir.createDirPath(io, "cache");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const lib = try std.fs.path.join(a, &.{ root, "lib" });
    const cache = try std.fs.path.join(a, &.{ root, "cache" });
    const missing = try std.fs.path.join(a, &.{ root, "missing" });
    const std_file = try std.fs.path.join(a, &.{ lib, "std", "std.zig" });

    var base = try parse(gpa,
        \\.{ .zig_exe = "/opt/zig/zig", .lib_dir = "/opt/zig/lib", .std_dir = "/opt/zig/lib/std", .global_cache_dir = "/home/u/.cache/zig", .version = "0.17.0" }
    );
    defer base.deinit(gpa);
    var rejected: Rejected = .{};

    // 没有覆盖：与 `zig env` 的结果相同，子进程继承当前进程的环境变量
    var same = try base.withOverrides(gpa, io, .empty, .{}, &rejected);
    defer same.deinit(gpa);
    try std.testing.expectEqualStrings(base.std_dir, same.std_dir);
    try std.testing.expectEqualStrings(base.global_cache_dir, same.global_cache_dir);
    try std.testing.expect(same.childEnviron() == null and !rejected.lib_dir and !rejected.global_cache_dir);

    // 有效的覆盖：替换路径并经环境变量告诉 zig。相对路径按当前目录解析，末尾的分隔符被去掉
    const relative = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "lib" ++ std.fs.path.sep_str });
    var both = try base.withOverrides(gpa, io, .empty, .{ .lib_dir = relative, .global_cache_dir = cache }, &rejected);
    defer both.deinit(gpa);
    try std.testing.expect(!rejected.lib_dir and !rejected.global_cache_dir);
    try std.testing.expectEqualStrings(lib, both.lib_dir);
    try std.testing.expectEqualStrings(std.fs.path.dirname(std_file).?, both.std_dir);
    try std.testing.expectEqualStrings(cache, both.global_cache_dir);
    try std.testing.expectEqualStrings(base.zig_exe, both.zig_exe);
    try std.testing.expectEqualStrings(base.version, both.version);
    try std.testing.expectEqualStrings(lib, both.childEnviron().?.get("ZIG_LIB_DIR").?);
    try std.testing.expectEqualStrings(cache, both.childEnviron().?.get("ZIG_GLOBAL_CACHE_DIR").?);

    // 不存在的路径、没有标准库的目录、不是目录的缓存：不采用，保留 `zig env` 的值
    var invalid = try base.withOverrides(gpa, io, .empty, .{ .lib_dir = cache, .global_cache_dir = missing }, &rejected);
    defer invalid.deinit(gpa);
    try std.testing.expect(rejected.lib_dir and rejected.global_cache_dir);
    try std.testing.expectEqualStrings(base.lib_dir, invalid.lib_dir);
    try std.testing.expectEqualStrings(base.std_dir, invalid.std_dir);
    try std.testing.expectEqualStrings(base.global_cache_dir, invalid.global_cache_dir);
    try std.testing.expect(invalid.childEnviron() == null);

    // 只采用有效的一项
    var partial = try base.withOverrides(gpa, io, .empty, .{ .lib_dir = lib, .global_cache_dir = std_file }, &rejected);
    defer partial.deinit(gpa);
    try std.testing.expect(!rejected.lib_dir and rejected.global_cache_dir);
    try std.testing.expectEqualStrings(lib, partial.lib_dir);
    try std.testing.expectEqualStrings(base.global_cache_dir, partial.global_cache_dir);
    try std.testing.expectEqualStrings(lib, partial.childEnviron().?.get("ZIG_LIB_DIR").?);
    try std.testing.expect(partial.childEnviron().?.get("ZIG_GLOBAL_CACHE_DIR") == null);
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
