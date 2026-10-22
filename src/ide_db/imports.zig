//! 自动导入：自持有的声明索引、公开导出闭包与安全的源码编辑。
//!
//! 索引只依赖各文件的语法：`InitShapes` 记录 const / var 初始化表达式中与命名空间有关的形状，`FileDecls` 由
//! ItemTree 与这些形状得出可从文件根访问的声明，`FileLinks` 按形状跨文件求值各声明指向的命名空间与别名的规范
//! 目标，`Exports` 沿公开成员展开闭包。都不降级成员的 HIR：只改变位置的编辑不改变这些值，按键时不必重新降级
//! 当前文件的各个 const，为标准库建索引时也不必降级其中的成员。

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
const mem = @import("../util/mem.zig");

pub const Edit = struct { start: u32, end: u32, text: []const u8 };
pub const Candidate = struct {
    label: []const u8,
    kind: enum { function, constant, variable, module, file },
    filter: []const u8,
    qualifier: []const u8,
    sort: []const u8,
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

/// 别名链与成员访问的最大求值深度
const max_depth = 32;

/// 只为 Zig 源文件建索引：模块的根可以是 `.zon` 或任意数据文件（如 `addAnonymousImport` 引入的 JSON），
/// 按 Zig 解析它们没有意义，大文件还很慢
pub fn isZigSource(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zig");
}

// ── 初始化表达式的形状 ─────────────────────────────────────────────

/// const / var 初始化表达式中决定它是否为命名空间、别名的部分：`base` 之后依次访问 `fields`。形式与
/// `Resolver.namespaceOf`、`aliasTarget` 求值的相同（`@import`、`@This()`、容器字面量、名字与成员访问，
/// 括号与 `comptime` 透明），其他形式不记录
pub const Shape = struct {
    base: Base,
    /// 依次访问的成员名字（已解码）
    fields: []const []const u8 = &.{},

    pub const Base = union(enum) {
        /// `@import` 的实参
        import: []const u8,
        this,
        /// ItemTree 中的容器下标
        container: u32,
        /// 引用的名字（已解码）；不带引号的原始类型名与原始值不是引用
        name: []const u8,
    };
};

/// 文件中各 const / var 的 `Shape`。只依赖本文件的语法树且不含位置：只改变位置的编辑之后值不变，依赖它的
/// `FileDecls` 不必重算
pub const InitShapes = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = FileId;
    pub const Value = struct {
        arena: std.heap.ArenaAllocator.State,
        /// 有形状的 item，升序
        items: []const u32 = &.{},
        shapes: []const Shape = &.{},

        pub fn get(value: Value, item: u32) ?Shape {
            const i = std.sort.binarySearch(u32, value.items, item, orderItem) orelse return null;
            return value.shapes[i];
        }
    };

    pub fn compute(ctx: *database.Db.Ctx, file: Key) engine.Error!Value {
        const gpa = ctx.db.gpa;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        if (!isZigSource(ctx.db.env.vfs.path(file))) return .{ .arena = arena.state };
        const a = arena.allocator();
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const temp = scratch.allocator();
        const tree = try ctx.get(database.syntax.FileItemTree, file);
        const map = try ctx.get(database.syntax.FileAstIdMap, file);
        // 容器字面量按语法节点的起点对应到 ItemTree 中的容器
        var containers: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        for (tree.containers, 0..) |c, i| {
            if (i == 0) continue;
            if (map.get(c.ast_id)) |node| try containers.put(temp, node.offset, @intCast(i));
        }
        var items: std.ArrayList(u32) = .empty;
        var shapes: std.ArrayList(Shape) = .empty;
        for (tree.items, 0..) |it, i| {
            if (it.kind != .@"const" and it.kind != .@"var") continue;
            const node = map.get(it.ast_id) orelse continue;
            const init = (ast.VarDecl{ .syntax = node }).initExpr() orelse continue;
            const shape = try shapeOf(a, temp, init, &containers) orelse continue;
            try items.append(temp, @intCast(i));
            try shapes.append(temp, shape);
        }
        const owned_items = try a.dupe(u32, items.items);
        const owned_shapes = try a.dupe(Shape, shapes.items);
        return .{ .arena = arena.state, .items = owned_items, .shapes = owned_shapes };
    }

    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a.items, b.items) and deepEql(a.shapes, b.shapes);
    }

    pub fn bytes(value: Value) usize {
        return mem.arenaBytes(value.arena);
    }

    pub fn deinit(value: *Value, gpa: Allocator) void {
        var arena = value.arena.promote(gpa);
        arena.deinit();
    }
};

