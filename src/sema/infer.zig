//! 表达式类型推导：双向推导，期望类型从参数、返回值、类型标注、字段初始化下推；
//! 分支汇合处做 peer type resolution 的常用子集。未知部分为 `unknown`，吸收一切且不产生诊断。
//!
//! 类型表达式（`?*const T`、`[]u8`、`struct {...}`）也是表达式，求值得到 `type` 类型的值。
//!
//! comptime 求值：调用带 comptime / anytype 参数或返回 `type` 的函数时创建实例
//! （InternPool 的 `instance`），在实例中推导函数体：参数绑定到实参值，条件已知的
//! `if` / `switch` 只走实际执行的分支，整数、布尔与类型相等比较做常量折叠，返回 `type` 的函数
//! 取实际执行到的 `return` 的值。没有具体实例时 `comptime T: type` 为抽象参数 `T`。

const std = @import("std");
const Allocator = std.mem.Allocator;
const database = @import("../database.zig");
const Db = database.Db;
const hir = database.hir;
const syntax = database.syntax;
const InternPool = @import("InternPool.zig");
const Index = InternPool.Index;
const TypedValue = InternPool.TypedValue;
const Body = @import("../hir/Body.zig");
const ExprId = Body.ExprId;
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Namespace = resolve.Namespace;
const FileId = @import("../base/Vfs.zig").FileId;
const ItemTree = @import("../syntax/ItemTree.zig");
const deepEql = @import("../util/deep_eql.zig").deepEql;
const queries = @import("queries.zig");
const value = @import("value.zig");
const eval = @import("eval.zig");
const SyntaxKind = @import("../syntax/kind.zig").SyntaxKind;

pub const Error = resolve.Error;

/// 一个 BodyOwner 的推导结果
pub const Result = struct {
    arena: std.heap.ArenaAllocator.State,
    /// 与 `Body.exprs` 一一对应
    exprs: []const TypedValue,
    /// 与 `Body.bindings` 一一对应
    bindings: []const TypedValue,
    /// 与 `Body.exprs` 一一对应：字段访问解析到的成员（字段或声明）
    members: []const ?hir.OwnerKey,
    /// 函数实际执行到的 `return` 的值（类型构造函数的结果）
    ret: TypedValue,
    /// 初始化表达式中字段名解析到的字段（`.{ .x = 1 }` 的 `x`）
    field_refs: []const FieldRef = &.{},
    /// 有期望类型的枚举字面量（含 decl literal 与还没写名字的 `.`）、错误值（`error.X`）与匿名初始化
    /// （`.{ ... }`）及其期望类型：补全按它列出成员、错误名与字段
    literal_expected: []const LiteralExpected = &.{},
    /// comptime 已知不会执行的 `if` / `switch` 分支，以及左侧已决定结果的 `and` / `or` 的右侧（最外层的）：
    /// 在当前构建配置下不编译的代码
    inactive: []const ExprId = &.{},
    /// 同一块中 noreturn 语句之后的语句（相对 owner 的范围）：同样不编译。如被选中的
    /// `if (!@hasDecl(T, "x")) @compileError(...);`、comptime 条件下的 `return` 之后的代码
    dead_spans: []const Body.Range = &.{},
    /// 类型为枚举字面量的参数（anytype 收到的 `.x`）在函数体中被转换成的类型，每个参数取第一处：调用处的
    /// 字面量引用这个类型中的成员（`testing.expectEqual(.x, actual)` 经 `@TypeOf(expected, actual)` 转换为
    /// actual 的类型）
    param_coercions: []const ParamCoercion = &.{},

    pub const LiteralExpected = struct { expr: ExprId, ty: Index };
    pub const ParamCoercion = struct { param: u32, ty: Index };

    pub const FieldRef = struct {
        /// `init` 表达式
        init: ExprId,
        /// 在 `Body.Expr.init.fields` 中的下标
        index: u32,
        member: hir.OwnerKey,
    };

    pub fn eql(a: *const Result, b: *const Result) bool {
        return deepEql(a.exprs, b.exprs) and deepEql(a.bindings, b.bindings) and deepEql(a.members, b.members) and deepEql(a.ret, b.ret) and deepEql(a.field_refs, b.field_refs) and deepEql(a.literal_expected, b.literal_expected) and deepEql(a.inactive, b.inactive) and deepEql(a.dead_spans, b.dead_spans) and deepEql(a.param_coercions, b.param_coercions);
    }

    pub fn deinit(r: *Result, gpa: Allocator) void {
        var arena = r.arena.promote(gpa);
        arena.deinit();
        r.* = undefined;
    }
};

pub const Mode = enum {
    /// 只推导签名：参数类型、返回类型、变量与字段的类型标注
    signature,
    full,
};

/// 按迭代推导：循环（`inline for`、comptime 中的 `for`）的循环变量 `binding` 取列表的第 `index` 个元素，
/// `inline` switch 分支的捕获 `binding` 取第 `index` 个分支项的值（见 `queries.InferKey.loop`）
pub const LoopSeed = struct { binding: u32, index: u32 };

pub fn run(ctx: *Db.Ctx, owner: hir.OwnerKey, mode: Mode, inst: ?Index, loop_seed: ?LoopSeed) Error!Result {
    const gpa = ctx.db.gpa;
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
    const tree = try r.itemTree(owner.file);
    const item: u32 = for (tree.items, 0..) |it, i| {
        if (it.ast_id == owner.item) break @intCast(i);
    } else return empty(gpa);
    const body = try ctx.get(hir.ItemBody, owner);
    const split = try splitIteration(ctx.db.env.ip, owner, inst);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var inf: Inferrer = .{
        .r = &r,
        .ip = ctx.db.env.ip,
        .file = owner.file,
        .item = item,
        .body = body,
        .exprs = try a.alloc(TypedValue, body.exprs.len),
        .done = try std.DynamicBitSetUnmanaged.initEmpty(scratch.allocator(), body.exprs.len),
        .bindings = try a.alloc(TypedValue, body.bindings.len),
        .members = try a.alloc(?hir.OwnerKey, body.exprs.len),
        .scratch = scratch.allocator(),
        .inst = split.inst,
        .loop_seed = split.seed orelse loop_seed,
    };
    @memset(inf.exprs, .unknown);
    @memset(inf.bindings, .unknown);
    @memset(inf.members, null);
    try inf.runOwner(tree.items[item].kind, mode);
    const ret = try inf.returnValue();
    const field_refs = try a.dupe(Result.FieldRef, inf.field_refs.items);
    const literal_expected = try a.dupe(Result.LiteralExpected, inf.literal_expected.items);
    const inactive = try a.dupe(ExprId, inf.inactive.items);
    const dead_spans = try a.dupe(Body.Range, inf.dead_spans.items);
    const param_coercions = try a.dupe(Result.ParamCoercion, inf.param_coercions.items);
    return .{ .arena = arena.state, .exprs = inf.exprs, .bindings = inf.bindings, .members = inf.members, .ret = ret, .field_refs = field_refs, .literal_expected = literal_expected, .inactive = inactive, .dead_spans = dead_spans, .param_coercions = param_coercions };
}

/// 只推导成员 `owner` 中的一个局部绑定或 comptime 表达式（见 `queries.LocalValue`）
pub fn runLocal(ctx: *Db.Ctx, owner: hir.OwnerKey, target_ref: @FieldType(queries.LocalKey, "target"), inst: ?Index) Error!TypedValue {
    const gpa = ctx.db.gpa;
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var r: Resolver = .{ .ctx = ctx, .arena = a };
    const tree = try r.itemTree(owner.file);
    const item: u32 = for (tree.items, 0..) |it, i| {
        if (it.ast_id == owner.item) break @intCast(i);
    } else return .unknown;
    const body = try ctx.get(hir.ItemBody, owner);
    const split = try splitIteration(ctx.db.env.ip, owner, inst);
    var inf: Inferrer = .{
        .r = &r,
        .ip = ctx.db.env.ip,
        .file = owner.file,
        .item = item,
        .body = body,
        .exprs = try a.alloc(TypedValue, body.exprs.len),
        .done = try std.DynamicBitSetUnmanaged.initEmpty(a, body.exprs.len),
        .bindings = try a.alloc(TypedValue, body.bindings.len),
        .members = try a.alloc(?hir.OwnerKey, body.exprs.len),
        .scratch = a,
        .inst = split.inst,
        .loop_seed = split.seed,
    };
    @memset(inf.exprs, .unknown);
    @memset(inf.bindings, .unknown);
    @memset(inf.members, null);
    if (tree.items[item].kind == .@"fn") {
        const own = inf.ownInstance();
        for (body.params, 0..) |p, i| inf.bindings[@backingInt(p)] = try inf.paramValue(p, if (own) |o| (if (i < o.args.len) o.args[i] else .unknown) else null);
    }
    const binding = switch (target_ref) {
        .binding => |id| id,
        .expr => |e| {
            if (@backingInt(e) >= body.exprs.len) return .unknown;
            inf.lazy = body.range(e);
            return inf.inferComptime(e, null);
        },
    };
    if (@backingInt(binding) >= body.bindings.len) return .unknown;
    const target = body.binding(binding);
    switch (target.kind) {
        .param => return inf.bindings[@backingInt(binding)],
        .local_const, .local_var => {
            const init = target.init orelse return .unknown;
            // 初始化表达式之外的局部绑定按需查询（见 `nameRef`）
            inf.lazy = body.range(init);
            const annotation: ?Index = if (target.ty) |t| (try inf.inferComptime(t, null)).asType() orelse .unknown else null;
            const v = try inf.infer(init, annotation);
            return if (annotation) |t|
                .{ .ty = t, .val = if (target.kind == .local_const and v.ty == t) v.val else null }
            else if (target.kind == .local_const)
                v
            else
                .{ .ty = v.ty };
        },
        // 捕获的值取决于控制流：取整个成员的推导结果
        .capture => {
            const res = try ctx.get(queries.Infer, .{ .owner = owner, .mode = .full, .inst = split.inst, .loop = split.seed });
            return if (@backingInt(binding) < res.bindings.len) res.bindings[@backingInt(binding)] else .unknown;
        },
    }
}

fn empty(gpa: Allocator) Result {
    _ = gpa;
    return .{ .arena = .{}, .exprs = &.{}, .bindings = &.{}, .members = &.{}, .ret = .unknown };
}

