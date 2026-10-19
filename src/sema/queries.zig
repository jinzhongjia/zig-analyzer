//! sema query：声明类型与 Body 的类型推导。

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const database = @import("../database.zig");
const Db = database.Db;
const hir = database.hir;
const InternPool = @import("InternPool.zig");
const Index = InternPool.Index;
const TypedValue = InternPool.TypedValue;
const infer = @import("infer.zig");
const eval = @import("eval.zig");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Namespace = resolve.Namespace;
const ast = @import("../syntax/ast.zig");
const ItemTree = @import("../syntax/ItemTree.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const Body = @import("../hir/Body.zig");
const mem = @import("../util/mem.zig");

/// 与目标相关的值运算参数：指针位宽，向量、整数、浮点与 C 类型的布局规则（各模块一致的部分）。值同时存于
/// InternPool 供值的运算读取，用到值运算的 query 先读本 input 以记录依赖
pub const TargetAbi = struct {
    pub const kind: engine.Kind = .input;
    pub const Key = void;
    pub const Value = InternPool.Target;
    pub const default: Value = .{};
};

pub const InferKey = struct {
    owner: hir.OwnerKey,
    mode: infer.Mode,
    /// owner 自身或其外层泛型函数的实例（已规范化，见 `normalizeInst`）；null 为非泛型或抽象实例
    inst: ?Index = null,
    /// 遍历类型列表的循环的循环变量按某次迭代取值（IDE 功能为循环体选实例时用）；null 时循环变量是抽象的
    loop: ?infer.LoopSeed = null,
};

pub const DeclKey = struct {
    owner: hir.OwnerKey,
    inst: ?Index = null,
};

/// BodyOwner 的类型推导结果。签名模式不读取函数体与初始化表达式，
/// 只改这些内容时依赖签名的 query 不必重算
pub const Infer = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = InferKey;
    pub const Value = *const infer.Result;
    /// 约束长时间会话的内存（泛型实例的结果会不断累积）：被淘汰的结果按需重新推导
    pub const lru = 16 * 1024;
    /// 值的大小差别很大（长函数的 HIR / 推导结果可达数百 KB），同时按字节数限制
    pub const lru_bytes = 48 * 1024 * 1024;

    pub fn bytes(v: Value) usize {
        if (v == &empty_result) return 0;
        return @sizeOf(infer.Result) + mem.arenaBytes(v.arena);
    }

    pub fn compute(ctx: *Db.Ctx, key: Key) engine.Error!Value {
        _ = try ctx.get(TargetAbi, {});
        const gpa = ctx.db.gpa;
        const result = try gpa.create(infer.Result);
        errdefer gpa.destroy(result);
        result.* = try infer.run(ctx, key.owner, key.mode, key.inst, key.loop);
        return result;
    }

    pub fn cycleFallback(_: Key) Value {
        return &empty_result;
    }

    pub fn eql(a: Value, b: Value) bool {
        return a.eql(b);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        if (v.* == &empty_result) return;
        const r: *infer.Result = @constCast(v.*);
        r.deinit(gpa);
        gpa.destroy(r);
    }
};

const empty_result: infer.Result = .{ .arena = .{}, .exprs = &.{}, .bindings = &.{}, .members = &.{}, .ret = .unknown };

