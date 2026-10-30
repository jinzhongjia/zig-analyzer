//! Compile set: all files the compiler runs AstGen on, i.e. the files reachable from the root
//! module of each compile step and from the standard library root file along `@import`s
//! (including imports in functions that are not analyzed). It determines the modules files belong
//! to and, together with the module directories, which files get live diagnostics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ProjectModel = @import("../base/ProjectModel.zig");
const Vfs = @import("../base/Vfs.zig");
const FileId = Vfs.FileId;

pub const Result = struct {
    /// File → the module it was in when first reached
    files: std.AutoArrayHashMapUnmanaged(FileId, Membership) = .empty,
    /// (file, module) pairs for files reached again later in other modules, in the order reached:
    /// in different compile steps the same file can belong to modules with different import tables
    /// (e.g. exe and test each create their own module but share the root file)
    others: std.AutoArrayHashMapUnmanaged(FileModule, void) = .empty,
    /// Module → the compile step that first reached it (the standard library is not included)
    modules: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty,
    /// Reachable files whose contents are not loaded yet; the caller should recompute after
    /// loading them
    missing: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        r.files.deinit(gpa);
        r.others.deinit(gpa);
        r.modules.deinit(gpa);
        r.missing.deinit(gpa);
    }

    pub fn contains(r: *const Result, file: FileId) bool {
        return r.files.contains(file);
    }
};

/// Module number used for the standard library during traversal
pub const std_module = std.math.maxInt(u32);

pub const FileModule = struct {
    file: FileId,
    /// Index into `ProjectModel.modules`; `std_module` for the standard library
    module: u32,
};

pub const Membership = struct {
    /// Index into `ProjectModel.modules`; `std_module` for the standard library
    module: u32,
    /// The compile step that reached the file first (index into `ProjectModel.steps`)
    step: u32,
};

/// `resolver` must provide:
/// - `intern(path: []const u8) !FileId`: absolute path → FileId
/// - `path(file: FileId) []const u8`: FileId → absolute path
/// - `imports(file: FileId) !?[]const []const u8`: the import strings of the file; returns null
///   when its contents are not loaded yet
pub fn compute(gpa: Allocator, model: *const ProjectModel, compile_steps: []const u32, resolver: anytype) !Result {
    var result: Result = .{};
    errdefer result.deinit(gpa);

    const Node = FileModule;
    var visited: std.AutoHashMapUnmanaged(Node, void) = .empty;
    defer visited.deinit(gpa);
    var stack: std.ArrayList(Node) = .empty;
    defer stack.deinit(gpa);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();

    for (compile_steps) |step| {
        const compile = model.steps[step].kind.compile;
        const root_module = compile.root_module;
        const root_file = model.modules[root_module].root_file orelse continue;
        // `@import("root")` depends on the compile step, so compile steps are traversed separately
        visited.clearRetainingCapacity();
        try stack.append(gpa, .{ .file = try resolver.intern(root_file), .module = root_module });
        // The target of `@import("root")`. The test runner of a test compilation is a module of
        // its own that imports only std, builtin and root, as the standard library does
        const root: ?Node = switch (compile.root) {
            .module => .{ .file = try resolver.intern(root_file), .module = root_module },
            .test_runner => |path| .{ .file = try resolver.intern(path), .module = std_module },
            .unknown => null,
        };
        if (compile.root == .test_runner) try stack.append(gpa, root.?);
        // The standard library (of the compilation's lib directory) is always part of the
        // compilation (the entry point start.zig is in it), even if user code does not import std
        const std_node: Node = .{ .file = try resolver.intern(model.stdRootOf(step)), .module = std_module };
        try stack.append(gpa, std_node);

        while (stack.pop()) |node| {
            if ((try visited.getOrPut(gpa, node)).found_existing) continue;
            if (node.module != std_module) _ = try result.modules.getOrPutValue(gpa, node.module, step);
            const gop = try result.files.getOrPut(gpa, node.file);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .module = node.module, .step = step };
            } else if (gop.value_ptr.module != node.module) {
                try result.others.put(gpa, node, {});
            }
            const imports = try resolver.imports(node.file) orelse {
                try result.missing.put(gpa, node.file, {});
                continue;
            };
            _ = scratch.reset(.retain_capacity);
            const a = scratch.allocator();
            const module_root = if (node.module == std_module) model.std_root else model.modules[node.module].root_file.?;
            const module_dir = std.fs.path.dirname(resolver.path(try resolver.intern(module_root))) orelse continue;
            for (imports) |name| {
                const target: Node = if (std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".zon")) blk: {
                    const file = try relativeImport(a, resolver, node.file, name, module_dir) orelse continue;
                    break :blk .{ .file = file, .module = node.module };
                } else if (std.mem.eql(u8, name, "std"))
                    std_node
                else if (std.mem.eql(u8, name, "root"))
                    root orelse continue
                else if (std.mem.eql(u8, name, "builtin"))
                    continue // generated by the compiler, not on disk
                else blk: {
                    if (node.module == std_module) continue;
                    const m = for (model.modules[node.module].imports) |imp| {
                        if (std.mem.eql(u8, imp.name, name)) break imp.module;
                    } else continue;
                    const file = model.modules[m].root_file orelse continue;
                    break :blk .{ .file = try resolver.intern(file), .module = m };
                };
                try stack.append(gpa, target);
            }
        }
    }
    return result;
}