fn shapeOf(a: Allocator, temp: Allocator, node: ast.SyntaxNode, containers: *const std.AutoHashMapUnmanaged(u32, u32)) Allocator.Error!?Shape {
    var fields: std.ArrayList([]const u8) = .empty;
    var cur = node;
    while (true) switch (cur.kind()) {
        .paren_expr, .comptime_expr => {
            var children = cur.children();
            cur = children.nextNode() orelse return null;
        },
        .field_access => {
            const access = ast.FieldAccess{ .syntax = cur };
            const name = access.name() orelse return null;
            try fields.append(temp, try ownedName(a, name.text));
            cur = access.lhs() orelse return null;
        },
        else => break,
    };
    const base: Shape.Base = switch (cur.kind()) {
        .name_ref => blk: {
            const token = (ast.NameRef{ .syntax = cur }).name() orelse return null;
            if (!std.mem.startsWith(u8, token.text, "@\"") and isBuiltinName(token.text)) return null;
            break :blk .{ .name = try ownedName(a, token.text) };
        },
        .builtin_call => blk: {
            const call = ast.BuiltinCall{ .syntax = cur };
            const builtin = (call.name() orelse return null).text;
            if (std.mem.eql(u8, builtin, "@This")) break :blk .this;
            if (!std.mem.eql(u8, builtin, "@import")) return null;
            var args = call.args();
            const arg = args.next() orelse return null;
            if (args.next() != null or arg.kind() != .literal) return null;
            const raw = (arg.firstToken() orelse return null).text;
            if (raw.len < 2 or raw[0] != '"') return null;
            break :blk .{ .import = std.zig.string_literal.parseAlloc(a, raw) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidLiteral => return null,
            } };
        },
        .container_decl => .{ .container = containers.get(cur.offset) orelse return null },
        else => return null,
    };
    std.mem.reverse([]const u8, fields.items);
    return .{ .base = base, .fields = try a.dupe([]const u8, fields.items) };
}

/// 名字的解码结果复制到 `a`：不含转义时 `identNameAlloc` 引用语法树的原文，语法树会被淘汰
fn ownedName(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const name = try ast.identNameAlloc(a, text);
    const start = @intFromPtr(text.ptr);
    const inside = @intFromPtr(name.ptr) >= start and @intFromPtr(name.ptr) < start + text.len;
    return if (inside) a.dupe(u8, name) else name;
}

/// 不带引号时由语言内建的名字（同 `Body.nameRefIsBuiltin`）
fn isBuiltinName(name: []const u8) bool {
    if (std.zig.primitives.isPrimitive(name)) return true;
    for ([_][]const u8{ "true", "false", "null", "undefined" }) |value| if (std.mem.eql(u8, name, value)) return true;
    return false;
}

fn orderItem(needle: u32, item: u32) std.math.Order {
    return std.math.order(needle, item);
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

    pub fn bytes(value: Value) usize {
        return mem.arenaBytes(value.arena);
    }

    pub fn deinit(value: *Value, gpa: Allocator) void {
        var arena = value.arena.promote(gpa);
        arena.deinit();
    }
};

