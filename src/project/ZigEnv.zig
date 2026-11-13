//! Locates the zig executable and reads `zig env`: the standard library path, the global cache
//! directory, and the version. The lib directory and the global cache directory can be
//! overridden by the configuration (`withOverrides`).
//!
//! The version check decides two things:
//! - In-process AstGen matches the compiler only when the user's zig is exactly the same version
//!   as the standard library zig-analyzer was compiled with;
//! - The binary format of the build system protocol's `Configuration` is defined by the standard
//!   library and can be loaded only from the versions in `supported_versions`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

const ZigEnv = @This();

/// The zig versions zig-analyzer can be built with and whose build graphs it reads. Their build
/// system protocol is the same; their `Configuration` differs only in `LazyPath.Base`, where 0.17.1
/// adds the `deployed_*` bases before `libc_runtimes`. None of these bases resolves to a known
/// path, so reading one as another changes nothing, and a base the reader's standard library does
/// not have fails validation.
pub const supported_versions = [_][]const u8{ "0.17.0", "0.17.1" };

comptime {
    if (!isSupported(builtin.zig_version_string))
        @compileError("zig " ++ builtin.zig_version_string ++ " is not supported: add it to supported_versions once its build graph format and protocol are checked");
}

fn isSupported(version: []const u8) bool {
    for (supported_versions) |v| if (std.mem.eql(u8, v, version)) return true;
    return false;
}

arena: std.heap.ArenaAllocator.State,
zig_exe: []const u8,
lib_dir: []const u8,
std_dir: []const u8,
global_cache_dir: []const u8,
version: []const u8,
/// `ZIG_LOCAL_CACHE_DIR` is set in the environment zig runs in (as `zig env` reports): zig then
/// keeps every local cache there
local_cache_dir_set: bool = false,
/// Environment variables of the child processes running zig (`zig build`, `zig build-obj` and so
/// on); when null, they inherit those of the current process. When the lib directory or the global
/// cache directory is overridden, zig is told through `ZIG_LIB_DIR` and `ZIG_GLOBAL_CACHE_DIR`:
/// `zig build` has no argument for specifying the global cache directory.
environ_map: ?Environ.Map = null,

pub fn deinit(env: *ZigEnv, gpa: Allocator) void {
    if (env.environ_map) |*m| m.deinit();
    var arena = env.arena.promote(gpa);
    arena.deinit();
    env.* = undefined;
}

/// The `environ_map` passed to `std.process.spawn` / `run` when running zig
pub fn childEnviron(env: *const ZigEnv) ?*const Environ.Map {
    return if (env.environ_map) |*m| m else null;
}

/// The user's zig is exactly the same version as the zig that zig-analyzer was compiled with
/// (including pre-release and build number)
pub fn matchesBuiltin(env: *const ZigEnv) bool {
    return std.mem.eql(u8, env.version, builtin.zig_version_string);
}

/// The build graphs of the user's zig can be read
pub fn readsBuildGraph(env: *const ZigEnv) bool {
    return isSupported(env.version);
}

pub const QueryError = error{ ZigNotFound, ZigEnvFailed } || Allocator.Error || Io.Cancelable;

