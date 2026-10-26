//! inlay hints：没有类型标注的局部变量的类型；初始化表达式中字段的类型；调用处（含内置函数）的参数名。

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
    /// 类型取自调用点的实例时说明所依据的调用
    tooltip: ?[]const u8 = null,
};

/// 配置 `inlay_hints.*`
pub const Options = struct {
    types: bool = true,
    /// 初始化表达式中字段名之后的字段类型
    field_types: bool = true,
    /// 类型中有按内容显示的匿名容器（`.kind: struct { a: u32 }`、`[]const struct { y: u8 }`）时也显示类型提示
    anonymous_containers: bool = false,
    parameters: bool = true,
    /// 内置函数调用的参数名；`parameters` 关闭时同样不提示
    builtin_parameters: bool = true,
    /// 只有一个实参的调用（含内置函数与去掉接收者后只剩一个实参的方法调用）不提示参数名
    exclude_single_argument: bool = true,
    /// 实参去掉 `&`、`.*`、`.?`、`try` 后是同名的变量（或以形参名结尾的字段访问）时不提示形参名
    hide_redundant_param_names: bool = true,
    /// 类型提示的字符数上限：超出时列表（字段、实参等）的其余项显示为 `…`，可能超出一项；0 为不限
    max_length: u32 = 25,
};

/// `[start, end)` 范围内的提示
pub fn inlayHints(r: *Resolver, file: FileId, start: u32, end: u32, opts: Options) resolve.Error![]const Hint {
    var out: std.ArrayList(Hint) = .empty;
    const tree = try r.itemTree(file);
    for (tree.items, 0..) |_, i| {
        const node = try r.itemNode(file, @intCast(i)) orelse continue;
        const range = node.range();
        if (range.end < start or range.start > end) continue;
        const a = try context.atSeeded(r, file, range.start, false) orelse continue;
        // 嵌套的成员各自处理：只处理以本成员为最内层 owner 的提示
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
        // 泛型函数体内抽象的类型（如 `T`）照常显示，只有未知时才取调用点的实例
        const abstract = a.res.bindings[i];
        const tv = if (abstract.ty == .unknown) a.bindingType(@fromBackingInt(@as(u32, @intCast(i)))) else abstract;
        // 未知的类型与值为类型的常量（`const T = u8`）不提示
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
                const target = try context.callee(r, a, c.callee) orelse continue;
                const params = try context.fnParams(r, target.def);
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

/// 初始化表达式中各字段名之后的字段类型。初始化的类型与推导时一致：写出的类型，或结果类型去掉 error union 与
/// optional（表达式本身记录的类型已转换为结果类型，不能直接用）。没有结果类型的 `.{ ... }`（匿名结构体）不提示：
/// 它的字段类型就是值的类型
fn fieldTypeHints(r: *Resolver, a: context.At, e: Body.ExprId, init: @FieldType(Body.Expr, "init"), start: u32, end: u32, opts: Options, out: *std.ArrayList(Hint)) resolve.Error!void {
    const ip = a.ip;
    const t: InternPool.Index = if (init.ty) |te| a.exprType(te).asType() orelse return else t: {
        var want = a.literalExpected(e) orelse return;
        if (ip.key(want) == .error_union_type) want = ip.key(want).error_union_type.payload;
        if (ip.key(want) == .optional_type) want = ip.key(want).optional_type;
        break :t want;
    };
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

/// 类型提示的文字；类型中有按内容显示的匿名容器而 `anonymous_containers` 关闭时为 null
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

/// 实参去掉不改变所指的值的外壳（`&x`、`x.*`、`x.?`、`try x`，可多层）后是名为 `name` 的变量，或最后一段为
/// `name` 的字段访问。其他运算（`a + x`、`-x`、`x orelse y` 等）得到新的值，不算
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

/// 内置函数参数的名字：`comptime T: type` 的 `T`、`noalias dest` 的 `dest`
fn builtinParamName(param: []const u8) []const u8 {
    var p = param;
    for ([_][]const u8{ "comptime ", "noalias " }) |prefix| {
        if (std.mem.startsWith(u8, p, prefix)) p = p[prefix.len..];
    }
    return std.mem.trim(u8, p[0 .. std.mem.indexOfScalar(u8, p, ':') orelse p.len], " ");
}

/// 内置函数是否提示参数名。单参数的都提示（由 `exclude_single_argument` 决定）；没有参数与变参的没有可提示的名字；
/// 多参数的按 `multi_param_hints`
fn showsParamNames(entry: *const builtins.Entry) bool {
    if (entry.variadic) return false;
    return switch (entry.parameters.len) {
        0 => false,
        1 => true,
        else => multi_param_hints.get(entry.name).?,
    };
}

/// 多参数内置函数是否提示参数名。只在参数名能补上实参看不出的信息时提示：同类型的实参顺序不合惯例、容易传反
/// （`@memcpy`、`@cmpxchgStrong`）；类型构造函数按位置传的配置（`@Struct(.auto, null, ...)` 中的 `null`）；
/// 参数顺序反常（`@fieldParentPtr`）。必须覆盖所有多参数内置函数，新增的内置函数在这里决定之前编译不过
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
    // 顺序与 `a / b`、`a << b` 一致
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
    // 参数名（`a`、`b`）没有信息量
    .{ "@mulAdd", false },
    .{ "@select", false },
    .{ "@shuffle", false },
    // 各实参的类型不同，看实参就知道是哪个参数
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

/// 「inferred from the call at file.zig:123」
fn seedNote(r: *Resolver, s: seed.Seed) resolve.Error![]const u8 {
    const text = (try r.ctx.get(@import("../database.zig").syntax.SourceText, s.file)).text;
    const line = std.mem.count(u8, text[0..@min(s.offset, text.len)], "\n") + 1;
    return std.fmt.allocPrint(r.arena, "inferred from the call at {s}:{d}", .{ std.fs.path.basename(r.ctx.db.env.vfs.path(s.file)), line });
}