/// 声明的类型；const 的值 comptime 已知时附带值（如 `const S = struct {...}` 的值为类型 S）
pub const DeclType = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = DeclKey;
    pub const Value = TypedValue;

    pub fn compute(ctx: *Db.Ctx, dk: Key) engine.Error!Value {
        _ = try ctx.get(TargetAbi, {});
        const key = dk.owner;
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        const ip = ctx.db.env.ip;
        const tree = try r.itemTree(key.file);
        const item: u32 = for (tree.items, 0..) |it, i| {
            if (it.ast_id == key.item) break @intCast(i);
        } else return .unknown;
        const b = try ctx.get(hir.ItemBody, key);
        switch (tree.items[item].kind) {
            .@"fn" => {
                const res = try ctx.get(Infer, .{ .owner = key, .mode = .signature, .inst = dk.inst });
                if (res.exprs.len == 0) return .unknown;
                // 绑定的参数（含 anytype 与无名参数）按顺序，`...` 没有绑定、只能在末尾（见 ItemTree 的 `varargs`）
                var params: std.ArrayList(Index) = .empty;
                for (b.params) |p| try params.append(r.arena, res.bindings[@backingInt(p)].ty);
                const varargs = tree.items[item].flags.varargs;
                const ty = try ip.get(.{ .fn_type = .{ .params = params.items, .ret = try returnType(&r, key, b, res, dk.inst), .varargs = varargs } });
                return .{ .ty = ty, .val = try ip.get(.{ .fn_value = .{ .ty = ty, .file = key.file, .decl = key.item, .inst = dk.inst } }) };
            },
            .@"const", .@"var" => {
                const res = try ctx.get(Infer, .{ .owner = key, .mode = .full, .inst = dk.inst });
                if (res.exprs.len == 0) return .unknown;
                const annotation: ?Index = if (b.type_expr) |t| res.exprs[@backingInt(t)].asType() orelse .unknown else null;
                var value: TypedValue = if (b.value) |v| res.exprs[@backingInt(v)] else .unknown;
                const is_const = tree.items[item].kind == .@"const";
                // 容器级常量在 comptime 求值：推导求不出值时由解释器执行初始化表达式
                if (is_const and value.val == null and b.value != null and !ctx.incomplete()) {
                    const ev = try eval.ownerValue(&r, key, dk.inst, annotation);
                    if (ev.val != null and (value.ty == .unknown or ev.ty == value.ty or annotation != null)) value = ev;
                }
                if (annotation) |t| return .{ .ty = t, .val = if (is_const and value.ty == t) value.val else null };
                return if (is_const) value else .{ .ty = value.ty };
            },
            .field => {
                const container = tree.items[item].container;
                if (tree.containers[container].kind == .@"enum") {
                    const ty = try containerType(&r, .{ .file = key.file, .container = container }, dk.inst);
                    return .{ .ty = ty, .val = try ip.get(.{ .enum_tag = .{ .ty = ty, .name = tree.items[item].name orelse "" } }) };
                }
                // union 中只写名字的字段（`union(enum) { a: u8, b }` 的 `b`）类型为 void
                if (b.type_expr == null and tree.containers[container].kind == .@"union") return .{ .ty = .void_type };
                const res = try ctx.get(Infer, .{ .owner = key, .mode = .signature, .inst = dk.inst });
                if (res.exprs.len == 0) return .unknown;
                return .{ .ty = if (b.type_expr) |t| res.exprs[@backingInt(t)].asType() orelse .unknown else .unknown };
            },
            .@"test", .@"comptime" => return .{ .ty = .void_type },
        }
    }

    pub fn cycleFallback(_: Key) Value {
        return .unknown;
    }
};

/// 函数在签名推导结果 `sig`（实例 `inst`）中的返回类型。`!T` 的错误集是由函数体推导的错误集，
/// 签名中只记录标记（不读取函数体），成员由 `ErrorSetOf` 求出
pub fn returnType(r: *Resolver, owner: hir.OwnerKey, body: *const Body, sig: *const infer.Result, inst: ?Index) resolve.Error!Index {
    const t = body.type_expr orelse return .unknown;
    if (@backingInt(t) >= sig.exprs.len) return .unknown;
    const ret = sig.exprs[@backingInt(t)].asType() orelse return .unknown;
    if (ret == .unknown or !try inferredErrorSet(r, owner)) return ret;
    const ip = r.ctx.db.env.ip;
    const set = try ip.get(.{ .inferred_error_set = .{ .file = owner.file, .decl = owner.item, .inst = inst } });
    return ip.get(.{ .error_union_type = .{ .err = set, .payload = ret } });
}

