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
/// 用户配置的诊断 step（`diagnostics.step`）；null 时按默认规则选择
preferred_step: ?u32 = null,

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

/// 用于诊断的 step：用户配置的 step；未配置时，项目定义了 `check` 就用它，否则用默认 step（通常是 install）
pub fn diagnosticsStep(m: *const ProjectModel) u32 {
    return m.preferred_step orelse m.topLevelStep("check") orelse m.default_step;
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

/// 每次构建请求的 step：诊断 step，加上所有生成模块根文件的产出 step。
/// 后者让诊断 step 不依赖的模块（如只在 test step 中使用的）也能得知根文件路径。
pub fn buildSteps(m: *const ProjectModel, gpa: Allocator) Allocator.Error![]u32 {
    var steps: std.ArrayList(u32) = .empty;
    errdefer steps.deinit(gpa);
    try steps.append(gpa, m.diagnosticsStep());
    for (m.modules) |mod| {
        const g = mod.generated_root orelse continue;
        const producer = (if (g.file < m.producers.len) m.producers[g.file] else null) orelse continue;
        if (std.mem.indexOfScalar(u32, steps.items, producer) == null) try steps.append(gpa, producer);
    }
    return steps.toOwnedSlice(gpa);
}

/// 记录生成文件 `file` 的绝对路径，更新以它为根的模块；有模块根文件变化时返回 true
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

/// `step` 传递依赖的所有 compile step（下标），按发现顺序
pub fn compileStepsOf(m: *const ProjectModel, gpa: Allocator, step: u32) Allocator.Error![]u32 {
    var seen: std.DynamicBitSetUnmanaged = try .initEmpty(gpa, m.steps.len);
    defer seen.deinit(gpa);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    var result: std.ArrayList(u32) = .empty;
    errdefer result.deinit(gpa);
    try stack.append(gpa, step);
    while (stack.pop()) |s| {
        if (seen.isSet(s)) continue;
        seen.set(s);
        if (m.steps[s].kind == .compile) try result.append(gpa, s);
        try stack.appendSlice(gpa, m.steps[s].deps);
    }
    return result.toOwnedSlice(gpa);
}
