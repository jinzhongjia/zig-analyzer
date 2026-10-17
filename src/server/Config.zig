//! 用户配置：来自客户端，即 `initialize` 的 `initializationOptions` 与
//! `workspace/didChangeConfiguration` 推送（或经 `workspace/configuration` 拉取）的 settings。
//!
//! JSON 结构如下；也接受外面再包一层 `"zig-analyzer"`：
//!
//!     { "zig": { "path": "/usr/local/bin/zig" },
//!       "build": { "enable": true, "args": ["-Dtarget=aarch64-linux"] },
//!       "diagnostics": { "steps": ["check", "test"], "compiler": true, "inactive_code": true, "debounce_ms": 50 },
//!       "inlay_hints": { "types": true, "parameters": true, "hide_redundant_param_names": true },
//!       "sema": { "callsite_seeding": true },
//!       "log": { "level": "info", "file": "/tmp/zig-analyzer.log", "slow_request_ms": 100 } }
//!
//! 逐项解析：未知的项与类型错误的项只产生警告（`warnings`），类型错误的项取默认值，其余项照常生效。
//!
//! 项目根目录的 `zig-analyzer.json`（同样的结构）可以设置与项目相关的项（`project_settings`），
//! 供团队共享；其中出现的项优先于客户端的配置（`overlayProject`）。

const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

const Config = @This();

arena: std.heap.ArenaAllocator.State = .{},
/// zig 可执行文件；null 时从 PATH 查找
zig_path: ?[]const u8 = null,
/// 是否通过构建系统协议获取项目模型；关闭时所有文件按单文件处理
build_enable: bool = true,
/// 传给 `zig build` 的额外参数（如 `-Dtarget=...`）
build_args: []const []const u8 = &.{},
/// 用于诊断的 step（`diagnostics.step`，与 `diagnostics.steps` 合并）
diagnostics_step: ?[]const u8 = null,
/// 用于诊断的 step 列表；为空时用 `check`，没有则用默认 step
diagnostics_steps: []const []const u8 = &.{},
/// 是否运行编译器得到诊断；关闭时只有 live 诊断（语法与 AstGen）
compiler_diagnostics: bool = true,
/// 编辑后等待这么多毫秒没有新的编辑才计算 live 诊断；0 为不等待
debounce_ms: u32 = 50,
/// 是否把当前构建配置下不编译的代码（comptime 已知不执行的分支）显示为非活动代码
inactive_code: bool = true,
/// inlay hints：推导出的类型
inlay_types: bool = true,
/// inlay hints：实参对应的形参名
inlay_parameters: bool = true,
/// 实参与形参同名（或以形参名结尾的字段访问）时不显示形参名
hide_redundant_param_names: bool = true,
/// 泛型函数体内没有具体类型时以调用点的实例推导（hover、补全、inlay hints 等）
callsite_seeding: bool = true,
/// InternPool 超过这么多 MB 时整代回收类型信息（之后按需重新推导）；0 为不回收
max_intern_pool_mb: u32 = 64,
/// 日志级别（err / warn / info / debug）
log_level: std.log.Level = .info,
/// 日志同时追加到这个文件；null 为只写 stderr
log_file: ?[]const u8 = null,
/// 请求超过这么多毫秒时记录查询耗时（慢请求日志）；0 为关闭
slow_request_ms: u32 = 100,
/// 解析时发现的问题（未知的项、类型错误的项），用于提示用户
warnings: []const []const u8 = &.{},
/// 配置中出现（且类型正确）的项，下标对应 `settings`
present: std.StaticBitSet(settings.len) = .empty,

/// 项目配置文件的文件名（位于项目根目录）
pub const project_file = "zig-analyzer.json";

/// 配置项：JSON 中的「分组.名字」与对应的字段
const Setting = struct { section: []const u8, key: []const u8, field: []const u8 };

