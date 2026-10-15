//! ItemTree：文件的声明骨架。
//!
//! 只记录「有哪些容器、每个容器有哪些成员、成员的名字 / 种类 / 修饰符 / 签名哈希 / 文档」，
//! 不记录任何位置信息，也不包含函数体与初始化表达式的内容。只改函数体时 ItemTree 不变，
//! 依赖它的名字解析与签名类型查询因此不会失效（early cutoff）。
//!
//! 位置通过 `AstId` 在 `AstIdMap` 中查找。函数体内部定义的容器（如泛型类型构造函数返回的
//! `struct {...}`）也会收录，因为它们的成员是名字解析的一部分。

const std = @import("std");
const Allocator = std.mem.Allocator;
const tree = @import("tree.zig");
const SyntaxNode = tree.SyntaxNode;
const SyntaxKind = @import("kind.zig").SyntaxKind;
const isTrivia = @import("kind.zig").isTrivia;
const ast = @import("ast.zig");

const ItemTree = @This();

arena: std.heap.ArenaAllocator.State,
/// 下标 0 为文件本身
containers: []const Container,
items: []const Item,
/// 各容器的成员（`items` 下标），按 `Container.members` 切分
member_list: []const u32,

/// 文件内稳定的节点 ID：由父节点 ID、种类、名字与同名序号哈希而来，
/// 在不改名、不移动的前提下跨编辑保持不变。
pub const AstId = enum(u32) { _ };

pub const Container = struct {
    ast_id: AstId,
    kind: Kind,
    /// 词法上包含本容器的成员（文件根为 null）
    parent_item: ?u32,
    members: struct { start: u32, len: u32 },
    /// `packed` / `extern`（布局与 ABI 大小的计算读取它，不必再读语法树）
    layout: Layout = .auto,
    /// `union(enum)`：标签类型由编译器生成
    auto_enum: bool = false,

    pub const Kind = enum { file, @"struct", @"enum", @"union", @"opaque" };
    pub const Layout = enum { auto, @"packed", @"extern" };
};

pub const Item = struct {
    ast_id: AstId,
    kind: Kind,
    /// 元组字段、comptime 块与匿名 test 没有名字
    name: ?[]const u8,
    container: u32,
    flags: Flags,
    /// 签名部分的结构哈希：函数原型、变量类型注解与对齐等、字段类型；不含函数体与初始化表达式
    sig_hash: u64,
    /// 文档注释正文（已去掉 `///` 前缀），多行以 `\n` 连接
    doc: ?[]const u8,

    pub const Kind = enum { @"fn", @"const", @"var", field, @"test", @"comptime" };

    pub const Flags = packed struct(u8) {
        is_pub: bool = false,
        is_extern: bool = false,
        is_export: bool = false,
        is_inline: bool = false,
        is_comptime: bool = false,
        is_threadlocal: bool = false,
        /// 函数的返回类型为 `!T`（推导的错误集）
        inferred_error_set: bool = false,
        /// 函数的参数列表中有不绑定的参数（`...`）：只能在末尾
        varargs: bool = false,
    };
};

pub fn deinit(self: *ItemTree, gpa: Allocator) void {
    var arena = self.arena.promote(gpa);
    arena.deinit();
    self.* = undefined;
}

/// 字段可以只写名字（枚举成员、联合的 void 字段），名字位于类型表达式的位置
pub fn bareFieldNames(kind: Container.Kind) bool {
    return kind == .@"enum" or kind == .@"union";
}

pub fn containerMembers(self: *const ItemTree, container: u32) []const u32 {
    const m = self.containers[container].members;
    return self.member_list[m.start..][0..m.len];
}

pub fn eql(a: *const ItemTree, b: *const ItemTree) bool {
    if (a.containers.len != b.containers.len or a.items.len != b.items.len) return false;
    if (!std.mem.eql(u32, a.member_list, b.member_list)) return false;
    for (a.containers, b.containers) |x, y| {
        if (x.ast_id != y.ast_id or x.kind != y.kind or x.parent_item != y.parent_item) return false;
        if (x.layout != y.layout or x.auto_enum != y.auto_enum) return false;
        if (x.members.start != y.members.start or x.members.len != y.members.len) return false;
    }
    for (a.items, b.items) |x, y| {
        if (x.ast_id != y.ast_id or x.kind != y.kind or x.container != y.container) return false;
        if (@as(u8, @bitCast(x.flags)) != @as(u8, @bitCast(y.flags)) or x.sig_hash != y.sig_hash) return false;
        if (!optStrEql(x.name, y.name) or !optStrEql(x.doc, y.doc)) return false;
    }
    return true;
}