/// 成员中不编译的代码的范围：`Infer` 的 `inactive` 与 `dead_spans`（相对成员起点，按位置排序）。
/// 非活动代码需要文件中全部成员的推导结果，大文件的 `Infer` 结果超出 LRU 的上限，每次发布都要重算被淘汰的
/// 部分；这里只保留区间，依赖未变时即使 `Infer` 的值已被淘汰也不必重算
pub const InactiveRanges = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = hir.OwnerKey;
    pub const Value = []const Range;

    pub const Range = struct { start: u32, end: u32 };

    pub fn compute(ctx: *Db.Ctx, key: Key) engine.Error!Value {
        const res = try ctx.get(Infer, .{ .owner = key, .mode = .full });
        if (res.inactive.len == 0 and res.dead_spans.len == 0) return &.{};
        const body = try ctx.get(hir.ItemBody, key);
        var out: std.ArrayList(Range) = .empty;
        errdefer out.deinit(ctx.db.gpa);
        for (res.inactive) |e| {
            const rg = body.range(e);
            if (rg.end > rg.start) try out.append(ctx.db.gpa, .{ .start = rg.start, .end = rg.end });
        }
        for (res.dead_spans) |rg| if (rg.end > rg.start) try out.append(ctx.db.gpa, .{ .start = rg.start, .end = rg.end });
        std.mem.sort(Range, out.items, {}, struct {
            fn lt(_: void, a: Range, b: Range) bool {
                return a.start < b.start;
            }
        }.lt);
        return out.toOwnedSlice(ctx.db.gpa);
    }

    pub fn eql(a: Value, b: Value) bool {
        return std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b));
    }

    pub fn bytes(v: Value) usize {
        return v.len * @sizeOf(Range);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        gpa.free(v.*);
    }
};

/// 推导的错误集的成员：函数体中 `return` 的错误与 `try` 传播的错误，含未知部分时为 anyerror。
/// 递归的函数取最小不动点（与编译器一致；编译器不允许相互递归，这里同样取各函数错误的并集）
pub const ErrorSetOf = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = DeclKey;
    pub const Value = Index;
    /// 函数体只把被调函数的错误并入结果：环中对自身的读取先视为空集，环的入口算一遍即得完整结果
    pub const fixpoint = true;

    pub fn compute(ctx: *Db.Ctx, key: Key) engine.Error!Value {
        _ = try ctx.get(TargetAbi, {});
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        const ip = ctx.db.env.ip;
        const body = try ctx.get(hir.ItemBody, key.owner);
        const res = try ctx.get(Infer, .{ .owner = key.owner, .mode = .full, .inst = key.inst });
        if (res.exprs.len != body.exprs.len) return .anyerror_type;
        var names: std.ArrayList([]const u8) = .empty;
        for (body.exprs) |e| {
            const t: Index = switch (e) {
                .@"return" => |v| if (v) |x| res.exprs[@backingInt(x)].ty else continue,
                .prefix => |p| if (p.op == .keyword_try) res.exprs[@backingInt(p.operand)].ty else continue,
                else => continue,
            };
            if (!try collectErrors(&r, t, &names, e == .prefix)) return .anyerror_type;
        }
        return ip.errorSet(r.arena, names.items);
    }

    pub fn cycleFallback(_: Key) Value {
        return .empty_error_set;
    }

    pub fn depthFallback(_: Key) Value {
        return .anyerror_type;
    }
};

/// 类型中可能出现的错误（错误集、error union 的错误集）加入 `names`；含 anyerror 或未知时返回 false。
/// `required` 时类型必须带有错误（`try` 的操作数）
fn collectErrors(r: *Resolver, t: Index, names: *std.ArrayList([]const u8), required: bool) resolve.Error!bool {
    const ip = r.ctx.db.env.ip;
    if (t == .unknown) return false;
    switch (ip.key(t)) {
        .error_union_type => |eu| return collectErrors(r, eu.err, names, true),
        .error_set_type => |set| {
            try names.appendSlice(r.arena, set);
            return true;
        },
        .inferred_error_set => {
            const set = try errorSetMembers(r, t) orelse return false;
            try names.appendSlice(r.arena, set);
            return true;
        },
        .simple_type => |s| return s != .anyerror and !required,
        // `return` 的其他值（载荷）不带错误
        else => return !required,
    }
}

