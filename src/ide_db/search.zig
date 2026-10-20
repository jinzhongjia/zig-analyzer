//! 引用查找：按名字粗筛候选文件，再逐处精确解析确认。
//!
//! 候选文件：能经由 `@import` 链到达定义所在文件的文件（引用不到定义的文件不必检查），
//! 且文件索引中包含该名字。局部名字只在所在成员（及其体内定义的容器成员）中查找。
//! 只在出现该名字的成员中解析；名字引用用名字解析，字段访问优先用命名空间求值，求不出时
//! 才读取该成员的类型推导结果。

const std = @import("std");
const database = @import("../database.zig");
const hir = database.hir;
const sema = database.sema;
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Def = resolve.Def;
const Body = @import("../hir/Body.zig");
const ast = @import("../syntax/ast.zig");
const infer = @import("../sema/infer.zig");
const FileIndex = @import("../syntax/FileIndex.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const deepEql = @import("../util/deep_eql.zig").deepEql;
const seed = @import("seed.zig");
const InternPool = @import("../sema/InternPool.zig");

pub const Reference = struct {
    file: FileId,
    start: u32,
    end: u32,
    /// 定义处的名字
    is_decl: bool = false,
};

/// 定义的名字；没有可引用的名字（文件、test、comptime 块）时为 null
pub fn defName(r: *Resolver, def: Def) resolve.Error!?[]const u8 {
    switch (def) {
        .item => |it| {
            const item = (try r.itemTree(it.file)).items[it.item];
            return switch (item.kind) {
                .@"test", .@"comptime" => null,
                else => item.name,
            };
        },
        .local => |l| return (try r.body(l.file, l.item)).binding(l.binding).name,
        .file => return null,
    }
}

pub const Options = struct {
    /// 搜索范围（项目中的文件）；定义所在的文件总在其中
    scope: []const FileId,
    /// 只在这个文件中查找（document highlight）
    only_file: ?FileId = null,
    /// 不为 null 时记录第一处有歧义的引用：泛型函数体内的成员访问，在一些调用点实例下指向 `def`，
    /// 另一些指向其他定义（重命名会破坏其他实例，应拒绝）
    ambiguous: ?*?Reference = null,
    /// 不为 null 时，名字出现在所查找的文件中嵌套超过上限、没有分析的代码里（`FileIndex.unanalyzed`）则置为
    /// true：那里可能有无法确认的引用（重命名会漏改，应拒绝）
    unanalyzed: ?*bool = null,
};

/// `def` 的全部引用（含定义处），按文件与位置排序
pub fn findReferences(r: *Resolver, def: Def, opts: Options) resolve.Error![]Reference {
    const name = try defName(r, def) orelse return &.{};
    var out: std.ArrayList(Reference) = .empty;
    if (try r.location(def)) |loc| {
        if (opts.only_file == null or opts.only_file.? == loc.file) try out.append(r.arena, .{ .file = loc.file, .start = loc.start, .end = loc.end, .is_decl = true });
    }
    const def_file = switch (def) {
        .item => |it| it.file,
        .local => |l| l.file,
        .file => unreachable,
    };

    var finder: Finder = .{ .r = r, .def = def, .name = name, .out = &out, .ambiguous = opts.ambiguous };
    switch (def) {
        .local => |l| {
            if (opts.only_file) |f| if (f != l.file) return out.items;
            if (opts.unanalyzed) |u| if ((try r.ctx.get(FileIndex.Query, l.file)).containsUnanalyzed(name)) {
                u.* = true;
            };
            // 局部名字：所在成员及其体内定义的容器中的成员
            const tree = try r.itemTree(l.file);
            for (0..tree.items.len) |i| {
                if (try sema.enclosedBy(r, l.file, @intCast(i), tree.items[l.item].ast_id)) try finder.item(l.file, @intCast(i));
            }
        },
        .item => {
            const files = if (opts.only_file) |f| try r.arena.dupe(FileId, &.{f}) else try importers(r, def_file, opts.scope);
            for (files) |f| {
                const index = try r.ctx.get(FileIndex.Query, f);
                if (!index.contains(name)) continue;
                if (opts.unanalyzed) |u| if (index.containsUnanalyzed(name)) {
                    u.* = true;
                };
                const tree = try r.itemTree(f);
                for (0..tree.items.len) |i| try finder.item(f, @intCast(i));
            }
        },
        .file => unreachable,
    }

    std.mem.sort(Reference, out.items, {}, struct {
        fn lt(_: void, a: Reference, b: Reference) bool {
            if (a.file != b.file) return @backingInt(a.file) < @backingInt(b.file);
            return a.start < b.start;
        }
    }.lt);
    // 定义处也可能作为表达式出现（如同一位置的多种解析路径）：去重
    var n: usize = 0;
    for (out.items) |ref| {
        if (n > 0 and out.items[n - 1].file == ref.file and out.items[n - 1].start == ref.start) {
            out.items[n - 1].is_decl = out.items[n - 1].is_decl or ref.is_decl;
            continue;
        }
        out.items[n] = ref;
        n += 1;
    }
    return out.items[0..n];
}

/// 模块图中的项目文件（不含标准库）
pub fn projectFiles(r: *Resolver) resolve.Error![]const FileId {
    const graph = try r.ctx.get(database.ModuleGraph.Input, {}) orelse return &.{};
    var out: std.ArrayList(FileId) = .empty;
    for (graph.files) |f| if (f.module != database.ModuleGraph.std_module) try out.append(r.arena, f.file);
    return out.items;
}

/// 在 `scope` 中能经由 `@import` 链到达 `target` 的文件（含 `target` 自身）。`target` 不在 `scope` 中
/// （标准库、依赖包）时，导入链会经过范围外的文件（项目 → `std.zig` → `mem.zig`）：沿 import 求出从
/// 范围内的文件可达的全部文件，在其上建立反向边；范围外的其他文件不在结果中
pub fn importers(r: *Resolver, target: FileId, scope: []const FileId) resolve.Error![]const FileId {
    // 范围内的文件在前（下标小于 `scope_len`），之后追加范围外可达的文件
    var nodes: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty;
    for (scope) |f| try nodes.put(r.arena, f, {});
    const scope_len = nodes.count();
    const in_scope = nodes.contains(target);
    // 反向边：被导入的文件 → 导入它的文件
    var reverse: std.AutoHashMapUnmanaged(FileId, std.ArrayList(FileId)) = .empty;
    var n: usize = 0;
    while (n < nodes.count()) : (n += 1) {
        const f = nodes.keys()[n];
        const index = try r.ctx.get(FileIndex.Query, f);
        for (index.imports) |s| {
            const to = try r.resolveImport(f, s) orelse continue;
            const gop = try reverse.getOrPut(r.arena, to);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(r.arena, f);
            if (!in_scope) try nodes.put(r.arena, to, {});
        }
    }
    var seen: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty;
    try seen.put(r.arena, target, {});
    var i: usize = 0;
    while (i < seen.count()) : (i += 1) {
        const f = seen.keys()[i];
        const from = reverse.get(f) orelse continue;
        for (from.items) |x| try seen.put(r.arena, x, {});
    }
    if (in_scope) return seen.keys();
    var out: std.ArrayList(FileId) = .empty;
    for (seen.keys()) |f| {
        if (f == target or nodes.getIndex(f).? < scope_len) try out.append(r.arena, f);
    }
    return out.items;
}

/// 项目范围的反向导入闭包在各成员的种子查找之间共享；文件索引与模块配置仍是实际依赖。
pub const ProjectImporters = struct {
    pub const kind: @import("../db/engine.zig").Kind = .derived;
    pub const Key = FileId;
    pub const Value = []const FileId;

    pub fn compute(ctx: *database.Db.Ctx, target: Key) @import("../db/engine.zig").Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        return ctx.db.gpa.dupe(FileId, try importers(&r, target, try projectFiles(&r)));
    }

    pub fn eql(a: Value, b: Value) bool {
        return std.mem.eql(FileId, a, b);
    }

    pub fn deinit(v: *Value, gpa: std.mem.Allocator) void {
        gpa.free(v.*);
    }
};

