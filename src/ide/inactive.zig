//! 非活动代码：comptime 已知不会执行的 `if` / `switch` 分支（如其他目标、其他构建配置的代码）、被选中的
//! `@compileError` / `return` 等 noreturn 语句之后的代码，以及左侧 comptime 已知并决定了结果的 `and` / `or`
//! 的右侧。
//! 编译器不分析这些分支，编辑器以淡色显示（LSP 诊断的 `Unnecessary` 标记），类似 rust-analyzer 对
//! 不满足 `#[cfg]` 的代码的处理。

const std = @import("std");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const queries = @import("../sema/queries.zig");
const database = @import("../database.zig");
const FileId = @import("../base/Vfs.zig").FileId;

pub const Range = struct { start: u32, end: u32 };

/// 文件中的非活动代码（字节区间，按位置排序）
pub fn ranges(r: *Resolver, file: FileId) resolve.Error![]const Range {
    var out: std.ArrayList(Range) = .empty;
    const tree = try r.itemTree(file);
    const source = (try r.ctx.get(database.syntax.ParseFile, file)).source;
    for (0..tree.items.len) |i| {
        const node = try r.itemNode(file, @intCast(i)) orelse continue;
        const owner = try r.ownerKey(file, @intCast(i));
        for (try r.ctx.get(queries.InactiveRanges, owner)) |rg| {
            // noreturn 语句之后的代码从该语句的末尾算起：从下一条语句开始显示
            var start = node.offset + rg.start;
            const end = node.offset + rg.end;
            while (start < end and std.ascii.isWhitespace(source[start])) start += 1;
            if (start < end) try out.append(r.arena, .{ .start = start, .end = end });
        }
    }
    std.mem.sort(Range, out.items, {}, struct {
        fn lt(_: void, a: Range, b: Range) bool {
            return a.start < b.start;
        }
    }.lt);
    return out.items;
}
