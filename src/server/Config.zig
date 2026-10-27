//! User configuration from the client: the settings in the `initializationOptions` of `initialize`
//! and those pushed with `workspace/didChangeConfiguration` (or pulled with
//! `workspace/configuration`).
//!
//! The JSON structure is as follows; an extra outer `"zig-analyzer"` wrapper is also accepted:
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
//! Settings are parsed one by one: unknown settings and settings whose value has the wrong type
//! only produce warnings (`warnings`); a setting whose value has the wrong type takes its default
//! value, and the other settings still apply.
//!
//! `zig-analyzer.zon` in the project root directory can set the project-related settings
//! (`project_settings`) to be shared by the team; the settings that appear in it take precedence
//! over the client's configuration (`overlayProject`). It has the same structure, written in ZON
//! (comments are allowed), with enum values written as enum literals:
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
/// The zig executable; when null, it is looked up in PATH
zig_path: ?[]const u8 = null,
/// The zig lib directory (containing `std/std.zig`): the standard library is resolved from it, and
/// zig is run with it too; when null, the one reported by `zig env` is used
zig_lib_path: ?[]const u8 = null,
/// `@import("builtin")` for files outside any project (single-file mode and so on); when null, it
/// is generated with the settings of `zig test`. Modules in projects always use the one generated
/// from the build arguments
zig_builtin_path: ?[]const u8 = null,
/// The zig global cache directory (dependency packages, generated builtin.zig files and so on),
/// also used when running zig; when null, the one reported by `zig env` is used
zig_global_cache_path: ?[]const u8 = null,
/// Whether to obtain the project model through the build system protocol; when disabled, all
/// files are handled in single-file mode
build_enable: bool = true,
/// Extra arguments passed to `zig build` (such as `-Dtarget=...`)
build_args: []const []const u8 = &.{},
/// Step used for diagnostics (`diagnostics.step`, merged with `diagnostics.steps`)
diagnostics_step: ?[]const u8 = null,
/// Steps used for diagnostics; when empty, `check` is used, or the default step if there is none
diagnostics_steps: []const []const u8 = &.{},
/// Whether to run the compiler to get diagnostics; when disabled, there are only live
/// diagnostics (syntax and AstGen)
compiler_diagnostics: bool = true,
/// After an edit, live diagnostics are computed only once this many milliseconds pass without a
/// new edit; 0 means no waiting
debounce_ms: u32 = 50,
/// Whether to show code that is not compiled under the current build configuration (branches
/// known at comptime not to execute) as inactive code
inactive_code: bool = false,
/// inlay hints: inferred types
inlay_types: bool = true,
/// inlay hints: field types after the field names in initializer expressions
inlay_field_types: bool = true,
/// inlay hints: also show type hints when the type contains an anonymous container displayed by
/// its contents (`struct { a: u32 }`)
inlay_anonymous_containers: bool = false,
/// inlay hints: the parameter name for each argument
inlay_parameters: bool = true,
/// inlay hints: parameter names in builtin function calls (likewise not shown when
/// `inlay_parameters` is disabled)
inlay_builtin_parameters: bool = true,
/// Calls with only one argument (including builtin calls) show no parameter names
inlay_exclude_single_argument: bool = true,
/// The parameter name is not shown when the argument, with `&`, `.*`, `.?` and `try` removed, has
/// the same name as the parameter (or is a field access ending in the parameter name)
hide_redundant_param_names: bool = true,
/// inlay hints: maximum number of characters in a type hint; beyond it, the remaining items of a
/// list (fields, arguments, ...) are shown as `…`; 0 means no limit
inlay_max_length: u32 = 25,
/// Which tokens semantic highlighting emits
semantic_tokens_mode: SemanticTokensMode = .full,
/// Semantic highlighting: declarations of and references to container-level `var`s carry the
/// `global` modifier
semantic_tokens_global_var: bool = false,
/// Placement of derived declarations (`const Allocator = std.mem.Allocator;`) in the import
/// block: both organize imports and auto-import follow it
imports_derived: ImportOptions.Derived = .with_import,
/// Sorting within groups of the import block: by the imported path or the declaration name
imports_sort: ImportOptions.Sort = .path,
/// Offer, in plain name completion, auto-imports of reachable declarations and modules, as well as
/// members of visible namespaces matched by their full path
completion_auto_import: bool = true,
/// Maximum number of auto-import candidates offered by one completion (the best-ranked ones are
/// kept; the client gets the rest by requesting again as the user types); 0 means no limit
completion_max_auto_imports: u32 = 128,
/// Inside a generic function body without concrete types, infer from the instances at call sites
/// (hover, completion, inlay hints, ...)
callsite_seeding: bool = true,
/// When the InternPool exceeds this many MB, type information is reclaimed as a whole generation
/// (then inferred again on demand); 0 means never reclaim
max_intern_pool_mb: u32 = 64,
/// Number of syntax trees retained (`ParseFile` and `FileAstIdMap`; evicted ones are reparsed on
/// demand); 0 means no limit
cache_capacity: u32 = syntax_queries.parse_lru,
/// Per-query cache capacities, taking precedence over `cache_capacity`
cache_queries: CacheQueries = .{},
/// Whether workspace symbol also lists symbols in dependencies (fetched dependency packages,
/// generated files, open standard library files)
workspace_symbol_dependencies: bool = false,
/// Maximum number of symbols workspace symbol returns (the best matches are kept); 0 means no
/// limit. Clients that query again as the user types do not need everything at once; clients
/// that query only once and filter on the client side need to raise it or set it to 0.
workspace_symbol_limit: u32 = 256,
/// Naming check (the Names section of the Zig style guide): whether to report names in open files
/// that do not follow the naming conventions, and offer a rename fix
naming_enable: bool = false,
/// Names the naming check skips; `*` matches any sequence of characters (`SDL_*`)
naming_ignore: []const []const u8 = &.{},
/// Files the naming check skips: `/`-separated paths relative to the workspace root directory
/// (relative to the project root directory in `zig-analyzer.zon`); `*` matches any sequence of
/// characters (including `/`)
naming_exclude: []const []const u8 = &.{},
/// Whether each rule of the naming check is enabled
naming_rules: NamingRules = .{},
/// Who detects external changes on disk (see `Watcher`)
files_watcher: Watcher = .auto,
/// Log level (err / warn / info / debug)
log_level: std.log.Level = .info,
/// Log messages are also appended to this file; null means stderr only
log_file: ?[]const u8 = null,
/// When a request takes longer than this many milliseconds, log the time spent in queries (slow
/// request log); 0 disables it
slow_request_ms: u32 = 100,
/// Problems found while parsing (unknown settings, settings whose value has the wrong type), used
/// to notify the user
warnings: []const []const u8 = &.{},
/// Settings present in the configuration (and of the right type), indexed like `settings`
present: std.StaticBitSet(settings.len) = .empty,

