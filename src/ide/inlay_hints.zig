//! inlay hints: types of local variables without a type annotation; types of fields in
//! initializers; parameter names at call sites (including builtin calls).

const std = @import("std");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const context = @import("context.zig");
const builtins = @import("builtins.zig");
const seed = @import("../ide_db/seed.zig");
const render = @import("../sema/render.zig");
const infer = @import("../sema/infer.zig");
const queries = @import("../sema/queries.zig");
const InternPool = @import("../sema/InternPool.zig");
const Body = @import("../hir/Body.zig");
const FileId = @import("../base/Vfs.zig").FileId;

pub const Hint = struct {
    offset: u32,
    label: []const u8,
    kind: enum { type, parameter },
    /// When the type is taken from a call-site instance, describes the call it is based on
    tooltip: ?[]const u8 = null,
};

/// The `inlay_hints.*` configuration
pub const Options = struct {
    types: bool = true,
    /// Field types after the field names in initializers
    field_types: bool = true,
    /// Also show type hints when the type contains an anonymous container shown by its contents
    /// (`.kind: struct { a: u32 }`, `[]const struct { y: u8 }`)
    anonymous_containers: bool = false,
    parameters: bool = true,
    /// Parameter names of builtin calls; likewise not shown when `parameters` is off
    builtin_parameters: bool = true,
    /// Calls with a single argument (including builtins, and method calls left with one argument
    /// after the receiver is removed) get no parameter names
    exclude_single_argument: bool = true,
    /// No parameter name when the argument, with `&`, `.*`, `.?` and `try` removed, is a variable
    /// with the same name (or a field access ending in the parameter name)
    hide_redundant_param_names: bool = true,
    /// Character limit of a type hint: beyond it, the remaining items of lists (fields, arguments,
    /// ...) are shown as `…`, which may exceed the limit by one item; 0 means no limit
    max_length: u32 = 25,
};

/// Hints in the range `[start, end)`
pub fn inlayHints(r: *Resolver, file: FileId, start: u32, end: u32, opts: Options) resolve.Error![]const Hint {
    var out: std.ArrayList(Hint) = .empty;
    const tree = try r.itemTree(file);
    for (tree.items, 0..) |_, i| {
        const node = try r.itemNode(file, @intCast(i)) orelse continue;
        const range = node.range();
        if (range.end < start or range.start > end) continue;
        const a = try context.atSeeded(r, file, range.start, false) orelse continue;
        // Nested members are handled on their own: only hints whose innermost owner is this member
        if (a.item != i) continue;
        try bodyHints(r, a, start, end, opts, &out);
    }
    std.mem.sort(Hint, out.items, {}, struct {
        fn lt(_: void, x: Hint, y: Hint) bool {
            return x.offset < y.offset;
        }
    }.lt);
    return out.items;
}

fn bodyHints(r: *Resolver, a: context.At, start: u32, end: u32, opts: Options, out: *std.ArrayList(Hint)) resolve.Error!void {
    const b = a.body;
    const base = a.node.offset;
    if (opts.types) for (b.bindings, 0..) |binding, i| {
        if (binding.kind != .local_const and binding.kind != .local_var) continue;
        if (binding.ty != null or binding.name.len == 0) continue;
        const at = base + binding.range.end;
        if (at < start or at > end) continue;
        // Abstract types in a generic function body (such as `T`) are shown as usual; a call-site
        // instance is used only for unknown types
        const abstract = a.res.bindings[i];
        const tv = if (abstract.ty == .unknown) a.bindingType(@fromBackingInt(@as(u32, @intCast(i)))) else abstract;
        // No hints for unknown types or for constants whose value is a type (`const T = u8`)
        if (tv.ty == .unknown or tv.ty == .type_type) continue;
        const tooltip: ?[]const u8 = if (abstract.ty == .unknown) if (a.seeded) |s| try seedNote(r, s) else null else null;
        const label = try typeLabel(r, tv.ty, opts) orelse continue;
        try out.append(r.arena, .{ .offset = at, .label = label, .kind = .type, .tooltip = tooltip });
    };
    if (opts.field_types) for (b.exprs, 0..) |e, i| {
        if (e != .init) continue;
        try fieldTypeHints(r, a, @fromBackingInt(@as(u32, @intCast(i))), e.init, start, end, opts, out);
    };
    if (opts.parameters) for (b.exprs, 0..) |e, i| {
        const range = b.expr_ranges[i];
        if (base + range.end < start or base + range.start > end) continue;
        switch (e) {
            .call => |c| {
                if (opts.exclude_single_argument and c.args.len == 1) continue;
                const target = try context.callProto(r, a, c.callee) orelse continue;
                const params = try target.params(r.arena);
                const skip: usize = if (target.bound) 1 else 0;
                for (c.args, 0..) |arg, ai| {
                    if (ai + skip >= params.len) break;
                    const name = (params[ai + skip].name() orelse continue).text;
                    try paramHint(r, a, arg, name, opts, out);
                }
            },
            .builtin_call => |c| {
                if (!opts.builtin_parameters) continue;
                if (opts.exclude_single_argument and c.args.len == 1) continue;
                const entry = builtins.get(c.name) orelse continue;
                if (!showsParamNames(entry)) continue;
                const n = @min(c.args.len, entry.parameters.len);
                for (c.args[0..n], entry.parameters[0..n]) |arg, param| try paramHint(r, a, arg, builtinParamName(param), opts, out);
            },
            else => {},
        }
    };
}