/// 不淘汰的小索引；只依赖本文件的 ItemTree 与 `InitShapes`，其他文件的变化不使它失效
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
            var b: DeclBuilder = .{
                .tree = try ctx.get(database.syntax.FileItemTree, file),
                .shapes = try ctx.get(InitShapes, file),
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
            deepEql(a.members, b.members) and deepEql(a.member_start, b.member_start) and deepEql(a.outer, b.outer);
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
    tree: *const ItemTree,
    shapes: InitShapes.Value,
    /// 结果的 arena
    a: Allocator,
    temp: Allocator,
    /// 容器能否从文件根访问：容器字面量直接初始化的具名 const / var 之下的容器才能
    reachable: []?bool = undefined,
    names: []?[]const u8 = undefined,
    paths: []?[]const u8 = undefined,
    local: []?u32 = undefined,
    state: []State = undefined,

    const State = enum { unknown, visiting, done };

    fn build(b: *DeclBuilder) Allocator.Error!DeclIndex {
        const items = b.tree.items;
        const containers = b.tree.containers;
        b.reachable = try b.temp.alloc(?bool, containers.len);
        @memset(b.reachable, null);
        b.names = try b.temp.alloc(?[]const u8, items.len);
        @memset(b.names, null);
        b.paths = try b.temp.alloc(?[]const u8, items.len);
        @memset(b.paths, null);
        b.local = try b.temp.alloc(?u32, items.len);
        b.state = try b.temp.alloc(State, items.len);
        @memset(b.state, .unknown);

        var list: std.ArrayList(Decl) = .empty;
        for (items, 0..) |it, i| {
            switch (it.kind) {
                .@"fn", .@"const", .@"var" => {},
                else => continue,
            }
            if (it.name == null or !b.isReachable(it.container)) continue;
            const item: u32 = @intCast(i);
            try list.append(b.temp, .{
                .name = try b.ownName(item),
                .item = item,
                .kind = it.kind,
                .is_pub = it.flags.is_pub,
                .is_extern = it.flags.is_extern,
                .container = it.container,
                .root = try b.rootName(it.container),
                .path = try b.pathOf(item),
                .local = b.localNamespace(item, 0),
                .doc = if (it.doc) |d| try b.a.dupe(u8, d) else null,
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
            o.* = if (b.isReachable(@intCast(i))) items[parent].container else no_container;
        }

        var index: DeclIndex = .{ .arena = undefined, .decls = decls, .by_item = by_item, .members = members, .member_start = member_start, .outer = outer };
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

    fn isReachable(b: *DeclBuilder, container: u32) bool {
        if (container == 0) return true;
        if (b.reachable[container]) |known| return known;
        // 先记为不可达：自引用的结构不会无限递归
        b.reachable[container] = false;
        const result = blk: {
            const parent = b.tree.containers[container].parent_item orelse break :blk false;
            const it = b.tree.items[parent];
            if (it.kind != .@"const" and it.kind != .@"var" or it.name == null) break :blk false;
            const shape = b.shapes.get(parent) orelse break :blk false;
            if (shape.fields.len != 0) break :blk false;
            switch (shape.base) {
                .container => |c| if (c != container) break :blk false,
                else => break :blk false,
            }
            break :blk b.isReachable(it.container);
        };
        b.reachable[container] = result;
        return result;
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

    /// 本文件中的命名空间：只沿本文件的名字与成员求值，经过 import 时为 null
    fn localNamespace(b: *DeclBuilder, item: u32, depth: u32) ?u32 {
        if (depth > max_depth) return null;
        switch (b.state[item]) {
            .done => return b.local[item],
            .visiting => return null,
            .unknown => {},
        }
        b.state[item] = .visiting;
        const result = b.localUncached(item, depth);
        b.local[item] = result;
        b.state[item] = .done;
        return result;
    }

    fn localUncached(b: *DeclBuilder, item: u32, depth: u32) ?u32 {
        const it = b.tree.items[item];
        if (it.kind != .@"const" and it.kind != .@"var") return null;
        const shape = b.shapes.get(item) orelse return null;
        var ns: u32 = switch (shape.base) {
            .import => return null,
            .this => it.container,
            .container => |c| c,
            .name => |name| b.localNamespace(b.lookup(it.container, name) orelse return null, depth + 1) orelse return null,
        };
        for (shape.fields) |field| {
            const member = Resolver.lookupDecl(b.tree, ns, field) orelse return null;
            ns = b.localNamespace(member, depth + 1) orelse return null;
        }
        return if (b.isReachable(ns)) ns else null;
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

/// 按各文件的 `FileDecls` 与 `InitShapes` 求值命名空间与别名的规范目标，与 `Resolver.namespaceOf`、
/// `aliasTarget` 的结果相同（只认它们识别的形式）。只读取各文件的语法索引，不降级 HIR；结果在一次求值内缓存
const Eval = struct {
    r: *Resolver,
    temp: Allocator,
    namespaces: std.AutoHashMapUnmanaged(Declaration, ?Namespace) = .empty,
    targets: std.AutoHashMapUnmanaged(Declaration, Declaration) = .empty,

    fn namespaceOf(e: *Eval, file: FileId, item: u32) resolve.Error!?Namespace {
        return e.namespaceDepth(file, item, 0);
    }

    fn targetOf(e: *Eval, file: FileId, item: u32) resolve.Error!Declaration {
        return e.targetDepth(file, item, 0);
    }

    fn namespaceDepth(e: *Eval, file: FileId, item: u32, depth: u32) resolve.Error!?Namespace {
        if (depth > max_depth) return null;
        const key: Declaration = .{ .file = file, .item = item };
        if (e.namespaces.get(key)) |known| return known;
        // 环：求值途中再遇到时按不是命名空间处理
        try e.namespaces.put(e.temp, key, null);
        const result = try e.namespaceUncached(file, item, depth);
        try e.namespaces.put(e.temp, key, result);
        return result;
    }

    fn namespaceUncached(e: *Eval, file: FileId, item: u32, depth: u32) resolve.Error!?Namespace {
        const index = try e.r.ctx.get(FileDecls, file);
        const decl = index.byItem(item) orelse return null;
        if (decl.kind != .@"const" and decl.kind != .@"var") return null;
        if (decl.local) |c| return .{ .file = file, .container = c };
        const shape = (try e.r.ctx.get(InitShapes, file)).get(item) orelse return null;
        var ns = try e.base(file, index, decl, shape.base, depth) orelse return null;
        for (shape.fields) |field| {
            const member_item = try e.member(ns, field) orelse return null;
            ns = try e.namespaceDepth(ns.file, member_item, depth + 1) orelse return null;
        }
        return ns;
    }

    fn base(e: *Eval, file: FileId, index: *const DeclIndex, decl: *const Decl, shape: Shape.Base, depth: u32) resolve.Error!?Namespace {
        return switch (shape) {
            .import => |spec| .{ .file = try e.importTarget(file, spec) orelse return null, .container = 0 },
            .this => .{ .file = file, .container = decl.container },
            .container => |c| .{ .file = file, .container = c },
            .name => |name| try e.namespaceDepth(file, (index.lookup(decl.container, name) orelse return null).item, depth + 1),
        };
    }

    /// 同 `Resolver.resolveImport`，命名模块经 `ShapeImports` 查找
    fn importTarget(e: *Eval, file: FileId, spec: []const u8) resolve.Error!?FileId {
        if (std.mem.endsWith(u8, spec, ".zig") or std.mem.endsWith(u8, spec, ".zon")) return e.r.resolveImport(file, spec);
        return (try e.r.ctx.get(ShapeImports, file)).get(spec);
    }

    fn member(e: *Eval, ns: Namespace, name: []const u8) resolve.Error!?u32 {
        const index = try e.r.ctx.get(FileDecls, ns.file);
        return (index.member(ns.container, name) orelse return null).item;
    }

    fn targetDepth(e: *Eval, file: FileId, item: u32, depth: u32) resolve.Error!Declaration {
        const key: Declaration = .{ .file = file, .item = item };
        if (depth > max_depth) return key;
        if (e.targets.get(key)) |known| return known;
        try e.targets.put(e.temp, key, key);
        const result = try e.targetUncached(file, item, depth);
        try e.targets.put(e.temp, key, result);
        return result;
    }

    fn targetUncached(e: *Eval, file: FileId, item: u32, depth: u32) resolve.Error!Declaration {
        const self: Declaration = .{ .file = file, .item = item };
        const index = try e.r.ctx.get(FileDecls, file);
        const decl = index.byItem(item) orelse return self;
        if (decl.kind != .@"const") return self;
        const shape = (try e.r.ctx.get(InitShapes, file)).get(item) orelse return self;
        if (shape.fields.len == 0) {
            const name = switch (shape.base) {
                .name => |name| name,
                else => return self,
            };
            const target = index.lookup(decl.container, name) orelse return self;
            return e.targetDepth(file, target.item, depth + 1);
        }
        var ns = try e.base(file, index, decl, shape.base, depth) orelse return self;
        for (shape.fields[0 .. shape.fields.len - 1]) |field| {
            const member_item = try e.member(ns, field) orelse return self;
            ns = try e.namespaceDepth(ns.file, member_item, depth + 1) orelse return self;
        }
        const last = try e.member(ns, shape.fields[shape.fields.len - 1]) orelse return self;
        return e.targetDepth(ns.file, last, depth + 1);
    }
};

/// 文件中各 const / var 的形状以名字 import 的模块（`@import("std")` 等）在模块图中的目标。只依赖本文件的
/// `InitShapes` 与模块图：模块图的变化与这些名字无关时值不变，依赖它的 `FileLinks` 不必重算。不用
/// `FileImports`：它依赖文件的名字索引，按键时要为当前文件重算
pub const ShapeImports = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = FileId;
    pub const Value = struct {
        arena: std.heap.ArenaAllocator.State,
        names: []const []const u8 = &.{},
        targets: []const ?FileId = &.{},

        pub fn get(value: Value, name: []const u8) ?FileId {
            for (value.names, value.targets) |n, target| if (std.mem.eql(u8, n, name)) return target;
            return null;
        }
    };

    pub fn compute(ctx: *database.Db.Ctx, file: Key) engine.Error!Value {
        const gpa = ctx.db.gpa;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const shapes = try ctx.get(InitShapes, file);
        const graph = try ctx.get(database.ModuleGraph.Input, {});
        var names: std.ArrayList([]const u8) = .empty;
        var targets: std.ArrayList(?FileId) = .empty;
        for (shapes.shapes) |shape| {
            const spec = switch (shape.base) {
                .import => |spec| spec,
                else => continue,
            };
            if (std.mem.endsWith(u8, spec, ".zig") or std.mem.endsWith(u8, spec, ".zon")) continue;
            for (names.items) |n| {
                if (std.mem.eql(u8, n, spec)) break;
            } else {
                try names.append(a, try a.dupe(u8, spec));
                try targets.append(a, if (graph) |g| g.importTarget(file, spec) else null);
            }
        }
        return .{ .arena = arena.state, .names = names.items, .targets = targets.items };
    }

    pub fn eql(a: Value, b: Value) bool {
        return deepEql(a.names, b.names) and deepEql(a.targets, b.targets);
    }

    pub fn bytes(value: Value) usize {
        return mem.arenaBytes(value.arena);
    }

    pub fn deinit(value: *Value, gpa: Allocator) void {
        var arena = value.arena.promote(gpa);
        arena.deinit();
    }
};

/// 文件中各声明指向的命名空间与别名的规范目标（按 `DeclIndex.decls` 的下标），由 `Eval` 跨文件求值。补全与
/// 展开各个导出闭包都要用到；只依赖各文件的 `FileDecls` 与 `InitShapes`，按键时只需验证
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
        var eval: Eval = .{ .r = &r, .temp = scratch.allocator() };
        const namespaces = try a.alloc(?Namespace, index.decls.len);
        const targets = try a.alloc(Declaration, index.decls.len);
        for (index.decls, namespaces, targets) |decl, *ns, *target| {
            ns.* = try eval.namespaceOf(file, decl.item);
            target.* = try eval.targetOf(file, decl.item);
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
        const Pending = struct { ns: Namespace, path: []const u8 };
        var queue: std.ArrayList(Pending) = .empty;
        var seen: std.AutoHashMapUnmanaged(Namespace, void) = .empty;
        try queue.append(temp, .{ .ns = key.ns, .path = "" });
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
                    .kind = decl.kind,
                    .is_extern = decl.is_extern,
                    .file = current.ns.file,
                    .item = decl.item,
                    .target = links.targets[d],
                    .doc = decl.doc,
                });
                const ns = links.namespaces[d] orelse continue;
                const entry = try seen.getOrPut(temp, ns);
                if (!entry.found_existing) try queue.append(temp, .{ .ns = ns, .path = path });
            }
        }
        std.mem.sort(Export, out.items, {}, nameLess(Export));
        const decls = try a.dupe(Export, out.items);
        const index = try gpa.create(ExportIndex);
        index.* = .{ .arena = arena.state, .decls = decls };
        return index;
    }
    /// 名字与文档指向 `FileDecls` 的值，按指针比较：同一个值才相等。被替换的旧值可能已经释放，不能读取内容
    pub fn eql(a: Value, b: Value) bool {
        if (a.decls.len != b.decls.len) return false;
        for (a.decls, b.decls) |x, y| {
            if (!sameSlice(x.name, y.name)) return false;
            if ((x.doc == null) != (y.doc == null) or (x.doc != null and !sameSlice(x.doc.?, y.doc.?))) return false;
            if (!std.mem.eql(u8, x.path, y.path) or x.kind != y.kind or x.is_extern != y.is_extern) return false;
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

pub fn complete(r: *Resolver, file: FileId, offset: u32, owner: Owner, prefix: []const u8, limit: usize) resolve.Error!Result {
    if (prefix.len == 0 or !isZigSource(r.ctx.db.env.vfs.path(file))) return .{ .items = &.{} };
    var builder: Builder = .{ .r = r, .file = file, .offset = offset, .prefix = prefix, .limit = limit };
    const current = try r.ctx.get(FileDecls, file);
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
    // 已有命名空间别名优先，不为同一入口再生成 import。
    for (top.items) |alias| {
        const decl = alias.decl;
        const ns = alias.ns orelse continue;
        const exports = try r.ctx.get(Exports, .{ .ns = ns });
        const declared_matches = exports.matching(prefix);
        if (declared_matches.len == 0 and (ns.file != file or matches.start == matches.end)) continue;
        if (!try builder.refersToSelf(decl)) continue;
        const root = try renderName(r.arena, decl.name);
        for (declared_matches) |declared| {
            if (try builder.reuseDirect(declared.target, declared.name, declared.kind, declared.doc)) continue;
            const sort = builder.sortOf(declared.name, "~0");
            if (builder.rejects(sort, &.{ root, ".", declared.path })) continue;
            if (try builder.visible(declared.name) != null) continue;
            try builder.reused.put(r.arena, declared.target, {});
            try builder.add(.{ .label = try joinPath(r.arena, root, declared.path), .kind = candidateKind(declared.kind), .filter = declared.name, .qualifier = root, .sort = sort, .doc = declared.doc, .target = .{ .decl = .{ .file = declared.file, .item = declared.item } } });
        }
        // 同文件可访问私有成员，公开闭包仍由所有请求共享。
        if (ns.file == file) for (current.decls[matches.start..matches.end], links.targets[matches.start..matches.end]) |nested, target| {
            if (try builder.reuseDirect(target, nested.name, nested.kind, nested.doc)) continue;
            const relative = try localRelative(r.arena, current, ns, nested) orelse continue;
            const sort = builder.sortOf(nested.name, "~0");
            if (builder.rejects(sort, &.{ root, ".", relative })) continue;
            if (try builder.visible(nested.name) != null) continue;
            try builder.reused.put(r.arena, target, {});
            try builder.add(.{ .label = try joinPath(r.arena, root, relative), .kind = candidateKind(nested.kind), .filter = nested.name, .qualifier = root, .sort = sort, .doc = nested.doc, .target = .{ .decl = .{ .file = file, .item = nested.item } } });
        };
    }
    // 同文件的私有链合法；可见的顶层名由普通补全负责。
    for (current.decls[matches.start..matches.end], links.targets[matches.start..matches.end]) |decl, target| {
        if (try builder.reuseDirect(target, decl.name, decl.kind, decl.doc)) continue;
        const root_name = decl.root orelse continue;
        const sort = builder.sortOf(decl.name, "~1");
        if (builder.rejects(sort, &.{decl.path})) continue;
        if (try builder.visible(decl.name) != null) continue;
        const root_def = try builder.visible(root_name) orelse continue;
        const expected = findRoot(current, root_name) orelse continue;
        if (!deepEql(root_def, resolve.Def{ .item = .{ .file = file, .item = expected.item } })) continue;
        try builder.add(.{ .label = try r.arena.dupe(u8, decl.path), .kind = candidateKind(decl.kind), .filter = decl.name, .qualifier = try r.arena.dupe(u8, root_name), .sort = sort, .doc = decl.doc, .target = .{ .decl = .{ .file = file, .item = decl.item } } });
    }
    if (graph) |g| {
        // 模块名字即使没有任何声明也可补全；生成文件根未知时不提供。
        const names = try g.importNames(r.arena, file);
        for ([_][]const []const u8{ &.{ "std", "builtin" }, names }) |group| for (group) |name| {
            const target = g.importTarget(file, name) orelse continue;
            const ns: Namespace = .{ .file = target, .container = 0 };
            const spec = try r.arena.dupe(u8, name);
            if (std.ascii.startsWithIgnoreCase(name, prefix) and try builder.namespaceAlias(ns) == null and try builder.visible(name) == null)
                try builder.importCandidate(name, .module, false, spec, "", null, "~2", .{ .file = target });
            try builder.exported(ns, spec);
        };
        // 项目文件只查询小索引的前缀区间，不在按键路径扫描 ItemTree/Body。
        for (g.files) |entry| {
            if (entry.file == file or entry.module == database.ModuleGraph.std_module) continue;
            const path = r.ctx.db.env.vfs.path(entry.file);
            if (!isZigSource(path)) continue;
            const index = try r.ctx.get(FileDecls, entry.file);
            const public = index.matchingPublic(prefix);
            const ns: Namespace = .{ .file = entry.file, .container = 0 };
            const basename = std.fs.path.basename(path);
            const stem = basename[0 .. basename.len - ".zig".len];
            const stem_matches = std.ascii.startsWithIgnoreCase(stem, prefix);
            if (public.len == 0 and !stem_matches) continue;
            const spec = try importSpec(r, g, file, entry.file) orelse continue;
            const aliased = try builder.namespaceAlias(ns) != null;
            if (stem_matches and !aliased and try builder.visible(stem) == null)
                try builder.importCandidate(stem, .file, false, spec, "", null, "~3", .{ .file = entry.file });
            if (aliased or public.len == 0) continue;
            const targets = (try r.ctx.get(FileLinks, entry.file)).targets;
            for (public) |p| {
                const decl = index.decls[p.decl];
                const target = targets[p.decl];
                if (try builder.reuseDirect(target, decl.name, decl.kind, decl.doc)) continue;
                if (builder.reused.contains(target)) continue;
                try builder.importIfVisible(decl.name, candidateKind(decl.kind), decl.is_extern, spec, p.path, decl.doc, if (std.mem.indexOfScalar(u8, p.path, '.') == null) "~3" else "~4", .{ .decl = .{ .file = entry.file, .item = decl.item } });
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

/// 当前文件的顶层 const 及其指向的命名空间、规范目标
const Alias = struct { decl: *const Decl, ns: ?Namespace, target: Declaration };

const Builder = struct {
    r: *Resolver,
    file: FileId,
    offset: u32,
    prefix: []const u8,
    limit: usize,
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
    items: std.ArrayList(Candidate) = .empty,
    /// `items` 已满时排序最差的一项；`items` 变化后重新计算
    worst: ?usize = null,
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
    fn reuseDirect(b: *Builder, target: Declaration, name: []const u8, kind: ItemTree.Item.Kind, doc: ?[]const u8) resolve.Error!bool {
        const alias = try b.directAlias(target) orelse return false;
        // 别名与目标共享前缀时，继续输入后须重新选择过滤名字，不能沿用另一条拼写。
        if (!std.mem.eql(u8, alias.name, name) and std.ascii.startsWithIgnoreCase(alias.name, b.prefix)) b.incomplete = true;
        try b.add(.{ .label = try renderName(b.r.arena, alias.name), .kind = candidateKind(kind), .filter = name, .qualifier = "", .sort = b.sortOf(name, "~0"), .doc = doc, .target = .{ .decl = .{ .file = b.file, .item = alias.item } } });
        try b.reused.put(b.r.arena, target, {});
        return true;
    }
    /// 分组为 `group` 的候选的排序（见 `caseMark`）
    fn sortOf(b: *const Builder, name: []const u8, comptime group: []const u8) []const u8 {
        return if (caseMark(name, b.prefix).len == 0) group else "~" ++ group;
    }
    fn add(b: *Builder, candidate: Candidate) resolve.Error!void {
        for (b.items.items) |existing| {
            if (std.mem.eql(u8, existing.label, candidate.label) and std.mem.eql(u8, existing.qualifier, candidate.qualifier)) return;
        }
        if (b.items.items.len < b.limit) {
            try b.items.append(b.r.arena, candidate);
            b.worst = null;
        } else {
            b.incomplete = true;
            // 保留排序最好的有限个结果；截断不受图中 FileId 顺序影响。
            if (b.limit == 0) return;
            const worst = b.worstIndex();
            if (candidateLess({}, candidate, b.items.items[worst])) {
                b.items.items[worst] = candidate;
                b.worst = null;
            }
        }
    }
    fn worstIndex(b: *Builder) usize {
        if (b.worst) |worst| return worst;
        var worst: usize = 0;
        for (b.items.items, 0..) |item, i| if (candidateLess({}, b.items.items[worst], item)) {
            worst = i;
        };
        b.worst = worst;
        return worst;
    }
    /// 已满且排序（`sort`，再按依次拼接 `label` 各段得到的标签）比最差的一项差：不会进入结果，不必构造这一项，
    /// 也不必检查它是否可见。短前缀可以匹配到上千个声明，只有排序最好的 `limit` 个需要构造。`label` 为 null
    /// 时只比较 `sort`
    fn rejects(b: *Builder, sort: []const u8, label: ?[]const []const u8) bool {
        if (b.items.items.len < b.limit) return false;
        b.incomplete = true;
        if (b.limit == 0) return true;
        const worst = b.items.items[b.worstIndex()];
        return switch (std.mem.order(u8, sort, worst.sort)) {
            .lt => false,
            .gt => true,
            .eq => if (label) |parts| orderJoined(parts, worst.label) == .gt else false,
        };
    }
    fn exported(b: *Builder, ns: Namespace, spec: []const u8) resolve.Error!void {
        if (try b.namespaceAlias(ns) != null) return;
        const index = try b.r.ctx.get(Exports, .{ .ns = ns });
        for (index.matching(b.prefix)) |decl| {
            if (try b.reuseDirect(decl.target, decl.name, decl.kind, decl.doc)) continue;
            if (b.reused.contains(decl.target)) continue;
            try b.importIfVisible(decl.name, candidateKind(decl.kind), decl.is_extern, spec, decl.path, decl.doc, if (std.mem.indexOfScalar(u8, decl.path, '.') == null) "~3" else "~4", .{ .decl = .{ .file = decl.file, .item = decl.item } });
        }
    }
    /// 名字在当前位置不可见时提供 import；先按排序淘汰，再检查可见性
    fn importIfVisible(b: *Builder, name: []const u8, kind: @FieldType(Candidate, "kind"), is_extern: bool, spec: []const u8, path: []const u8, doc: ?[]const u8, rank: []const u8, target: Target) resolve.Error!void {
        var buf: [256]u8 = undefined;
        const args = importSortArgs(b.prefix, name, spec, path, rank);
        const sort = std.fmt.bufPrint(&buf, import_sort, args) catch try std.fmt.allocPrint(b.r.arena, import_sort, args);
        if (b.rejects(sort, null)) return;
        if (try b.visible(name) != null) return;
        try b.importCandidate(name, kind, is_extern, spec, path, doc, rank, target);
    }
    fn importCandidate(b: *Builder, name: []const u8, kind: @FieldType(Candidate, "kind"), is_extern: bool, spec: []const u8, path: []const u8, doc: ?[]const u8, rank: []const u8, target: Target) resolve.Error!void {
        const a = b.r.arena;
        const sort = try std.fmt.allocPrint(a, import_sort, importSortArgs(b.prefix, name, spec, path, rank));
        if (b.rejects(sort, null)) return;
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
        try b.add(.{ .label = label, .kind = kind, .filter = name, .qualifier = qualifier, .sort = sort, .doc = doc, .import_edit = edit, .target = target });
    }
};

/// 名字按前缀不区分大小写匹配；前缀的大小写与输入不一致时，排序前面加 `~`：排在所有大小写一致的候选之后，各自的
/// 相对顺序不变，截断时不挤掉大小写一致的候选
fn caseMark(name: []const u8, prefix: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, prefix)) "" else "~";
}

/// import 候选的排序（见 `caseMark`）：同目录的文件、其他相对路径、命名模块依次靠后，再按层级、路径长度、名字长度
/// 与来源
const import_sort = "{s}~2:{d}:{s}:{d:0>6}:{d:0>4}:{s}{s}{s}";

fn importSortArgs(prefix: []const u8, name: []const u8, spec: []const u8, path: []const u8, rank: []const u8) struct { []const u8, u8, []const u8, usize, usize, []const u8, []const u8, []const u8 } {
    const origin: u8 = if (!std.mem.endsWith(u8, spec, ".zig")) 2 else if (std.mem.indexOfScalar(u8, spec, '/') == null) 0 else 1;
    return .{ caseMark(name, prefix), origin, rank, spec.len + path.len, name.len, spec, if (path.len == 0) "" else ":", path };
}

/// `parts` 依次拼接后与 `other` 比较
fn orderJoined(parts: []const []const u8, other: []const u8) std.math.Order {
    var rest = other;
    for (parts) |part| {
        const n = @min(part.len, rest.len);
        const order = std.mem.order(u8, part[0..n], rest[0..n]);
        if (order != .eq) return order;
        if (part.len > rest.len) return .gt;
        rest = rest[part.len..];
    }
    return if (rest.len == 0) .eq else .lt;
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
/// `decl` 相对同文件命名空间 `ns` 的路径
fn localRelative(a: Allocator, index: *const DeclIndex, ns: Namespace, decl: Decl) Allocator.Error!?[]const u8 {
    if (ns.container == 0) return decl.path;
    for (index.decls) |parent| {
        if (parent.local) |container| if (container == ns.container) {
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