/// Build scripts: build.zig and build.zig.zon in the build root, plus the files reachable from
/// build.zig along relative-path `@import`s. The compiler compiles build.zig into the build
/// program, so errors in it are reported as well; modules imported by name (std, dependency
/// packages) are not included. Only used to decide live diagnostics and whether to reconfigure
/// after a save; not used for module membership.
pub const Scripts = struct {
    files: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty,
    /// Reachable files whose contents are not loaded yet; the caller should recompute after
    /// loading them
    missing: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty,

    pub fn deinit(s: *Scripts, gpa: Allocator) void {
        s.files.deinit(gpa);
        s.missing.deinit(gpa);
    }
};

/// `resolver` has the same requirements as in `compute`
pub fn buildScripts(gpa: Allocator, build_root: []const u8, resolver: anytype) !Scripts {
    var result: Scripts = .{};
    errdefer result.deinit(gpa);
    var stack: std.ArrayList(FileId) = .empty;
    defer stack.deinit(gpa);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    for ([_][]const u8{ "build.zig.zon", "build.zig" }) |name| {
        try stack.append(gpa, try resolver.intern(try std.fs.path.join(scratch.allocator(), &.{ build_root, name })));
    }
    // build.zig is the root file of its module
    const module_dir = std.fs.path.dirname(resolver.path(stack.items[1])) orelse return result;
    while (stack.pop()) |file| {
        if ((try result.files.getOrPut(gpa, file)).found_existing) continue;
        const imports = try resolver.imports(file) orelse {
            try result.missing.put(gpa, file, {});
            continue;
        };
        for (imports) |name| {
            if (!std.mem.endsWith(u8, name, ".zig") and !std.mem.endsWith(u8, name, ".zon")) continue;
            try stack.append(gpa, try relativeImport(scratch.allocator(), resolver, file, name, module_dir) orelse continue);
        }
    }
    return result;
}

/// Target of the relative-path `@import(name)` in file `file`, whose module's root file is in
/// `module_dir`. Null when the path leaves `module_dir`: the compiler reports `import of file
/// outside module path` and compiles nothing from it. When the resolved path is not absolute (a
/// path relative to another drive on Windows, such as `D:a.zig`), it is not under `module_dir`
/// either, so it is never interned.
fn relativeImport(a: Allocator, resolver: anytype, file: FileId, name: []const u8, module_dir: []const u8) !?FileId {
    const dir = std.fs.path.dirname(resolver.path(file)) orelse return null;
    const target = try Vfs.resolve(.native, a, dir, name) orelse return null;
    if (!Vfs.isUnderStyle(.native, .native, target, module_dir)) return null;
    return try resolver.intern(target);
}

const testing = std.testing;
const native = @import("../util/test_path.zig").native;

