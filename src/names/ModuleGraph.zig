//! 模块图：各模块的根文件与 import 表，以及每个文件所属的模块。
//!
//! 由 Server 汇总各项目的构建图与编译集合生成，作为查询引擎的 input（`ModuleGraphInput`）。
//! 文件的模块归属来自编译集合（与编译器一致：从 compile step 的根模块沿 import 到达）。一个文件可以
//! 属于多个模块（不同 compile step 各自创建的模块共用一个文件，如 exe 与 test 共用根文件），按名字的
//! import 依次在这些模块的 import 表中查找。不在任何编译集合中的文件没有归属，只能 import 标准库与
//! 相对路径。

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const Vfs = @import("../base/Vfs.zig");
const FileId = Vfs.FileId;
const ProjectModel = @import("../base/ProjectModel.zig");
const CompileSet = @import("../diagnostics/compile_set.zig");
const deepEql = @import("../util/deep_eql.zig").deepEql;
const FileIndex = @import("../syntax/FileIndex.zig");

const ModuleGraph = @This();

/// 其余字段的切片都分配在这块 arena 中。构建完成后不再分配，只用于整体释放，
/// 因此只保存 `State`，释放时用同一个 gpa `promote` 回 `ArenaAllocator`。
/// 不存整个 `ArenaAllocator`：`allocator()` 返回的 `Allocator` 指向 arena 自身，值被复制后会失效。
arena: std.heap.ArenaAllocator.State,
/// `<std_dir>/std.zig`；zig 环境未知时为 null
std_root: ?FileId,
/// 不属于任何模块的文件使用的 builtin.zig（本机目标、Debug，与单文件编译一致）
default_builtin: ?FileId = null,
modules: []const Module,
/// 按 FileId 排序
files: []const FileEntry,

pub const std_module = CompileSet.std_module;

pub const Module = struct {
    root: ?FileId,
    imports: []const Import,
    /// 该模块的 builtin.zig（按模块的目标与编译选项生成）
    builtin: ?FileId = null,
};

pub const Import = struct {
    name: []const u8,
    module: u32,
};

pub const FileEntry = struct {
    file: FileId,
    /// `modules` 下标；标准库文件为 `std_module`。属于多个模块时为最优先的一个（诊断 step 的、本机
    /// 目标的 compile step 中的模块在前）
    module: u32,
    /// `@import("root")` 的目标模块（`module` 所在 compile step 的根模块）
    root_module: u32,
    /// 文件同时属于的其他模块，按优先级排列（不含 `module`）
    others: []const u32 = &.{},
};

pub fn deinit(g: *ModuleGraph, gpa: Allocator) void {
    var arena = g.arena.promote(gpa);
    arena.deinit();
    g.* = undefined;
}

