//! 自动导入：自持有的声明索引、公开导出闭包与安全的源码编辑。

const std = @import("std");
const database = @import("../database.zig");
const engine = @import("../db/engine.zig");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Namespace = resolve.Namespace;
const FileId = @import("../base/Vfs.zig").FileId;
const ItemTree = @import("../syntax/ItemTree.zig");
const ast = @import("../syntax/ast.zig");
const Body = @import("../hir/Body.zig");
const Allocator = std.mem.Allocator;
const deepEql = @import("../util/deep_eql.zig").deepEql;

/// 只为 Zig 源文件建索引：模块的根可以是 `.zon` 或任意数据文件（如 `addAnonymousImport` 引入的 JSON），
/// 按 Zig 解析它们没有意义，大文件还很慢
pub fn isZigSource(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zig");
}

pub const Edit = struct { start: u32, end: u32, text: []const u8 };
pub const Candidate = struct {
    label: []const u8,
    kind: enum { function, constant, variable, module, file },
    filter: []const u8,
    qualifier: []const u8,
    sort: []const u8,
    doc: ?[]const u8 = null,
    import_edit: ?Edit = null,
};
pub const Result = struct { items: []const Candidate, is_incomplete: bool = false };
pub const ChainSeg = struct { name: []const u8 };
const Declaration = struct { file: FileId, item: u32 };
pub const Decl = struct {
    name: []const u8,
    item: u32,
    kind: ItemTree.Item.Kind,
    is_pub: bool,
    is_extern: bool,
    container: u32,
    chain: []const ChainSeg,
    path: []const u8,
    namespace: ?Namespace,
    target: Declaration,
    doc: ?[]const u8,
};
pub const DeclIndex = struct {
    arena: std.heap.ArenaAllocator.State,
    decls: []const Decl,
    public_decls: []const Export,

    pub fn matching(index: *const DeclIndex, prefix: []const u8) []const Decl {
        const start = lowerBound(Decl, index.decls, prefix);
        var end = start;
        while (end < index.decls.len and std.mem.startsWith(u8, index.decls[end].name, prefix)) : (end += 1) {}
        return index.decls[start..end];
    }

    pub fn matchingPublic(index: *const DeclIndex, prefix: []const u8) []const Export {
        const start = lowerBound(Export, index.public_decls, prefix);
        var end = start;
        while (end < index.public_decls.len and std.mem.startsWith(u8, index.public_decls[end].name, prefix)) : (end += 1) {}
        return index.public_decls[start..end];
    }
};

