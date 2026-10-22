//! 改名的安全检查（引用的查找见 `search.findReferences`）：新名字与已有的名字冲突，以及以字符串引用名字的反射用法。
//!
//! Zig 不允许局部名字遮蔽外层的局部名字与声明，同一容器的成员（声明与字段）也不能重名：这些改名后 AstGen 会报错，
//! `declarationConflict` 预先查出，`verifyAstGen` 以改名后的文本确认。容器中的声明却可以与外层容器的声明同名
//! （内层的优先），改名后不报错，名字悄悄指向了另一个声明，由 `resolutionConflict` 检查。

const std = @import("std");
const Allocator = std.mem.Allocator;
const database = @import("../database.zig");
const live = @import("../diagnostics/live.zig");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Def = resolve.Def;
const ItemTree = @import("../syntax/ItemTree.zig");
const Body = @import("../hir/Body.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const deepEql = @import("../util/deep_eql.zig").deepEql;

/// 不能改名的原因
pub const Problem = struct {
    file: FileId,
    /// 问题所在的位置（字节偏移）
    offset: u32,
    message: []const u8,
};

/// 替换 `[start, end)` 的文本
pub const Edit = struct { start: u32, end: u32, text: []const u8 };

/// 声明处的冲突（改名为 `new` 后 AstGen 会报错）：同一容器中已有名为 `new` 的成员；局部名字与它处可见的名字
/// 同名（遮蔽外层），或与它作用域内更深处的局部名字同名（被遮蔽）；函数体内的容器的声明与函数中可见的局部名字同名
pub fn declarationConflict(r: *Resolver, def: Def, new: []const u8) resolve.Error!?Problem {
    switch (def) {
        .file => return null,
        .item => |it| {
            const tree = try r.itemTree(it.file);
            for (tree.containerMembers(tree.items[it.item].container)) |m| {
                if (m == it.item) continue;
                switch (tree.items[m].kind) {
                    .@"test", .@"comptime" => continue,
                    else => {},
                }
                const name = tree.items[m].name orelse continue;
                if (std.mem.eql(u8, name, new)) return try problemAt(r, .{ .item = .{ .file = it.file, .item = m } }, "`{s}` is already declared in the same container", new);
            }
            // 字段不是作用域中的名字
            if (tree.items[it.item].kind == .field) return null;
            if (try r.resolveContainerName(it.file, it.item, new)) |d| if (d == .local) {
                return try problemAt(r, d, "the new name `{s}` would shadow this local", new);
            };
            return null;
        },
        .local => |l| {
            const b = try r.body(l.file, l.item);
            const scope = scopeOf(b, l.binding) orelse return null;
            if (b.lookup(scope, new)) |other| if (other != l.binding) {
                return try problemAt(r, .{ .local = .{ .file = l.file, .item = l.item, .binding = other } }, "`{s}` is already declared in this scope", new);
            };
            if (try r.resolveContainerName(l.file, l.item, new)) |d| return try problemAt(r, d, "the new name `{s}` would shadow this declaration", new);
            for (b.bindings, 0..) |other, i| {
                const id: Body.BindingId = @fromBackingInt(@as(u32, @intCast(i)));
                if (id == l.binding or !std.mem.eql(u8, other.name, new)) continue;
                if (within(b, scopeOf(b, id) orelse continue, scope)) {
                    return try problemAt(r, .{ .local = .{ .file = l.file, .item = l.item, .binding = id } }, "this `{s}` would shadow the renamed name", new);
                }
            }
            return null;
        },
    }
}

/// 容器中的声明改名为 `new` 后，容器以内的名字引用改变了指向（AstGen 不报错）：
/// - 对它的引用处已经能看到更近的 `new`（容器以内的声明或局部名字）：改名后引用被那个名字截获
/// - 容器以内原本指向容器以外的 `new`：改名后指向它
pub fn resolutionConflict(r: *Resolver, def: Def, new: []const u8) resolve.Error!?Problem {
    const it = switch (def) {
        .item => |it| it,
        else => return null,
    };
    const tree = try r.itemTree(it.file);
    switch (tree.items[it.item].kind) {
        .@"fn", .@"const", .@"var" => {},
        else => return null,
    }
    const old = tree.items[it.item].name orelse return null;
    const container = tree.items[it.item].container;
    for (0..tree.items.len) |i| {
        const index: u32 = @intCast(i);
        if (!inside(tree, index, container)) continue;
        if (!try r.mayMention(it.file, index, old) and !try r.mayMention(it.file, index, new)) continue;
        const body = try r.body(it.file, index);
        const base = try r.itemOffset(it.file, index) orelse continue;
        for (body.exprs, body.expr_scopes, body.expr_ranges, 0..) |e, scope, range, k| {
            const name = switch (e) {
                .name_ref => |n| n,
                else => continue,
            };
            if (body.nameRefIsBuiltin(@fromBackingInt(@as(u32, @intCast(k))))) continue;
            if (std.mem.eql(u8, name, old)) {
                const d = try r.resolveName(it.file, index, body, scope, old) orelse continue;
                if (!deepEql(d, def)) continue;
                const other = try r.resolveName(it.file, index, body, scope, new) orelse continue;
                if (try definedInside(r, other, it.file, container)) return .{
                    .file = it.file,
                    .offset = base + range.start,
                    .message = try std.fmt.allocPrint(r.arena, "this reference would refer to another `{s}` declared closer to it", .{new}),
                };
            } else if (std.mem.eql(u8, name, new)) {
                const d = try r.resolveName(it.file, index, body, scope, new) orelse continue;
                if (!try definedInside(r, d, it.file, container)) return .{
                    .file = it.file,
                    .offset = base + range.start,
                    .message = try std.fmt.allocPrint(r.arena, "this `{s}` refers to another declaration, which the renamed declaration would shadow", .{new}),
                };
            }
        }
    }
    return null;
}

/// 名字以字符串字面量出现的第一处：反射（`@field(x, "name")`、`@hasDecl(T, "name")`）与序列化以字符串引用名字，
/// 改名无法更新这些字符串
pub fn stringReference(r: *Resolver, files: []const FileId, name: []const u8) resolve.Error!?Problem {
    const quoted = try std.fmt.allocPrint(r.arena, "\"{s}\"", .{name});
    for (files) |f| {
        const text = (try r.ctx.get(database.syntax.SourceText, f)).text;
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, quoted)) |pos| : (from = pos + 1) {
            // 跳过注释中的与 `@"name"` 形式的标识符
            const root = (try r.ctx.get(database.syntax.ParseFile, f)).rootNode();
            const tok = root.tokenAtOffset(@intCast(pos)) orelse continue;
            if (tok.kind != .string_literal or tok.offset != pos or tok.text.len != quoted.len) continue;
            return .{
                .file = f,
                .offset = @intCast(pos),
                .message = try std.fmt.allocPrint(r.arena, "`{s}` appears in a string literal, which may refer to it by name (as `@field` and serialization do) and would not be updated", .{name}),
            };
        }
    }
    return null;
}

