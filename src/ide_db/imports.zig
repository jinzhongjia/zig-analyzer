//! 自动导入：自持有的声明索引、公开导出闭包与安全的源码编辑。
//!
//! `FileDecls` 由 ItemTree 得出可从文件根访问的声明，`FileLinks` 记录各声明指向的命名空间与别名的规范目标，
//! `Exports` 沿公开成员展开闭包。命名空间与别名都由 `Resolver.namespaceOf` / `aliasTarget` 求值，与跳转、
//! hover 等功能是同一份实现；条件形式（`if` / `switch`）的命名空间由推导求出。

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
const sema_queries = @import("../sema/queries.zig");
const hir = @import("../hir/queries.zig");
const Allocator = std.mem.Allocator;
const deepEql = @import("../util/deep_eql.zig").deepEql;
const mem = @import("../util/mem.zig");
const organize_imports = @import("organize_imports.zig");
const fuzzy = @import("fuzzy.zig");
const symbol_kind = @import("symbol_kind.zig");

pub const Edit = struct { start: u32, end: u32, text: []const u8 };
pub const Candidate = struct {
    label: []const u8,
    /// 声明的种类见 `symbol_kind`；`module`、`file` 为新增 import 的模块与文件本身
    kind: enum { function, constant, variable, namespace, @"struct", @"enum", type, module, file },
    filter: []const u8,
    qualifier: []const u8,
    /// 匹配分（见 `fuzzy`）乘以来源的权重与路径的深度系数，越大越靠前
    score: f32,
    doc: ?[]const u8 = null,
    import_edit: ?Edit = null,
    target: Target,
};
pub const Result = struct { items: []const Candidate, is_incomplete: bool = false };
pub const Declaration = struct { file: FileId, item: u32 };
/// 候选所指的定义：补全项被选中时据此给出签名、文档与位置
pub const Target = union(enum) {
    decl: Declaration,
    /// 模块或文件本身
    file: FileId,
};

/// 别名链与成员访问的最大求值深度，与 `Resolver` 的别名链上限相同
const max_depth = 100;

/// 补全对命名空间之下至多这么多段的路径做模糊匹配（`std.mem.eql` 在 `std` 之下 2 段），更深的只按名字的前缀匹配
pub const shallow_depth = 2;

/// 只为 Zig 源文件建索引：模块的根可以是 `.zon` 或任意数据文件（如 `addAnonymousImport` 引入的 JSON），
/// 按 Zig 解析它们没有意义，大文件还很慢
pub fn isZigSource(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zig");
}

// ── 文件的声明 ─────────────────────────────────────────────────────

pub const Decl = struct {
    name: []const u8,
    item: u32,
    kind: ItemTree.Item.Kind,
    is_pub: bool,
    is_extern: bool,
    container: u32,
    /// 顶层祖先（经由它访问）的名字；顶层声明为 null
    root: ?[]const u8,
    /// 从文件根访问它的路径（各段已转义）
    path: []const u8,
    /// 指向本文件中的容器时为该容器（容器字面量、`@This()`、指向同文件容器的别名）；指向其他文件的由
    /// `Eval` 求值
    local: ?u32,
    doc: ?[]const u8,
    /// 按语法能确定的种类（const 与 var），补全的候选据此显示种类，不必为它求声明的类型
    form: symbol_kind.Form = .unknown,
};

/// 经由公开成员（包括指向同文件私有容器的公开别名）从文件根可达的声明：`decl` 为 `DeclIndex.decls` 的下标
pub const Public = struct { decl: u32, path: []const u8 };

/// 不能从文件根访问的容器与文件根的外层容器
const no_container = std.math.maxInt(u32);

pub const DeclIndex = struct {
    arena: std.heap.ArenaAllocator.State,
    /// 按名字排序（`orderName`）
    decls: []const Decl = &.{},
    /// 按名字排序（`orderName`）
    public_decls: []const Public = &.{},
    /// `decls` 的下标，按 item 排序
    by_item: []const u32 = &.{},
    /// `decls` 的下标按容器分组、组内按名字排序：容器 c 的成员为 `members[member_start[c]..member_start[c + 1]]`
    members: []const u32 = &.{},
    member_start: []const u32 = &.{},
    /// 各容器的外层容器（定义它的成员所在的容器），按容器下标
    outer: []const u32 = &.{},
    /// 各容器从文件根开始的词法路径（已转义）；根容器为 ""，不可达的容器为 null
    container_paths: []const ?[]const u8 = &.{},

    /// 名字以 `prefix` 开头（不区分大小写）的声明在 `decls` 中的下标区间
    pub fn matching(index: *const DeclIndex, prefix: []const u8) struct { start: usize, end: usize } {
        const start = prefixStart(Decl, index.decls, prefix);
        var end = start;
        while (end < index.decls.len and std.ascii.startsWithIgnoreCase(index.decls[end].name, prefix)) : (end += 1) {}
        return .{ .start = start, .end = end };
    }

    pub fn matchingPublic(index: *const DeclIndex, prefix: []const u8) []const Public {
        var low: usize = 0;
        var high = index.public_decls.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (std.ascii.lessThanIgnoreCase(index.decls[index.public_decls[mid].decl].name, prefix)) low = mid + 1 else high = mid;
        }
        var end = low;
        while (end < index.public_decls.len and std.ascii.startsWithIgnoreCase(index.decls[index.public_decls[end].decl].name, prefix)) : (end += 1) {}
        return index.public_decls[low..end];
    }

    pub fn byItem(index: *const DeclIndex, item: u32) ?*const Decl {
        var low: usize = 0;
        var high = index.by_item.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const decl = &index.decls[index.by_item[mid]];
            if (decl.item == item) return decl;
            if (decl.item < item) low = mid + 1 else high = mid;
        }
        return null;
    }

    pub fn containerMembers(index: *const DeclIndex, container: u32) []const u32 {
        if (container + 1 >= index.member_start.len) return &.{};
        return index.members[index.member_start[container]..index.member_start[container + 1]];
    }

    /// 容器中名为 `name` 的声明
    pub fn member(index: *const DeclIndex, container: u32, name: []const u8) ?*const Decl {
        const members = index.containerMembers(container);
        var low: usize = 0;
        var high = members.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const decl = &index.decls[members[mid]];
            switch (orderName(decl.name, name)) {
                .eq => return decl,
                .lt => low = mid + 1,
                .gt => high = mid,
            }
        }
        return null;
    }

    /// 容器层级的作用域：从 `container` 起向外查找名字
    pub fn lookup(index: *const DeclIndex, container: u32, name: []const u8) ?*const Decl {
        var c = container;
        while (c != no_container and c < index.outer.len) : (c = index.outer[c]) {
            if (index.member(c, name)) |decl| return decl;
        }
        return null;
    }
};

/// 文件级新绑定只需避开真正的声明：容器成员（ItemTree）、其他函数的参数、局部变量与捕获（函数体）。
/// 成员访问、初始化字段名、标签、类型引用与普通名字引用都不是声明，不构成冲突；按键时不必扫描并散列整棵
/// 语法树里的所有标识符。
pub const BindingNames = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = FileId;
    pub const Value = struct { arena: std.heap.ArenaAllocator.State, names: []const []const u8 };

    pub fn compute(ctx: *database.Db.Ctx, file: Key) engine.Error!Value {
        const gpa = ctx.db.gpa;
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const temp = scratch.allocator();
        var list: std.ArrayList([]const u8) = .empty;
        const parse = try ctx.get(database.syntax.ParseFile, file);
        try collect(&list, temp, parse.rootNode());
        const tree = try ctx.get(database.syntax.FileItemTree, file);
        for (tree.items) |item| if (item.kind != .@"test") if (item.name) |name| try list.append(temp, name);
        std.mem.sort([]const u8, list.items, {}, struct {
            fn less(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.lessThan(u8, left, right);
            }
        }.less);
        var unique: usize = 0;
        for (list.items) |name| {
            if (unique != 0 and std.mem.eql(u8, list.items[unique - 1], name)) continue;
            list.items[unique] = name;
            unique += 1;
        }
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const sorted = try a.alloc([]const u8, unique);
        for (list.items[0..unique], sorted) |name, *out| out.* = try a.dupe(u8, name);
        return .{ .arena = arena.state, .names = sorted };
    }

    fn collect(names: *std.ArrayList([]const u8), scratch: Allocator, node: ast.SyntaxNode) Allocator.Error!void {
        switch (node.kind()) {
            .param => if ((ast.Param{ .syntax = node }).name()) |token| try names.append(scratch, try ast.identNameAlloc(scratch, token.text)),
            .var_decl => if ((ast.VarDecl{ .syntax = node }).name()) |token| try names.append(scratch, try ast.identNameAlloc(scratch, token.text)),
            .payload => {
                var bindings = (ast.Payload{ .syntax = node }).bindings();
                while (bindings.next()) |binding| try names.append(scratch, try ast.identNameAlloc(scratch, binding.name.text));
                return;
            },
            else => {},
        }
        var children = node.children();
        while (children.nextNode()) |child| try collect(names, scratch, child);
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

    pub fn bytes(value: Value) usize {
        return mem.arenaBytes(value.arena);
    }

    pub fn deinit(value: *Value, gpa: Allocator) void {
        var arena = value.arena.promote(gpa);
        arena.deinit();
    }
};

