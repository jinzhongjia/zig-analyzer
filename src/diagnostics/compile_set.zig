//! 编译集合：编译器会做 AstGen 的全部文件，即从各 compile step 的根模块与标准库根文件出发，
//! 沿 ZIR 记录的 `@import`（含未被分析的函数中的 import）可达的文件。live 诊断只对其中的文件发布。

const std = @import("std");
const Allocator = std.mem.Allocator;
const ProjectModel = @import("../base/ProjectModel.zig");
const Vfs = @import("../base/Vfs.zig");
const FileId = Vfs.FileId;

pub const Result = struct {
    /// 文件 → 第一次到达它时所在的模块
    files: std.AutoArrayHashMapUnmanaged(FileId, Membership) = .empty,
    /// 文件之后又在其他模块中到达时的 (文件, 模块)，按到达顺序：不同 compile step 中同一文件可以属于
    /// import 表不同的模块（如 exe 与 test 各自创建模块、共用根文件）
    others: std.AutoArrayHashMapUnmanaged(FileModule, void) = .empty,
    /// 可达但尚未加载内容的文件；调用方加载后应重新计算
    missing: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        r.files.deinit(gpa);
        r.others.deinit(gpa);
        r.missing.deinit(gpa);
    }

    pub fn contains(r: *const Result, file: FileId) bool {
        return r.files.contains(file);
    }
};

/// 标准库在遍历中使用的模块编号
pub const std_module = std.math.maxInt(u32);

pub const FileModule = struct {
    file: FileId,
    /// `ProjectModel.modules` 下标；标准库为 `std_module`
    module: u32,
};

pub const Membership = struct {
    /// `ProjectModel.modules` 下标；标准库为 `std_module`
    module: u32,
    /// 所在 compile step 的根模块（`@import("root")` 的目标）
    root_module: u32,
};

/// `resolver` 需提供：
/// - `intern(path: []const u8) !FileId`：绝对路径 → FileId
/// - `path(file: FileId) []const u8`：FileId → 绝对路径
/// - `imports(file: FileId) !?[]const []const u8`：文件的 import 字符串；内容尚未加载时返回 null
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
        const root_module = model.steps[step].kind.compile.root_module;
        const root_file = model.modules[root_module].root_file orelse continue;
        // `@import("root")` 依赖 compile step，因此每个 compile step 单独遍历
        visited.clearRetainingCapacity();
        try stack.append(gpa, .{ .file = try resolver.intern(root_file), .module = root_module });
        // 标准库总会参与编译（入口 start.zig 在其中），即使用户代码没有 import std
        try stack.append(gpa, .{ .file = try resolver.intern(model.std_root), .module = std_module });

        while (stack.pop()) |node| {
            if ((try visited.getOrPut(gpa, node)).found_existing) continue;
            const gop = try result.files.getOrPut(gpa, node.file);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .module = node.module, .root_module = root_module };
            } else if (gop.value_ptr.module != node.module) {
                try result.others.put(gpa, node, {});
            }
            const imports = try resolver.imports(node.file) orelse {
                try result.missing.put(gpa, node.file, {});
                continue;
            };
            _ = scratch.reset(.retain_capacity);
            const a = scratch.allocator();
            for (imports) |name| {
                const target: Node = if (std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".zon")) blk: {
                    const file = try relativeImport(a, resolver, node.file, name) orelse continue;
                    break :blk .{ .file = file, .module = node.module };
                } else if (std.mem.eql(u8, name, "std"))
                    .{ .file = try resolver.intern(model.std_root), .module = std_module }
                else if (std.mem.eql(u8, name, "root"))
                    .{ .file = try resolver.intern(root_file), .module = root_module }
                else if (std.mem.eql(u8, name, "builtin"))
                    continue // 由编译器生成，不在磁盘上
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

/// 构建脚本：构建根目录的 build.zig、build.zig.zon，以及从 build.zig 沿相对路径的 `@import` 可达的文件。
/// build.zig 由编译器编译为构建程序，其中的错误同样会报出；按名字 import 的模块（std、依赖包）不在其中。
/// 只用于决定 live 诊断与保存后是否重新配置，不参与模块归属
pub const Scripts = struct {
    files: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty,
    /// 可达但尚未加载内容的文件；调用方加载后应重新计算
    missing: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty,

    pub fn deinit(s: *Scripts, gpa: Allocator) void {
        s.files.deinit(gpa);
        s.missing.deinit(gpa);
    }
};

/// `resolver` 的要求同 `compute`
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
    while (stack.pop()) |file| {
        if ((try result.files.getOrPut(gpa, file)).found_existing) continue;
        const imports = try resolver.imports(file) orelse {
            try result.missing.put(gpa, file, {});
            continue;
        };
        for (imports) |name| {
            if (!std.mem.endsWith(u8, name, ".zig") and !std.mem.endsWith(u8, name, ".zon")) continue;
            try stack.append(gpa, try relativeImport(scratch.allocator(), resolver, file, name) orelse continue);
        }
    }
    return result;
}

