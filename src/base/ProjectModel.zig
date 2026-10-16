//! 项目模型：构建图中与语言分析相关的部分（step、模块、根文件、import 表）。
//! 由 `project/configuration.zig` 从 `std.Build.Configuration` 转换而来。

const std = @import("std");
const Allocator = std.mem.Allocator;

const ProjectModel = @This();

arena: std.heap.ArenaAllocator.State,
/// 构建根目录（绝对路径）
build_root: []const u8,
/// 标准库根文件 `<std_dir>/std.zig`
std_root: []const u8,
steps: []const Step,
/// 可变：生成文件的路径在构建中得知后，由 `setGeneratedPath` 填入对应模块的 `root_file`
modules: []Module,
default_step: u32,
/// 生成文件编号 → 产出它的 step（构建图中的 `GeneratedFileIndex`）
producers: []const ?u32 = &.{},
/// 用于诊断的 step：构建图转换时为默认值（项目定义了 `check` 就用它，否则用默认 step），
/// 用户配置了 `diagnostics.steps` 时由 `setDiagnosticsSteps` 替换
diagnostics_steps: []const u32 = &.{},

pub const Step = struct {
    name: []const u8,
    kind: Kind,
    /// 直接依赖的 step（下标）
    deps: []const u32,

    pub const Kind = union(enum) {
        top_level: struct { description: []const u8 },
        /// 根模块（`modules` 下标）
        compile: struct { root_module: u32 },
        other,
    };
};

pub const Module = struct {
    /// 根文件绝对路径；未设置，或为尚未得知路径的生成文件时为 null
    root_file: ?[]const u8,
    /// 根文件是构建时生成的文件
    generated_root: ?GeneratedPath = null,
    imports: []const Import,
    /// 生成该模块 `builtin.zig` 的编译器参数：子命令（`build-exe` 等）与影响 builtin 的模块参数
    builtin_args: []const []const u8 = &.{},
    /// 生成的 `builtin.zig` 的路径（由 Workspace 在加载构建图后填入）
    builtin_file: ?[]const u8 = null,

    /// 目标为本机（没有指定 `-target`，或指定的是 `native` 开头的三元组）
    pub fn isNativeTarget(m: *const Module) bool {
        for (m.builtin_args, 0..) |arg, i| {
            if (!std.mem.eql(u8, arg, "-target") or i + 1 >= m.builtin_args.len) continue;
            return std.mem.startsWith(u8, m.builtin_args[i + 1], "native");
        }
        return true;
    }
};

/// 相对于生成文件的路径：从生成文件向上 `up` 级目录，再拼上 `sub_path`
pub const GeneratedPath = struct {
    file: u32,
    up: u32 = 0,
    sub_path: []const u8 = "",
};

pub const Import = struct {
    name: []const u8,
    module: u32,
};

pub fn deinit(m: *ProjectModel, gpa: Allocator) void {
    var arena = m.arena.promote(gpa);
    arena.deinit();
    m.* = undefined;
}

pub fn topLevelStep(m: *const ProjectModel, name: []const u8) ?u32 {
    for (m.steps, 0..) |s, i| {
        if (s.kind == .top_level and std.mem.eql(u8, s.name, name)) return @intCast(i);
    }
    return null;
}

/// 默认的诊断 step：项目定义了 `check` 就用它，否则用默认 step（通常是 install）
pub fn defaultDiagnosticsStep(m: *const ProjectModel) u32 {
    return m.topLevelStep("check") orelse m.default_step;
}

/// 按名字设置诊断 step（顶层 step）；返回找不到的名字的个数。一个都找不到时保留默认值
pub fn setDiagnosticsSteps(m: *ProjectModel, gpa: Allocator, names: []const []const u8) Allocator.Error!usize {
    var arena = m.arena.promote(gpa);
    defer m.arena = arena.state;
    var steps: std.ArrayList(u32) = .empty;
    var missing: usize = 0;
    for (names) |name| {
        const s = m.topLevelStep(name) orelse {
            missing += 1;
            continue;
        };
        if (std.mem.indexOfScalar(u32, steps.items, s) == null) try steps.append(arena.allocator(), s);
    }
    if (steps.items.len != 0) m.diagnostics_steps = steps.items;
    return missing;
}