/// 不淘汰的小索引：本文件的 ItemTree，以及各容器是否从文件根可达（由 `Resolver` 求值）
pub const FileDecls = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = FileId;
    pub const Value = *const DeclIndex;

    pub fn compute(ctx: *database.Db.Ctx, file: Key) engine.Error!Value {
        const gpa = ctx.db.gpa;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        var index: DeclIndex = .{ .arena = undefined };
        if (isZigSource(ctx.db.env.vfs.path(file))) {
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
            var b: DeclBuilder = .{
                .r = &r,
                .file = file,
                .tree = try ctx.get(database.syntax.FileItemTree, file),
                .a = arena.allocator(),
                .temp = scratch.allocator(),
            };
            index = try b.build();
        }
        index.arena = arena.state;
        const out = try gpa.create(DeclIndex);
        out.* = index;
        return out;
    }

    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a.decls, b.decls) and deepEql(a.public_decls, b.public_decls) and deepEql(a.by_item, b.by_item) and
            deepEql(a.members, b.members) and deepEql(a.member_start, b.member_start) and deepEql(a.outer, b.outer) and
            deepEql(a.container_paths, b.container_paths);
    }
    pub fn bytes(v: Value) usize {
        return @sizeOf(DeclIndex) + mem.arenaBytes(v.arena);
    }
    pub fn deinit(v: *Value, gpa: Allocator) void {
        var arena = v.*.arena.promote(gpa);
        arena.deinit();
        gpa.destroy(@constCast(v.*));
    }
};

const DeclBuilder = struct {
    r: *Resolver,
    file: FileId,
    tree: *const ItemTree,
    /// 结果的 arena
    a: Allocator,
    temp: Allocator,
    /// 容器能否从文件根访问：具名 const / var 的值就是这个容器（容器字面量直接初始化）时才能
    reachable: []?bool = undefined,
    names: []?[]const u8 = undefined,
    paths: []?[]const u8 = undefined,

    fn build(b: *DeclBuilder) resolve.Error!DeclIndex {
        const items = b.tree.items;
        const containers = b.tree.containers;
        b.reachable = try b.temp.alloc(?bool, containers.len);
        @memset(b.reachable, null);
        b.names = try b.temp.alloc(?[]const u8, items.len);
        @memset(b.names, null);
        b.paths = try b.temp.alloc(?[]const u8, items.len);
        @memset(b.paths, null);

        var list: std.ArrayList(Decl) = .empty;
        for (items, 0..) |it, i| {
            switch (it.kind) {
                .@"fn", .@"const", .@"var" => {},
                else => continue,
            }
            if (it.name == null or !try b.isReachable(it.container)) continue;
            const item: u32 = @intCast(i);
            // 方法（第一个参数是所在容器的值或指针）经由实例调用，不作为可导入的函数
            if (it.kind == .@"fn" and it.container != 0 and try b.isMethod(item)) continue;
            try list.append(b.temp, .{
                .name = try b.ownName(item),
                .item = item,
                .kind = it.kind,
                .is_pub = it.flags.is_pub,
                .is_extern = it.flags.is_extern,
                .container = it.container,
                .root = try b.rootName(it.container),
                .path = try b.pathOf(item),
                .local = try b.localNamespace(item),
                .doc = if (it.doc) |d| try b.a.dupe(u8, d) else null,
                .form = if (it.kind == .@"fn") .unknown else if (try b.r.itemNode(b.file, item)) |node| symbol_kind.declForm(node) else .unknown,
            });
        }
        std.mem.sort(Decl, list.items, {}, nameLess(Decl));
        const decls = try b.a.dupe(Decl, list.items);

        const by_item = try b.a.alloc(u32, decls.len);
        for (by_item, 0..) |*d, i| d.* = @intCast(i);
        std.mem.sort(u32, by_item, decls, struct {
            fn less(all: []const Decl, x: u32, y: u32) bool {
                return all[x].item < all[y].item;
            }
        }.less);

        // decls 已按名字排序，依次放入各容器的分组，组内仍按名字排序
        const member_start = try b.a.alloc(u32, containers.len + 1);
        @memset(member_start, 0);
        for (decls) |d| member_start[d.container + 1] += 1;
        for (1..member_start.len) |i| member_start[i] += member_start[i - 1];
        const members = try b.a.alloc(u32, decls.len);
        const fill = try b.temp.dupe(u32, member_start[0..containers.len]);
        for (decls, 0..) |d, i| {
            members[fill[d.container]] = @intCast(i);
            fill[d.container] += 1;
        }

        const outer = try b.a.alloc(u32, containers.len);
        for (containers, outer, 0..) |c, *o, i| {
            const parent = c.parent_item orelse {
                o.* = no_container;
                continue;
            };
            o.* = if (try b.isReachable(@intCast(i))) items[parent].container else no_container;
        }

        const container_paths = try b.a.alloc(?[]const u8, containers.len);
        @memset(container_paths, null);
        if (containers.len != 0) container_paths[0] = "";
        for (containers, 0..) |c, i| {
            if (i == 0 or !try b.isReachable(@intCast(i))) continue;
            const parent = c.parent_item orelse continue;
            container_paths[i] = try b.pathOf(parent);
        }

        var index: DeclIndex = .{
            .arena = undefined,
            .decls = decls,
            .by_item = by_item,
            .members = members,
            .member_start = member_start,
            .outer = outer,
            .container_paths = container_paths,
        };
        index.public_decls = try b.publicPaths(&index);
        return index;
    }

    /// 经由公开成员从文件根可达的路径：公开别名可以指向本文件的私有容器，不展开到其他文件
    fn publicPaths(b: *DeclBuilder, index: *const DeclIndex) Allocator.Error![]const Public {
        const Pending = struct { container: u32, path: []const u8, lexical: bool };
        var queue: std.ArrayList(Pending) = .empty;
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        try queue.append(b.temp, .{ .container = 0, .path = "", .lexical = true });
        try seen.put(b.temp, 0, {});
        var list: std.ArrayList(Public) = .empty;
        var cursor: usize = 0;
        while (cursor < queue.items.len) : (cursor += 1) {
            const pending = queue.items[cursor];
            for (index.containerMembers(pending.container)) |d| {
                const decl = index.decls[d];
                if (!decl.is_pub) continue;
                const path = if (pending.lexical) decl.path else try appendName(b.a, pending.path, decl.name);
                try list.append(b.temp, .{ .decl = d, .path = path });
                const ns = decl.local orelse continue;
                const visited = try seen.getOrPut(b.temp, ns);
                if (!visited.found_existing) try queue.append(b.temp, .{
                    .container = ns,
                    .path = path,
                    .lexical = pending.lexical and b.tree.containers[ns].parent_item == decl.item,
                });
            }
        }
        std.mem.sort(Public, list.items, index.decls, struct {
            fn less(decls: []const Decl, x: Public, y: Public) bool {
                const order = orderName(decls[x.decl].name, decls[y.decl].name);
                if (order != .eq) return order == .lt;
                return std.mem.lessThan(u8, x.path, y.path);
            }
        }.less);
        return b.a.dupe(Public, list.items);
    }

    fn isReachable(b: *DeclBuilder, container: u32) resolve.Error!bool {
        if (container == 0) return true;
        if (b.reachable[container]) |known| return known;
        // 先记为不可达：自引用的结构不会无限递归
        b.reachable[container] = false;
        const result = blk: {
            const parent = b.tree.containers[container].parent_item orelse break :blk false;
            const it = b.tree.items[parent];
            if (it.kind != .@"const" and it.kind != .@"var" or it.name == null) break :blk false;
            const ns = try namespaceOfDecl(b.r, b.file, parent) orelse break :blk false;
            if (ns.file != b.file or ns.container != container) break :blk false;
            break :blk try b.isReachable(it.container);
        };
        b.reachable[container] = result;
        return result;
    }

    /// 函数 `item` 的第一个参数的类型是它所在的容器（`self: Self`、`self: *const @This()`、`s: *S`）
    fn isMethod(b: *DeclBuilder, item: u32) resolve.Error!bool {
        const node = try b.r.itemNode(b.file, item) orelse return false;
        const proto = (ast.FnDecl{ .syntax = node }).proto() orelse (if (node.kind() == .fn_proto) ast.FnProto{ .syntax = node } else return false);
        var params = proto.params();
        const first = params.next() orelse return false;
        var ty = (ast.Param{ .syntax = first }).typeExpr() orelse return false;
        // `*T`、`*const T`：取被指向的类型
        while (ty.kind() == .ptr_type) {
            var last: ?ast.SyntaxNode = null;
            var children = ty.children();
            while (children.nextNode()) |c| switch (c.kind()) {
                .sentinel, .align_clause, .addrspace_clause => {},
                else => last = c,
            };
            ty = last orelse return false;
        }
        const container = b.tree.items[item].container;
        switch (ty.kind()) {
            .builtin_call => {
                const name = (ast.BuiltinCall{ .syntax = ty }).name() orelse return false;
                return std.mem.eql(u8, name.text, "@This");
            },
            .name_ref => {
                const token = (ast.NameRef{ .syntax = ty }).name() orelse return false;
                const name = try ast.identNameAlloc(b.temp, token.text);
                const found = b.lookup(container, name) orelse return false;
                const ns = try namespaceOfDecl(b.r, b.file, found) orelse return false;
                return ns.file == b.file and ns.container == container;
            },
            else => return false,
        }
    }

    fn ownName(b: *DeclBuilder, item: u32) Allocator.Error![]const u8 {
        if (b.names[item]) |name| return name;
        const name = try b.a.dupe(u8, b.tree.items[item].name.?);
        b.names[item] = name;
        return name;
    }

    fn rootName(b: *DeclBuilder, container: u32) Allocator.Error!?[]const u8 {
        if (container == 0) return null;
        var c = container;
        while (true) {
            const parent = b.tree.containers[c].parent_item.?;
            const outer = b.tree.items[parent].container;
            if (outer == 0) return try b.ownName(parent);
            c = outer;
        }
    }

    fn pathOf(b: *DeclBuilder, item: u32) Allocator.Error![]const u8 {
        if (b.paths[item]) |path| return path;
        const it = b.tree.items[item];
        const name = try b.ownName(item);
        const segment = try renderName(b.temp, name);
        const path = if (it.container == 0)
            (if (std.mem.eql(u8, segment, name)) name else try b.a.dupe(u8, segment))
        else
            try joinPath(b.a, try b.pathOf(b.tree.containers[it.container].parent_item.?), segment);
        b.paths[item] = path;
        return path;
    }

    /// 指向本文件中可从文件根访问的容器时为该容器
    fn localNamespace(b: *DeclBuilder, item: u32) resolve.Error!?u32 {
        const kind = b.tree.items[item].kind;
        if (kind != .@"const" and kind != .@"var") return null;
        const ns = try namespaceOfDecl(b.r, b.file, item) orelse return null;
        if (ns.file != b.file or !try b.isReachable(ns.container)) return null;
        return ns.container;
    }

    fn lookup(b: *DeclBuilder, container: u32, name: []const u8) ?u32 {
        var c = container;
        while (true) {
            if (Resolver.lookupDecl(b.tree, c, name)) |found| return found;
            const parent = b.tree.containers[c].parent_item orelse return null;
            c = b.tree.items[parent].container;
        }
    }
};