const Inferrer = struct {
    r: *Resolver,
    ip: *InternPool,
    file: FileId,
    item: u32,
    body: *const Body,
    exprs: []TypedValue,
    done: std.DynamicBitSetUnmanaged,
    bindings: []TypedValue,
    members: []?hir.OwnerKey,
    scratch: Allocator,
    /// 函数的返回类型（return 的期望类型）
    ret_type: ?Index = null,
    /// 带标签的块与循环：break 的值类型
    labels: std.ArrayList(LabelFrame) = .empty,
    /// 方法调用：字段访问解析到实例上的函数声明（调用时跳过 self 参数）
    bound: std.AutoHashMapUnmanaged(ExprId, void) = .empty,
    /// 初始化表达式中字段名的引用（见 `Result.field_refs`）
    field_refs: std.ArrayList(Result.FieldRef) = .empty,
    /// 正在推导的 init 表达式
    current_init: ?ExprId = null,
    /// 只推导一个局部绑定（`runLocal`）时其初始化表达式的范围：范围外的局部绑定没有推导，按需查询
    lazy: ?Body.Range = null,
    /// 见 `Result.literal_expected`
    literal_expected: std.ArrayList(Result.LiteralExpected) = .empty,
    /// 见 `Result.inactive`
    inactive: std.ArrayList(ExprId) = .empty,
    /// 见 `Result.dead_spans`
    dead_spans: std.ArrayList(Body.Range) = .empty,
    /// 见 `Result.param_coercions`
    param_coercions: std.ArrayList(Result.ParamCoercion) = .empty,
    /// 实例上下文（owner 自身或外层泛型函数的实例）
    inst: ?Index,
    /// 见 `LoopSeed`
    loop_seed: ?LoopSeed = null,
    /// 大于 0 时位于 comptime 已知不会执行的分支中：其中的 return 不计入结果
    dead: u32 = 0,
    /// 实际执行到的 return 的值
    returns: std.ArrayList(TypedValue) = .empty,
    /// 大于 0 时位于 comptime 上下文中（类型表达式、数组长度、comptime 实参等）：其中的函数调用由解释器求值
    comptime_depth: u32 = 0,
    /// 成员中直接发起的 comptime 求值的回跳配额（见 `eval.bodyQuota`），首次使用时计算
    quota: ?u32 = null,

    /// break 的目标。只记录实际会执行到的 break（不在 comptime 已知不执行的分支中）
    const LabelFrame = struct {
        name: ?[]const u8,
        is_loop: bool,
        expected: ?Index = null,
        types: std.ArrayList(Index) = .empty,
        values: std.ArrayList(TypedValue) = .empty,
    };

    fn runOwner(inf: *Inferrer, kind: ItemTree.Item.Kind, mode: Mode) Error!void {
        const b = inf.body;
        switch (kind) {
            .@"fn" => {
                const own = inf.ownInstance();
                for (b.params, 0..) |p, i| inf.bindings[@backingInt(p)] = try inf.paramValue(p, if (own) |o| (if (i < o.args.len) o.args[i] else .unknown) else null);
                if (b.type_expr) |t| inf.ret_type = (try inf.inferComptime(t, null)).asType();
                if (mode == .full) if (b.value) |v| {
                    _ = try inf.infer(v, null);
                };
            },
            .@"const", .@"var", .field => {
                const annotation: ?Index = if (b.type_expr) |t| (try inf.inferComptime(t, null)).asType() else if (kind == .field) try inf.enumValueType() else null;
                // 对齐属于签名：字段的布局读取它
                if (b.align_expr) |e| _ = try inf.inferComptime(e, try inf.clauseType(.@"align"));
                if (mode == .full) if (b.value) |v| {
                    _ = try inf.infer(v, annotation);
                };
            },
            .@"test", .@"comptime" => if (mode == .full) if (b.value) |v| {
                _ = try inf.infer(v, null);
            },
        }
        // 子句不属于表达式树：按子句的结果类型推导
        if (mode == .full) for (b.clauses) |c| {
            _ = try inf.infer(c.expr, try inf.clauseType(c.kind));
        };
    }

    /// 枚举成员的值（`a = 1`）的结果类型：显式给出的标签类型
    fn enumValueType(inf: *Inferrer) Error!?Index {
        const tree = try inf.r.itemTree(inf.file);
        const container = tree.items[inf.item].container;
        if (tree.containers[container].kind != .@"enum") return null;
        const t = try queries.containerType(inf.r, .{ .file = inf.file, .container = container }, inf.inst);
        return eval.explicitTagType(inf.r, t);
    }

    /// 子句中表达式的结果类型（与编译器一致）
    fn clauseType(inf: *Inferrer, kind: Body.Clause.Kind) Error!?Index {
        const ip = inf.ip;
        return switch (kind) {
            .@"align" => try ip.intType(.unsigned, 29),
            .bit_range => try ip.intType(.unsigned, 16),
            .@"linksection" => try ip.ptrTo(.u8_type, .slice, true),
            .@"callconv" => try inf.stdType(&.{ "builtin", "CallingConvention" }),
            .@"addrspace" => try inf.stdType(&.{ "builtin", "AddressSpace" }),
        };
    }

    fn branchQuota(inf: *Inferrer) u32 {
        if (inf.quota) |q| return q;
        const q = eval.bodyQuota(inf.r, inf.body, inf.exprs);
        inf.quota = q;
        return q;
    }

    /// owner 自身（函数）的实例
    /// 本成员按迭代推导时（`loop_seed`）的实例，见 `InternPool.Instance.iteration`；不按迭代推导时为 null
    fn iterationInstance(inf: *Inferrer) Error!?Index {
        const seed = inf.loop_seed orelse return null;
        return try inf.instanceAt(seed.binding, seed.index);
    }

    /// 本成员的实例在循环变量 `binding` 取第 `index` 次迭代时
    fn instanceAt(inf: *Inferrer, binding: u32, index: u32) Error!Index {
        if (inf.ownInstance()) |own| {
            var key = own;
            key.iteration = .{ .binding = binding, .index = index, .abstract = false };
            return inf.ip.get(.{ .instance = key });
        }
        const decl = (try inf.r.itemTree(inf.file)).items[inf.item].ast_id;
        return inf.ip.get(.{ .instance = .{ .file = inf.file, .decl = decl, .args = &.{}, .parent = inf.inst, .iteration = .{ .binding = binding, .index = index, .abstract = true } } });
    }

    /// 本成员中定义在 `e` 处的容器的实例。每次迭代单独分析的循环体（`inline for`、`inline` switch 分支）内的
    /// 容器，字段类型可以依赖循环变量：按迭代推导时取这次迭代的实例，否则取迭代未确定的实例（类型不具体）
    fn containerInst(inf: *Inferrer, e: ExprId) Error!?Index {
        const at = inf.body.range(e).start;
        if (inf.loop_seed) |seed| if (seedRegion(inf.body, seed.binding)) |rg| if (rg.contains(at)) return try inf.instanceAt(seed.binding, seed.index);
        var best: ?struct { binding: u32, len: u32 } = null;
        for (inf.body.exprs) |x| {
            const binding: Body.BindingId, const rg = switch (x) {
                .loop => |l| if (l.is_inline and l.capture.len > 0) .{ l.capture[0], inf.body.range(l.body) } else continue,
                .@"switch" => |sw| blk: {
                    for (sw.prongs) |p| if (p.is_inline and p.capture.len > 0 and inf.body.range(p.body).contains(at)) break :blk .{ p.capture[0], inf.body.range(p.body) };
                    continue;
                },
                else => continue,
            };
            if (!rg.contains(at)) continue;
            if (best == null or rg.end - rg.start < best.?.len) best = .{ .binding = @backingInt(binding), .len = rg.end - rg.start };
        }
        const b = best orelse return inf.inst;
        return try inf.instanceAt(b.binding, InternPool.Instance.Iteration.unknown_index);
    }

    fn ownInstance(inf: *Inferrer) ?InternPool.Instance {
        const i = inf.inst orelse return null;
        const key = inf.ip.key(i).instance;
        if (key.file != inf.file) return null;
        const tree = inf.r.itemTree(inf.file) catch return null;
        return if (key.decl == tree.items[inf.item].ast_id) key else null;
    }

    /// 参数的值：实例中 comptime 参数取实参值（按参数类型转换），comptime anytype 参数取实参值，
    /// anytype 参数取实参的类型；
    /// 没有具体实参时类型参数（`comptime T: type`，或不写 comptime 的 `T: type`）为抽象参数
    fn paramValue(inf: *Inferrer, p: Body.BindingId, arg: ?Index) Error!TypedValue {
        const binding = inf.body.binding(p);
        const ty_e = binding.ty orelse {
            const a = arg orelse return .unknown;
            if (a == .runtime or a == .unknown) return .unknown;
            // comptime anytype：实例记录的是实参值；anytype：实参类型
            if (binding.is_comptime) return .{ .ty = value.typeOfValue(inf.ip, a), .val = a };
            return .{ .ty = a };
        };
        const ty: Index = (try inf.inferComptime(ty_e, null)).asType() orelse .unknown;
        if (arg) |a| if (a != .unknown and a != .runtime) return .{ .ty = ty, .val = (try value.coerceValue(inf.ip, a, ty)) orelse a };
        if (ty == .type_type and (arg == null or arg.? == .unknown)) return TypedValue.ofType(try inf.ip.get(.{ .opaque_param = .{ .file = inf.file, .owner = try inf.body_owner(), .binding = @backingInt(p), .name = binding.name } }));
        return .{ .ty = ty };
    }

    /// 读取 ItemTree 是 query：即使已缓存，读事务被写事务或客户端取消时也会返回 `error.Canceled`
    fn body_owner(inf: *Inferrer) Error!ItemTree.AstId {
        return (try inf.r.itemTree(inf.file)).items[inf.item].ast_id;
    }

    /// 实际执行到的 return 的值：都相同时带值，否则为类型的 peer
    fn returnValue(inf: *Inferrer) Error!TypedValue {
        const rs = inf.returns.items;
        if (rs.len == 0) return .unknown;
        const first = rs[0];
        for (rs[1..]) |x| if (!deepEql(x, first)) {
            if (inf.selfInstance(rs)) |own| return own;
            var types: std.ArrayList(Index) = .empty;
            for (rs) |y| try types.append(inf.scratch, y.ty);
            return .{ .ty = try inf.peer(types.items) };
        };
        return first;
    }

    /// 条件求不出时的多个 return 都是同一个容器定义的不同实例（自递归的类型函数，如 `Aligned` 中的
    /// `return Aligned(T, null)` 与 `return struct {...}`）：取本实例中的那个
    fn selfInstance(inf: *Inferrer, rs: []const TypedValue) ?TypedValue {
        var own: ?TypedValue = null;
        var def: ?InternPool.Container = null;
        for (rs) |x| {
            const c = switch (inf.ip.key(x.val orelse return null)) {
                .container_type => |c| c,
                else => return null,
            };
            if (def) |d| {
                if (d.file != c.file or d.ast_id != c.ast_id) return null;
            } else def = c;
            if (std.meta.eql(c.inst, inf.inst)) own = x;
        }
        return own;
    }

    /// 求不出值的条件是否 comptime 已知（如取决于抽象参数）：comptime 上下文、结果为 comptime-only 类型、
    /// 容器级的常量与变量的初始化和字段（在 comptime 求值），或条件本身 comptime 已知
    fn comptimeCond(inf: *Inferrer, cond: ExprId, result: Index) Error!bool {
        if (inf.comptime_depth > 0 or value.isComptimeOnly(inf.ip, result)) return true;
        const kind = (try inf.r.itemTree(inf.file)).items[inf.item].kind;
        if (kind != .@"fn" and kind != .@"test") return true;
        return try inf.knownness(cond, 0) == .comptime_known;
    }

    /// comptime 已知的条件：bool 值，或 optional 是否为 null（非 null 的 optional 值即其载荷值）
    fn isCompileError(inf: *Inferrer, e: ExprId) bool {
        return switch (inf.body.expr(e)) {
            .builtin_call => |c| std.mem.eql(u8, c.name, "@compileError"),
            else => false,
        };
    }

    fn condValue(inf: *Inferrer, cond: TypedValue) ?bool {
        const v = cond.val orelse return null;
        switch (inf.ip.key(cond.ty)) {
            // 非 null 的 optional 与成功的 error union 以载荷值表示，`false` 载荷仍是成功
            .optional_type => return switch (v) {
                .null_value => false,
                .unknown, .undefined_value => null,
                else => true,
            },
            .error_union_type => {
                if (v == .unknown or v == .undefined_value) return null;
                return switch (inf.ip.key(v)) {
                    .error_value => false,
                    else => true,
                };
            },
            else => {},
        }
        if (v == .true_value) return true;
        if (v == .false_value) return false;
        if (v == .null_value) return false;
        if (v == .unknown or v == .undefined_value) return null;
        return null;
    }

    /// `if` / `switch` 的分支：不会执行的记录为非活动代码（见 `Result.inactive`）
    fn inferArm(inf: *Inferrer, e: ExprId, expected: ?Index, dead_branch: bool) Error!TypedValue {
        if (dead_branch and inf.dead == 0) try inf.inactive.append(inf.scratch, e);
        return inf.inferBranch(e, expected, dead_branch);
    }

    /// 在 `dead_branch` 为真时以「不会执行」的状态推导
    fn inferBranch(inf: *Inferrer, e: ExprId, expected: ?Index, dead_branch: bool) Error!TypedValue {
        if (dead_branch) inf.dead += 1;
        defer if (dead_branch) {
            inf.dead -= 1;
        };
        return inf.infer(e, expected);
    }

    fn get(inf: *Inferrer, e: ExprId) TypedValue {
        return inf.exprs[@backingInt(e)];
    }

    pub fn infer(inf: *Inferrer, e: ExprId, expected: ?Index) Error!TypedValue {
        const i = @backingInt(e);
        if (inf.done.isSet(i)) return inf.exprs[i];
        inf.done.set(i);
        // 嵌套过深（深层的表达式或 query 递归）：以未知结束，结果不缓存
        if (inf.r.ctx.stackExhausted()) {
            inf.r.ctx.exhausted();
            return .unknown;
        }
        const raw = try inf.inferInner(e, expected);
        const tv = try inf.coerce(raw, expected);
        inf.exprs[i] = tv;
        // 转换为枚举 / union 的枚举字面量（`.red`、`switch` 的 `.a =>`）引用对应的成员
        if (inf.members[i] == null and inf.body.expr(e) == .enum_literal) try inf.recordTagMember(e, tv.ty);
        if (raw.ty == .enum_literal_type) if (expected) |want| try inf.noteParamCoercion(e, want);
        return tv;
    }

    /// 没有结果类型的分支结果按 peer type 转换（`if (b.op()) |t| t.kind else .invalid`）：分支中的枚举字面量引用
    /// peer 类型中的成员，并以它为期望类型
    fn peerLiteral(inf: *Inferrer, e: ExprId, ty: Index) Error!void {
        if (ty == .unknown or ty == .enum_literal_type) return;
        if (inf.body.expr(e) != .enum_literal or inf.members[@backingInt(e)] != null) return;
        if (inf.get(e).ty != .enum_literal_type) return;
        try inf.literal_expected.append(inf.scratch, .{ .expr = e, .ty = ty });
        try inf.recordTagMember(e, ty);
    }

    /// 见 `Result.param_coercions`：`e` 是对本成员参数的引用，以期望类型 `want` 使用
    fn noteParamCoercion(inf: *Inferrer, e: ExprId, want: Index) Error!void {
        if (want == .unknown or want == .enum_literal_type) return;
        const b = inf.body;
        const name = switch (b.expr(e)) {
            .name_ref => |n| n,
            else => return,
        };
        const def = try inf.r.resolveName(inf.file, inf.item, b, b.expr_scopes[@backingInt(e)], name) orelse return;
        const l = switch (def) {
            .local => |l| l,
            else => return,
        };
        if (l.file != inf.file or l.item != inf.item) return;
        const param: u32 = @intCast(std.mem.indexOfScalar(Body.BindingId, b.params, l.binding) orelse return);
        for (inf.param_coercions.items) |pc| if (pc.param == param) return;
        try inf.param_coercions.append(inf.scratch, .{ .param = param, .ty = want });
    }

    /// comptime 上下文中的表达式（类型标注、参数与返回类型、数组长度）。推导求不出值时，在最外层
    /// 交给解释器以当前的绑定求值（如 `fn f(comptime T: type) switch (@typeInfo(T)) {...}`）
    fn inferComptime(inf: *Inferrer, e: ExprId, expected: ?Index) Error!TypedValue {
        const outermost = inf.comptime_depth == 0;
        inf.comptime_depth += 1;
        const tv = blk: {
            defer inf.comptime_depth -= 1;
            break :blk try inf.infer(e, expected);
        };
        if (tv.val != null or inf.dead > 0) return tv;
        // comptime 实参中的字符串字面量（推导器平时不为字符串生成值）：与解释器一致，值的类型为 `*const [N:0]u8`
        switch (inf.body.expr(e)) {
            .literal => |text| if (try Body.stringLiteralValue(inf.scratch, text)) |str| {
                const ty = try inf.ip.stringLiteralType(str.len);
                const v: TypedValue = .{ .ty = ty, .val = try inf.ip.get(.{ .bytes = .{ .ty = ty, .bytes = str } }) };
                inf.exprs[@backingInt(e)] = v;
                return v;
            },
            else => {},
        }
        if (!outermost or inf.r.ctx.incomplete()) return tv;
        switch (inf.body.expr(e)) {
            .missing, .other, .literal, .name_ref => return tv,
            else => {},
        }
        const ev = try eval.exprValue(inf.r, inf.file, inf.item, inf.body, e, inf.inst, inf.bindings, expected, inf.branchQuota());
        if (ev.val == null) return tv;
        inf.exprs[@backingInt(e)] = ev;
        return ev;
    }

    fn recordTagMember(inf: *Inferrer, e: ExprId, t: Index) Error!void {
        // 结果类型为 `E!U`、`?U`、`E!?U` 时转换到 U（`fn parse() Error!Value { return .null_val; }`）
        const want = inf.destType(t, .eu_opt) orelse return;
        // `union(enum)` 生成的标签枚举：成员是 union 的字段
        const want_union = switch (inf.ip.key(want)) {
            .union_tag_type => |u| u,
            else => want,
        };
        return inf.recordTagMemberOf(e, want_union);
    }

    fn recordTagMemberOf(inf: *Inferrer, e: ExprId, want: Index) Error!void {
        const c = switch (inf.ip.key(want)) {
            .container_type => |c| c,
            else => return,
        };
        if (c.kind != .@"enum" and c.kind != .@"union") return;
        const ns = try queries.namespaceOfType(inf.r, want) orelse return;
        const tree = try inf.r.itemTree(ns.file);
        const f = fieldItem(tree, ns.container, inf.body.expr(e).enum_literal) orelse return;
        inf.members[@backingInt(e)] = .{ .file = ns.file, .item = tree.items[f].ast_id };
    }

    /// 结果类型转换：字面量类的值在有期望类型时取期望类型（optional 的期望类型先按载荷类型转换），
    /// `T` 的值转换为 `?T`
    fn coerce(inf: *Inferrer, tv: TypedValue, expected: ?Index) Error!TypedValue {
        const want = expected orelse return tv;
        if (want == .unknown or tv.ty == want) return tv;
        const ip = inf.ip;
        const target = switch (ip.key(want)) {
            .optional_type => |c| c,
            else => want,
        };
        switch (tv.ty) {
            .comptime_int_type, .comptime_float_type => if (ip.isInt(target) or ip.isFloat(target)) {
                const val: ?Index = if (tv.val) |v| try value.coerceValue(ip, v, want) else null;
                return .{ .ty = want, .val = val };
            },
            .enum_literal_type => if (tv.val) |v| {
                // `E!T`：字面量转换为载荷类型 T（再由编译器包装成 error union）
                switch (ip.key(want)) {
                    .error_union_type => |eu| return inf.coerce(tv, eu.payload),
                    else => {},
                }
                const name = ip.key(v).enum_literal;
                if (value.isEnumType(ip, target)) return .{ .ty = want, .val = try ip.get(.{ .enum_tag = .{ .ty = target, .name = name } }) };
                switch (ip.key(target)) {
                    .container_type => |c| if (c.kind == .@"union") return .{ .ty = want },
                    .reified_type => |rt| if (rt.kind == .@"union") return .{ .ty = want },
                    else => {},
                }
            },
            .null_type, .undefined_type => return .{ .ty = want, .val = tv.val },
            else => {},
        }
        if (target != want and tv.ty == target) return .{ .ty = want, .val = tv.val };
        return tv;
    }

    fn inferInner(inf: *Inferrer, e: ExprId, expected: ?Index) Error!TypedValue {
        const ip = inf.ip;
        const b = inf.body;
        switch (b.expr(e)) {
            .missing => return .unknown,
            .name_ref => |name| return inf.nameRef(e, name),
            .literal => |text| return inf.literal(text),
            .field_access => |fa| return inf.fieldAccess(e, fa.lhs, fa.field),
            .enum_literal => |name| {
                if (expected) |want| if (want != .unknown) try inf.literal_expected.append(inf.scratch, .{ .expr = e, .ty = want });
                if (expected) |want| if (try inf.declLiteral(e, want, name)) |tv| return tv;
                return .{ .ty = .enum_literal_type, .val = try ip.get(.{ .enum_literal = name }) };
            },
            .error_value => |name| {
                if (expected) |want| if (want != .unknown) try inf.literal_expected.append(inf.scratch, .{ .expr = e, .ty = want });
                const set = try ip.errorSet(inf.scratch, &.{name});
                return .{ .ty = set, .val = try ip.get(.{ .error_value = name }) };
            },
            .builtin_call => |bc| return inf.builtin(e, bc.name, bc.args, expected),
            .call => |c| return inf.call(c.callee, c.args, expected),
            .block => |blk| return inf.block(blk, expected),
            .@"if" => |x| {
                const cond = try inf.infer(x.cond, null);
                try inf.bindCaptures(x.capture, x.cond, cond, .if_then);
                try inf.bindCaptures(x.else_capture, x.cond, cond, .if_else);
                const taken = inf.condValue(cond);
                const then = try inf.inferArm(x.then, expected, taken == false);
                const other: TypedValue = if (x.@"else") |el| try inf.inferArm(el, expected, taken == true) else .{ .ty = .void_type };
                if (taken) |t| {
                    // 选中的分支是 `@compileError`：被使用的声明不可能是编译错误（否则无法编译），使用它的代码
                    // 只在另一个分支生效的配置中编译。如 `std.testing.allocator = if (builtin.is_test) .. else
                    // @compileError(..)` 在非测试模块的 test 块中使用：取另一个分支
                    if (x.@"else") |el| {
                        const chosen, const rest = if (t) .{ x.then, el } else .{ el, x.then };
                        if (inf.isCompileError(chosen) and !inf.isCompileError(rest)) return if (t) other else then;
                    }
                    return if (t) then else other;
                }
                const ty = try inf.peer(&.{ then.ty, other.ty });
                try inf.peerLiteral(x.then, ty);
                if (x.@"else") |el| try inf.peerLiteral(el, ty);
                return .{ .ty = ty, .val = if (try inf.comptimeCond(x.cond, ty)) sameLiveValue(&.{ then, other }, ty) else null };
            },
            .loop => |l| return inf.loop(l, expected),
            .@"switch" => |s| {
                const operand = try inf.infer(s.operand, null);
                // 带标签的 union 按标签匹配：分支项按标签类型推导，转换为 union 本身会失去值，选不出执行的分支
                const item_ty = try inf.comparedType(operand.ty);
                for (s.prongs) |prong| for (prong.items) |item| {
                    _ = try inf.infer(item, item_ty);
                };
                // 带标签的 switch：`break :label value` 的值也是结果
                const label = inf.switchLabel(e, s.operand);
                // comptime 已知的操作数：只有匹配的分支会执行。`continue :label` 会转到其他分支，有它时不选
                const chosen = if (label != null and inf.continuesTo(label.?)) null else try inf.chooseProng(s.prongs, operand);
                if (label) |name| try inf.labels.append(inf.scratch, .{ .name = name, .is_loop = false, .expected = expected });
                var types: std.ArrayList(Index) = .empty;
                var values: std.ArrayList(TypedValue) = .empty;
                var chosen_tv: TypedValue = .unknown;
                for (s.prongs, 0..) |prong, i| {
                    try inf.bindSwitchCapture(prong, s.prongs, s.operand, operand, chosen != null and chosen.? == i);
                    const tv = try inf.inferArm(prong.body, expected, chosen != null and chosen.? != i);
                    if (chosen != null and chosen.? == i) chosen_tv = tv;
                    try types.append(inf.scratch, tv.ty);
                    try values.append(inf.scratch, tv);
                }
                if (label != null) {
                    const frame = inf.labels.pop().?;
                    // 选中分支时只记录了它的 break（其他分支按不执行推导）
                    if (chosen != null) {
                        if (frame.types.items.len == 0) return chosen_tv;
                        var live_types: std.ArrayList(Index) = .empty;
                        var live_values: std.ArrayList(TypedValue) = .empty;
                        if (chosen_tv.ty != .noreturn_type) {
                            try live_types.append(inf.scratch, chosen_tv.ty);
                            try live_values.append(inf.scratch, chosen_tv);
                        }
                        try live_types.appendSlice(inf.scratch, frame.types.items);
                        try live_values.appendSlice(inf.scratch, frame.values.items);
                        const t = try inf.peer(live_types.items);
                        return .{ .ty = t, .val = sameValue(live_values.items, t) };
                    }
                    try types.appendSlice(inf.scratch, frame.types.items);
                    try values.appendSlice(inf.scratch, frame.values.items);
                }
                if (chosen != null) return chosen_tv;
                const ty = try inf.peer(types.items);
                for (s.prongs) |prong| try inf.peerLiteral(prong.body, ty);
                return .{ .ty = ty, .val = if (try inf.comptimeCond(s.operand, ty)) sameLiveValue(values.items, ty) else null };
            },
            .@"catch" => |c| {
                const lhs = try inf.infer(c.lhs, null);
                const payload, const err = inf.unwrapErrorUnion(lhs.ty);
                if (c.capture) |cap| inf.bindings[@backingInt(cap)] = .{ .ty = err };
                const rhs = try inf.infer(c.rhs, inf.fallbackType(expected, payload, c.rhs));
                return .{ .ty = try inf.peer(&.{ payload, rhs.ty }) };
            },
            .binary => |bin| return inf.binary(e, bin.op, bin.lhs, bin.rhs, expected),
            .prefix => |p| return inf.prefix(p.op, p.operand, expected),
            .assign => |a| {
                const lhs = try inf.infer(a.lhs, null);
                _ = try inf.infer(a.rhs, try inf.assignRhsType(a.op, lhs.ty));
                return .{ .ty = .void_type };
            },
            .index => |x| {
                const lhs = try inf.infer(x.lhs, null);
                const i = try inf.infer(x.index, .usize_type);
                // 元组（含指向元组的指针）：下标 comptime 已知时取字段的类型；comptime 字段的值属于类型
                if (tupleOf(ip, lhs.ty)) |tt| if (value.intOf(ip, i.val)) |n| if (std.math.cast(usize, n)) |k| if (k < tt.types.len) {
                    if (lhs.val != null) if (try eval.elemValue(inf.r, lhs, k)) |ev| return .{ .ty = tt.types[k], .val = ev.val };
                    const v = InternPool.fieldValue(tt.values, k);
                    return .{ .ty = tt.types[k], .val = if (v == .runtime or v == .unknown) null else v };
                };
                const elem = inf.elementType(lhs.ty);
                // comptime 已知的聚合与下标：取出元素
                if (lhs.val != null) if (value.intOf(ip, i.val)) |n| if (std.math.cast(usize, n)) |k| if (try eval.elemValue(inf.r, lhs, k)) |ev| {
                    return .{ .ty = if (elem != .unknown) elem else ev.ty, .val = ev.val };
                };
                return .{ .ty = elem };
            },
            .slice => |s| return inf.slice(e, s.lhs, s.start, s.end, s.sentinel),
            .deref => |x| {
                const p = try inf.infer(x, null);
                const pt = switch (ip.key(p.ty)) {
                    // C 指针也可以解引用（translate-c 生成的 `[*c]T`）
                    .ptr_type => |pt| if (pt.size == .one or pt.size == .c) pt else return .unknown,
                    else => return .unknown,
                };
                // 指向常量的 comptime 已知指针：由解释器取出所指的值
                if (pt.is_const) if (try inf.knownValue(e, p.val, pt.child)) |tv| return tv;
                return .{ .ty = pt.child };
            },
            .unwrap_optional => |x| {
                const o = try inf.infer(x, null);
                const child: Index = switch (ip.key(o.ty)) {
                    .optional_type => |c| c,
                    else => .unknown,
                };
                // 已知的非 null optional 值即载荷值
                return .{ .ty = child, .val = if (child != .unknown and inf.condValue(o) == true) o.val else null };
            },
            .init => |x| {
                if (x.ty == null) if (expected) |want| if (want != .unknown) try inf.literal_expected.append(inf.scratch, .{ .expr = e, .ty = want });
                const saved = inf.current_init;
                inf.current_init = e;
                defer inf.current_init = saved;
                return inf.initExpr(x.ty, x.fields, expected);
            },
            .container => |c| {
                if (c.arg) |arg| _ = try inf.infer(arg, null);
                const ns = try inf.containerAt(e) orelse return .unknown;
                return TypedValue.ofType(try queries.containerType(inf.r, ns, try inf.containerInst(e)));
            },
            .fn_type => |f| {
                const params = try inf.scratch.alloc(Index, f.params.len);
                for (f.params, params) |p, *out| out.* = (try inf.infer(p, null)).asType() orelse .unknown;
                const ret = if (f.ret) |r| (try inf.infer(r, null)).asType() orelse .unknown else .unknown;
                return TypedValue.ofType(try ip.get(.{ .fn_type = .{ .params = params, .ret = ret } }));
            },
            .@"return" => |v| {
                const ret: TypedValue = if (v) |x| try inf.infer(x, inf.ret_type) else .{ .ty = .void_type };
                if (inf.dead == 0) try inf.returns.append(inf.scratch, ret);
                return .{ .ty = .noreturn_type };
            },
            .@"break" => |br| {
                // 先找到目标：break 的值按块的期望类型推导
                const frame_index = inf.labelFrame(br.label);
                const want: ?Index = if (frame_index) |fi| inf.labels.items[fi].expected else null;
                const brk: TypedValue = if (br.value) |v| try inf.infer(v, want) else .{ .ty = .void_type };
                // 推导期间 labels 可能扩容，按下标重新取
                if (frame_index) |fi| if (inf.dead == 0) {
                    const frame = &inf.labels.items[fi];
                    try frame.types.append(inf.scratch, brk.ty);
                    try frame.values.append(inf.scratch, brk);
                };
                return .{ .ty = .noreturn_type };
            },
            .@"continue" => |c| {
                // labeled switch 的 `continue :l value`：值按 switch 操作数的类型推导
                if (c.value) |v| _ = try inf.infer(v, if (c.label) |l| inf.switchOperandType(e, l) else null);
                return .{ .ty = .noreturn_type };
            },
            .@"comptime" => |x| return inf.inferComptime(x, expected),
            .@"unreachable" => return .{ .ty = .noreturn_type },
            .optional_type => |x| {
                const child = (try inf.infer(x, null)).asType() orelse return typeUnknown();
                return TypedValue.ofType(try ip.optionalOf(child));
            },
            .error_union_type => |eu| {
                const err = (try inf.infer(eu.err, null)).asType() orelse .unknown;
                const payload = (try inf.infer(eu.payload, null)).asType() orelse .unknown;
                // 错误集求不出（抽象参数的 `B.Error`）时保留载荷类型：`try` 的结果仍可确定
                if (payload == .unknown) return typeUnknown();
                return TypedValue.ofType(try ip.get(.{ .error_union_type = .{ .err = err, .payload = payload } }));
            },
            .ptr_type => |p| {
                const child = (try inf.infer(p.child, null)).asType() orelse return typeUnknown();
                const sentinel: ?Index = if (p.sentinel) |x| (try inf.infer(x, child)).val else null;
                if (child == .unknown) return typeUnknown();
                return TypedValue.ofType(try ip.get(.{ .ptr_type = .{ .child = child, .size = @fromBackingInt(@intCast(@backingInt(p.size))), .is_const = p.is_const, .sentinel = sentinel } }));
            },
            .array_type => |arr| {
                const len = try inf.inferComptime(arr.len, .usize_type);
                const child = (try inf.infer(arr.child, null)).asType() orelse return typeUnknown();
                const sentinel: ?Index = if (arr.sentinel) |x| (try inf.infer(x, child)).val else null;
                const n: u64 = if (len.val) |v| switch (ip.key(v)) {
                    .int_value => |iv| std.math.cast(u64, iv.value) orelse return typeUnknown(),
                    else => return typeUnknown(),
                } else {
                    // 长度求不出（如取决于抽象参数）：元素类型已知，长度按源码显示
                    if (child == .unknown or (arr.sentinel != null and sentinel == null)) return typeUnknown();
                    var text: std.ArrayList(u8) = .empty;
                    if (!try inf.exprText(arr.len, &text, 0)) return typeUnknown();
                    return TypedValue.ofType(try ip.get(.{ .abstract_array_type = .{ .len = text.items, .child = child, .sentinel = sentinel } }));
                };
                return TypedValue.ofType(try ip.get(.{ .array_type = .{ .len = n, .child = child, .sentinel = sentinel } }));
            },
            .error_set => |names| return TypedValue.ofType(try ip.errorSet(inf.scratch, names)),
            .other => |children| {
                for (children) |c| _ = try inf.infer(c, null);
                return .unknown;
            },
        }
    }

    // ── 名字 ─────────────────────────────────────────────────────────

    fn nameRef(inf: *Inferrer, e: ExprId, name: []const u8) Error!TypedValue {
        const b = inf.body;
        if (!b.nameRefIsEscaped(e)) if (try primitive(inf.ip, name)) |tv| return tv;
        const def = try inf.r.resolveName(inf.file, inf.item, b, b.expr_scopes[@backingInt(e)], name) orelse return .unknown;
        if (inf.lazy) |range| if (def == .local) {
            const l = def.local;
            // 属于本成员的局部绑定（外层成员的由 defType 经 LocalValue 查询）
            if (l.file != inf.file or l.item != inf.item) return queries.defType(inf.r, def, null, inf.inst);
            const binding = b.binding(l.binding);
            if (binding.kind != .param and !range.contains(binding.range.start)) {
                return inf.r.ctx.get(queries.LocalValue, .{ .owner = try inf.r.ownerKey(l.file, l.item), .target = .{ .binding = l.binding }, .inst = try inf.iterationInstance() orelse inf.inst });
            }
        };
        return queries.defType(inf.r, def, .{ .file = inf.file, .item = inf.item, .bindings = inf.bindings }, inf.inst);
    }

    fn literal(inf: *Inferrer, text: []const u8) Error!TypedValue {
        const ip = inf.ip;
        if (text.len == 0) return .unknown;
        switch (text[0]) {
            '"', '\\' => {
                const s = try Body.stringLiteralValue(inf.scratch, text) orelse return .unknown;
                return .{ .ty = try ip.stringLiteralType(s.len) };
            },
            '\'' => {
                const c = std.zig.parseCharLiteral(text);
                const code: ?i128 = switch (c) {
                    .success => |v| v,
                    .failure => null,
                };
                return .{ .ty = .comptime_int_type, .val = if (code) |v| try ip.get(.{ .int_value = .{ .ty = .comptime_int_type, .value = v } }) else null };
            },
            else => switch (std.zig.parseNumberLiteral(text)) {
                .int => |v| return .{ .ty = .comptime_int_type, .val = try ip.get(.{ .int_value = .{ .ty = .comptime_int_type, .value = v } }) },
                .big_int => return .{ .ty = .comptime_int_type },
                .float => {
                    const x = std.fmt.parseFloat(f128, text) catch return .{ .ty = .comptime_float_type };
                    return .{ .ty = .comptime_float_type, .val = try value.floatValue(ip, .comptime_float_type, x) };
                },
                .failure => return .unknown,
            },
        }
    }

    // ── 成员访问 ─────────────────────────────────────────────────────

    fn fieldAccess(inf: *Inferrer, e: ExprId, lhs_e: ExprId, field: ?[]const u8) Error!TypedValue {
        const ip = inf.ip;
        const lhs = try inf.infer(lhs_e, null);
        const name = field orelse return .unknown;
        // 类型上的成员：声明、枚举成员、错误集成员
        if (lhs.asType()) |t| {
            switch (ip.key(t)) {
                .container_type => {
                    const ns = try queries.namespaceOfType(inf.r, t) orelse return .unknown;
                    const def = try inf.r.memberDef(ns, name) orelse {
                        if (try inf.unionTagMember(e, t, ns, name)) |tv| return tv;
                        return try inf.otherBranchMember(e, lhs_e, t, name) orelse .unknown;
                    };
                    inf.members[@backingInt(e)] = try defKey(inf.r, def);
                    return queries.defType(inf.r, def, null, queries.instOfType(ip, t));
                },
                .error_set_type => return .{ .ty = t, .val = try ip.get(.{ .error_value = name }) },
                // 构造的枚举（`@Enum`、union(enum) 的标签枚举）的成员
                .reified_type, .union_tag_type => return try eval.typeMember(inf.r, t, name) orelse .unknown,
                // 当前配置下的值不是容器（`std.c.EVFILT` 在 linux 上为 void）
                else => return try inf.otherBranchMember(e, lhs_e, t, name) orelse .unknown,
            }
        }
        var tv = try inf.instanceMember(e, lhs, name);
        if (tv.ty == .unknown and inf.members[@backingInt(e)] == null and lhs.ty != .unknown) {
            if (try inf.otherBranchField(e, lhs_e, lhs.ty, name)) |x| tv = x;
        }
        // comptime 已知的值（结构体、union、元组、`len`）：取出字段的值
        if (tv.val == null and lhs.val != null) if (try eval.fieldValue(inf.r, lhs, name)) |fv| {
            return .{ .ty = if (tv.ty != .unknown) tv.ty else fv.ty, .val = fv.val };
        };
        if (tv.val == null and lhs.val == null) if (try inf.declInitFieldValue(lhs_e, name)) |fv| {
            return .{ .ty = if (tv.ty != .unknown) tv.ty else fv.ty, .val = fv.val };
        };
        return tv;
    }

    /// 左侧是初始化为结构体字面量的容器级常量、但整体的值求不出时（其他字段求不出）：取该字段的初始化
    /// 表达式的值。如 wasm 目标的 `builtin.cpu = .{ .arch = .wasm32, .features = featureSet(..) }` 中
    /// `featureSet` 求不出，`builtin.cpu.arch` 仍为 `.wasm32`
    fn declInitFieldValue(inf: *Inferrer, lhs_e: ExprId, name: []const u8) Error!?TypedValue {
        const owner: hir.OwnerKey = if (inf.members[@backingInt(lhs_e)]) |m| m else switch (inf.body.expr(lhs_e)) {
            .name_ref => |n| blk: {
                const def = try inf.r.resolveName(inf.file, inf.item, inf.body, inf.body.expr_scopes[@backingInt(lhs_e)], n) orelse return null;
                break :blk try defKey(inf.r, def) orelse return null;
            },
            else => return null,
        };
        const tree = try inf.r.itemTree(owner.file);
        const item = for (tree.items) |it| {
            if (it.ast_id == owner.item) break it;
        } else return null;
        if (item.kind != .@"const") return null;
        const body = try inf.r.ctx.get(hir.ItemBody, owner);
        const init = switch (body.expr(body.value orelse return null)) {
            .init => |x| x,
            else => return null,
        };
        const field = for (init.fields) |f| {
            if (f.name != null and std.mem.eql(u8, f.name.?, name)) break f;
        } else return null;
        const res = try inf.r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full });
        if (res.exprs.len != body.exprs.len) return null;
        const fv = res.exprs[@backingInt(field.value)];
        return if (fv.val != null) fv else null;
    }

    /// 带标签的 union 在类型上访问字段（`Value.null_val`）：值为该字段的标签，类型为 union 的标签类型，
    /// 可以转换为 union（与编译器一致）；引用的成员是 union 的字段
    fn unionTagMember(inf: *Inferrer, e: ExprId, t: Index, ns: Namespace, name: []const u8) Error!?TypedValue {
        const tree = try inf.r.itemTree(ns.file);
        if (tree.containers[ns.container].kind != .@"union") return null;
        const fi = fieldItem(tree, ns.container, name) orelse return null;
        const tag = try eval.unionTag(inf.r, t) orelse return null;
        inf.members[@backingInt(e)] = .{ .file = ns.file, .item = tree.items[fi].ast_id };
        return .{ .ty = tag, .val = try inf.ip.get(.{ .enum_tag = .{ .ty = tag, .name = name } }) };
    }

    /// 当前构建配置下不存在的成员，所在的命名空间由声明中的 `if` / `switch` 按目标选择（如 `posix.system`
    /// 在 linux 上为 `linux`，其他目标为 `std.c` 等）：到其他分支选择的容器中查找。这样的代码只在其他目标上
    /// 编译，给出那里的定义，而不是未知
    fn otherBranchMember(inf: *Inferrer, e: ExprId, lhs_e: ExprId, current: Index, name: []const u8) Error!?TypedValue {
        const ip = inf.ip;
        var cands: std.ArrayList(Index) = .empty;
        if (inf.members[@backingInt(lhs_e)]) |owner| {
            try alternativeContainers(inf.r, inf.scratch, owner, &cands, 0);
        } else try leafAlternatives(inf.r, inf.scratch, inf.file, inf.item, inf.body, inf.exprs, lhs_e, &cands, 0);
        for (cands.items) |t| {
            if (t == current) continue;
            const ns = try queries.namespaceOfType(inf.r, t) orelse continue;
            const def = try inf.r.memberDef(ns, name) orelse continue;
            inf.members[@backingInt(e)] = try defKey(inf.r, def);
            return try queries.defType(inf.r, def, null, queries.instOfType(ip, t));
        }
        return null;
    }

    /// 实例上当前构建配置下不存在的成员，实例的类型由按目标选择的命名空间给出（`state: platform.State`、
    /// `var state = platform.State.init()`，platform 按目标选择文件；`var t = try posix.tcgetattr(fd)`，返回类型
    /// `termios` 按目标选择）：到其他配置下的类型中查找字段与方法
    fn otherBranchField(inf: *Inferrer, e: ExprId, lhs_e: ExprId, lhs_ty: Index, name: []const u8) Error!?TypedValue {
        const ip = inf.ip;
        const current = switch (ip.key(lhs_ty)) {
            .ptr_type => |p| if (p.size == .one) p.child else lhs_ty,
            else => lhs_ty,
        };
        var cands: std.ArrayList(Index) = .empty;
        const here: ExprCtx = .{ .file = inf.file, .item = inf.item, .body = inf.body, .exprs = inf.exprs, .members = inf.members };
        try valueAlternatives(inf.r, inf.scratch, here, lhs_e, &cands, 0);
        for (cands.items) |t| {
            if (t == current) continue;
            const ns = try queries.namespaceOfType(inf.r, t) orelse continue;
            const tree = try inf.r.itemTree(ns.file);
            const def: resolve.Def = if (fieldItem(tree, ns.container, name)) |fi|
                .{ .item = .{ .file = ns.file, .item = fi } }
            else
                try inf.r.memberDef(ns, name) orelse continue;
            inf.members[@backingInt(e)] = try defKey(inf.r, def);
            return try queries.defType(inf.r, def, null, queries.instOfType(ip, t));
        }
        return null;
    }

    /// 实例（值）上的成员：字段与方法，自动解引用单指针
    fn instanceMember(inf: *Inferrer, e: ExprId, lhs: TypedValue, name: []const u8) Error!TypedValue {
        const ip = inf.ip;
        var t = lhs.ty;
        switch (ip.key(t)) {
            .ptr_type => |p| if (p.size == .one) {
                t = p.child;
            },
            else => {},
        }
        switch (ip.key(t)) {
            .container_type => {
                const ns = try queries.namespaceOfType(inf.r, t) orelse return .unknown;
                const tree = try inf.r.itemTree(ns.file);
                if (fieldItem(tree, ns.container, name)) |f| {
                    inf.members[@backingInt(e)] = .{ .file = ns.file, .item = tree.items[f].ast_id };
                    return .{ .ty = (try queries.defType(inf.r, .{ .item = .{ .file = ns.file, .item = f } }, null, queries.instOfType(ip, t))).ty };
                }
                // 方法
                const def = try inf.r.memberDef(ns, name) orelse return .unknown;
                inf.members[@backingInt(e)] = try defKey(inf.r, def);
                const tv = try queries.defType(inf.r, def, null, queries.instOfType(ip, t));
                if (ip.key(tv.ty) == .fn_type) try inf.bound.put(inf.scratch, e, {});
                return tv;
            },
            .array_type => |arr| if (std.mem.eql(u8, name, "len")) {
                return .{ .ty = .usize_type, .val = try ip.get(.{ .int_value = .{ .ty = .usize_type, .value = arr.len } }) };
            },
            .abstract_array_type => if (std.mem.eql(u8, name, "len")) {
                return .{ .ty = .usize_type };
            },
            .ptr_type => |p| if (p.size == .slice) {
                if (std.mem.eql(u8, name, "len")) return .{ .ty = .usize_type };
                if (std.mem.eql(u8, name, "ptr")) return .{ .ty = try ip.get(.{ .ptr_type = .{ .child = p.child, .size = .many, .is_const = p.is_const, .sentinel = p.sentinel } }) };
            },
            // 元组、匿名结构体、构造的结构体与 union
            .tuple_type, .anon_struct_type, .reified_type => {
                if (ip.key(t) == .tuple_type and std.mem.eql(u8, name, "len")) return .{ .ty = .usize_type, .val = try ip.get(.{ .int_value = .{ .ty = .usize_type, .value = ip.key(t).tuple_type.types.len } }) };
                const ty = try eval.fieldType(inf.r, t, name) orelse .unknown;
                // 字面量的 comptime 字段：值属于类型
                return .{ .ty = ty, .val = literalFieldValue(ip, t, name) };
            },
            else => {},
        }
        return .unknown;
    }

    /// decl literal：结果类型（去掉 error union、optional 与单项指针，与编译器一致）为容器时，`.name` 是该
    /// 类型的声明 `T.name`（枚举优先取同名成员）
    fn declLiteral(inf: *Inferrer, e: ExprId, want: Index, name: []const u8) Error!?TypedValue {
        const ip = inf.ip;
        var t = want;
        while (true) switch (ip.key(t)) {
            .error_union_type => |eu| t = eu.payload,
            .optional_type => |child| t = child,
            .ptr_type => |p| if (p.size == .one) {
                t = p.child;
            } else break,
            else => break,
        };
        const c = switch (ip.key(t)) {
            .container_type => |c| c,
            else => return null,
        };
        const ns = try queries.namespaceOfType(inf.r, t) orelse return null;
        if (c.kind == .@"enum") {
            const tree = try inf.r.itemTree(ns.file);
            if (fieldItem(tree, ns.container, name) != null) return null;
        }
        const tree = try inf.r.itemTree(ns.file);
        const m = Resolver.lookupDecl(tree, ns.container, name) orelse return null;
        const def: resolve.Def = .{ .item = .{ .file = ns.file, .item = m } };
        inf.members[@backingInt(e)] = try defKey(inf.r, def);
        return try queries.defType(inf.r, def, null, c.inst);
    }

    /// 标准库中按路径查找的类型（如 `builtin.Type`）
    fn stdType(inf: *Inferrer, path: []const []const u8) Error!?Index {
        var ns: Namespace = .{ .file = try inf.r.ctx.get(database.ModuleGraph.StdRoot, {}) orelse return null, .container = 0 };
        var t: Index = .unknown;
        for (path, 0..) |name, i| {
            const def = try inf.r.memberDef(ns, name) orelse return null;
            t = (try queries.defType(inf.r, def, null, null)).asType() orelse return null;
            if (i + 1 < path.len) ns = try queries.namespaceOfType(inf.r, t) orelse return null;
        }
        return t;
    }

    // ── 调用 ─────────────────────────────────────────────────────────

    fn call(inf: *Inferrer, callee_e: ExprId, args: []const ExprId, expected: ?Index) Error!TypedValue {
        // `.init(...)`：decl literal 在结果类型中查找
        const callee = try inf.infer(callee_e, if (inf.body.expr(callee_e) == .enum_literal) expected else null);
        const f = switch (inf.ip.key(callee.ty)) {
            .fn_type => |f| f,
            // 函数指针
            .ptr_type => |p| if (p.size == .one and inf.ip.key(p.child) == .fn_type) inf.ip.key(p.child).fn_type else {
                for (args) |a| _ = try inf.infer(a, null);
                return .unknown;
            },
            else => {
                for (args) |a| _ = try inf.infer(a, null);
                return .unknown;
            },
        };
        const skip: usize = if (inf.bound.contains(callee_e)) 1 else 0;
        const g = try genericCallee(inf.r, inf.scratch, callee, f) orelse {
            for (args, 0..) |a, i| _ = try inf.infer(a, paramType(f, i + skip));
            if (inf.comptime_depth > 0) if (try inf.comptimeCall(callee, callee_e, args, skip)) |tv| return tv;
            return .{ .ty = f.ret };
        };
        // 泛型调用：comptime 实参决定实例，先推导；抽象签名中依赖其他参数的参数类型不能作为期望类型。
        // anytype 实参只需要类型，不是 comptime 上下文
        for (args, 0..) |a, i| switch (g.kind(i + skip)) {
            .comptime_value => _ = try inf.inferComptime(a, inf.concrete(paramType(f, i + skip))),
            .comptime_anytype => _ = try inf.inferComptime(a, null),
            .anytype_type => _ = try inf.infer(a, null),
            .runtime => {},
        };
        const inst = try instanceOf(inf.r, inf.scratch, g, f, try inf.argValues(callee_e, args, skip, g.body.params.len));
        const sig = try inf.r.ctx.get(queries.Infer, .{ .owner = g.owner, .mode = .signature, .inst = inst });
        // 其余实参按实例中的参数类型推导
        for (args, 0..) |a, i| if (g.kind(i + skip) == .runtime) {
            _ = try inf.infer(a, instParamType(sig, g.body, i + skip) orelse inf.concrete(paramType(f, i + skip)));
        };
        const result = try inf.callResult(g, inst, sig, try inf.argValues(callee_e, args, skip, g.body.params.len));
        try inf.literalArgTargets(g, inst, args, skip);
        return result;
    }

    /// anytype 形参收到的枚举字面量（`testing.expectEqual(.x, actual)`）：被调函数的实例把参数转换为哪个类型，
    /// 字面量就引用其中的成员，并以它为期望类型（补全、构造类型的成员）
    fn literalArgTargets(inf: *Inferrer, g: Generic, inst: Index, args: []const ExprId, skip: usize) Error!void {
        var full: ?*const Result = null;
        for (args, 0..) |a, i| {
            switch (g.kind(i + skip)) {
                .anytype_type, .comptime_anytype => {},
                else => continue,
            }
            if (inf.body.expr(a) != .enum_literal or inf.members[@backingInt(a)] != null) continue;
            if (inf.get(a).ty != .enum_literal_type) continue;
            const res = full orelse try inf.r.ctx.get(queries.Infer, .{ .owner = g.owner, .mode = .full, .inst = inst });
            full = res;
            for (res.param_coercions) |pc| if (pc.param == i + skip) {
                try inf.literal_expected.append(inf.scratch, .{ .expr = a, .ty = pc.ty });
                try inf.recordTagMember(a, pc.ty);
                break;
            };
        }
    }

    /// 与形参一一对应的实参（方法调用的接收者在最前）
    fn argValues(inf: *Inferrer, callee_e: ExprId, args: []const ExprId, skip: usize, n: usize) Error![]const TypedValue {
        const out = try inf.scratch.alloc(TypedValue, n);
        for (out, 0..) |*o, i| {
            o.* = if (i < skip) switch (inf.body.expr(callee_e)) {
                .field_access => |fa| inf.get(fa.lhs),
                else => .unknown,
            } else if (i - skip < args.len) inf.get(args[i - skip]) else .unknown;
        }
        return out;
    }

    /// 实例化调用的结果：返回类型在实例中求值。返回 comptime-only 类型（如 `type`）或位于 comptime
    /// 上下文中时由解释器执行函数体求出值；解释器放弃时，返回 `type` 的函数取推导中实际执行到的 `return`
    fn callResult(inf: *Inferrer, g: Generic, inst: Index, sig: *const Result, args: []const TypedValue) Error!TypedValue {
        const ret = try queries.returnType(inf.r, g.owner, g.body, sig, inst);
        if ((try eval.isComptimeOnly(inf.r, ret) or inf.comptime_depth > 0) and !inf.r.ctx.incomplete()) {
            const tv = try eval.call(inf.r, inst, args, inf.branchQuota());
            if (tv.val != null and (ret == .unknown or tv.ty == ret)) return tv;
        }
        if (ret == .type_type) {
            const full = try inf.r.ctx.get(queries.Infer, .{ .owner = g.owner, .mode = .full, .inst = inst });
            return if (full.ret.ty == .type_type) full.ret else .{ .ty = .type_type };
        }
        return .{ .ty = ret };
    }

    /// comptime 上下文中调用非泛型函数（如数组长度中的 `double(4)`）：由解释器求值
    fn comptimeCall(inf: *Inferrer, callee: TypedValue, callee_e: ExprId, args: []const ExprId, skip: usize) Error!?TypedValue {
        const fv = switch (inf.ip.key(callee.val orelse return null)) {
            .fn_value => |v| v,
            else => return null,
        };
        const body = try inf.r.ctx.get(hir.ItemBody, .{ .file = fv.file, .item = fv.decl });
        const inst = try runtimeInstance(inf.ip, inf.scratch, fv, body.params.len);
        const tv = try eval.call(inf.r, inst, try inf.argValues(callee_e, args, skip, body.params.len), inf.branchQuota());
        return if (tv.val != null) tv else null;
    }

    /// 不含抽象参数与未知部分的类型（可以作为调用方的期望类型）
    fn concrete(inf: *Inferrer, t: ?Index) ?Index {
        const ty = t orelse return null;
        return if (value.isConcrete(inf.ip, ty)) ty else null;
    }

    /// switch 的操作数与分支项都 comptime 已知时，会执行的分支
    fn chooseProng(inf: *Inferrer, prongs: []const Body.Prong, operand: TypedValue) Error!?usize {
        const v = operand.val orelse return null;
        var else_prong: ?usize = null;
        for (prongs, 0..) |prong, i| {
            if (prong.is_else) {
                else_prong = i;
                continue;
            }
            for (prong.items) |item| {
                const iv = inf.get(item).val orelse return null;
                if (try eval.eqlValues(inf.r, iv, v) orelse return null) return i;
            }
        }
        return else_prong;
    }

    /// comptime 已知的比较
    fn compare(inf: *Inferrer, op: SyntaxKind, lhs: TypedValue, rhs: TypedValue) Error!?bool {
        const ip = inf.ip;
        const a = lhs.val orelse return null;
        const b = rhs.val orelse return null;
        if (value.intOf(ip, a)) |x| if (value.intOf(ip, b)) |y| return order(op, x, y);
        if (ip.key(a) == .float_value or ip.key(b) == .float_value) if (value.floatOf(ip, a)) |x| if (value.floatOf(ip, b)) |y| return order(op, x, y);
        if (op != .equal_equal and op != .bang_equal) return null;
        const eq = try eval.eqlValues(inf.r, a, b) orelse return null;
        return eq == (op == .equal_equal);
    }

    fn builtin(inf: *Inferrer, e: ExprId, name: []const u8, args: []const ExprId, expected: ?Index) Error!TypedValue {
        const ip = inf.ip;
        const eq = std.mem.eql;
        if (eq(u8, name, "@import")) {
            for (args) |a| _ = try inf.infer(a, null);
            const target = try inf.r.importTarget(inf.file, inf.body, args) orelse return .unknown;
            return TypedValue.ofType(try queries.containerType(inf.r, .{ .file = target, .container = 0 }, null));
        }
        if (eq(u8, name, "@This")) {
            const tree = try inf.r.itemTree(inf.file);
            return TypedValue.ofType(try queries.containerType(inf.r, .{ .file = inf.file, .container = tree.items[inf.item].container }, inf.inst));
        }
        if (eq(u8, name, "@embedFile")) {
            if (args.len != 1) return .unknown;
            const arg = try inf.infer(args[0], null);
            const path = try inf.stringArg(args[0]) orelse try eval.stringValue(inf.r, arg) orelse return .unknown;
            return try eval.embedFile(inf.r, inf.file, path) orelse .unknown;
        }
        // 模块名由构建系统决定（见 `std.builtin.SourceLocation.module`），项目模型中没有，只给出类型
        if (eq(u8, name, "@src")) return .{ .ty = try inf.stdType(&.{ "builtin", "SourceLocation" }) orelse .unknown };
        if (eq(u8, name, "@as")) {
            if (args.len != 2) return .unknown;
            const t = (try inf.infer(args[0], null)).asType() orelse .unknown;
            const v = try inf.infer(args[1], if (t != .unknown) t else null);
            return .{ .ty = t, .val = if (v.ty == t) v.val else null };
        }
        if (eq(u8, name, "@TypeOf")) {
            var types: std.ArrayList(Index) = .empty;
            for (args) |a| try types.append(inf.scratch, (try inf.infer(a, null)).ty);
            const t = try inf.peer(types.items);
            return if (t == .unknown) typeUnknown() else TypedValue.ofType(t);
        }
        if (eq(u8, name, "@Int")) {
            if (args.len != 2) return typeUnknown();
            const sign = switch (inf.body.expr(args[0])) {
                .enum_literal => |n| std.meta.stringToEnum(std.builtin.Signedness, n),
                else => null,
            };
            _ = try inf.infer(args[0], null);
            const bits = try inf.infer(args[1], .u8_type);
            const n: ?u16 = if (bits.val) |v| switch (ip.key(v)) {
                .int_value => |iv| std.math.cast(u16, iv.value),
                else => null,
            } else null;
            if (sign == null or n == null) return typeUnknown();
            return TypedValue.ofType(try ip.intType(sign.?, n.?));
        }
        // 构造类型的内置函数：由解释器求值（参数都是 comptime 已知的值）
        const reifying = [_][]const u8{ "@Pointer", "@Tuple", "@Enum", "@Struct", "@Union", "@Fn", "@Vector", "@EnumLiteral" };
        for (reifying) |n| if (eq(u8, name, n)) {
            for (args) |a| _ = try inf.infer(a, null);
            if (inf.dead > 0 or inf.r.ctx.incomplete()) return typeUnknown();
            const tv = try eval.exprValue(inf.r, inf.file, inf.item, inf.body, e, inf.inst, inf.bindings, null, inf.branchQuota());
            return if (tv.val != null) tv else typeUnknown();
        };
        if (eq(u8, name, "@sizeOf") or eq(u8, name, "@alignOf") or eq(u8, name, "@bitSizeOf")) {
            const t = (if (args.len == 1) (try inf.infer(args[0], null)).asType() else null) orelse return .{ .ty = .comptime_int_type };
            // 容器的布局读取字段类型的推导结果：当前结果已不完整时不再深入
            const l = value.typeLayout(ip, t) orelse (if (inf.dead > 0 or inf.r.ctx.incomplete()) null else try eval.typeLayout(inf.r, t)) orelse return .{ .ty = .comptime_int_type };
            const n = (if (eq(u8, name, "@sizeOf")) l.size else if (eq(u8, name, "@alignOf")) l.alignment else l.bits) orelse return .{ .ty = .comptime_int_type };
            return .{ .ty = .comptime_int_type, .val = try ip.get(.{ .int_value = .{ .ty = .comptime_int_type, .value = n } }) };
        }
        if (eq(u8, name, "@hasDecl") or eq(u8, name, "@hasField")) {
            for (args) |a| _ = try inf.infer(a, null);
            if (args.len != 2) return .{ .ty = .bool_type };
            const t = inf.get(args[0]).asType() orelse return .{ .ty = .bool_type };
            const member = try inf.stringArg(args[1]) orelse return .{ .ty = .bool_type };
            const has = try hasMember(inf.r, t, member, eq(u8, name, "@hasDecl")) orelse return .{ .ty = .bool_type };
            return boolValue(has);
        }
        if (eq(u8, name, "@intFromBool")) {
            for (args) |a| _ = try inf.infer(a, .bool_type);
            const b = if (args.len == 1) inf.condValue(inf.get(args[0])) else null;
            return .{ .ty = .u1_type, .val = if (b) |x| try ip.get(.{ .int_value = .{ .ty = .u1_type, .value = @intFromBool(x) } }) else null };
        }
        // 结果是标准库中定义的类型：只给出类型（不构造值）
        if (eq(u8, name, "@typeInfo")) {
            for (args) |x| _ = try inf.infer(x, null);
            const ty = (try inf.stdType(&.{ "builtin", "Type" })) orelse .unknown;
            const t = if (args.len == 1) inf.get(args[0]).asType() else null;
            const val: ?Index = if (t != null and value.isConcrete(ip, t.?)) try eval.typeInfo(inf.r, t.?) else null;
            return .{ .ty = ty, .val = val };
        }
        if (eq(u8, name, "@src")) return .{ .ty = (try inf.stdType(&.{ "builtin", "SourceLocation" })) orelse .unknown };
        if (eq(u8, name, "@FieldType")) {
            if (args.len != 2) return typeUnknown();
            const t = (try inf.infer(args[0], null)).asType() orelse return typeUnknown();
            _ = try inf.infer(args[1], null);
            const field = switch (inf.body.expr(args[1])) {
                .literal => |text| std.zig.string_literal.parseAlloc(inf.scratch, text) catch return typeUnknown(),
                else => return typeUnknown(),
            };
            const ns = try queries.namespaceOfType(inf.r, t) orelse return typeUnknown();
            const tree = try inf.r.itemTree(ns.file);
            const f = fieldItem(tree, ns.container, field) orelse return typeUnknown();
            const ft = (try queries.defType(inf.r, .{ .item = .{ .file = ns.file, .item = f } }, null, queries.instOfType(ip, t))).ty;
            return if (ft == .unknown) typeUnknown() else TypedValue.ofType(ft);
        }
        if (eq(u8, name, "@field")) {
            if (args.len != 2) return .unknown;
            // 字段名为字符串字面量或 comptime 已知的字符串
            const field_name = try inf.infer(args[1], null);
            return inf.fieldAccess(e, args[0], try inf.stringArg(args[1]) orelse try eval.stringValue(inf.r, field_name));
        }
        if (try inf.typedArgsBuiltin(name, args, expected)) |tv| return tv;
        // 嵌套的指针转换在编译器中合并为一次转换（`@ptrCast(@alignCast(p))`、`@alignCast(@fieldParentPtr(...))`）：
        // 内层取外层的结果类型
        if (isPtrCast(name) and args.len == 1) switch (inf.body.expr(args[0])) {
            .builtin_call => |inner| if (isPtrCast(inner.name) or eq(u8, inner.name, "@fieldParentPtr")) {
                _ = try inf.infer(args[0], inf.destType(expected, .eu));
            },
            else => {},
        };
        for (args) |a| _ = try inf.infer(a, null);
        // 转换：结果类型由期望类型决定（按编译器的 `resolveDestType` 去掉 error union / optional）
        const casts = [_]struct { []const u8, DestStrip }{
            .{ "@intCast", .eu_opt },      .{ "@truncate", .eu_opt },    .{ "@floatCast", .eu_opt }, .{ "@floatFromInt", .eu_opt },
            .{ "@intFromFloat", .eu_opt }, .{ "@enumFromInt", .eu_opt }, .{ "@bitCast", .eu_opt },   .{ "@ptrCast", .eu },
            .{ "@alignCast", .eu },        .{ "@addrSpaceCast", .eu },   .{ "@ptrFromInt", .eu },    .{ "@fieldParentPtr", .eu },
            .{ "@errorCast", .opt },
        };
        for (casts) |c| if (eq(u8, name, c[0])) {
            if (inf.destType(expected, c[1])) |t| return .{ .ty = t };
            // `@alignCast` / `@addrSpaceCast` 没有结果类型（在编译器中是错误）时取参数的类型
            if ((eq(u8, name, "@alignCast") or eq(u8, name, "@addrSpaceCast")) and args.len == 1) return .{ .ty = inf.get(args[0]).ty };
            return .unknown;
        };
        // 去掉 const / volatile：结果只取决于参数的类型（与编译器一致）
        if (eq(u8, name, "@constCast") or eq(u8, name, "@volatileCast")) {
            const t = if (args.len == 1) inf.get(args[0]).ty else .unknown;
            return .{ .ty = if (eq(u8, name, "@constCast")) try inf.mutablePtr(t) else t };
        }
        if (eq(u8, name, "@intFromEnum") or eq(u8, name, "@backingInt")) {
            if (try inf.pureValue(name, args)) |tv| return tv;
            const t = if (args.len == 1) inf.get(args[0]).ty else .unknown;
            if (t == .unknown) return .unknown;
            return .{ .ty = try eval.backingIntType(inf.r, t) orelse .unknown };
        }
        if (eq(u8, name, "@clz") or eq(u8, name, "@ctz") or eq(u8, name, "@popCount")) {
            if (try inf.pureValue(name, args)) |tv| return tv;
            return .{ .ty = (if (args.len == 1) try inf.bitCountType(inf.get(args[0]).ty) else null) orelse .unknown };
        }
        // `struct { T, u1 }`：T 为两侧的 peer（`@shlWithOverflow` 为左侧的类型），向量时溢出位也是向量
        if (eq(u8, name, "@addWithOverflow") or eq(u8, name, "@subWithOverflow") or eq(u8, name, "@mulWithOverflow") or eq(u8, name, "@shlWithOverflow")) {
            if (args.len != 2) return .unknown;
            if (try inf.pureValue(name, args)) |tv| return tv;
            const lhs = inf.get(args[0]).ty;
            const t = if (eq(u8, name, "@shlWithOverflow")) lhs else try inf.peer(&.{ lhs, inf.get(args[1]).ty });
            if (t == .unknown) return .unknown;
            const bit: Index = switch (ip.key(t)) {
                .vector_type => |v| try ip.get(.{ .vector_type = .{ .len = v.len, .child = .u1_type } }),
                else => .u1_type,
            };
            return .{ .ty = try ip.get(.{ .tuple_type = .{ .types = &.{ t, bit } } }) };
        }
        // `@Vector(n, T)`：n 为 `pred` / `mask` 的长度
        if (eq(u8, name, "@select") or eq(u8, name, "@shuffle")) {
            if (args.len != 4) return .unknown;
            const t = inf.get(args[0]).asType() orelse return .unknown;
            const n: ?u64 = switch (ip.key(inf.get(if (eq(u8, name, "@select")) args[1] else args[3]).ty)) {
                .vector_type => |v| v.len,
                .array_type => |a| a.len,
                else => null,
            };
            const len = std.math.cast(u32, n orelse return .unknown) orelse return .unknown;
            return .{ .ty = try ip.get(.{ .vector_type = .{ .len = len, .child = t } }) };
        }
        // 错误的整数值：位宽取决于错误数量的上限（编译器默认为 u16）
        if (eq(u8, name, "@intFromError")) return .{ .ty = try ip.intType(.unsigned, 16) };
        if (eq(u8, name, "@errorReturnTrace")) {
            const trace = try inf.stdType(&.{ "builtin", "StackTrace" }) orelse return .unknown;
            return .{ .ty = try ip.optionalOf(try ip.ptrTo(trace, .one, false)) };
        }
        if (eq(u8, name, "@offsetOf") or eq(u8, name, "@bitOffsetOf")) {
            const t = if (args.len == 2) inf.get(args[0]).asType() else null;
            const field = if (args.len == 2) try inf.stringArg(args[1]) else null;
            if (t == null or field == null or inf.dead > 0 or inf.r.ctx.incomplete()) return .{ .ty = .comptime_int_type };
            const bits = try eval.bitOffsetOf(inf.r, t.?, field.?) orelse return .{ .ty = .comptime_int_type };
            const n = if (eq(u8, name, "@offsetOf")) bits / 8 else bits;
            return .{ .ty = .comptime_int_type, .val = try ip.get(.{ .int_value = .{ .ty = .comptime_int_type, .value = n } }) };
        }
        const simple = [_]struct { []const u8, Index }{
            .{ "@intFromPtr", .usize_type },
            .{ "@inComptime", .bool_type },
            .{ "@panic", .noreturn_type },
            .{ "@compileError", .noreturn_type },
            .{ "@trap", .noreturn_type },
            .{ "@memcpy", .void_type },
            .{ "@memmove", .void_type },
            .{ "@setRuntimeSafety", .void_type },
            .{ "@breakpoint", .void_type },
            .{ "@compileLog", .void_type },
            .{ "@disableInstrumentation", .void_type },
            .{ "@disableIntrinsics", .void_type },
            .{ "@returnAddress", .usize_type },
            .{ "@frameAddress", .usize_type },
            .{ "@errorFromInt", .anyerror_type },
        };
        for (simple) |s| if (eq(u8, name, s[0])) return .{ .ty = s[1] };
        if (eq(u8, name, "@tagName") or eq(u8, name, "@errorName") or eq(u8, name, "@typeName")) {
            if (args.len == 1) if (try inf.pureValue(name, args)) |tv| return tv;
            // `@typeName` 的参数总是类型：名字求不出时没有运行时切片形式
            if (eq(u8, name, "@typeName")) return .unknown;
            const sentinel = try ip.get(.{ .int_value = .{ .ty = .u8_type, .value = 0 } });
            return .{ .ty = try ip.get(.{ .ptr_type = .{ .child = .u8_type, .size = .slice, .is_const = true, .sentinel = sentinel } }) };
        }
        // 结果与第一个参数同类型（除法与取余为两侧的 peer）
        const same = [_][]const u8{ "@abs", "@sqrt", "@sin", "@cos", "@tan", "@exp", "@exp2", "@log", "@log2", "@log10", "@floor", "@ceil", "@trunc", "@round", "@byteSwap", "@bitReverse", "@min", "@max", "@mod", "@rem", "@divExact", "@divFloor", "@divTrunc", "@divCeil" };
        for (same) |n| if (eq(u8, name, n)) {
            if (args.len == 0) return .unknown;
            if (try inf.pureValue(name, args)) |tv| return tv;
            var types: std.ArrayList(Index) = .empty;
            for (args) |a| try types.append(inf.scratch, inf.get(a).ty);
            if (eq(u8, name, "@min") or eq(u8, name, "@max")) {
                // 与编译器一致：有浮点参数时取位宽最大的浮点类型，整数取容纳结果范围的最小整数类型
                for (types.items) |t| if (ip.isFloat(t)) return .{ .ty = value.minMaxFloatType(ip, types.items) orelse try inf.peer(types.items) };
                const operands = try inf.scratch.alloc(TypedValue, args.len);
                for (args, operands) |a, *o| o.* = inf.get(a);
                return .{ .ty = try value.minMaxIntType(ip, eq(u8, name, "@min"), operands) orelse try inf.peer(types.items) };
            }
            // 有符号整数的绝对值为同位宽的无符号整数
            if (eq(u8, name, "@abs")) if (value.intInfo(ip, types.items[0])) |info| if (info.signed) return .{ .ty = try ip.intType(.unsigned, info.bits) };
            // 除法与取余：两侧的 peer
            if (args.len == 2) return .{ .ty = try inf.peer(types.items) };
            return .{ .ty = types.items[0] };
        };
        return .unknown;
    }

    /// 参数有结果类型的内置函数（与编译器一致）：参数按各自的结果类型推导；不是这些内置函数时为 null
    fn typedArgsBuiltin(inf: *Inferrer, name: []const u8, args: []const ExprId, expected: ?Index) Error!?TypedValue {
        const ip = inf.ip;
        const eq = std.mem.eql;
        if (eq(u8, name, "@splat")) {
            const dest = inf.destType(expected, .eu_opt);
            const elem: ?Index = if (dest) |d| switch (ip.key(d)) {
                .vector_type => |v| v.child,
                .array_type => |a| a.child,
                .abstract_array_type => |a| a.child,
                else => null,
            } else null;
            for (args) |a| _ = try inf.infer(a, elem);
            return .{ .ty = dest orelse .unknown };
        }
        // 参数的结果类型为目标类型的 backing 整数
        if (eq(u8, name, "@fromBackingInt")) {
            const dest = inf.destType(expected, .eu_opt);
            const int_ty: ?Index = if (dest) |d| try eval.backingIntType(inf.r, d) else null;
            for (args) |a| _ = try inf.infer(a, int_ty);
            return .{ .ty = dest orelse .unknown };
        }
        // 右侧为 `Log2Int(T)`
        if (eq(u8, name, "@shlExact") or eq(u8, name, "@shrExact")) {
            const lhs: TypedValue = if (args.len > 0) try inf.infer(args[0], null) else .unknown;
            for (args[@min(args.len, 1)..]) |a| _ = try inf.infer(a, try inf.log2IntType(lhs.ty));
            return try inf.pureValue(name, args) orelse .{ .ty = lhs.ty };
        }
        // 初始化值的结果类型为字段的类型
        if (eq(u8, name, "@unionInit")) {
            if (args.len != 3) return null;
            const t = (try inf.infer(args[0], null)).asType();
            const field_name = try inf.infer(args[1], null);
            const field = try inf.stringArg(args[1]) orelse try eval.stringValue(inf.r, field_name);
            const field_ty: ?Index = if (t != null and field != null) try inf.unionFieldType(t.?, field.?) else null;
            _ = try inf.infer(args[2], field_ty);
            return .{ .ty = t orelse .unknown };
        }
        // 填充值的结果类型为元素类型
        if (eq(u8, name, "@memset")) {
            const dest: TypedValue = if (args.len > 0) try inf.infer(args[0], null) else .unknown;
            const elem = inf.elementType(dest.ty);
            for (args[@min(args.len, 1)..]) |a| _ = try inf.infer(a, if (elem != .unknown) elem else null);
            return .{ .ty = .void_type };
        }
        // 各参数的结果类型；`elem` 为第一个参数给出的类型
        const ArgType = enum { none, elem, u32, atomic_order, atomic_rmw_op, reduce_op, call_modifier, branch_hint, float_mode, prefetch_options, export_options, extern_options };
        const signatures = [_]struct { []const u8, []const ArgType }{
            .{ "@atomicLoad", &.{ .none, .none, .atomic_order } },
            .{ "@atomicStore", &.{ .none, .none, .elem, .atomic_order } },
            .{ "@atomicRmw", &.{ .none, .none, .atomic_rmw_op, .elem, .atomic_order } },
            .{ "@cmpxchgStrong", &.{ .none, .none, .elem, .elem, .atomic_order, .atomic_order } },
            .{ "@cmpxchgWeak", &.{ .none, .none, .elem, .elem, .atomic_order, .atomic_order } },
            .{ "@mulAdd", &.{ .none, .elem, .elem, .elem } },
            .{ "@reduce", &.{ .reduce_op, .none } },
            .{ "@call", &.{ .call_modifier, .none, .none } },
            .{ "@branchHint", &.{.branch_hint} },
            .{ "@setFloatMode", &.{.float_mode} },
            .{ "@setEvalBranchQuota", &.{.u32} },
            .{ "@prefetch", &.{ .none, .prefetch_options } },
            .{ "@export", &.{ .none, .export_options } },
            .{ "@extern", &.{ .none, .extern_options } },
        };
        const sig = for (signatures) |x| {
            if (eq(u8, name, x[0])) break x[1];
        } else return null;
        var elem: Index = .unknown;
        for (args, 0..) |a, i| {
            const want: ?Index = switch (if (i < sig.len) sig[i] else .none) {
                .none => null,
                .elem => if (elem != .unknown) elem else null,
                .u32 => try ip.intType(.unsigned, 32),
                .atomic_order => try inf.stdType(&.{ "builtin", "AtomicOrder" }),
                .atomic_rmw_op => try inf.stdType(&.{ "builtin", "AtomicRmwOp" }),
                .reduce_op => try inf.stdType(&.{ "builtin", "ReduceOp" }),
                .call_modifier => try inf.stdType(&.{ "builtin", "CallModifier" }),
                .branch_hint => try inf.stdType(&.{ "builtin", "BranchHint" }),
                .float_mode => try inf.stdType(&.{ "builtin", "FloatMode" }),
                .prefetch_options => try inf.stdType(&.{ "builtin", "PrefetchOptions" }),
                .export_options => try inf.stdType(&.{ "builtin", "ExportOptions" }),
                .extern_options => try inf.stdType(&.{ "builtin", "ExternOptions" }),
            };
            const tv = try inf.infer(a, want);
            if (i == 0) elem = tv.asType() orelse .unknown;
        }
        if (eq(u8, name, "@atomicLoad") or eq(u8, name, "@atomicRmw") or eq(u8, name, "@extern")) return .{ .ty = elem };
        if (eq(u8, name, "@cmpxchgStrong") or eq(u8, name, "@cmpxchgWeak")) return .{ .ty = try ip.optionalOf(elem) };
        if (eq(u8, name, "@mulAdd")) return try inf.pureValue(name, args) orelse .{ .ty = elem };
        if (eq(u8, name, "@reduce")) return .{ .ty = if (args.len == 2) inf.elementType(inf.get(args[1]).ty) else .unknown };
        if (eq(u8, name, "@call")) return .{ .ty = if (args.len == 3) inf.fnReturnType(inf.get(args[1]).ty) else .unknown };
        return .{ .ty = .void_type };
    }

    const DestStrip = enum { eu_opt, eu, opt };

    /// 转换类内置函数的目标类型：期望类型按编译器的 `resolveDestType` 去掉 error union / optional
    fn destType(inf: *Inferrer, expected: ?Index, strip: DestStrip) ?Index {
        const ip = inf.ip;
        var t = expected orelse return null;
        if (t == .unknown) return null;
        if (strip != .opt) switch (ip.key(t)) {
            .error_union_type => |eu| t = eu.payload,
            else => {},
        };
        if (strip != .eu) switch (ip.key(t)) {
            .optional_type => |c| t = c,
            else => {},
        };
        return t;
    }

    /// 去掉指针（含 optional 指针）的 const
    fn mutablePtr(inf: *Inferrer, t: Index) Error!Index {
        const ip = inf.ip;
        switch (ip.key(t)) {
            .ptr_type => |p| {
                var q = p;
                q.is_const = false;
                return ip.get(.{ .ptr_type = q });
            },
            .optional_type => |c| if (ip.key(c) == .ptr_type) return ip.optionalOf(try inf.mutablePtr(c)),
            else => {},
        }
        return t;
    }

    /// `@clz` / `@ctz` / `@popCount` 的结果类型：能容纳 0 到位宽的最小无符号整数，向量逐元素
    fn bitCountType(inf: *Inferrer, t: Index) Error!?Index {
        const ip = inf.ip;
        switch (ip.key(t)) {
            .vector_type => |v| {
                const child = try inf.bitCountType(v.child) orelse return null;
                return try ip.get(.{ .vector_type = .{ .len = v.len, .child = child } });
            },
            else => {},
        }
        const info = value.intInfo(ip, t) orelse return null;
        return try ip.intType(.unsigned, if (info.bits == 0) 0 else std.math.log2_int(u16, info.bits) + 1);
    }

    /// 函数（或函数指针）的返回类型；依赖参数时为 unknown
    fn fnReturnType(inf: *Inferrer, t: Index) Index {
        const ip = inf.ip;
        const f = switch (ip.key(t)) {
            .fn_type => |f| f,
            .ptr_type => |p| if (p.size == .one and ip.key(p.child) == .fn_type) ip.key(p.child).fn_type else return .unknown,
            else => return .unknown,
        };
        return inf.concrete(f.ret) orelse .unknown;
    }

    /// 参数都已知时只做计算的内置函数（数学函数、布局）的值，由解释器计算
    fn pureValue(inf: *Inferrer, name: []const u8, args: []const ExprId) Error!?TypedValue {
        if (inf.dead > 0 or inf.r.ctx.incomplete()) return null;
        const tvs = try inf.scratch.alloc(TypedValue, args.len);
        for (args, tvs) |a, *o| {
            o.* = inf.get(a);
            if (o.val == null) return null;
        }
        return eval.builtinValue(inf.r, name, tvs);
    }

    /// 字符串字面量实参的内容
    fn stringArg(inf: *Inferrer, e: ExprId) Error!?[]const u8 {
        return switch (inf.body.expr(e)) {
            .literal => |text| if (text.len > 0 and text[0] == '"') std.zig.string_literal.parseAlloc(inf.scratch, text) catch null else null,
            else => null,
        };
    }

    // ── 块与控制流 ───────────────────────────────────────────────────

    fn block(inf: *Inferrer, blk: Body.Block, expected: ?Index) Error!TypedValue {
        try inf.labels.append(inf.scratch, .{ .name = blk.label, .is_loop = false, .expected = expected });
        var last: Index = .void_type;
        var dead_rest = false;
        for (blk.stmts, 0..) |s, si| {
            last = try inf.stmt(s);
            if (last == .noreturn_type and !dead_rest) {
                dead_rest = true;
                if (inf.dead == 0 and si + 1 < blk.stmts.len) try inf.dead_spans.append(inf.scratch, .{ .start = s.end, .end = blk.stmts[blk.stmts.len - 1].end });
                inf.dead += 1;
            }
        }
        if (dead_rest) inf.dead -= 1;
        var frame = inf.labels.pop().?;
        if (blk.label != null) {
            // 执行到块尾时值为 void
            if (last != .noreturn_type and inf.dead == 0) {
                try frame.types.append(inf.scratch, .void_type);
                try frame.values.append(inf.scratch, .{ .ty = .void_type, .val = .void_value });
            }
            const t = try inf.peer(frame.types.items);
            return .{ .ty = t, .val = sameValue(frame.values.items, t) };
        }
        return .{ .ty = if (last == .noreturn_type) .noreturn_type else .void_type };
    }

    fn stmt(inf: *Inferrer, s: Body.Stmt) Error!Index {
        switch (s.kind) {
            .expr => |e| return (try inf.infer(e, null)).ty,
            .local => |b| {
                const binding = inf.body.binding(b);
                const annotation: ?Index = if (binding.ty) |t| (try inf.inferComptime(t, null)).asType() orelse .unknown else null;
                const init: TypedValue = if (binding.init) |i| try inf.infer(i, annotation) else .unknown;
                inf.bindings[@backingInt(b)] = if (annotation) |t|
                    .{ .ty = t, .val = if (binding.kind == .local_const and init.ty == t) init.val else null }
                else if (binding.kind == .local_const)
                    init
                else
                    .{ .ty = init.ty };
                return .void_type;
            },
            .@"defer" => |e| {
                _ = try inf.infer(e, null);
                return .void_type;
            },
            .@"errdefer" => |d| {
                if (d.capture) |c| inf.bindings[@backingInt(c)] = .{ .ty = .anyerror_type };
                _ = try inf.infer(d.body, null);
                return .void_type;
            },
            .destructure => |d| {
                const v = try inf.infer(d.value, null);
                for (d.targets, 0..) |t, i| switch (t) {
                    .binding => |b| {
                        const binding = inf.body.binding(b);
                        const elem = try inf.destructureElem(v, i);
                        inf.bindings[@backingInt(b)] = if (binding.ty) |ty| blk: {
                            const annotation = (try inf.infer(ty, null)).asType() orelse .unknown;
                            break :blk .{ .ty = annotation, .val = if (binding.kind == .local_const and elem.ty == annotation) elem.val else null };
                        } else if (binding.kind == .local_const) elem else .{ .ty = elem.ty };
                    },
                    .expr => |x| _ = try inf.infer(x, null),
                };
                return .void_type;
            },
        }
    }

    /// 解构 `const a, const b = x;` 的第 `i` 个元素：元组的字段、数组与向量的元素
    fn destructureElem(inf: *Inferrer, v: TypedValue, i: usize) Error!TypedValue {
        const ip = inf.ip;
        const ty: Index = switch (ip.key(v.ty)) {
            .tuple_type => |tt| if (i < tt.types.len) tt.types[i] else return .unknown,
            .array_type => |a| a.child,
            .vector_type => |vt| vt.child,
            else => return .unknown,
        };
        if (v.val != null) if (try eval.elemValue(inf.r, v, i)) |ev| return .{ .ty = ty, .val = ev.val };
        // 元组的 comptime 字段：值属于类型
        const x: Index = switch (ip.key(v.ty)) {
            .tuple_type => |tt| InternPool.fieldValue(tt.values, i),
            else => .runtime,
        };
        return .{ .ty = ty, .val = if (x == .runtime or x == .unknown) null else x };
    }

    fn loop(inf: *Inferrer, l: Body.Loop, expected: ?Index) Error!TypedValue {
        const ip = inf.ip;
        switch (l.kind) {
            .@"while" => {
                const cond = try inf.infer(l.inputs[0], null);
                try inf.bindCaptures(l.capture, l.inputs[0], cond, .if_then);
                try inf.bindCaptures(l.else_capture, l.inputs[0], cond, .if_else);
            },
            .@"for" => {
                // 按某次迭代推导这个循环（见 `LoopSeed`）：各个循环变量都取这次迭代的值
                const iteration: ?u32 = if (inf.loop_seed) |seed|
                    (if (std.mem.indexOfScalar(Body.BindingId, l.capture, @fromBackingInt(seed.binding)) != null) seed.index else null)
                else
                    null;
                for (l.inputs, 0..) |input, i| {
                    var list: TypedValue = .unknown;
                    var start: TypedValue = .unknown;
                    const elem: Index = switch (inf.body.expr(input)) {
                        // `a..b` / `0..`
                        .other => |range| blk: {
                            for (range) |x| _ = try inf.infer(x, .usize_type);
                            if (range.len > 0) start = inf.get(range[0]);
                            break :blk .usize_type;
                        },
                        else => blk: {
                            list = try inf.infer(input, null);
                            break :blk inf.forElement(list.ty);
                        },
                    };
                    if (i < l.capture.len) {
                        const cap = l.capture[i];
                        const ptr = inf.body.binding(cap).is_ptr;
                        const is_const = if (ptr) try inf.forCaptureConst(input, list.ty) else false;
                        const ty = if (ptr) try ip.ptrTo(elem, .one, is_const) else elem;
                        inf.bindings[@backingInt(cap)] = if (elem == .type_type and !ptr)
                            try inf.typeCapture(cap, list, iteration)
                        else if (iteration) |n| blk: {
                            const it_ty = try inf.iterationType(list.ty, elem, n, ptr, is_const);
                            const v = try inf.iterationValue(list, start, n);
                            // 指针捕获取指向这次迭代的元素的指针；可变列表的元素在运行时会变，不取值
                            const val = if (!ptr) v else if (is_const) (if (v) |x| try ip.get(.{ .ptr_value = .{ .ty = it_ty, .pointee = x } }) else null) else null;
                            break :blk .{ .ty = it_ty, .val = val };
                        } else .{ .ty = ty };
                    }
                }
            },
        }
        if (l.cont) |c| _ = try inf.infer(c, null);
        // break 的值与 else 分支取循环的结果类型
        try inf.labels.append(inf.scratch, .{ .name = l.label, .is_loop = true, .expected = expected });
        _ = try inf.infer(l.body, null);
        var frame = inf.labels.pop().?;
        const other: Index = if (l.@"else") |el| (try inf.infer(el, expected)).ty else .void_type;
        try frame.types.append(inf.scratch, other);
        return .{ .ty = try inf.peer(frame.types.items) };
    }

    /// 元素为类型的循环变量（`inline for (.{ f32, f64 }) |T|`）：每次迭代的类型不同，与泛型函数的
    /// `comptime T: type` 一样按抽象参数推导。按某次迭代推导时（`loop_seed`）取列表中的该元素
    fn typeCapture(inf: *Inferrer, cap: Body.BindingId, list: TypedValue, iteration: ?u32) Error!TypedValue {
        if (iteration) |n| if (list.val != null) {
            if (try eval.elemValue(inf.r, list, n)) |ev| if (ev.val) |t| return TypedValue.ofType(t);
        };
        return TypedValue.ofType(try inf.ip.get(.{ .opaque_param = .{ .file = inf.file, .owner = try inf.body_owner(), .binding = @backingInt(cap), .name = inf.body.binding(cap).name } }));
    }

    /// `for` 的指针捕获是否为 const：遍历指针（切片、多项指针、指向数组的指针）时取指针本身的
    /// `is_const`；遍历数组值时取决于被遍历的值是否为 const place
    fn forCaptureConst(inf: *Inferrer, input: ExprId, list: Index) Error!bool {
        return switch (inf.ip.key(list)) {
            .ptr_type => |p| p.is_const,
            .array_type, .vector_type, .tuple_type => inf.isConstPlace(input),
            else => false,
        };
    }

    /// 按第 `n` 次迭代推导时非类型的循环变量的类型：各项类型不同的元组（`.{ &posix, &windows }`）取第 `n` 项的类型
    fn iterationType(inf: *Inferrer, list: Index, elem: Index, n: u32, ptr: bool, is_const: bool) Error!Index {
        var t = elem;
        if (t == .unknown) if (tupleOf(inf.ip, list)) |tt| if (n < tt.types.len) {
            t = tt.types[n];
        };
        return if (ptr) inf.ip.ptrTo(t, .one, is_const) else t;
    }

    /// 按第 `n` 次迭代推导时非类型的循环变量的值：范围（`start..`）为 `start + n`，列表为第 `n` 个元素
    fn iterationValue(inf: *Inferrer, list: TypedValue, start: TypedValue, n: u32) Error!?Index {
        if (value.intOf(inf.ip, start.val)) |s| return try inf.ip.get(.{ .int_value = .{ .ty = .usize_type, .value = s + n } });
        if (list.val == null) return null;
        return if (try eval.elemValue(inf.r, list, n)) |ev| ev.val else null;
    }

    /// `continue :label` 的目标为 labeled switch 时其操作数的类型
    fn switchOperandType(inf: *Inferrer, e: ExprId, label: []const u8) ?Index {
        const b = inf.body;
        var s: ?Body.ScopeId = b.expr_scopes[@backingInt(e)];
        while (s) |id| : (s = b.scope(id).parent) {
            const l = b.scope(id).label orelse continue;
            if (!std.mem.eql(u8, l.name, label)) continue;
            const sw = switch (b.expr(l.expr)) {
                .@"switch" => |sw| sw,
                else => return null,
            };
            const t = inf.get(sw.operand).ty;
            return if (t != .unknown) t else null;
        }
        return null;
    }

    /// `catch` / `orelse` 右侧的期望类型。编译器取整个表达式的结果类型；没有结果类型时两侧做 peer type
    /// resolution，这里以载荷类型作为右侧字面量（`0`、`.red`）的期望，得到与 peer 相同的结果。`null` 例外：
    /// 与载荷 peer 得到 optional（`parseInt(u8, s, 10) catch null` 为 `?u8`），不能转换为载荷类型
    fn fallbackType(inf: *Inferrer, expected: ?Index, payload: Index, rhs: ExprId) ?Index {
        if (expected) |want| if (want != .unknown) return want;
        if (payload == .unknown) return null;
        switch (inf.body.expr(rhs)) {
            .name_ref => |name| if (std.mem.eql(u8, name, "null")) return null,
            else => {},
        }
        return payload;
    }

    /// 函数体中有 `continue :label`（带标签的 switch 由它转到其他分支）
    fn continuesTo(inf: *Inferrer, label: []const u8) bool {
        for (inf.body.exprs) |x| switch (x) {
            .@"continue" => |c| if (c.label) |l| if (std.mem.eql(u8, l, label)) return true,
            else => {},
        };
        return false;
    }

    /// switch 的标签：lowering 在推导操作数之前推入了以这个 switch 为目标的带标签作用域
    fn switchLabel(inf: *Inferrer, e: ExprId, operand: ExprId) ?[]const u8 {
        const b = inf.body;
        var s: ?Body.ScopeId = b.expr_scopes[@backingInt(operand)];
        while (s) |id| : (s = b.scope(id).parent) {
            const l = b.scope(id).label orelse continue;
            if (l.expr == e) return l.name;
        }
        return null;
    }

    /// break 的目标（`labels` 中的下标）
    fn labelFrame(inf: *Inferrer, label: ?[]const u8) ?usize {
        var i = inf.labels.items.len;
        while (i > 0) {
            i -= 1;
            const f = inf.labels.items[i];
            if (label) |name| {
                if (f.name != null and std.mem.eql(u8, f.name.?, name)) return i;
            } else if (f.is_loop) return i;
        }
        return null;
    }

    const CaptureSource = enum { if_then, if_else };

    /// if / while 的捕获：optional 取子类型，error union 取载荷（else 分支取错误集）
    fn bindCaptures(inf: *Inferrer, caps: []const Body.BindingId, cond_e: ExprId, cond_tv: TypedValue, source: CaptureSource) Error!void {
        if (caps.len == 0) return;
        const ip = inf.ip;
        const cond = cond_tv.ty;
        const t: Index = switch (ip.key(cond)) {
            .optional_type => |c| if (source == .if_then) c else .unknown,
            .error_union_type => |eu| if (source == .if_then) eu.payload else eu.err,
            else => .unknown,
        };
        const cap = caps[0];
        const is_ptr = inf.body.binding(cap).is_ptr;
        // 已知的非 null optional 值即载荷值
        const val: ?Index = if (!is_ptr and source == .if_then and ip.key(cond) == .optional_type and inf.condValue(cond_tv) == true) cond_tv.val else null;
        inf.bindings[@backingInt(cap)] = .{ .ty = if (is_ptr) try ip.ptrTo(t, .one, try inf.isConstPlace(cond_e)) else t, .val = val };
    }

    /// switch 的捕获。带标签的 union：捕获为各分支项对应字段类型的 peer（与编译器一致），`else` 分支与
    /// 求不出的分支项为 unknown；第二个捕获为标签。`chosen`：操作数 comptime 已知，这是执行的分支，捕获取
    /// 实际的载荷值；各项的载荷类型没有 peer 时只能是 `inline` 分支（每项单独实例化，如
    /// `inline .@"struct", .@"union" => |info|`），类型也取实际的载荷类型
    fn bindSwitchCapture(inf: *Inferrer, prong: Body.Prong, prongs: []const Body.Prong, operand_e: ExprId, operand_tv: TypedValue, chosen: bool) Error!void {
        if (prong.capture.len == 0) return;
        const ip = inf.ip;
        const operand = operand_tv.ty;
        const is_union = switch (ip.key(operand)) {
            .container_type => |c| c.kind == .@"union",
            .reified_type => |rt| rt.kind == .@"union",
            else => false,
        };
        const is_error_set = switch (ip.key(operand)) {
            .error_set_type, .inferred_error_set => true,
            else => false,
        };
        var t: Index = if (is_union)
            try inf.prongPayloadType(prong, operand)
        else if (is_error_set)
            try inf.errorSetProngType(prong, prongs, try queries.errorSetMembers(inf.r, operand))
        else
            operand;
        var val: ?Index = null;
        if (chosen and is_union) if (operand_tv.val) |v| switch (ip.key(v)) {
            .union_value => |u| if (try inf.unionFieldType(operand, u.tag)) |pt| {
                if (t == .unknown) t = pt;
                if (t == pt) val = u.payload;
            },
            else => {},
        };
        if (chosen and is_error_set) if (operand_tv.val) |v| switch (ip.key(v)) {
            .error_value => val = v,
            else => {},
        };
        const cap = prong.capture[0];
        const is_ptr = inf.body.binding(cap).is_ptr;
        // 按 inline 分支的某个取值推导（见 `LoopSeed`）：捕获取这个分支项的值
        if (prong.is_inline and !is_union and !is_error_set and !is_ptr) if (inf.loop_seed) |seed| if (seed.binding == @backingInt(cap)) {
            if ((try inlineProngValues(ip, inf.body, inf.exprs, prong, operand, seed.index)).value) |v| val = v;
        };
        inf.bindings[@backingInt(cap)] = .{ .ty = if (is_ptr) try ip.ptrTo(t, .one, try inf.isConstPlace(operand_e)) else t, .val = if (is_ptr) null else val };
        if (prong.capture.len > 1) {
            const tag: Index = if (is_union) try eval.unionTag(inf.r, operand) orelse .unknown else .unknown;
            inf.bindings[@backingInt(prong.capture[1])] = .{ .ty = tag };
        }
    }

    /// 错误集 switch 分支捕获的类型：普通分支为分支项中的错误组成的集合，`else` 为操作数成员去掉
    /// 其他分支列出的错误；成员求不出（`anyerror`）时为 unknown
    fn errorSetProngType(inf: *Inferrer, prong: Body.Prong, prongs: []const Body.Prong, members: ?[]const []const u8) Error!Index {
        const all = members orelse return .unknown;
        var names: std.ArrayList([]const u8) = .empty;
        if (prong.is_else) {
            for (all) |m| {
                var listed = false;
                for (prongs) |p| {
                    if (p.is_else) continue;
                    for (p.items) |item| if (try inf.errorItemName(item)) |n| {
                        if (std.mem.eql(u8, n, m)) {
                            listed = true;
                            break;
                        }
                    };
                    if (listed) break;
                }
                if (!listed) try names.append(inf.scratch, m);
            }
        } else {
            for (prong.items) |item| if (try inf.errorItemName(item)) |n| try names.append(inf.scratch, n);
            if (names.items.len == 0) return .unknown;
        }
        return inf.ip.errorSet(inf.scratch, names.items);
    }

    fn errorItemName(inf: *Inferrer, item: ExprId) Error!?[]const u8 {
        return switch (inf.body.expr(item)) {
            .error_value => |n| n,
            else => switch (inf.ip.key(inf.get(item).val orelse return null)) {
                .error_value => |n| n,
                else => null,
            },
        };
    }

    fn prongPayloadType(inf: *Inferrer, prong: Body.Prong, operand: Index) Error!Index {
        if (prong.is_else or prong.items.len == 0) return .unknown;
        const types = try inf.scratch.alloc(Index, prong.items.len);
        for (prong.items, types) |item, *t| {
            const name = switch (inf.body.expr(item)) {
                .enum_literal => |n| n,
                else => switch (inf.ip.key(inf.get(item).val orelse return .unknown)) {
                    .enum_tag => |tag| tag.name,
                    else => return .unknown,
                },
            };
            t.* = try inf.unionFieldType(operand, name) orelse return .unknown;
        }
        return inf.peer(types);
    }

    /// union 字段的类型
    fn unionFieldType(inf: *Inferrer, t: Index, name: []const u8) Error!?Index {
        if (inf.ip.key(t) != .container_type) return eval.fieldType(inf.r, t, name);
        const ns = try queries.namespaceOfType(inf.r, t) orelse return null;
        const tree = try inf.r.itemTree(ns.file);
        const f = fieldItem(tree, ns.container, name) orelse return null;
        return (try queries.defType(inf.r, .{ .item = .{ .file = ns.file, .item = f } }, null, queries.instOfType(inf.ip, t))).ty;
    }

    // ── 运算 ─────────────────────────────────────────────────────────

    /// 比较中另一侧的结果类型：带标签的 union 与标签比较，另一侧按标签类型（`u == .none`）
    fn comparedType(inf: *Inferrer, t: Index) Error!?Index {
        if (t == .unknown or t == .comptime_int_type) return null;
        const is_union = switch (inf.ip.key(t)) {
            .container_type => |c| c.kind == .@"union",
            .reified_type => |rt| rt.kind == .@"union",
            else => false,
        };
        if (is_union) return try eval.unionTag(inf.r, t);
        return t;
    }

    fn binary(inf: *Inferrer, e: ExprId, op: SyntaxKind, lhs_e: ExprId, rhs_e: ExprId, expected: ?Index) Error!TypedValue {
        const ip = inf.ip;
        switch (op) {
            .keyword_orelse => {
                const lhs = try inf.infer(lhs_e, null);
                const child: Index = switch (ip.key(lhs.ty)) {
                    .optional_type => |c| c,
                    else => .unknown,
                };
                // comptime 已知时只有一侧会被求值
                const non_null = inf.condValue(lhs);
                const rhs = try inf.inferBranch(rhs_e, inf.fallbackType(expected, child, rhs_e), non_null == true);
                if (non_null) |n| return if (n) .{ .ty = child, .val = lhs.val } else rhs;
                return .{ .ty = try inf.peer(&.{ child, rhs.ty }) };
            },
            .keyword_and, .keyword_or => {
                const is_and = op == .keyword_and;
                const lhs = inf.condValue(try inf.infer(lhs_e, .bool_type));
                // 左侧 comptime 已知并决定了结果时右侧不编译（`@hasDecl(T, "x") and T.x`）
                const rhs = inf.condValue(try inf.inferArm(rhs_e, .bool_type, if (lhs) |l| l != is_and else false));
                // 短路：一侧已决定结果
                if (lhs) |l| if (l != is_and) return boolValue(l);
                if (rhs) |r| if (r != is_and) return boolValue(r);
                if (lhs != null and rhs != null) return boolValue(is_and);
                return .{ .ty = .bool_type };
            },
            .equal_equal, .bang_equal, .angle_bracket_left, .angle_bracket_right, .angle_bracket_left_equal, .angle_bracket_right_equal => {
                // 枚举字面量在左侧（`.a == e`）：先推导右侧，字面量按右侧的类型（peer）
                const literal_lhs = inf.body.expr(lhs_e) == .enum_literal and inf.body.expr(rhs_e) != .enum_literal;
                const lhs, const rhs = if (literal_lhs) blk: {
                    const r = try inf.infer(rhs_e, null);
                    break :blk .{ try inf.infer(lhs_e, try inf.comparedType(r.ty)), r };
                } else blk: {
                    const l = try inf.infer(lhs_e, null);
                    break :blk .{ l, try inf.infer(rhs_e, try inf.comparedType(l.ty)) };
                };
                // 向量逐元素比较，结果为 bool 的向量
                const vec_len: ?u32 = switch (ip.key(lhs.ty)) {
                    .vector_type => |v| v.len,
                    else => switch (ip.key(rhs.ty)) {
                        .vector_type => |v| v.len,
                        else => null,
                    },
                };
                if (vec_len) |n| return .{ .ty = try ip.get(.{ .vector_type = .{ .len = n, .child = .bool_type } }) };
                if (try inf.compare(op, lhs, rhs)) |result| return boolValue(result);
                return .{ .ty = .bool_type };
            },
            // 与编译器一致：左侧没有结果类型；`<<` / `>>` 的右侧按 `Log2Int(T)` 推导，`<<|` 的右侧没有结果类型
            .angle_bracket_angle_bracket_left, .angle_bracket_angle_bracket_right, .angle_bracket_angle_bracket_left_pipe => {
                const lhs = try inf.infer(lhs_e, null);
                const rhs = try inf.infer(rhs_e, if (op == .angle_bracket_angle_bracket_left_pipe) null else try inf.log2IntType(lhs.ty));
                return inf.foldInt(op, lhs.ty, lhs, rhs);
            },
            .plus_plus => return inf.concat(e, try inf.infer(lhs_e, null), try inf.infer(rhs_e, null)),
            // 指针运算（与编译器一致）：`[*]T ± usize` 仍为原指针类型，两个指针相减为 usize
            .plus, .minus => {
                const lhs = try inf.infer(lhs_e, null);
                if (!isNonSlicePtr(ip, lhs.ty)) return inf.arith(op, lhs, rhs_e);
                const rhs = try inf.infer(rhs_e, .usize_type);
                if (isNonSlicePtr(ip, rhs.ty)) return .{ .ty = if (op == .minus) .usize_type else .unknown };
                return .{ .ty = if (isManyPtr(ip, lhs.ty)) lhs.ty else .unknown };
            },
            // 错误集合并
            .pipe_pipe => {
                const lhs = (try inf.infer(lhs_e, null)).asType() orelse .unknown;
                const rhs = (try inf.infer(rhs_e, null)).asType() orelse .unknown;
                const x = try queries.errorSetMembers(inf.r, lhs) orelse return typeUnknown();
                const y = try queries.errorSetMembers(inf.r, rhs) orelse return typeUnknown();
                const names = try std.mem.concat(inf.scratch, []const u8, &.{ x, y });
                return TypedValue.ofType(try ip.errorSet(inf.scratch, names));
            },
            else => return inf.arith(op, try inf.infer(lhs_e, null), rhs_e),
        }
    }

    /// 算术与位运算：两侧 peer；两侧都是已知整数时按 peer 类型的位宽折叠。与编译器一致，操作数没有
    /// 结果类型（`const m: u8 = (0xFF << 4) >> 4` 按 comptime_int 计算得 255，之后才转换为 u8）；
    /// 右侧以左侧的类型作为字面量的期望，与 peer 的结果相同
    fn arith(inf: *Inferrer, op: SyntaxKind, lhs: TypedValue, rhs_e: ExprId) Error!TypedValue {
        const rhs = try inf.infer(rhs_e, if (lhs.ty != .unknown and lhs.ty != .comptime_int_type) lhs.ty else null);
        return inf.foldInt(op, try inf.peer(&.{ lhs.ty, rhs.ty }), lhs, rhs);
    }

    /// `++`（与编译器的 `zirArrayCat` 一致）：元组相接为元组；数组与指向数组的指针相接为数组，元素类型为两侧
    /// 元素类型的 peer，任一侧是指针时为 `*const [N]T`。两侧的值都已知时由解释器求值
    fn concat(inf: *Inferrer, e: ExprId, lhs: TypedValue, rhs: TypedValue) Error!TypedValue {
        const ty = try inf.concatType(lhs.ty, rhs.ty);
        if (ty == .unknown) return .unknown;
        if (lhs.val != null and rhs.val != null and inf.dead == 0 and !inf.r.ctx.incomplete()) {
            const tv = try eval.exprValue(inf.r, inf.file, inf.item, inf.body, e, inf.inst, inf.bindings, null, inf.branchQuota());
            if (tv.val != null and tv.ty == ty) return tv;
        }
        return .{ .ty = ty };
    }

    /// 操作数的值 `operand` 已知时由解释器求 `e` 的值；求不出或类型不是 `ty` 时为 null
    fn knownValue(inf: *Inferrer, e: ExprId, operand: ?Index, ty: Index) Error!?TypedValue {
        if (operand == null or inf.dead != 0 or inf.r.ctx.incomplete()) return null;
        const tv = try eval.exprValue(inf.r, inf.file, inf.item, inf.body, e, inf.inst, inf.bindings, null, inf.branchQuota());
        return if (tv.val != null and tv.ty == ty) tv else null;
    }

    fn concatType(inf: *Inferrer, a: Index, b: Index) Error!Index {
        const ip = inf.ip;
        if (ip.key(a) == .tuple_type and ip.key(b) == .tuple_type) {
            // comptime 字段保持为 comptime 字段
            const x = ip.key(a).tuple_type;
            const y = ip.key(b).tuple_type;
            const types = try std.mem.concat(inf.scratch, Index, &.{ x.types, y.types });
            const values = try inf.scratch.alloc(Index, types.len);
            for (values, 0..) |*v, i| v.* = if (i < x.types.len) InternPool.fieldValue(x.values, i) else InternPool.fieldValue(y.values, i - x.types.len);
            return ip.get(.{ .tuple_type = .{ .types = types, .values = InternPool.fieldValues(values) } });
        }
        // 元组与数组相接时元组按另一侧的元素类型看作数组
        const x = concatOperand(ip, a, b) orelse return .unknown;
        const y = concatOperand(ip, b, a) orelse return .unknown;
        const elem = try inf.peer(&.{ x.elem, y.elem });
        if (elem == .unknown) return .unknown;
        // 哨兵先转换为结果的元素类型再比较
        const xs: ?Index = if (x.sentinel) |v| try value.coerceValue(ip, v, elem) orelse return .unknown else null;
        const ys: ?Index = if (y.sentinel) |v| try value.coerceValue(ip, v, elem) orelse return .unknown else null;
        // 长度是 u64，无法表示的拼接不产生结果
        const len = std.math.add(u64, x.len, y.len) catch return .unknown;
        const array = try ip.get(.{ .array_type = .{ .len = len, .child = elem, .sentinel = eval.concatSentinel(xs, ys) } });
        return if (x.is_ptr or y.is_ptr) ip.ptrTo(array, .one, true) else array;
    }

    /// 整数运算：结果类型为 `ty`，两侧值已知且结果有定义时带值
    fn foldInt(inf: *Inferrer, op: SyntaxKind, ty: Index, lhs: TypedValue, rhs: TypedValue) Error!TypedValue {
        const ip = inf.ip;
        if (ip.isFloat(ty)) {
            const a = value.floatOf(ip, lhs.val) orelse return .{ .ty = ty };
            const b = value.floatOf(ip, rhs.val) orelse return .{ .ty = ty };
            return .{ .ty = ty, .val = try value.binaryFloat(ip, op, ty, a, b) };
        }
        if (ty != .comptime_int_type and !ip.isInt(ty)) return .{ .ty = ty };
        const a = value.intOf(ip, lhs.val) orelse return .{ .ty = ty };
        const b = value.intOf(ip, rhs.val) orelse return .{ .ty = ty };
        const v = value.binaryInt(ip, op, ty, a, b) orelse return .{ .ty = ty };
        return .{ .ty = ty, .val = try ip.get(.{ .int_value = .{ .ty = ty, .value = v } }) };
    }

    fn prefix(inf: *Inferrer, op: SyntaxKind, operand_e: ExprId, expected: ?Index) Error!TypedValue {
        const ip = inf.ip;
        switch (op) {
            .keyword_try => {
                // 与编译器一致：结果类型只用于 `try .foo(...)` 中 decl literal 的查找
                const decl_call = switch (inf.body.expr(operand_e)) {
                    .call => |c| inf.body.expr(c.callee) == .enum_literal,
                    else => false,
                };
                const v = try inf.infer(operand_e, if (decl_call) expected else null);
                const payload, _ = inf.unwrapErrorUnion(v.ty);
                return .{ .ty = payload };
            },
            .bang => {
                const v = inf.condValue(try inf.infer(operand_e, .bool_type));
                if (v) |b| if (inf.get(operand_e).ty == .bool_type) return boolValue(!b);
                return .{ .ty = .bool_type };
            },
            .ampersand => {
                const want: ?Index = if (expected) |x| switch (ip.key(x)) {
                    .optional_type => |c| c,
                    else => x,
                } else null;
                const child_expected: ?Index = if (want) |x| switch (ip.key(x)) {
                    .ptr_type => |p| switch (p.size) {
                        .one => p.child,
                        // `&.{ a, b }` 转换为切片或多项指针：按 `[2]T` 推导
                        .slice, .many, .c => switch (inf.body.expr(operand_e)) {
                            .init => |init| if (init.ty == null) try ip.get(.{ .array_type = .{ .len = init.fields.len, .child = p.child, .sentinel = p.sentinel } }) else null,
                            else => null,
                        },
                    },
                    else => null,
                } else null;
                const v = try inf.infer(operand_e, child_expected);
                const is_const = try inf.isConstPlace(operand_e);
                const ty = try ip.ptrTo(v.ty, .one, is_const);
                // 指向 comptime 已知的常量的指针（`parseEx(Id, &params, ...)`、`@field(x, &name)`）comptime 已知：
                // 值为指向该常量值的指针
                if (is_const) if (v.val) |pointee| {
                    return .{ .ty = ty, .val = try eval.constPointer(inf.r, ty, pointee) };
                };
                return .{ .ty = ty };
            },
            .minus, .minus_percent, .tilde => {
                // 数字字面量先按 comptime_int 运算，结果再转换为期望类型（`const x: i8 = -128`）
                const v = try inf.infer(operand_e, if (inf.body.expr(operand_e) == .literal) null else expected);
                if (op == .minus and ip.isFloat(v.ty)) {
                    const x = value.floatOf(ip, v.val) orelse return .{ .ty = v.ty };
                    return .{ .ty = v.ty, .val = try value.floatValue(ip, v.ty, -x) };
                }
                const a = value.intOf(ip, v.val) orelse return .{ .ty = v.ty };
                const r = switch (op) {
                    .tilde => value.bitNot(ip, v.ty, a),
                    else => value.negate(ip, v.ty, a, op == .minus_percent),
                } orelse return .{ .ty = v.ty };
                return .{ .ty = v.ty, .val = try ip.get(.{ .int_value = .{ .ty = v.ty, .value = r } }) };
            },
            else => return .{ .ty = (try inf.infer(operand_e, expected)).ty },
        }
    }

    fn initExpr(inf: *Inferrer, ty_e: ?ExprId, fields: []const Body.FieldInit, expected: ?Index) Error!TypedValue {
        const ip = inf.ip;
        // `.{ ... }` 的类型为结果类型去掉 error union 与 optional（与编译器一致）
        const want = inf.destType(expected, .eu_opt);
        if (ty_e == null and want == null) return inf.anonInit(fields);
        const t: Index = if (ty_e) |te|
            try inf.inferredLenArray(te, fields.len) orelse (try inf.infer(te, null)).asType() orelse .unknown
        else
            want.?;
        const ns: ?Namespace = if (t != .unknown and ip.key(t) == .container_type) try queries.namespaceOfType(inf.r, t) else null;
        for (fields, 0..) |f, fi_index| {
            var field_ty: ?Index = switch (ip.key(t)) {
                .array_type => |a| a.child,
                .abstract_array_type => |a| a.child,
                .vector_type => |v| v.child,
                .tuple_type => |tt| if (f.name == null and fi_index < tt.types.len) tt.types[fi_index] else null,
                else => null,
            };
            if (f.name) |name| if (ns) |n| {
                const tree = try inf.r.itemTree(n.file);
                if (fieldItem(tree, n.container, name)) |fi| {
                    field_ty = (try queries.defType(inf.r, .{ .item = .{ .file = n.file, .item = fi } }, null, queries.instOfType(ip, t))).ty;
                    if (inf.current_init) |init_e| try inf.field_refs.append(inf.scratch, .{ .init = init_e, .index = @intCast(fi_index), .member = .{ .file = n.file, .item = tree.items[fi].ast_id } });
                }
            } else switch (ip.key(t)) {
                // 构造的类型、元组与匿名结构体的字段
                .reified_type, .tuple_type, .anon_struct_type => field_ty = try eval.fieldType(inf.r, t, name),
                else => {},
            };
            _ = try inf.infer(f.value, if (field_ty) |x| (if (x != .unknown) x else null) else null);
        }
        return .{ .ty = t };
    }

    /// 没有结果类型的 `.{ ... }`：元组（`struct { A, B }`）或匿名结构体；元素都已知时带值
    fn anonInit(inf: *Inferrer, fields: []const Body.FieldInit) Error!TypedValue {
        const ip = inf.ip;
        const types = try inf.scratch.alloc(Index, fields.len);
        const vals = try inf.scratch.alloc(Index, fields.len);
        var known = true;
        for (fields, types, vals) |f, *t, *v| {
            const tv = try inf.infer(f.value, null);
            t.* = tv.ty;
            v.* = tv.val orelse .unknown;
            if (tv.val == null) known = false;
        }
        for (types) |t| if (t == .unknown) return .unknown;
        // comptime 已知的字段是 comptime 字段，值属于类型（与编译器一致）
        const values = try inf.scratch.alloc(Index, fields.len);
        for (fields, types, vals, values) |f, t, v, *o| o.* = try inf.literalField(f.value, t, v);
        const field_values = InternPool.fieldValues(values);
        const named = fields.len > 0 and fields[0].name != null;
        const ty = if (named) blk: {
            const names = try inf.scratch.alloc([]const u8, fields.len);
            for (fields, names) |f, *n| n.* = f.name orelse return .unknown;
            break :blk try ip.get(.{ .anon_struct_type = .{ .names = names, .types = types, .values = field_values } });
        } else try ip.get(.{ .tuple_type = .{ .types = types, .values = field_values } });
        return .{ .ty = ty, .val = if (known) try value.aggregate(ip, inf.scratch, ty, vals) else null };
    }

    /// 字面量字段的 comptime 值（见 `InternPool.fieldValue`）：值已知或类型只有一个可能值时为该值，
    /// 运行时的值为 `runtime`，判断不了时为 `unknown`
    fn literalField(inf: *Inferrer, e: ExprId, ty: Index, val: Index) Error!Index {
        if (val != .unknown) return val;
        if (ty == .void_type) return .void_value;
        // 字符串字面量（推导器不为字符串生成值）
        switch (inf.body.expr(e)) {
            .literal => |text| if (try Body.stringLiteralValue(inf.scratch, text)) |str| {
                return inf.ip.get(.{ .bytes = .{ .ty = ty, .bytes = str } });
            },
            else => {},
        }
        if (value.intInfo(inf.ip, ty)) |info| if (info.bits == 0) return inf.ip.get(.{ .int_value = .{ .ty = ty, .value = 0 } });
        if (inf.comptime_depth > 0) return .unknown;
        return if (try inf.knownness(e, 0) == .runtime) .runtime else .unknown;
    }

    const Knownness = enum { comptime_known, runtime, uncertain };

    /// 表达式的值是否 comptime 已知，覆盖与编译器判断一致的常见情形，判断不了时为 `uncertain`
    fn knownness(inf: *Inferrer, e: ExprId, depth: u32) Error!Knownness {
        const ip = inf.ip;
        const tv = inf.get(e);
        if (tv.val != null) return .comptime_known;
        // comptime-only 类型的值一定 comptime 已知
        if (tv.ty != .unknown and value.isComptimeOnly(ip, tv.ty)) return .comptime_known;
        if (depth > 8) return .uncertain;
        const b = inf.body;
        switch (b.expr(e)) {
            .name_ref => |name| {
                const def = try inf.r.resolveName(inf.file, inf.item, b, b.expr_scopes[@backingInt(e)], name) orelse return .uncertain;
                switch (def) {
                    .local => |l| {
                        // 外层函数的局部变量（体内容器的成员中引用）：与编译器一致，只能引用 comptime 已知的
                        if (l.file != inf.file or l.item != inf.item) return .comptime_known;
                        const binding = b.binding(l.binding);
                        return switch (binding.kind) {
                            .local_var => .runtime,
                            .param => if (binding.is_comptime) .comptime_known else try inf.paramKnownness(),
                            .local_const => if (binding.init) |init| inf.knownness(init, depth + 1) else .uncertain,
                            .capture => inf.captureKnownness(l.binding, depth + 1),
                        };
                    },
                    .item => |it| return declKnownness((try inf.r.itemTree(it.file)).items[it.item]),
                    .file => return .comptime_known,
                }
            },
            .field_access => |fa| {
                // 容器的声明
                if (inf.members[@backingInt(e)]) |owner| {
                    const tree = try inf.r.itemTree(owner.file);
                    for (tree.items) |it| if (it.ast_id == owner.item) return declKnownness(it);
                    return .uncertain;
                }
                return inf.anyRuntime(&.{fa.lhs}, depth);
            },
            .call => |c| {
                // 普通函数的调用在运行时执行（返回 comptime-only 类型的调用已在上面处理）
                const fv = switch (ip.key(inf.get(c.callee).val orelse return .uncertain)) {
                    .fn_value => |f| f,
                    else => return .uncertain,
                };
                const tree = try inf.r.itemTree(fv.file);
                for (tree.items) |it| if (it.ast_id == fv.decl) return if (it.flags.is_inline) .uncertain else .runtime;
                return .uncertain;
            },
            .binary => |x| return inf.anyRuntime(&.{ x.lhs, x.rhs }, depth),
            .prefix => |x| return if (x.op == .ampersand) inf.addressKnownness(x.operand, depth) else inf.anyRuntime(&.{x.operand}, depth),
            .index => |x| return inf.anyRuntime(&.{ x.lhs, x.index }, depth),
            .slice => |x| return inf.anyRuntime(&.{ x.lhs, x.start, x.end orelse x.start }, depth),
            .deref, .unwrap_optional => |x| return inf.anyRuntime(&.{x}, depth),
            .@"catch" => |x| return inf.anyRuntime(&.{x.lhs}, depth),
            .builtin_call => |c| {
                if (c.args.len == 0) return .uncertain;
                // 转换类的内置函数取决于被转换的值（最后一个参数），`@field` 取决于对象
                const casts = [_][]const u8{ "@as", "@intCast", "@truncate", "@bitCast", "@floatCast", "@floatFromInt", "@intFromFloat", "@ptrCast", "@alignCast", "@constCast", "@volatileCast", "@intFromEnum", "@enumFromInt", "@intFromBool", "@intFromPtr", "@errorCast" };
                for (casts) |n| if (std.mem.eql(u8, c.name, n)) return inf.anyRuntime(c.args[c.args.len - 1 ..], depth);
                if (std.mem.eql(u8, c.name, "@field")) return inf.anyRuntime(c.args[0..1], depth);
                return .uncertain;
            },
            else => return .uncertain,
        }
    }

    /// 有一个运行时的值即为运行时
    fn anyRuntime(inf: *Inferrer, es: []const ExprId, depth: u32) Error!Knownness {
        for (es) |x| if (try inf.knownness(x, depth + 1) == .runtime) return .runtime;
        return .uncertain;
    }

    /// 非 comptime 参数：返回 comptime-only 类型的函数在 comptime 调用，参数都 comptime 已知；
    /// inline 函数的参数取决于调用处
    fn paramKnownness(inf: *Inferrer) Error!Knownness {
        const it = (try inf.r.itemTree(inf.file)).items[inf.item];
        if (it.kind != .@"fn" or it.flags.is_inline) return .uncertain;
        const ret = inf.ret_type orelse return .uncertain;
        if (ret == .unknown) return .uncertain;
        return if (try eval.isComptimeOnly(inf.r, ret)) .comptime_known else .runtime;
    }

    /// 捕获：非 inline 循环的捕获每次迭代不同，在运行时确定；if、catch 与 switch 的捕获取决于来源
    /// （switch 只看载荷：inline 分支的标签捕获 comptime 已知）
    fn captureKnownness(inf: *Inferrer, binding: Body.BindingId, depth: u32) Error!Knownness {
        for (inf.body.exprs) |x| switch (x) {
            .@"if" => |i| if (contains(i.capture, binding) or contains(i.else_capture, binding)) return inf.anyRuntime(&.{i.cond}, depth),
            .loop => |l| if (contains(l.capture, binding) or contains(l.else_capture, binding)) return if (l.is_inline) .uncertain else .runtime,
            .@"switch" => |sw| for (sw.prongs) |p| if (p.capture.len > 0 and p.capture[0] == binding) return inf.anyRuntime(&.{sw.operand}, depth),
            .@"catch" => |c| if (c.capture == binding) return inf.anyRuntime(&.{c.lhs}, depth),
            else => {},
        };
        return .uncertain;
    }

    /// `&x`：局部变量与参数的地址在运行时确定，全局声明的地址 comptime 已知
    fn addressKnownness(inf: *Inferrer, e: ExprId, depth: u32) Error!Knownness {
        const b = inf.body;
        switch (b.expr(e)) {
            .name_ref => |name| {
                const def = try inf.r.resolveName(inf.file, inf.item, b, b.expr_scopes[@backingInt(e)], name) orelse return .uncertain;
                return switch (def) {
                    .local => |l| if (l.file == inf.file and l.item == inf.item and b.binding(l.binding).kind != .local_const) .runtime else .uncertain,
                    .item, .file => .comptime_known,
                };
            },
            .field_access => |fa| return inf.addressKnownness(fa.lhs, depth + 1),
            else => return inf.anyRuntime(&.{e}, depth),
        }
    }

    /// 表达式的源码形式（显示长度未知的数组用）：名字、字段访问、字面量、调用与二元运算；其他形式为 false
    fn exprText(inf: *Inferrer, e: ExprId, out: *std.ArrayList(u8), depth: u32) Error!bool {
        if (depth > 8) return false;
        const a = inf.scratch;
        switch (inf.body.expr(e)) {
            .name_ref => |n| try out.appendSlice(a, n),
            .literal => |t| try out.appendSlice(a, t),
            .field_access => |fa| {
                if (!try inf.exprText(fa.lhs, out, depth + 1)) return false;
                try out.append(a, '.');
                try out.appendSlice(a, fa.field orelse return false);
            },
            .builtin_call, .call => {
                const args = switch (inf.body.expr(e)) {
                    .builtin_call => |c| blk: {
                        try out.appendSlice(a, c.name);
                        break :blk c.args;
                    },
                    .call => |c| blk: {
                        if (!try inf.exprText(c.callee, out, depth + 1)) return false;
                        break :blk c.args;
                    },
                    else => unreachable,
                };
                try out.append(a, '(');
                for (args, 0..) |x, i| {
                    if (i > 0) try out.appendSlice(a, ", ");
                    if (!try inf.exprText(x, out, depth + 1)) return false;
                }
                try out.append(a, ')');
            },
            .binary => |x| {
                const tag: std.zig.Token.Tag = @fromBackingInt(@as(@typeInfo(std.zig.Token.Tag).@"enum".tag_type, @intCast(@backingInt(x.op))));
                const op = tag.lexeme() orelse return false;
                // 嵌套的运算加上括号（HIR 中不保留括号）
                for ([_]ExprId{ x.lhs, x.rhs }, 0..) |side, i| {
                    if (i == 1) try out.print(a, " {s} ", .{op});
                    const nested = inf.body.expr(side) == .binary;
                    if (nested) try out.append(a, '(');
                    if (!try inf.exprText(side, out, depth + 1)) return false;
                    if (nested) try out.append(a, ')');
                }
            },
            else => return false,
        }
        return true;
    }

    /// `[_]T{ ... }`：数组长度由元素个数决定。不是这种形式时返回 null
    fn inferredLenArray(inf: *Inferrer, te: ExprId, n: usize) Error!?Index {
        const arr = switch (inf.body.expr(te)) {
            .array_type => |a| a,
            else => return null,
        };
        switch (inf.body.expr(arr.len)) {
            .name_ref => |name| if (!std.mem.eql(u8, name, "_")) return null,
            else => return null,
        }
        const ip = inf.ip;
        inf.done.set(@backingInt(te));
        inf.done.set(@backingInt(arr.len));
        inf.exprs[@backingInt(arr.len)] = .{ .ty = .usize_type, .val = try ip.get(.{ .int_value = .{ .ty = .usize_type, .value = n } }) };
        const child = (try inf.infer(arr.child, null)).asType() orelse .unknown;
        const sentinel: ?Index = if (arr.sentinel) |x| (try inf.infer(x, child)).val else null;
        if (child == .unknown) {
            inf.exprs[@backingInt(te)] = typeUnknown();
            return .unknown;
        }
        const t = try ip.get(.{ .array_type = .{ .len = n, .child = child, .sentinel = sentinel } });
        inf.exprs[@backingInt(te)] = TypedValue.ofType(t);
        return t;
    }

    // ── 类型工具 ─────────────────────────────────────────────────────

    /// `for` 遍历的元素类型：`elementType`，以及各字段类型相同的元组（`.{ f32, f64 }` 的元素为 `type`）
    fn forElement(inf: *Inferrer, t: Index) Index {
        const tt = tupleOf(inf.ip, t) orelse return inf.elementType(t);
        if (tt.types.len == 0) return .unknown;
        for (tt.types[1..]) |x| if (x != tt.types[0]) return .unknown;
        return tt.types[0];
    }

    /// 数组、向量、切片、多项指针、指向数组的指针的元素类型
    fn elementType(inf: *Inferrer, t: Index) Index {
        const ip = inf.ip;
        return switch (ip.key(t)) {
            .array_type => |a| a.child,
            .abstract_array_type => |a| a.child,
            .vector_type => |v| v.child,
            .ptr_type => |p| switch (p.size) {
                .slice, .many, .c => p.child,
                .one => switch (ip.key(p.child)) {
                    .array_type => |a| a.child,
                    .abstract_array_type => |a| a.child,
                    else => .unknown,
                },
            },
            else => .unknown,
        };
    }

    /// 切片（与编译器的 `analyzeSlice` 一致）：长度 comptime 已知时为指向数组的指针，否则为切片；多项指针
    /// 不给结束位置时为指针运算，仍是原指针类型。切到数组或切片的末尾时保留原有的哨兵
    fn slice(inf: *Inferrer, e: ExprId, lhs_e: ExprId, start_e: ExprId, end_e: ?ExprId, sentinel_e: ?ExprId) Error!TypedValue {
        const ip = inf.ip;
        const lhs = try inf.infer(lhs_e, null);
        const start = try inf.infer(start_e, .usize_type);
        const end: ?TypedValue = if (end_e) |x| try inf.infer(x, .usize_type) else null;
        const Source = struct { elem: Index, sentinel: ?Index = null, len: ?u64 = null, is_const: bool = false };
        const src: Source = switch (ip.key(lhs.ty)) {
            .array_type => |a| .{ .elem = a.child, .sentinel = a.sentinel, .len = a.len, .is_const = try inf.isConstPlace(lhs_e) },
            .abstract_array_type => |a| .{ .elem = a.child, .sentinel = a.sentinel, .is_const = try inf.isConstPlace(lhs_e) },
            .ptr_type => |p| switch (p.size) {
                .one => switch (ip.key(p.child)) {
                    .array_type => |a| .{ .elem = a.child, .sentinel = a.sentinel, .len = a.len, .is_const = p.is_const },
                    .abstract_array_type => |a| .{ .elem = a.child, .sentinel = a.sentinel, .is_const = p.is_const },
                    // 指向单个元素的指针按长度为 1 的数组切片
                    else => .{ .elem = p.child, .len = 1, .is_const = p.is_const },
                },
                .slice, .many, .c => .{ .elem = p.child, .sentinel = p.sentinel, .is_const = p.is_const },
            },
            else => .{ .elem = .unknown },
        };
        const explicit: ?TypedValue = if (sentinel_e) |x| try inf.infer(x, if (src.elem != .unknown) src.elem else null) else null;
        if (src.elem == .unknown) return .unknown;
        if (end == null and isManyPtr(ip, lhs.ty)) return .{ .ty = lhs.ty };
        const start_n = std.math.cast(u64, value.intOf(ip, start.val) orelse -1);
        const end_n: ?u64 = if (end) |x| std.math.cast(u64, value.intOf(ip, x.val) orelse -1) else src.len;
        const end_is_len = end == null or (src.len != null and end_n != null and end_n.? == src.len.?);
        const sentinel: ?Index = if (explicit) |x| (x.val orelse return .unknown) else if (end_is_len) src.sentinel else null;
        if (start_n != null and end_n != null and end_n.? >= start_n.?) {
            const array = try ip.get(.{ .array_type = .{ .len = end_n.? - start_n.?, .child = src.elem, .sentinel = sentinel } });
            const ty = try ip.ptrTo(array, .one, src.is_const);
            // comptime 已知的常量与区间：由解释器求出切片的值
            if (src.is_const) if (try inf.knownValue(e, lhs.val, ty)) |tv| return tv;
            return .{ .ty = ty };
        }
        return .{ .ty = try ip.get(.{ .ptr_type = .{ .child = src.elem, .size = .slice, .is_const = src.is_const, .sentinel = sentinel } }) };
    }

    /// 移位右侧的结果类型 `Log2Int(T)`（与编译器一致）；不是整数及其向量时为 null
    fn log2IntType(inf: *Inferrer, t: Index) Error!?Index {
        const ip = inf.ip;
        if (t == .comptime_int_type) return .comptime_int_type;
        switch (ip.key(t)) {
            .vector_type => |v| {
                const child = try inf.log2IntType(v.child) orelse return null;
                return try ip.get(.{ .vector_type = .{ .len = v.len, .child = child } });
            },
            else => {},
        }
        const info = value.intInfo(ip, t) orelse return null;
        return try ip.intType(.unsigned, if (info.bits == 0) 0 else std.math.log2_int_ceil(u16, info.bits));
    }

    /// 赋值右侧的结果类型（与编译器一致）：`<<=` / `>>=` 为 `Log2Int(T)`，`<<|=` 没有结果类型，多项指针的
    /// `+=` / `-=` 为 usize
    fn assignRhsType(inf: *Inferrer, op: SyntaxKind, lhs: Index) Error!?Index {
        if (lhs == .unknown) return null;
        return switch (op) {
            .angle_bracket_angle_bracket_left_equal, .angle_bracket_angle_bracket_right_equal => inf.log2IntType(lhs),
            .angle_bracket_angle_bracket_left_pipe_equal => null,
            .plus_equal, .minus_equal => if (isManyPtr(inf.ip, lhs)) .usize_type else lhs,
            else => lhs,
        };
    }

    fn isConstPtr(inf: *Inferrer, t: Index) bool {
        return switch (inf.ip.key(t)) {
            .ptr_type => |p| p.is_const,
            else => false,
        };
    }

    /// `&x`：x 是 const 声明或 const 局部变量时得到 `*const T`
    fn isConstPlace(inf: *Inferrer, e: ExprId) Error!bool {
        const b = inf.body;
        switch (b.expr(e)) {
            .name_ref => |name| {
                const def = try inf.r.resolveName(inf.file, inf.item, b, b.expr_scopes[@backingInt(e)], name) orelse return false;
                return switch (def) {
                    // 外层函数的局部变量（体内容器的成员中引用）在其所在成员的 Body 中
                    .local => |l| (if (l.file == inf.file and l.item == inf.item) b else try inf.r.body(l.file, l.item)).binding(l.binding).kind != .local_var,
                    .item => |it| (try inf.r.itemTree(it.file)).items[it.item].kind == .@"const",
                    .file => true,
                };
            },
            .field_access => |fa| {
                // 经由指针访问时取决于指针；否则取决于左侧
                const lhs = inf.get(fa.lhs);
                return switch (inf.ip.key(lhs.ty)) {
                    .ptr_type => |p| p.is_const,
                    else => inf.isConstPlace(fa.lhs),
                };
            },
            .deref => |x| return inf.isConstPtr(inf.get(x).ty),
            .index => |x| {
                const lhs = inf.get(x.lhs).ty;
                return switch (inf.ip.key(lhs)) {
                    .ptr_type => |p| p.is_const,
                    else => inf.isConstPlace(x.lhs),
                };
            },
            else => return true,
        }
    }

    fn unwrapErrorUnion(inf: *Inferrer, t: Index) struct { Index, Index } {
        return switch (inf.ip.key(t)) {
            .error_union_type => |eu| .{ eu.payload, eu.err },
            else => .{ .unknown, .unknown },
        };
    }

    /// peer type resolution 的常用子集；无法统一时为 unknown
    pub fn peer(inf: *Inferrer, types: []const Index) Error!Index {
        const ip = inf.ip;
        var result: ?Index = null;
        var has_null = false;
        for (types) |t| {
            switch (t) {
                .noreturn_type, .undefined_type => continue,
                .null_type => {
                    has_null = true;
                    continue;
                },
                .unknown => return .unknown,
                else => {},
            }
            const cur = result orelse {
                result = t;
                continue;
            };
            if (cur == t) continue;
            if (cur == .comptime_int_type and (ip.isInt(t) or ip.isFloat(t))) {
                result = t;
                continue;
            }
            if (t == .comptime_int_type and (ip.isInt(cur) or ip.isFloat(cur))) continue;
            if (cur == .comptime_float_type and ip.isFloat(t)) {
                result = t;
                continue;
            }
            if (t == .comptime_float_type and ip.isFloat(cur)) continue;
            // 枚举字面量与枚举或带标签的 union：取后者
            if (cur == .enum_literal_type and isTagged(ip, t)) {
                result = t;
                continue;
            }
            if (t == .enum_literal_type and isTagged(ip, cur)) continue;
            // 整数之间：同符号取较宽者（位宽相同取前者），无符号且较窄时放入有符号，与编译器一致
            if (value.peerIntType(ip, cur, t)) |p| {
                result = p;
                continue;
            }
            // 浮点之间取位宽较大者（c_longdouble 的位宽取决于目标）
            if (ip.isFloat(cur) and ip.isFloat(t)) {
                const x = value.floatBits(ip, cur) orelse return .unknown;
                const y = value.floatBits(ip, t) orelse return .unknown;
                if (y > x) result = t;
                continue;
            }
            // 一侧为 optional：载荷与另一侧的 peer 再包为 optional
            if (ip.key(cur) == .optional_type or ip.key(t) == .optional_type) {
                const p = try inf.peer(&.{ optionalChild(ip, cur), optionalChild(ip, t) });
                if (p == .unknown) return .unknown;
                result = try ip.optionalOf(p);
                continue;
            }
            if (try peerPtr(ip, cur, t)) |p| {
                result = p;
                continue;
            }
            return .unknown;
        }
        const t = result orelse return if (has_null) .null_type else if (types.len != 0 and allNoreturn(types)) .noreturn_type else .void_type;
        if (has_null and ip.key(t) != .optional_type) return ip.optionalOf(t);
        return t;
    }

    /// 枚举字面量可以转换到的类型：枚举与 union
    fn isTagged(ip: *InternPool, t: Index) bool {
        if (value.isEnumType(ip, t)) return true;
        return switch (ip.key(t)) {
            .container_type => |c| c.kind == .@"union",
            .reified_type => |rt| rt.kind == .@"union",
            else => false,
        };
    }

    fn allNoreturn(types: []const Index) bool {
        for (types) |t| if (t != .noreturn_type) return false;
        return true;
    }

    fn containerAt(inf: *Inferrer, e: ExprId) Error!?Namespace {
        return inf.r.containerAt(inf.file, inf.item, inf.body.range(e).start);
    }
};