/// 文件 `file` 中按相对路径 `@import(name)` 的目标。解析结果不是绝对路径时（Windows 上另一驱动器的相对路径，
/// 如 `D:a.zig`）不能驻留，返回 null
fn relativeImport(a: Allocator, resolver: anytype, file: FileId, name: []const u8) !?FileId {
    const dir = std.fs.path.dirname(resolver.path(file)) orelse return null;
    return try resolver.intern(try Vfs.resolve(.native, a, dir, name) orelse return null);
}

const testing = std.testing;
const native = @import("../util/test_path.zig").native;

/// 测试用：内存中的文件系统
const FakeFs = struct {
    paths: std.ArrayList([]const u8) = .empty,
    /// 路径 → import 列表；不在表中视为未加载
    files: std.StringHashMapUnmanaged([]const []const u8) = .empty,

    fn intern(fs: *FakeFs, file_path: []const u8) !FileId {
        // 与 `Vfs.intern` 的约定相同：只接受绝对路径
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
    // main（模块 0）import "lib"（模块 1）、"std"、相对文件；std 内部 import "root"
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
    try fs.files.put(gpa, native("/p/src/util.zig"), &.{"../data.zon"});
    try fs.files.put(gpa, native("/p/data.zon"), &.{});
    try fs.files.put(gpa, native("/p/lib/lib.zig"), &.{ "std", "nested/deep.zig", "unknown_module" });
    // std.zig 尚未加载

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
    try testing.expectEqualStrings(native("/p/data.zon"), names.items[0]);
    try testing.expectEqualStrings(native("/p/lib/lib.zig"), names.items[1]);
    try testing.expectEqualStrings(native("/p/lib/nested/deep.zig"), names.items[2]);
    try testing.expectEqualStrings(native("/p/src/main.zig"), names.items[3]);
    try testing.expectEqualStrings(native("/p/src/util.zig"), names.items[4]);
    try testing.expectEqualStrings(native("/zig/std/std.zig"), names.items[5]);
    try testing.expectEqual(6, names.items.len);
    // 未加载的文件：std.zig 与 deep.zig
    try testing.expectEqual(2, r.missing.count());
    // 模块归属：相对 import 留在原模块，按名字 import 进入目标模块
    const member = struct {
        fn of(res: *const Result, f: *FakeFs, path: []const u8) Membership {
            for (f.paths.items, 0..) |p, i| if (std.mem.eql(u8, p, path)) return res.files.get(@fromBackingInt(@as(u32, @intCast(i)))).?;
            unreachable;
        }
    }.of;
    try testing.expectEqual(0, member(&r, &fs, native("/p/src/util.zig")).module);
    try testing.expectEqual(1, member(&r, &fs, native("/p/lib/nested/deep.zig")).module);
    try testing.expectEqual(std_module, member(&r, &fs, native("/zig/std/std.zig")).module);
    try testing.expectEqual(0, member(&r, &fs, native("/p/lib/lib.zig")).root_module);
}

test buildScripts {
    const gpa = testing.allocator;
    var fs: FakeFs = .{};
    defer fs.deinit();
    // build.zig 导入 std、依赖包与相对文件；相对文件再导入 zon 与上级目录的文件
    try fs.files.put(gpa, native("/p/build.zig"), &.{ "std", "dep", "build/helper.zig" });
    try fs.files.put(gpa, native("/p/build.zig.zon"), &.{});
    try fs.files.put(gpa, native("/p/build/helper.zig"), &.{ "../build.zig.zon", "../shared.zig" });
    // shared.zig 尚未加载

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
    // 曾把 Windows 上另一驱动器的相对路径（`D:other.zig` 解析后仍是相对路径）交给 `intern`，在其中 panic
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
    // exe（模块 0）与 test（模块 1）共用根文件 main.zig；test 的模块多 import 一个 helper（模块 2），
    // 两者都 import dep（模块 3）
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
    // 先到达的 compile step 决定 `files` 中的归属
    try testing.expectEqual(0, r.files.get(main).?.module);
    try testing.expectEqual(0, r.files.get(util).?.module);
    try testing.expectEqual(2, r.files.get(id(&fs, native("/p/helper.zig"))).?.module);
    // test 的模块中再次到达的文件记为其他归属；两个 step 中模块相同的文件（dep、std）不重复记录
    try testing.expectEqual(2, r.others.count());
    try testing.expect(r.others.contains(.{ .file = main, .module = 1 }));
    try testing.expect(r.others.contains(.{ .file = util, .module = 1 }));
}