// ── 跨文件求值 ─────────────────────────────────────────────────────

/// 声明指向的命名空间（见 `DeclNamespace`）
fn namespaceOfDecl(r: *Resolver, file: FileId, item: u32) resolve.Error!?Namespace {
    return r.ctx.get(DeclNamespace, try r.ownerKey(file, item));
}

/// 声明指向的命名空间：`Resolver.namespaceOf`；初始化表达式是条件形式（`if` / `switch`）时由推导求出它的值
/// （`pub const X = if (cond) A else B;` 取 comptime 选中的分支）。按声明缓存：一个文件可以有上千个声明，
/// 为它建索引的读事务被编辑打断时，已求出的声明不必重算；编辑后没有变化的声明也直接命中
pub const DeclNamespace = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = hir.OwnerKey;
    pub const Value = ?Namespace;

    pub fn compute(ctx: *database.Db.Ctx, key: Key) engine.Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        const item = try itemOf(&r, key) orelse return null;
        return computeNamespace(&r, key.file, item);
    }

    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a, b);
    }
};

/// 声明作为别名的规范目标（`Resolver.aliasTarget`；不是别名时为它自身），按声明缓存（同 `DeclNamespace`）
pub const DeclTarget = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = hir.OwnerKey;
    pub const Value = Declaration;

    pub fn compute(ctx: *database.Db.Ctx, key: Key) engine.Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        const item = try itemOf(&r, key) orelse return .{ .file = key.file, .item = 0 };
        return switch (try r.aliasTarget(.{ .item = .{ .file = key.file, .item = item } })) {
            .item => |it| .{ .file = it.file, .item = it.item },
            else => .{ .file = key.file, .item = item },
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a, b);
    }
};

fn itemOf(r: *Resolver, key: hir.OwnerKey) resolve.Error!?u32 {
    for ((try r.itemTree(key.file)).items, 0..) |it, i| if (it.ast_id == key.item) return @intCast(i);
    return null;
}

fn computeNamespace(r: *Resolver, file: FileId, item: u32) resolve.Error!?Namespace {
    if (try r.namespaceOf(.{ .item = .{ .file = file, .item = item } })) |ns| return ns;
    const tree = try r.itemTree(file);
    if (tree.items[item].kind != .@"const") return null;
    const body = try r.body(file, item);
    const value = body.value orelse return null;
    switch (body.expr(value)) {
        .@"if", .@"switch" => {},
        else => return null,
    }
    const tv = try r.ctx.get(sema_queries.DeclType, .{ .owner = try r.ownerKey(file, item) });
    const t = tv.asType() orelse return null;
    return sema_queries.namespaceOfType(r, t);
}

/// 文件中各声明指向的命名空间与别名的规范目标（按 `DeclIndex.decls` 的下标）。补全与展开各个导出闭包都要
/// 用到
pub const FileLinks = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = FileId;
    pub const Value = struct {
        arena: std.heap.ArenaAllocator.State,
        namespaces: []const ?Namespace = &.{},
        targets: []const Declaration = &.{},
    };

    pub fn compute(ctx: *database.Db.Ctx, file: Key) engine.Error!Value {
        const gpa = ctx.db.gpa;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const index = try ctx.get(FileDecls, file);
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        const namespaces = try a.alloc(?Namespace, index.decls.len);
        const targets = try a.alloc(Declaration, index.decls.len);
        for (index.decls, namespaces, targets) |decl, *ns, *target| {
            ns.* = try namespaceOfDecl(&r, file, decl.item);
            target.* = try ctx.get(DeclTarget, try r.ownerKey(file, decl.item));
        }
        return .{ .arena = arena.state, .namespaces = namespaces, .targets = targets };
    }

    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a.namespaces, b.namespaces) and deepEql(a.targets, b.targets);
    }

    pub fn bytes(value: Value) usize {
        return mem.arenaBytes(value.arena);
    }

    pub fn deinit(value: *Value, gpa: Allocator) void {
        var arena = value.arena.promote(gpa);
        arena.deinit();
    }
};

// ── 只被测试用到的文件 ─────────────────────────────────────────────