fn optStrEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

// ── 构建 ─────────────────────────────────────────────────────────────

pub fn build(gpa: Allocator, root: SyntaxNode) Allocator.Error!ItemTree {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var b: Builder = .{ .gpa = gpa, .arena = arena.allocator() };
    defer b.deinit();

    const file_id = mixId(0, "file", "", 0);
    try b.taken.put(gpa, file_id, {});
    try b.containers.append(gpa, .{ .ast_id = file_id, .kind = .file, .parent_item = null, .members = undefined });
    try b.visitContainer(root, 0);

    // 按容器顺序排列成员列表
    var member_list: std.ArrayList(u32) = .empty;
    for (b.containers.items, b.pending_members.items) |*c, members| {
        c.members = .{ .start = @intCast(member_list.items.len), .len = @intCast(members.items.len) };
        try member_list.appendSlice(b.arena, members.items);
    }
    const containers = try b.arena.dupe(Container, b.containers.items);
    const items = try b.arena.dupe(Item, b.items.items);
    return .{ .arena = arena.state, .containers = containers, .items = items, .member_list = member_list.items };
}

const Builder = struct {
    gpa: Allocator,
    arena: Allocator,
    containers: std.ArrayList(Container) = .empty,
    /// 与 `containers` 一一对应，构建过程中收集各容器的成员
    pending_members: std.ArrayList(std.ArrayList(u32)) = .empty,
    items: std.ArrayList(Item) = .empty,
    taken: std.AutoHashMapUnmanaged(AstId, void) = .empty,

    fn deinit(b: *Builder) void {
        b.containers.deinit(b.gpa);
        b.pending_members.deinit(b.gpa);
        b.items.deinit(b.gpa);
        b.taken.deinit(b.gpa);
    }

    /// `node` 为 source_file 或 container_decl，`index` 为已登记的容器下标
    fn visitContainer(b: *Builder, node: SyntaxNode, index: u32) Allocator.Error!void {
        while (b.pending_members.items.len <= index) try b.pending_members.append(b.gpa, .empty);
        const container_id = b.containers.items[index].ast_id;
        var it = node.children();
        while (it.nextNode()) |member| {
            const kind: Item.Kind = switch (member.kind()) {
                .fn_decl => .@"fn",
                .var_decl => if (member.childToken(.keyword_var) != null) .@"var" else .@"const",
                .container_field => .field,
                .test_decl => .@"test",
                .comptime_decl => .@"comptime",
                else => continue,
            };
            const name = if (ast.memberName(member, bareFieldNames(b.containers.items[index].kind))) |t| ast.identName(t.text) else null;
            const item_index: u32 = @intCast(b.items.items.len);
            try b.items.append(b.gpa, .{
                .ast_id = try b.uniqueId(container_id, @tagName(kind), name orelse ""),
                .kind = kind,
                .name = if (name) |n| try b.arena.dupe(u8, n) else null,
                .container = index,
                .flags = fnFlags(member, memberFlags(member)),
                .sig_hash = signatureHash(member, kind),
                .doc = try b.docText(member),
            });
            try b.pending_members.items[index].append(b.arena, item_index);
            try b.visitNested(member, item_index);
        }
    }

    /// 在成员子树中查找容器定义（含函数体内部），不进入已找到容器的内部
    fn visitNested(b: *Builder, node: SyntaxNode, parent_item: u32) Allocator.Error!void {
        var it = node.children();
        while (it.nextNode()) |c| {
            if (c.kind() != .container_decl) {
                try b.visitNested(c, parent_item);
                continue;
            }
            const index: u32 = @intCast(b.containers.items.len);
            const kind = containerKind(c);
            try b.containers.append(b.gpa, .{
                .ast_id = try b.uniqueId(b.items.items[parent_item].ast_id, "container", ""),
                .kind = kind,
                .parent_item = parent_item,
                .members = undefined,
                .layout = if (c.childToken(.keyword_packed) != null) .@"packed" else if (c.childToken(.keyword_extern) != null) .@"extern" else .auto,
                .auto_enum = kind == .@"union" and c.childToken(.keyword_enum) != null,
            });
            try b.visitContainer(c, index);
        }
    }

    /// 同一父节点下相同（种类, 名字）的第 n 个
    fn uniqueId(b: *Builder, parent: AstId, kind: []const u8, name: []const u8) Allocator.Error!AstId {
        var ordinal: u32 = 0;
        while (true) : (ordinal += 1) {
            const id = mixId(@backingInt(parent), kind, name, ordinal);
            if (!(try b.taken.getOrPut(b.gpa, id)).found_existing) return id;
        }
    }

    fn docText(b: *Builder, member: SyntaxNode) Allocator.Error!?[]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var it = member.children();
        while (it.next()) |e| {
            if (e != .token) break;
            if (e.token.kind != .doc_comment) {
                if (isTrivia(e.token.kind)) continue;
                break;
            }
            var line = e.token.text["///".len..];
            if (std.mem.startsWith(u8, line, " ")) line = line[1..];
            if (out.items.len != 0) try out.append(b.arena, '\n');
            try out.appendSlice(b.arena, std.mem.trimEnd(u8, line, "\r"));
        }
        return if (out.items.len == 0) null else out.items;
    }
};