pub const FnType = @FieldType(InternPool.Key, "fn_type");

/// 容器的声明的值：var 与 extern 声明在运行时读取，其余（const、函数）comptime 已知
fn declKnownness(it: ItemTree.Item) Inferrer.Knownness {
    return if (it.kind == .@"var" or it.flags.is_extern) .runtime else .comptime_known;
}

fn contains(list: []const Body.BindingId, b: Body.BindingId) bool {
    return std.mem.indexOfScalar(Body.BindingId, list, b) != null;
}

/// `if` / `switch` 各分支（含嵌套的）的结果表达式
/// 声明 `owner` 在各种构建配置下可能的值（容器类型）：初始化为按 comptime 条件选择的 `if` / `switch` 时取
/// 各分支，分支或初始化本身是别名（`linux`、`std.c`、`system.SO`）时沿别名查找。用于当前配置下不存在的成员
fn alternativeContainers(r: *Resolver, a: Allocator, owner: hir.OwnerKey, out: *std.ArrayList(Index), depth: u32) Error!void {
    if (depth > 4 or out.items.len >= max_alternatives) return;
    const item = try itemOfKey(r, owner) orelse return;
    const body = try r.ctx.get(hir.ItemBody, owner);
    const init = body.value orelse return;
    const res = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full });
    if (res.exprs.len != body.exprs.len) return;
    var leaves: std.ArrayList(ExprId) = .empty;
    try branchLeaves(a, body, init, &leaves, 0);
    for (leaves.items) |leaf| try leafAlternatives(r, a, owner.file, item, body, res.exprs, leaf, out, depth);
}