/// 文件中按路径的 `@import("x.zig")` 及其是否只用于测试：位于 test 声明中，或位于只被测试用到的非 pub
/// 顶层声明中。非 pub 顶层声明不被正式代码引用、而被 test 声明（直接或经由同样只被测试用到的声明）引用时
/// 只被测试用到（如
/// `const World = @import("x_test.zig").World;` 只在 test 与 test 调用的辅助函数中使用：按需分析的编译器只在
/// 测试中编译它）。只依赖本文件的语法树
pub const ImportSites = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = FileId;
    pub const Value = struct {
        arena: std.heap.ArenaAllocator.State,
        specs: []const []const u8 = &.{},
        in_test: []const bool = &.{},
    };

    const Site = struct { spec: []const u8, in_test: bool, decl: ?u32 };
    /// 顶层声明：名字（test 与无名的为 null）、是否为 pub、其中引用的名字
    const TopDecl = struct { name: ?[]const u8, is_pub: bool, is_test: bool, refs: std.ArrayList([]const u8) = .empty };

    pub fn compute(ctx: *database.Db.Ctx, file: Key) engine.Error!Value {
        const gpa = ctx.db.gpa;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        if (!isZigSource(ctx.db.env.vfs.path(file))) return .{ .arena = arena.state };
        const a = arena.allocator();
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const temp = scratch.allocator();
        var sites: std.ArrayList(Site) = .empty;
        var decls: std.ArrayList(TopDecl) = .empty;
        const root = (try ctx.get(database.syntax.ParseFile, file)).rootNode();
        var top = root.children();
        while (top.nextNode()) |node| {
            const index: u32 = @intCast(decls.items.len);
            try decls.append(temp, try topDecl(temp, node));
            try collect(a, temp, node, index, &decls.items[index], &sites);
        }
        // 按名字传递只经过有名字的非 test 声明
        var by_name: std.StringHashMapUnmanaged(u32) = .empty;
        for (decls.items, 0..) |d, i| if (!d.is_test) if (d.name) |name| try by_name.put(temp, name, @intCast(i));
        // 正式代码：pub 声明与其他非 test 的顶层内容，以及被它们引用的非 pub 声明
        const live = try temp.alloc(bool, decls.items.len);
        for (decls.items, live) |d, *l| l.* = !d.is_test and (d.is_pub or d.name == null);
        try propagate(temp, decls.items, &by_name, live, null);
        // 测试代码：test 声明，以及被它们引用的其余非 pub 声明。两者都不引用的是死代码，按正式代码
        const tested = try temp.alloc(bool, decls.items.len);
        for (decls.items, tested) |d, *t| t.* = d.is_test;
        try propagate(temp, decls.items, &by_name, tested, live);
        const specs = try a.alloc([]const u8, sites.items.len);
        const in_test = try a.alloc(bool, sites.items.len);
        for (sites.items, specs, in_test) |site, *spec, *flag| {
            spec.* = site.spec;
            flag.* = site.in_test or (if (site.decl) |d| !live[d] and tested[d] else false);
        }
        return .{ .arena = arena.state, .specs = specs, .in_test = in_test };
    }

    /// `marked` 中的声明引用的其他声明（按名字）也标记，直到不再变化；`except` 中已标记的不再标记
    fn propagate(temp: Allocator, decls: []const TopDecl, by_name: *const std.StringHashMapUnmanaged(u32), marked: []bool, except: ?[]const bool) Allocator.Error!void {
        var queue: std.ArrayList(u32) = .empty;
        for (marked, 0..) |m, i| if (m) try queue.append(temp, @intCast(i));
        while (queue.pop()) |i| for (decls[i].refs.items) |ref| {
            const j = by_name.get(ref) orelse continue;
            if (marked[j]) continue;
            if (except) |e| if (e[j]) continue;
            marked[j] = true;
            try queue.append(temp, j);
        };
    }

    fn topDecl(temp: Allocator, node: ast.SyntaxNode) Allocator.Error!TopDecl {
        const is_pub = node.childToken(.keyword_pub) != null;
        switch (node.kind()) {
            .test_decl => return .{ .name = null, .is_pub = false, .is_test = true },
            .var_decl => if ((ast.VarDecl{ .syntax = node }).name()) |t| return .{ .name = try ast.identNameAlloc(temp, t.text), .is_pub = is_pub, .is_test = false },
            .fn_decl => if ((ast.FnDecl{ .syntax = node }).proto()) |proto| if (proto.name()) |t| return .{ .name = try ast.identNameAlloc(temp, t.text), .is_pub = is_pub, .is_test = false },
            else => {},
        }
        return .{ .name = null, .is_pub = is_pub, .is_test = false };
    }

    /// 顶层声明 `decl`（下标 `index`）中的 import 与引用的名字
    fn collect(a: Allocator, temp: Allocator, node: ast.SyntaxNode, index: u32, decl: *TopDecl, sites: *std.ArrayList(Site)) Allocator.Error!void {
        switch (node.kind()) {
            .name_ref => if ((ast.NameRef{ .syntax = node }).name()) |t| try decl.refs.append(temp, try ast.identNameAlloc(temp, t.text)),
            .builtin_call => if (try pathImport(a, node)) |spec| try sites.append(temp, .{ .spec = spec, .in_test = decl.is_test, .decl = if (decl.is_pub or decl.name == null) null else index }),
            else => {},
        }
        var children = node.children();
        while (children.nextNode()) |child| try collect(a, temp, child, index, decl, sites);
    }

    fn pathImport(a: Allocator, node: ast.SyntaxNode) Allocator.Error!?[]const u8 {
        const call = ast.BuiltinCall{ .syntax = node };
        const name = call.name() orelse return null;
        if (!std.mem.eql(u8, name.text, "@import")) return null;
        var args = call.args();
        const arg = args.next() orelse return null;
        if (arg.kind() != .literal) return null;
        const raw = (arg.firstToken() orelse return null).text;
        const spec = std.zig.string_literal.parseAlloc(a, raw) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidLiteral => return null,
        };
        return if (std.mem.endsWith(u8, spec, ".zig")) spec else null;
    }

    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a.specs, b.specs) and deepEql(a.in_test, b.in_test);
    }

    pub fn bytes(value: Value) usize {
        return mem.arenaBytes(value.arena);
    }

    pub fn deinit(value: *Value, gpa: Allocator) void {
        var arena = value.arena.promote(gpa);
        arena.deinit();
    }
};

/// 项目中只被测试用到的文件（升序）：从各模块的根出发沿 import 可达、但只沿测试之外的 import 不可达的文件。
/// 如只在 `test { _ = @import("x_test.zig"); }` 中 import 的测试文件，以及只被它们 import 的测试辅助文件
pub const TestOnlyFiles = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = void;
    pub const Value = []const FileId;

    pub fn compute(ctx: *database.Db.Ctx, _: Key) engine.Error!Value {
        const gpa = ctx.db.gpa;
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const temp = scratch.allocator();
        var r: Resolver = .{ .ctx = ctx, .arena = temp };
        const graph = try ctx.get(database.ModuleGraph.Input, {}) orelse return gpa.dupe(FileId, &.{});
        var roots: std.ArrayList(FileId) = .empty;
        for (graph.modules) |module| if (module.root) |root| try roots.append(temp, root);
        // 沿全部 import 可达的文件，与只沿测试之外的 import 可达的文件：前者减去后者只被测试用到。都不可达的
        // 文件（如还没有被 import 的新文件）不归为测试文件
        const all = try reach(&r, temp, roots.items, true);
        const live = try reach(&r, temp, roots.items, false);
        var out: std.ArrayList(FileId) = .empty;
        var it = all.keyIterator();
        while (it.next()) |file| if (!live.contains(file.*) and isZigSource(ctx.db.env.vfs.path(file.*))) try out.append(temp, file.*);
        std.mem.sort(FileId, out.items, {}, struct {
            fn less(_: void, x: FileId, y: FileId) bool {
                return @backingInt(x) < @backingInt(y);
            }
        }.less);
        return gpa.dupe(FileId, out.items);
    }

    /// 从 `roots` 沿 import 可达的文件；`with_tests` 为 false 时不经过只用于测试的 import
    fn reach(r: *Resolver, temp: Allocator, roots: []const FileId, with_tests: bool) resolve.Error!std.AutoHashMapUnmanaged(FileId, void) {
        var reached: std.AutoHashMapUnmanaged(FileId, void) = .empty;
        var queue: std.ArrayList(FileId) = .empty;
        for (roots) |root| if (!(try reached.getOrPut(temp, root)).found_existing) try queue.append(temp, root);
        var i: usize = 0;
        while (i < queue.items.len) : (i += 1) {
            const file = queue.items[i];
            const sites = try r.ctx.get(ImportSites, file);
            for (sites.specs, sites.in_test) |spec, in_test| {
                if (in_test and !with_tests) continue;
                const target = try r.resolveImport(file, spec) orelse continue;
                if (!(try reached.getOrPut(temp, target)).found_existing) try queue.append(temp, target);
            }
        }
        return reached;
    }

    pub fn contains(value: Value, file: FileId) bool {
        return std.sort.binarySearch(FileId, value, file, struct {
            fn order(needle: FileId, item: FileId) std.math.Order {
                return std.math.order(@backingInt(needle), @backingInt(item));
            }
        }.order) != null;
    }

    pub fn eql(a: Value, b: Value) bool {
        return std.mem.eql(FileId, a, b);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        gpa.free(v.*);
    }
};

// ── 公开导出闭包 ───────────────────────────────────────────────────

/// `file` 中经公开路径可达的命名空间所在的其他 Zig 源文件（可能重复）：按批预热公开导出闭包时据此展开
pub fn publicTargets(ctx: *database.Db.Ctx, file: FileId, out: *std.ArrayList(FileId), a: Allocator) engine.Error!void {
    const index = try ctx.get(FileDecls, file);
    const links = try ctx.get(FileLinks, file);
    for (index.public_decls) |p| {
        const ns = links.namespaces[p.decl] orelse continue;
        if (ns.file != file and isZigSource(ctx.db.env.vfs.path(ns.file))) try out.append(a, ns.file);
    }
}

