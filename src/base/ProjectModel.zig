//! Project model: the parts of the build graph relevant to language analysis (steps, modules,
//! root files, import tables).
//! Converted from `std.Build.Configuration` by `project/configuration.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ProjectModel = @This();

arena: std.heap.ArenaAllocator.State,
/// Build root (absolute path)
build_root: []const u8,
/// Local cache directory used by the maker (absolute path): most generated files are in it. Set
/// by `configuration.convert`; the empty default is only for hand-written models in tests
local_cache_root: []const u8 = "",
/// Root directories of the dependency packages fetched by hash that contain modules (absolute
/// paths, `<package dir>/<hash>`; the package directory defaults to `<build root>/zig-pkg`).
/// They contain dependency code rather than user code; packages given by `--fork` and path
/// dependencies are not included
package_roots: []const []const u8 = &.{},
/// Standard library root file `<std_dir>/std.zig`
std_root: []const u8,
steps: []const Step,
/// Mutable: once the path of a generated file becomes known during the build,
/// `setGeneratedPath` fills it into the `root_file` of the corresponding module
modules: []Module,
default_step: u32,
/// Generated file index → the step that produces it (`GeneratedFileIndex` in the build graph)
producers: []const ?u32 = &.{},
/// Steps used for diagnostics: set to the default when the build graph is converted (`check` if
/// the project defines it, otherwise the default step), and replaced by `setDiagnosticsSteps`
/// when the user configures `diagnostics.steps`
diagnostics_steps: []const u32 = &.{},

pub const Step = struct {
    name: []const u8,
    kind: Kind,
    /// Steps depended on directly (indices)
    deps: []const u32,

    pub const Kind = union(enum) {
        top_level: struct { description: []const u8 },
        /// Root module (index into `modules`)
        compile: struct { root_module: u32 },
        other,
    };
};

pub const Module = struct {
    /// Absolute path of the root file; null when unset or when it is a generated file whose path
    /// is not known yet
    root_file: ?[]const u8,
    /// The root file is a file generated during the build
    generated_root: ?GeneratedPath = null,
    imports: []const Import,
    /// Compiler arguments for generating this module's `builtin.zig`: the subcommand
    /// (`build-exe`, etc.) and the module arguments that affect builtin
    builtin_args: []const []const u8 = &.{},
    /// Path of the generated `builtin.zig` (filled in by Workspace after loading the build graph)
    builtin_file: ?[]const u8 = null,

    /// The target is native (no `-target` given, or a triple starting with `native`)
    pub fn isNativeTarget(m: *const Module) bool {
        for (m.builtin_args, 0..) |arg, i| {
            if (!std.mem.eql(u8, arg, "-target") or i + 1 >= m.builtin_args.len) continue;
            return std.mem.startsWith(u8, m.builtin_args[i + 1], "native");
        }
        return true;
    }
};

/// A path relative to a generated file: `up` directory levels up from the generated file, then
/// joined with `sub_path`
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

/// Default diagnostics step: `check` if the project defines it, otherwise the default step
/// (usually install)
pub fn defaultDiagnosticsStep(m: *const ProjectModel) u32 {
    return m.topLevelStep("check") orelse m.default_step;
}

/// Sets the diagnostics steps (top-level steps) by name; returns the number of names not found.
/// Keeps the default when none of them is found
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

/// The set of `roots` and the steps they transitively depend on
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

/// Steps requested in each build: the diagnostics steps (omitted when `diagnostics` is false),
/// plus the steps producing every generated module root file.
/// The latter let modules the diagnostics steps do not depend on (such as ones used only in a
/// test step) learn their root file paths too.
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

/// Records the absolute path of generated file `file` and updates the modules rooted at it;
/// returns true when the root file of some module changed
/// Records the path of a module's `builtin.zig`
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

/// Merges in the modules and compile steps of another build graph (the modules exported by the
/// project; see `project/exports.zig`).
/// The merged steps have no dependencies and no step depends on them, so they never appear in
/// build requests and only take part in module membership; generated file indices belong to the
/// other build graph, so modules rooted at generated files have no root file
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
    var package_roots: std.ArrayList([]const u8) = .empty;
    try package_roots.appendSlice(a, m.package_roots);
    for (exports.package_roots) |p| try package_roots.append(a, try a.dupe(u8, p));
    m.modules = modules;
    m.steps = steps.items;
    m.package_roots = package_roots.items;
}

/// All compile steps (indices) that `step` transitively depends on, in discovery order
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
    // The generated file index belongs to the probe's build graph and must not be taken as a
    // generated file of this project
    try std.testing.expectEqual(null, m.modules[2].root_file);
    try std.testing.expectEqual(null, m.modules[2].generated_root);
}
