//! 编译集合（设计 §11.4）：编译器会做 AstGen 的全部文件，即从各 compile step 的根模块与标准库根文件出发，
//! 沿 ZIR 记录的 `@import`（含未被分析的函数中的 import）可达的文件。live 诊断只对其中的文件发布。

const std = @import("std");
const Allocator = std.mem.Allocator;
const ProjectModel = @import("../base/ProjectModel.zig");
const FileId = @import("../base/Vfs.zig").FileId;

pub const Result = struct {
    files: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty,
    /// 可达但尚未加载内容的文件；调用方加载后应重新计算
    missing: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        r.files.deinit(gpa);
        r.missing.deinit(gpa);
    }

    pub fn contains(r: *const Result, file: FileId) bool {
        return r.files.contains(file);
    }
};

/// 标准库在遍历中使用的模块编号
const std_module = std.math.maxInt(u32);

/// `resolver` 需提供：
/// - `intern(path: []const u8) !FileId`：绝对路径 → FileId
/// - `path(file: FileId) []const u8`：FileId → 绝对路径
/// - `imports(file: FileId) !?[]const []const u8`：文件的 import 字符串；内容尚未加载时返回 null
pub fn compute(gpa: Allocator, model: *const ProjectModel, compile_steps: []const u32, resolver: anytype) !Result {
    var result: Result = .{};
    errdefer result.deinit(gpa);

    const Node = struct { file: FileId, module: u32 };
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
            try result.files.put(gpa, node.file, {});
            const imports = try resolver.imports(node.file) orelse {
                try result.missing.put(gpa, node.file, {});
                continue;
            };
            _ = scratch.reset(.retain_capacity);
            const a = scratch.allocator();
            for (imports) |name| {
                const target: Node = if (std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".zon")) blk: {
                    const dir = std.fs.path.dirname(resolver.path(node.file)) orelse continue;
                    break :blk .{ .file = try resolver.intern(try std.fs.path.resolveAlloc(a, &.{ dir, name })), .module = node.module };
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

const testing = std.testing;
const native = @import("../util/test_path.zig").native;

/// 测试用：内存中的文件系统
const FakeFs = struct {
    paths: std.ArrayList([]const u8) = .empty,
    /// 路径 → import 列表；不在表中视为未加载
    files: std.StringHashMapUnmanaged([]const []const u8) = .empty,

    fn intern(fs: *FakeFs, file_path: []const u8) !FileId {
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
}