pub const Export = struct {
    /// 指向 `FileDecls` 的值（不淘汰，依赖它的本 query 随它重算）
    name: []const u8,
    path: []const u8,
    /// 路径的段数
    depth: u32,
    kind: ItemTree.Item.Kind,
    is_extern: bool,
    file: FileId,
    item: u32,
    target: Declaration,
    /// 指向 `FileDecls` 的值
    doc: ?[]const u8,
};
pub const ExportIndex = struct {
    arena: std.heap.ArenaAllocator.State,
    /// 按名字排序（`orderName`）
    decls: []const Export,
    /// 路径至多 `shallow_depth` 段的导出（`decls` 的下标）：补全对它们的整条路径做模糊匹配
    shallow: []const u32,
    /// 名字以 `prefix` 开头（不区分大小写）的导出
    pub fn matching(index: *const ExportIndex, prefix: []const u8) []const Export {
        const start = prefixStart(Export, index.decls, prefix);
        var end = start;
        while (end < index.decls.len and std.ascii.startsWithIgnoreCase(index.decls[end].name, prefix)) : (end += 1) {}
        return index.decls[start..end];
    }
};

/// 沿真正的公开成员边遍历，不把依赖内部文件的相对路径泄漏到调用模块。
/// 每个命名空间取最短的公开路径，既终止自引用，也避免别名造成指数级路径展开。
pub const Exports = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = struct { ns: Namespace };
    pub const Value = *const ExportIndex;
    /// 打开过的文件各有别名指向的命名空间，闭包不淘汰时随会话增长；被淘汰的由不淘汰的 `FileDecls` 与
    /// `FileLinks` 重新展开，只是查找与复制
    pub const lru = 1024;
    pub const lru_bytes = 16 * 1024 * 1024;
    pub fn compute(ctx: *database.Db.Ctx, key: Key) engine.Error!Value {
        const gpa = ctx.db.gpa;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const temp = scratch.allocator();
        const Pending = struct { ns: Namespace, path: []const u8, depth: u32 };
        var queue: std.ArrayList(Pending) = .empty;
        var seen: std.AutoHashMapUnmanaged(Namespace, void) = .empty;
        try queue.append(temp, .{ .ns = key.ns, .path = "", .depth = 0 });
        try seen.put(temp, key.ns, {});
        var out: std.ArrayList(Export) = .empty;
        var i: usize = 0;
        while (i < queue.items.len) : (i += 1) {
            const current = queue.items[i];
            const index = try ctx.get(FileDecls, current.ns.file);
            const links = try ctx.get(FileLinks, current.ns.file);
            for (index.containerMembers(current.ns.container)) |d| {
                const decl = &index.decls[d];
                if (!decl.is_pub) continue;
                const path = try appendName(a, current.path, decl.name);
                try out.append(temp, .{
                    .name = decl.name,
                    .path = path,
                    .depth = current.depth + 1,
                    .kind = decl.kind,
                    .is_extern = decl.is_extern,
                    .file = current.ns.file,
                    .item = decl.item,
                    .target = links.targets[d],
                    .doc = decl.doc,
                });
                const ns = links.namespaces[d] orelse continue;
                const entry = try seen.getOrPut(temp, ns);
                if (!entry.found_existing) try queue.append(temp, .{ .ns = ns, .path = path, .depth = current.depth + 1 });
            }
        }
        std.mem.sort(Export, out.items, {}, nameLess(Export));
        const decls = try a.dupe(Export, out.items);
        var shallow: std.ArrayList(u32) = .empty;
        for (decls, 0..) |d, j| if (d.depth <= shallow_depth) try shallow.append(temp, @intCast(j));
        const shallow_decls = try a.dupe(u32, shallow.items);
        const index = try gpa.create(ExportIndex);
        index.* = .{ .arena = arena.state, .decls = decls, .shallow = shallow_decls };
        return index;
    }
    /// 名字与文档指向 `FileDecls` 的值，按指针比较：同一个值才相等。被替换的旧值可能已经释放，不能读取内容
    pub fn eql(a: Value, b: Value) bool {
        if (a.decls.len != b.decls.len) return false;
        for (a.decls, b.decls) |x, y| {
            if (!sameSlice(x.name, y.name)) return false;
            if ((x.doc == null) != (y.doc == null) or (x.doc != null and !sameSlice(x.doc.?, y.doc.?))) return false;
            if (!std.mem.eql(u8, x.path, y.path) or x.depth != y.depth or x.kind != y.kind or x.is_extern != y.is_extern) return false;
            if (x.file != y.file or x.item != y.item or !deepEql(x.target, y.target)) return false;
        }
        return true;
    }
    pub fn bytes(v: Value) usize {
        return @sizeOf(ExportIndex) + mem.arenaBytes(v.arena);
    }
    pub fn deinit(v: *Value, gpa: Allocator) void {
        var arena = v.*.arena.promote(gpa);
        arena.deinit();
        gpa.destroy(@constCast(v.*));
    }
};

fn sameSlice(a: []const u8, b: []const u8) bool {
    return a.ptr == b.ptr and a.len == b.len;
}

/// 光标所在的成员：调用方已经查到时传入，免得再遍历一次文件的成员
pub const Owner = union(enum) { unknown, known: ?u32 };

/// 候选来源的权重（见 `Candidate.score`）：经由光标处可见的名字访问的（命名空间别名的成员、复用的直接别名、同文件的
/// 私有链）优先于需要新增 import 的
pub const visible_weight = 0.85;
pub const import_weight = 0.75;
/// 只按名字前缀找到、整条路径又没有模糊匹配上的候选（名字含转义字符时）的匹配分
const min_match = 0.01;

/// 候选的路径每多一段，分数乘以的系数少 `depth_step`（至少为 `min_depth_factor`）：同样匹配时浅的优先
const depth_step = 0.05;
const min_depth_factor = 0.5;

