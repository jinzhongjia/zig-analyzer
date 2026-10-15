//! 用户配置（设计 §15 的最小版本）：只来自客户端，即 `initialize` 的 `initializationOptions`
//! 与 `workspace/didChangeConfiguration` 推送的 settings。
//!
//! JSON 结构如下，未知字段忽略；也接受外面再包一层 `"zig-analyzer"`：
//!
//!     { "zig": { "path": "/usr/local/bin/zig" },
//!       "build": { "args": ["-Dtarget=aarch64-linux"] },
//!       "diagnostics": { "step": "check", "inactive_code": true },
//!       "log": { "level": "info", "file": "/tmp/zig-analyzer.log", "slow_request_ms": 100 } }

const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

const Config = @This();

arena: std.heap.ArenaAllocator.State = .{},
/// 日志级别（err / warn / info / debug）
log_level: std.log.Level = .info,
/// 日志同时追加到这个文件；null 为只写 stderr
log_file: ?[]const u8 = null,
/// 请求超过这么多毫秒时记录查询耗时（慢请求日志）；0 为关闭
slow_request_ms: u32 = 100,
/// zig 可执行文件；null 时从 PATH 查找
zig_path: ?[]const u8 = null,
/// 传给 `zig build` 的额外参数（如 `-Dtarget=...`）
build_args: []const []const u8 = &.{},
/// 用于诊断的 step；null 时用 `check`，没有则用默认 step
diagnostics_step: ?[]const u8 = null,
/// 是否把当前构建配置下不编译的代码（comptime 已知不执行的分支）显示为非活动代码
inactive_code: bool = true,

const Json = struct {
    zig: ?struct { path: ?[]const u8 = null } = null,
    build: ?struct { args: ?[]const []const u8 = null } = null,
    diagnostics: ?struct { step: ?[]const u8 = null, inactive_code: ?bool = null } = null,
    log: ?struct { level: ?std.log.Level = null, file: ?[]const u8 = null, slow_request_ms: ?u32 = null } = null,
};

pub fn deinit(c: *Config, gpa: Allocator) void {
    var arena = c.arena.promote(gpa);
    arena.deinit();
    c.* = undefined;
}

pub fn parse(gpa: Allocator, value: json.Value) error{ OutOfMemory, InvalidConfig }!Config {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const root = if (value == .object) value.object.get("zig-analyzer") orelse value else value;
    const j = json.parseFromValueLeaky(Json, arena.allocator(), root, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidConfig,
    };
    return .{
        .arena = arena.state,
        .zig_path = if (j.zig) |z| z.path else null,
        .build_args = if (j.build) |b| b.args orelse &.{} else &.{},
        .diagnostics_step = if (j.diagnostics) |d| d.step else null,
        .inactive_code = if (j.diagnostics) |d| d.inactive_code orelse true else true,
        .log_level = if (j.log) |l| l.level orelse .info else .info,
        .log_file = if (j.log) |l| l.file else null,
        .slow_request_ms = if (j.log) |l| l.slow_request_ms orelse 100 else 100,
    };
}

pub fn clone(c: *const Config, gpa: Allocator) Allocator.Error!Config {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const args = try a.alloc([]const u8, c.build_args.len);
    for (c.build_args, args) |src, *dst| dst.* = try a.dupe(u8, src);
    return .{
        .zig_path = if (c.zig_path) |p| try a.dupe(u8, p) else null,
        .build_args = args,
        .diagnostics_step = if (c.diagnostics_step) |s| try a.dupe(u8, s) else null,
        .inactive_code = c.inactive_code,
        .log_level = c.log_level,
        .log_file = if (c.log_file) |f| try a.dupe(u8, f) else null,
        .slow_request_ms = c.slow_request_ms,
        .arena = arena.state,
    };
}

/// 影响构建系统协议进程的配置是否相同（不同时需要重启项目）
pub fn sameBuild(a: *const Config, b: *const Config) bool {
    if (!eqlOptional(a.diagnostics_step, b.diagnostics_step)) return false;
    if (a.build_args.len != b.build_args.len) return false;
    for (a.build_args, b.build_args) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

pub fn sameZig(a: *const Config, b: *const Config) bool {
    return eqlOptional(a.zig_path, b.zig_path);
}

fn eqlOptional(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

const testing = std.testing;

fn parseText(text: []const u8) !Config {
    const value = try json.parseFromSlice(json.Value, testing.allocator, text, .{});
    defer value.deinit();
    return parse(testing.allocator, value.value);
}

test "parse: nested fields, optional wrapper, unknown fields ignored" {
    var c = try parseText(
        \\{"zig-analyzer": {"zig": {"path": "/z/zig"}, "build": {"args": ["-Da=1", "-Db"]}, "diagnostics": {"step": "test"}, "other": 1}}
    );
    defer c.deinit(testing.allocator);
    try testing.expectEqualStrings("/z/zig", c.zig_path.?);
    try testing.expectEqual(2, c.build_args.len);
    try testing.expectEqualStrings("-Db", c.build_args[1]);
    try testing.expectEqualStrings("test", c.diagnostics_step.?);

    var copy = try c.clone(testing.allocator);
    defer copy.deinit(testing.allocator);
    try testing.expect(c.sameBuild(&copy) and c.sameZig(&copy));

    var empty = try parseText("{}");
    defer empty.deinit(testing.allocator);
    try testing.expect(empty.zig_path == null and empty.build_args.len == 0 and empty.diagnostics_step == null and empty.inactive_code);
    var no_inactive = try parseText(
        \\{"diagnostics": {"inactive_code": false}}
    );
    defer no_inactive.deinit(testing.allocator);
    try testing.expect(!no_inactive.inactive_code);
    try testing.expect(!c.sameBuild(&empty) and !c.sameZig(&empty));
}

test "parse: wrong types are rejected" {
    try testing.expectError(error.InvalidConfig, parseText(
        \\{"build": {"args": "-Da=1"}}
    ));
    try testing.expectError(error.InvalidConfig, parseText("[]"));
}