const settings = [_]Setting{
    .{ .section = "zig", .key = "path", .field = "zig_path" },
    .{ .section = "build", .key = "enable", .field = "build_enable" },
    .{ .section = "build", .key = "args", .field = "build_args" },
    .{ .section = "diagnostics", .key = "step", .field = "diagnostics_step" },
    .{ .section = "diagnostics", .key = "steps", .field = "diagnostics_steps" },
    .{ .section = "diagnostics", .key = "compiler", .field = "compiler_diagnostics" },
    .{ .section = "diagnostics", .key = "inactive_code", .field = "inactive_code" },
    .{ .section = "diagnostics", .key = "debounce_ms", .field = "debounce_ms" },
    .{ .section = "inlay_hints", .key = "types", .field = "inlay_types" },
    .{ .section = "inlay_hints", .key = "parameters", .field = "inlay_parameters" },
    .{ .section = "inlay_hints", .key = "hide_redundant_param_names", .field = "hide_redundant_param_names" },
    .{ .section = "sema", .key = "callsite_seeding", .field = "callsite_seeding" },
    .{ .section = "sema", .key = "max_intern_pool_mb", .field = "max_intern_pool_mb" },
    .{ .section = "log", .key = "level", .field = "log_level" },
    .{ .section = "log", .key = "file", .field = "log_file" },
    .{ .section = "log", .key = "slow_request_ms", .field = "slow_request_ms" },
};

/// 可以在项目配置文件中设置的项
const project_settings = [_][]const u8{ "build_args", "diagnostics_step", "diagnostics_steps", "compiler_diagnostics" };

fn isProjectSetting(comptime field: []const u8) bool {
    for (project_settings) |f| if (std.mem.eql(u8, f, field)) return true;
    return false;
}

pub fn deinit(c: *Config, gpa: Allocator) void {
    var arena = c.arena.promote(gpa);
    arena.deinit();
    c.* = undefined;
}

/// 解析配置。只有根不是对象时返回 `error.InvalidConfig`；其余问题记入 `warnings`
pub fn parse(gpa: Allocator, value: json.Value) error{ OutOfMemory, InvalidConfig }!Config {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const root = if (value == .object) value.object.get("zig-analyzer") orelse value else value;
    if (root != .object) return error.InvalidConfig;

    var c: Config = .{};
    var warnings: std.ArrayList([]const u8) = .empty;
    var sections = root.object.iterator();
    while (sections.next()) |section| {
        const name = section.key_ptr.*;
        if (!isSection(name)) {
            try warnings.append(a, try std.fmt.allocPrint(a, "unknown setting `{s}`", .{name}));
            continue;
        }
        if (section.value_ptr.* != .object) {
            try warnings.append(a, try std.fmt.allocPrint(a, "`{s}` must be an object", .{name}));
            continue;
        }
        var keys = section.value_ptr.object.iterator();
        keys: while (keys.next()) |entry| {
            const key = entry.key_ptr.*;
            inline for (settings, 0..) |s, si| if (std.mem.eql(u8, s.section, name) and std.mem.eql(u8, s.key, key)) {
                const T = @FieldType(Config, s.field);
                if (json.parseFromValueLeaky(T, a, entry.value_ptr.*, .{ .allocate = .alloc_always })) |v| {
                    @field(c, s.field) = v;
                    c.present.set(si);
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => try warnings.append(a, try std.fmt.allocPrint(a, "invalid value for `{s}.{s}`, using the default", .{ name, key })),
                }
                continue :keys;
            };
            try warnings.append(a, try std.fmt.allocPrint(a, "unknown setting `{s}.{s}`", .{ name, key }));
        }
    }
    c.warnings = warnings.items;
    c.arena = arena.state;
    return c;
}

fn isSection(name: []const u8) bool {
    inline for (settings) |s| if (std.mem.eql(u8, s.section, name)) return true;
    return false;
}

