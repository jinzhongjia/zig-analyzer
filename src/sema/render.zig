//! 类型与值的显示（hover、inlay hint、补全详情共用）。

const std = @import("std");
const Io = std.Io;
const InternPool = @import("InternPool.zig");
const Index = InternPool.Index;
const TypedValue = InternPool.TypedValue;
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const queries = @import("queries.zig");
const Body = @import("../hir/Body.zig");

/// 容器类型的名字：声明它的成员名（`const Point = struct {...}` → `Point`），文件为文件名。没有名字的容器（字段类型、
/// 变量的类型标注、实参中的容器）按内容显示：`struct { x: u8 }`，其中再有没有名字的容器显示为 `struct {...}`
const ContainerNames = struct {
    r: *Resolver,
    /// 正在按内容显示外层的匿名容器
    nested: bool = false,
    /// 显示过按内容显示的匿名容器时置为 true
    anonymous: ?*bool = null,

    pub fn write(n: ContainerNames, c: InternPool.Container, w: *Io.Writer) Io.Writer.Error!void {
        const found = n.name(c) catch null;
        try w.writeAll(found orelse return n.writeContent(c, w));
        // 泛型实例：`List(u8)`，只列出 comptime 已知的实参
        try n.writeArgs(n.shownInst(c.inst) orelse return, w);
    }

    /// 匿名容器的内容：布局、种类与字段（枚举只有名字），至多列出 `InternPool.max_printed_elems` 个字段
    fn writeContent(n: ContainerNames, c: InternPool.Container, w: *Io.Writer) Io.Writer.Error!void {
        if (n.anonymous) |seen| seen.* = true;
        const tree = n.r.itemTree(c.file) catch return w.writeAll(@tagName(c.kind));
        const ci = for (tree.containers, 0..) |x, i| {
            if (x.ast_id == c.ast_id) break i;
        } else return w.writeAll(@tagName(c.kind));
        const x = tree.containers[ci];
        if (x.layout != .auto) try w.print("{t} ", .{x.layout});
        try w.writeAll(@tagName(c.kind));
        if (x.auto_enum) try w.writeAll("(enum)");
        if (n.nested) return w.writeAll(" {...}");
        const inner: ContainerNames = .{ .r = n.r, .nested = true, .anonymous = n.anonymous };
        const ip = n.r.ctx.db.env.ip;
        try w.writeAll(" {");
        var count: usize = 0;
        for (tree.containerMembers(@intCast(ci))) |m| {
            const it = tree.items[m];
            if (it.kind != .field) continue;
            if (count == InternPool.max_printed_elems) {
                try w.writeAll(", ...");
                break;
            }
            try w.writeAll(if (count == 0) " " else ", ");
            count += 1;
            // 元组字段没有名字
            if (it.name) |field| try w.print("{f}", .{std.zig.fmtId(field)});
            if (c.kind == .@"enum") continue;
            if (it.name != null) try w.writeAll(": ");
            const tv = queries.defType(n.r, .{ .item = .{ .file = c.file, .item = m } }, null, c.inst) catch TypedValue.unknown;
            try ip.print(tv.ty, w, inner);
        }
        try w.writeAll(if (count == 0) "}" else " }");
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

    /// 容器是成员的值时以成员命名：`const S = struct {...}` 为 `S`，函数体中按局部常量命名，`return` 的容器以函数命名
    /// （`List(u8)`）；值是在几个容器中选一个的 `if` / `switch` 时同样命名（编译器在这里命名为 `S__struct_1`，以成员
    /// 命名更易读）。字段与变量的类型标注、实参、`?struct {...}` 中的容器没有名字，返回 null
    fn name(n: ContainerNames, c: InternPool.Container) resolve.Error!?[]const u8 {
        if (c.kind == .file) {
            const base = std.fs.path.basename(n.r.ctx.db.env.vfs.path(c.file));
            return if (std.mem.endsWith(u8, base, ".zig")) base[0 .. base.len - 4] else base;
        }
        const tree = try n.r.itemTree(c.file);
        for (tree.containers, 0..) |x, ci| if (x.ast_id == c.ast_id) {
            const parent = x.parent_item orelse return null;
            const item = tree.items[parent];
            if (item.kind == .field) return null;
            const rel = try n.r.containerRel(.{ .file = c.file, .container = @intCast(ci) }) orelse return null;
            const b = try n.r.body(c.file, parent);
            if (item.kind == .@"const" or item.kind == .@"var") {
                const value = b.value orelse return null;
                return if (yields(b, value, rel)) item.name else null;
            }
            for (b.bindings) |binding| {
                const init = binding.init orelse continue;
                if (yields(b, init, rel)) return binding.name;
            }
            if (item.kind != .@"fn") return null;
            for (b.exprs) |e| switch (e) {
                .@"return" => |v| if (v) |operand| if (yields(b, operand, rel)) return item.name,
                else => {},
            };
            return null;
        };
        return null;
    }

    /// 表达式的结果是否就是位于 `rel` 的容器：容器本身，或 `if` / `switch` 某个分支的结果
    fn yields(b: *const Body, e: Body.ExprId, rel: u32) bool {
        return switch (b.expr(e)) {
            .container => b.range(e).start == rel,
            .@"if" => |x| yields(b, x.then, rel) or (if (x.@"else") |other| yields(b, other, rel) else false),
            .@"switch" => |s| for (s.prongs) |p| {
                if (yields(b, p.body, rel)) break true;
            } else false,
            .@"comptime" => |x| yields(b, x, rel),
            else => false,
        };
    }
};

pub fn writeType(r: *Resolver, t: Index, w: *Io.Writer) Io.Writer.Error!void {
    try r.ctx.db.env.ip.print(t, w, ContainerNames{ .r = r });
}

pub fn typeAlloc(r: *Resolver, t: Index) error{OutOfMemory}![]const u8 {
    return (try typeAllocNoting(r, t)).text;
}

/// 同 `typeAlloc`，并说明其中是否有按内容显示的匿名容器
pub fn typeAllocNoting(r: *Resolver, t: Index) error{OutOfMemory}!struct { text: []const u8, anonymous: bool } {
    var out: Io.Writer.Allocating = .init(r.arena);
    var anonymous = false;
    r.ctx.db.env.ip.print(t, &out.writer, ContainerNames{ .r = r, .anonymous = &anonymous }) catch return error.OutOfMemory;
    return .{ .text = out.written(), .anonymous = anonymous };
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