/// Runs `<zig_exe> env` and parses the result. When `zig_exe` is null, looks up `zig` in PATH.
pub fn query(gpa: Allocator, io: Io, zig_exe: ?[]const u8) QueryError!ZigEnv {
    // `zig build test` runs only the tests that do not depend on external tools: zig is not found,
    // tests that depend on it are skipped, and the server starts no projects or compilations
    if (builtin.is_test and !@import("build_options").zig_tests) return error.ZigNotFound;
    const exe = zig_exe orelse "zig";
    const result = std.process.run(gpa, io, .{
        .argv = &.{ exe, "env" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        // zig behind a wrapper script (asdf, mise) or on a network file system may hang forever
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

/// Parses the output of `zig env`. `zig env` prints environment variables such as
/// ZIG_GLOBAL_CACHE_DIR verbatim, so they may be relative paths: they are made absolute against
/// the current directory `cwd`
fn fromOutput(gpa: Allocator, text: []const u8, cwd: []const u8) error{ OutOfMemory, ParseZon }!ZigEnv {
    var env = try parse(gpa, text);
    errdefer env.deinit(gpa);
    // The arena state must be written back before `return env` copies the return value: a defer
    // runs only after the copy
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

/// Paths configured by the user, taking precedence over the values reported by `zig env`;
/// relative paths are resolved against the current directory
pub const Overrides = struct {
    /// The lib directory: must contain `std/std.zig`
    lib_dir: ?[]const u8 = null,
    /// The global cache directory: must be an existing directory
    global_cache_dir: ?[]const u8 = null,
};

/// Overrides not applied by `withOverrides`: the path does not exist or does not meet the
/// requirements
pub const Rejected = struct {
    lib_dir: bool = false,
    global_cache_dir: bool = false,
};

pub const OverrideError = Allocator.Error || Io.Cancelable || Environ.CreateMapError;

/// Overrides the paths in `base` (the result of `zig env`) with `overrides` and returns a new
/// environment (not referencing the memory of `base`). Overrides that cannot be applied are
/// recorded in `rejected`, keeping the values of `base`. When any override is applied, the
/// environment variables of the child processes running zig are the current process's `environ`
/// plus the overriding paths.
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
        .local_cache_dir_set = base.local_cache_dir_set,
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

/// Whether the two environments give the same paths (zig executable, lib directory, standard
/// library directory, global cache directory)
pub fn samePaths(a: *const ZigEnv, b: *const ZigEnv) bool {
    return std.mem.eql(u8, a.zig_exe, b.zig_exe) and std.mem.eql(u8, a.lib_dir, b.lib_dir) and
        std.mem.eql(u8, a.std_dir, b.std_dir) and std.mem.eql(u8, a.global_cache_dir, b.global_cache_dir);
}

/// Converts a file path from the configuration (such as `zig.builtin_path`) to a normalized
/// absolute path (freed by the caller), resolving relative paths against the current directory.
/// Null when it does not exist or (after following symbolic links) is not a file.
pub fn resolveFile(gpa: Allocator, io: Io, path: []const u8) (Allocator.Error || Io.Cancelable)!?[]u8 {
    const resolved = try resolveOverride(gpa, io, path) orelse return null;
    if (try isKind(io, resolved, .file)) return resolved;
    gpa.free(resolved);
    return null;
}

/// Converts a configured path to a normalized absolute path (relative paths against the current
/// directory); null when the current directory cannot be obtained
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

/// Whether `path` exists and (after following symbolic links) is a file of kind `kind`
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

    // No overrides: the same as the result of `zig env`; child processes inherit the environment
    // variables of the current process
    var same = try base.withOverrides(gpa, io, .empty, .{}, &rejected);
    defer same.deinit(gpa);
    try std.testing.expectEqualStrings(base.std_dir, same.std_dir);
    try std.testing.expectEqualStrings(base.global_cache_dir, same.global_cache_dir);
    try std.testing.expect(same.childEnviron() == null and !rejected.lib_dir and !rejected.global_cache_dir);

    // Valid overrides: the paths are replaced, and zig is told through environment variables.
    // Relative paths are resolved against the current directory, and trailing separators are
    // removed.
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

    // A nonexistent path, a directory without the standard library, a cache that is not a
    // directory: not applied, keeping the values of `zig env`
    var invalid = try base.withOverrides(gpa, io, .empty, .{ .lib_dir = cache, .global_cache_dir = missing }, &rejected);
    defer invalid.deinit(gpa);
    try std.testing.expect(rejected.lib_dir and rejected.global_cache_dir);
    try std.testing.expectEqualStrings(base.lib_dir, invalid.lib_dir);
    try std.testing.expectEqualStrings(base.std_dir, invalid.std_dir);
    try std.testing.expectEqualStrings(base.global_cache_dir, invalid.global_cache_dir);
    try std.testing.expect(invalid.childEnviron() == null);

    // Only the valid one is applied
    var partial = try base.withOverrides(gpa, io, .empty, .{ .lib_dir = lib, .global_cache_dir = std_file }, &rejected);
    defer partial.deinit(gpa);
    try std.testing.expect(!rejected.lib_dir and rejected.global_cache_dir);
    try std.testing.expectEqualStrings(lib, partial.lib_dir);
    try std.testing.expectEqualStrings(base.global_cache_dir, partial.global_cache_dir);
    try std.testing.expectEqualStrings(lib, partial.childEnviron().?.get("ZIG_LIB_DIR").?);
    try std.testing.expect(partial.childEnviron().?.get("ZIG_GLOBAL_CACHE_DIR") == null);
}

/// Parses the ZON output of `zig env`
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
        env: struct { ZIG_LOCAL_CACHE_DIR: ?[]const u8 = null } = .{},
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
        .local_cache_dir_set = raw.env.ZIG_LOCAL_CACHE_DIR != null,
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
    try std.testing.expect(!env.local_cache_dir_set);

    var local = try parse(std.testing.allocator,
        \\.{ .zig_exe = "zig", .lib_dir = "lib", .std_dir = "lib/std", .global_cache_dir = "c", .version = "0.17.0", .env = .{ .ZIG_LIB_DIR = null, .ZIG_LOCAL_CACHE_DIR = "/tmp/lc" } }
    );
    defer local.deinit(std.testing.allocator);
    try std.testing.expect(local.local_cache_dir_set);
}

test fromOutput {
    // Prevents the returned env from carrying the arena state from before the paths were
    // converted: when the allocator cannot grow in place, the chunk holding the absolute paths
    // leaks when freed
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .resize_fail_index = 0 });
    const gpa = failing.allocator();
    // A current directory long enough that the absolute paths do not fit in the arena's
    // existing chunk
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
    // This repository's CI and development environments run a supported zig
    try std.testing.expect(env.readsBuildGraph());
}

test "build graphs are read only from the supported versions" {
    for ([_]struct { []const u8, bool }{
        .{ "0.17.0", true },
        .{ "0.17.1", true },
        .{ "0.17.2", false },
        .{ "0.18.0-dev.1+abc", false },
    }) |case| {
        const version, const expected = case;
        const env: ZigEnv = .{ .arena = .{}, .zig_exe = "zig", .lib_dir = "", .std_dir = "", .global_cache_dir = "", .version = version };
        try std.testing.expectEqual(expected, env.readsBuildGraph());
    }
}