/// For tests: an in-memory file system
const FakeFs = struct {
    paths: std.ArrayList([]const u8) = .empty,
    /// Path → import list; a path not in the table counts as not loaded
    files: std.StringHashMapUnmanaged([]const []const u8) = .empty,

    fn intern(fs: *FakeFs, file_path: []const u8) !FileId {
        // Same contract as `Vfs.intern`: only absolute paths are accepted
        if (!std.fs.path.isAbsolute(file_path)) return error.NotAbsolute;
        for (fs.paths.items, 0..) |p, i| if (std.mem.eql(u8, p, file_path)) return @fromBackingInt(@as(u32, @intCast(i)));
        try fs.paths.append(testing.allocator, try testing.allocator.dupe(u8, file_path));
        return @fromBackingInt(@as(u32, @intCast(fs.paths.items.len - 1)));
    }
    fn path(fs: *FakeFs, file: FileId) []const u8 {
        return fs.paths.items[@backingInt(file)];
    }
    fn imports(fs: *FakeFs, file: FileId) !?[]const []const u8 {
        return fs.files.get(fs.path(file));
    }
    fn deinit(fs: *FakeFs) void {
        for (fs.paths.items) |p| testing.allocator.free(p);
        fs.paths.deinit(testing.allocator);
        fs.files.deinit(testing.allocator);
    }
};

test compute {
    const gpa = testing.allocator;
    // main (module 0) imports "lib" (module 1), "std" and a relative file; std internally
    // imports "root"
    var modules = [_]ProjectModel.Module{
        .{ .root_file = native("/p/src/main.zig"), .imports = &.{.{ .name = "lib", .module = 1 }} },
        .{ .root_file = native("/p/lib/lib.zig"), .imports = &.{} },
    };
    const steps = [_]ProjectModel.Step{
        .{ .name = "check", .kind = .{ .top_level = .{ .description = "" } }, .deps = &.{1} },
        .{ .name = "compile", .kind = .{ .compile = .{ .root_module = 0 } }, .deps = &.{} },
    };
    const model: ProjectModel = .{ .arena = .{}, .build_root = native("/p"), .std_root = native("/zig/std/std.zig"), .steps = &steps, .modules = &modules, .default_step = 0 };

    var fs: FakeFs = .{};
    defer fs.deinit();
    try fs.files.put(gpa, native("/p/src/main.zig"), &.{ "lib", "std", "util.zig", "builtin" });
    try fs.files.put(gpa, native("/p/src/util.zig"), &.{"data/../data.zon"});
    try fs.files.put(gpa, native("/p/src/data.zon"), &.{});
    try fs.files.put(gpa, native("/p/lib/lib.zig"), &.{ "std", "nested/deep.zig", "unknown_module" });
    // std.zig is not loaded yet

    var r = try compute(gpa, &model, &.{1}, &fs);
    defer r.deinit(gpa);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    for (r.files.keys()) |f| try names.append(gpa, fs.path(f));
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    try testing.expectEqualStrings(native("/p/lib/lib.zig"), names.items[0]);
    try testing.expectEqualStrings(native("/p/lib/nested/deep.zig"), names.items[1]);
    try testing.expectEqualStrings(native("/p/src/data.zon"), names.items[2]);
    try testing.expectEqualStrings(native("/p/src/main.zig"), names.items[3]);
    try testing.expectEqualStrings(native("/p/src/util.zig"), names.items[4]);
    try testing.expectEqualStrings(native("/zig/std/std.zig"), names.items[5]);
    try testing.expectEqual(6, names.items.len);
    // Files not loaded: std.zig and deep.zig
    try testing.expectEqual(2, r.missing.count());
    // Module membership: relative imports stay in the original module, imports by name enter the
    // target module
    const member = struct {
        fn of(res: *const Result, f: *FakeFs, path: []const u8) Membership {
            for (f.paths.items, 0..) |p, i| if (std.mem.eql(u8, p, path)) return res.files.get(@fromBackingInt(@as(u32, @intCast(i)))).?;
            unreachable;
        }
    }.of;
    try testing.expectEqual(0, member(&r, &fs, native("/p/src/util.zig")).module);
    try testing.expectEqual(1, member(&r, &fs, native("/p/lib/nested/deep.zig")).module);
    try testing.expectEqual(std_module, member(&r, &fs, native("/zig/std/std.zig")).module);
    try testing.expectEqual(1, member(&r, &fs, native("/p/lib/lib.zig")).step);
    // The first compile step reaching each module
    try testing.expectEqual(1, r.modules.get(0).?);
    try testing.expectEqual(1, r.modules.get(1).?);
    try testing.expectEqual(2, r.modules.count());
}

