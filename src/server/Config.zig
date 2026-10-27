//! 用户配置：来自客户端，即 `initialize` 的 `initializationOptions` 与
//! `workspace/didChangeConfiguration` 推送（或经 `workspace/configuration` 拉取）的 settings。
//!
//! JSON 结构如下；也接受外面再包一层 `"zig-analyzer"`：
//!
//!     { "zig": { "path": "/usr/local/bin/zig", "lib_path": "/usr/local/lib/zig", "builtin_path": "/tmp/builtin.zig",
//!                "global_cache_path": "/home/me/.cache/zig" },
//!       "build": { "enable": true, "args": ["-Dtarget=aarch64-linux"] },
//!       "diagnostics": { "steps": ["check", "test"], "compiler": true, "inactive_code": false, "debounce_ms": 50 },
//!       "inlay_hints": { "types": true, "field_types": true, "anonymous_containers": false, "parameters": true,
//!                        "builtin_parameters": true, "exclude_single_argument": true, "hide_redundant_param_names": true,
//!                        "max_length": 25 },
//!       "semantic_tokens": { "mode": "full", "global_var": false },
//!       "imports": { "derived": "with_import", "sort": "path" },
//!       "completion": { "auto_import": true, "max_auto_imports": 128 },
//!       "sema": { "callsite_seeding": true },
//!       "cache": { "capacity": 64, "queries": { "Infer": { "count": 16384, "mb": 48 } } },
//!       "workspace_symbol": { "dependencies": false, "limit": 256 },
//!       "naming": { "enable": false, "ignore": ["SDL_*"], "exclude": ["src/c/*"], "rules": { "field": false } },
//!       "files": { "watcher": "auto" },
//!       "log": { "level": "info", "file": "/tmp/zig-analyzer.log", "slow_request_ms": 100 } }
//!
//! 逐项解析：未知的项与类型错误的项只产生警告（`warnings`），类型错误的项取默认值，其余项照常生效。
//!
//! 项目根目录的 `zig-analyzer.zon` 可以设置与项目相关的项（`project_settings`），供团队共享；其中出现的项优先于
//! 客户端的配置（`overlayProject`）。结构相同，写成 ZON（可以有注释），枚举值写成枚举字面量：
//!
//!     .{
//!         .build = .{ .args = .{"-Dtarget=aarch64-linux"} },
//!         .naming = .{ .enable = true, .rules = .{ .field = false } },
//!     }

const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const ImportOptions = @import("../ide_db/organize_imports.zig").Options;
const syntax_queries = @import("../syntax/queries.zig");

const Config = @This();

