//! 表达式类型推导（设计 §9.3）：双向推导，期望类型从参数、返回值、类型标注、字段初始化下推；
//! 分支汇合处做 peer type resolution 的常用子集。未知部分为 `unknown`，吸收一切且不产生诊断。
//!
//! 类型表达式（`?*const T`、`[]u8`、`struct {...}`）也是表达式，求值得到 `type` 类型的值。
//! 不做 comptime 函数求值（M5）：泛型类型构造函数的调用、依赖 comptime 参数的返回类型为 unknown。

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

    pub fn eql(a: *const Result, b: *const Result) bool {
        return deepEql(a.exprs, b.exprs) and deepEql(a.bindings, b.bindings) and deepEql(a.members, b.members);
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

pub fn run(ctx: *Db.Ctx, owner: hir.OwnerKey, mode: Mode) Error!Result {
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
    };
    @memset(inf.exprs, .unknown);
    @memset(inf.bindings, .unknown);
    @memset(inf.members, null);
    try inf.runOwner(tree.items[item].kind, mode);
    return .{ .arena = arena.state, .exprs = inf.exprs, .bindings = inf.bindings, .members = inf.members };
}

fn empty(gpa: Allocator) Result {
    _ = gpa;
    return .{ .arena = .{}, .exprs = &.{}, .bindings = &.{}, .members = &.{} };
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

    const LabelFrame = struct { name: ?[]const u8, is_loop: bool, types: std.ArrayList(Index) = .empty };

    fn runOwner(inf: *Inferrer, kind: ItemTree.Item.Kind, mode: Mode) Error!void {
        const b = inf.body;
        switch (kind) {
            .@"fn" => {
                for (b.params) |p| inf.bindings[@backingInt(p)] = try inf.typeOfAnnotation(b.binding(p).ty);
                if (b.type_expr) |t| inf.ret_type = (try inf.infer(t, null)).asType();
                if (mode == .full) if (b.value) |v| {
                    _ = try inf.infer(v, null);
                };
            },
            .@"const", .@"var", .field => {
                const annotation: ?Index = if (b.type_expr) |t| (try inf.infer(t, null)).asType() else null;
                if (mode == .full) if (b.value) |v| {
                    _ = try inf.infer(v, annotation);
                };
            },
            .@"test", .@"comptime" => if (mode == .full) if (b.value) |v| {
                _ = try inf.infer(v, null);
            },
        }
    }

    /// 绑定的类型标注：求值得到类型；`anytype`（没有标注）为 unknown
    fn typeOfAnnotation(inf: *Inferrer, ty: ?ExprId) Error!TypedValue {
        const t = ty orelse return .unknown;
        const tv = try inf.infer(t, null);
        // `comptime T: type`：值未知的类型（M5 以抽象实例表示）
        return .{ .ty = tv.asType() orelse .unknown };
    }

    fn get(inf: *Inferrer, e: ExprId) TypedValue {
        return inf.exprs[@backingInt(e)];
    }

    pub fn infer(inf: *Inferrer, e: ExprId, expected: ?Index) Error!TypedValue {
        const i = @backingInt(e);
        if (inf.done.isSet(i)) return inf.exprs[i];
        inf.done.set(i);
        const raw = try inf.inferInner(e, expected);
        const tv = try inf.coerce(raw, expected);
        inf.exprs[i] = tv;
        return tv;
    }

    /// 结果类型转换：字面量类的值在有期望类型时取期望类型
    fn coerce(inf: *Inferrer, tv: TypedValue, expected: ?Index) Error!TypedValue {
        const want = expected orelse return tv;
        if (want == .unknown or tv.ty == want) return tv;
        const ip = inf.ip;
        switch (tv.ty) {
            .comptime_int_type, .comptime_float_type => if (ip.isInt(want) or ip.isFloat(want)) {
                const val: ?Index = if (tv.val) |v| switch (ip.key(v)) {
                    .int_value => |iv| try ip.get(.{ .int_value = .{ .ty = want, .value = iv.value } }),
                    else => null,
                } else null;
                return .{ .ty = want, .val = val };
            },
            .enum_literal_type => if (tv.val) |v| switch (ip.key(want)) {
                .container_type => |c| if (c.kind == .@"enum" or c.kind == .@"union") {
                    const name = ip.key(v).enum_literal;
                    return .{ .ty = want, .val = if (c.kind == .@"enum") try ip.get(.{ .enum_tag = .{ .ty = want, .name = name } }) else null };
                },
                else => {},
            },
            .null_type, .undefined_type => return .{ .ty = want, .val = tv.val },
            else => {},
        }
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
                try inf.bindCaptures(x.capture, cond.ty, .if_then);
                try inf.bindCaptures(x.else_capture, cond.ty, .if_else);
                const then = try inf.infer(x.then, expected);
                const other: TypedValue = if (x.@"else") |el| try inf.infer(el, expected) else .{ .ty = .void_type };
                return .{ .ty = try inf.peer(&.{ then.ty, other.ty }) };
            },
            .loop => |l| return inf.loop(l, expected),
            .@"switch" => |s| {
                const operand = try inf.infer(s.operand, null);
                var types: std.ArrayList(Index) = .empty;
                for (s.prongs) |prong| {
                    for (prong.items) |item| _ = try inf.infer(item, operand.ty);
                    try inf.bindSwitchCapture(prong, operand.ty);
                    try types.append(inf.scratch, (try inf.infer(prong.body, expected)).ty);
                }
                return .{ .ty = try inf.peer(types.items) };
            },
            .@"catch" => |c| {
                const lhs = try inf.infer(c.lhs, null);
                const payload, const err = inf.unwrapErrorUnion(lhs.ty);
                if (c.capture) |cap| inf.bindings[@backingInt(cap)] = .{ .ty = err };
                const rhs = try inf.infer(c.rhs, if (payload != .unknown) payload else null);
                return .{ .ty = try inf.peer(&.{ payload, rhs.ty }) };
            },
            .binary => |bin| return inf.binary(bin.op, bin.lhs, bin.rhs, expected),
            .prefix => |p| return inf.prefix(p.op, p.operand, expected),
            .assign => |a| {
                const lhs = try inf.infer(a.lhs, null);
                _ = try inf.infer(a.rhs, if (lhs.ty != .unknown) lhs.ty else null);
                return .{ .ty = .void_type };
            },
            .index => |x| {
                const lhs = try inf.infer(x.lhs, null);
                _ = try inf.infer(x.index, .usize_type);
                return .{ .ty = inf.elementType(lhs.ty) };
            },
            .slice => |s| {
                const lhs = try inf.infer(s.lhs, null);
                _ = try inf.infer(s.start, .usize_type);
                if (s.end) |end| _ = try inf.infer(end, .usize_type);
                if (s.sentinel) |sen| _ = try inf.infer(sen, null);
                const elem = inf.elementType(lhs.ty);
                return .{ .ty = try ip.ptrTo(elem, .slice, inf.isConstPtr(lhs.ty)) };
            },
            .deref => |x| {
                const p = try inf.infer(x, null);
                return .{ .ty = switch (ip.key(p.ty)) {
                    .ptr_type => |pt| if (pt.size == .one) pt.child else .unknown,
                    else => .unknown,
                } };
            },
            .unwrap_optional => |x| {
                const o = try inf.infer(x, null);
                return .{ .ty = switch (ip.key(o.ty)) {
                    .optional_type => |c| c,
                    else => .unknown,
                } };
            },
            .init => |x| return inf.initExpr(x.ty, x.fields, expected),
            .container => {
                const ns = try inf.containerAt(e) orelse return .unknown;
                return TypedValue.ofType(try queries.containerType(inf.r, ns));
            },
            .fn_type => |f| {
                const params = try inf.scratch.alloc(Index, f.params.len);
                for (f.params, params) |p, *out| out.* = (try inf.infer(p, null)).asType() orelse .unknown;
                const ret = if (f.ret) |r| (try inf.infer(r, null)).asType() orelse .unknown else .unknown;
                return TypedValue.ofType(try ip.get(.{ .fn_type = .{ .params = params, .ret = ret } }));
            },
            .@"return" => |v| {
                if (v) |x| _ = try inf.infer(x, inf.ret_type);
                return .{ .ty = .noreturn_type };
            },
            .@"break" => |br| {
                const value: TypedValue = if (br.value) |v| try inf.infer(v, null) else .{ .ty = .void_type };
                if (inf.labelFrame(br.label, true)) |frame| try frame.types.append(inf.scratch, value.ty);
                return .{ .ty = .noreturn_type };
            },
            .@"continue" => |c| {
                if (c.value) |v| _ = try inf.infer(v, null);
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
                return TypedValue.ofType(try ip.ptrTo(child, @fromBackingInt(@intCast(@backingInt(p.size))), p.is_const));
            },
            .array_type => |arr| {
                const len = try inf.infer(arr.len, .usize_type);
                const child = (try inf.infer(arr.child, null)).asType() orelse return typeUnknown();
                const n: u64 = if (len.val) |v| switch (ip.key(v)) {
                    .int_value => |iv| std.math.cast(u64, iv.value) orelse return typeUnknown(),
                    else => return typeUnknown(),
                } else return typeUnknown();
                return TypedValue.ofType(try ip.get(.{ .array_type = .{ .len = n, .child = child } }));
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
        return queries.defType(inf.r, def, .{ .file = inf.file, .item = inf.item, .bindings = inf.bindings });
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
                const value: ?i128 = switch (c) {
                    .success => |v| v,
                    .failure => null,
                };
                return .{ .ty = .comptime_int_type, .val = if (value) |v| try ip.get(.{ .int_value = .{ .ty = .comptime_int_type, .value = v } }) else null };
            },
            else => switch (std.zig.parseNumberLiteral(text)) {
                .int => |v| return .{ .ty = .comptime_int_type, .val = try ip.get(.{ .int_value = .{ .ty = .comptime_int_type, .value = v } }) },
                .big_int => return .{ .ty = .comptime_int_type },
                .float => return .{ .ty = .comptime_float_type },
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
                    const def = try inf.r.memberDef(ns, name) orelse return .unknown;
                    inf.members[@backingInt(e)] = try defKey(inf.r, def);
                    return queries.defType(inf.r, def, null);
                },
                .error_set_type => return .{ .ty = t, .val = try ip.get(.{ .error_value = name }) },
                else => return .unknown,
            }
        }
        // 实例上的成员：自动解引用单指针
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
                    return .{ .ty = (try queries.defType(inf.r, .{ .item = .{ .file = ns.file, .item = f } }, null)).ty };
                }
                // 方法
                const def = try inf.r.memberDef(ns, name) orelse return .unknown;
                inf.members[@backingInt(e)] = try defKey(inf.r, def);
                const tv = try queries.defType(inf.r, def, null);
                if (ip.key(tv.ty) == .fn_type) try inf.bound.put(inf.scratch, e, {});
                return tv;
            },
            .array_type => |arr| if (std.mem.eql(u8, name, "len")) {
                return .{ .ty = .usize_type, .val = try ip.get(.{ .int_value = .{ .ty = .usize_type, .value = arr.len } }) };
            },
            .ptr_type => |p| if (p.size == .slice) {
                if (std.mem.eql(u8, name, "len")) return .{ .ty = .usize_type };
                if (std.mem.eql(u8, name, "ptr")) return .{ .ty = try ip.ptrTo(p.child, .many, p.is_const) };
            },
            else => {},
        }
        return .unknown;
    }

    /// decl literal：结果类型为容器时，`.name` 是该类型的声明 `T.name`（枚举优先取同名成员）
    fn declLiteral(inf: *Inferrer, e: ExprId, want: Index, name: []const u8) Error!?TypedValue {
        const c = switch (inf.ip.key(want)) {
            .container_type => |c| c,
            else => return null,
        };
        const ns = try queries.namespaceOfType(inf.r, want) orelse return null;
        if (c.kind == .@"enum") {
            const tree = try inf.r.itemTree(ns.file);
            if (fieldItem(tree, ns.container, name) != null) return null;
        }
        const tree = try inf.r.itemTree(ns.file);
        const m = Resolver.lookupDecl(tree, ns.container, name) orelse return null;
        const def: resolve.Def = .{ .item = .{ .file = ns.file, .item = m } };
        inf.members[@backingInt(e)] = try defKey(inf.r, def);
        return try queries.defType(inf.r, def, null);
    }

    // ── 调用 ─────────────────────────────────────────────────────────

    fn call(inf: *Inferrer, callee_e: ExprId, args: []const ExprId, expected: ?Index) Error!TypedValue {
        // `.init(...)`：decl literal 在结果类型中查找
        const callee = try inf.infer(callee_e, if (inf.body.expr(callee_e) == .enum_literal) expected else null);
        const f = switch (inf.ip.key(callee.ty)) {
            .fn_type => |f| f,
            else => {
                for (args) |a| _ = try inf.infer(a, null);
                return .unknown;
            },
        };
        const skip: usize = if (inf.bound.contains(callee_e)) 1 else 0;
        for (args, 0..) |a, i| {
            const p: ?Index = if (i + skip < f.params.len and f.params[i + skip] != .unknown) f.params[i + skip] else null;
            _ = try inf.infer(a, p);
        }
        return .{ .ty = f.ret };
    }

    fn builtin(inf: *Inferrer, e: ExprId, name: []const u8, args: []const ExprId, expected: ?Index) Error!TypedValue {
        const ip = inf.ip;
        const eq = std.mem.eql;
        if (eq(u8, name, "@import")) {
            const target = try inf.r.importTarget(inf.file, inf.body, args) orelse return .unknown;
            return TypedValue.ofType(try queries.containerType(inf.r, .{ .file = target, .container = 0 }));
        }
        if (eq(u8, name, "@This")) {
            const tree = try inf.r.itemTree(inf.file);
            return TypedValue.ofType(try queries.containerType(inf.r, .{ .file = inf.file, .container = tree.items[inf.item].container }));
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
        if (eq(u8, name, "@field")) {
            if (args.len != 2) return .unknown;
            _ = try inf.infer(args[1], null);
            const field = switch (inf.body.expr(args[1])) {
                .literal => |text| std.zig.string_literal.parseAlloc(inf.scratch, text) catch null,
                else => null,
            };
            const tv = try inf.fieldAccess(e, args[0], field);
            return tv;
        }
        for (args) |a| _ = try inf.infer(a, null);
        // 结果类型由期望类型决定的转换
        const result_typed = [_][]const u8{ "@intCast", "@truncate", "@floatCast", "@floatFromInt", "@intFromFloat", "@ptrCast", "@alignCast", "@constCast", "@volatileCast", "@enumFromInt", "@errorCast", "@bitCast", "@fieldParentPtr", "@ptrFromInt", "@splat", "@errSetCast", "@addrSpaceCast" };
        for (result_typed) |n| if (eq(u8, name, n)) return .{ .ty = expected orelse .unknown };
        const simple = [_]struct { []const u8, Index }{
            .{ "@sizeOf", .comptime_int_type },
            .{ "@alignOf", .comptime_int_type },
            .{ "@bitSizeOf", .comptime_int_type },
            .{ "@offsetOf", .comptime_int_type },
            .{ "@bitOffsetOf", .comptime_int_type },
            .{ "@intFromPtr", .usize_type },
            .{ "@intFromBool", .u1_type },
            .{ "@hasDecl", .bool_type },
            .{ "@hasField", .bool_type },
            .{ "@inComptime", .bool_type },
            .{ "@panic", .noreturn_type },
            .{ "@compileError", .noreturn_type },
            .{ "@trap", .noreturn_type },
            .{ "@memcpy", .void_type },
            .{ "@memset", .void_type },
            .{ "@memmove", .void_type },
            .{ "@setEvalBranchQuota", .void_type },
            .{ "@setRuntimeSafety", .void_type },
            .{ "@breakpoint", .void_type },
            .{ "@compileLog", .void_type },
            .{ "@export", .void_type },
            .{ "@prefetch", .void_type },
            .{ "@setFloatMode", .void_type },
        };
        for (simple) |s| if (eq(u8, name, s[0])) return .{ .ty = s[1] };
        if (eq(u8, name, "@tagName") or eq(u8, name, "@errorName") or eq(u8, name, "@typeName")) {
            const sentinel = try ip.get(.{ .int_value = .{ .ty = .u8_type, .value = 0 } });
            return .{ .ty = try ip.get(.{ .ptr_type = .{ .child = .u8_type, .size = .slice, .is_const = true, .sentinel = sentinel } }) };
        }
        // 结果与第一个参数同类型
        const same = [_][]const u8{ "@abs", "@sqrt", "@sin", "@cos", "@tan", "@exp", "@exp2", "@log", "@log2", "@log10", "@floor", "@ceil", "@trunc", "@round", "@byteSwap", "@bitReverse", "@min", "@max", "@mod", "@rem", "@divExact", "@divFloor", "@divTrunc", "@shlExact", "@shrExact" };
        for (same) |n| if (eq(u8, name, n)) {
            if (args.len == 0) return .unknown;
            var types: std.ArrayList(Index) = .empty;
            for (args) |a| try types.append(inf.scratch, inf.get(a).ty);
            return .{ .ty = if (eq(u8, name, "@min") or eq(u8, name, "@max")) try inf.peer(types.items) else inf.get(args[0]).ty };
        };
        return .unknown;
    }

    // ── 块与控制流 ───────────────────────────────────────────────────

    fn block(inf: *Inferrer, blk: Body.Block, expected: ?Index) Error!TypedValue {
        try inf.labels.append(inf.scratch, .{ .name = blk.label, .is_loop = false });
        var last: Index = .void_type;
        for (blk.stmts) |s| last = try inf.stmt(s);
        const frame = inf.labels.pop().?;
        if (blk.label != null) {
            var types = frame.types;
            if (last != .noreturn_type) try types.append(inf.scratch, .void_type);
            const t = try inf.peer(types.items);
            _ = expected;
            return .{ .ty = t };
        }
        return .{ .ty = if (last == .noreturn_type) .noreturn_type else .void_type };
    }

    fn stmt(inf: *Inferrer, s: Body.Stmt) Error!Index {
        switch (s.kind) {
            .expr => |e| return (try inf.infer(e, null)).ty,
            .local => |b| {
                const binding = inf.body.binding(b);
                const annotation: ?Index = if (binding.ty) |t| (try inf.infer(t, null)).asType() orelse .unknown else null;
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
                _ = try inf.infer(d.value, null);
                for (d.targets) |t| switch (t) {
                    .binding => |b| inf.bindings[@backingInt(b)] = if (inf.body.binding(b).ty) |ty| .{ .ty = (try inf.infer(ty, null)).asType() orelse .unknown } else .unknown,
                    .expr => |x| _ = try inf.infer(x, null),
                };
                return .void_type;
            },
        }
    }

    fn loop(inf: *Inferrer, l: Body.Loop, expected: ?Index) Error!TypedValue {
        _ = expected;
        const ip = inf.ip;
        switch (l.kind) {
            .@"while" => {
                const cond = try inf.infer(l.inputs[0], null);
                try inf.bindCaptures(l.capture, cond.ty, .if_then);
                try inf.bindCaptures(l.else_capture, cond.ty, .if_else);
            },
            .@"for" => {
                for (l.inputs, 0..) |input, i| {
                    const elem: Index = switch (inf.body.expr(input)) {
                        // `a..b` / `0..`
                        .other => |range| blk: {
                            for (range) |x| _ = try inf.infer(x, .usize_type);
                            break :blk .usize_type;
                        },
                        else => inf.elementType((try inf.infer(input, null)).ty),
                    };
                    if (i < l.capture.len) {
                        const cap = l.capture[i];
                        const ptr = inf.body.binding(cap).is_ptr;
                        inf.bindings[@backingInt(cap)] = .{ .ty = if (ptr) try ip.ptrTo(elem, .one, false) else elem };
                    }
                }
            },
        }
        if (l.cont) |c| _ = try inf.infer(c, null);
        try inf.labels.append(inf.scratch, .{ .name = l.label, .is_loop = true });
        _ = try inf.infer(l.body, null);
        var frame = inf.labels.pop().?;
        const other: Index = if (l.@"else") |el| (try inf.infer(el, null)).ty else .void_type;
        try frame.types.append(inf.scratch, other);
        return .{ .ty = try inf.peer(frame.types.items) };
    }

    fn labelFrame(inf: *Inferrer, label: ?[]const u8, for_break: bool) ?*LabelFrame {
        _ = for_break;
        var i = inf.labels.items.len;
        while (i > 0) {
            i -= 1;
            const f = &inf.labels.items[i];
            if (label) |name| {
                if (f.name != null and std.mem.eql(u8, f.name.?, name)) return f;
            } else if (f.is_loop) return f;
        }
        return null;
    }

    const CaptureSource = enum { if_then, if_else };

    /// if / while 的捕获：optional 取子类型，error union 取载荷（else 分支取错误集）
    fn bindCaptures(inf: *Inferrer, caps: []const Body.BindingId, cond: Index, source: CaptureSource) Error!void {
        if (caps.len == 0) return;
        const ip = inf.ip;
        const t: Index = switch (ip.key(cond)) {
            .optional_type => |c| if (source == .if_then) c else .unknown,
            .error_union_type => |eu| if (source == .if_then) eu.payload else eu.err,
            else => .unknown,
        };
        const cap = caps[0];
        inf.bindings[@backingInt(cap)] = .{ .ty = if (inf.body.binding(cap).is_ptr) try ip.ptrTo(t, .one, false) else t };
    }

    fn bindSwitchCapture(inf: *Inferrer, prong: Body.Prong, operand: Index) Error!void {
        if (prong.capture.len == 0) return;
        const ip = inf.ip;
        var t: Index = operand;
        // 带标签的 union：单个分支项时捕获对应字段的类型
        if (ip.key(operand) == .container_type and ip.key(operand).container_type.kind == .@"union" and prong.items.len == 1) {
            if (inf.body.expr(prong.items[0]) == .enum_literal) {
                const name = inf.body.expr(prong.items[0]).enum_literal;
                const ns = try queries.namespaceOfType(inf.r, operand);
                t = .unknown;
                if (ns) |n| {
                    const tree = try inf.r.itemTree(n.file);
                    if (fieldItem(tree, n.container, name)) |f| t = (try queries.defType(inf.r, .{ .item = .{ .file = n.file, .item = f } }, null)).ty;
                }
            } else t = .unknown;
        } else if (ip.key(operand) == .container_type and ip.key(operand).container_type.kind == .@"union") t = .unknown;
        const cap = prong.capture[0];
        inf.bindings[@backingInt(cap)] = .{ .ty = if (inf.body.binding(cap).is_ptr) try ip.ptrTo(t, .one, false) else t };
        if (prong.capture.len > 1) inf.bindings[@backingInt(prong.capture[1])] = .{ .ty = .unknown };
    }

    // ── 运算 ─────────────────────────────────────────────────────────

    fn binary(inf: *Inferrer, op: SyntaxKind, lhs_e: ExprId, rhs_e: ExprId, expected: ?Index) Error!TypedValue {
        switch (op) {
            .keyword_orelse => {
                const lhs = try inf.infer(lhs_e, null);
                const child: Index = switch (inf.ip.key(lhs.ty)) {
                    .optional_type => |c| c,
                    else => .unknown,
                };
                const rhs = try inf.infer(rhs_e, if (child != .unknown) child else null);
                return .{ .ty = try inf.peer(&.{ child, rhs.ty }) };
            },
            .keyword_and, .keyword_or => {
                _ = try inf.infer(lhs_e, .bool_type);
                _ = try inf.infer(rhs_e, .bool_type);
                return .{ .ty = .bool_type };
            },
            .equal_equal, .bang_equal, .angle_bracket_left, .angle_bracket_right, .angle_bracket_left_equal, .angle_bracket_right_equal => {
                const lhs = try inf.infer(lhs_e, null);
                _ = try inf.infer(rhs_e, if (lhs.ty != .unknown and lhs.ty != .comptime_int_type) lhs.ty else null);
                return .{ .ty = .bool_type };
            },
            .angle_bracket_angle_bracket_left, .angle_bracket_angle_bracket_right, .angle_bracket_angle_bracket_left_pipe => {
                const lhs = try inf.infer(lhs_e, expected);
                _ = try inf.infer(rhs_e, null);
                return .{ .ty = lhs.ty };
            },
            .plus_plus => {
                _ = try inf.infer(lhs_e, null);
                _ = try inf.infer(rhs_e, null);
                return .unknown;
            },
            // 错误集合并
            .pipe_pipe => {
                const lhs = (try inf.infer(lhs_e, null)).asType() orelse .unknown;
                const rhs = (try inf.infer(rhs_e, null)).asType() orelse .unknown;
                const ip = inf.ip;
                if (ip.key(lhs) != .error_set_type or ip.key(rhs) != .error_set_type) return typeUnknown();
                const names = try std.mem.concat(inf.scratch, []const u8, &.{ ip.key(lhs).error_set_type, ip.key(rhs).error_set_type });
                return TypedValue.ofType(try ip.errorSet(inf.scratch, names));
            },
            else => {
                // 算术与位运算：两侧 peer
                const lhs = try inf.infer(lhs_e, expected);
                const rhs = try inf.infer(rhs_e, if (lhs.ty != .unknown and lhs.ty != .comptime_int_type) lhs.ty else expected);
                return .{ .ty = try inf.peer(&.{ lhs.ty, rhs.ty }) };
            },
        }
    }

    fn prefix(inf: *Inferrer, op: SyntaxKind, operand_e: ExprId, expected: ?Index) Error!TypedValue {
        const ip = inf.ip;
        switch (op) {
            .keyword_try => {
                const v = try inf.infer(operand_e, null);
                const payload, _ = inf.unwrapErrorUnion(v.ty);
                return .{ .ty = payload };
            },
            .bang => {
                _ = try inf.infer(operand_e, .bool_type);
                return .{ .ty = .bool_type };
            },
            .ampersand => {
                const child_expected: ?Index = if (expected) |x| switch (ip.key(x)) {
                    .ptr_type => |p| if (p.size == .one) p.child else null,
                    else => null,
                } else null;
                const v = try inf.infer(operand_e, child_expected);
                return .{ .ty = try ip.ptrTo(v.ty, .one, try inf.isConstPlace(operand_e)) };
            },
            else => return .{ .ty = (try inf.infer(operand_e, expected)).ty },
        }
    }

    fn initExpr(inf: *Inferrer, ty_e: ?ExprId, fields: []const Body.FieldInit, expected: ?Index) Error!TypedValue {
        const ip = inf.ip;
        const t: Index = if (ty_e) |te| (try inf.infer(te, null)).asType() orelse .unknown else expected orelse .unknown;
        const ns: ?Namespace = if (t != .unknown and ip.key(t) == .container_type) try queries.namespaceOfType(inf.r, t) else null;
        const elem: ?Index = switch (ip.key(t)) {
            .array_type => |a| a.child,
            else => null,
        };
        for (fields) |f| {
            var field_ty: ?Index = elem;
            if (f.name) |name| if (ns) |n| {
                const tree = try inf.r.itemTree(n.file);
                if (fieldItem(tree, n.container, name)) |fi| field_ty = (try queries.defType(inf.r, .{ .item = .{ .file = n.file, .item = fi } }, null)).ty;
            };
            _ = try inf.infer(f.value, if (field_ty) |x| (if (x != .unknown) x else null) else null);
        }
        return .{ .ty = t };
    }

    // ── 类型工具 ─────────────────────────────────────────────────────

    /// 数组、切片、多项指针、指向数组的指针的元素类型
    fn elementType(inf: *Inferrer, t: Index) Index {
        const ip = inf.ip;
        return switch (ip.key(t)) {
            .array_type => |a| a.child,
            .ptr_type => |p| switch (p.size) {
                .slice, .many, .c => p.child,
                .one => switch (ip.key(p.child)) {
                    .array_type => |a| a.child,
                    else => .unknown,
                },
            },
            else => .unknown,
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
            // T 与 ?T
            if (ip.key(cur) == .optional_type and ip.key(cur).optional_type == t) continue;
            if (ip.key(t) == .optional_type and ip.key(t).optional_type == cur) {
                result = t;
                continue;
            }
            // 指针 const 合并
            if (ip.key(cur) == .ptr_type and ip.key(t) == .ptr_type) {
                var a = ip.key(cur).ptr_type;
                const b = ip.key(t).ptr_type;
                if (a.child == b.child and a.size == b.size) {
                    a.is_const = a.is_const or b.is_const;
                    result = try ip.get(.{ .ptr_type = a });
                    continue;
                }
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
        const tree = try inf.r.itemTree(inf.file);
        const owner = try inf.r.itemNode(inf.file, inf.item) orelse return null;
        const map = try inf.r.ctx.get(syntax.FileAstIdMap, inf.file);
        const rel = inf.body.range(e).start;
        for (tree.containers, 0..) |c, i| {
            if (c.parent_item != inf.item) continue;
            const node = map.get(c.ast_id) orelse continue;
            if (node.offset == owner.offset + rel) return .{ .file = inf.file, .container = @intCast(i) };
        }
        return null;
    }
};

fn typeUnknown() TypedValue {
    return .{ .ty = .type_type };
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