/// 逐个项目添加构建图与编译集合（调用方只需在 `add` 期间持有该项目的锁）
pub const Builder = struct {
    gpa: Allocator,
    vfs: *Vfs,
    arena: std.heap.ArenaAllocator,
    modules: std.ArrayList(Module) = .empty,
    files: std.AutoArrayHashMapUnmanaged(FileId, FileEntry) = .empty,
    /// 文件的其他归属，按加入的顺序（即优先级）；`finish` 时按文件分组写入 `FileEntry.others`
    others: std.AutoArrayHashMapUnmanaged(Other, void) = .empty,

    const Other = struct {
        /// 文件在 `files` 中的下标
        index: u32,
        module: u32,
    };

    pub fn init(gpa: Allocator, vfs: *Vfs) Builder {
        return .{ .gpa = gpa, .vfs = vfs, .arena = .init(gpa) };
    }

    /// `finish` 之后不必调用
    pub fn deinit(b: *Builder) void {
        b.files.deinit(b.gpa);
        b.others.deinit(b.gpa);
        b.arena.deinit();
    }

    /// `extra`：其余编译 step 可达的文件（测试、示例中的文件也能解析模块 import），归属排在编译集合之后。
    /// 同一文件属于多个项目时，先加入的项目中的归属优先
    pub fn add(b: *Builder, model: *const ProjectModel, compile_set: *const CompileSet.Result, extra: ?*const CompileSet.Result) Allocator.Error!void {
        const a = b.arena.allocator();
        const offset: u32 = @intCast(b.modules.items.len);
        for (model.modules) |m| {
            const imports = try a.alloc(Import, m.imports.len);
            for (m.imports, imports) |src, *dst| dst.* = .{ .name = try a.dupe(u8, src.name), .module = offset + src.module };
            try b.modules.append(a, .{
                .root = if (m.root_file) |p| try b.vfs.intern(p) else null,
                .imports = imports,
                .builtin = if (m.builtin_file) |p| try b.vfs.intern(p) else null,
            });
        }
        for ([_]?*const CompileSet.Result{ compile_set, extra }) |set| {
            const cs = set orelse continue;
            for (cs.files.keys(), cs.files.values()) |file, mem| {
                const module = if (mem.module == std_module) std_module else offset + mem.module;
                const gop = try b.files.getOrPut(b.gpa, file);
                if (gop.found_existing) {
                    try b.addOther(gop.index, module);
                } else {
                    gop.value_ptr.* = .{ .file = file, .module = module, .root_module = offset + mem.root_module };
                }
            }
            // 这些文件第一次到达时的归属已在上面加入
            for (cs.others.keys()) |o| try b.addOther(b.files.getIndex(o.file).?, if (o.module == std_module) std_module else offset + o.module);
        }
    }

    fn addOther(b: *Builder, index: usize, module: u32) Allocator.Error!void {
        if (b.files.values()[index].module == module) return;
        try b.others.put(b.gpa, .{ .index = @intCast(index), .module = module }, {});
    }

    pub fn finish(b: *Builder, std_root: ?FileId, default_builtin: ?FileId) Allocator.Error!ModuleGraph {
        const a = b.arena.allocator();
        const values = b.files.values();
        // 其他归属按文件分组放在同一个数组中，同一文件内保持加入的顺序（计数排序）
        const all = try a.alloc(u32, b.others.count());
        const next = try b.gpa.alloc(u32, values.len);
        defer b.gpa.free(next);
        @memset(next, 0);
        for (b.others.keys()) |o| next[o.index] += 1;
        var start: u32 = 0;
        for (values, next) |*e, *n| {
            e.others = all[start..][0..n.*];
            n.* = start;
            start += @intCast(e.others.len);
        }
        for (b.others.keys()) |o| {
            all[next[o.index]] = o.module;
            next[o.index] += 1;
        }
        const entries = try a.dupe(FileEntry, values);
        std.mem.sort(FileEntry, entries, {}, struct {
            fn lt(_: void, x: FileEntry, y: FileEntry) bool {
                return @backingInt(x.file) < @backingInt(y.file);
            }
        }.lt);
        b.files.deinit(b.gpa);
        b.others.deinit(b.gpa);
        return .{ .arena = b.arena.state, .std_root = std_root, .default_builtin = default_builtin, .modules = b.modules.items, .files = entries };
    }
};

pub fn entry(g: *const ModuleGraph, file: FileId) ?FileEntry {
    const i = std.sort.binarySearch(FileEntry, g.files, file, struct {
        fn order(f: FileId, e: FileEntry) std.math.Order {
            return std.math.order(@backingInt(f), @backingInt(e.file));
        }
    }.order) orelse return null;
    return g.files[i];
}

/// 文件 `file` 中 `@import(name)` 的目标（模块名：std、builtin、root 与所属各模块 import 的模块；
/// 相对路径不经过模块图，不在此处理）
pub fn importTarget(g: *const ModuleGraph, file: FileId, name: []const u8) ?FileId {
    if (std.mem.eql(u8, name, "std")) return g.std_root;
    if (std.mem.eql(u8, name, "builtin")) {
        // 标准库使用所在 compile step 根模块的 builtin（与编译器一致）；不属于任何模块的文件用默认的
        const e = g.entry(file) orelse return g.default_builtin;
        const m = if (e.module == std_module) e.root_module else e.module;
        return g.modules[m].builtin orelse g.default_builtin;
    }
    const e = g.entry(file) orelse return null;
    if (std.mem.eql(u8, name, "root")) return g.modules[e.root_module].root;
    // 属于多个模块时依次查找；多个模块都 import 同一名字（可能指向不同的模块）时取最优先的模块中的
    if (g.moduleImport(e.module, name)) |m| return g.modules[m].root;
    for (e.others) |other| if (g.moduleImport(other, name)) |m| return g.modules[m].root;
    return null;
}