/// 文件级新绑定会影响其他函数的参数、局部变量和捕获；引用本身不构成声明冲突。
pub const BindingNames = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = FileId;
    pub const Value = struct { arena: std.heap.ArenaAllocator.State, names: []const []const u8 };

    pub fn compute(ctx: *database.Db.Ctx, file: Key) engine.Error!Value {
        const gpa = ctx.db.gpa;
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        var names: std.StringHashMapUnmanaged(void) = .empty;
        defer names.deinit(gpa);
        const parse = try ctx.get(database.syntax.ParseFile, file);
        try collect(&names, gpa, scratch.allocator(), parse.rootNode());
        const tree = try ctx.get(database.syntax.FileItemTree, file);
        for (tree.items) |item| if (item.kind == .field) {
            if (item.name) |name| try names.put(gpa, name, {});
        };
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const sorted = try a.alloc([]const u8, names.count());
        var keys = names.keyIterator();
        for (sorted) |*out| out.* = try a.dupe(u8, keys.next().?.*);
        std.mem.sort([]const u8, sorted, {}, struct {
            fn less(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.less);
        return .{ .arena = arena.state, .names = sorted };
    }

    fn collect(names: *std.StringHashMapUnmanaged(void), gpa: Allocator, scratch: Allocator, node: ast.SyntaxNode) Allocator.Error!void {
        if (node.kind() == .name_ref) return;
        var children = node.children();
        while (children.next()) |child| switch (child) {
            .node => |inner| try collect(names, gpa, scratch, inner),
            .token => |token| if (token.kind == .identifier) {
                try names.put(gpa, try ast.identNameAlloc(scratch, token.text), {});
            },
        };
    }

    pub fn contains(value: Value, name: []const u8) bool {
        return std.sort.binarySearch([]const u8, value.names, name, struct {
            fn order(needle: []const u8, item: []const u8) std.math.Order {
                return std.mem.order(u8, needle, item);
            }
        }.order) != null;
    }

    pub fn eql(left: Value, right: Value) bool {
        return deepEql(left.names, right.names);
    }

    pub fn deinit(value: *Value, gpa: Allocator) void {
        var arena = value.arena.promote(gpa);
        arena.deinit();
    }
};

/// 不淘汰的小索引；命名空间分类依赖 Body，不能只依赖不含初始化表达式的 ItemTree。
pub const FileDecls = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = FileId;
    pub const Value = *const DeclIndex;

    pub fn compute(ctx: *database.Db.Ctx, file: Key) engine.Error!Value {
        const gpa = ctx.db.gpa;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        if (!isZigSource(ctx.db.env.vfs.path(file))) {
            const out = try gpa.create(DeclIndex);
            out.* = .{ .arena = arena.state, .decls = &.{}, .public_decls = &.{} };
            return out;
        }
        const a = arena.allocator();
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const temp = scratch.allocator();
        var r: Resolver = .{ .ctx = ctx, .arena = temp };
        const tree = try r.itemTree(file);
        const items = tree.items;
        const containers = tree.containers;
        const namespaces = try temp.alloc(?Namespace, items.len);
        @memset(namespaces, null);
        const targets = try temp.alloc(Declaration, items.len);
        for (items, 0..) |it, i| {
            targets[i] = .{ .file = file, .item = @intCast(i) };
            if (it.kind != .@"const" and it.kind != .@"var") continue;
            var container = it.container;
            var eligible = true;
            while (container != 0) {
                const parent = containers[container].parent_item orelse {
                    eligible = false;
                    break;
                };
                if (items[parent].kind != .@"const" and items[parent].kind != .@"var") {
                    eligible = false;
                    break;
                }
                container = items[parent].container;
            }
            if (eligible) {
                const def: resolve.Def = .{ .item = .{ .file = file, .item = @intCast(i) } };
                namespaces[i] = try r.namespaceOf(def);
                targets[i] = switch (try r.aliasTarget(def)) {
                    .item => |target| .{ .file = target.file, .item = target.item },
                    else => targets[i],
                };
            }
        }
        var decls: std.ArrayList(Decl) = .empty;
        for (items, 0..) |it, i| {
            switch (it.kind) {
                .@"fn", .@"const", .@"var" => {},
                else => continue,
            }
            const name = it.name orelse continue;
            var chain: std.ArrayList(ChainSeg) = .empty;
            var container = it.container;
            var accessible = true;
            while (container != 0) {
                const parent = containers[container].parent_item orelse {
                    accessible = false;
                    break;
                };
                const p = items[parent];
                const ns = namespaces[parent] orelse {
                    accessible = false;
                    break;
                };
                if (ns.file != file or ns.container != container or p.name == null) {
                    accessible = false;
                    break;
                }
                try chain.append(a, .{ .name = try a.dupe(u8, p.name.?) });
                container = p.container;
            }
            if (!accessible) continue;
            std.mem.reverse(ChainSeg, chain.items);
            var path: []const u8 = "";
            for (chain.items) |seg| path = try appendName(a, path, seg.name);
            path = try appendName(a, path, name);
            try decls.append(a, .{
                .name = try a.dupe(u8, name),
                .item = @intCast(i),
                .kind = it.kind,
                .is_pub = it.flags.is_pub,
                .is_extern = it.flags.is_extern,
                .container = it.container,
                .chain = chain.items,
                .path = path,
                .namespace = namespaces[i],
                .target = targets[i],
                .doc = if (it.doc) |d| try a.dupe(u8, d) else null,
            });
        }
        // 普通项目文件只缓存同文件公开别名可达的路径，不展开其他文件或 std。
        const by_item = try temp.alloc(?*const Decl, items.len);
        @memset(by_item, null);
        for (decls.items) |*decl| by_item[decl.item] = decl;
        const Pending = struct { container: u32, path: []const u8, lexical: bool };
        var queue: std.ArrayList(Pending) = .empty;
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        try queue.append(temp, .{ .container = 0, .path = "", .lexical = true });
        try seen.put(temp, 0, {});
        var public_decls: std.ArrayList(Export) = .empty;
        var cursor: usize = 0;
        while (cursor < queue.items.len) : (cursor += 1) {
            const pending = queue.items[cursor];
            for (tree.containerMembers(pending.container)) |item| {
                const decl = by_item[item] orelse continue;
                if (!decl.is_pub) continue;
                const path = if (pending.lexical) decl.path else try appendName(a, pending.path, decl.name);
                try public_decls.append(a, .{
                    .name = decl.name,
                    .path = path,
                    .kind = decl.kind,
                    .is_extern = decl.is_extern,
                    .file = file,
                    .item = decl.item,
                    .target = decl.target,
                    .doc = decl.doc,
                });
                const ns = decl.namespace orelse continue;
                if (ns.file != file) continue;
                const visited = try seen.getOrPut(temp, ns.container);
                if (!visited.found_existing) try queue.append(temp, .{
                    .container = ns.container,
                    .path = path,
                    .lexical = pending.lexical and containers[ns.container].parent_item == decl.item,
                });
            }
        }
        std.mem.sort(Export, public_decls.items, {}, nameLess(Export));
        std.mem.sort(Decl, decls.items, {}, nameLess(Decl));
        const out = try gpa.create(DeclIndex);
        out.* = .{ .arena = arena.state, .decls = decls.items, .public_decls = public_decls.items };
        return out;
    }
    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a.decls, b.decls) and deepEql(a.public_decls, b.public_decls);
    }
    pub fn deinit(v: *Value, gpa: Allocator) void {
        var arena = v.*.arena.promote(gpa);
        arena.deinit();
        gpa.destroy(@constCast(v.*));
    }
};

