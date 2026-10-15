//! 表达式类型推导（设计 §9.3）：双向推导，期望类型从参数、返回值、类型标注、字段初始化下推；
//! 分支汇合处做 peer type resolution 的常用子集。未知部分为 `unknown`，吸收一切且不产生诊断。
//!
//! 类型表达式（`?*const T`、`[]u8`、`struct {...}`）也是表达式，求值得到 `type` 类型的值。
//!
//! comptime 求值（设计 §9.4）：调用带 comptime / anytype 参数或返回 `type` 的函数时创建实例
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
    /// 有期望类型的枚举字面量（含 decl literal 与还没写名字的 `.`）与匿名初始化（`.{ ... }`）及其期望类型：
    /// 补全按它列出成员与字段
    literal_expected: []const LiteralExpected = &.{},
    /// comptime 已知不会执行的 `if` / `switch` 分支（最外层的）：在当前构建配置下不编译的代码
    inactive: []const ExprId = &.{},

    pub const LiteralExpected = struct { expr: ExprId, ty: Index };

    pub const FieldRef = struct {
        /// `init` 表达式
        init: ExprId,
        /// 在 `Body.Expr.init.fields` 中的下标
        index: u32,
        member: hir.OwnerKey,
    };

    pub fn eql(a: *const Result, b: *const Result) bool {
        return deepEql(a.exprs, b.exprs) and deepEql(a.bindings, b.bindings) and deepEql(a.members, b.members) and deepEql(a.ret, b.ret) and deepEql(a.field_refs, b.field_refs) and deepEql(a.literal_expected, b.literal_expected) and deepEql(a.inactive, b.inactive);
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

pub fn run(ctx: *Db.Ctx, owner: hir.OwnerKey, mode: Mode, inst: ?Index) Error!Result {
    const gpa = ctx.db.gpa;
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
    const tree = try r.itemTree(owner.file);
    const item: u32 = for (tree.items, 0..) |it, i| {
        if (it.ast_id == owner.item) break @intCast(i);
    } else return empty(gpa);
    const body = try ctx.get(hir.ItemBody, owner);

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
        .inst = inst,
    };
    @memset(inf.exprs, .unknown);
    @memset(inf.bindings, .unknown);
    @memset(inf.members, null);
    try inf.runOwner(tree.items[item].kind, mode);
    const ret = try inf.returnValue();
    const field_refs = try a.dupe(Result.FieldRef, inf.field_refs.items);
    const literal_expected = try a.dupe(Result.LiteralExpected, inf.literal_expected.items);
    const inactive = try a.dupe(ExprId, inf.inactive.items);
    return .{ .arena = arena.state, .exprs = inf.exprs, .bindings = inf.bindings, .members = inf.members, .ret = ret, .field_refs = field_refs, .literal_expected = literal_expected, .inactive = inactive };
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
    /// 见 `Result.literal_expected`
    literal_expected: std.ArrayList(Result.LiteralExpected) = .empty,
    /// 见 `Result.inactive`
    inactive: std.ArrayList(ExprId) = .empty,
    /// 实例上下文（owner 自身或外层泛型函数的实例）
    inst: ?Index,
    /// 大于 0 时位于 comptime 已知不会执行的分支中：其中的 return 不计入结果
    dead: u32 = 0,
    /// 实际执行到的 return 的值
    returns: std.ArrayList(TypedValue) = .empty,
    /// 大于 0 时位于 comptime 上下文中（类型表达式、数组长度、comptime 实参等）：其中的函数调用由解释器求值
    comptime_depth: u32 = 0,

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

    /// owner 自身（函数）的实例
    fn ownInstance(inf: *Inferrer) ?InternPool.Instance {
        const i = inf.inst orelse return null;
        const key = inf.ip.key(i).instance;
        if (key.file != inf.file) return null;
        const tree = inf.r.itemTree(inf.file) catch return null;
        return if (key.decl == tree.items[inf.item].ast_id) key else null;
    }

    /// 参数的值：实例中 comptime 参数取实参值（按参数类型转换），anytype 参数取实参的类型；
    /// 没有具体实参时类型参数（`comptime T: type`，或不写 comptime 的 `T: type`）为抽象参数
    fn paramValue(inf: *Inferrer, p: Body.BindingId, arg: ?Index) Error!TypedValue {
        const binding = inf.body.binding(p);
        const ty_e = binding.ty orelse {
            // anytype：实例记录的是实参类型
            return .{ .ty = if (arg) |a| (if (a == .runtime) .unknown else a) else .unknown };
        };
        const ty: Index = (try inf.inferComptime(ty_e, null)).asType() orelse .unknown;
        if (arg) |a| if (a != .unknown and a != .runtime) return .{ .ty = ty, .val = (try value.coerceValue(inf.ip, a, ty)) orelse a };
        if (ty == .type_type and (arg == null or arg.? == .unknown)) return TypedValue.ofType(try inf.ip.get(.{ .opaque_param = .{ .file = inf.file, .owner = inf.body_owner(), .binding = @backingInt(p), .name = binding.name } }));
        return .{ .ty = ty };
    }

    fn body_owner(inf: *Inferrer) ItemTree.AstId {
        return (inf.r.itemTree(inf.file) catch unreachable).items[inf.item].ast_id;
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
    fn condValue(inf: *Inferrer, cond: TypedValue) ?bool {
        const v = cond.val orelse return null;
        if (v == .true_value) return true;
        if (v == .false_value) return false;
        if (v == .null_value) return false;
        if (v == .unknown or v == .undefined_value) return null;
        return if (inf.ip.key(cond.ty) == .optional_type) true else null;
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
        return tv;
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
        if (!outermost or tv.val != null or inf.dead > 0 or inf.r.ctx.incomplete()) return tv;
        switch (inf.body.expr(e)) {
            .missing, .other, .literal, .name_ref => return tv,
            else => {},
        }
        const ev = try eval.exprValue(inf.r, inf.file, inf.item, inf.body, e, inf.inst, inf.bindings, expected);
        if (ev.val == null) return tv;
        inf.exprs[@backingInt(e)] = ev;
        return ev;
    }

    fn recordTagMember(inf: *Inferrer, e: ExprId, t: Index) Error!void {
        const want = switch (inf.ip.key(t)) {
            .optional_type => |c| c,
            else => t,
        };
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
                const set = try ip.errorSet(inf.scratch, &.{name});
                return .{ .ty = set, .val = try ip.get(.{ .error_value = name }) };
            },
            .builtin_call => |bc| return inf.builtin(e, bc.name, bc.args, expected),
            .call => |c| return inf.call(c.callee, c.args, expected),
            .block => |blk| return inf.block(blk, expected),
            .@"if" => |x| {
                const cond = try inf.infer(x.cond, null);
                try inf.bindCaptures(x.capture, cond, .if_then);
                try inf.bindCaptures(x.else_capture, cond, .if_else);
                const taken = inf.condValue(cond);
                const then = try inf.inferArm(x.then, expected, taken == false);
                const other: TypedValue = if (x.@"else") |el| try inf.inferArm(el, expected, taken == true) else .{ .ty = .void_type };
                if (taken) |t| return if (t) then else other;
                const ty = try inf.peer(&.{ then.ty, other.ty });
                return .{ .ty = ty, .val = if (try inf.comptimeCond(x.cond, ty)) sameLiveValue(&.{ then, other }, ty) else null };
            },
            .loop => |l| return inf.loop(l, expected),
            .@"switch" => |s| {
                const operand = try inf.infer(s.operand, null);
                for (s.prongs) |prong| for (prong.items) |item| {
                    _ = try inf.infer(item, operand.ty);
                };
                // comptime 已知的操作数：只有匹配的分支会执行
                const chosen = try inf.chooseProng(s.prongs, operand);
                var types: std.ArrayList(Index) = .empty;
                var values: std.ArrayList(TypedValue) = .empty;
                var chosen_tv: TypedValue = .unknown;
                for (s.prongs, 0..) |prong, i| {
                    try inf.bindSwitchCapture(prong, operand.ty);
                    const tv = try inf.inferArm(prong.body, expected, chosen != null and chosen.? != i);
                    if (chosen != null and chosen.? == i) chosen_tv = tv;
                    try types.append(inf.scratch, tv.ty);
                    try values.append(inf.scratch, tv);
                }
                if (chosen != null) return chosen_tv;
                const ty = try inf.peer(types.items);
                return .{ .ty = ty, .val = if (try inf.comptimeCond(s.operand, ty)) sameLiveValue(values.items, ty) else null };
            },
            .@"catch" => |c| {
                const lhs = try inf.infer(c.lhs, null);
                const payload, const err = inf.unwrapErrorUnion(lhs.ty);
                if (c.capture) |cap| inf.bindings[@backingInt(cap)] = .{ .ty = err };
                const rhs = try inf.infer(c.rhs, if (payload != .unknown) payload else null);
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
            .slice => |s| return inf.slice(s.lhs, s.start, s.end, s.sentinel),
            .deref => |x| {
                const p = try inf.infer(x, null);
                return .{ .ty = switch (ip.key(p.ty)) {
                    .ptr_type => |pt| if (pt.size == .one) pt.child else .unknown,
                    else => .unknown,
                } };
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
                return TypedValue.ofType(try queries.containerType(inf.r, ns, inf.inst));
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
            .@"comptime" => |x| return inf.infer(x, expected),
            .@"unreachable" => return .{ .ty = .noreturn_type },
            .optional_type => |x| {
                const child = (try inf.infer(x, null)).asType() orelse return typeUnknown();
                return TypedValue.ofType(try ip.optionalOf(child));
            },
            .error_union_type => |eu| {
                const err = (try inf.infer(eu.err, null)).asType() orelse .unknown;
                const payload = (try inf.infer(eu.payload, null)).asType() orelse .unknown;
                if (err == .unknown or payload == .unknown) return typeUnknown();
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
        if (try primitive(inf.ip, name)) |tv| return tv;
        const def = try inf.r.resolveName(inf.file, inf.item, b, b.expr_scopes[@backingInt(e)], name) orelse return .unknown;
        return queries.defType(inf.r, def, .{ .file = inf.file, .item = inf.item, .bindings = inf.bindings }, inf.inst);
    }

    fn literal(inf: *Inferrer, text: []const u8) Error!TypedValue {
        const ip = inf.ip;
        if (text.len == 0) return .unknown;
        switch (text[0]) {
            '"' => {
                const s = std.zig.string_literal.parseAlloc(inf.scratch, text) catch return .unknown;
                return .{ .ty = try ip.stringLiteralType(s.len) };
            },
            '\\' => return .{ .ty = try ip.ptrTo(.u8_type, .slice, true) },
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
                    const def = try inf.r.memberDef(ns, name) orelse return try inf.otherBranchMember(e, lhs_e, t, name) orelse .unknown;
                    inf.members[@backingInt(e)] = try defKey(inf.r, def);
                    return queries.defType(inf.r, def, null, queries.instOfType(ip, t));
                },
                .error_set_type => return .{ .ty = t, .val = try ip.get(.{ .error_value = name }) },
                // 构造的枚举（`@Enum`、union(enum) 的标签枚举）的成员
                .reified_type, .union_tag_type => return try eval.typeMember(inf.r, t, name) orelse .unknown,
                else => return .unknown,
            }
        }
        const tv = try inf.instanceMember(e, lhs, name);
        // comptime 已知的值（结构体、union、元组、`len`）：取出字段的值
        if (tv.val == null and lhs.val != null) if (try eval.fieldValue(inf.r, lhs, name)) |fv| {
            return .{ .ty = if (tv.ty != .unknown) tv.ty else fv.ty, .val = fv.val };
        };
        return tv;
    }

    /// 当前构建配置下不存在的成员，所在的命名空间由声明中的 `if` / `switch` 按目标选择（如 `posix.system`
    /// 在 linux 上为 `linux`，其他目标为 `std.c` 等）：到其他分支选择的容器中查找。这样的代码只在其他目标上
    /// 编译，给出那里的定义，而不是未知
    fn otherBranchMember(inf: *Inferrer, e: ExprId, lhs_e: ExprId, current: Index, name: []const u8) Error!?TypedValue {
        const ip = inf.ip;
        const owner: hir.OwnerKey = if (inf.members[@backingInt(lhs_e)]) |m| m else switch (inf.body.expr(lhs_e)) {
            .name_ref => |n| blk: {
                const def = try inf.r.resolveName(inf.file, inf.item, inf.body, inf.body.expr_scopes[@backingInt(lhs_e)], n) orelse return null;
                break :blk try defKey(inf.r, def) orelse return null;
            },
            else => return null,
        };
        const body = try inf.r.ctx.get(hir.ItemBody, owner);
        const init = body.value orelse return null;
        switch (body.expr(init)) {
            .@"if", .@"switch" => {},
            else => return null,
        }
        const res = try inf.r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full });
        if (res.exprs.len != body.exprs.len) return null;
        var leaves: std.ArrayList(ExprId) = .empty;
        try branchLeaves(inf.scratch, body, init, &leaves, 0);
        for (leaves.items) |leaf| {
            const t = res.exprs[@backingInt(leaf)].asType() orelse continue;
            if (t == current or ip.key(t) != .container_type) continue;
            const ns = try queries.namespaceOfType(inf.r, t) orelse continue;
            const def = try inf.r.memberDef(ns, name) orelse continue;
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
                if (std.mem.eql(u8, name, "ptr")) return .{ .ty = try ip.ptrTo(p.child, .many, p.is_const) };
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
        const graph = try inf.r.ctx.get(database.ModuleGraph.Input, {}) orelse return null;
        var ns: Namespace = .{ .file = graph.std_root orelse return null, .container = 0 };
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
            .anytype_type => _ = try inf.infer(a, null),
            .runtime => {},
        };
        const inst = try instanceOf(inf.r, inf.scratch, g, f, try inf.argValues(callee_e, args, skip, g.body.params.len));
        const sig = try inf.r.ctx.get(queries.Infer, .{ .owner = g.owner, .mode = .signature, .inst = inst });
        // 其余实参按实例中的参数类型推导
        for (args, 0..) |a, i| if (g.kind(i + skip) == .runtime) {
            _ = try inf.infer(a, instParamType(sig, g.body, i + skip) orelse inf.concrete(paramType(f, i + skip)));
        };
        return inf.callResult(g, inst, sig, try inf.argValues(callee_e, args, skip, g.body.params.len));
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
            const tv = try eval.call(inf.r, inst, args);
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
        const tv = try eval.call(inf.r, inst, try inf.argValues(callee_e, args, skip, body.params.len));
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
            const tv = try eval.exprValue(inf.r, inf.file, inf.item, inf.body, e, inf.inst, inf.bindings, null);
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
        for (blk.stmts) |s| {
            last = try inf.stmt(s);
            if (last == .noreturn_type and !dead_rest) {
                dead_rest = true;
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
                try inf.bindCaptures(l.capture, cond, .if_then);
                try inf.bindCaptures(l.else_capture, cond, .if_else);
            },
            .@"for" => {
                for (l.inputs, 0..) |input, i| {
                    const elem: Index = switch (inf.body.expr(input)) {
                        // `a..b` / `0..`
                        .other => |range| blk: {
                            for (range) |x| _ = try inf.infer(x, .usize_type);
                            break :blk .usize_type;
                        },
                        else => inf.forElement((try inf.infer(input, null)).ty),
                    };
                    if (i < l.capture.len) {
                        const cap = l.capture[i];
                        const ptr = inf.body.binding(cap).is_ptr;
                        // 元素为类型（`inline for (.{ f32, f64 }) |T|`）：每次迭代的类型不同，与泛型函数的
                        // `comptime T: type` 一样按抽象参数推导
                        inf.bindings[@backingInt(cap)] = if (elem == .type_type and !ptr)
                            TypedValue.ofType(try ip.get(.{ .opaque_param = .{ .file = inf.file, .owner = inf.body_owner(), .binding = @backingInt(cap), .name = inf.body.binding(cap).name } }))
                        else
                            .{ .ty = if (ptr) try ip.ptrTo(elem, .one, false) else elem };
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
    fn bindCaptures(inf: *Inferrer, caps: []const Body.BindingId, cond_tv: TypedValue, source: CaptureSource) Error!void {
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
        inf.bindings[@backingInt(cap)] = .{ .ty = if (is_ptr) try ip.ptrTo(t, .one, false) else t, .val = val };
    }

    /// switch 的捕获。带标签的 union：捕获为各分支项对应字段类型的 peer（与编译器一致），`else` 分支与
    /// 求不出的分支项为 unknown；第二个捕获为标签
    fn bindSwitchCapture(inf: *Inferrer, prong: Body.Prong, operand: Index) Error!void {
        if (prong.capture.len == 0) return;
        const ip = inf.ip;
        const is_union = switch (ip.key(operand)) {
            .container_type => |c| c.kind == .@"union",
            .reified_type => |rt| rt.kind == .@"union",
            else => false,
        };
        const t: Index = if (is_union) try inf.prongPayloadType(prong, operand) else operand;
        const cap = prong.capture[0];
        inf.bindings[@backingInt(cap)] = .{ .ty = if (inf.body.binding(cap).is_ptr) try ip.ptrTo(t, .one, false) else t };
        if (prong.capture.len > 1) {
            const tag: Index = if (is_union) try eval.unionTag(inf.r, operand) orelse .unknown else .unknown;
            inf.bindings[@backingInt(prong.capture[1])] = .{ .ty = tag };
        }
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
                const rhs = try inf.inferBranch(rhs_e, if (child != .unknown) child else null, non_null == true);
                if (non_null) |n| return if (n) .{ .ty = child, .val = lhs.val } else rhs;
                return .{ .ty = try inf.peer(&.{ child, rhs.ty }) };
            },
            .keyword_and, .keyword_or => {
                const lhs = inf.condValue(try inf.infer(lhs_e, .bool_type));
                const rhs = inf.condValue(try inf.infer(rhs_e, .bool_type));
                const is_and = op == .keyword_and;
                // 短路：一侧已决定结果
                if (lhs) |l| if (l != is_and) return boolValue(l);
                if (rhs) |r| if (r != is_and) return boolValue(r);
                if (lhs != null and rhs != null) return boolValue(is_and);
                return .{ .ty = .bool_type };
            },
            .equal_equal, .bang_equal, .angle_bracket_left, .angle_bracket_right, .angle_bracket_left_equal, .angle_bracket_right_equal => {
                const lhs = try inf.infer(lhs_e, null);
                // 带标签的 union 与标签比较：另一侧不按 union 类型转换
                const is_union = switch (ip.key(lhs.ty)) {
                    .container_type => |c| c.kind == .@"union",
                    .reified_type => |rt| rt.kind == .@"union",
                    else => false,
                };
                const rhs = try inf.infer(rhs_e, if (lhs.ty != .unknown and lhs.ty != .comptime_int_type and !is_union) lhs.ty else null);
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
            // `<<` / `>>` 的右侧按 `Log2Int(T)` 推导，`<<|` 的右侧没有结果类型（与编译器一致）
            .angle_bracket_angle_bracket_left, .angle_bracket_angle_bracket_right, .angle_bracket_angle_bracket_left_pipe => {
                const lhs = try inf.infer(lhs_e, expected);
                const rhs = try inf.infer(rhs_e, if (op == .angle_bracket_angle_bracket_left_pipe) null else try inf.log2IntType(lhs.ty));
                return inf.foldInt(op, lhs.ty, lhs, rhs);
            },
            .plus_plus => return inf.concat(e, try inf.infer(lhs_e, null), try inf.infer(rhs_e, null)),
            // 指针运算（与编译器一致）：`[*]T ± usize` 仍为原指针类型，两个指针相减为 usize
            .plus, .minus => {
                const lhs = try inf.infer(lhs_e, expected);
                if (!isNonSlicePtr(ip, lhs.ty)) return inf.arith(op, lhs, rhs_e, expected);
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
            else => return inf.arith(op, try inf.infer(lhs_e, expected), rhs_e, expected),
        }
    }

    /// 算术与位运算：两侧 peer；两侧都是已知整数时按结果类型的位宽折叠
    fn arith(inf: *Inferrer, op: SyntaxKind, lhs: TypedValue, rhs_e: ExprId, expected: ?Index) Error!TypedValue {
        const rhs = try inf.infer(rhs_e, if (lhs.ty != .unknown and lhs.ty != .comptime_int_type) lhs.ty else expected);
        return inf.foldInt(op, try inf.peer(&.{ lhs.ty, rhs.ty }), lhs, rhs);
    }

    /// `++`（与编译器的 `zirArrayCat` 一致）：元组相接为元组；数组与指向数组的指针相接为数组，元素类型为两侧
    /// 元素类型的 peer，任一侧是指针时为 `*const [N]T`。两侧的值都已知时由解释器求值
    fn concat(inf: *Inferrer, e: ExprId, lhs: TypedValue, rhs: TypedValue) Error!TypedValue {
        const ty = try inf.concatType(lhs.ty, rhs.ty);
        if (ty == .unknown) return .unknown;
        if (lhs.val != null and rhs.val != null and inf.dead == 0 and !inf.r.ctx.incomplete()) {
            const tv = try eval.exprValue(inf.r, inf.file, inf.item, inf.body, e, inf.inst, inf.bindings, null);
            if (tv.val != null and tv.ty == ty) return tv;
        }
        return .{ .ty = ty };
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
        const array = try ip.get(.{ .array_type = .{ .len = x.len + y.len, .child = elem, .sentinel = eval.concatSentinel(xs, ys) } });
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
                return .{ .ty = try ip.ptrTo(v.ty, .one, try inf.isConstPlace(operand_e)) };
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
        // 字符串字面量（推导器不为字符串生成值；多行字符串在 HIR 中只保留第一行）
        switch (inf.body.expr(e)) {
            .literal => |text| if (text.len > 0 and text[0] == '"') {
                const str = std.zig.string_literal.parseAlloc(inf.scratch, text) catch return .unknown;
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
    fn slice(inf: *Inferrer, lhs_e: ExprId, start_e: ExprId, end_e: ?ExprId, sentinel_e: ?ExprId) Error!TypedValue {
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
            return .{ .ty = try ip.ptrTo(array, .one, src.is_const) };
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
                    .local => |l| b.binding(l.binding).kind != .local_var,
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
            // 整数之间：同符号取较宽者（位宽相同取前者），无符号且较窄时放入有符号，与编译器一致
            if (value.peerIntType(ip, cur, t)) |p| {
                result = p;
                continue;
            }
            // 浮点之间取位宽较大者（c_longdouble 的位宽取决于目标）
            if (ip.isFloat(cur) and ip.isFloat(t)) {
                const x = (value.typeLayout(ip, cur) orelse return .unknown).bits orelse return .unknown;
                const y = (value.typeLayout(ip, t) orelse return .unknown).bits orelse return .unknown;
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
fn tupleOf(ip: *InternPool, t: Index) ?InternPool.Tuple {
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

pub const ParamKind = enum { runtime, comptime_value, anytype_type };

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
    const body = try r.ctx.get(hir.ItemBody, owner);
    const all_comptime = try eval.isComptimeOnly(r, f.ret);
    const kinds = try scratch.alloc(ParamKind, body.params.len);
    var generic = all_comptime;
    for (body.params, kinds, 0..) |p, *k, i| {
        const b = body.binding(p);
        k.* = if (b.ty == null)
            .anytype_type
        else if (all_comptime or b.is_comptime or (i < f.params.len and value.isComptimeOnly(ip, f.params[i])))
            .comptime_value
        else
            .runtime;
        if (k.* != .runtime) generic = true;
    }
    if (!generic) return null;
    return .{ .owner = owner, .body = body, .parent = fv.inst, .kinds = kinds };
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

/// `@hasDecl`（只计 pub 声明）/ `@hasField`；类型不是源码中的容器时为 null
fn hasMember(r: *Resolver, t: Index, name: []const u8, decl: bool) Error!?bool {
    const ns = try queries.namespaceOfType(r, t) orelse return null;
    const tree = try r.itemTree(ns.file);
    if (!decl) return fieldItem(tree, ns.container, name) != null;
    const m = Resolver.lookupDecl(tree, ns.container, name) orelse return false;
    return tree.items[m].flags.is_pub;
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