/// 文件 `file` 中 `@import(name)` 的全部目标：文件所属的多个模块以 `name` import 不同的模块时有多个，
/// 按模块的优先级排列、不重复，第一个即 `importTarget` 的结果（它为 null 时为空）
pub fn importTargets(g: *const ModuleGraph, arena: Allocator, file: FileId, name: []const u8) Allocator.Error![]const FileId {
    const first = g.importTarget(file, name) orelse return &.{};
    var targets: std.ArrayList(FileId) = .empty;
    try targets.append(arena, first);
    // std、builtin、root 只有一个目标
    for ([_][]const u8{ "std", "builtin", "root" }) |n| if (std.mem.eql(u8, name, n)) return targets.items;
    // `module` import 了这个名字时，其目标即 `first`
    for (g.entry(file).?.others) |other| {
        const target = g.modules[g.moduleImport(other, name) orelse continue].root orelse continue;
        if (std.mem.indexOfScalar(FileId, targets.items, target) == null) try targets.append(arena, target);
    }
    return targets.items;
}

/// 模块 `module` 以 `name` import 的模块
fn moduleImport(g: *const ModuleGraph, module: u32, name: []const u8) ?u32 {
    if (module == std_module) return null;
    for (g.modules[module].imports) |imp| {
        if (std.mem.eql(u8, imp.name, name)) return imp.module;
    }
    return null;
}

/// 文件所属的各模块的 import 名字（不重复，按模块的优先级）
pub fn importNames(g: *const ModuleGraph, arena: Allocator, file: FileId) Allocator.Error![]const []const u8 {
    const e = g.entry(file) orelse return &.{};
    var names: std.ArrayList([]const u8) = .empty;
    const first = [_]u32{e.module};
    for ([_][]const u32{ &first, e.others }) |modules| for (modules) |m| {
        if (m == std_module) continue;
        for (g.modules[m].imports) |imp| {
            for (names.items) |n| {
                if (std.mem.eql(u8, n, imp.name)) break;
            } else try names.append(arena, imp.name);
        }
    };
    return names.items;
}

pub fn eql(a: *const ModuleGraph, b: *const ModuleGraph) bool {
    return deepEql(a.std_root, b.std_root) and deepEql(a.default_builtin, b.default_builtin) and deepEql(a.modules, b.modules) and deepEql(a.files, b.files);
}

/// 查询引擎 input；未设置时为 null（没有任何项目与 zig 环境信息）
pub const Input = struct {
    pub const kind: engine.Kind = .input;
    pub const Key = void;
    pub const Value = ?*const ModuleGraph;
    pub const default: Value = null;

    pub fn eql(a: Value, b: Value) bool {
        if (a == null or b == null) return a == null and b == null;
        return a.?.eql(b.?);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        if (v.*) |g| {
            const m: *ModuleGraph = @constCast(g);
            m.deinit(gpa);
            gpa.destroy(m);
        }
    }
};

/// 文件中各模块名 import 的目标（文件中出现的 `@import` 字符串，另加 std、builtin、root）。
///
/// 名字解析经由它读取模块图：模块图的其他变化（如加入新文件、其他模块的 import 表）在这里截断，
/// 不使依赖它的推导重算（项目加载期间模块图会多次更新）
pub const FileImports = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = FileId;
    pub const Value = *const Table;

    pub const Table = struct {
        /// `Table` 自身与 `names`、`targets` 所在的 arena，只保存 `State` 的原因同 `ModuleGraph.arena`
        arena: std.heap.ArenaAllocator.State,
        names: []const []const u8,
        targets: []const ?FileId,

        /// 名字不在表中时为 null；在表中但没有目标时为 `.{ null }`
        pub fn get(t: *const Table, name: []const u8) ??FileId {
            for (t.names, t.targets) |n, target| if (std.mem.eql(u8, n, name)) return target;
            return null;
        }
    };

    pub fn compute(ctx: anytype, file: Key) engine.Error!Value {
        const graph = try ctx.get(Input, {});
        const index = try ctx.get(FileIndex.Query, file);
        var arena: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var names: std.ArrayList([]const u8) = .empty;
        for ([_][]const u8{ "std", "builtin", "root" }) |n| try names.append(a, n);
        for (index.imports) |n| {
            if (std.mem.endsWith(u8, n, ".zig") or std.mem.endsWith(u8, n, ".zon")) continue;
            for (names.items) |x| {
                if (std.mem.eql(u8, x, n)) break;
            } else try names.append(a, try a.dupe(u8, n));
        }
        const targets = try a.alloc(?FileId, names.items.len);
        for (names.items, targets) |n, *t| t.* = if (graph) |g| g.importTarget(file, n) else null;
        const table = try a.create(Table);
        table.* = .{ .arena = undefined, .names = names.items, .targets = targets };
        table.arena = arena.state;
        return table;
    }

    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a.names, b.names) and deepEql(a.targets, b.targets);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        var arena = v.*.arena.promote(gpa);
        arena.deinit();
    }
};