const Finder = struct {
    r: *Resolver,
    def: Def,
    name: []const u8,
    out: *std.ArrayList(Reference),
    ambiguous: ?*?Reference,
    /// 最近一个成员的调用点实例（`instances`）
    cached: ?struct { file: FileId, item: u32, list: []const InternPool.Index } = null,

    /// 检查文件 `file` 中的成员 `item`
    fn item(f: *Finder, file: FileId, item_index: u32) resolve.Error!void {
        const r = f.r;
        // decltest 的名字不在 Body 中：`test helper` 的标识符是对 helper 的引用
        if (try r.itemNode(file, item_index)) |node| if (node.kind() == .test_decl) if (node.childToken(.identifier)) |t| {
            const name = try ast.identNameAlloc(r.arena, t.text);
            if (std.mem.eql(u8, name, f.name)) {
                if (try r.resolveContainerName(file, item_index, name)) |def| if (deepEql(def, f.def)) {
                    try f.add(file, t.offset, t.offset + @as(u32, @intCast(t.text.len)));
                };
            }
        };
        if (!try r.mayMention(file, item_index, f.name)) return;
        const body = try r.body(file, item_index);
        if (!mentions(body, f.name)) return;
        const base = try r.itemOffset(file, item_index) orelse return;
        var res: ?*const infer.Result = null;
        for (body.exprs, 0..) |e, i| {
            const id: Body.ExprId = @fromBackingInt(@as(u32, @intCast(i)));
            const range = body.expr_ranges[i];
            switch (e) {
                .name_ref => |n| if (std.mem.eql(u8, n, f.name)) {
                    const d = try r.resolveName(file, item_index, body, body.expr_scopes[i], n) orelse continue;
                    if (deepEql(d, f.def)) try f.add(file, base + range.start, base + range.end);
                },
                .field_access => |fa| if (fa.field != null and std.mem.eql(u8, fa.field.?, f.name)) {
                    const at: Reference = .{ .file = file, .start = base + range.start, .end = base + range.end };
                    // 命名空间的声明直接比较；其他成员（带标签 union 的字段标签、其他目标分支中的声明）由推导给出
                    const ns_def = if (try r.evalNamespace(file, item_index, body, fa.lhs)) |ns| try r.memberDef(ns, f.name) else null;
                    const hit = if (ns_def) |d| deepEql(d, f.def) else try f.refersTo(&res, file, item_index, .{ .e = id }, at);
                    if (hit) try f.addLastToken(file, base + range.end);
                },
                .enum_literal => |n| if (std.mem.eql(u8, n, f.name)) {
                    const at: Reference = .{ .file = file, .start = base + range.start, .end = base + range.end };
                    if (try f.refersTo(&res, file, item_index, .{ .e = id }, at)) try f.addLastToken(file, base + range.end);
                },
                .init => |x| for (x.fields, 0..) |fi, k| {
                    const n = fi.name orelse continue;
                    if (!std.mem.eql(u8, n, f.name)) continue;
                    const at: Reference = .{ .file = file, .start = base + fi.name_range.start, .end = base + fi.name_range.end };
                    if (try f.refersTo(&res, file, item_index, .{ .e = id, .field = k }, at)) try f.add(file, at.start, at.end);
                },
                else => {},
            }
        }
    }

    fn inferred(f: *Finder, res: *?*const infer.Result, file: FileId, item_index: u32) resolve.Error!*const infer.Result {
        if (res.*) |x| return x;
        const x = try f.r.ctx.get(sema.Infer, .{ .owner = try f.r.ownerKey(file, item_index), .mode = .full });
        res.* = x;
        return x;
    }

    /// 推导结果中记录的成员（字段、方法、decl literal、枚举成员、初始化的字段）是否为 `def`。
    /// 泛型函数体内抽象推导求不出时检查全部调用点实例：任一实例指向 `def` 即为引用；同时有实例指向
    /// 其他定义时记为有歧义（`at`）
    fn refersTo(f: *Finder, res: *?*const infer.Result, file: FileId, item_index: u32, l: Lookup, at: Reference) resolve.Error!bool {
        if (l.member(try f.inferred(res, file, item_index))) |m| {
            const d = try keyDef(f.r, m) orelse return false;
            return deepEql(d, f.def);
        }
        const owner = try f.r.ownerKey(file, item_index);
        var hit = false;
        var miss = false;
        for (try f.instances(file, item_index)) |inst| {
            const m = l.member(try f.r.ctx.get(sema.Infer, .{ .owner = owner, .mode = .full, .inst = inst })) orelse continue;
            const d = try keyDef(f.r, m) orelse continue;
            if (deepEql(d, f.def)) hit = true else miss = true;
        }
        if (hit and miss) if (f.ambiguous) |a| if (a.* == null) {
            a.* = at;
        };
        return hit;
    }

    fn instances(f: *Finder, file: FileId, item_index: u32) resolve.Error![]const InternPool.Index {
        if (f.cached) |c| if (c.file == file and c.item == item_index) return c.list;
        const list = try seed.allInstances(f.r, file, item_index);
        f.cached = .{ .file = file, .item = item_index, .list = list };
        return list;
    }

    fn add(f: *Finder, file: FileId, start: u32, end: u32) resolve.Error!void {
        try f.out.append(f.r.arena, .{ .file = file, .start = start, .end = end });
    }

    /// 以表达式末尾的名字（字段名、枚举字面量的名字）为引用位置。直接在源码上回扫，
    /// 不依赖解析结果（可能已被淘汰）
    fn addLastToken(f: *Finder, file: FileId, end: u32) resolve.Error!void {
        const text = (try f.r.ctx.get(database.syntax.SourceText, file)).text;
        const start = lastNameStart(text, end) orelse return;
        try f.add(file, start, end);
    }
};

