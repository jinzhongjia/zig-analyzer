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
        try n.writeArgs(n.shownInst(c.inst) orelse return, w);
    }

    /// 显示实参的实例：没有实例的成员按迭代推导时的实例（见 `InternPool.Instance.iteration`）显示外层实例
    fn shownInst(n: ContainerNames, inst: ?Index) ?Index {
        const i = inst orelse return null;
        const key = n.r.ctx.db.env.ip.key(i).instance;
        if (key.iteration) |it| if (it.abstract) return n.shownInst(key.parent);
        return i;
    }

    /// 内置函数构造的类型：以构造它的函数实例命名（`FieldEnum(S)`）；不在函数中构造、正是某个常量的值时以常量命名
    /// （`const Kind = blk: { ... break :blk @Enum(...); }` → `Kind`）；否则按内容显示
    pub fn writeReified(n: ContainerNames, t: InternPool.Reified, w: *Io.Writer) Io.Writer.Error!void {
        const ip = n.r.ctx.db.env.ip;
        const inst = t.inst orelse {
            const decl_name = n.constNaming(t) catch null orelse return ip.printReified(t, w, n);
            return w.writeAll(decl_name);
        };
        const i = ip.key(inst).instance;
        const tree = n.r.itemTree(i.file) catch return ip.printReified(t, w, n);
        for (tree.items) |it| if (it.ast_id == i.decl) {
            try w.writeAll(it.name orelse return ip.printReified(t, w, n));
            return n.writeArgs(inst, w);
        };
        return ip.printReified(t, w, n);
    }

    /// 构造所在的常量，其值就是这个类型（同一处构造）时的名字
    fn constNaming(n: ContainerNames, t: InternPool.Reified) resolve.Error!?[]const u8 {
        const ip = n.r.ctx.db.env.ip;
        const tree = try n.r.itemTree(t.file);
        for (tree.items) |it| {
            if (it.ast_id != t.owner) continue;
            if (it.kind != .@"const") return null;
            const decl = try n.r.ctx.get(queries.DeclType, .{ .owner = .{ .file = t.file, .item = it.ast_id } });
            const v = decl.val orelse return null;
            const same = switch (ip.key(v)) {
                .reified_type => |x| x.file == t.file and x.owner == t.owner and x.expr == t.expr and x.inst == null,
                else => false,
            };
            return if (same) it.name else null;
        }
        return null;
    }

    /// 推导的错误集：显示由函数体求出的成员
    pub fn writeInferredErrorSet(n: ContainerNames, t: Index, w: *Io.Writer) Io.Writer.Error!void {
        const ip = n.r.ctx.db.env.ip;
        const names = queries.errorSetMembers(n.r, t) catch null orelse return w.writeAll("anyerror");
        const set = ip.errorSet(n.r.arena, names) catch return w.writeAll("anyerror");
        return ip.print(set, w, n);
    }

    /// 结构体值显示时的字段名；不是结构体（数组、元组等）时为 null
    pub fn fieldNames(n: ContainerNames, t: Index) ?[]const []const u8 {
        const ip = n.r.ctx.db.env.ip;
        switch (ip.key(t)) {
            .container_type => |c| if (c.kind != .@"struct" and c.kind != .file) return null,
            .anon_struct_type => |s| return s.names,
            .reified_type => |rt| if (rt.kind != .@"struct") return null,
            else => return null,
        }
        const fields = @import("eval.zig").fieldNames(n.r, t) catch return null;
        const out = n.r.arena.alloc([]const u8, fields.len) catch return null;
        for (fields, out) |f, *o| o.* = f.name;
        return out;
    }

    fn writeArgs(n: ContainerNames, inst: Index, w: *Io.Writer) Io.Writer.Error!void {
        const ip = n.r.ctx.db.env.ip;
        try w.writeAll("(");
        var first = true;
        // 非 comptime 参数不属于实例的身份，不显示；未知的 comptime 实参显示为 `_`
        for (ip.key(inst).instance.args) |arg| {
            if (arg == .runtime) continue;
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
        const rel = try n.r.containerRel(.{ .file = file, .container = container }) orelse return null;
        const b = try n.r.body(file, item);
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
                const start = out.written().len;
                writeType(r, v, w) catch |e| break :blk e;
                // 很长的值（如 `@typeInfo` 的结果）截断显示
                if (out.written().len - start > max_value_len) {
                    out.shrinkRetainingCapacity(start + max_value_len);
                    w.writeAll("...") catch |e| break :blk e;
                }
            },
        };
    }) catch return error.OutOfMemory;
    return out.written();
}

/// 值显示的最大长度（字节）
const max_value_len = 120;