/// 解析项目配置文件的内容。JSON 有误时返回 `error.InvalidConfig`；不能在项目中设置的项记入 `warnings` 并忽略
pub fn parseProject(gpa: Allocator, text: []const u8) error{ OutOfMemory, InvalidConfig }!Config {
    const value = json.parseFromSlice(json.Value, gpa, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidConfig,
    };
    defer value.deinit();
    var c = try parse(gpa, value.value);
    errdefer c.deinit(gpa);
    // arena 的状态须在 `return c` 复制返回值之前写回：defer 在复制之后才执行
    {
        var arena = c.arena.promote(gpa);
        defer c.arena = arena.state;
        const a = arena.allocator();
        var warnings: std.ArrayList([]const u8) = .fromOwnedSlice(@constCast(c.warnings));
        inline for (settings, 0..) |s, si| if (comptime !isProjectSetting(s.field)) if (c.present.isSet(si)) {
            try warnings.append(a, try std.fmt.allocPrint(a, "`{s}.{s}` cannot be set in " ++ project_file, .{ s.section, s.key }));
            c.present.unset(si);
        };
        c.warnings = warnings.items;
    }
    return c;
}

/// 以项目配置中出现的项覆盖（`project` 由 `parseProject` 得到）
pub fn overlayProject(c: *Config, gpa: Allocator, project: *const Config) Allocator.Error!void {
    var arena = c.arena.promote(gpa);
    defer c.arena = arena.state;
    const a = arena.allocator();
    inline for (settings, 0..) |s, si| if (comptime isProjectSetting(s.field)) {
        if (project.present.isSet(si)) {
            @field(c, s.field) = try dupeValue(a, @field(project, s.field));
            c.present.set(si);
        }
    };
}

fn dupeValue(a: Allocator, v: anytype) Allocator.Error!@TypeOf(v) {
    return switch (@TypeOf(v)) {
        ?[]const u8 => if (v) |x| try a.dupe(u8, x) else null,
        []const []const u8 => blk: {
            const list = try a.alloc([]const u8, v.len);
            for (v, list) |src, *dst| dst.* = try a.dupe(u8, src);
            break :blk list;
        },
        else => v,
    };
}

/// 深拷贝（不含 `warnings`）
pub fn clone(c: *const Config, gpa: Allocator) Allocator.Error!Config {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var out: Config = .{};
    inline for (settings) |s| @field(out, s.field) = try dupeValue(a, @field(c, s.field));
    out.present = c.present;
    out.arena = arena.state;
    return out;
}

/// 用于诊断的 step：`diagnostics.steps` 与 `diagnostics.step` 合并；为空时由项目决定（`check` 或默认 step）
pub fn diagnosticsSteps(c: *const Config, a: Allocator) Allocator.Error![]const []const u8 {
    if (c.diagnostics_step == null) return c.diagnostics_steps;
    for (c.diagnostics_steps) |s| if (std.mem.eql(u8, s, c.diagnostics_step.?)) return c.diagnostics_steps;
    const out = try a.alloc([]const u8, c.diagnostics_steps.len + 1);
    out[0] = c.diagnostics_step.?;
    @memcpy(out[1..], c.diagnostics_steps);
    return out;
}

/// 影响构建系统协议进程的配置是否相同（不同时需要重启项目）
pub fn sameBuild(a: *const Config, b: *const Config) bool {
    if (a.build_enable != b.build_enable or a.compiler_diagnostics != b.compiler_diagnostics) return false;
    if (!eqlOptional(a.diagnostics_step, b.diagnostics_step)) return false;
    return eqlList(a.build_args, b.build_args) and eqlList(a.diagnostics_steps, b.diagnostics_steps);
}

pub fn sameZig(a: *const Config, b: *const Config) bool {
    return eqlOptional(a.zig_path, b.zig_path);
}