/// 文件应用 `edits`（按位置排列、互不重叠）之后，比之前多出的第一个 AstGen 错误：重名、遮蔽，以及文件中漏改的
/// 引用（引用不到声明）都会报出。位置换算回改名之前的文本
pub fn verifyAstGen(r: *Resolver, file: FileId, edits: []const Edit) resolve.Error!?Problem {
    const ctx = r.ctx;
    const gpa = ctx.db.gpa;
    const text = (try ctx.get(database.syntax.SourceText, file)).text;
    var renamed: std.ArrayList(u8) = .empty;
    var pos: u32 = 0;
    for (edits) |e| {
        try renamed.appendSlice(r.arena, text[pos..e.start]);
        try renamed.appendSlice(r.arena, e.text);
        pos = e.end;
    }
    try renamed.appendSlice(r.arena, text[pos..]);
    const backend = try ctx.get(live.LiveBackend, {});
    const mode = live.modeOf(ctx.db.env.vfs.path(file));
    // 当前文本的结果：打开的文件已由诊断发布算出（`AstCheck` 读取的是 `FileText`）
    var own_before: ?*live.Result = null;
    defer if (own_before) |b| b.destroy(gpa);
    const before = if (try ctx.get(database.inputs.FileText, file) != null) try ctx.get(live.AstCheck, file) else blk: {
        own_before = try live.checkWith(gpa, ctx.db.io, backend, text, mode);
        break :blk own_before.?;
    };
    const after = try live.checkWith(gpa, ctx.db.io, backend, renamed.items, mode);
    defer after.destroy(gpa);
    // 按文案对应，改名前已有的错误不算。不比较个数：新的错误可能使 AstGen 不再报出原有的错误
    var known: std.StringHashMapUnmanaged(u32) = .empty;
    for (before.items) |d| {
        const gop = try known.getOrPut(r.arena, d.message);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    }
    for (after.items) |d| {
        if (known.getPtr(d.message)) |n| if (n.* > 0) {
            n.* -= 1;
            continue;
        };
        return .{ .file = file, .offset = mapBack(edits, d.start), .message = try r.arena.dupe(u8, d.message) };
    }
    return null;
}

