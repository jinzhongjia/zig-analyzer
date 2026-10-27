//! Inactive code: `if` / `switch` branches known at comptime never to execute (such as code for
//! other targets or other build configurations), code after a noreturn statement selected at
//! comptime, such as `@compileError` / `return`, and the right-hand side of an `and` / `or` whose
//! left-hand side is known at comptime and decides the result.
//! The compiler does not analyze these branches; editors show them dimmed (the `Unnecessary`
//! tag of LSP diagnostics), like rust-analyzer does for code that does not satisfy `#[cfg]`.

const std = @import("std");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const queries = @import("../sema/queries.zig");
const database = @import("../database.zig");
const FileId = @import("../base/Vfs.zig").FileId;

pub const Range = struct { start: u32, end: u32 };

/// Inactive code in the file (byte ranges, sorted by position)
pub fn ranges(r: *Resolver, file: FileId) resolve.Error![]const Range {
    var out: std.ArrayList(Range) = .empty;
    const tree = try r.itemTree(file);
    const source = (try r.ctx.get(database.syntax.ParseFile, file)).source;
    for (0..tree.items.len) |i| {
        const node = try r.itemNode(file, @intCast(i)) orelse continue;
        const owner = try r.ownerKey(file, @intCast(i));
        for (try r.ctx.get(queries.InactiveRanges, owner)) |rg| {
            // Code after a noreturn statement is counted from the end of that statement;
            // display starts at the next statement
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