test buildScripts {
    const gpa = testing.allocator;
    var fs: FakeFs = .{};
    defer fs.deinit();
    // build.zig imports std, a dependency package and a relative file; the relative file in turn
    // imports the zon file and a file in the parent directory
    try fs.files.put(gpa, native("/p/build.zig"), &.{ "std", "dep", "build/helper.zig" });
    try fs.files.put(gpa, native("/p/build.zig.zon"), &.{});
    try fs.files.put(gpa, native("/p/build/helper.zig"), &.{ "../build.zig.zon", "../shared.zig" });
    // shared.zig is not loaded yet

    var r = try buildScripts(gpa, native("/p"), &fs);
    defer r.deinit(gpa);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    for (r.files.keys()) |f| try names.append(gpa, fs.path(f));
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    try testing.expectEqual(4, names.items.len);
    try testing.expectEqualStrings(native("/p/build.zig"), names.items[0]);
    try testing.expectEqualStrings(native("/p/build.zig.zon"), names.items[1]);
    try testing.expectEqualStrings(native("/p/build/helper.zig"), names.items[2]);
    try testing.expectEqualStrings(native("/p/shared.zig"), names.items[3]);
    try testing.expectEqual(1, r.missing.count());
    try testing.expectEqualStrings(native("/p/shared.zig"), fs.path(r.missing.keys()[0]));
}

test "relative imports that do not resolve to absolute paths are skipped" {
    // A path relative to another drive on Windows (`D:other.zig` is still relative after
    // resolution) used to be passed to `intern`, which panicked
    const gpa = testing.allocator;
    var fs: FakeFs = .{};
    defer fs.deinit();
    try fs.files.put(gpa, native("/p/build.zig"), &.{ "D:other.zig", "helper.zig" });
    try fs.files.put(gpa, native("/p/build.zig.zon"), &.{});
    try fs.files.put(gpa, native("/p/helper.zig"), &.{});
    var r = try buildScripts(gpa, native("/p"), &fs);
    defer r.deinit(gpa);
    try testing.expect(r.files.contains(try fs.intern(native("/p/helper.zig"))));
}

test "a file shared by modules of different compile steps records every module" {
    const gpa = testing.allocator;
    // exe (module 0) and test (module 1) share the root file main.zig; the test module also
    // imports helper (module 2), and both import dep (module 3)
    var modules = [_]ProjectModel.Module{
        .{ .root_file = native("/p/src/main.zig"), .imports = &.{.{ .name = "dep", .module = 3 }} },
        .{ .root_file = native("/p/src/main.zig"), .imports = &.{ .{ .name = "dep", .module = 3 }, .{ .name = "helper", .module = 2 } } },
        .{ .root_file = native("/p/helper.zig"), .imports = &.{} },
        .{ .root_file = native("/p/dep.zig"), .imports = &.{} },
    };
    const steps = [_]ProjectModel.Step{
        .{ .name = "exe", .kind = .{ .compile = .{ .root_module = 0 } }, .deps = &.{} },
        .{ .name = "test", .kind = .{ .compile = .{ .root_module = 1 } }, .deps = &.{} },
    };
    const model: ProjectModel = .{ .arena = .{}, .build_root = native("/p"), .std_root = native("/zig/std/std.zig"), .steps = &steps, .modules = &modules, .default_step = 0 };

    var fs: FakeFs = .{};
    defer fs.deinit();
    try fs.files.put(gpa, native("/p/src/main.zig"), &.{ "dep", "helper", "util.zig", "std" });
    try fs.files.put(gpa, native("/p/src/util.zig"), &.{});
    try fs.files.put(gpa, native("/p/helper.zig"), &.{});
    try fs.files.put(gpa, native("/p/dep.zig"), &.{});
    try fs.files.put(gpa, native("/zig/std/std.zig"), &.{});

    var r = try compute(gpa, &model, &.{ 0, 1 }, &fs);
    defer r.deinit(gpa);
    const id = struct {
        fn of(f: *FakeFs, path: []const u8) FileId {
            for (f.paths.items, 0..) |p, i| if (std.mem.eql(u8, p, path)) return @fromBackingInt(@as(u32, @intCast(i)));
            unreachable;
        }
    }.of;
    const main = id(&fs, native("/p/src/main.zig"));
    const util = id(&fs, native("/p/src/util.zig"));
    // The compile step that reaches a file first determines its membership in `files`
    try testing.expectEqual(0, r.files.get(main).?.module);
    try testing.expectEqual(0, r.files.get(util).?.module);
    try testing.expectEqual(2, r.files.get(id(&fs, native("/p/helper.zig"))).?.module);
    // Files reached again in the test module are recorded as other memberships; files in the same
    // module in both steps (dep, std) are not recorded twice
    try testing.expectEqual(2, r.others.count());
    try testing.expect(r.others.contains(.{ .file = main, .module = 1 }));
    try testing.expect(r.others.contains(.{ .file = util, .module = 1 }));
    // The compile step that reaches a module first (its builtin comes from that compilation)
    for ([_]u32{ 0, 1, 1, 0 }, 0..) |step, module| try testing.expectEqual(step, r.modules.get(@intCast(module)).?);
}