/// 标准库的根文件：同 `FileImports`，截断模块图的其他变化
pub const StdRoot = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = void;
    pub const Value = ?FileId;

    pub fn compute(ctx: anytype, _: Key) engine.Error!Value {
        const graph = try ctx.get(Input, {}) orelse return null;
        return graph.std_root;
    }
};

const testing = std.testing;
const native = @import("../util/test_path.zig").native;

test "a file in several modules resolves imports from each of them" {
    const gpa = testing.allocator;
    var vfs: Vfs = .init(testing.io, gpa);
    defer vfs.deinit();
    // exe 的模块（0）与 test 的模块（1）共用根文件 main.zig：exe 中 dep → a；test 中 dep → b，另有 helper → b
    var modules = [_]ProjectModel.Module{
        .{ .root_file = native("/p/src/main.zig"), .imports = &.{.{ .name = "dep", .module = 2 }} },
        .{ .root_file = native("/p/src/main.zig"), .imports = &.{ .{ .name = "dep", .module = 3 }, .{ .name = "helper", .module = 3 } } },
        .{ .root_file = native("/p/a.zig"), .imports = &.{} },
        .{ .root_file = native("/p/b.zig"), .imports = &.{} },
    };
    const model: ProjectModel = .{ .arena = .{}, .build_root = native("/p"), .std_root = native("/zig/std/std.zig"), .steps = &.{}, .modules = &modules, .default_step = 0 };
    const main = try vfs.intern(native("/p/src/main.zig"));
    const a = try vfs.intern(native("/p/a.zig"));
    const b = try vfs.intern(native("/p/b.zig"));
    // 编译集合（诊断 step 为 exe）与全部 compile step 的集合（exe 在前）
    var cs: CompileSet.Result = .{};
    defer cs.deinit(gpa);
    try cs.files.put(gpa, main, .{ .module = 0, .root_module = 0 });
    try cs.files.put(gpa, a, .{ .module = 2, .root_module = 0 });
    var extra: CompileSet.Result = .{};
    defer extra.deinit(gpa);
    try extra.files.put(gpa, main, .{ .module = 0, .root_module = 0 });
    try extra.files.put(gpa, a, .{ .module = 2, .root_module = 0 });
    try extra.files.put(gpa, b, .{ .module = 3, .root_module = 1 });
    try extra.others.put(gpa, .{ .file = main, .module = 1 }, {});

    var builder: Builder = .init(gpa, &vfs);
    try builder.add(&model, &cs, &extra);
    var g = try builder.finish(null, null);
    defer g.deinit(gpa);
    try testing.expectEqualSlices(u32, &.{1}, g.entry(main).?.others);
    // 只有 test 的模块 import 的名字也能解析
    try testing.expectEqual(@as(?FileId, b), g.importTarget(main, "helper"));
    // 两个模块都 import 的名字取优先的模块（编译集合中的 exe）中的
    try testing.expectEqual(@as(?FileId, a), g.importTarget(main, "dep"));
    try testing.expectEqual(null, g.importTarget(main, "other"));
    // `@import("root")` 取优先的归属所在 compile step 的根模块
    try testing.expectEqual(@as(?FileId, main), g.importTarget(main, "root"));

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const names = try g.importNames(arena.allocator(), main);
    try testing.expectEqual(2, names.len);
    try testing.expectEqualStrings("dep", names[0]);
    try testing.expectEqualStrings("helper", names[1]);
}

