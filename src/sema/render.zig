//! Display of types and values (shared by hover, inlay hints and completion details).

const std = @import("std");
const Io = std.Io;
const InternPool = @import("InternPool.zig");
const Index = InternPool.Index;
const TypedValue = InternPool.TypedValue;
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Namespace = resolve.Namespace;
const queries = @import("queries.zig");
const eval = @import("eval.zig");
const database = @import("../database.zig");
const Body = @import("../hir/Body.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const AstId = @import("../syntax/ItemTree.zig").AstId;

/// Names of container types: the name of the member that declares the container
/// (`const Point = struct {...}` → `Point`), and the file name for a file. Containers without a
/// name (field types, type annotations of variables, containers in arguments) are displayed by
/// their contents: `struct { x: u8 }`. Unnamed containers nested further inside them are expanded
/// the same way when listing the full contents, and only self-references (`?*const @This()`) are
/// displayed as `struct {...}`; otherwise they are always displayed as `struct {...}`.
const ContainerNames = struct {
    r: *Resolver,
    /// The enclosing anonymous containers currently being displayed by their contents
    outer: ?*const Outer = null,
    /// Set to true once an anonymous container has been displayed by its contents
    anonymous: ?*bool = null,

    /// List the full contents: hover and the display of values. Otherwise (inlay
    /// hints, completion details, etc.) nested anonymous containers are displayed as
    /// `struct {...}`.
    full: bool = false,
    /// Maximum number of characters in the output (`max_length` of inlay hints, and
    /// `max_value_length` for values); null means unlimited. See `InternPool.truncateList`; the
    /// output must be written to an `Io.Writer.Allocating`, which keeps everything written so far
    /// in its buffer.
    max_length: ?usize = null,
    /// Write the full number of items after the `…` of a cut list or string (see
    /// `InternPool.truncateList`)
    show_total: bool = false,

    const Outer = struct { c: InternPool.Container, parent: ?*const Outer };

    /// Number of characters the output can still take (read by `InternPool.print`); null means
    /// unlimited
    pub fn remaining(n: ContainerNames, w: *Io.Writer) ?usize {
        const max = n.max_length orelse return null;
        const written = w.buffered();
        return max -| (std.unicode.utf8CountCodepoints(written) catch written.len);
    }

    pub fn write(n: ContainerNames, c: InternPool.Container, w: *Io.Writer) Io.Writer.Error!void {
        if (c.kind == .file) {
            const base = std.fs.path.basename(n.r.ctx.db.env.vfs.path(c.file));
            return w.writeAll(if (std.mem.endsWith(u8, base, ".zig")) base[0 .. base.len - 4] else base);
        }
        const found = n.name(c) catch null orelse return n.writeContent(c, w);
        // Only the type a generic function returns carries the arguments (`List(u8)`); a container
        // named inside a generic instance is qualified by the named container or function, as the
        // compiler names it: `Outer(u8).Inner`, `Outer(u8).Gen(u16)`, and `Local.S` for a local
        // constant (the function without arguments)
        const inst = n.shownInst(c.inst) orelse return w.writeAll(found.name);
        switch (found.by) {
            .member => {
                try n.writeQualifier(c, found.item, w);
                try w.writeAll(found.name);
            },
            .local => {
                try n.writeOwner(c, found.item, null, w);
                try w.print(".{s}", .{found.name});
            },
            .returned => try n.writeOwner(c, found.item, inst, w),
        }
    }

    /// The member `item` whose body names the container: qualified as in `writeQualifier`, with
    /// the arguments when `inst` is the instance of `item` itself (a generic function)
    fn writeOwner(n: ContainerNames, c: InternPool.Container, item: u32, inst: ?Index, w: *Io.Writer) Io.Writer.Error!void {
        const tree = n.r.itemTree(c.file) catch return;
        const it = tree.items[item];
        try n.writeQualifier(c, item, w);
        try w.writeAll(it.name orelse "_");
        const i = inst orelse return;
        const key = n.r.ctx.db.env.ip.key(i).instance;
        if (key.file == c.file and key.decl == it.ast_id) try n.writeArgs(i, w);
    }

    /// `Q.` when the container `Q` that declares `item` is named and lies in a generic function
    /// body (its name carries the instance arguments); nothing otherwise
    fn writeQualifier(n: ContainerNames, c: InternPool.Container, item: u32, w: *Io.Writer) Io.Writer.Error!void {
        const ip = n.r.ctx.db.env.ip;
        const tree = n.r.itemTree(c.file) catch return;
        const parent = queries.containerType(n.r, .{ .file = c.file, .container = tree.items[item].container }, c.inst) catch return;
        const p = switch (ip.key(parent)) {
            .container_type => |p| p,
            else => return,
        };
        const generic = if (p.inst) |i| ip.key(i) != .context else false;
        if (!generic or p.kind == .file or (n.name(p) catch null) == null) return;
        try n.write(p, w);
        try w.writeAll(".");
    }

    /// Contents of an anonymous container: layout, kind and fields (only names for enums)
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
        if (n.full) {
            var o = n.outer;
            while (o) |up| : (o = up.parent) if (up.c.file == c.file and up.c.ast_id == c.ast_id) return w.writeAll(" {...}");
        } else if (n.outer != null) return w.writeAll(" {...}");
        const here: Outer = .{ .c = c, .parent = n.outer };
        const inner: ContainerNames = .{ .r = n.r, .outer = &here, .anonymous = n.anonymous, .full = n.full, .max_length = n.max_length, .show_total = n.show_total };
        const ip = n.r.ctx.db.env.ip;
        try w.writeAll(" {");
        const members = tree.containerMembers(@intCast(ci));
        var total: usize = 0;
        for (members) |m| total += @intFromBool(tree.items[m].kind == .field);
        var count: usize = 0;
        for (members) |m| {
            const it = tree.items[m];
            if (it.kind != .field) continue;
            try w.writeAll(if (count == 0) " " else ", ");
            count += 1;
            if (try InternPool.truncateList(n, w, total)) break;
            // Tuple fields have no names
            if (it.name) |field| try w.print("{f}", .{std.zig.fmtId(field)});
            if (c.kind == .@"enum") continue;
            if (it.name != null) try w.writeAll(": ");
            const tv = queries.defType(n.r, .{ .item = .{ .file = c.file, .item = m } }, null, c.inst) catch TypedValue.unknown;
            try ip.print(tv.ty, w, inner);
        }
        try w.writeAll(if (count == 0) "}" else " }");
    }

    /// The instance whose arguments are displayed: for the per-iteration instance (see
    /// `InternPool.Instance.iteration`) of a member that has no instance, the enclosing instance
    /// is displayed; null outside generic functions (a compilation context is not displayed)
    fn shownInst(n: ContainerNames, inst: ?Index) ?Index {
        const i = inst orelse return null;
        const key = switch (n.r.ctx.db.env.ip.key(i)) {
            .instance => |key| key,
            else => return null,
        };
        if (key.iteration) |it| if (it.abstract) return n.shownInst(key.parent);
        return i;
    }

    /// Types constructed by builtins: named after the function instance that constructs them
    /// (`FieldEnum(S)`); when not constructed in a function and exactly the value of a constant,
    /// named after the constant (`const Kind = blk: { ... break :blk @Enum(...); }` → `Kind`);
    /// otherwise displayed by their contents
    pub fn writeReified(n: ContainerNames, t: InternPool.Reified, w: *Io.Writer) Io.Writer.Error!void {
        const ip = n.r.ctx.db.env.ip;
        const i = switch (ip.key(t.inst orelse .unknown)) {
            .instance => |i| i,
            else => {
                const decl_name = n.constNaming(t) catch null orelse return ip.printReified(t, w, n);
                return w.writeAll(decl_name);
            },
        };
        const inst = t.inst.?;
        const tree = n.r.itemTree(i.file) catch return ip.printReified(t, w, n);
        for (tree.items) |it| if (it.ast_id == i.decl) {
            try w.writeAll(it.name orelse return ip.printReified(t, w, n));
            return n.writeArgs(inst, w);
        };
        return ip.printReified(t, w, n);
    }

    /// Name of the constant where the type is constructed, when its value is exactly this type
    /// (constructed at the same place)
    fn constNaming(n: ContainerNames, t: InternPool.Reified) resolve.Error!?[]const u8 {
        const ip = n.r.ctx.db.env.ip;
        const tree = try n.r.itemTree(t.file);
        for (tree.items) |it| {
            if (it.ast_id != t.owner) continue;
            if (it.kind != .@"const") return null;
            const decl = try n.r.ctx.get(queries.DeclType, .{ .owner = .{ .file = t.file, .item = it.ast_id }, .inst = t.inst });
            const v = decl.val orelse return null;
            const same = switch (ip.key(v)) {
                .reified_type => |x| x.file == t.file and x.owner == t.owner and x.expr == t.expr and x.inst == t.inst,
                else => false,
            };
            return if (same) it.name else null;
        }
        return null;
    }

    /// Inferred error sets: displays the members computed from the function body
    pub fn writeInferredErrorSet(n: ContainerNames, t: Index, w: *Io.Writer) Io.Writer.Error!void {
        const ip = n.r.ctx.db.env.ip;
        const names = queries.errorSetMembers(n.r, t) catch null orelse return w.writeAll("anyerror");
        const set = ip.errorSet(n.r.arena, names) catch return w.writeAll("anyerror");
        return ip.print(set, w, n);
    }

    /// Field names used when displaying a struct value; null when it is not a struct (arrays,
    /// tuples, etc.)
    pub fn fieldNames(n: ContainerNames, t: Index) ?[]const []const u8 {
        const ip = n.r.ctx.db.env.ip;
        switch (ip.key(t)) {
            .container_type => |c| if (!c.kind.isStruct()) return null,
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
        // Non-comptime parameters are not part of the instance's identity and are not shown;
        // unknown comptime arguments are shown as `_`
        const args = ip.key(inst).instance.args;
        var total: usize = 0;
        for (args) |arg| total += @intFromBool(arg != .runtime);
        for (args) |arg| {
            if (arg == .runtime) continue;
            if (!first) try w.writeAll(", ");
            first = false;
            if (try InternPool.truncateList(n, w, total)) break;
            if (arg == .unknown) try w.writeAll("_") else try ip.print(arg, w, n);
        }
        try w.writeAll(")");
    }

    /// How a container is named: after the member whose value it is (`const S = struct {...}` is
    /// `S`), after the local constant of a function body, or after the function that `return`s it
    /// (`List(u8)`); the same naming applies when the value is an `if` / `switch` choosing among
    /// several containers (the compiler names it `S__struct_1` here; naming after the member is
    /// more readable). `item` is the member whose name or body names it.
    const Naming = struct { name: []const u8, item: u32, by: enum { member, local, returned } };

    /// Containers in type annotations of fields and variables, in arguments, and in
    /// `?struct {...}` have no name; returns null. Files are not handled here (see `write`).
    fn name(n: ContainerNames, c: InternPool.Container) resolve.Error!?Naming {
        const tree = try n.r.itemTree(c.file);
        for (tree.containers, 0..) |x, ci| if (x.ast_id == c.ast_id) {
            const parent = x.parent_item orelse return null;
            const item = tree.items[parent];
            if (item.kind == .field) return null;
            const rel = try n.r.containerRel(.{ .file = c.file, .container = @intCast(ci) }) orelse return null;
            const b = try n.r.body(c.file, parent);
            if (item.kind == .@"const" or item.kind == .@"var") {
                const value = b.value orelse return null;
                if (!yields(b, value, rel)) return null;
                return .{ .name = item.name orelse return null, .item = parent, .by = .member };
            }
            for (b.bindings) |binding| {
                const init = binding.init orelse continue;
                if (yields(b, init, rel)) return .{ .name = binding.name, .item = parent, .by = .local };
            }
            if (item.kind != .@"fn") return null;
            for (b.exprs) |e| switch (e) {
                .@"return" => |v| if (v) |operand| if (yields(b, operand, rel)) return .{ .name = item.name orelse return null, .item = parent, .by = .returned },
                else => {},
            };
            return null;
        };
        return null;
    }

    /// Whether the result of the expression is the container at `rel`: the container itself, or
    /// the result of a branch of an `if` / `switch`
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

/// Whether the container is the value written in the constant `item` of `file`
/// (`const S = struct {...}`, including a branch of an `if` / `switch`), the declaration it is
/// named after; false for an alias of a container declared elsewhere (`const T = S`,
/// `const Self = @This()`, `const L = List(u8)`)
pub fn declaresContainer(r: *Resolver, c: InternPool.Container, file: FileId, item: u32) resolve.Error!bool {
    if (c.kind == .file or c.file != file) return false;
    const tree = try r.itemTree(file);
    for (tree.containers, 0..) |x, ci| if (x.ast_id == c.ast_id) {
        if (x.parent_item != item) return false;
        const rel = try r.containerRel(.{ .file = file, .container = @intCast(ci) }) orelse return false;
        const b = try r.body(file, item);
        return ContainerNames.yields(b, b.value orelse return false, rel);
    };
    return false;
}

/// Display listing the full contents: types in hover and completion details (values there are
/// limited, see `shownValue`)
pub fn writeFull(r: *Resolver, t: Index, w: *Io.Writer) Io.Writer.Error!void {
    try r.ctx.db.env.ip.print(t, w, ContainerNames{ .r = r, .full = true });
}

/// The result of `@typeName`: the name the compiler gives the type, allocated in `a`.
/// Containers are fully qualified by the module path of their file and the declarations that
/// name them (`main.S.Inner`, `array_list.Aligned(u8,null)`). Null when that name cannot be
/// determined exactly: containers the compiler names after a global counter (all but those that
/// are directly the value of a declaration, of a local constant, or of a `return`), containers in
/// a generic instance that do not capture every argument their name shows (the instances share
/// one type, named after the instance that creates it first), types constructed by builtins,
/// function types (the calling convention is not tracked), inferred error sets and unknown parts.
pub fn typeName(r: *Resolver, a: std.mem.Allocator, t: Index) resolve.Error!?[]const u8 {
    var out: Io.Writer.Allocating = .init(a);
    var q: QualifiedNames = .{ .r = r, .w = &out.writer };
    q.writeType(t) catch |err| switch (err) {
        error.Unnamed => return null,
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return out.written();
}

/// Writes types and values in the format of the compiler's `Type.print` and `Value.print`
const QualifiedNames = struct {
    r: *Resolver,
    w: *Io.Writer,

    const Error = resolve.Error || Io.Writer.Error || error{Unnamed};

    fn writeType(q: *QualifiedNames, t: Index) Error!void {
        const ip = q.r.ctx.db.env.ip;
        const w = q.w;
        switch (ip.key(t)) {
            .simple_type => |s| try w.writeAll(switch (s) {
                .null => "@TypeOf(null)",
                .undefined => "@TypeOf(undefined)",
                .enum_literal => "@EnumLiteral()",
                else => @tagName(s),
            }),
            .int_type => |i| try w.print("{c}{d}", .{ @as(u8, if (i.signedness == .signed) 'i' else 'u'), i.bits }),
            .ptr_type => |p| {
                try w.writeAll(switch (p.size) {
                    .one => "*",
                    .many => "[*",
                    .slice => "[",
                    .c => "[*c",
                });
                if (p.size != .one) {
                    if (p.sentinel) |s| {
                        try w.writeAll(":");
                        try q.writeValue(s);
                    }
                    try w.writeAll("]");
                }
                if (p.is_const) try w.writeAll("const ");
                try q.writeType(p.child);
            },
            .array_type => |arr| {
                try w.print("[{d}", .{arr.len});
                if (arr.sentinel) |s| {
                    try w.writeAll(":");
                    try q.writeValue(s);
                }
                try w.writeAll("]");
                try q.writeType(arr.child);
            },
            .optional_type => |c| {
                try w.writeAll("?");
                try q.writeType(c);
            },
            .error_union_type => |e| {
                try q.writeType(e.err);
                try w.writeAll("!");
                try q.writeType(e.payload);
            },
            // The compiler lists the names sorted by their bytes
            .error_set_type => |names| {
                const sorted = try q.r.arena.dupe([]const u8, names);
                std.mem.sort([]const u8, sorted, {}, struct {
                    fn lessThan(_: void, x: []const u8, y: []const u8) bool {
                        return std.mem.lessThan(u8, x, y);
                    }
                }.lessThan);
                try w.writeAll("error{");
                for (sorted, 0..) |n, i| {
                    if (i != 0) try w.writeAll(",");
                    try w.writeAll(n);
                }
                try w.writeAll("}");
            },
            .vector_type => |v| {
                try w.print("@Vector({d}, ", .{v.len});
                try q.writeType(v.child);
                try w.writeAll(")");
            },
            .tuple_type => |tuple| {
                if (tuple.types.len == 0) return w.writeAll("@TypeOf(.{})");
                try w.writeAll("struct {");
                for (tuple.types, 0..) |ty, i| {
                    try w.writeAll(if (i == 0) " " else ", ");
                    const v = InternPool.fieldValue(tuple.values, i);
                    if (v == .unknown) return error.Unnamed;
                    if (v != .runtime) try w.writeAll("comptime ");
                    try q.writeType(ty);
                    if (v != .runtime) {
                        try w.writeAll(" = ");
                        try q.writeValue(v);
                    }
                }
                try w.writeAll(" }");
            },
            .union_tag_type => |u| {
                try w.writeAll("@typeInfo(");
                try q.writeType(u);
                try w.writeAll(").@\"union\".tag_type.?");
            },
            .container_type => |c| try q.writeContainer(c),
            else => return error.Unnamed,
        }
    }

    /// Values in types: sentinels, comptime fields of tuples and the arguments in the names of
    /// containers returned by generic functions
    fn writeValue(q: *QualifiedNames, v: Index) Error!void {
        const ip = q.r.ctx.db.env.ip;
        switch (ip.key(v)) {
            .int_value => |x| try q.w.print("{d}", .{x.value}),
            .simple_value => |s| try q.w.writeAll(if (s == .void) "{}" else @tagName(s)),
            .enum_literal => |n| try q.w.print(".{s}", .{n}),
            .enum_tag => |tag| try q.w.print(".{s}", .{tag.name}),
            .error_value => |n| try q.w.print("error.{s}", .{n}),
            else => try q.writeType(v),
        }
    }

    fn writeContainer(q: *QualifiedNames, c: InternPool.Container) Error!void {
        const r = q.r;
        if (c.kind == .file) return q.writeFile(c.file);
        const tree = try r.itemTree(c.file);
        const ci = for (tree.containers, 0..) |x, i| {
            if (x.ast_id == c.ast_id) break i;
        } else return error.Unnamed;
        const ns: Namespace = .{ .file = c.file, .container = @intCast(ci) };
        const parent = tree.containers[ns.container].parent_item orelse return error.Unnamed;
        const item = tree.items[parent];
        const rel = try r.containerRel(ns) orelse return error.Unnamed;
        const b = try r.body(c.file, parent);
        switch (item.kind) {
            // The value of a declaration: named after it
            .@"const", .@"var" => {
                if (!isContainerAt(b, b.value orelse return error.Unnamed, rel)) return error.Unnamed;
                try q.requireCaptured(c, ns, null);
                try q.writeNamespace(c, parent);
                try q.w.print(".{s}", .{item.name orelse return error.Unnamed});
            },
            .@"fn" => {
                // The value of a local constant or variable: named after the function and the
                // local, without the arguments
                for (b.bindings) |binding| if (binding.init) |init| if (isContainerAt(b, init, rel)) {
                    try q.requireCaptured(c, ns, item.ast_id);
                    try q.writeNamespace(c, parent);
                    try q.w.print(".{s}.{s}", .{ item.name orelse return error.Unnamed, binding.name });
                    return;
                };
                // The operand of a `return`: named after the function and its arguments
                for (b.exprs) |e| switch (e) {
                    .@"return" => |operand| if (operand) |o| if (isContainerAt(b, o, rel)) {
                        try q.requireCaptured(c, ns, null);
                        try q.writeNamespace(c, parent);
                        try q.w.print(".{s}", .{item.name orelse return error.Unnamed});
                        return q.writeArgs(c, parent, b);
                    },
                    else => {},
                };
                return error.Unnamed;
            },
            else => return error.Unnamed,
        }
    }

    /// Whether expression `e` is directly the container at `rel` (the compiler names a
    /// container after its declaration only then)
    fn isContainerAt(b: *const Body, e: Body.ExprId, rel: u32) bool {
        return b.expr(e) == .container and b.range(e).start == rel;
    }

    /// The container that declares member `item`, in the instance of container `c`
    fn writeNamespace(q: *QualifiedNames, c: InternPool.Container, item: u32) Error!void {
        const tree = try q.r.itemTree(c.file);
        try q.writeType(try queries.containerType(q.r, .{ .file = c.file, .container = tree.items[item].container }, c.inst));
    }

    /// `(a,b)`: the arguments of the instance of the function `item` that returns container `c`
    fn writeArgs(q: *QualifiedNames, c: InternPool.Container, item: u32, b: *const Body) Error!void {
        const ip = q.r.ctx.db.env.ip;
        const tree = try q.r.itemTree(c.file);
        const inst: ?InternPool.Instance = if (c.inst) |i| switch (ip.key(i)) {
            .instance => |k| if (k.file == c.file and k.decl == tree.items[item].ast_id) k else null,
            else => null,
        } else null;
        const k = inst orelse {
            // A function that is not generic: the compiler shows the values of its runtime
            // parameters, which the type does not record
            if (b.params.len != 0) return error.Unnamed;
            return q.w.writeAll("()");
        };
        // The instance records the type of an `anytype` argument, not its value
        const forms = try q.r.ctx.get(database.hir.ParamForms, .{ .file = c.file, .item = k.decl });
        try q.w.writeAll("(");
        for (k.args, 0..) |arg, i| {
            if (arg == .runtime or arg == .unknown) return error.Unnamed;
            if (i < forms.len and forms[i] == .any) return error.Unnamed;
            if (i != 0) try q.w.writeAll(",");
            try q.writeValue(arg);
        }
        try q.w.writeAll(")");
    }

    /// The compiler identifies a container in a generic instance by the values it captures, so
    /// the instances whose arguments its name shows must all be told apart by them: the
    /// container must capture every parameter of each enclosing instance (except `exempt`, the
    /// function whose local constant it is, whose arguments the name does not show)
    fn requireCaptured(q: *QualifiedNames, c: InternPool.Container, ns: Namespace, exempt: ?AstId) Error!void {
        const r = q.r;
        const ip = r.ctx.db.env.ip;
        var caps: ?[]const eval.Capture = null;
        var cur = c.inst;
        while (cur) |i| {
            const k = switch (ip.key(i)) {
                .instance => |k| k,
                else => return,
            };
            if (k.iteration != null) return error.Unnamed;
            cur = k.parent;
            if (k.file == c.file and exempt == k.decl) continue;
            const tree = try r.itemTree(k.file);
            const fn_item = for (tree.items, 0..) |it, n| {
                if (it.ast_id == k.decl) break n;
            } else return error.Unnamed;
            const params = (try r.body(k.file, @intCast(fn_item))).params;
            if (params.len == 0) continue;
            if (k.file != ns.file) return error.Unnamed;
            const captured = caps orelse try eval.captures(r, ns);
            caps = captured;
            for (params) |p| {
                for (captured) |cap| {
                    if (cap.item == fn_item and cap.binding == p) break;
                } else return error.Unnamed;
            }
        }
    }

    /// A file is named after its path under the root directory of its module, without the
    /// extension and with `.` for the separators (`util/thing.zig` → `util.thing`). A file
    /// outside every module is compiled on its own as a root, so only its base name is used.
    fn writeFile(q: *QualifiedNames, file: FileId) Error!void {
        const r = q.r;
        const vfs = r.ctx.db.env.vfs;
        const path = vfs.path(file);
        const sub = if (try moduleDir(r, file)) |dir| sub: {
            if (!vfs.isUnder(path, dir) or path.len <= dir.len) return error.Unnamed;
            break :sub std.mem.trimStart(u8, path[dir.len..], "/\\");
        } else std.fs.path.basename(path);
        const ext = std.fs.path.extension(sub);
        for (sub[0 .. sub.len - ext.len]) |ch| try q.w.writeByte(if (ch == '/' or ch == '\\') '.' else ch);
    }

    /// Root directory of the module of `file`: the standard library's for its files; null for a
    /// file in no module
    fn moduleDir(r: *Resolver, file: FileId) resolve.Error!?[]const u8 {
        const vfs = r.ctx.db.env.vfs;
        const path = vfs.path(file);
        if (try r.ctx.get(database.ModuleGraph.StdRoot, r.context)) |std_root| if (std.fs.path.dirname(vfs.path(std_root))) |dir| {
            if (vfs.isUnder(path, dir)) return dir;
        };
        const graph = try r.ctx.get(database.ModuleGraph.Input, {}) orelse return null;
        const e = graph.entry(file) orelse return null;
        if (e.module >= graph.modules.len) return null;
        const root = graph.modules[e.module].root orelse return null;
        return std.fs.path.dirname(vfs.path(root));
    }
};

pub fn typeAlloc(r: *Resolver, t: Index) error{OutOfMemory}![]const u8 {
    return (try typeAllocNoting(r, t, null)).text;
}

/// Like `typeAlloc`, but outputs at most about `max_length` characters (see
/// `ContainerNames.max_length`) and reports whether it contains anonymous containers displayed
/// by their contents
pub fn typeAllocNoting(r: *Resolver, t: Index, max_length: ?usize) error{OutOfMemory}!struct { text: []const u8, anonymous: bool } {
    var out: Io.Writer.Allocating = .init(r.arena);
    var anonymous = false;
    r.ctx.db.env.ip.print(t, &out.writer, ContainerNames{ .r = r, .anonymous = &anonymous, .max_length = max_length }) catch return error.OutOfMemory;
    return .{ .text = out.written(), .anonymous = anonymous };
}

/// Displays `type = T` when the value is a type, and `T = v` for other values known at comptime.
/// Lists the full contents of the type; the value is limited (see `shownValue`) (hover,
/// completion details).
pub fn typedValueAlloc(r: *Resolver, tv: TypedValue) error{OutOfMemory}![]const u8 {
    var out: Io.Writer.Allocating = .init(r.arena);
    writeFull(r, tv.ty, &out.writer) catch return error.OutOfMemory;
    if (try shownValue(r, tv)) |v| out.writer.print(" = {s}", .{v}) catch return error.OutOfMemory;
    return out.written();
}

/// The part after the declaration name: `: T = v`; only ` = v` when the value determines the
/// type (see `valueDetermined`)
pub fn annotationAlloc(r: *Resolver, tv: TypedValue) error{OutOfMemory}![]const u8 {
    if (valueDetermined(r.ctx.db.env.ip, tv)) return std.fmt.allocPrint(r.arena, " = {s}", .{(try shownValue(r, tv)).?});
    return std.fmt.allocPrint(r.arena, ": {s}", .{try typedValueAlloc(r, tv)});
}

/// Display without a declaration (for an expression): only the value when the value determines
/// the type, otherwise the same as `typedValueAlloc`
pub fn exprAlloc(r: *Resolver, tv: TypedValue) error{OutOfMemory}![]const u8 {
    if (valueDetermined(r.ctx.db.env.ip, tv)) return (try shownValue(r, tv)).?;
    return typedValueAlloc(r, tv);
}

/// Display of a value that is directly the result of `@embedFile(path)`: the type (in full) and
/// the call instead of the content, `T = @embedFile("path")`
pub fn embedAlloc(r: *Resolver, ty: Index, path: []const u8) error{OutOfMemory}![]const u8 {
    var out: Io.Writer.Allocating = .init(r.arena);
    writeFull(r, ty, &out.writer) catch return error.OutOfMemory;
    out.writer.print(" = @embedFile(\"{f}\")", .{std.zig.fmtString(path)}) catch return error.OutOfMemory;
    return out.written();
}

/// Tuples and anonymous structs whose fields are all comptime fields, when the value is known:
/// the type is fully determined by the value (the type of `.{ A, B }` is
/// `struct { comptime type = A, comptime type = B }`), so displaying the value suffices
fn valueDetermined(ip: *InternPool, tv: TypedValue) bool {
    if (tv.val == null) return false;
    const types, const values = switch (ip.key(tv.ty)) {
        .tuple_type => |t| .{ t.types, t.values },
        .anon_struct_type => |s| .{ s.types, s.values },
        else => return false,
    };
    for (0..types.len) |i| switch (InternPool.fieldValue(values, i)) {
        .runtime, .unknown => return false,
        else => {},
    };
    return true;
}

/// Maximum number of characters of a displayed comptime value: a value such as a slice of a large
/// binary `@embedFile` would otherwise make a hover of several megabytes. The cut is marked: `…`
/// and the full number of items or bytes follow (`"ab…" (1048576 bytes total)`). Also the
/// maximum number of characters of embedded text shown in hover.
pub const max_value_length = 2000;

/// The value known at comptime, at most about `max_value_length` characters (functions are not
/// displayed: the type already shows the signature)
fn shownValue(r: *Resolver, tv: TypedValue) error{OutOfMemory}!?[]const u8 {
    const v = tv.val orelse return null;
    if (r.ctx.db.env.ip.key(v) == .fn_value) return null;
    var out: Io.Writer.Allocating = .init(r.arena);
    r.ctx.db.env.ip.print(v, &out.writer, ContainerNames{ .r = r, .full = true, .max_length = max_value_length, .show_total = true }) catch return error.OutOfMemory;
    return out.written();
}
