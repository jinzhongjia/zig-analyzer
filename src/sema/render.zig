//! 类型与值的显示（hover、inlay hint、补全详情共用）。

const std = @import("std");
const Io = std.Io;
const InternPool = @import("InternPool.zig");
const Index = InternPool.Index;
const TypedValue = InternPool.TypedValue;
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const queries = @import("queries.zig");

/// 容器类型的名字：声明它的成员名（`const Point = struct {...}` → `Point`），文件为文件名
const ContainerNames = struct {
    r: *Resolver,

    pub fn write(n: ContainerNames, c: InternPool.Container, w: *Io.Writer) Io.Writer.Error!void {
        const found = n.name(c) catch null;
        try w.writeAll(found orelse @tagName(c.kind));
    }

    fn name(n: ContainerNames, c: InternPool.Container) resolve.Error!?[]const u8 {
        if (c.kind == .file) {
            const base = std.fs.path.basename(n.r.ctx.db.env.vfs.path(c.file));
            return if (std.mem.endsWith(u8, base, ".zig")) base[0 .. base.len - 4] else base;
        }
        const tree = try n.r.itemTree(c.file);
        for (tree.containers) |x| if (x.ast_id == c.ast_id) {
            const parent = x.parent_item orelse return null;
            return tree.items[parent].name;
        };
        return null;
    }
};

pub fn writeType(r: *Resolver, t: Index, w: *Io.Writer) Io.Writer.Error!void {
    try r.ctx.db.env.ip.print(t, w, ContainerNames{ .r = r });
}

pub fn typeAlloc(r: *Resolver, t: Index) error{OutOfMemory}![]const u8 {
    var out: Io.Writer.Allocating = .init(r.arena);
    writeType(r, t, &out.writer) catch return error.OutOfMemory;
    return out.written();
}

/// 值为类型时显示 `type = T`；comptime 已知的其他值显示 `T = v`
pub fn typedValueAlloc(r: *Resolver, tv: TypedValue) error{OutOfMemory}![]const u8 {
    var out: Io.Writer.Allocating = .init(r.arena);
    const w = &out.writer;
    (blk: {
        writeType(r, tv.ty, w) catch |e| break :blk e;
        if (tv.val) |v| switch (r.ctx.db.env.ip.key(v)) {
            .fn_value, .simple_value => {},
            else => {
                w.writeAll(" = ") catch |e| break :blk e;
                writeType(r, v, w) catch |e| break :blk e;
            },
        };
    }) catch return error.OutOfMemory;
    return out.written();
}