arena: std.heap.ArenaAllocator.State = .{},
/// zig 可执行文件；null 时从 PATH 查找
zig_path: ?[]const u8 = null,
/// zig 的 lib 目录（其下有 `std/std.zig`），标准库从这里解析，运行 zig 时同样使用；null 时用 `zig env` 给出的
zig_lib_path: ?[]const u8 = null,
/// 不属于任何项目的文件（单文件模式等）的 `@import("builtin")`；null 时按 `zig test` 的设置生成。
/// 项目中的模块总是用按构建参数生成的
zig_builtin_path: ?[]const u8 = null,
/// zig 的全局缓存目录（依赖包、生成的 builtin.zig 等），运行 zig 时同样使用；null 时用 `zig env` 给出的
zig_global_cache_path: ?[]const u8 = null,
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
inactive_code: bool = false,
/// inlay hints：推导出的类型
inlay_types: bool = true,
/// inlay hints：初始化表达式中字段名之后的字段类型
inlay_field_types: bool = true,
/// inlay hints：类型中有按内容显示的匿名容器（`struct { a: u32 }`）时也显示类型提示
inlay_anonymous_containers: bool = false,
/// inlay hints：实参对应的形参名
inlay_parameters: bool = true,
/// inlay hints：内置函数调用的参数名（`inlay_parameters` 关闭时同样不显示）
inlay_builtin_parameters: bool = true,
/// 只有一个实参的调用（含内置函数）不显示形参名
inlay_exclude_single_argument: bool = true,
/// 实参去掉 `&`、`.*`、`.?`、`try` 后与形参同名（或是以形参名结尾的字段访问）时不显示形参名
hide_redundant_param_names: bool = true,
/// inlay hints：类型提示的字符数上限，超出时列表（字段、实参等）的其余项显示为 `…`；0 为不限
inlay_max_length: u32 = 25,
/// 语义着色发出哪些 token
semantic_tokens_mode: SemanticTokensMode = .full,
/// 语义着色：容器级 `var` 的声明与引用带 `global` modifier
semantic_tokens_global_var: bool = false,
/// import 块中派生声明（`const Allocator = std.mem.Allocator;`）的位置：整理 import 与自动导入都按它
imports_derived: ImportOptions.Derived = .with_import,
/// import 块的组内排序：按引用的路径或声明名
imports_sort: ImportOptions.Sort = .path,
/// 普通名字补全中提供可达声明与模块的自动导入，以及按整条路径匹配的可见命名空间的成员
completion_auto_import: bool = true,
/// 一次补全至多提供的自动导入候选（保留排序最好的，其余由客户端随输入重新请求得到）；0 为不限
completion_max_auto_imports: u32 = 128,
/// 泛型函数体内没有具体类型时以调用点的实例推导（hover、补全、inlay hints 等）
callsite_seeding: bool = true,
/// InternPool 超过这么多 MB 时整代回收类型信息（之后按需重新推导）；0 为不回收
max_intern_pool_mb: u32 = 64,
/// 保留的语法树个数（`ParseFile` 与 `FileAstIdMap`，被淘汰的按需重新解析）；0 为不限
cache_capacity: u32 = syntax_queries.parse_lru,
/// 按 query 设置的缓存容量，优先于 `cache_capacity`
cache_queries: CacheQueries = .{},
/// workspace symbol 是否也列出依赖库（获取的依赖包、生成文件、打开的标准库文件）中的符号
workspace_symbol_dependencies: bool = false,
/// workspace symbol 至多返回的符号数（保留匹配最好的）；0 为不限。随输入重新查询的客户端不需要一次拿到全部，
/// 只查询一次、在客户端过滤的需要调高或设为 0
workspace_symbol_limit: u32 = 256,
/// 命名检查（Zig 风格指南的 Names 一节）：是否为打开的文件提示不符合命名约定的名字，并提供改名的修复
naming_enable: bool = false,
/// 命名检查跳过的名字；`*` 匹配任意字符序列（`SDL_*`）
naming_ignore: []const []const u8 = &.{},
/// 命名检查跳过的文件：相对工作区根目录（`zig-analyzer.zon` 中为相对项目根目录）、以 `/` 分隔的路径；
/// `*` 匹配任意字符序列（含 `/`）
naming_exclude: []const []const u8 = &.{},
/// 命名检查的各条规则是否启用
naming_rules: NamingRules = .{},
/// 磁盘上的外部改动由谁发现（见 `Watcher`）
files_watcher: Watcher = .auto,
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

/// 外部改动的来源。客户端支持时总会向它注册文件监听（`workspace/didChangeWatchedFiles`）
pub const Watcher = enum {
    /// 客户端不支持动态注册文件监听时由服务器监听
    auto,
    /// 只用客户端的通知
    client,
    /// 总是由服务器监听（客户端的通知仍然处理）
    server,
};

/// 语义着色发出的 token
pub const SemanticTokensMode = enum {
    /// 全部 token
    full,
    /// 只发需要名字解析与类型推导才能确定分类的 token；关键字、注释、字面量、运算符、标签与内建名留给编辑器的语法高亮
    partial,
};

