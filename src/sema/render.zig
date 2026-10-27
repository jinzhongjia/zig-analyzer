//! Display of types and values (shared by hover, inlay hints and completion details).

const std = @import("std");
const Io = std.Io;
const InternPool = @import("InternPool.zig");
const Index = InternPool.Index;
const TypedValue = InternPool.TypedValue;
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const queries = @import("queries.zig");
const Body = @import("../hir/Body.zig");

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

    /// List the full contents: hover, `@typeName` and the display of values. Otherwise (inlay
    /// hints, completion details, etc.) nested anonymous containers are displayed as
    /// `struct {...}`.
    full: bool = false,
    /// Maximum number of characters in the output (`max_length` of inlay hints); null means
    /// unlimited. See `InternPool.truncateList`; the output must be written to an
    /// `Io.Writer.Allocating`, which keeps everything written so far in its buffer.
    max_length: ?usize = null,

    const Outer = struct { c: InternPool.Container, parent: ?*const Outer };

    /// Number of characters the output can still take (read by `InternPool.print`); null means
    /// unlimited
    pub fn remaining(n: ContainerNames, w: *Io.Writer) ?usize {
        const max = n.max_length orelse return null;
        const written = w.buffered();
        return max -| (std.unicode.utf8CountCodepoints(written) catch written.len);
    }

    pub fn write(n: ContainerNames, c: InternPool.Container, w: *Io.Writer) Io.Writer.Error!void {
        const found = n.name(c) catch null;
        try w.writeAll(found orelse return n.writeContent(c, w));
        // Generic instance: `List(u8)`, listing only the arguments known at comptime
        try n.writeArgs(n.shownInst(c.inst) orelse return, w);
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
        const inner: ContainerNames = .{ .r = n.r, .outer = &here, .anonymous = n.anonymous, .full = n.full, .max_length = n.max_length };
        const ip = n.r.ctx.db.env.ip;
        try w.writeAll(" {");
        var count: usize = 0;
        for (tree.containerMembers(@intCast(ci))) |m| {
            const it = tree.items[m];
            if (it.kind != .field) continue;
            try w.writeAll(if (count == 0) " " else ", ");
            count += 1;
            if (try InternPool.truncateList(n, w)) break;
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
    /// is displayed
    fn shownInst(n: ContainerNames, inst: ?Index) ?Index {
        const i = inst orelse return null;
        const key = n.r.ctx.db.env.ip.key(i).instance;
        if (key.iteration) |it| if (it.abstract) return n.shownInst(key.parent);
        return i;
    }

    /// Types constructed by builtins: named after the function instance that constructs them
    /// (`FieldEnum(S)`); when not constructed in a function and exactly the value of a constant,
    /// named after the constant (`const Kind = blk: { ... break :blk @Enum(...); }` → `Kind`);
    /// otherwise displayed by their contents
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

    /// Name of the constant where the type is constructed, when its value is exactly this type
    /// (constructed at the same place)
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
        // Non-comptime parameters are not part of the instance's identity and are not shown;
        // unknown comptime arguments are shown as `_`
        for (ip.key(inst).instance.args) |arg| {
            if (arg == .runtime) continue;
            if (!first) try w.writeAll(", ");
            first = false;
            if (try InternPool.truncateList(n, w)) break;
            if (arg == .unknown) try w.writeAll("_") else try ip.print(arg, w, n);
        }
        try w.writeAll(")");
    }

    /// A container that is the value of a member is named after the member:
    /// `const S = struct {...}` is `S`, in a function body it is named after the local constant,
    /// and a `return`ed container is named after the function (`List(u8)`); the same naming
    /// applies when the value is an `if` / `switch` choosing among several containers (the
    /// compiler names it `S__struct_1` here; naming after the member is more readable).
    /// Containers in type annotations of fields and variables, in arguments, and in
    /// `?struct {...}` have no name; returns null.
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

/// Display listing the full contents: the result of `@typeName`, and types and values in hover
/// and completion details
pub fn writeFull(r: *Resolver, t: Index, w: *Io.Writer) Io.Writer.Error!void {
    try r.ctx.db.env.ip.print(t, w, ContainerNames{ .r = r, .full = true });
}

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
/// Lists the full contents without truncation (hover, completion details).
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

/// The value known at comptime (functions and `simple_value` are not displayed)
fn shownValue(r: *Resolver, tv: TypedValue) error{OutOfMemory}!?[]const u8 {
    const v = tv.val orelse return null;
    switch (r.ctx.db.env.ip.key(v)) {
        .fn_value, .simple_value => return null,
        else => {},
    }
    var out: Io.Writer.Allocating = .init(r.arena);
    writeFull(r, v, &out.writer) catch return error.OutOfMemory;
    return out.written();
}