pub const Export = struct {
    name: []const u8,
    path: []const u8,
    kind: ItemTree.Item.Kind,
    is_extern: bool,
    file: FileId,
    item: u32,
    target: Declaration,
    doc: ?[]const u8,
};
pub const ExportIndex = struct {
    arena: std.heap.ArenaAllocator.State,
    decls: []const Export,
    pub fn matching(index: *const ExportIndex, prefix: []const u8) []const Export {
        const start = lowerBound(Export, index.decls, prefix);
        var end = start;
        while (end < index.decls.len and std.mem.startsWith(u8, index.decls[end].name, prefix)) : (end += 1) {}
        return index.decls[start..end];
    }
};

/// 沿真正的公开成员边遍历，不把依赖内部文件的相对路径泄漏到调用模块。
/// 每个命名空间取最短的公开路径，既终止自引用，也避免别名造成指数级路径展开。
pub const Exports = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = struct { ns: Namespace };
    pub const Value = *const ExportIndex;
    pub fn compute(ctx: *database.Db.Ctx, key: Key) engine.Error!Value {
        const gpa = ctx.db.gpa;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const Pending = struct { ns: Namespace, path: []const u8 };
        var queue: std.ArrayList(Pending) = .empty;
        var seen: std.AutoHashMapUnmanaged(Namespace, void) = .empty;
        try queue.append(a, .{ .ns = key.ns, .path = "" });
        try seen.put(a, key.ns, {});
        var out: std.ArrayList(Export) = .empty;
        var i: usize = 0;
        while (i < queue.items.len) : (i += 1) {
            const current = queue.items[i];
            const index = try ctx.get(FileDecls, current.ns.file);
            // FileDecls 自有字节且不淘汰；这里只把结果复制到本 query 的 arena。
            for (index.decls) |decl| {
                if (decl.container != current.ns.container or !decl.is_pub) continue;
                const path = try appendName(a, current.path, decl.name);
                try out.append(a, .{ .name = try a.dupe(u8, decl.name), .path = path, .kind = decl.kind, .is_extern = decl.is_extern, .file = current.ns.file, .item = decl.item, .target = decl.target, .doc = if (decl.doc) |d| try a.dupe(u8, d) else null });
                if (decl.namespace) |ns| {
                    const entry = try seen.getOrPut(a, ns);
                    if (!entry.found_existing) try queue.append(a, .{ .ns = ns, .path = path });
                }
            }
        }
        std.mem.sort(Export, out.items, {}, nameLess(Export));
        const index = try gpa.create(ExportIndex);
        index.* = .{ .arena = arena.state, .decls = out.items };
        return index;
    }
    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a.decls, b.decls);
    }
    pub fn deinit(v: *Value, gpa: Allocator) void {
        var arena = v.*.arena.promote(gpa);
        arena.deinit();
        gpa.destroy(@constCast(v.*));
    }
};