const max_alternatives = 64;

/// 表达式 `e` 在各种构建配置下可能的值（容器类型）：当前的值，以及它引用的声明在其他配置下的值
fn leafAlternatives(r: *Resolver, a: Allocator, file: FileId, item: u32, body: *const Body, exprs: []const TypedValue, e: ExprId, out: *std.ArrayList(Index), depth: u32) Error!void {
    if (depth > 4 or out.items.len >= max_alternatives) return;
    const ip = r.ctx.db.env.ip;
    if (@backingInt(e) < exprs.len) if (exprs[@backingInt(e)].asType()) |t| if (ip.key(t) == .container_type) try appendUnique(a, out, t);
    switch (body.expr(e)) {
        .name_ref => |n| {
            const def = try r.resolveName(file, item, body, body.expr_scopes[@backingInt(e)], n) orelse return;
            const key = try defKey(r, def) orelse return;
            try alternativeContainers(r, a, key, out, depth + 1);
        },
        // `X.Name`：X 的各个可能的容器中的 `Name`
        .field_access => |fa| {
            const name = fa.field orelse return;
            var bases: std.ArrayList(Index) = .empty;
            try leafAlternatives(r, a, file, item, body, exprs, fa.lhs, &bases, depth + 1);
            for (bases.items) |base| {
                const ns = try queries.namespaceOfType(r, base) orelse continue;
                const def = try r.memberDef(ns, name) orelse continue;
                const tv = try queries.defType(r, def, null, queries.instOfType(ip, base));
                if (tv.asType()) |t| if (ip.key(t) == .container_type) try appendUnique(a, out, t);
                const key = try defKey(r, def) orelse continue;
                try alternativeContainers(r, a, key, out, depth + 1);
            }
        },
        else => {},
    }
}