/// `roots` 及其传递依赖的 step 集合
pub fn dependencyClosure(m: *const ProjectModel, gpa: Allocator, roots: []const u32) Allocator.Error!std.DynamicBitSetUnmanaged {
    var seen: std.DynamicBitSetUnmanaged = try .initEmpty(gpa, m.steps.len);
    errdefer seen.deinit(gpa);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    try stack.appendSlice(gpa, roots);
    while (stack.pop()) |s| {
        if (seen.isSet(s)) continue;
        seen.set(s);
        try stack.appendSlice(gpa, m.steps[s].deps);
    }
    return seen;
}

/// 每次构建请求的 step：诊断 step（`diagnostics` 为 false 时不含），加上所有生成模块根文件的产出 step。
/// 后者让诊断 step 不依赖的模块（如只在 test step 中使用的）也能得知根文件路径。
pub fn buildSteps(m: *const ProjectModel, gpa: Allocator, diagnostics: bool) Allocator.Error![]u32 {
    var steps: std.ArrayList(u32) = .empty;
    errdefer steps.deinit(gpa);
    if (diagnostics) try steps.appendSlice(gpa, m.diagnostics_steps);
    for (m.modules) |mod| {
        const g = mod.generated_root orelse continue;
        const producer = (if (g.file < m.producers.len) m.producers[g.file] else null) orelse continue;
        if (std.mem.indexOfScalar(u32, steps.items, producer) == null) try steps.append(gpa, producer);
    }
    return steps.toOwnedSlice(gpa);
}

/// 记录生成文件 `file` 的绝对路径，更新以它为根的模块；有模块根文件变化时返回 true
/// 记录模块 `builtin.zig` 的路径
pub fn setBuiltinFile(m: *ProjectModel, gpa: Allocator, module: u32, path: []const u8) Allocator.Error!void {
    var arena = m.arena.promote(gpa);
    defer m.arena = arena.state;
    m.modules[module].builtin_file = try arena.allocator().dupe(u8, path);
}

pub fn setGeneratedPath(m: *ProjectModel, gpa: Allocator, file: u32, path: []const u8) Allocator.Error!bool {
    var arena = m.arena.promote(gpa);
    defer m.arena = arena.state;
    var changed = false;
    for (m.modules) |*mod| {
        const g = mod.generated_root orelse continue;
        if (g.file != file) continue;
        var dir: []const u8 = path;
        for (0..g.up) |_| dir = std.fs.path.dirname(dir) orelse dir;
        const resolved = try std.fs.path.join(arena.allocator(), &.{ dir, g.sub_path });
        if (mod.root_file) |old| if (std.mem.eql(u8, old, resolved)) continue;
        mod.root_file = resolved;
        changed = true;
    }
    return changed;
}

pub fn hasCompileSteps(m: *const ProjectModel) bool {
    for (m.steps) |s| if (s.kind == .compile) return true;
    return false;
}

/// 并入另一个构建图（项目导出的模块，见 `project/exports.zig`）的模块与 compile step。
/// 并入的 step 没有依赖、也不被任何 step 依赖，不会出现在构建请求中，只参与模块归属；
/// 生成文件的编号属于另一个构建图，以生成文件为根的模块没有根文件
pub fn appendExports(m: *ProjectModel, gpa: Allocator, exports: *const ProjectModel) Allocator.Error!void {
    var arena = m.arena.promote(gpa);
    defer m.arena = arena.state;
    const a = arena.allocator();
    const base: u32 = @intCast(m.modules.len);
    const modules = try a.alloc(Module, m.modules.len + exports.modules.len);
    @memcpy(modules[0..m.modules.len], m.modules);
    for (exports.modules, modules[m.modules.len..]) |src, *dst| {
        const imports = try a.alloc(Import, src.imports.len);
        for (src.imports, imports) |imp, *out| out.* = .{ .name = try a.dupe(u8, imp.name), .module = base + imp.module };
        const builtin_args = try a.alloc([]const u8, src.builtin_args.len);
        for (src.builtin_args, builtin_args) |arg, *out| out.* = try a.dupe(u8, arg);
        dst.* = .{
            .root_file = if (src.generated_root != null) null else if (src.root_file) |p| try a.dupe(u8, p) else null,
            .imports = imports,
            .builtin_args = builtin_args,
            .builtin_file = if (src.builtin_file) |p| try a.dupe(u8, p) else null,
        };
    }
    var steps: std.ArrayList(Step) = .empty;
    try steps.appendSlice(a, m.steps);
    for (exports.steps) |s| switch (s.kind) {
        .compile => |c| try steps.append(a, .{
            .name = try a.dupe(u8, s.name),
            .kind = .{ .compile = .{ .root_module = base + c.root_module } },
            .deps = &.{},
        }),
        else => {},
    };
    m.modules = modules;
    m.steps = steps.items;
}