/// 应用 `edits` 之后的位置换算回之前的文本；位于替换的文本中时取被替换区间的起点
fn mapBack(edits: []const Edit, offset: u32) u32 {
    var delta: i64 = 0;
    for (edits) |e| {
        const start: i64 = @as(i64, e.start) + delta;
        if (offset < start) break;
        if (offset < start + @as(i64, @intCast(e.text.len))) return e.start;
        delta += @as(i64, @intCast(e.text.len)) - @as(i64, e.end - e.start);
    }
    return @intCast(@as(i64, offset) - delta);
}

fn problemAt(r: *Resolver, def: Def, comptime fmt: []const u8, new: []const u8) resolve.Error!?Problem {
    const loc = try r.location(def) orelse return null;
    return .{ .file = loc.file, .offset = loc.start, .message = try std.fmt.allocPrint(r.arena, fmt, .{new}) };
}

/// 绑定所在的作用域
fn scopeOf(b: *const Body, id: Body.BindingId) ?Body.ScopeId {
    for (b.scopes, 0..) |s, i| {
        if (std.mem.indexOfScalar(Body.BindingId, s.bindings, id) != null) return @fromBackingInt(@as(u32, @intCast(i)));
    }
    return null;
}

/// 作用域 `s` 是 `ancestor` 或在它之内
fn within(b: *const Body, s: Body.ScopeId, ancestor: Body.ScopeId) bool {
    var cur: ?Body.ScopeId = s;
    while (cur) |c| : (cur = b.scope(c).parent) {
        if (c == ancestor) return true;
    }
    return false;
}

/// 成员 `item` 在容器 `container` 之内（直接的成员，或体内定义的容器的成员）
fn inside(tree: *const ItemTree, item: u32, container: u32) bool {
    var c = tree.items[item].container;
    while (true) {
        if (c == container) return true;
        const parent = tree.containers[c].parent_item orelse return false;
        c = tree.items[parent].container;
    }
}

/// 定义在文件 `file` 的容器 `container` 之内：容器（及其体内容器）的成员，或其中成员的局部名字
fn definedInside(r: *Resolver, d: Def, file: FileId, container: u32) resolve.Error!bool {
    const tree = try r.itemTree(file);
    return switch (d) {
        .item => |x| x.file == file and inside(tree, x.item, container),
        .local => |x| x.file == file and inside(tree, x.item, container),
        .file => false,
    };
}

test {
    _ = @import("rename_test.zig");
}
