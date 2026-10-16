//! 名字解析：局部作用域 → 词法外层容器链；`a.b.c` 沿 `@import`、容器定义、
//! `@This()` 与别名链求出命名空间后查找成员。不做类型推导：经由函数调用、变量类型得到的
//! 命名空间（如 `std.ArrayList(u8)`、`var x: S` 的 `x.`）由 sema 处理。

const std = @import("std");
const Allocator = std.mem.Allocator;
const database = @import("../database.zig");
const Db = database.Db;
const syntax = database.syntax;
const hir = database.hir;
const ModuleGraph = @import("ModuleGraph.zig");
const Vfs = @import("../base/Vfs.zig");
const FileId = Vfs.FileId;
const ItemTree = @import("../syntax/ItemTree.zig");
const ast = @import("../syntax/ast.zig");
const SyntaxNode = ast.SyntaxNode;
const Body = @import("../hir/Body.zig");

/// 名字解析的结果
pub const Def = union(enum) {
    /// 容器成员（`ItemTree.items` 下标）
    item: struct { file: FileId, item: u32 },
    /// 局部绑定：参数、局部变量、捕获（`item` 为所在 BodyOwner）
    local: struct { file: FileId, item: u32, binding: Body.BindingId },
    /// `@import` 的目标文件
    file: FileId,
};

/// 可以做成员访问的命名空间：文件中的一个容器（0 为文件本身）
pub const Namespace = struct {
    file: FileId,
    container: u32,
};

pub const Error = error{ Canceled, OutOfMemory };

/// 别名链的最大长度，防止 `const a = b; const b = a;` 这类环
const max_depth = 64;