pub fn complete(r: *Resolver, file: FileId, offset: u32, prefix: []const u8, limit: usize) resolve.Error!Result {
    if (prefix.len == 0) return .{ .items = &.{} };
    var builder: Builder = .{ .r = r, .file = file, .offset = offset, .prefix = prefix, .limit = limit };
    const current = try r.ctx.get(FileDecls, file);
    const graph = try r.ctx.get(database.ModuleGraph.Input, {});
    builder.owner = try r.ownerAt(file, offset, true);
    if (builder.owner) |owner| {
        builder.body = try r.body(file, owner);
        const base = try r.itemOffset(file, owner) orelse offset;
        builder.scope = builder.body.?.scopeAt((offset -| base) -| 1);
    }
    // 别名的规范目标由 FileDecls 缓存；请求只建立当前可见名字的反向映射。
    for (current.decls) |*decl| {
        if (decl.container != 0 or decl.kind != .@"const" or deepEql(decl.target, Declaration{ .file = file, .item = decl.item })) continue;
        const visible = try builder.visible(decl.name) orelse continue;
        if (!deepEql(visible, resolve.Def{ .item = .{ .file = file, .item = decl.item } })) continue;
        const entry = try builder.direct_aliases.getOrPut(r.arena, decl.target);
        if (!entry.found_existing) entry.value_ptr.* = decl;
    }
    // 已有命名空间别名优先，不为同一入口再生成 import。
    for (current.decls) |decl| {
        if (decl.container != 0 or decl.kind != .@"const") continue;
        const ns = decl.namespace orelse continue;
        const visible = try builder.visible(decl.name) orelse continue;
        if (!deepEql(visible, resolve.Def{ .item = .{ .file = file, .item = decl.item } })) continue;
        const root = try renderName(r.arena, decl.name);
        try builder.aliases.put(r.arena, ns, {});
        const exports = try r.ctx.get(Exports, .{ .ns = ns });
        for (exports.matching(prefix)) |declared| {
            if (try builder.reuseDirect(declared.target, declared.name, declared.kind, declared.doc)) continue;
            if (try builder.visible(declared.name) != null) continue;
            try builder.reused.put(r.arena, declared.target, {});
            try builder.add(.{ .label = try joinPath(r.arena, root, declared.path), .kind = candidateKind(declared.kind), .filter = declared.name, .qualifier = root, .sort = "~0", .doc = declared.doc });
        }
        // 同文件可访问私有成员，公开闭包仍由所有请求共享。
        if (ns.file == file) for (current.matching(prefix)) |nested| {
            if (try builder.reuseDirect(nested.target, nested.name, nested.kind, nested.doc)) continue;
            const relative = try localRelative(r.arena, current, ns, nested) orelse continue;
            if (try builder.visible(nested.name) != null) continue;
            try builder.reused.put(r.arena, nested.target, {});
            try builder.add(.{ .label = try joinPath(r.arena, root, relative), .kind = candidateKind(nested.kind), .filter = nested.name, .qualifier = root, .sort = "~0", .doc = nested.doc });
        };
    }
    // 同文件的私有链合法；可见的顶层名由普通补全负责。
    for (current.matching(prefix)) |decl| {
        if (try builder.reuseDirect(decl.target, decl.name, decl.kind, decl.doc)) continue;
        if (decl.chain.len == 0 or try builder.visible(decl.name) != null) continue;
        const root_name = decl.chain[0].name;
        const root_def = try builder.visible(root_name) orelse continue;
        const expected = findRoot(current, root_name) orelse continue;
        if (!deepEql(root_def, resolve.Def{ .item = .{ .file = file, .item = expected.item } })) continue;
        try builder.add(.{ .label = try r.arena.dupe(u8, decl.path), .kind = candidateKind(decl.kind), .filter = decl.name, .qualifier = try r.arena.dupe(u8, decl.chain[0].name), .sort = "~1", .doc = decl.doc });
    }
    if (graph) |g| {
        // 模块名字即使没有任何声明也可补全；生成文件根未知时不提供。
        const names = try g.importNames(r.arena, file);
        for ([_][]const []const u8{ &.{ "std", "builtin" }, names }) |group| for (group) |name| {
            const target = g.importTarget(file, name) orelse continue;
            const ns: Namespace = .{ .file = target, .container = 0 };
            const spec = try r.arena.dupe(u8, name);
            if (!builder.aliases.contains(ns) and std.mem.startsWith(u8, name, prefix) and try builder.visible(name) == null)
                try builder.importCandidate(name, .module, false, spec, "", null, "~2");
            try builder.exported(ns, spec);
        };
        // 项目文件只查询小索引的前缀区间，不在按键路径扫描 ItemTree/Body。
        for (g.files) |entry| {
            if (entry.file == file or entry.module == database.ModuleGraph.std_module) continue;
            const path = r.ctx.db.env.vfs.path(entry.file);
            if (!isZigSource(path)) continue;
            const index = try r.ctx.get(FileDecls, entry.file);
            const matches = index.matchingPublic(prefix);
            const ns: Namespace = .{ .file = entry.file, .container = 0 };
            const basename = std.fs.path.basename(path);
            const stem = basename[0 .. basename.len - ".zig".len];
            if (matches.len == 0 and !std.mem.startsWith(u8, stem, prefix)) continue;
            const spec = try importSpec(r, g, file, entry.file) orelse continue;
            if (std.mem.startsWith(u8, stem, prefix) and !builder.aliases.contains(ns) and try builder.visible(stem) == null)
                try builder.importCandidate(stem, .file, false, spec, "", null, "~3");
            if (builder.aliases.contains(ns)) continue;
            for (matches) |decl| {
                if (try builder.reuseDirect(decl.target, decl.name, decl.kind, decl.doc)) continue;
                if (builder.reused.contains(decl.target) or try builder.visible(decl.name) != null) continue;
                try builder.importCandidate(decl.name, candidateKind(decl.kind), decl.is_extern, spec, decl.path, decl.doc, if (std.mem.indexOfScalar(u8, decl.path, '.') == null) "~3" else "~4");
            }
        }
    }
    std.mem.sort(Candidate, builder.items.items, {}, candidateLess);
    for (builder.items.items) |*item| {
        item.filter = try r.arena.dupe(u8, item.filter);
        if (item.doc) |doc| item.doc = try r.arena.dupe(u8, doc);
    }
    return .{ .items = builder.items.items, .is_incomplete = builder.incomplete };
}