/// `import_options` 决定新 import 插入的位置（见 `organize_imports.Inserter`）。候选先按分数排序（见
/// `Candidate.score`），再依次构造（检查可见性、生成 import 编辑），构造满 `limit` 个为止；结果按这个次序
pub fn complete(r: *Resolver, file: FileId, offset: u32, owner: Owner, prefix: []const u8, limit: usize, import_options: organize_imports.Options) resolve.Error!Result {
    if (prefix.len == 0 or !isZigSource(r.ctx.db.env.vfs.path(file))) return .{ .items = &.{} };
    const current = try r.ctx.get(FileDecls, file);
    var builder: Builder = .{ .r = r, .file = file, .offset = offset, .prefix = prefix, .current = current, .matcher = try .init(r.arena, prefix), .import_options = import_options };
    const links = try r.ctx.get(FileLinks, file);
    const graph = try r.ctx.get(database.ModuleGraph.Input, {});
    builder.owner = switch (owner) {
        .unknown => try r.ownerAt(file, offset, true),
        .known => |item| item,
    };
    if (builder.owner) |item| {
        builder.body = try r.body(file, item);
        // 成员的起点取自语法树（按键时本来就重算），不读 `ItemSummaries`：它要为整个文件重算
        const base = if (try r.itemNode(file, item)) |node| node.offset else offset;
        builder.scope = builder.body.?.scopeAt((offset -| base) -| 1);
    }
    // 顶层 const 可能是别名；用到时才检查它在光标处是否可见
    var top: std.ArrayList(Alias) = .empty;
    for (current.decls, links.namespaces, links.targets) |*decl, ns, target| {
        if (decl.container != 0 or decl.kind != .@"const") continue;
        try top.append(r.arena, .{ .decl = decl, .ns = ns, .target = target });
        if (ns) |n| try builder.alias_namespaces.put(r.arena, n, {});
        if (!deepEql(target, Declaration{ .file = file, .item = decl.item })) try builder.alias_targets.put(r.arena, target, {});
    }
    builder.top = top.items;
    const matches = current.matching(prefix);
    // 已有命名空间别名优先，不为同一入口再生成 import。浅层的导出按整条路径模糊匹配，更深的按名字的前缀
    for (top.items) |alias| {
        const decl = alias.decl;
        const ns = alias.ns orelse continue;
        const exports = try r.ctx.get(Exports, .{ .ns = ns });
        const declared_matches = exports.matching(prefix);
        if (exports.shallow.len == 0 and declared_matches.len == 0 and (ns.file != file or matches.start == matches.end)) continue;
        if (!try builder.refersToSelf(decl)) continue;
        const root = try renderName(r.arena, decl.name);
        for (exports.shallow) |j| try builder.member(root, &exports.decls[j], false);
        for (declared_matches) |*declared| if (declared.depth > shallow_depth) try builder.member(root, declared, true);
        // 同文件可访问私有成员，公开闭包仍由所有请求共享。
        if (ns.file == file) for (current.decls[matches.start..matches.end], links.targets[matches.start..matches.end]) |*nested, target| {
            const relative = localRelative(current, ns, nested.*);
            const parts: Parts = if (relative) |rel| .{ root, rel } else .{ nested.path, "" };
            const score = try builder.byNameScore(parts);
            if (try builder.reuse(target, nested.name, nested.kind, nested.doc, score, parts)) continue;
            if (relative == null) continue;
            try builder.reused.put(r.arena, target, {});
            try builder.push(.{ .score = score * visible_weight, .parts = parts, .what = .{ .member = .{ .name = nested.name, .kind = nested.kind, .doc = nested.doc, .decl = .{ .file = file, .item = nested.item } } } });
        };
    }
    // 同文件的私有链合法；可见的顶层名由普通补全负责。
    for (current.decls[matches.start..matches.end], links.targets[matches.start..matches.end]) |*decl, target| {
        const parts: Parts = .{ decl.path, "" };
        const score = try builder.byNameScore(parts);
        if (try builder.reuse(target, decl.name, decl.kind, decl.doc, score, parts)) continue;
        const root_name = decl.root orelse continue;
        try builder.push(.{ .score = score * visible_weight, .parts = parts, .what = .{ .chain = .{ .decl = decl, .root = root_name } } });
    }
    if (graph) |g| {
        // 模块名字即使没有任何声明也可补全；生成文件根未知时不提供。
        const names = try g.importNames(r.arena, file);
        for ([_][]const []const u8{ &.{ "std", "builtin" }, names }) |group| for (group) |name| {
            const target = g.importTarget(file, name) orelse continue;
            const ns: Namespace = .{ .file = target, .container = 0 };
            const spec = try r.arena.dupe(u8, name);
            if (try builder.matcher.score(name)) |score| if (try builder.namespaceAlias(ns) == null and try builder.visible(name) == null)
                try builder.push(.{ .score = score * import_weight, .parts = .{ spec, "" }, .what = .{ .module = .{ .name = spec, .kind = .module, .spec = spec, .target = target } } });
            try builder.exported(ns, spec);
        };
        // 项目文件只查询小索引的前缀区间，不在按键路径扫描 ItemTree/Body。只被测试用到的文件只在测试代码（同样
        // 只被测试用到的文件、test 声明）中导入
        const test_only = try r.ctx.get(TestOnlyFiles, {});
        const in_test = TestOnlyFiles.contains(test_only, file) or
            (if (builder.owner) |item| (try r.itemTree(file)).items[item].kind == .@"test" else false);
        for (g.files) |entry| {
            if (entry.file == file or entry.module == database.ModuleGraph.std_module) continue;
            if (!in_test and TestOnlyFiles.contains(test_only, entry.file)) continue;
            const path = r.ctx.db.env.vfs.path(entry.file);
            if (!isZigSource(path)) continue;
            const index = try r.ctx.get(FileDecls, entry.file);
            const public = index.matchingPublic(prefix);
            const basename = std.fs.path.basename(path);
            const stem = basename[0 .. basename.len - ".zig".len];
            const stem_score = try builder.matcher.score(stem);
            if (public.len == 0 and stem_score == null) continue;
            const spec = try importSpec(r, g, file, entry.file) orelse continue;
            const ns: Namespace = .{ .file = entry.file, .container = 0 };
            const aliased = try builder.namespaceAlias(ns) != null;
            if (stem_score) |score| if (!aliased and try builder.visible(stem) == null)
                try builder.push(.{ .score = score * import_weight, .parts = .{ stem, "" }, .what = .{ .module = .{ .name = stem, .kind = .file, .spec = spec, .target = entry.file } } });
            if (aliased or public.len == 0) continue;
            const targets = (try r.ctx.get(FileLinks, entry.file)).targets;
            for (public) |p| {
                const decl = &index.decls[p.decl];
                const target = targets[p.decl];
                const parts: Parts = .{ stem, p.path };
                const score = try builder.byNameScore(parts);
                if (try builder.reuse(target, decl.name, decl.kind, decl.doc, score, parts)) continue;
                if (builder.reused.contains(target)) continue;
                try builder.push(.{ .score = score * import_weight, .parts = parts, .what = .{ .import = .{ .name = decl.name, .kind = decl.kind, .is_extern = decl.is_extern, .spec = spec, .path = p.path, .doc = decl.doc, .target = .{ .decl = .{ .file = entry.file, .item = decl.item } } } } });
            }
        }
    }
    std.mem.sort(Found, builder.found.items, {}, foundLess);
    for (builder.found.items) |p| {
        if (builder.items.items.len >= limit) {
            builder.incomplete = true;
            break;
        }
        try builder.construct(p);
    }
    for (builder.items.items) |*item| {
        item.filter = try r.arena.dupe(u8, item.filter);
        if (item.doc) |doc| item.doc = try r.arena.dupe(u8, doc);
    }
    return .{ .items = builder.items.items, .is_incomplete = builder.incomplete };
}

/// 当前文件的顶层 const 及其指向的命名空间、规范目标
const Alias = struct { decl: *const Decl, ns: ?Namespace, target: Declaration };

/// 候选的路径：两部分以 `.` 连接（第二部分为空时只有第一部分），打分与同分时的排序都按它
const Parts = [2][]const u8;

/// 已匹配、尚未构造的候选：构造时才检查可见性、生成标签与 import 编辑
const Found = struct {
    score: f32,
    parts: Parts,
    /// 名字以输入开头且大小写一致：同分时优先（全为小写的输入不区分大小写打分）
    case_exact: bool = false,
    what: union(enum) {
        /// 经由可见的命名空间访问，标签为路径
        member: struct { name: []const u8, kind: ItemTree.Item.Kind, doc: ?[]const u8, decl: Declaration },
        /// 复用指向同一规范目标的直接别名
        reuse: struct { alias: *const Decl, name: []const u8, kind: ItemTree.Item.Kind, doc: ?[]const u8 },
        /// 同文件的私有链，标签为声明的路径
        chain: struct { decl: *const Decl, root: []const u8 },
        /// 新增 import 的模块或文件
        module: struct { name: []const u8, kind: @FieldType(Candidate, "kind"), spec: []const u8, target: FileId },
        /// 新增 import 的声明
        import: struct { name: []const u8, kind: ItemTree.Item.Kind, is_extern: bool, spec: []const u8, path: []const u8, doc: ?[]const u8, target: Target },
    },
};