/// 一个 query 的缓存容量：保留的值的个数与 MB 数，null 为默认值，0 为不限。超出时淘汰最久未使用的值，之后按需重算，
/// 结果不变
pub const CacheLimit = struct {
    count: ?u32 = null,
    mb: ?u32 = null,
};

/// 可以设置缓存容量的 query，字段名即 query 名
pub const CacheQueries = struct {
    ParseFile: CacheLimit = .{},
    FileAstIdMap: CacheLimit = .{},
    FileItemTree: CacheLimit = .{},
    ItemBody: CacheLimit = .{},
    Infer: CacheLimit = .{},
    Exports: CacheLimit = .{},
};

/// 命名检查的规则，与诊断的 code `naming.<规则>` 一一对应
pub const NamingRules = struct {
    /// 类型与类型别名：TitleCase
    type: bool = true,
    /// 返回 `type` 的可调用对象：TitleCase
    type_function: bool = true,
    /// 其他可调用对象（函数、函数别名、函数指针）：camelCase
    function: bool = true,
    /// 命名空间（没有顶层字段的文件）：snake_case
    namespace: bool = true,
    /// 其他值：snake_case
    value: bool = true,
    /// 字段与枚举成员（写法按字段的类型）
    field: bool = true,
};

/// 项目配置文件的文件名（位于项目根目录）
pub const project_file = "zig-analyzer.zon";

/// 配置项：「分组.名字」与对应的字段
const Setting = struct { section: []const u8, key: []const u8, field: []const u8 };

const settings = [_]Setting{
    .{ .section = "zig", .key = "path", .field = "zig_path" },
    .{ .section = "zig", .key = "lib_path", .field = "zig_lib_path" },
    .{ .section = "zig", .key = "builtin_path", .field = "zig_builtin_path" },
    .{ .section = "zig", .key = "global_cache_path", .field = "zig_global_cache_path" },
    .{ .section = "build", .key = "enable", .field = "build_enable" },
    .{ .section = "build", .key = "args", .field = "build_args" },
    .{ .section = "diagnostics", .key = "step", .field = "diagnostics_step" },
    .{ .section = "diagnostics", .key = "steps", .field = "diagnostics_steps" },
    .{ .section = "diagnostics", .key = "compiler", .field = "compiler_diagnostics" },
    .{ .section = "diagnostics", .key = "inactive_code", .field = "inactive_code" },
    .{ .section = "diagnostics", .key = "debounce_ms", .field = "debounce_ms" },
    .{ .section = "inlay_hints", .key = "types", .field = "inlay_types" },
    .{ .section = "inlay_hints", .key = "field_types", .field = "inlay_field_types" },
    .{ .section = "inlay_hints", .key = "anonymous_containers", .field = "inlay_anonymous_containers" },
    .{ .section = "inlay_hints", .key = "parameters", .field = "inlay_parameters" },
    .{ .section = "inlay_hints", .key = "builtin_parameters", .field = "inlay_builtin_parameters" },
    .{ .section = "inlay_hints", .key = "exclude_single_argument", .field = "inlay_exclude_single_argument" },
    .{ .section = "inlay_hints", .key = "hide_redundant_param_names", .field = "hide_redundant_param_names" },
    .{ .section = "inlay_hints", .key = "max_length", .field = "inlay_max_length" },
    .{ .section = "semantic_tokens", .key = "mode", .field = "semantic_tokens_mode" },
    .{ .section = "semantic_tokens", .key = "global_var", .field = "semantic_tokens_global_var" },
    .{ .section = "imports", .key = "derived", .field = "imports_derived" },
    .{ .section = "imports", .key = "sort", .field = "imports_sort" },
    .{ .section = "completion", .key = "auto_import", .field = "completion_auto_import" },
    .{ .section = "completion", .key = "max_auto_imports", .field = "completion_max_auto_imports" },
    .{ .section = "sema", .key = "callsite_seeding", .field = "callsite_seeding" },
    .{ .section = "sema", .key = "max_intern_pool_mb", .field = "max_intern_pool_mb" },
    .{ .section = "cache", .key = "capacity", .field = "cache_capacity" },
    .{ .section = "cache", .key = "queries", .field = "cache_queries" },
    .{ .section = "workspace_symbol", .key = "dependencies", .field = "workspace_symbol_dependencies" },
    .{ .section = "workspace_symbol", .key = "limit", .field = "workspace_symbol_limit" },
    .{ .section = "naming", .key = "enable", .field = "naming_enable" },
    .{ .section = "naming", .key = "ignore", .field = "naming_ignore" },
    .{ .section = "naming", .key = "exclude", .field = "naming_exclude" },
    .{ .section = "naming", .key = "rules", .field = "naming_rules" },
    .{ .section = "files", .key = "watcher", .field = "files_watcher" },
    .{ .section = "log", .key = "level", .field = "log_level" },
    .{ .section = "log", .key = "file", .field = "log_file" },
    .{ .section = "log", .key = "slow_request_ms", .field = "slow_request_ms" },
};