fn mixId(parent: u32, kind: []const u8, name: []const u8, ordinal: u32) AstId {
    var h: std.hash.Wyhash = .init(parent);
    h.update(kind);
    h.update(&.{0});
    h.update(name);
    h.update(std.mem.asBytes(&ordinal));
    return @fromBackingInt(@as(u32, @truncate(h.final())));
}

/// 函数原型中下游需要的语法信息（避免签名推导为此读取每次编辑都会变化的语法树）
fn fnFlags(member: SyntaxNode, base: Item.Flags) Item.Flags {
    var flags = base;
    const proto = (ast.cast(ast.FnDecl, member) orelse return flags).proto() orelse return flags;
    flags.inferred_error_set = proto.inferredErrorSet();
    var it = proto.params();
    while (it.next()) |p| {
        const param = ast.cast(ast.Param, p).?;
        if (param.name() == null and param.typeExpr() == null) flags.varargs = true;
    }
    return flags;
}

fn memberFlags(member: SyntaxNode) Item.Flags {
    var flags: Item.Flags = .{};
    var it = member.children();
    while (it.next()) |e| {
        if (e != .token) {
            if (e.node.kind() == .fn_proto) continue;
            break;
        }
        switch (e.token.kind) {
            .keyword_pub => flags.is_pub = true,
            .keyword_extern => flags.is_extern = true,
            .keyword_export => flags.is_export = true,
            .keyword_inline => flags.is_inline = true,
            .keyword_comptime => flags.is_comptime = true,
            .keyword_threadlocal => flags.is_threadlocal = true,
            .keyword_const, .keyword_var, .identifier, .keyword_fn => break,
            else => {},
        }
    }
    return flags;
}

fn containerKind(node: SyntaxNode) Container.Kind {
    var it = node.children();
    while (it.next()) |e| switch (e.kind()) {
        .keyword_struct => return .@"struct",
        .keyword_enum => return .@"enum",
        .keyword_union => return .@"union",
        .keyword_opaque => return .@"opaque",
        else => {},
    };
    return .@"struct";
}

/// 签名哈希：对签名部分的非 trivia token（种类与文本）做哈希，容器定义只计入其头部。
fn signatureHash(member: SyntaxNode, kind: Item.Kind) u64 {
    var h: std.hash.Wyhash = .init(0);
    switch (kind) {
        .@"fn" => if (member.childNode(.fn_proto)) |proto| hashTokens(&h, proto),
        .@"const", .@"var" => {
            // 名字之后、`=` 之前：类型注解与 align / addrspace / linksection
            var it = member.children();
            var seen_name = false;
            while (it.next()) |e| {
                if (e == .token) {
                    if (e.token.kind == .equal) break;
                    if (e.token.kind == .identifier) seen_name = true;
                    if (seen_name and !isTrivia(e.token.kind)) hashToken(&h, e.token);
                } else if (seen_name) hashTokens(&h, e.node);
            }
            // 初始化为容器定义时计入容器头（种类、参数），成员另行记录
            if (initContainer(member)) |c| hashContainerHead(&h, c);
        },
        .field => {
            var it = member.children();
            while (it.next()) |e| {
                if (e == .token) {
                    if (e.token.kind == .equal) break;
                    if (!isTrivia(e.token.kind) and e.token.kind != .doc_comment) hashToken(&h, e.token);
                } else if (e.node.kind() == .container_decl) {
                    hashContainerHead(&h, e.node);
                } else hashTokens(&h, e.node);
            }
        },
        .@"test", .@"comptime" => {},
    }
    return h.final();
}