test "importTargets lists the targets of every module of a file in priority order" {
    const gpa = testing.allocator;
    var vfs: Vfs = .init(testing.io, gpa);
    defer vfs.deinit();
    // exe（0）、test（1）与 check（4）的模块共用根文件 main.zig，按这个顺序优先
    var modules = [_]ProjectModel.Module{
        .{ .root_file = native("/p/src/main.zig"), .imports = &.{ .{ .name = "dep", .module = 2 }, .{ .name = "same", .module = 2 } } },
        .{ .root_file = native("/p/src/main.zig"), .imports = &.{ .{ .name = "dep", .module = 3 }, .{ .name = "same", .module = 2 }, .{ .name = "helper", .module = 3 }, .{ .name = "opt", .module = 2 } } },
        .{ .root_file = native("/p/a.zig"), .imports = &.{} },
        .{ .root_file = native("/p/b.zig"), .imports = &.{} },
        .{ .root_file = native("/p/src/main.zig"), .imports = &.{ .{ .name = "dep", .module = 2 }, .{ .name = "opt", .module = 3 } } },
    };
    const model: ProjectModel = .{ .arena = .{}, .build_root = native("/p"), .std_root = native("/zig/std/std.zig"), .steps = &.{}, .modules = &modules, .default_step = 0 };
    const main = try vfs.intern(native("/p/src/main.zig"));
    const a = try vfs.intern(native("/p/a.zig"));
    const b = try vfs.intern(native("/p/b.zig"));
    const std_root = try vfs.intern(native("/zig/std/std.zig"));
    var cs: CompileSet.Result = .{};
    defer cs.deinit(gpa);
    try cs.files.put(gpa, main, .{ .module = 0, .root_module = 0 });
    try cs.files.put(gpa, a, .{ .module = 2, .root_module = 0 });
    try cs.files.put(gpa, b, .{ .module = 3, .root_module = 1 });
    try cs.others.put(gpa, .{ .file = main, .module = 1 }, {});
    try cs.others.put(gpa, .{ .file = main, .module = 4 }, {});

    var builder: Builder = .init(gpa, &vfs);
    try builder.add(&model, &cs, null);
    var g = try builder.finish(std_root, null);
    defer g.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    // 不同的目标都列出，按模块的优先级；check 中与 exe 相同的目标不重复
    try testing.expectEqualSlices(FileId, &.{ a, b }, try g.importTargets(ar, main, "dep"));
    // 各模块的目标相同
    try testing.expectEqualSlices(FileId, &.{a}, try g.importTargets(ar, main, "same"));
    // 只有一个模块 import 的名字
    try testing.expectEqualSlices(FileId, &.{b}, try g.importTargets(ar, main, "helper"));
    // 最优先的模块没有 import 这个名字
    try testing.expectEqualSlices(FileId, &.{ a, b }, try g.importTargets(ar, main, "opt"));
    try testing.expectEqualSlices(FileId, &.{}, try g.importTargets(ar, main, "other"));
    try testing.expectEqualSlices(FileId, &.{std_root}, try g.importTargets(ar, main, "std"));
    try testing.expectEqualSlices(FileId, &.{main}, try g.importTargets(ar, main, "root"));
    // 第一个目标即 `importTarget` 的结果
    for ([_][]const u8{ "dep", "same", "helper", "opt", "std", "root" }) |name| {
        try testing.expectEqual(g.importTarget(main, name), (try g.importTargets(ar, main, name))[0]);
    }
}

test "a file in many modules keeps its other modules in linear space" {
    // 防止每加入一个归属就复制一遍已有的归属：属于 k 个模块的文件会在模块图的 arena 中留下 O(k²) 的垃圾
    const gpa = testing.allocator;
    var vfs: Vfs = .init(testing.io, gpa);
    defer vfs.deinit();
    const k = 1000;
    var modules: [k]ProjectModel.Module = undefined;
    for (&modules) |*m| m.* = .{ .root_file = native("/p/src/main.zig"), .imports = &.{} };
    const model: ProjectModel = .{ .arena = .{}, .build_root = native("/p"), .std_root = native("/zig/std/std.zig"), .steps = &.{}, .modules = &modules, .default_step = 0 };
    const main = try vfs.intern(native("/p/src/main.zig"));
    var cs: CompileSet.Result = .{};
    defer cs.deinit(gpa);
    try cs.files.put(gpa, main, .{ .module = 0, .root_module = 0 });
    for (1..k) |m| try cs.others.put(gpa, .{ .file = main, .module = @intCast(m) }, {});

    var builder: Builder = .init(gpa, &vfs);
    try builder.add(&model, &cs, null);
    var g = try builder.finish(null, null);
    defer g.deinit(gpa);
    const others = g.entry(main).?.others;
    try testing.expectEqual(k - 1, others.len);
    for (others, 1..) |m, i| try testing.expectEqual(i, m);
    // 这些归属只占 4 KB；逐个复制时的垃圾约为 2 MB
    try testing.expect(g.arena.promote(gpa).queryCapacity() < 512 * 1024);
}