const Builder = struct {
    r: *Resolver,
    file: FileId,
    offset: u32,
    prefix: []const u8,
    current: *const DeclIndex,
    matcher: fuzzy.Matcher,
    owner: ?u32 = null,
    body: ?*const Body = null,
    scope: Body.ScopeId = .root,
    /// 当前文件的顶层 const，按名字排序
    top: []const Alias = &.{},
    /// `top` 中各项的命名空间与不是自身的规范目标：不在其中时不必逐个检查
    alias_namespaces: std.AutoHashMapUnmanaged(Namespace, void) = .empty,
    alias_targets: std.AutoHashMapUnmanaged(Declaration, void) = .empty,
    reused: std.AutoHashMapUnmanaged(Declaration, void) = .empty,
    visible_names: std.StringHashMapUnmanaged(?resolve.Def) = .empty,
    found: std.ArrayList(Found) = .empty,
    items: std.ArrayList(Candidate) = .empty,
    incomplete: bool = false,
    /// import 声明的排列规则（新 import 按它放到整理好的块中应在的位置）
    import_options: organize_imports.Options = .{},
    /// 首次生成 import 编辑时准备
    inserter: ?organize_imports.Inserter = null,
    /// 光标前正在输入的名字：插入的编辑与它重叠时不提供
    typing: ?@import("../syntax/tree.zig").TextRange = null,

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
            if (findRoot(b.current, name)) |decl| found = .{ .item = .{ .file = b.file, .item = decl.item } };
        }
        try b.visible_names.put(b.r.arena, name, found);
        return found;
    }

    /// 不先用当前文件的 `FileIndex` 粗筛：逐字输入时补全紧跟在编辑之后，它总要重算，比 `BindingNames` 更贵
    fn bindingConflict(b: *Builder, name: []const u8) resolve.Error!bool {
        return BindingNames.contains(try b.r.ctx.get(BindingNames, b.file), name);
    }
    /// 顶层声明的名字在光标处仍指向它自己（没有被局部的同名绑定遮蔽）
    fn refersToSelf(b: *Builder, decl: *const Decl) resolve.Error!bool {
        const def = try b.visible(decl.name) orelse return false;
        return deepEql(def, resolve.Def{ .item = .{ .file = b.file, .item = decl.item } });
    }
    /// 光标处可见、指向 `ns` 的第一个顶层别名
    fn namespaceAlias(b: *Builder, ns: Namespace) resolve.Error!?*const Decl {
        if (!b.alias_namespaces.contains(ns)) return null;
        for (b.top) |alias| if (alias.ns) |n| if (deepEql(n, ns) and try b.refersToSelf(alias.decl)) return alias.decl;
        return null;
    }
    /// 光标处可见、规范目标为 `target` 的第一个顶层直接别名
    fn directAlias(b: *Builder, target: Declaration) resolve.Error!?*const Decl {
        if (!b.alias_targets.contains(target)) return null;
        for (b.top) |alias| {
            if (deepEql(alias.target, target) and !deepEql(alias.target, Declaration{ .file = b.file, .item = alias.decl.item }) and try b.refersToSelf(alias.decl)) return alias.decl;
        }
        return null;
    }
    /// 规范目标已有可见的直接别名时改为复用它（`score` 为路径 `parts` 的匹配分）
    fn reuse(b: *Builder, target: Declaration, name: []const u8, kind: ItemTree.Item.Kind, doc: ?[]const u8, score: f32, parts: Parts) resolve.Error!bool {
        const alias = try b.directAlias(target) orelse return false;
        // 别名与目标共享前缀时，继续输入后须重新选择过滤名字，不能沿用另一条拼写。
        if (!std.mem.eql(u8, alias.name, name) and std.ascii.startsWithIgnoreCase(alias.name, b.prefix)) b.incomplete = true;
        try b.push(.{ .score = score * visible_weight, .parts = parts, .what = .{ .reuse = .{ .alias = alias, .name = name, .kind = kind, .doc = doc } } });
        try b.reused.put(b.r.arena, target, {});
        return true;
    }
    /// 可见的命名空间别名 `root` 的导出 `declared`；`by_name` 时它已按名字前缀匹配
    fn member(b: *Builder, root: []const u8, declared: *const Export, by_name: bool) resolve.Error!void {
        const parts: Parts = .{ root, declared.path };
        const score = try b.matchOf(parts, by_name) orelse return;
        if (try b.reuse(declared.target, declared.name, declared.kind, declared.doc, score, parts)) return;
        try b.reused.put(b.r.arena, declared.target, {});
        try b.push(.{ .score = score * visible_weight, .parts = parts, .what = .{ .member = .{ .name = declared.name, .kind = declared.kind, .doc = declared.doc, .decl = .{ .file = declared.file, .item = declared.item } } } });
    }
    fn exported(b: *Builder, ns: Namespace, spec: []const u8) resolve.Error!void {
        if (try b.namespaceAlias(ns) != null) return;
        const index = try b.r.ctx.get(Exports, .{ .ns = ns });
        for (index.shallow) |j| try b.exportedDecl(&index.decls[j], spec, false);
        for (index.matching(b.prefix)) |*decl| if (decl.depth > shallow_depth) try b.exportedDecl(decl, spec, true);
    }
    fn exportedDecl(b: *Builder, decl: *const Export, spec: []const u8, by_name: bool) resolve.Error!void {
        const parts: Parts = .{ spec, decl.path };
        const score = try b.matchOf(parts, by_name) orelse return;
        if (try b.reuse(decl.target, decl.name, decl.kind, decl.doc, score, parts)) return;
        if (b.reused.contains(decl.target)) return;
        try b.push(.{ .score = score * import_weight, .parts = parts, .what = .{ .import = .{ .name = decl.name, .kind = decl.kind, .is_extern = decl.is_extern, .spec = spec, .path = decl.path, .doc = decl.doc, .target = .{ .decl = .{ .file = decl.file, .item = decl.item } } } } });
    }
    /// 路径的匹配分乘以深度系数；不匹配时为 null。`by_name` 时已按名字前缀匹配，路径没有匹配上（名字含转义字符）
    /// 时取最低分
    fn matchOf(b: *Builder, parts: Parts, by_name: bool) resolve.Error!?f32 {
        const score = try b.matcher.scoreJoined(&joined(parts)) orelse
            (if (by_name) min_match else return null);
        return score * depthFactor(parts);
    }
    /// 已按名字前缀匹配上的候选的分数（见 `matchOf`）
    fn byNameScore(b: *Builder, parts: Parts) resolve.Error!f32 {
        return (try b.matchOf(parts, true)).?;
    }
    fn push(b: *Builder, p: Found) resolve.Error!void {
        var found = p;
        const name = switch (p.what) {
            .member => |m| m.name,
            .reuse => |u| u.name,
            .chain => |c| c.decl.name,
            .module => |m| m.name,
            .import => |i| i.name,
        };
        found.case_exact = std.mem.startsWith(u8, name, b.prefix);
        try b.found.append(b.r.arena, found);
    }
    /// 名字以输入的前缀开头时按名字过滤；按路径匹配上的按路径过滤，客户端不会把它滤掉
    fn filterOf(b: *Builder, name: []const u8, parts: Parts) resolve.Error![]const u8 {
        if (std.ascii.startsWithIgnoreCase(name, b.prefix)) return name;
        return joinPath(b.r.arena, parts[0], parts[1]);
    }
    fn construct(b: *Builder, p: Found) resolve.Error!void {
        switch (p.what) {
            .member => |m| {
                if (try b.visible(m.name) != null) return;
                try b.add(.{ .label = try joinPath(b.r.arena, p.parts[0], p.parts[1]), .kind = try b.declKind(m.decl), .filter = try b.filterOf(m.name, p.parts), .qualifier = p.parts[0], .score = p.score, .doc = m.doc, .target = .{ .decl = m.decl } });
            },
            .reuse => |u| try b.add(.{ .label = try renderName(b.r.arena, u.alias.name), .kind = try b.declKind(.{ .file = b.file, .item = u.alias.item }), .filter = try b.filterOf(u.name, p.parts), .qualifier = "", .score = p.score, .doc = u.doc, .target = .{ .decl = .{ .file = b.file, .item = u.alias.item } } }),
            .chain => |c| {
                if (try b.visible(c.decl.name) != null) return;
                const root_def = try b.visible(c.root) orelse return;
                const expected = findRoot(b.current, c.root) orelse return;
                if (!deepEql(root_def, resolve.Def{ .item = .{ .file = b.file, .item = expected.item } })) return;
                try b.add(.{ .label = try b.r.arena.dupe(u8, c.decl.path), .kind = try b.declKind(.{ .file = b.file, .item = c.decl.item }), .filter = try b.filterOf(c.decl.name, p.parts), .qualifier = try renderName(b.r.arena, c.root), .score = p.score, .doc = c.decl.doc, .target = .{ .decl = .{ .file = b.file, .item = c.decl.item } } });
            },
            .module => |m| try b.importCandidate(m.name, m.kind, false, m.spec, "", null, p, .{ .file = m.target }),
            .import => |i| {
                if (try b.visible(i.name) != null) return;
                // 运行期存储（容器级 var、extern const）不能复制到新的 comptime 常量中
                const storage = i.kind == .@"var" or (i.is_extern and i.kind == .@"const");
                try b.importCandidate(i.name, try b.declKind(i.target.decl), storage, i.spec, i.path, i.doc, p, i.target);
            },
        }
    }
    fn add(b: *Builder, candidate: Candidate) resolve.Error!void {
        for (b.items.items) |existing| {
            if (std.mem.eql(u8, existing.label, candidate.label) and std.mem.eql(u8, existing.qualifier, candidate.qualifier)) return;
        }
        try b.items.append(b.r.arena, candidate);
    }
    /// 构造的候选的种类（见 `symbol_kind`）。先取建索引时已求出、常驻的结果：函数、按语法能确定种类的声明
    /// （`Decl.form`）、值为命名空间的 const 以及指向它们的别名，不必为所在的文件解析、求声明的类型；其余求声明的类型
    fn declKind(b: *Builder, decl: Declaration) resolve.Error!@FieldType(Candidate, "kind") {
        const key = try b.r.ownerKey(decl.file, decl.item);
        if (try b.indexedKind(decl, key)) |kind| return kind;
        const target = try b.r.ctx.get(DeclTarget, key);
        if (!deepEql(target, decl)) if (try b.indexedKind(target, try b.r.ownerKey(target.file, target.item))) |kind| return kind;
        const symbol = try symbol_kind.ofDecl(b.r, decl.file, decl.item);
        return switch (symbol.kind) {
            .namespace => .namespace,
            .@"struct" => .@"struct",
            .@"enum" => .@"enum",
            .type => .type,
            .function, .method => .function,
            .variable, .field, .enum_member, .parameter, .type_parameter => if (symbol.readonly) .constant else .variable,
        };
    }
    /// 函数（自动导入不提供方法，见 `DeclBuilder.isMethod`）、按语法能确定种类的 const / var 与值为 Zig 文件或容器的
    /// const 的种类
    fn indexedKind(b: *Builder, decl: Declaration, key: hir.OwnerKey) resolve.Error!?@FieldType(Candidate, "kind") {
        const item_kind = (try b.r.itemTree(decl.file)).items[decl.item].kind;
        switch (item_kind) {
            .@"fn" => return .function,
            .@"const", .@"var" => {},
            else => return null,
        }
        if ((try b.r.ctx.get(FileDecls, decl.file)).byItem(decl.item)) |d| switch (d.form) {
            .value => return if (item_kind == .@"var") .variable else .constant,
            .type => return .type,
            .function => return .function,
            .unknown => {},
        };
        if (item_kind != .@"const") return null;
        const ns = try b.r.ctx.get(DeclNamespace, key) orelse return null;
        if (!isZigSource(b.r.ctx.db.env.vfs.path(ns.file))) return null;
        return switch ((try b.r.itemTree(ns.file)).containers[ns.container].kind) {
            .file => .namespace,
            .@"struct" => .@"struct",
            .@"enum" => .@"enum",
            .@"union", .@"opaque" => .type,
        };
    }
    fn importCandidate(b: *Builder, name: []const u8, kind: @FieldType(Candidate, "kind"), storage: bool, spec: []const u8, path: []const u8, doc: ?[]const u8, p: Found, target: Target) resolve.Error!void {
        const a = b.r.arena;
        const qualifier = if (path.len == 0) spec else try std.fmt.allocPrint(a, "{s}:{s}", .{ spec, path });
        var binding = name;
        var binding_path = path;
        var direct = false;
        // 运行期存储经由命名空间访问；extern const 仍保留只读补全类别。
        const label = if (storage or try b.bindingConflict(name)) blk: {
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
        const edit: ?Edit = if (direct) null else blk: {
            if (b.inserter == null) {
                const parse = try b.r.ctx.get(database.syntax.ParseFile, b.file);
                b.inserter = try organize_imports.Inserter.init(a, parse, b.import_options);
                if (parse.rootNode().tokenAtOffset(b.offset -| 1)) |token| if (token.kind == .identifier or token.kind == .invalid) {
                    b.typing = token.range();
                };
            }
            const decl = try std.fmt.allocPrint(a, "const {f} = @import(\"{f}\"){s}{s};", .{
                std.zig.fmtId(binding), std.zig.fmtString(spec), if (binding_path.len == 0) "" else ".", binding_path,
            });
            const e = try b.inserter.?.edit(a, binding, spec, binding_path, decl);
            if (b.typing) |t| if (e.start < t.end and @max(e.end, e.start + 1) > t.start) return;
            break :blk .{ .start = e.start, .end = e.end, .text = e.text };
        };
        try b.add(.{ .label = label, .kind = kind, .filter = try b.filterOf(name, p.parts), .qualifier = qualifier, .score = p.score, .doc = doc, .import_edit = edit, .target = target });
    }
};

