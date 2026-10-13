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
        // 泛型实例：`List(u8)`，只列出 comptime 已知的实参
        const inst = c.inst orelse return;
        const ip = n.r.ctx.db.env.ip;
        try w.writeAll("(");
        var first = true;
        // 非 comptime 参数（实参为 unknown）不属于实例的身份，不显示；未知的 comptime 实参显示为 `_`
        const inst_key = ip.key(inst).instance;
        const body = n.r.ctx.get(@import("../database.zig").hir.ItemBody, .{ .file = inst_key.file, .item = inst_key.decl }) catch null;
        for (inst_key.args, 0..) |arg, i| {
            const comptime_param = if (body) |b| (i < b.params.len and (b.binding(b.params[i]).is_comptime or b.binding(b.params[i]).ty == null)) else arg != .unknown;
            if (!comptime_param) continue;
            if (!first) try w.writeAll(", ");
            first = false;
            if (arg == .unknown) try w.writeAll("_") else try ip.print(arg, w, n);
        }
        try w.writeAll(")");
    }

    fn name(n: ContainerNames, c: InternPool.Container) resolve.Error!?[]const u8 {
        if (c.kind == .file) {
            const base = std.fs.path.basename(n.r.ctx.db.env.vfs.path(c.file));
            return if (std.mem.endsWith(u8, base, ".zig")) base[0 .. base.len - 4] else base;
        }
        const tree = try n.r.itemTree(c.file);
        for (tree.containers, 0..) |x, ci| if (x.ast_id == c.ast_id) {
            const parent = x.parent_item orelse return null;
            const item = tree.items[parent];
            switch (item.kind) {
                // `const S = struct {...}`、字段类型中的容器
                .@"const", .@"var", .field => return item.name,
                else => {},
            }
            // 函数 / test 体内：绑定它的局部变量名；否则为类型构造函数返回的容器，取函数名
            if (try n.localName(c.file, parent, @intCast(ci))) |local| return local;
            return if (item.kind == .@"fn") item.name else null;
        };
        return null;
    }

    /// 体内 `const E = enum {...}` 的局部变量名
    fn localName(n: ContainerNames, file: @import("../base/Vfs.zig").FileId, item: u32, container: u32) resolve.Error!?[]const u8 {
        const owner = try n.r.itemNode(file, item) orelse return null;
        const node = try n.r.containerNode(.{ .file = file, .container = container }) orelse return null;
        const b = try n.r.body(file, item);
        const rel = node.offset - owner.offset;
        for (b.bindings) |binding| {
            const init = binding.init orelse continue;
            if (b.expr(init) == .container and b.range(init).start == rel) return binding.name;
        }
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