/// owner 中的表达式及其推导结果
const ExprCtx = struct {
    file: FileId,
    /// `ItemTree.items` 下标
    item: u32,
    body: *const Body,
    exprs: []const TypedValue,
    members: []const ?hir.OwnerKey,
};

fn ownerCtx(r: *Resolver, key: hir.OwnerKey, mode: Mode) Error!?ExprCtx {
    const item = try itemOfKey(r, key) orelse return null;
    const body = try r.ctx.get(hir.ItemBody, key);
    const res = try r.ctx.get(queries.Infer, .{ .owner = key, .mode = mode });
    if (res.exprs.len != body.exprs.len) return null;
    return .{ .file = key.file, .item = item, .body = body, .exprs = res.exprs, .members = res.members };
}

/// 表达式 `e` 的值在各种构建配置下可能的类型（容器类型）：当前的类型；局部变量与参数的类型标注或初始化；
/// 全局变量的类型标注或初始化；调用的返回类型（`X.Y.init()` 还取 `X.Y`）；字段访问取左侧各种类型中同名字段的类型
fn valueAlternatives(r: *Resolver, a: Allocator, c: ExprCtx, e: ExprId, out: *std.ArrayList(Index), depth: u32) Error!void {
    if (depth > 6 or out.items.len >= max_alternatives) return;
    const ip = r.ctx.db.env.ip;
    if (@backingInt(e) < c.exprs.len) {
        var t = c.exprs[@backingInt(e)].ty;
        switch (ip.key(t)) {
            .ptr_type => |p| if (p.size == .one) {
                t = p.child;
            },
            else => {},
        }
        if (ip.key(t) == .container_type) try appendUnique(a, out, t);
    }
    switch (c.body.expr(e)) {
        .prefix => |x| if (x.op == .keyword_try) try valueAlternatives(r, a, c, x.operand, out, depth + 1),
        .unwrap_optional, .deref => |x| try valueAlternatives(r, a, c, x, out, depth + 1),
        .name_ref => |n| {
            const def = try r.resolveName(c.file, c.item, c.body, c.body.expr_scopes[@backingInt(e)], n) orelse return;
            switch (def) {
                .local => |l| {
                    if (l.file != c.file or l.item != c.item) return;
                    const binding = c.body.binding(l.binding);
                    if (binding.ty) |t| return typeAlternatives(r, a, c, t, out);
                    if (binding.init) |init| try valueAlternatives(r, a, c, init, out, depth + 1);
                },
                else => {
                    const key = try defKey(r, def) orelse return;
                    const vc = try ownerCtx(r, key, .full) orelse return;
                    if (vc.body.type_expr) |t| return typeAlternatives(r, a, vc, t, out);
                    if (vc.body.value) |v| try valueAlternatives(r, a, vc, v, out, depth + 1);
                },
            }
        },
        .call => |call| {
            const callee_key: ?hir.OwnerKey = switch (c.body.expr(call.callee)) {
                .field_access => c.members[@backingInt(call.callee)],
                .name_ref => |n| blk: {
                    const def = try r.resolveName(c.file, c.item, c.body, c.body.expr_scopes[@backingInt(call.callee)], n) orelse break :blk null;
                    break :blk try defKey(r, def);
                },
                else => null,
            };
            if (callee_key) |key| if (try ownerCtx(r, key, .signature)) |fc| if (fc.body.type_expr) |ret| {
                try typeAlternatives(r, a, fc, ret, out);
            };
            // 返回 `@This()` 的构造函数在其他配置下的类型由 `X.Y` 给出
            switch (c.body.expr(call.callee)) {
                .field_access => |fa| try leafAlternatives(r, a, c.file, c.item, c.body, c.exprs, fa.lhs, out, 0),
                else => {},
            }
        },
        .field_access => |fa| {
            const name = fa.field orelse return;
            var bases: std.ArrayList(Index) = .empty;
            try valueAlternatives(r, a, c, fa.lhs, &bases, depth + 1);
            for (bases.items) |base| {
                const ns = try queries.namespaceOfType(r, base) orelse continue;
                const tree = try r.itemTree(ns.file);
                const fi = fieldItem(tree, ns.container, name) orelse continue;
                const fc = try ownerCtx(r, .{ .file = ns.file, .item = tree.items[fi].ast_id }, .signature) orelse continue;
                if (fc.body.type_expr) |t| try typeAlternatives(r, a, fc, t, out);
            }
        },
        else => {},
    }
}