/// 可以在项目配置文件中设置的项
const project_settings = [_][]const u8{
    "build_args",      "diagnostics_step", "diagnostics_steps", "compiler_diagnostics",
    "naming_enable",   "naming_ignore",    "naming_exclude",    "naming_rules",
    "imports_derived", "imports_sort",
};

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

/// 解析项目配置文件（ZON）的内容。不能在项目中设置的项记入 `warnings` 并忽略；语法错误、类型错误或未知的项使整个
/// 文件被忽略，第一处错误（含位置）记入 `warnings`
pub fn parseProject(gpa: Allocator, text: []const u8) Allocator.Error!Config {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var c: Config = .{};
    var warnings: std.ArrayList([]const u8) = .empty;
    try readProject(gpa, arena.allocator(), text, &c, &warnings);
    c.warnings = warnings.items;
    c.arena = arena.state;
    return c;
}

/// 项目配置文件的结构：分组与项同 `settings`，各项可选（没有写出时为 null）。
/// 整个文件一次解析：`std.zon.parse.fromZoir` 不使用 `node` 选项，总是从根开始，不能逐项解析
const ProjectFile = blk: {
    // 每个分组都遍历一遍全部配置项
    @setEvalBranchQuota(4000);
    const Attrs = std.lang.Type.Struct.FieldAttributes;
    var names: []const []const u8 = &.{};
    for (settings) |s| {
        for (names) |n| {
            if (std.mem.eql(u8, n, s.section)) break;
        } else names = names ++ .{s.section};
    }
    var types: [names.len]type = undefined;
    var attrs: [names.len]Attrs = undefined;
    for (names, &types, &attrs) |name, *Section, *attr| {
        var keys: []const []const u8 = &.{};
        var key_types: []const type = &.{};
        var key_attrs: []const Attrs = &.{};
        for (settings) |s| if (std.mem.eql(u8, s.section, name)) {
            // 本身可选的项（`zig.path` 等）不再包一层：ZON 不支持嵌套的可选类型，写成 null 等同于没写
            const T = @FieldType(Config, s.field);
            const V = if (@typeInfo(T) == .optional) T else ?T;
            keys = keys ++ .{s.key};
            key_types = key_types ++ .{V};
            key_attrs = key_attrs ++ .{Attrs{ .default_value_ptr = &@as(V, null) }};
        };
        Section.* = @Struct(.auto, null, keys, key_types[0..keys.len], key_attrs[0..keys.len]);
        attr.* = .{ .default_value_ptr = &@as(Section.*, .{}) };
    }
    break :blk @Struct(.auto, null, names, &types, &attrs);
};