/// 错误集的成员；anyerror 或无法求出时为 null
pub fn errorSetMembers(r: *Resolver, t: Index) resolve.Error!?[]const []const u8 {
    const ip = r.ctx.db.env.ip;
    switch (ip.key(t)) {
        .error_set_type => |names| return names,
        .inferred_error_set => |s| {
            const set = try r.ctx.get(ErrorSetOf, .{ .owner = .{ .file = s.file, .item = s.decl }, .inst = s.inst });
            return switch (ip.key(set)) {
                .error_set_type => |names| names,
                else => null,
            };
        },
        else => return null,
    }
}

/// 函数的返回类型是否为 `!T`（推导的错误集）
fn inferredErrorSet(r: *Resolver, owner: hir.OwnerKey) resolve.Error!bool {
    const tree = try r.itemTree(owner.file);
    for (tree.items) |it| if (it.ast_id == owner.item) return it.flags.inferred_error_set;
    return false;
}

/// comptime 调用的结果：由解释器执行函数体，结果按实例与实参缓存
pub const CallEval = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = eval.CallKey;
    pub const Value = TypedValue;

    pub fn compute(ctx: *Db.Ctx, key: Key) engine.Error!Value {
        _ = try ctx.get(TargetAbi, {});
        return eval.compute(ctx, key);
    }

    pub fn cycleFallback(_: Key) Value {
        return .unknown;
    }
};

/// 推导进行中的局部绑定（同一 owner 内直接读取，避免循环）
pub const LocalKey = struct {
    owner: hir.OwnerKey,
    target: union(enum) {
        binding: Body.BindingId,
        /// 在 comptime 上下文中求值的表达式（如体内 `enum(u8)` 的参数）
        expr: Body.ExprId,
    },
    inst: ?Index = null,
};

/// 成员中一个局部绑定（或一个 comptime 表达式）的类型与值：只推导这一个绑定（参数取实例；
/// 局部常量 / 变量推导其类型标注与初始化表达式，其中引用的其他局部绑定同样按需查询）。
///
/// 体内定义的容器引用外层函数的局部名字（如 `const T = struct {...}; ... struct { fn f(x: T) }`）时
/// 经由它，不依赖外层函数的整个函数体：否则外层函数体又引用内层成员时形成环，
/// 环中的结果不写入 memo，每次读取都要重算
pub const LocalValue = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = LocalKey;
    pub const Value = TypedValue;

    pub fn compute(ctx: anytype, key: Key) engine.Error!Value {
        _ = try ctx.get(TargetAbi, {});
        return infer.runLocal(ctx, key.owner, key.target, key.inst);
    }

    pub fn cycleFallback(_: Key) Value {
        return .unknown;
    }
};

pub const LocalScope = struct {
    file: FileId,
    item: u32,
    bindings: []const TypedValue,
};

/// 名字解析结果的类型。`inst` 为解析发生处的实例上下文
pub fn defType(r: *Resolver, def: resolve.Def, current: ?LocalScope, inst: ?Index) resolve.Error!TypedValue {
    switch (def) {
        .item => |it| {
            const tree = try r.itemTree(it.file);
            return r.ctx.get(DeclType, .{ .owner = .{ .file = it.file, .item = tree.items[it.item].ast_id }, .inst = try declInst(r, it.file, it.item, inst) });
        },
        .local => |l| {
            if (current) |c| if (c.file == l.file and c.item == l.item) return c.bindings[@backingInt(l.binding)];
            return r.ctx.get(LocalValue, .{ .owner = try r.ownerKey(l.file, l.item), .target = .{ .binding = l.binding }, .inst = try normalizeInst(r, l.file, l.item, inst) });
        },
        .file => |f| return TypedValue.ofType(try containerType(r, .{ .file = f, .container = 0 }, null)),
    }
}

/// 实例上下文中适用于成员 `item` 的实例：沿实例链找第一个属于 `item` 自身（函数）
/// 或其外层函数的实例。成员不在任何泛型函数中时为 null，保证同一成员不会因上下文不同而重复推导
pub fn normalizeInst(r: *Resolver, file: FileId, item: u32, inst: ?Index) resolve.Error!?Index {
    const ip = r.ctx.db.env.ip;
    var cur = inst;
    while (cur) |c| : (cur = ip.key(c).instance.parent) {
        const i = ip.key(c).instance;
        if (i.file == file and try enclosedBy(r, file, item, i.decl)) return c;
    }
    return null;
}