fn initContainer(member: SyntaxNode) ?SyntaxNode {
    var it = member.children();
    var after_equal = false;
    while (it.next()) |e| {
        if (e == .token and e.token.kind == .equal) after_equal = true;
        if (after_equal and e == .node) return if (e.node.kind() == .container_decl) e.node else null;
    }
    return null;
}

fn hashContainerHead(h: *std.hash.Wyhash, node: SyntaxNode) void {
    var it = node.children();
    while (it.next()) |e| {
        if (e == .token) {
            if (e.token.kind == .l_brace) break;
            if (!isTrivia(e.token.kind)) hashToken(h, e.token);
        } else hashTokens(h, e.node);
    }
}

fn hashToken(h: *std.hash.Wyhash, t: tree.SyntaxToken) void {
    h.update(std.mem.asBytes(&t.kind));
    h.update(t.text);
}

fn hashTokens(h: *std.hash.Wyhash, node: SyntaxNode) void {
    var it = node.children();
    while (it.next()) |e| switch (e) {
        .token => |t| if (!isTrivia(t.kind)) hashToken(h, t),
        .node => |c| hashTokens(h, c),
    };
}

// ── AstId → 节点 ─────────────────────────────────────────────────────

/// 某个解析结果中 AstId 到节点的映射。每次重新解析后重建（廉价），用于把稳定 ID 换回当前树上的节点。
pub const AstIdMap = struct {
    map: std.AutoArrayHashMapUnmanaged(AstId, SyntaxNode) = .empty,

    pub fn deinit(m: *AstIdMap, gpa: Allocator) void {
        m.map.deinit(gpa);
    }

    /// 哈希表占用的字节数（节点本身属于语法树，不计入）
    pub fn bytes(m: *const AstIdMap) usize {
        return m.map.capacity() * (@sizeOf(AstId) + @sizeOf(SyntaxNode) + @sizeOf(u32));
    }

    pub fn get(m: *const AstIdMap, id: AstId) ?SyntaxNode {
        return m.map.get(id);
    }

    /// `item_tree` 必须由同一棵语法树构建
    pub fn build(gpa: Allocator, item_tree: *const ItemTree, root: SyntaxNode) Allocator.Error!AstIdMap {
        var result: AstIdMap = .{};
        errdefer result.deinit(gpa);
        try result.map.ensureTotalCapacity(gpa, item_tree.items.len + item_tree.containers.len);
        // 与 Builder 相同的遍历顺序：容器与成员按出现顺序编号
        var c_index: u32 = 0;
        var i_index: u32 = 0;
        result.map.putAssumeCapacity(item_tree.containers[0].ast_id, root);
        c_index += 1;
        walk(item_tree, root, &result, &c_index, &i_index);
        return result;
    }

    fn walk(item_tree: *const ItemTree, node: SyntaxNode, m: *AstIdMap, c_index: *u32, i_index: *u32) void {
        var it = node.children();
        while (it.nextNode()) |member| {
            switch (member.kind()) {
                .fn_decl, .var_decl, .container_field, .test_decl, .comptime_decl => {},
                else => continue,
            }
            m.map.putAssumeCapacity(item_tree.items[i_index.*].ast_id, member);
            i_index.* += 1;
            walkNested(item_tree, member, m, c_index, i_index);
        }
    }

    fn walkNested(item_tree: *const ItemTree, node: SyntaxNode, m: *AstIdMap, c_index: *u32, i_index: *u32) void {
        var it = node.children();
        while (it.nextNode()) |c| {
            if (c.kind() != .container_decl) {
                walkNested(item_tree, c, m, c_index, i_index);
                continue;
            }
            m.map.putAssumeCapacity(item_tree.containers[c_index.*].ast_id, c);
            c_index.* += 1;
            walk(item_tree, c, m, c_index, i_index);
        }
    }
};

test {
    _ = @import("ItemTree_test.zig");
}