/// Source of external changes. When the client supports it, file watchers are always registered
/// with it (`workspace/didChangeWatchedFiles`).
pub const Watcher = enum {
    /// Watched by the server when the client does not support dynamic file watcher registration
    auto,
    /// Only the client's notifications
    client,
    /// Always watched by the server (the client's notifications are still handled)
    server,
};

/// Tokens emitted by semantic highlighting
pub const SemanticTokensMode = enum {
    /// All tokens
    full,
    /// Only tokens whose classification requires name resolution and type inference; keywords,
    /// comments, literals, operators, labels and builtin names are left to the editor's syntax
    /// highlighting
    partial,
};

/// Cache capacity of one query: the number of values retained and the number of MB; null means
/// the default, 0 means no limit. When exceeded, the least recently used values are evicted and
/// recomputed on demand later, with the same results.
pub const CacheLimit = struct {
    count: ?u32 = null,
    mb: ?u32 = null,
};

/// Queries whose cache capacity can be set; the field names are the query names
pub const CacheQueries = struct {
    ParseFile: CacheLimit = .{},
    FileAstIdMap: CacheLimit = .{},
    FileItemTree: CacheLimit = .{},
    ItemBody: CacheLimit = .{},
    Infer: CacheLimit = .{},
    Exports: CacheLimit = .{},
};

/// Rules of the naming check, matching the diagnostic codes `naming.<rule>` one to one
pub const NamingRules = struct {
    /// Types and type aliases: TitleCase
    type: bool = true,
    /// Callables that return `type`: TitleCase
    type_function: bool = true,
    /// Other callables (functions, function aliases, function pointers): camelCase
    function: bool = true,
    /// Namespaces (files without top-level fields): snake_case
    namespace: bool = true,
    /// Other values: snake_case
    value: bool = true,
    /// Fields and enum members (the style depends on the field's type)
    field: bool = true,
};

/// File name of the project configuration file (in the project root directory)
pub const project_file = "zig-analyzer.zon";

/// A setting: `section.key` and the corresponding field
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

/// Settings that can be set in the project configuration file
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

/// Parses the configuration. Returns `error.InvalidConfig` only when the root is not an object;
/// other problems are recorded in `warnings`.
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

/// Parses the contents of the project configuration file (ZON). Settings that cannot be set in a
/// project are recorded in `warnings` and ignored; a syntax error, a type error or an unknown
/// setting causes the whole file to be ignored, and the first error (with its location) is
/// recorded in `warnings`.
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

