//! workspace/symbol：在项目文件的 ItemTree 中按名字模糊匹配声明。
//!
//! 匹配规则：查询串（忽略大小写）是名字的子序列。完全相同优先，其次前缀，再次子序列；同级按名字长度。

const std = @import("std");
const types = @import("../lsp/types.zig");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const ast = @import("../syntax/ast.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const document_symbol = @import("document_symbol.zig");
const ItemTree = @import("../syntax/ItemTree.zig");

pub const Symbol = struct {
    name: []const u8,
    kind: types.SymbolKind,
    /// 所在容器的名字（文件顶层为 null）
    container: ?[]const u8,
    file: FileId,
    start: u32,
    end: u32,
    rank: u8,
};

/// 最多返回的符号数
pub const limit = 256;

pub fn search(r: *Resolver, files: []const FileId, query: []const u8) resolve.Error![]const Symbol {
    var out: std.ArrayList(Symbol) = .empty;
    for (files) |file| {
        const tree = try r.itemTree(file);
        for (tree.items, 0..) |item, i| {
            switch (item.kind) {
                .@"test", .@"comptime" => continue,
                else => {},
            }
            const name = item.name orelse continue;
            const rank = match(name, query) orelse continue;
            const container = tree.containers[item.container];
            const node = try r.itemNode(file, @intCast(i)) orelse continue;
            const tok = ast.memberName(node, ItemTree.bareFieldNames(container.kind)) orelse continue;
            try out.append(r.arena, .{
                .name = ast.identName(name),
                .kind = document_symbol.symbolKind(tree, @intCast(i), container.kind),
                .container = if (container.parent_item) |p| tree.items[p].name else null,
                .file = file,
                .start = tok.offset,
                .end = tok.offset + @as(u32, @intCast(tok.text.len)),
                .rank = rank,
            });
        }
    }
    std.mem.sort(Symbol, out.items, {}, struct {
        fn lt(_: void, a: Symbol, b: Symbol) bool {
            if (a.rank != b.rank) return a.rank < b.rank;
            if (a.name.len != b.name.len) return a.name.len < b.name.len;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return out.items[0..@min(out.items.len, limit)];
}

/// 匹配等级：0 完全相同，1 前缀，2 子序列；不匹配为 null（均忽略大小写）
fn match(raw_name: []const u8, query: []const u8) ?u8 {
    const name = ast.identName(raw_name);
    if (std.ascii.eqlIgnoreCase(name, query)) return 0;
    if (std.ascii.startsWithIgnoreCase(name, query)) return 1;
    var i: usize = 0;
    for (name) |c| {
        if (i == query.len) break;
        if (std.ascii.toLower(c) == std.ascii.toLower(query[i])) i += 1;
    }
    return if (i == query.len) 2 else null;
}

test match {
    try std.testing.expectEqual(0, match("Foo", "foo"));
    try std.testing.expectEqual(1, match("ArrayList", "arr"));
    try std.testing.expectEqual(2, match("ArrayList", "al"));
    try std.testing.expectEqual(null, match("ArrayList", "la"));
    try std.testing.expectEqual(2, match("@\"a b\"", "ab"));
}