fn eqlOptional(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn eqlList(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

const testing = std.testing;

fn parseText(text: []const u8) !Config {
    const value = try json.parseFromSlice(json.Value, testing.allocator, text, .{});
    defer value.deinit();
    return parse(testing.allocator, value.value);
}

test "parse: nested fields, optional wrapper" {
    var c = try parseText(
        \\{"zig-analyzer": {"zig": {"path": "/z/zig"}, "build": {"args": ["-Da=1", "-Db"]}, "diagnostics": {"step": "test", "steps": ["check"]}}}
    );
    defer c.deinit(testing.allocator);
    try testing.expectEqualStrings("/z/zig", c.zig_path.?);
    try testing.expectEqual(2, c.build_args.len);
    try testing.expectEqualStrings("-Db", c.build_args[1]);
    try testing.expectEqual(0, c.warnings.len);
    const steps = try c.diagnosticsSteps(testing.allocator);
    defer testing.allocator.free(steps);
    try testing.expectEqualStrings("test", steps[0]);
    try testing.expectEqualStrings("check", steps[1]);

    var copy = try c.clone(testing.allocator);
    defer copy.deinit(testing.allocator);
    try testing.expect(c.sameBuild(&copy) and c.sameZig(&copy));

    var empty = try parseText("{}");
    defer empty.deinit(testing.allocator);
    try testing.expect(empty.zig_path == null and empty.build_args.len == 0 and empty.inactive_code and empty.build_enable and empty.callsite_seeding);
    try testing.expectEqual(0, (try empty.diagnosticsSteps(testing.allocator)).len);
    try testing.expect(!c.sameBuild(&empty) and !c.sameZig(&empty));

    var no_compiler = try parseText(
        \\{"diagnostics": {"compiler": false}, "inlay_hints": {"types": false}}
    );
    defer no_compiler.deinit(testing.allocator);
    try testing.expect(!no_compiler.compiler_diagnostics and !no_compiler.inlay_types and no_compiler.inlay_parameters);
    try testing.expect(!no_compiler.sameBuild(&empty));
}

test "parse: unknown and invalid settings are reported, the rest still applies" {
    var c = try parseText(
        \\{"build": {"args": "-Da=1", "enable": false}, "sema": {"callsite_seeding": false, "fuel": 1}, "colors": {}, "log": 3}
    );
    defer c.deinit(testing.allocator);
    // 类型错误的项取默认值，同组的其他项照常生效
    try testing.expectEqual(0, c.build_args.len);
    try testing.expect(!c.build_enable and !c.callsite_seeding);
    try testing.expectEqual(4, c.warnings.len);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (c.warnings) |w| try joined.print(testing.allocator, "{s}\n", .{w});
    try testing.expect(std.mem.indexOf(u8, joined.items, "invalid value for `build.args`, using the default") != null);
    try testing.expect(std.mem.indexOf(u8, joined.items, "unknown setting `sema.fuel`") != null);
    try testing.expect(std.mem.indexOf(u8, joined.items, "unknown setting `colors`") != null);
    try testing.expect(std.mem.indexOf(u8, joined.items, "`log` must be an object") != null);

    try testing.expectError(error.InvalidConfig, parseText("[]"));
}

test "project file: only project settings apply and override the client" {
    var client = try parseText(
        \\{"build": {"args": ["-Dclient"]}, "diagnostics": {"steps": ["check"]}, "log": {"level": "debug"}}
    );
    defer client.deinit(testing.allocator);
    var project = try parseProject(testing.allocator,
        \\{"build": {"args": ["-Dtarget=wasm32-freestanding"], "enable": false}, "diagnostics": {"compiler": false}, "log": {"level": "err"}}
    );
    defer project.deinit(testing.allocator);
    try testing.expectEqual(2, project.warnings.len);
    try testing.expectEqualStrings("`build.enable` cannot be set in zig-analyzer.json", project.warnings[0]);

    try client.overlayProject(testing.allocator, &project);
    try testing.expectEqualStrings("-Dtarget=wasm32-freestanding", client.build_args[0]);
    try testing.expect(!client.compiler_diagnostics and client.build_enable);
    // 项目中没有的项保留客户端的值
    try testing.expectEqualStrings("check", client.diagnostics_steps[0]);
    try testing.expectEqual(.debug, client.log_level);

    try testing.expectError(error.InvalidConfig, parseProject(testing.allocator, "{\"build\": "));
}

test "project file: the parsed config owns the memory of its warnings" {
    // 防止返回的配置带着加入警告之前的 arena 状态：分配器不能原地扩大时，警告所在的内存块在释放时泄漏
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .resize_fail_index = 0 });
    const gpa = failing.allocator();
    var project = try parseProject(gpa,
        \\{"build": {"enable": false}, "diagnostics": {"compiler": false}, "log": {"level": "err"}}
    );
    defer project.deinit(gpa);
    try testing.expectEqual(2, project.warnings.len);
    try testing.expectEqualStrings("`build.enable` cannot be set in zig-analyzer.json", project.warnings[0]);
}