/// Structure of the project configuration file: the sections and settings are the same as in
/// `settings`, and every setting is optional (null when not written).
/// The whole file is parsed at once: `std.zon.parse.fromZoir` does not use the `node` option and
/// always starts from the root, so settings cannot be parsed one by one.
const ProjectFile = blk: {
    // Each section goes through all the settings once
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
            // Settings that are optional themselves (`zig.path`, ...) are not wrapped in another
            // optional: ZON does not support nested optional types, and writing null is the same
            // as omitting the setting
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

/// Body of `parseProject`: the settings are written into `c` and problems are recorded in
/// `warnings`, all allocated in `a`
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

/// Overrides with the settings that appear in the project configuration (`project` comes from
/// `parseProject`)
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

/// Whether the setting for field `field` is present in the configuration (and of the right type)
pub fn isSet(c: *const Config, comptime field: []const u8) bool {
    inline for (settings, 0..) |s, si| if (comptime std.mem.eql(u8, s.field, field)) return c.present.isSet(si);
    @compileError("no setting for field " ++ field);
}

/// Deep copy (without `warnings`)
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

/// Steps used for diagnostics: `diagnostics.steps` merged with `diagnostics.step`; when empty,
/// the project decides (`check` or the default step)
pub fn diagnosticsSteps(c: *const Config, a: Allocator) Allocator.Error![]const []const u8 {
    if (c.diagnostics_step == null) return c.diagnostics_steps;
    for (c.diagnostics_steps) |s| if (std.mem.eql(u8, s, c.diagnostics_step.?)) return c.diagnostics_steps;
    const out = try a.alloc([]const u8, c.diagnostics_steps.len + 1);
    out[0] = c.diagnostics_step.?;
    @memcpy(out[1..], c.diagnostics_steps);
    return out;
}

/// Layout rules of the import block (organize imports, auto-import)
pub fn importOptions(c: *const Config) ImportOptions {
    return .{ .derived = c.imports_derived, .sort = c.imports_sort };
}

/// Whether the settings that affect the build system protocol process are the same (when they
/// differ, the project needs to be restarted)
pub fn sameBuild(a: *const Config, b: *const Config) bool {
    if (a.build_enable != b.build_enable or a.compiler_diagnostics != b.compiler_diagnostics) return false;
    if (!eqlOptional(a.diagnostics_step, b.diagnostics_step)) return false;
    return eqlList(a.build_args, b.build_args) and eqlList(a.diagnostics_steps, b.diagnostics_steps);
}

pub fn sameZig(a: *const Config, b: *const Config) bool {
    return eqlOptional(a.zig_path, b.zig_path);
}

/// Whether the paths overriding the zig environment (lib directory, default builtin, global cache
/// directory) are the same (when they differ, the standard library and builtin are reloaded)
pub fn sameZigPaths(a: *const Config, b: *const Config) bool {
    return eqlOptional(a.zig_lib_path, b.zig_lib_path) and eqlOptional(a.zig_builtin_path, b.zig_builtin_path) and
        eqlOptional(a.zig_global_cache_path, b.zig_global_cache_path);
}

/// Whether the naming check settings are the same (when they differ, open files are republished)
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
    // A query whose capacity cannot be set: the whole setting uses the default, with a warning
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

    // Locations of the local zig installation, which cannot be shared through the project
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
    // A setting whose value has the wrong type takes its default value; the other settings in the
    // same section still apply
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
    // Settings absent from the project keep the client's values
    try testing.expectEqualStrings("check", client.diagnostics_steps[0]);
    try testing.expectEqual(.debug, client.log_level);
    // The import layout is a style shared by the team and can be set in the project configuration
    try testing.expect(client.imports_derived == .separate and client.imports_sort == .name);
}

test "project file: an error ignores the whole file and is reported with its location" {
    const cases = [_]struct { text: []const u8, prefix: []const u8 }{
        // Syntax error
        .{ .text = ".{\n    .build = .{ .args = ,\n}", .prefix = "2:" },
        // Type errors, unknown settings
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
    // Guards against the returned configuration carrying the arena state from before the
    // warnings were added: when the allocator cannot grow in place, the memory block holding the
    // warnings leaks when the configuration is freed
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

    // Unknown rule: the whole setting takes its default value
    var unknown = try parseText(
        \\{"naming": {"rules": {"constants": false}}}
    );
    defer unknown.deinit(testing.allocator);
    try testing.expectEqualStrings("invalid value for `naming.rules`, using the default", unknown.warnings[0]);
    try testing.expect(unknown.naming_rules.value);

    // The naming conventions in the project override the client's
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