/// Field types after each field name in an initializer, in the initializer's type (see
/// `context.At.initType`). `.{ ... }` without a result type (an anonymous struct) gets no hints:
/// its field types are just the types of the values
fn fieldTypeHints(r: *Resolver, a: context.At, e: Body.ExprId, init: @FieldType(Body.Expr, "init"), start: u32, end: u32, opts: Options, out: *std.ArrayList(Hint)) resolve.Error!void {
    const t = a.initType(e) orelse return;
    if (t == .unknown) return;
    const ns = try queries.namespaceOfType(r, t);
    for (init.fields, 0..) |f, k| {
        if (f.name == null) continue;
        const at = a.node.offset + f.name_range.end;
        if (at < start or at > end) continue;
        const ty = (try infer.initField(r, t, ns, k, f.name)).ty orelse continue;
        if (ty == .unknown) continue;
        try out.append(r.arena, .{ .offset = at, .label = try typeLabel(r, ty, opts) orelse continue, .kind = .type });
    }
}

/// Text of a type hint; null when the type contains an anonymous container shown by its
/// contents and `anonymous_containers` is off
fn typeLabel(r: *Resolver, t: InternPool.Index, opts: Options) resolve.Error!?[]const u8 {
    const shown = try render.typeAllocNoting(r, t, if (opts.max_length == 0) null else opts.max_length);
    if (shown.anonymous and !opts.anonymous_containers) return null;
    return try std.fmt.allocPrint(r.arena, ": {s}", .{shown.text});
}

fn paramHint(r: *Resolver, a: context.At, arg: Body.ExprId, name: []const u8, opts: Options, out: *std.ArrayList(Hint)) resolve.Error!void {
    if (std.mem.eql(u8, name, "_")) return;
    if (opts.hide_redundant_param_names and namesParam(a.body, arg, name)) return;
    try out.append(r.arena, .{ .offset = a.node.offset + a.body.range(arg).start, .label = try std.fmt.allocPrint(r.arena, "{s}:", .{name}), .kind = .parameter });
}

/// Whether the argument, after stripping wrappers that do not change the value it refers to (`&x`,
/// `x.*`, `x.?`, `try x`, possibly nested), is a variable named `name` or a field access whose
/// last segment is `name`. Other operations (`a + x`, `-x`, `x orelse y`, ...) produce a new value
/// and do not count
fn namesParam(b: *const Body, arg: Body.ExprId, name: []const u8) bool {
    var e = arg;
    while (true) switch (b.expr(e)) {
        .prefix => |p| switch (p.op) {
            .ampersand, .keyword_try => e = p.operand,
            else => return false,
        },
        .deref, .unwrap_optional => |x| e = x,
        .name_ref => |n| return std.mem.eql(u8, n, name),
        .field_access => |fa| return if (fa.field) |f| std.mem.eql(u8, f, name) else false,
        else => return false,
    };
}