const Builder = struct {
    r: *Resolver,
    file: FileId,
    offset: u32,
    prefix: []const u8,
    limit: usize,
    owner: ?u32 = null,
    body: ?*const Body = null,
    scope: Body.ScopeId = .root,
    aliases: std.AutoHashMapUnmanaged(Namespace, void) = .empty,
    direct_aliases: std.AutoHashMapUnmanaged(Declaration, *const Decl) = .empty,
    reused: std.AutoHashMapUnmanaged(Declaration, void) = .empty,
    visible_names: std.StringHashMapUnmanaged(?resolve.Def) = .empty,
    items: std.ArrayList(Candidate) = .empty,
    incomplete: bool = false,
    insertion: ?u32 = null,
    insertion_blocked: bool = false,

    fn visible(b: *Builder, name: []const u8) resolve.Error!?resolve.Def {
        if (b.visible_names.get(name)) |result| return result;
        var found: ?resolve.Def = null;
        if (b.owner) |owner| {
            if (b.body.?.lookup(b.scope, name)) |binding| {
                found = .{ .local = .{ .file = b.file, .item = owner, .binding = binding } };
            } else if ((try b.r.itemTree(b.file)).items[owner].container != 0) {
                found = try b.r.resolveContainerName(b.file, owner, name);
            }
        }
        if (found == null) {
            const index = try b.r.ctx.get(FileDecls, b.file);
            if (findRoot(index, name)) |decl| found = .{ .item = .{ .file = b.file, .item = decl.item } };
        }
        try b.visible_names.put(b.r.arena, name, found);
        return found;
    }

    fn bindingConflict(b: *Builder, name: []const u8) resolve.Error!bool {
        if (!(try b.r.ctx.get(database.FileIndex.Query, b.file)).contains(name)) return false;
        return BindingNames.contains(try b.r.ctx.get(BindingNames, b.file), name);
    }
    fn reuseDirect(b: *Builder, target: Declaration, name: []const u8, kind: ItemTree.Item.Kind, doc: ?[]const u8) resolve.Error!bool {
        const alias = b.direct_aliases.get(target) orelse return false;
        // 别名与目标共享前缀时，继续输入后须重新选择过滤名字，不能沿用另一条拼写。
        if (!std.mem.eql(u8, alias.name, name) and std.mem.startsWith(u8, alias.name, b.prefix)) b.incomplete = true;
        try b.add(.{ .label = try renderName(b.r.arena, alias.name), .kind = candidateKind(kind), .filter = name, .qualifier = "", .sort = "~0", .doc = doc });
        try b.reused.put(b.r.arena, target, {});
        return true;
    }
    fn add(b: *Builder, candidate: Candidate) resolve.Error!void {
        for (b.items.items) |existing| {
            if (std.mem.eql(u8, existing.label, candidate.label) and std.mem.eql(u8, existing.qualifier, candidate.qualifier)) return;
        }
        if (b.items.items.len < b.limit) {
            try b.items.append(b.r.arena, candidate);
        } else {
            b.incomplete = true;
            // 保留排序最好的有限个结果；截断不受图中 FileId 顺序影响。
            if (b.limit == 0) return;
            var worst: usize = 0;
            for (b.items.items, 0..) |item, i| if (candidateLess({}, b.items.items[worst], item)) {
                worst = i;
            };
            if (candidateLess({}, candidate, b.items.items[worst])) b.items.items[worst] = candidate;
        }
    }
    fn exported(b: *Builder, ns: Namespace, spec: []const u8) resolve.Error!void {
        if (b.aliases.contains(ns)) return;
        const index = try b.r.ctx.get(Exports, .{ .ns = ns });
        for (index.matching(b.prefix)) |decl| {
            if (try b.reuseDirect(decl.target, decl.name, decl.kind, decl.doc)) continue;
            if (b.reused.contains(decl.target) or try b.visible(decl.name) != null) continue;
            try b.importCandidate(decl.name, candidateKind(decl.kind), decl.is_extern, spec, decl.path, decl.doc, if (std.mem.indexOfScalar(u8, decl.path, '.') == null) "~3" else "~4");
        }
    }
    fn importCandidate(b: *Builder, name: []const u8, kind: @FieldType(Candidate, "kind"), is_extern: bool, spec: []const u8, path: []const u8, doc: ?[]const u8, rank: []const u8) resolve.Error!void {
        const a = b.r.arena;
        const qualifier = if (path.len == 0) spec else try std.fmt.allocPrint(a, "{s}:{s}", .{ spec, path });
        var binding = name;
        var binding_path = path;
        var direct = false;
        // 运行期存储不能复制到 comptime 常量；extern const 仍保留只读补全类别。
        const label = if (kind == .variable or (is_extern and kind == .constant) or try b.bindingConflict(name)) blk: {
            const base = std.fs.path.basename(spec);
            const namespace = if (std.mem.endsWith(u8, base, ".zig")) base[0 .. base.len - 4] else base;
            if (try b.bindingConflict(namespace) or try b.visible(namespace) != null) {
                direct = true;
                break :blk try std.fmt.allocPrint(a, "@import(\"{f}\"){s}{s}", .{
                    std.zig.fmtString(spec), if (path.len == 0) "" else ".", path,
                });
            }
            binding = namespace;
            binding_path = "";
            break :blk if (path.len == 0) try renderName(a, namespace) else try std.fmt.allocPrint(a, "{f}.{s}", .{ std.zig.fmtId(namespace), path });
        } else try renderName(a, name);
        if (!direct) {
            if (b.insertion == null) {
                b.insertion = try insertionOffset(b.r, b.file);
                const root = (try b.r.ctx.get(database.syntax.ParseFile, b.file)).rootNode();
                if (root.tokenAtOffset(b.offset -| 1)) |token| {
                    const end = token.offset + @as(u32, @intCast(token.text.len));
                    b.insertion_blocked = token.kind == .identifier and token.offset <= b.insertion.? and b.insertion.? < end;
                }
            }
            if (b.insertion_blocked) return;
        }
        const edit: ?Edit = if (direct) null else blk: {
            const offset = b.insertion.?;
            const source = (try b.r.ctx.get(database.syntax.SourceText, b.file)).text;
            const newline: []const u8 = if (offset > 0 and source[offset - 1] != '\n') "\n" else "";
            const text = try std.fmt.allocPrint(a, "{s}const {f} = @import(\"{f}\"){s}{s};\n", .{
                newline, std.zig.fmtId(binding), std.zig.fmtString(spec), if (binding_path.len == 0) "" else ".", binding_path,
            });
            break :blk .{ .start = offset, .end = offset, .text = text };
        };
        try b.add(.{ .label = label, .kind = kind, .filter = name, .qualifier = qualifier, .sort = try std.fmt.allocPrint(a, "~2:{d}:{s}:{d:0>6}:{d:0>4}:{s}", .{
            if (!std.mem.endsWith(u8, spec, ".zig")) @as(u8, 2) else if (std.mem.indexOfScalar(u8, spec, '/') == null) @as(u8, 0) else @as(u8, 1),
            rank,
            spec.len + path.len,
            name.len,
            qualifier,
        }), .doc = doc, .import_edit = edit });
    }
};