/// 推导结果中的成员：表达式 `e` 访问的成员，或初始化表达式 `e` 的第 `field` 个字段
const Lookup = struct {
    e: Body.ExprId,
    field: ?usize = null,

    fn member(l: Lookup, res: *const infer.Result) ?hir.OwnerKey {
        if (l.field) |k| {
            for (res.field_refs) |ref| if (ref.init == l.e and ref.index == k) return ref.member;
            return null;
        }
        const i = @backingInt(l.e);
        return if (i < res.members.len) res.members[i] else null;
    }
};

/// Body 中是否出现了名字 `name`（名字引用、字段访问、枚举字面量、初始化字段）
pub fn mentions(body: *const Body, name: []const u8) bool {
    for (body.exprs) |e| switch (e) {
        .name_ref => |n| if (std.mem.eql(u8, n, name)) return true,
        .field_access => |fa| if (fa.field) |n| if (std.mem.eql(u8, n, name)) return true,
        .enum_literal => |n| if (std.mem.eql(u8, n, name)) return true,
        .init => |x| for (x.fields) |fi| if (fi.name) |n| if (std.mem.eql(u8, n, name)) return true,
        else => {},
    };
    return false;
}

/// 结束于 `end` 的名字（标识符或 `@"..."`）的起始位置
fn lastNameStart(text: []const u8, end: u32) ?u32 {
    if (end == 0 or end > text.len) return null;
    if (text[end - 1] == '"') {
        // 内部可能有转义的引号：从同一行中每个 `@"` 起按字符串字面量的规则向后扫描，取恰好结束于 `end` 的
        const line_start = if (std.mem.lastIndexOfScalar(u8, text[0 .. end - 1], '\n')) |i| i + 1 else 0;
        var q = end - 1;
        while (q > line_start + 1) {
            q -= 1;
            if (text[q] == '"' and text[q - 1] == '@' and quotedEnd(text, q) == end) return @intCast(q - 1);
        }
        return null;
    }
    var i = end;
    while (i > 0 and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_')) i -= 1;
    return if (i == end) null else i;
}

/// 起始于 `q`（开引号）的字符串字面量的结束位置（闭引号之后）
fn quotedEnd(text: []const u8, q: usize) ?usize {
    var i = q + 1;
    while (i < text.len) : (i += 1) switch (text[i]) {
        '\\' => i += 1,
        '"' => return i + 1,
        '\n' => return null,
        else => {},
    };
    return null;
}

test lastNameStart {
    try std.testing.expectEqual(4, lastNameStart("a.b.cde", 7));
    try std.testing.expectEqual(2, lastNameStart("x.@\"a b\"", 8));
    try std.testing.expectEqual(null, lastNameStart("a.", 2));
    try std.testing.expectEqual(2, lastNameStart("s.@\"a\\\"b\"", 9));
    try std.testing.expectEqual(2, lastNameStart("s.@\"a\\\\\"", 8));
}

fn keyDef(r: *Resolver, key: hir.OwnerKey) resolve.Error!?Def {
    const tree = try r.itemTree(key.file);
    for (tree.items, 0..) |it, i| if (it.ast_id == key.item) return .{ .item = .{ .file = key.file, .item = @intCast(i) } };
    return null;
}

test {
    _ = @import("search_test.zig");
}