/// `step` 传递依赖的所有 compile step（下标），按发现顺序
pub fn compileStepsOf(m: *const ProjectModel, gpa: Allocator, roots: []const u32) Allocator.Error![]u32 {
    var seen: std.DynamicBitSetUnmanaged = try .initEmpty(gpa, m.steps.len);
    defer seen.deinit(gpa);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    var result: std.ArrayList(u32) = .empty;
    errdefer result.deinit(gpa);
    try stack.appendSlice(gpa, roots);
    while (stack.pop()) |s| {
        if (seen.isSet(s)) continue;
        seen.set(s);
        if (m.steps[s].kind == .compile) try result.append(gpa, s);
        try stack.appendSlice(gpa, m.steps[s].deps);
    }
    return result.toOwnedSlice(gpa);
}

test "Module.isNativeTarget" {
    const native: Module = .{ .root_file = null, .imports = &.{}, .builtin_args = &.{ "build-exe", "-Odebug" } };
    const explicit_native: Module = .{ .root_file = null, .imports = &.{}, .builtin_args = &.{ "build-exe", "-target", "native-linux" } };
    const wasm: Module = .{ .root_file = null, .imports = &.{}, .builtin_args = &.{ "build-lib", "-target", "wasm32-freestanding", "-mcpu", "generic" } };
    try std.testing.expect(native.isNativeTarget());
    try std.testing.expect(explicit_native.isNativeTarget());
    try std.testing.expect(!wasm.isNativeTarget());
}

test appendExports {
    const gpa = std.testing.allocator;
    var main_arena: std.heap.ArenaAllocator = .init(gpa);
    const ma = main_arena.allocator();
    const main_modules = try ma.dupe(Module, &.{.{ .root_file = "/p/a.zig", .imports = &.{} }});
    var m: ProjectModel = .{
        .arena = main_arena.state,
        .build_root = "/p",
        .std_root = "/std/std.zig",
        .steps = try ma.dupe(Step, &.{.{ .name = "install", .kind = .{ .top_level = .{ .description = "" } }, .deps = &.{} }}),
        .modules = main_modules,
        .default_step = 0,
    };
    defer m.deinit(gpa);

    var exports_modules = [_]Module{
        .{ .root_file = "/p/lib.zig", .imports = &.{.{ .name = "dep", .module = 1 }}, .builtin_args = &.{"build-obj"} },
        .{ .root_file = "/p/.zig-cache/o/x/options.zig", .generated_root = .{ .file = 3 }, .imports = &.{} },
    };
    const exports: ProjectModel = .{
        .arena = undefined,
        .build_root = "/p/.zig-cache/zig-analyzer/exports",
        .std_root = "/std/std.zig",
        .steps = &.{
            .{ .name = "exports", .kind = .{ .top_level = .{ .description = "" } }, .deps = &.{1} },
            .{ .name = "compile obj lib", .kind = .{ .compile = .{ .root_module = 0 } }, .deps = &.{} },
        },
        .modules = &exports_modules,
        .default_step = 0,
    };
    try m.appendExports(gpa, &exports);

    try std.testing.expect(m.hasCompileSteps());
    try std.testing.expectEqual(2, m.steps.len);
    try std.testing.expectEqual(1, m.steps[1].kind.compile.root_module);
    try std.testing.expectEqual(0, m.steps[1].deps.len);
    try std.testing.expectEqual(3, m.modules.len);
    try std.testing.expectEqualStrings("/p/a.zig", m.modules[0].root_file.?);
    try std.testing.expectEqualStrings("/p/lib.zig", m.modules[1].root_file.?);
    try std.testing.expectEqual(2, m.modules[1].imports[0].module);
    try std.testing.expectEqualStrings("build-obj", m.modules[1].builtin_args[0]);
    // 生成文件的编号属于探针的构建图，不能当作本项目的生成文件
    try std.testing.expectEqual(null, m.modules[2].root_file);
    try std.testing.expectEqual(null, m.modules[2].generated_root);
}