/// `parseProject` 的主体：设置写入 `c`，问题记入 `warnings`，都分配在 `a` 中
fn readProject(gpa: Allocator, a: Allocator, text: []const u8, c: *Config, warnings: *std.ArrayList([]const u8)) Allocator.Error!void {
    var diag: std.zon.parse.Diagnostics = undefined;
    const file = std.zon.parse.fromSlice(ProjectFile, .{
        .gpa = gpa,
        .arena = a,
        .source = try a.dupeSentinel(u8, text, 0),
        .diagnostics = &diag,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            const e = diag.errors[0];
            try warnings.append(a, try std.fmt.allocPrint(a, "{d}:{d}: {s}; the file is ignored", .{ e.loc.line + 1, e.loc.column + 1, e.msg }));
            return;
        },
    };
    inline for (settings, 0..) |s, si| if (@field(@field(file, s.section), s.key)) |v| {
        if (comptime isProjectSetting(s.field)) {
            @field(c, s.field) = v;
            c.present.set(si);
        } else {
            try warnings.append(a, try std.fmt.allocPrint(a, "`{s}.{s}` cannot be set in " ++ project_file, .{ s.section, s.key }));
        }
    };
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

/// 字段 `field` 对应的项是否出现在配置中（且类型正确）
pub fn isSet(c: *const Config, comptime field: []const u8) bool {
    inline for (settings, 0..) |s, si| if (comptime std.mem.eql(u8, s.field, field)) return c.present.isSet(si);
    @compileError("no setting for field " ++ field);
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

/// import 块的排列规则（整理 import、自动导入）
pub fn importOptions(c: *const Config) ImportOptions {
    return .{ .derived = c.imports_derived, .sort = c.imports_sort };
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

/// 覆盖 zig 环境的路径（lib 目录、默认 builtin、全局缓存目录）是否相同（不同时重新加载标准库与 builtin）
pub fn sameZigPaths(a: *const Config, b: *const Config) bool {
    return eqlOptional(a.zig_lib_path, b.zig_lib_path) and eqlOptional(a.zig_builtin_path, b.zig_builtin_path) and
        eqlOptional(a.zig_global_cache_path, b.zig_global_cache_path);
}

/// 命名检查的配置是否相同（不同时重新发布打开的文件）
pub fn sameNaming(a: *const Config, b: *const Config) bool {
    return a.naming_enable == b.naming_enable and std.meta.eql(a.naming_rules, b.naming_rules) and
        eqlList(a.naming_ignore, b.naming_ignore) and eqlList(a.naming_exclude, b.naming_exclude);
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
    try testing.expect(empty.zig_path == null and empty.build_args.len == 0 and !empty.inactive_code and empty.build_enable and empty.callsite_seeding);
    try testing.expectEqual(0, (try empty.diagnosticsSteps(testing.allocator)).len);
    try testing.expect(!c.sameBuild(&empty) and !c.sameZig(&empty));

    var no_compiler = try parseText(
        \\{"diagnostics": {"compiler": false}, "inlay_hints": {"types": false}}
    );
    defer no_compiler.deinit(testing.allocator);
    try testing.expect(!no_compiler.compiler_diagnostics and !no_compiler.inlay_types and no_compiler.inlay_parameters);
    try testing.expect(!no_compiler.sameBuild(&empty));

    try testing.expectEqual(Watcher.auto, empty.files_watcher);
    var server_watcher = try parseText(
        \\{"files": {"watcher": "server"}}
    );
    defer server_watcher.deinit(testing.allocator);
    try testing.expectEqual(Watcher.server, server_watcher.files_watcher);

    try testing.expect(empty.semantic_tokens_mode == .full and !empty.semantic_tokens_global_var);
    var partial = try parseText(
        \\{"semantic_tokens": {"mode": "partial", "global_var": true}}
    );
    defer partial.deinit(testing.allocator);
    try testing.expect(partial.semantic_tokens_mode == .partial and partial.semantic_tokens_global_var);
    try testing.expectEqual(0, partial.warnings.len);

    try testing.expect(empty.cache_capacity == 64 and empty.cache_queries.Infer.count == null and empty.cache_queries.Infer.mb == null);
    var cache = try parseText(
        \\{"cache": {"capacity": 0, "queries": {"Infer": {"count": 32768, "mb": 96}, "ParseFile": {"mb": 0}}}}
    );
    defer cache.deinit(testing.allocator);
    try testing.expectEqual(0, cache.cache_capacity);
    try testing.expect(cache.cache_queries.Infer.count.? == 32768 and cache.cache_queries.Infer.mb.? == 96);
    try testing.expect(cache.cache_queries.ParseFile.count == null and cache.cache_queries.ParseFile.mb.? == 0 and cache.cache_queries.ItemBody.count == null);
    try testing.expectEqual(0, cache.warnings.len);
    // 不能设置容量的 query：整项取默认值并警告
    var unknown_query = try parseText(
        \\{"cache": {"queries": {"Infer": {"count": 1}, "LocalValue": {"count": 1}}}}
    );
    defer unknown_query.deinit(testing.allocator);
    try testing.expect(unknown_query.cache_queries.Infer.count == null);
    try testing.expectEqual(1, unknown_query.warnings.len);
}

test "parse: zig path overrides" {
    var c = try parseText(
        \\{"zig": {"lib_path": "/z/lib", "builtin_path": "/z/builtin.zig", "global_cache_path": "/z/cache"}}
    );
    defer c.deinit(testing.allocator);
    try testing.expectEqual(0, c.warnings.len);
    try testing.expectEqualStrings("/z/lib", c.zig_lib_path.?);
    try testing.expectEqualStrings("/z/builtin.zig", c.zig_builtin_path.?);
    try testing.expectEqualStrings("/z/cache", c.zig_global_cache_path.?);

    var copy = try c.clone(testing.allocator);
    defer copy.deinit(testing.allocator);
    try testing.expect(c.sameZigPaths(&copy) and c.sameZig(&copy));

    var fewer = try parseText(
        \\{"zig": {"lib_path": "/z/lib", "builtin_path": "/z/builtin.zig"}}
    );
    defer fewer.deinit(testing.allocator);
    try testing.expect(!c.sameZigPaths(&fewer) and c.sameZig(&fewer));
    var empty = try parseText("{}");
    defer empty.deinit(testing.allocator);
    try testing.expect(empty.zig_lib_path == null and empty.zig_builtin_path == null and empty.zig_global_cache_path == null);

    // 本机 zig 安装的位置，不能由项目共享
    var project = try parseProject(testing.allocator,
        \\.{ .zig = .{ .lib_path = "/z/lib" }, .build = .{ .args = .{"-Da"} } }
    );
    defer project.deinit(testing.allocator);
    try testing.expectEqual(1, project.warnings.len);
    try testing.expectEqualStrings("`zig.lib_path` cannot be set in zig-analyzer.zon", project.warnings[0]);
    try testing.expect(!project.isSet("zig_lib_path") and project.isSet("build_args"));
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
        \\{"build": {"args": ["-Dclient"]}, "diagnostics": {"steps": ["check"]}, "log": {"level": "debug"}, "imports": {"sort": "name"}}
    );
    defer client.deinit(testing.allocator);
    var project = try parseProject(testing.allocator,
        \\// 注释
        \\.{
        \\    .build = .{ .args = .{"-Dtarget=wasm32-freestanding"}, .enable = false },
        \\    .diagnostics = .{ .compiler = false },
        \\    .log = .{ .level = .err },
        \\    .imports = .{ .derived = .separate },
        \\}
    );
    defer project.deinit(testing.allocator);
    try testing.expectEqual(2, project.warnings.len);
    try testing.expectEqualStrings("`build.enable` cannot be set in zig-analyzer.zon", project.warnings[0]);

    try client.overlayProject(testing.allocator, &project);
    try testing.expectEqualStrings("-Dtarget=wasm32-freestanding", client.build_args[0]);
    try testing.expect(!client.compiler_diagnostics and client.build_enable);
    // 项目中没有的项保留客户端的值
    try testing.expectEqualStrings("check", client.diagnostics_steps[0]);
    try testing.expectEqual(.debug, client.log_level);
    // import 的排列是团队共享的风格，可以写在项目配置中
    try testing.expect(client.imports_derived == .separate and client.imports_sort == .name);
}

test "project file: an error ignores the whole file and is reported with its location" {
    const cases = [_]struct { text: []const u8, prefix: []const u8 }{
        // 语法错误
        .{ .text = ".{\n    .build = .{ .args = ,\n}", .prefix = "2:" },
        // 类型错误、未知的项
        .{ .text = ".{\n    .naming = .{ .enable = true },\n    .build = .{ .args = true },\n}", .prefix = "3:25: " },
        .{ .text = ".{ .naming = .{ .rules = .{ .constants = false } } }", .prefix = "1:30: " },
        .{ .text = ".{ .colors = .{} }", .prefix = "1:5: " },
        .{ .text = "\"build\"", .prefix = "1:1: " },
    };
    for (cases) |case| {
        var c = try parseProject(testing.allocator, case.text);
        defer c.deinit(testing.allocator);
        try testing.expectEqual(1, c.warnings.len);
        try testing.expect(std.mem.startsWith(u8, c.warnings[0], case.prefix));
        try testing.expect(std.mem.endsWith(u8, c.warnings[0], "; the file is ignored"));
        try testing.expect(!c.isSet("naming_enable") and !c.isSet("build_args"));
    }

    var empty = try parseProject(testing.allocator, "// 只有注释\n.{}");
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(0, empty.warnings.len);
}

test "project file: the parsed config owns the memory of its warnings" {
    // 防止返回的配置带着加入警告之前的 arena 状态：分配器不能原地扩大时，警告所在的内存块在释放时泄漏
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .resize_fail_index = 0 });
    const gpa = failing.allocator();
    var project = try parseProject(gpa,
        \\.{ .build = .{ .enable = false }, .diagnostics = .{ .compiler = false }, .log = .{ .level = .err } }
    );
    defer project.deinit(gpa);
    try testing.expectEqual(2, project.warnings.len);
    try testing.expectEqualStrings("`build.enable` cannot be set in zig-analyzer.zon", project.warnings[0]);
}