fn importSpec(r: *Resolver, graph: *const database.ModuleGraph, from: FileId, target: FileId) resolve.Error!?[]const u8 {
    for ([_][]const u8{ "std", "builtin" }) |name| if (graph.importTarget(from, name) == target) return name;
    for (try graph.importNames(r.arena, from)) |name| if (graph.importTarget(from, name) == target) return try r.arena.dupe(u8, name);
    const src = graph.entry(from) orelse return null;
    const dst = graph.entry(target) orelse return null;
    if (src.module != dst.module or src.module == database.ModuleGraph.std_module) return null;
    const root = graph.modules[src.module].root orelse return null;
    const vfs = r.ctx.db.env.vfs;
    const root_dir = std.fs.path.dirname(vfs.path(root)) orelse return null;
    const target_path = vfs.path(target);
    if (!vfs.isUnder(vfs.path(from), root_dir) or !vfs.isUnder(target_path, root_dir)) return null;
    const dir = std.fs.path.dirname(vfs.path(from)) orelse return null;
    const relative = try std.fs.path.relativeAlloc(r.arena, root_dir, null, dir, target_path);
    for (relative) |*c| if (c.* == '\\') {
        c.* = '/';
    };
    return relative;
}

fn insertionOffset(r: *Resolver, file: FileId) resolve.Error!u32 {
    const parse = try r.ctx.get(database.syntax.ParseFile, file);
    var last: ?u32 = null;
    var children = parse.rootNode().children();
    while (children.nextNode()) |node| {
        if (node.kind() != .var_decl or node.childToken(.keyword_const) == null) continue;
        const init = (ast.VarDecl{ .syntax = node }).initExpr() orelse continue;
        if (importInitializer(init)) last = node.range().end;
    }
    const source = (try r.ctx.get(database.syntax.SourceText, file)).text;
    if (last) |end| {
        var pos: usize = end;
        // 保留 import 同行的注释；下一行插入，不吞掉下一条声明。
        while (pos < source.len and (source[pos] == ' ' or source[pos] == '\t' or source[pos] == '\r')) : (pos += 1) {}
        if (std.mem.startsWith(u8, source[pos..], "//")) while (pos < source.len and source[pos] != '\n') : (pos += 1) {};
        if (pos < source.len and source[pos] == '\n') pos += 1;
        return @intCast(pos);
    }
    var pos: usize = 0;
    var docs_end: usize = 0;
    while (pos < source.len) {
        const end = if (std.mem.indexOfScalarPos(u8, source, pos, '\n')) |e| e + 1 else source.len;
        const line = std.mem.trim(u8, source[pos..end], " \t\r\n");
        if (std.mem.startsWith(u8, line, "//!")) {
            docs_end = end;
        } else if (line.len != 0 and !std.mem.startsWith(u8, line, "//")) break;
        pos = end;
    }
    return @intCast(docs_end);
}