test "relative imports leaving the module directory are not followed" {
    // The compiler reports `import of file outside module path` and does not compile the target:
    // common/util.zig must not join the module of /p/src/main.zig
    const gpa = testing.allocator;
    var modules = [_]ProjectModel.Module{.{ .root_file = native("/p/src/main.zig"), .imports = &.{} }};
    const steps = [_]ProjectModel.Step{.{ .name = "exe", .kind = .{ .compile = .{ .root_module = 0 } }, .deps = &.{} }};
    const model: ProjectModel = .{ .arena = .{}, .build_root = native("/p"), .std_root = native("/zig/std/std.zig"), .steps = &steps, .modules = &modules, .default_step = 0 };
    var fs: FakeFs = .{};
    defer fs.deinit();
    try fs.files.put(gpa, native("/p/src/main.zig"), &.{ "../common/util.zig", "sub/../inner.zig", "std" });
    try fs.files.put(gpa, native("/p/src/inner.zig"), &.{});
    try fs.files.put(gpa, native("/p/common/util.zig"), &.{});
    try fs.files.put(gpa, native("/zig/std/std.zig"), &.{"../escape.zig"});
    try fs.files.put(gpa, native("/zig/escape.zig"), &.{});

    var r = try compute(gpa, &model, &.{0}, &fs);
    defer r.deinit(gpa);
    try testing.expect(r.contains(try fs.intern(native("/p/src/inner.zig"))));
    try testing.expect(!r.contains(try fs.intern(native("/p/common/util.zig"))));
    try testing.expect(!r.contains(try fs.intern(native("/zig/escape.zig"))));
    try testing.expectEqual(3, r.files.count());

    // The same holds for build scripts, whose module directory is the build root
    try fs.files.put(gpa, native("/p/build.zig"), &.{"../outside.zig"});
    try fs.files.put(gpa, native("/p/build.zig.zon"), &.{});
    try fs.files.put(gpa, native("/outside.zig"), &.{});
    var s = try buildScripts(gpa, native("/p"), &fs);
    defer s.deinit(gpa);
    try testing.expectEqual(2, s.files.count());
}

test "@import(\"root\") in a test compilation reaches the test runner" {
    const gpa = testing.allocator;
    var modules = [_]ProjectModel.Module{.{ .root_file = native("/p/src/root.zig"), .imports = &.{} }};
    const steps = [_]ProjectModel.Step{.{ .name = "test", .kind = .{ .compile = .{
        .root_module = 0,
        .root = .{ .test_runner = native("/zig/compiler/test_runner.zig") },
    } }, .deps = &.{} }};
    const model: ProjectModel = .{ .arena = .{}, .build_root = native("/p"), .std_root = native("/zig/std/std.zig"), .steps = &steps, .modules = &modules, .default_step = 0 };

    var fs: FakeFs = .{};
    defer fs.deinit();
    try fs.files.put(gpa, native("/p/src/root.zig"), &.{"helper.zig"});
    try fs.files.put(gpa, native("/p/src/helper.zig"), &.{"root"});
    try fs.files.put(gpa, native("/zig/compiler/test_runner.zig"), &.{ "std", "builtin" });
    try fs.files.put(gpa, native("/zig/std/std.zig"), &.{"root"});

    var r = try compute(gpa, &model, &.{0}, &fs);
    defer r.deinit(gpa);
    // The runner is compiled as a module of its own, and `root` never reaches the user's root
    // file in another module
    const runner = r.files.get(try fs.intern(native("/zig/compiler/test_runner.zig"))).?;
    try testing.expectEqual(std_module, runner.module);
    try testing.expectEqual(0, r.files.get(try fs.intern(native("/p/src/root.zig"))).?.module);
    try testing.expectEqual(0, r.others.count());
}