/// 类型表达式在各种构建配置下可能的容器类型；可选、错误联合与指针取其中的类型。
/// 类型的别名链与值的推导链分别限制深度：值经过几层变量与调用之后，类型仍可能有多层别名
fn typeAlternatives(r: *Resolver, a: Allocator, c: ExprCtx, t: ExprId, out: *std.ArrayList(Index)) Error!void {
    var x = t;
    while (true) switch (c.body.expr(x)) {
        .optional_type => |child| x = child,
        .error_union_type => |eu| x = eu.payload,
        .ptr_type => |p| x = p.child,
        else => break,
    };
    try leafAlternatives(r, a, c.file, c.item, c.body, c.exprs, x, out, 0);
}

fn appendUnique(a: Allocator, out: *std.ArrayList(Index), t: Index) Allocator.Error!void {
    if (std.mem.indexOfScalar(Index, out.items, t) == null and out.items.len < max_alternatives) try out.append(a, t);
}

/// `ItemTree.items` 中 AST id 为 `key.item` 的项的下标
fn itemOfKey(r: *Resolver, key: hir.OwnerKey) Error!?u32 {
    const tree = try r.itemTree(key.file);
    for (tree.items, 0..) |it, i| if (it.ast_id == key.item) return @intCast(i);
    return null;
}

