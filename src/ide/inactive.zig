//! 非活动代码：comptime 已知不会执行的 `if` / `switch` 分支（如其他目标、其他构建配置的代码）。
//! 编译器不分析这些分支，编辑器以淡色显示（LSP 诊断的 `Unnecessary` 标记），类似 rust-analyzer 对
//! 不满足 `#[cfg]` 的代码的处理。

const std = @import("std");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const database = @import("../database.zig");
const hir = database.hir;
const queries = @import("../sema/queries.zig");
const FileId = @import("../base/Vfs.zig").FileId;

pub const Range = struct { start: u32, end: u32 };

/// 文件中的非活动代码（字节区间，按位置排序）
pub fn ranges(r: *Resolver, file: FileId) resolve.Error![]const Range {
    var out: std.ArrayList(Range) = .empty;
    const tree = try r.itemTree(file);
    for (0..tree.items.len) |i| {
        const node = try r.itemNode(file, @intCast(i)) orelse continue;
        const owner = try r.ownerKey(file, @intCast(i));
        const res = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full });
        if (res.inactive.len == 0) continue;
        const body = try r.ctx.get(hir.ItemBody, owner);
        for (res.inactive) |e| {
            const rg = body.range(e);
            if (rg.end > rg.start) try out.append(r.arena, .{ .start = node.offset + rg.start, .end = node.offset + rg.end });
        }
    }
    std.mem.sort(Range, out.items, {}, struct {
        fn lt(_: void, a: Range, b: Range) bool {
            return a.start < b.start;
        }
    }.lt);
    return out.items;
}