pub const Resolver = struct {
    ctx: *Db.Ctx,
    arena: Allocator,

    fn vfs(r: *Resolver) *Vfs {
        return r.ctx.db.env.vfs;
    }

    pub fn itemTree(r: *Resolver, file: FileId) Error!*const ItemTree {
        return r.ctx.get(syntax.FileItemTree, file);
    }

    pub fn ownerKey(r: *Resolver, file: FileId, item: u32) Error!hir.OwnerKey {
        return .{ .file = file, .item = (try r.itemTree(file)).items[item].ast_id };
    }

    pub fn body(r: *Resolver, file: FileId, item: u32) Error!*const Body {
        return r.ctx.get(hir.ItemBody, try r.ownerKey(file, item));
    }

    /// 成员节点（当前语法树中）
    pub fn itemNode(r: *Resolver, file: FileId, item: u32) Error!?SyntaxNode {
        const tree = try r.itemTree(file);
        return (try r.ctx.get(syntax.FileAstIdMap, file)).get(tree.items[item].ast_id);
    }

    /// 成员在文件中的起始位置：只需要位置时用它，不依赖解析结果（可能已被淘汰）
    pub fn itemOffset(r: *Resolver, file: FileId, item: u32) Error!?u32 {
        return (try r.ctx.get(syntax.ItemSummaries, file)).items[item].offset;
    }

    /// 容器在文件中的起始位置（同 `itemOffset`，不依赖解析结果）
    pub fn containerOffset(r: *Resolver, ns: Namespace) Error!?u32 {
        const s = try r.ctx.get(syntax.ItemSummaries, ns.file);
        if (ns.container >= s.container_offsets.len) return null;
        return s.container_offsets[ns.container];
    }

    /// 成员 `item` 体内、相对其起始位置 `rel` 处定义的容器
    pub fn containerAt(r: *Resolver, file: FileId, item: u32, rel: u32) Error!?Namespace {
        const tree = try r.itemTree(file);
        const owner = try r.itemOffset(file, item) orelse return null;
        const s = try r.ctx.get(syntax.ItemSummaries, file);
        for (tree.containers, s.container_offsets, 0..) |c, offset, i| {
            if (c.parent_item != item) continue;
            if (offset == owner + rel) return .{ .file = file, .container = @intCast(i) };
        }
        return null;
    }

    /// 体内定义的容器 `ns` 相对于其外层成员起始位置的位置
    pub fn containerRel(r: *Resolver, ns: Namespace) Error!?u32 {
        const parent = (try r.itemTree(ns.file)).containers[ns.container].parent_item orelse return null;
        const owner = try r.itemOffset(ns.file, parent) orelse return null;
        const offset = try r.containerOffset(ns) orelse return null;
        return offset - owner;
    }

    /// 成员是否可能提到名字 `name`（有假阳性）：在生成 Body 之前粗筛
    pub fn mayMention(r: *Resolver, file: FileId, item: u32, name: []const u8) Error!bool {
        return (try r.ctx.get(syntax.ItemSummaries, file)).items[item].mayMention(name);
    }

    pub fn containerNode(r: *Resolver, ns: Namespace) Error!?SyntaxNode {
        const tree = try r.itemTree(ns.file);
        return (try r.ctx.get(syntax.FileAstIdMap, ns.file)).get(tree.containers[ns.container].ast_id);
    }

    // ── 名字查找 ─────────────────────────────────────────────────────

    /// 在 BodyOwner `item` 的 `scope` 处解析名字
    pub fn resolveName(r: *Resolver, file: FileId, item: u32, b: *const Body, scope: Body.ScopeId, name: []const u8) Error!?Def {
        if (b.lookup(scope, name)) |binding| return .{ .local = .{ .file = file, .item = item, .binding = binding } };
        const tree = try r.itemTree(file);
        var container = tree.items[item].container;
        while (true) {
            if (lookupDecl(tree, container, name)) |m| return .{ .item = .{ .file = file, .item = m } };
            // 容器定义在某个成员的体内：继续查该成员在容器位置可见的局部名字
            const parent = tree.containers[container].parent_item orelse return null;
            if (try r.localAtContainer(file, parent, container, name)) |def| return def;
            container = tree.items[parent].container;
        }
    }

    fn localAtContainer(r: *Resolver, file: FileId, parent: u32, container: u32, name: []const u8) Error!?Def {
        const rel = try r.containerRel(.{ .file = file, .container = container }) orelse return null;
        const pb = try r.body(file, parent);
        const binding = pb.lookup(pb.scopeAt(rel), name) orelse return null;
        return .{ .local = .{ .file = file, .item = parent, .binding = binding } };
    }

    /// 容器中可按名字直接引用的成员（声明；字段不是作用域中的名字）
    pub fn lookupDecl(tree: *const ItemTree, container: u32, name: []const u8) ?u32 {
        for (tree.containerMembers(container)) |m| {
            const it = tree.items[m];
            switch (it.kind) {
                .@"fn", .@"const", .@"var" => if (it.name) |n| if (std.mem.eql(u8, n, name)) return m,
                else => {},
            }
        }
        return null;
    }

    /// `ns.name`：声明；枚举还包括其成员（`E.a`）
    pub fn memberDef(r: *Resolver, ns: Namespace, name: []const u8) Error!?Def {
        const tree = try r.itemTree(ns.file);
        if (ns.container >= tree.containers.len) return null;
        if (lookupDecl(tree, ns.container, name)) |m| return .{ .item = .{ .file = ns.file, .item = m } };
        if (tree.containers[ns.container].kind == .@"enum") {
            for (tree.containerMembers(ns.container)) |m| {
                const it = tree.items[m];
                if (it.kind == .field and it.name != null and std.mem.eql(u8, it.name.?, name)) return .{ .item = .{ .file = ns.file, .item = m } };
            }
        }
        return null;
    }

    /// `const f = a.b.c;` 这类别名最终指向的定义；不是别名时为 `def` 本身
    pub fn aliasTarget(r: *Resolver, def: Def) Error!Def {
        var cur = def;
        for (0..max_depth) |_| {
            const it = switch (cur) {
                .item => |it| it,
                else => return cur,
            };
            if ((try r.itemTree(it.file)).items[it.item].kind != .@"const") return cur;
            const b = try r.body(it.file, it.item);
            const value = b.value orelse return cur;
            cur = switch (b.expr(value)) {
                .name_ref => |n| try r.resolveName(it.file, it.item, b, b.expr_scopes[@backingInt(value)], n),
                .field_access => |fa| if (try r.evalNamespace(it.file, it.item, b, fa.lhs)) |ns| try r.memberDef(ns, fa.field orelse return cur) else null,
                else => null,
            } orelse return cur;
        }
        return cur;
    }

    // ── 命名空间求值 ─────────────────────────────────────────────────

    /// 定义指向的命名空间（`const x = @import(...)`、`const S = struct {...}`、别名等）
    pub fn namespaceOf(r: *Resolver, def: Def) Error!?Namespace {
        return r.namespaceOfDepth(def, 0);
    }

    fn namespaceOfDepth(r: *Resolver, def: Def, depth: u32) Error!?Namespace {
        if (depth > max_depth) return null;
        switch (def) {
            .file => |f| return .{ .file = f, .container = 0 },
            .item => |it| {
                const tree = try r.itemTree(it.file);
                switch (tree.items[it.item].kind) {
                    .@"const", .@"var" => {},
                    else => return null,
                }
                const b = try r.body(it.file, it.item);
                const value = b.value orelse return null;
                return r.evalDepth(it.file, it.item, b, value, depth + 1);
            },
            .local => |l| {
                const b = try r.body(l.file, l.item);
                const init = b.binding(l.binding).init orelse return null;
                return r.evalDepth(l.file, l.item, b, init, depth + 1);
            },
        }
    }

    /// 表达式求值得到的命名空间
    pub fn evalNamespace(r: *Resolver, file: FileId, item: u32, b: *const Body, e: Body.ExprId) Error!?Namespace {
        return r.evalDepth(file, item, b, e, 0);
    }

    fn evalDepth(r: *Resolver, file: FileId, item: u32, b: *const Body, e: Body.ExprId, depth: u32) Error!?Namespace {
        if (depth > max_depth) return null;
        switch (b.expr(e)) {
            .name_ref => |name| {
                const def = try r.resolveName(file, item, b, b.expr_scopes[@backingInt(e)], name) orelse return null;
                return r.namespaceOfDepth(def, depth + 1);
            },
            .field_access => |fa| {
                const ns = try r.evalDepth(file, item, b, fa.lhs, depth + 1) orelse return null;
                const def = try r.memberDef(ns, fa.field orelse return null) orelse return null;
                return r.namespaceOfDepth(def, depth + 1);
            },
            .builtin_call => |call| {
                if (std.mem.eql(u8, call.name, "@import")) {
                    const target = try r.importTarget(file, b, call.args) orelse return null;
                    return r.namespaceOfDepth(.{ .file = target }, depth + 1);
                }
                if (std.mem.eql(u8, call.name, "@This")) {
                    return .{ .file = file, .container = (try r.itemTree(file)).items[item].container };
                }
                return null;
            },
            .container => return r.containerAt(file, item, b.range(e).start),
            .@"comptime" => |inner| return r.evalDepth(file, item, b, inner, depth + 1),
            else => return null,
        }
    }

    // ── import ───────────────────────────────────────────────────────

    /// `@import(args)` 的目标文件
    pub fn importTarget(r: *Resolver, file: FileId, b: *const Body, args: []const Body.ExprId) Error!?FileId {
        if (args.len != 1) return null;
        const raw = switch (b.expr(args[0])) {
            .literal => |text| text,
            else => return null,
        };
        const name = stringValue(r.arena, raw) orelse return null;
        return r.resolveImport(file, name);
    }

    pub fn resolveImport(r: *Resolver, file: FileId, name: []const u8) Error!?FileId {
        if (std.mem.endsWith(u8, name, ".zig") or std.mem.endsWith(u8, name, ".zon")) {
            const dir = std.fs.path.dirname(r.vfs().path(file)) orelse return null;
            return try r.vfs().intern(try std.fs.path.join(r.arena, &.{ dir, name }));
        }
        // 经由文件的 import 表：只依赖与本文件相关的部分（见 `FileImports`）
        if ((try r.ctx.get(ModuleGraph.FileImports, file)).get(name)) |target| return target;
        const graph = try r.ctx.get(ModuleGraph.Input, {}) orelse return null;
        return graph.importTarget(file, name);
    }

    // ── 位置 ─────────────────────────────────────────────────────────

    /// 包含 `offset` 的最内层成员（`inclusive_end`：光标位于成员末尾时也算在内）
    pub fn ownerAt(r: *Resolver, file: FileId, offset: u32, inclusive_end: bool) Error!?u32 {
        const tree = try r.itemTree(file);
        const map = try r.ctx.get(syntax.FileAstIdMap, file);
        var best: ?u32 = null;
        var best_len: u32 = std.math.maxInt(u32);
        for (tree.items, 0..) |it, i| {
            const node = map.get(it.ast_id) orelse continue;
            const range = node.range();
            const inside = range.start <= offset and (offset < range.end or (inclusive_end and offset == range.end));
            if (inside and range.end - range.start < best_len) {
                best = @intCast(i);
                best_len = range.end - range.start;
            }
        }
        return best;
    }

    /// 成员所在的容器是否允许只写名字的字段（枚举、联合；决定字段名字的位置）
    pub fn inEnum(r: *Resolver, file: FileId, item: u32) Error!bool {
        const tree = try r.itemTree(file);
        return ItemTree.bareFieldNames(tree.containers[tree.items[item].container].kind);
    }

    /// 定义所在的文件与名字位置（文件为开头）
    pub fn location(r: *Resolver, def: Def) Error!?struct { file: FileId, start: u32, end: u32 } {
        switch (def) {
            .file => |f| return .{ .file = f, .start = 0, .end = 0 },
            .item => |it| {
                const node = try r.itemNode(it.file, it.item) orelse return null;
                if (ast.memberName(node, try r.inEnum(it.file, it.item))) |t| return .{ .file = it.file, .start = t.offset, .end = t.offset + @as(u32, @intCast(t.text.len)) };
                return .{ .file = it.file, .start = node.offset, .end = node.offset };
            },
            .local => |l| {
                const node = try r.itemNode(l.file, l.item) orelse return null;
                const range = (try r.body(l.file, l.item)).binding(l.binding).range;
                return .{ .file = l.file, .start = node.offset + range.start, .end = node.offset + range.end };
            },
        }
    }
};

/// 字符串字面量的值；不是合法的单行字符串时返回 null
fn stringValue(arena: Allocator, raw: []const u8) ?[]const u8 {
    if (raw.len < 2 or raw[0] != '"') return null;
    return std.zig.string_literal.parseAlloc(arena, raw) catch null;
}

test {
    _ = @import("resolve_test.zig");
}