fn branchLeaves(a: Allocator, body: *const Body, e: ExprId, out: *std.ArrayList(ExprId), depth: u32) Allocator.Error!void {
    if (depth > 8) return;
    switch (body.expr(e)) {
        .@"if" => |x| {
            try branchLeaves(a, body, x.then, out, depth + 1);
            if (x.@"else") |el| try branchLeaves(a, body, el, out, depth + 1);
        },
        .@"switch" => |sw| for (sw.prongs) |p| try branchLeaves(a, body, p.body, out, depth + 1),
        else => try out.append(a, e),
    }
}

/// 指针转换类内置函数（嵌套时在编译器中合并为一次转换）
fn isPtrCast(name: []const u8) bool {
    for ([_][]const u8{ "@ptrCast", "@alignCast", "@addrSpaceCast", "@constCast", "@volatileCast" }) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

fn optionalChild(ip: *InternPool, t: Index) Index {
    return switch (ip.key(t)) {
        .optional_type => |c| c,
        else => t,
    };
}

/// 两个指针的 peer（与编译器一致）：元素类型须相同；指向数组的单项指针与切片、多项指针统一为后者，长度不同的
/// 数组指针统一为切片；const 取并集，哨兵只在两侧相同时保留。不能统一时为 null
fn peerPtr(ip: *InternPool, a: Index, b: Index) Allocator.Error!?Index {
    const x = switch (ip.key(a)) {
        .ptr_type => |p| p,
        else => return null,
    };
    const y = switch (ip.key(b)) {
        .ptr_type => |p| p,
        else => return null,
    };
    if (try tupleAsArray(ip, x, y)) |p| return peerPtr(ip, p, b);
    if (try tupleAsArray(ip, y, x)) |p| return peerPtr(ip, a, p);
    const xa: ?@FieldType(InternPool.Key, "array_type") = if (x.size == .one) switch (ip.key(x.child)) {
        .array_type => |arr| arr,
        else => null,
    } else null;
    const ya: ?@FieldType(InternPool.Key, "array_type") = if (y.size == .one) switch (ip.key(y.child)) {
        .array_type => |arr| arr,
        else => null,
    } else null;
    const is_const = x.is_const or y.is_const;
    // 指向非数组的单项指针只与同类型的单项指针统一
    if ((x.size == .one and xa == null) or (y.size == .one and ya == null)) {
        if (x.size != y.size or x.child != y.child) return null;
        return try ip.get(.{ .ptr_type = .{ .child = x.child, .size = .one, .is_const = is_const } });
    }
    const x_elem = if (xa) |arr| arr.child else x.child;
    const y_elem = if (ya) |arr| arr.child else y.child;
    if (x_elem != y_elem) return null;
    const x_sentinel = if (xa) |arr| arr.sentinel else x.sentinel;
    const y_sentinel = if (ya) |arr| arr.sentinel else y.sentinel;
    const sentinel: ?Index = if (x_sentinel != null and y_sentinel != null and x_sentinel.? == y_sentinel.?) x_sentinel else null;
    if (xa != null and ya != null) {
        if (xa.?.len == ya.?.len) {
            const arr = try ip.get(.{ .array_type = .{ .len = xa.?.len, .child = x_elem, .sentinel = sentinel } });
            return try ip.ptrTo(arr, .one, is_const);
        }
        return try ip.get(.{ .ptr_type = .{ .child = x_elem, .size = .slice, .is_const = is_const, .sentinel = sentinel } });
    }
    const size: InternPool.PtrSize = if (xa != null) y.size else if (ya != null) x.size else if (x.size == y.size) x.size else return null;
    return try ip.get(.{ .ptr_type = .{ .child = x_elem, .size = size, .is_const = is_const, .sentinel = sentinel } });
}

/// 指向元组的单项指针 `p`（`&.{}`、`&.{ a, b }`）的各项都是指针 `other` 的元素类型（或没有项）时，对应的指向
/// 数组的指针：与切片、指向数组的指针做 peer type resolution 时按数组处理（`else => &.{}`）
fn tupleAsArray(ip: *InternPool, p: @FieldType(InternPool.Key, "ptr_type"), other: @FieldType(InternPool.Key, "ptr_type")) Allocator.Error!?Index {
    if (p.size != .one) return null;
    const tt = switch (ip.key(p.child)) {
        .tuple_type => |t| t,
        else => return null,
    };
    const elem = if (other.size == .one) switch (ip.key(other.child)) {
        .array_type => |arr| arr.child,
        else => return null,
    } else other.child;
    for (tt.types) |t| if (t != elem) return null;
    const arr = try ip.get(.{ .array_type = .{ .len = @intCast(tt.types.len), .child = elem, .sentinel = null } });
    return try ip.ptrTo(arr, .one, p.is_const);
}

/// 可做指针运算的指针（多项指针与 C 指针）
fn isManyPtr(ip: *InternPool, t: Index) bool {
    return switch (ip.key(t)) {
        .ptr_type => |p| p.size == .many or p.size == .c,
        else => false,
    };
}

fn isNonSlicePtr(ip: *InternPool, t: Index) bool {
    return switch (ip.key(t)) {
        .ptr_type => |p| p.size != .slice,
        else => false,
    };
}

const ConcatOperand = struct { elem: Index, len: u64, sentinel: ?Index, is_ptr: bool };

/// `++` 的一侧：数组、指向数组的指针，或另一侧可下标时的元组（元素类型取另一侧的）
fn concatOperand(ip: *InternPool, t: Index, other: Index) ?ConcatOperand {
    switch (ip.key(t)) {
        .array_type => |a| return .{ .elem = a.child, .len = a.len, .sentinel = a.sentinel, .is_ptr = false },
        .ptr_type => |p| if (p.size == .one) switch (ip.key(p.child)) {
            .array_type => |a| return .{ .elem = a.child, .len = a.len, .sentinel = a.sentinel, .is_ptr = true },
            else => {},
        },
        .tuple_type => |tt| {
            const elem: Index = switch (ip.key(other)) {
                .array_type => |a| a.child,
                .vector_type => |v| v.child,
                .ptr_type => |p| switch (p.size) {
                    .one => switch (ip.key(p.child)) {
                        .array_type => |a| a.child,
                        .vector_type => |v| v.child,
                        else => return null,
                    },
                    .many, .c, .slice => p.child,
                },
                else => return null,
            };
            return .{ .elem = elem, .len = tt.types.len, .sentinel = null, .is_ptr = false };
        },
        else => {},
    }
    return null;
}

/// 元组类型（含指向元组的单项指针）
pub fn tupleOf(ip: *InternPool, t: Index) ?InternPool.Tuple {
    return switch (ip.key(t)) {
        .tuple_type => |tt| tt,
        .ptr_type => |p| if (p.size == .one) switch (ip.key(p.child)) {
            .tuple_type => |tt| tt,
            else => null,
        } else null,
        else => null,
    };
}

/// 元组与匿名结构体类型中名为 `name` 的 comptime 字段的值
fn literalFieldValue(ip: *InternPool, t: Index, name: []const u8) ?Index {
    const v = switch (ip.key(t)) {
        .tuple_type => |tt| blk: {
            const i = std.fmt.parseInt(usize, name, 10) catch return null;
            if (i >= tt.types.len) return null;
            break :blk InternPool.fieldValue(tt.values, i);
        },
        .anon_struct_type => |a| for (a.names, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) break InternPool.fieldValue(a.values, i);
        } else return null,
        else => return null,
    };
    return if (v == .runtime or v == .unknown) null else v;
}