fn importInitializer(node: ast.SyntaxNode) bool {
    if (node.kind() == .builtin_call) return node.childToken(.builtin) != null and std.mem.eql(u8, node.childToken(.builtin).?.text, "@import");
    if (node.kind() == .field_access or node.kind() == .paren_expr) {
        var children = node.children();
        const lhs = children.nextNode() orelse return false;
        return importInitializer(lhs);
    }
    return false;
}

fn findRoot(index: *const DeclIndex, name: []const u8) ?Decl {
    const start = lowerBound(Decl, index.decls, name);
    for (index.decls[start..]) |decl| {
        if (!std.mem.eql(u8, decl.name, name)) break;
        if (decl.container == 0) return decl;
    }
    return null;
}
fn localRelative(a: Allocator, index: *const DeclIndex, ns: Namespace, decl: Decl) Allocator.Error!?[]const u8 {
    if (ns.container == 0) return decl.path;
    for (index.decls) |parent| {
        if (parent.namespace) |target| if (deepEql(target, ns)) {
            if (decl.path.len > parent.path.len and std.mem.startsWith(u8, decl.path, parent.path) and decl.path[parent.path.len] == '.')
                return try a.dupe(u8, decl.path[parent.path.len + 1 ..]);
        };
    }
    return null;
}
fn candidateKind(kind: ItemTree.Item.Kind) @FieldType(Candidate, "kind") {
    return switch (kind) {
        .@"fn" => .function,
        .@"var" => .variable,
        else => .constant,
    };
}
fn renderName(a: Allocator, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{f}", .{std.zig.fmtId(name)});
}
fn appendName(a: Allocator, path: []const u8, name: []const u8) Allocator.Error![]const u8 {
    return joinPath(a, path, try renderName(a, name));
}
fn joinPath(a: Allocator, lhs: []const u8, rhs: []const u8) Allocator.Error![]const u8 {
    if (lhs.len == 0) return a.dupe(u8, rhs);
    return std.fmt.allocPrint(a, "{s}.{s}", .{ lhs, rhs });
}
fn nameLess(comptime T: type) fn (void, T, T) bool {
    return struct {
        fn less(_: void, a: T, b: T) bool {
            const order = std.mem.order(u8, a.name, b.name);
            if (order != .eq) return order == .lt;
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.less;
}
fn lowerBound(comptime T: type, items: []const T, name: []const u8) usize {
    var low: usize = 0;
    var high = items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (std.mem.lessThan(u8, items[mid].name, name)) low = mid + 1 else high = mid;
    }
    return low;
}
fn candidateLess(_: void, a: Candidate, b: Candidate) bool {
    const order = std.mem.order(u8, a.sort, b.sort);
    if (order != .eq) return order == .lt;
    const labels = std.mem.order(u8, a.label, b.label);
    if (labels != .eq) return labels == .lt;
    return std.mem.lessThan(u8, a.qualifier, b.qualifier);
}

test {
    _ = @import("imports_test.zig");
}