test "naming settings: client and project file" {
    var empty = try parseText("{}");
    defer empty.deinit(testing.allocator);
    try testing.expect(!empty.naming_enable and empty.naming_rules.field and empty.naming_ignore.len == 0);

    var client = try parseText(
        \\{"naming": {"enable": true, "ignore": ["SDL_*"], "rules": {"field": false}}}
    );
    defer client.deinit(testing.allocator);
    try testing.expectEqual(0, client.warnings.len);
    try testing.expect(client.naming_enable and !client.naming_rules.field and client.naming_rules.value);
    try testing.expectEqualStrings("SDL_*", client.naming_ignore[0]);
    try testing.expect(!client.sameNaming(&empty));

    // 未知的规则：整项取默认值
    var unknown = try parseText(
        \\{"naming": {"rules": {"constants": false}}}
    );
    defer unknown.deinit(testing.allocator);
    try testing.expectEqualStrings("invalid value for `naming.rules`, using the default", unknown.warnings[0]);
    try testing.expect(unknown.naming_rules.value);

    // 项目中的命名约定覆盖客户端的
    var project = try parseProject(testing.allocator,
        \\.{ .naming = .{ .exclude = .{"src/c/*"}, .rules = .{ .value = false } } }
    );
    defer project.deinit(testing.allocator);
    try testing.expectEqual(0, project.warnings.len);
    try client.overlayProject(testing.allocator, &project);
    try testing.expect(client.naming_enable and client.naming_rules.field and !client.naming_rules.value);
    try testing.expectEqualStrings("src/c/*", client.naming_exclude[0]);
    try testing.expectEqualStrings("SDL_*", client.naming_ignore[0]);
}
