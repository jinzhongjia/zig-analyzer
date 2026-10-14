//! 引用查找（设计 §10.2 `search.find_refs`）：按名字粗筛候选文件，再逐处精确解析确认。
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
const infer = @import("../sema/infer.zig");
const FileIndex = @import("FileIndex.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const deepEql = @import("../util/deep_eql.zig").deepEql;

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

    var finder: Finder = .{ .r = r, .def = def, .name = name, .out = &out };
    switch (def) {
        .local => |l| {
            if (opts.only_file) |f| if (f != l.file) return out.items;
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

/// 在 `scope` 中能经由 `@import` 链到达 `target` 的文件（含 `target` 自身）
pub fn importers(r: *Resolver, target: FileId, scope: []const FileId) resolve.Error![]const FileId {
    // 反向边：被导入的文件 → 导入它的文件
    var reverse: std.AutoHashMapUnmanaged(FileId, std.ArrayList(FileId)) = .empty;
    for (scope) |f| {
        const index = try r.ctx.get(FileIndex.Query, f);
        for (index.imports) |s| {
            const to = try r.resolveImport(f, s) orelse continue;
            const gop = try reverse.getOrPut(r.arena, to);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(r.arena, f);
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
    return seen.keys();
}

const Finder = struct {
    r: *Resolver,
    def: Def,
    name: []const u8,
    out: *std.ArrayList(Reference),

    /// 检查文件 `file` 中的成员 `item`
    fn item(f: *Finder, file: FileId, item_index: u32) resolve.Error!void {
        const r = f.r;
        const body = try r.body(file, item_index);
        if (!mentions(body, f.name)) return;
        const node = try r.itemNode(file, item_index) orelse return;
        const base = node.offset;
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
                    const d = if (try r.evalNamespace(file, item_index, body, fa.lhs)) |ns|
                        try r.memberDef(ns, f.name)
                    else
                        try f.viaTypes(&res, file, item_index, id);
                    if (d != null and deepEql(d.?, f.def)) try f.addLastToken(file, base + range.end);
                },
                .enum_literal => |n| if (std.mem.eql(u8, n, f.name)) {
                    const d = try f.viaTypes(&res, file, item_index, id);
                    if (d != null and deepEql(d.?, f.def)) try f.addLastToken(file, base + range.end);
                },
                .init => |x| for (x.fields, 0..) |fi, k| {
                    const n = fi.name orelse continue;
                    if (!std.mem.eql(u8, n, f.name)) continue;
                    const result = try f.inferred(&res, file, item_index);
                    for (result.field_refs) |ref| {
                        if (ref.init != id or ref.index != k) continue;
                        const d = try keyDef(r, ref.member) orelse continue;
                        if (deepEql(d, f.def)) try f.add(file, base + fi.name_range.start, base + fi.name_range.end);
                    }
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

    /// 推导结果中记录的成员（字段、方法、decl literal、枚举成员）
    fn viaTypes(f: *Finder, res: *?*const infer.Result, file: FileId, item_index: u32, e: Body.ExprId) resolve.Error!?Def {
        const result = try f.inferred(res, file, item_index);
        const i = @backingInt(e);
        if (i >= result.members.len) return null;
        return keyDef(f.r, result.members[i] orelse return null);
    }

    fn add(f: *Finder, file: FileId, start: u32, end: u32) resolve.Error!void {
        try f.out.append(f.r.arena, .{ .file = file, .start = start, .end = end });
    }

    /// 以表达式的最后一个 token（字段名、枚举字面量的名字）为引用位置
    fn addLastToken(f: *Finder, file: FileId, end: u32) resolve.Error!void {
        const root = (try f.r.ctx.get(database.syntax.ParseFile, file)).rootNode();
        const t = root.tokenAtOffset(end - 1) orelse return;
        try f.add(file, t.offset, t.offset + @as(u32, @intCast(t.text.len)));
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

fn keyDef(r: *Resolver, key: hir.OwnerKey) resolve.Error!?Def {
    const tree = try r.itemTree(key.file);
    for (tree.items, 0..) |it, i| if (it.ast_id == key.item) return .{ .item = .{ .file = key.file, .item = @intCast(i) } };
    return null;
}

test {
    _ = @import("search_test.zig");
}