/// 路径每多一段，系数少 `depth_step`
fn depthFactor(parts: Parts) f32 {
    var segments: usize = 1 + std.mem.count(u8, parts[0], ".");
    if (parts[1].len != 0) segments += 1 + std.mem.count(u8, parts[1], ".");
    return @max(min_depth_factor, 1 - depth_step * @as(f32, @floatFromInt(segments - 1)));
}

/// 分数从高到低，同分时名字的大小写与输入一致的优先，再按路径、来源
fn foundLess(_: void, a: Found, b: Found) bool {
    if (a.score != b.score) return a.score > b.score;
    if (a.case_exact != b.case_exact) return a.case_exact;
    const order = orderParts(a.parts, b.parts);
    if (order != .eq) return order == .lt;
    return @backingInt(a.what) < @backingInt(b.what);
}

/// 两个路径依次拼接（中间的 `.` 见 `Parts`）后比较
fn orderParts(a: Parts, b: Parts) std.math.Order {
    const x = joined(a);
    const y = joined(b);
    var k: usize = 0;
    while (true) : (k += 1) {
        const p = byteAt(x, k) orelse return if (byteAt(y, k) == null) .eq else .lt;
        const q = byteAt(y, k) orelse return .gt;
        if (p != q) return std.math.order(p, q);
    }
}

fn joined(parts: Parts) [3][]const u8 {
    return .{ parts[0], if (parts[1].len == 0) "" else ".", parts[1] };
}

fn byteAt(parts: [3][]const u8, k: usize) ?u8 {
    var i = k;
    for (parts) |part| {
        if (i < part.len) return part[i];
        i -= part.len;
    }
    return null;
}

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

/// 当前文件 import `target` 用的路径或模块名；不能直接 import 时为 null
pub fn importPath(r: *Resolver, from: FileId, target: FileId) resolve.Error!?[]const u8 {
    const graph = try r.ctx.get(database.ModuleGraph.Input, {}) orelse return null;
    return importSpec(r, graph, from, target);
}

/// 定义所在文件的显示路径：标准库中为 `std/` 下的路径；当前文件可以按路径 import 的为 import 路径；在当前文件
/// 可以 import 的其他模块的根目录下时，为模块名加根目录下的路径（模块的根不一定在编译集合中）；都不是时为完整路径
pub fn displayPath(r: *Resolver, from: FileId, target: FileId) resolve.Error![]const u8 {
    const vfs = r.ctx.db.env.vfs;
    const path = vfs.path(target);
    const graph = try r.ctx.get(database.ModuleGraph.Input, {}) orelse return path;
    if (graph.std_root) |root| if (std.fs.path.dirname(vfs.path(root))) |dir| if (vfs.isUnder(path, dir))
        return under(r.arena, "std", dir, path);
    if (try importSpec(r, graph, from, target)) |spec| if (isZigSource(spec)) return spec;
    for ([_][]const []const u8{ &.{"builtin"}, try graph.importNames(r.arena, from) }) |group| for (group) |name| {
        const root = graph.importTarget(from, name) orelse continue;
        const dir = std.fs.path.dirname(vfs.path(root)) orelse continue;
        if (vfs.isUnder(path, dir)) return under(r.arena, name, dir, path);
    };
    return path;
}

/// `path` 相对 `dir` 的部分，前面加上 `prefix/`，分隔符统一为 `/`
fn under(a: Allocator, prefix: []const u8, dir: []const u8, path: []const u8) Allocator.Error![]const u8 {
    const relative = try std.fs.path.relativeAlloc(a, dir, null, dir, path);
    for (relative) |*c| if (c.* == '\\') {
        c.* = '/';
    };
    return std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, relative });
}

fn findRoot(index: *const DeclIndex, name: []const u8) ?Decl {
    const start = lowerBound(Decl, index.decls, name);
    for (index.decls[start..]) |decl| {
        if (!std.mem.eql(u8, decl.name, name)) break;
        if (decl.container == 0) return decl;
    }
    return null;
}
/// `decl` 相对同文件命名空间 `ns` 的路径；容器的词法路径已预算，单次查找为 O(1)
fn localRelative(index: *const DeclIndex, ns: Namespace, decl: Decl) ?[]const u8 {
    if (ns.container == 0) return decl.path;
    if (ns.container >= index.container_paths.len) return null;
    const prefix = index.container_paths[ns.container] orelse return null;
    if (prefix.len == 0) return decl.path;
    if (decl.path.len <= prefix.len or !std.mem.startsWith(u8, decl.path, prefix) or decl.path[prefix.len] != '.') return null;
    return decl.path[prefix.len + 1 ..];
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
/// 索引中名字的顺序：先不区分 ASCII 大小写，相同时再按字节。不区分大小写地以同一前缀开头的名字因此连续，可以
/// 二分查找；按名字的精确查找用同一个顺序
fn orderName(a: []const u8, b: []const u8) std.math.Order {
    const order = std.ascii.orderIgnoreCase(a, b);
    return if (order != .eq) order else std.mem.order(u8, a, b);
}
fn nameLess(comptime T: type) fn (void, T, T) bool {
    return struct {
        fn less(_: void, a: T, b: T) bool {
            const order = orderName(a.name, b.name);
            if (order != .eq) return order == .lt;
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.less;
}
/// 第一个名字不小于 `name` 的项（按 `orderName`）
fn lowerBound(comptime T: type, items: []const T, name: []const u8) usize {
    var low: usize = 0;
    var high = items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (orderName(items[mid].name, name) == .lt) low = mid + 1 else high = mid;
    }
    return low;
}
/// 第一个名字不区分大小写地不小于 `prefix` 的项：以 `prefix` 开头（不区分大小写）的项从这里开始
fn prefixStart(comptime T: type, items: []const T, prefix: []const u8) usize {
    var low: usize = 0;
    var high = items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (std.ascii.lessThanIgnoreCase(items[mid].name, prefix)) low = mid + 1 else high = mid;
    }
    return low;
}

test {
    _ = @import("imports_test.zig");
}
