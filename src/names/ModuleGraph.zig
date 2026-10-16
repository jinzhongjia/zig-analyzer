//! 模块图（设计 §7.1）：各模块的根文件与 import 表，以及每个文件所属的模块。
//!
//! 由 Server 汇总各项目的构建图与编译集合生成，作为查询引擎的 input（`ModuleGraphInput`）。
//! 文件的模块归属来自编译集合（与编译器一致：从 compile step 的根模块沿 import 到达）；
//! 不在任何编译集合中的文件没有归属，只能 import 标准库与相对路径。

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const Vfs = @import("../base/Vfs.zig");
const FileId = Vfs.FileId;
const ProjectModel = @import("../base/ProjectModel.zig");
const CompileSet = @import("../diagnostics/compile_set.zig");
const deepEql = @import("../util/deep_eql.zig").deepEql;
const FileIndex = @import("../ide_db/FileIndex.zig");

const ModuleGraph = @This();

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
    /// `modules` 下标；标准库文件为 `std_module`
    module: u32,
    /// `@import("root")` 的目标模块
    root_module: u32,
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

    pub fn init(gpa: Allocator, vfs: *Vfs) Builder {
        return .{ .gpa = gpa, .vfs = vfs, .arena = .init(gpa) };
    }

    /// `finish` 之后不必调用
    pub fn deinit(b: *Builder) void {
        b.files.deinit(b.gpa);
        b.arena.deinit();
    }

    /// `extra`：其余编译 step 可达的文件，不在编译集合中的按它归属（测试、示例中的文件也能解析模块 import）
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
                // 同一文件属于多个项目（或同时在编译集合与 `extra` 中）时取第一个
                const gop = try b.files.getOrPut(b.gpa, file);
                if (gop.found_existing) continue;
                gop.value_ptr.* = .{
                    .file = file,
                    .module = if (mem.module == std_module) std_module else offset + mem.module,
                    .root_module = offset + mem.root_module,
                };
            }
        }
    }

    pub fn finish(b: *Builder, std_root: ?FileId, default_builtin: ?FileId) Allocator.Error!ModuleGraph {
        const entries = try b.arena.allocator().dupe(FileEntry, b.files.values());
        std.mem.sort(FileEntry, entries, {}, struct {
            fn lt(_: void, x: FileEntry, y: FileEntry) bool {
                return @backingInt(x.file) < @backingInt(y.file);
            }
        }.lt);
        b.files.deinit(b.gpa);
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

/// 文件 `file` 中 `@import(name)` 的目标（模块名：std、builtin、root 与所在模块 import 的模块；
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
    if (e.module == std_module) return null;
    for (g.modules[e.module].imports) |imp| {
        if (std.mem.eql(u8, imp.name, name)) return g.modules[imp.module].root;
    }
    return null;
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
/// 不使依赖它的推导重算。项目加载期间模块图会多次更新，此前每次都使已推导的结果全部重算
pub const FileImports = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = FileId;
    pub const Value = *const Table;

    pub const Table = struct {
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