/// `comptime_anytype`（`comptime x: anytype`）在实例中记录实参值，参数类型由值给出；`anytype_type` 记录实参类型
pub const ParamKind = enum { runtime, comptime_value, comptime_anytype, anytype_type };

/// 需要实例化的被调函数：参数中有 comptime（含隐式的 comptime-only 类型参数）或 anytype，
/// 或返回 comptime-only 类型（如 `type`，此时调用在 comptime 执行，所有实参都参与实例）
pub const Generic = struct {
    owner: hir.OwnerKey,
    body: *const Body,
    parent: ?Index,
    kinds: []const ParamKind,

    pub fn kind(g: Generic, i: usize) ParamKind {
        return if (i < g.kinds.len) g.kinds[i] else .runtime;
    }
};

pub fn genericCallee(r: *Resolver, scratch: Allocator, callee: TypedValue, f: FnType) Error!?Generic {
    const ip = r.ctx.db.env.ip;
    const fv = switch (ip.key(callee.val orelse return null)) {
        .fn_value => |v| v,
        else => return null,
    };
    const owner: hir.OwnerKey = .{ .file = fv.file, .item = fv.decl };
    // 先只看参数的形式：不是泛型的调用（绝大多数）不依赖被调函数的函数体
    const forms = try r.ctx.get(hir.ParamForms, owner);
    const all_comptime = try eval.isComptimeOnly(r, f.ret);
    const kinds = try scratch.alloc(ParamKind, forms.len);
    var generic = all_comptime;
    for (forms, kinds, 0..) |form, *k, i| {
        k.* = switch (form) {
            .any => .anytype_type,
            .comptime_any => .comptime_anytype,
            .typed, .comptime_typed => if (all_comptime or form == .comptime_typed or (i < f.params.len and value.isComptimeOnly(ip, f.params[i])))
                .comptime_value
            else
                .runtime,
        };
        if (k.* != .runtime) generic = true;
    }
    if (!generic) return null;
    return .{ .owner = owner, .body = try r.ctx.get(hir.ItemBody, owner), .parent = fv.inst, .kinds = kinds };
}

/// 调用的实例（`args` 与形参一一对应）。comptime 实参按参数类型转换：参数类型依赖其他参数
/// （`comptime n: T`）时，先以未转换的实参建立实例求出参数类型，再转换实参，保证 `Box(u8, 3)`
/// 与 `Box(u8, @as(u8, 3))` 是同一个实例
pub fn instanceOf(r: *Resolver, scratch: Allocator, g: Generic, f: FnType, args: []const TypedValue) Error!Index {
    const ip = r.ctx.db.env.ip;
    const inst_args = try scratch.alloc(Index, g.body.params.len);
    var dependent = false;
    for (inst_args, 0..) |*out, i| {
        const tv: TypedValue = if (i < args.len) args[i] else .unknown;
        switch (g.kinds[i]) {
            .runtime => out.* = .runtime,
            .anytype_type => out.* = tv.ty,
            .comptime_anytype => out.* = tv.val orelse .unknown,
            .comptime_value => {
                out.* = tv.val orelse .unknown;
                if (out.* == .unknown) continue;
                const pt = paramType(f, i) orelse .unknown;
                if (value.isConcrete(ip, pt)) {
                    out.* = (try value.coerceValue(ip, out.*, pt)) orelse .unknown;
                } else dependent = true;
            },
        }
    }
    var inst = try ip.get(.{ .instance = .{ .file = g.owner.file, .decl = g.owner.item, .args = inst_args, .parent = g.parent } });
    if (!dependent) return inst;
    const sig = try r.ctx.get(queries.Infer, .{ .owner = g.owner, .mode = .signature, .inst = inst });
    var changed = false;
    for (inst_args, 0..) |*out, i| {
        if (g.kinds[i] != .comptime_value or out.* == .unknown or value.isConcrete(ip, paramType(f, i) orelse .unknown)) continue;
        const pt = instParamType(sig, g.body, i) orelse continue;
        const coerced = (try value.coerceValue(ip, out.*, pt)) orelse .unknown;
        if (coerced != out.*) {
            out.* = coerced;
            changed = true;
        }
    }
    if (changed) inst = try ip.get(.{ .instance = .{ .file = g.owner.file, .decl = g.owner.item, .args = inst_args, .parent = g.parent } });
    return inst;
}

/// 非泛型函数作为 comptime 调用执行时的实例（不区分实参，实参的值另行传入）
/// 实例用于它所属的成员 `owner` 自身时：带迭代的实例（见 `InternPool.Instance.iteration`）拆成外层实例与
/// 循环种子；其他实例原样返回
fn splitIteration(ip: *InternPool, owner: hir.OwnerKey, inst: ?Index) Error!struct { inst: ?Index, seed: ?LoopSeed } {
    const i = inst orelse return .{ .inst = null, .seed = null };
    const key = ip.key(i).instance;
    const it = key.iteration orelse return .{ .inst = i, .seed = null };
    if (key.file != owner.file or key.decl != owner.item) return .{ .inst = i, .seed = null };
    const seed: LoopSeed = .{ .binding = it.binding, .index = it.index };
    if (it.abstract) return .{ .inst = key.parent, .seed = seed };
    var base = key;
    base.iteration = null;
    return .{ .inst = try ip.get(.{ .instance = base }), .seed = seed };
}

/// 循环种子的循环变量所在的区域：`for` 循环体，或 `inline` switch 分支的分支体
fn seedRegion(body: *const Body, binding: u32) ?Body.Range {
    for (body.exprs) |x| switch (x) {
        .loop => |l| for (l.capture) |c| if (@backingInt(c) == binding) return body.range(l.body),
        .@"switch" => |sw| for (sw.prongs) |p| if (p.capture.len > 0 and @backingInt(p.capture[0]) == binding) return body.range(p.body),
        else => {},
    };
    return null;
}

pub fn runtimeInstance(ip: *InternPool, scratch: Allocator, fv: @FieldType(InternPool.Key, "fn_value"), n: usize) Error!Index {
    const args = try scratch.alloc(Index, n);
    @memset(args, .runtime);
    return ip.get(.{ .instance = .{ .file = fv.file, .decl = fv.decl, .args = args, .parent = fv.inst } });
}

/// 比较两个数
fn order(op: SyntaxKind, x: anytype, y: @TypeOf(x)) ?bool {
    return switch (op) {
        .equal_equal => x == y,
        .bang_equal => x != y,
        .angle_bracket_left => x < y,
        .angle_bracket_right => x > y,
        .angle_bracket_left_equal => x <= y,
        .angle_bracket_right_equal => x >= y,
        else => null,
    };
}

/// 不计 noreturn 的分支：各分支的值都相同时为该值
fn sameLiveValue(values: []const TypedValue, ty: Index) ?Index {
    var v: ?Index = null;
    for (values) |x| {
        if (x.ty == .noreturn_type) continue;
        if (x.ty != ty) return null;
        const xv = x.val orelse return null;
        if (v) |y| {
            if (y != xv) return null;
        } else v = xv;
    }
    return v;
}

/// 各个 break 的值都相同（且类型就是汇合后的类型）时的值
fn sameValue(values: []const TypedValue, ty: Index) ?Index {
    if (values.len == 0) return null;
    const v = values[0].val orelse return null;
    for (values) |x| if (x.ty != ty or x.val != v) return null;
    return v;
}

fn boolValue(b: bool) TypedValue {
    return .{ .ty = .bool_type, .val = if (b) .true_value else .false_value };
}

/// 签名中第 `i` 个参数的类型（未知时为 null）
fn paramType(f: @FieldType(InternPool.Key, "fn_type"), i: usize) ?Index {
    return if (i < f.params.len and f.params[i] != .unknown) f.params[i] else null;
}

/// 实例的签名推导结果中第 `i` 个参数的类型
fn instParamType(sig: *const Result, body: *const Body, i: usize) ?Index {
    if (i >= body.params.len) return null;
    const b = @backingInt(body.params[i]);
    if (b >= sig.bindings.len or sig.bindings[b].ty == .unknown) return null;
    return sig.bindings[b].ty;
}

fn typeUnknown() TypedValue {
    return .{ .ty = .type_type };
}

/// `@hasDecl`（只计 pub 声明）/ `@hasField`；元组、匿名结构体与构造的类型没有声明，字段名在类型中；
/// 其他不是源码中的容器的类型为 null
fn hasMember(r: *Resolver, t: Index, name: []const u8, decl: bool) Error!?bool {
    switch (r.ctx.db.env.ip.key(t)) {
        .tuple_type => |tt| {
            if (decl) return false;
            const i = std.fmt.parseInt(usize, name, 10) catch return false;
            return i < tt.types.len;
        },
        .anon_struct_type => |s| return !decl and hasName(s.names, name),
        .reified_type => |rt| return !decl and hasName(rt.names, name),
        else => {},
    }
    const ns = try queries.namespaceOfType(r, t) orelse return null;
    const tree = try r.itemTree(ns.file);
    if (!decl) return fieldItem(tree, ns.container, name) != null;
    const m = Resolver.lookupDecl(tree, ns.container, name) orelse return false;
    return tree.items[m].flags.is_pub;
}

/// `inline` 分支的取值（非 union、非错误集的操作数）：分支项依次展开，区间 `a...b` 逐个整数。`count` 为
/// 取值个数，`value` 为第 `want` 个；有求不出的分支项或是 `else` 分支时 `count` 为 null
pub fn inlineProngValues(ip: *InternPool, body: *const Body, exprs: []const TypedValue, prong: Body.Prong, ty: Index, want: ?u32) Error!struct { count: ?u32, value: ?Index } {
    if (prong.is_else or !prong.is_inline) return .{ .count = null, .value = null };
    const int_ty: Index = if (value.intInfo(ip, ty) != null) ty else .comptime_int_type;
    var n: u64 = 0;
    var found: ?Index = null;
    for (prong.items) |item| {
        if (@backingInt(item) >= exprs.len) return .{ .count = null, .value = null };
        switch (body.expr(item)) {
            .other => |range| {
                if (range.len != 2) return .{ .count = null, .value = null };
                const lo = value.intOf(ip, exprs[@backingInt(range[0])].val) orelse return .{ .count = null, .value = null };
                const hi = value.intOf(ip, exprs[@backingInt(range[1])].val) orelse return .{ .count = null, .value = null };
                if (hi < lo) continue;
                const len: u64 = @intCast(hi - lo + 1);
                if (want) |w| if (found == null and w >= n and w < n + len) {
                    found = try ip.get(.{ .int_value = .{ .ty = int_ty, .value = lo + @as(i128, w - n) } });
                };
                n += len;
            },
            else => {
                const v = exprs[@backingInt(item)].val orelse return .{ .count = null, .value = null };
                if (want) |w| if (w == n) {
                    found = v;
                };
                n += 1;
            },
        }
    }
    return .{ .count = std.math.cast(u32, n), .value = found };
}

fn hasName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// 容器中的字段（按名字）
pub fn fieldItem(tree: *const ItemTree, container: u32, name: []const u8) ?u32 {
    for (tree.containerMembers(container)) |m| {
        const it = tree.items[m];
        if (it.kind == .field and it.name != null and std.mem.eql(u8, it.name.?, name)) return m;
    }
    return null;
}

pub fn defKey(r: *Resolver, def: resolve.Def) Error!?hir.OwnerKey {
    return switch (def) {
        .item => |it| .{ .file = it.file, .item = (try r.itemTree(it.file)).items[it.item].ast_id },
        else => null,
    };
}

/// 原生类型与值的名字
pub fn primitive(ip: *InternPool, name: []const u8) Error!?TypedValue {
    const simple = std.meta.stringToEnum(InternPool.Simple, name);
    if (simple) |s| switch (s) {
        // 这些是类型名但不是可直接书写的标识符
        .null, .undefined, .enum_literal => {},
        else => return TypedValue.ofType(try ip.get(.{ .simple_type = s })),
    };
    if (std.mem.eql(u8, name, "true")) return .{ .ty = .bool_type, .val = .true_value };
    if (std.mem.eql(u8, name, "false")) return .{ .ty = .bool_type, .val = .false_value };
    if (std.mem.eql(u8, name, "null")) return .{ .ty = .null_type, .val = .null_value };
    if (std.mem.eql(u8, name, "undefined")) return .{ .ty = .undefined_type, .val = .undefined_value };
    // `u8`、`i32`、`u0`
    if (name.len >= 2 and (name[0] == 'u' or name[0] == 'i')) {
        const bits = std.fmt.parseInt(u16, name[1..], 10) catch return null;
        if (name[1] == '0' and name.len > 2) return null;
        return TypedValue.ofType(try ip.intType(if (name[0] == 'u') .unsigned else .signed, bits));
    }
    return null;
}