/// 成员声明（DeclType）适用的实例。函数取包含它的泛型函数的实例，不取它自身的实例：
/// 函数体内递归引用自身时，函数值不能带上当前调用的实例（否则每层递归都是新的实例，无法识别为环）
pub fn declInst(r: *Resolver, file: FileId, item: u32, inst: ?Index) resolve.Error!?Index {
    const tree = try r.itemTree(file);
    if (tree.items[item].kind != .@"fn") return normalizeInst(r, file, item, inst);
    const parent = tree.containers[tree.items[item].container].parent_item orelse return null;
    return normalizeInst(r, file, parent, inst);
}

/// `item` 是否为 `fn_decl` 本身或位于其内部（经由体内定义的容器）
pub fn enclosedBy(r: *Resolver, file: FileId, item: u32, fn_decl: @import("../syntax/ItemTree.zig").AstId) resolve.Error!bool {
    const tree = try r.itemTree(file);
    var cur: ?u32 = item;
    while (cur) |it| {
        if (tree.items[it].ast_id == fn_decl) return true;
        cur = tree.containers[tree.items[it].container].parent_item;
    }
    return false;
}

/// 命名空间（文件中的容器）对应的容器类型；容器定义在泛型函数体内时带上适用的实例
pub fn containerType(r: *Resolver, ns: Namespace, inst: ?Index) resolve.Error!Index {
    const tree = try r.itemTree(ns.file);
    const c = tree.containers[ns.container];
    const container_inst = if (c.parent_item) |p| try normalizeInst(r, ns.file, p, inst) else null;
    if (c.kind == .@"struct") if (try tupleDecl(r, tree, ns, container_inst)) |t| return t;
    return r.ctx.db.env.ip.get(.{ .container_type = .{ .file = ns.file, .ast_id = c.ast_id, .kind = switch (c.kind) {
        .file => .file,
        .@"struct" => .@"struct",
        .@"enum" => .@"enum",
        .@"union" => .@"union",
        .@"opaque" => .@"opaque",
    }, .inst = container_inst } });
}

/// 元组声明 `struct { A, B }`：与编译器一致是结构化的元组类型（字段类型相同的声明是同一个类型）。
/// 有字段名或声明时不是元组声明，为 null
fn tupleDecl(r: *Resolver, tree: *const ItemTree, ns: Namespace, inst: ?Index) resolve.Error!?Index {
    const members = tree.containerMembers(ns.container);
    if (members.len == 0) return null;
    for (members) |m| if (tree.items[m].kind != .field or tree.items[m].name != null) return null;
    const types = try r.arena.alloc(Index, members.len);
    const values = try r.arena.alloc(Index, members.len);
    for (members, types, values) |m, *t, *v| {
        t.* = (try defType(r, .{ .item = .{ .file = ns.file, .item = m } }, null, inst)).ty;
        // comptime 字段的值属于类型，这里不求值
        v.* = if (tree.items[m].flags.is_comptime) .unknown else .runtime;
    }
    return try r.ctx.db.env.ip.get(.{ .tuple_type = .{ .types = types, .values = InternPool.fieldValues(values) } });
}

pub fn namespaceOfType(r: *Resolver, t: Index) resolve.Error!?Namespace {
    const c = switch (r.ctx.db.env.ip.key(t)) {
        .container_type => |c| c,
        else => return null,
    };
    const tree = try r.itemTree(c.file);
    for (tree.containers, 0..) |x, i| if (x.ast_id == c.ast_id) return .{ .file = c.file, .container = @intCast(i) };
    return null;
}

/// 容器类型所属的实例
pub fn instOfType(ip: *InternPool, t: Index) ?Index {
    return switch (ip.key(t)) {
        .container_type => |c| c.inst,
        else => null,
    };
}

test {
    _ = @import("sema_test.zig");
}