/// Name of a builtin parameter: `T` for `comptime T: type`, `dest` for `noalias dest`
fn builtinParamName(param: []const u8) []const u8 {
    var p = param;
    for ([_][]const u8{ "comptime ", "noalias " }) |prefix| {
        if (std.mem.startsWith(u8, p, prefix)) p = p[prefix.len..];
    }
    return std.mem.trim(u8, p[0 .. std.mem.indexOfScalar(u8, p, ':') orelse p.len], " ");
}

/// Whether a builtin shows parameter names. All single-parameter builtins do (subject to
/// `exclude_single_argument`); builtins without parameters and variadic builtins have no names
/// to show; multi-parameter ones follow `multi_param_hints`
fn showsParamNames(entry: *const builtins.Entry) bool {
    if (entry.variadic) return false;
    return switch (entry.parameters.len) {
        0 => false,
        1 => true,
        else => multi_param_hints.get(entry.name).?,
    };
}

/// Whether a multi-parameter builtin shows parameter names. Names are shown only when they add
/// information the arguments do not reveal: arguments of the same type in an unconventional order
/// that are easy to swap (`@memcpy`, `@cmpxchgStrong`); configuration passed by position to type
/// constructors (the `null` in `@Struct(.auto, null, ...)`); an unusual parameter order
/// (`@fieldParentPtr`). Must cover every multi-parameter builtin: a newly added builtin fails to
/// compile until it is decided here
const multi_param_hints = std.StaticStringMap(bool).initComptime(.{
    .{ "@memcpy", true },
    .{ "@memmove", true },
    .{ "@cmpxchgStrong", true },
    .{ "@cmpxchgWeak", true },
    .{ "@wasmMemoryGrow", true },
    .{ "@Enum", true },
    .{ "@Fn", true },
    .{ "@Pointer", true },
    .{ "@Struct", true },
    .{ "@Union", true },
    .{ "@fieldParentPtr", true },
    // The order matches `a / b` and `a << b`
    .{ "@divExact", false },
    .{ "@divFloor", false },
    .{ "@divTrunc", false },
    .{ "@divCeil", false },
    .{ "@mod", false },
    .{ "@rem", false },
    .{ "@addWithOverflow", false },
    .{ "@subWithOverflow", false },
    .{ "@mulWithOverflow", false },
    .{ "@shlWithOverflow", false },
    .{ "@shlExact", false },
    .{ "@shrExact", false },
    // The parameter names (`a`, `b`) carry no information
    .{ "@mulAdd", false },
    .{ "@select", false },
    .{ "@shuffle", false },
    // The arguments have different types, so the argument shows which parameter it is
    .{ "@as", false },
    .{ "@Int", false },
    .{ "@Vector", false },
    .{ "@FieldType", false },
    .{ "@atomicLoad", false },
    .{ "@atomicStore", false },
    .{ "@atomicRmw", false },
    .{ "@call", false },
    .{ "@export", false },
    .{ "@extern", false },
    .{ "@prefetch", false },
    .{ "@field", false },
    .{ "@hasDecl", false },
    .{ "@hasField", false },
    .{ "@offsetOf", false },
    .{ "@bitOffsetOf", false },
    .{ "@reduce", false },
    .{ "@unionInit", false },
    .{ "@cVaArg", false },
    .{ "@memset", false },
});

comptime {
    @setEvalBranchQuota(20000);
    var multi = 0;
    for (builtins.entries) |entry| {
        if (entry.variadic or entry.parameters.len < 2) continue;
        multi += 1;
        if (multi_param_hints.get(entry.name) == null)
            @compileError("inlay hints: decide whether " ++ entry.name ++ " shows parameter names in multi_param_hints");
    }
    if (multi != multi_param_hints.keys().len)
        @compileError("inlay hints: multi_param_hints lists a builtin that is not a multi-parameter builtin");
}

/// "inferred from the call at file.zig:123"
fn seedNote(r: *Resolver, s: seed.Seed) resolve.Error![]const u8 {
    const text = (try r.ctx.get(@import("../database.zig").syntax.SourceText, s.file)).text;
    const line = std.mem.count(u8, text[0..@min(s.offset, text.len)], "\n") + 1;
    return std.fmt.allocPrint(r.arena, "inferred from the call at {s}:{d}", .{ std.fs.path.basename(r.ctx.db.env.vfs.path(s.file)), line });
}
