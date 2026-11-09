//! sema queries: declaration types and type inference of Bodies.

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
const zon = @import("zon.zig");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const Namespace = resolve.Namespace;
const ast = @import("../syntax/ast.zig");
const ItemTree = @import("../syntax/ItemTree.zig");
const FileId = @import("../base/Vfs.zig").FileId;
const Body = @import("../hir/Body.zig");
const mem = @import("../util/mem.zig");

/// Target-dependent parameters for value computations outside every compilation (the parts the
/// targets of all compilations agree on). The value is also stored in the InternPool for value
/// computations to read; queries that use value computations outside a compilation read this
/// input first to record the dependency.
pub const TargetAbi = struct {
    pub const kind: engine.Kind = .input;
    pub const Key = void;
    pub const Value = InternPool.Target;
    pub const default: Value = .{};
};

/// Target-dependent parameters of a compilation (an index into `ModuleGraph.compiles`): the
/// pointer bit width and the layout rules for vectors, integers, floats and C types of the target
/// of its builtin. Also stored in the InternPool (`InternPool.targets`); a computation running in
/// the compilation reads this input in `enterContext` to record the dependency.
pub const ContextTarget = struct {
    pub const kind: engine.Kind = .input;
    pub const Key = u32;
    pub const Value = InternPool.Target;
    pub const default: Value = .{};
};

pub const InferKey = struct {
    owner: hir.OwnerKey,
    mode: infer.Mode,
    /// Instance of the owner itself or of its enclosing generic function (normalized, see
    /// `normalizeInst`); null for non-generic code or the abstract instance. For a loop nested in
    /// loops inferred per iteration, the chain of iteration instances that carries their seeds
    /// (see `infer.iterationInst`).
    inst: ?Index = null,
    /// The loop variable of a loop over a list of types takes its value from one particular
    /// iteration (used when IDE features pick an instance for the loop body); when null, the loop
    /// variable is abstract. With nested loops, the seed of the innermost one (see
    /// `infer.LoopSeed`).
    loop: ?infer.LoopSeed = null,
    /// The root expression of a `.zon` file is inferred with this result type instead of the one of
    /// its import sites (`ZonResultType`): for a file whose sites give several (see `zonSiteTypes`)
    zon_type: ?Index = null,
};

pub const DeclKey = struct {
    owner: hir.OwnerKey,
    inst: ?Index = null,
};

/// Type inference result of a BodyOwner. Signature mode reads neither the function body nor the
/// initializer expression, so queries that depend on the signature need not be recomputed when
/// only those change.
pub const Infer = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = InferKey;
    pub const Value = *const infer.Result;
    /// Bounds the memory of long sessions (results for generic instances keep accumulating):
    /// evicted results are inferred again on demand
    pub const lru = 16 * 1024;
    /// Values vary greatly in size (the HIR / inference result of a long function can reach
    /// hundreds of KB), so the cache is limited by byte count as well
    pub const lru_bytes = 48 * 1024 * 1024;
    /// One read transaction can infer a large part of a project under many instances (the closure
    /// of `seed.AllInstances`). A much smaller limit makes those computations infer the same
    /// results again.
    pub const lru_read_bytes = 512 * 1024 * 1024;

    pub fn bytes(v: Value) usize {
        if (v == &empty_result) return 0;
        return @sizeOf(infer.Result) + mem.arenaBytes(v.arena);
    }

    pub fn compute(ctx: *Db.Ctx, key: Key) engine.Error!Value {
        const gpa = ctx.db.gpa;
        const result = try gpa.create(infer.Result);
        errdefer gpa.destroy(result);
        result.* = try infer.run(ctx, key.owner, key.mode, key.inst, key.loop, key.zon_type);
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

/// Type of a declaration; includes the value when the value of a const is known at comptime
/// (e.g. the value of `const S = struct {...}` is the type S)
pub const DeclType = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = DeclKey;
    pub const Value = TypedValue;

    pub fn compute(ctx: *Db.Ctx, dk: Key) engine.Error!Value {
        const key = dk.owner;
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        const scope = try enterContext(&r, key.file, dk.inst);
        defer scope.leave();
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
                // Parameters with bindings (including anytype and unnamed parameters) in order;
                // `...` has no binding and can only come last (see `varargs` in ItemTree)
                var params: std.ArrayList(Index) = .empty;
                var comptime_bits: u32 = 0;
                var noalias_bits: u32 = 0;
                for (b.params, 0..) |p, i| {
                    try params.append(r.arena, res.bindings[@backingInt(p)].ty);
                    const binding = b.binding(p);
                    const bit = InternPool.FnType.bitOf(i) orelse continue;
                    if (binding.is_comptime) comptime_bits |= bit;
                    if (binding.is_noalias) noalias_bits |= bit;
                }
                const flags = tree.items[item].flags;
                // In an instance of the function itself, the parameter and return types are those
                // of the instance
                const generic: GenericParts = if (isOwnInstance(ip, key, dk.inst)) .{} else try genericParts(&r, key.file, item, b);
                var ret = try returnType(&r, key, b, res, dk.inst);
                // A generic `!T` is still an error union with the inferred error set when `T`
                // cannot be inferred
                if (generic.ret and ret == .unknown and flags.inferred_error_set) {
                    const set = try ip.get(.{ .inferred_error_set = .{ .file = key.file, .decl = key.item, .inst = declaredInst(ip, key, dk.inst) } });
                    ret = try ip.get(.{ .error_union_type = .{ .err = set, .payload = .unknown } });
                }
                const ty = try ip.get(.{ .fn_type = .{
                    .params = params.items,
                    .ret = ret,
                    .varargs = flags.varargs,
                    .cc = try fnCallConv(&r, b, res, flags),
                    .comptime_bits = comptime_bits,
                    .noalias_bits = noalias_bits,
                    .generic_bits = generic.params,
                    .generic_ret = generic.ret,
                    .is_noinline = flags.is_noinline,
                } });
                return .{ .ty = ty, .val = try ip.get(.{ .fn_value = .{ .ty = ty, .file = key.file, .decl = key.item, .inst = dk.inst } }) };
            },
            .@"const", .@"var" => {
                const res = try ctx.get(Infer, .{ .owner = key, .mode = .full, .inst = dk.inst });
                if (res.exprs.len == 0) return .unknown;
                const annotation: ?Index = if (b.type_expr) |t| res.exprs[@backingInt(t)].asType() orelse .unknown else null;
                var value: TypedValue = if (b.value) |v| res.exprs[@backingInt(v)] else .unknown;
                if (annotation) |t| if (value.ty != t) {
                    value = .{ .ty = value.ty, .val = try @import("value.zig").arrayPtrAsSlice(ip, value, t) };
                    if (value.val != null) value.ty = t;
                };
                const is_const = tree.items[item].kind == .@"const";
                // Container-level constants are evaluated at comptime: when inference cannot
                // compute the value, the interpreter executes the initializer expression
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
                // A union field written with just a name (`b` in `union(enum) { a: u8, b }`) has
                // type void
                if (b.type_expr == null and tree.containers[container].kind == .@"union") return .{ .ty = .void_type };
                const res = try ctx.get(Infer, .{ .owner = key, .mode = .signature, .inst = dk.inst });
                if (res.exprs.len == 0) return .unknown;
                return .{ .ty = if (b.type_expr) |t| res.exprs[@backingInt(t)].asType() orelse .unknown else .unknown };
            },
            .@"test", .@"comptime" => return .{ .ty = .void_type },
            // The root of a ZON file is not a declaration; the value of importing it is `ZonValue`
            .zon => return .unknown,
        }
    }

    pub fn cycleFallback(_: Key) Value {
        return .unknown;
    }
};

/// Calling convention of a function declaration with body `body` and signature inference result
/// `sig`: its `callconv(...)`, otherwise (matching the compiler) `.c` for `export` and `extern`
/// functions, `.@"inline"` for `inline` functions and `.auto` for the others
fn fnCallConv(r: *Resolver, body: *const Body, sig: *const infer.Result, flags: ItemTree.Item.Flags) resolve.Error!InternPool.CallConv {
    for (body.clauses) |c| if (c.kind == .@"callconv") {
        const v: ?Index = if (@backingInt(c.expr) < sig.exprs.len) sig.exprs[@backingInt(c.expr)].val else null;
        return eval.writtenCallConv(r, body, c.expr, v);
    };
    if (flags.is_export or flags.is_extern) return .c;
    if (flags.is_inline) return .@"inline";
    return .auto;
}

/// Return type of a function in the signature inference result `sig` (instance `inst`). The error
/// set of `!T` is the error set inferred from the function body; the signature records only a
/// marker (without reading the body), and the members are computed by `ErrorSetOf`.
pub fn returnType(r: *Resolver, owner: hir.OwnerKey, body: *const Body, sig: *const infer.Result, inst: ?Index) resolve.Error!Index {
    const t = body.type_expr orelse return .unknown;
    if (@backingInt(t) >= sig.exprs.len) return .unknown;
    const ret = sig.exprs[@backingInt(t)].asType() orelse return .unknown;
    if (ret == .unknown or !try inferredErrorSet(r, owner)) return ret;
    const ip = r.ctx.db.env.ip;
    const set = try ip.get(.{ .inferred_error_set = .{ .file = owner.file, .decl = owner.item, .inst = declaredInst(ip, owner, inst) } });
    return ip.get(.{ .error_union_type = .{ .err = set, .payload = ret } });
}

/// Whether `inst` is an instance of function `owner` itself with comptime or `anytype`
/// arguments (see `declaredInst`)
fn isOwnInstance(ip: *InternPool, owner: hir.OwnerKey, inst: ?Index) bool {
    const i = switch (ip.key(inst orelse return false)) {
        .instance => |i| i,
        else => return false,
    };
    if (i.file != owner.file or i.decl != owner.item) return false;
    for (i.args) |a| if (a != .runtime) return true;
    return false;
}
const GenericParts = struct { params: u32 = 0, ret: bool = false };
/// Which parameter types, and whether the return type, of the function `item` are generic
/// (`InternPool.FnType.generic_bits`). As in the compiler (AstGen), a type is generic when the
/// parameter is `anytype` or its type expression refers to a parameter, directly or from the
/// members of a container defined in it.
fn genericParts(r: *Resolver, file: FileId, item: u32, b: *const Body) resolve.Error!GenericParts {
    var out: GenericParts = .{};
    // The signature is lowered before the function body: its expressions come first
    var end: u32 = 0;
    for (b.params, 0..) |p, i| {
        const t = b.binding(p).ty orelse {
            if (InternPool.FnType.bitOf(i)) |bit| out.params |= bit;
            continue;
        };
        end = @max(end, @backingInt(t) + 1);
    }
    if (b.type_expr) |t| end = @max(end, @backingInt(t) + 1);
    for (0..end) |n| {
        const e: Body.ExprId = @fromBackingInt(@as(u32, @intCast(n)));
        const refers = switch (b.expr(e)) {
            .name_ref => |name| !b.nameRefIsBuiltin(e) and if (b.lookup(b.expr_scopes[n], name)) |id| b.binding(id).kind == .param else false,
            .container => refers: {
                const ns = try r.containerAt(file, item, b.range(e).start) orelse break :refers false;
                for (try eval.captures(r, ns)) |cap| {
                    if (cap.item == item and b.binding(cap.binding).kind == .param) break :refers true;
                }
                break :refers false;
            },
            else => false,
        };
        if (!refers) continue;
        const at = b.range(e);
        if (b.type_expr) |t| if (within(at, b.range(t))) {
            out.ret = true;
            continue;
        };
        for (b.params, 0..) |p, i| {
            const t = b.binding(p).ty orelse continue;
            if (!within(at, b.range(t))) continue;
            if (InternPool.FnType.bitOf(i)) |bit| out.params |= bit;
            break;
        }
    }
    return out;
}
fn within(inner: Body.Range, outer: Body.Range) bool {
    return outer.start <= inner.start and inner.end <= outer.end;
}
/// The instance context of the declaration of a function, given an instance it runs in. A call of
/// a non-generic function runs in an instance whose arguments are all runtime; it is the function
/// as declared, so its return type must be the one in the type of the function.
fn declaredInst(ip: *InternPool, owner: hir.OwnerKey, inst: ?Index) ?Index {
    const i = switch (ip.key(inst orelse return null)) {
        .instance => |i| i,
        else => return inst,
    };
    if (i.file != owner.file or i.decl != owner.item) return inst;
    for (i.args) |a| if (a != .runtime) return inst;
    return i.parent;
}

/// Ranges of code in a member that is not compiled: the `inactive` and `dead_spans` of `Infer`
/// (relative to the start of the member, sorted by position). Inactive code needs the inference
/// results of all members of the file, and for a large file the `Infer` results exceed the LRU
/// limit, so every publish would recompute the evicted part; only the ranges are kept here, so
/// while the dependencies are unchanged nothing needs recomputing even if the `Infer` values have
/// been evicted.
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

/// Members of an inferred error set: the errors `return`ed in the function body and the errors
/// propagated by `try`; anyerror when any part is unknown. Recursive functions take the least
/// fixpoint (matching the compiler; the compiler rejects mutual recursion, for which the union of
/// the errors of the functions is likewise taken here).
pub const ErrorSetOf = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = DeclKey;
    pub const Value = Index;
    /// A function body only merges the errors of its callees into the result: a read of
    /// itself within a cycle is first treated as the empty set, and one computation at the
    /// entry of the cycle gives the complete result
    pub const fixpoint = true;

    pub fn compute(ctx: *Db.Ctx, key: Key) engine.Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        const scope = try enterContext(&r, key.owner.file, key.inst);
        defer scope.leave();
        const ip = ctx.db.env.ip;
        const body = try ctx.get(hir.ItemBody, key.owner);
        const res = try ctx.get(Infer, .{ .owner = key.owner, .mode = .full, .inst = key.inst });
        if (res.exprs.len != body.exprs.len) return .anyerror_type;
        var names: std.ArrayList([]const u8) = .empty;
        for (body.exprs, body.expr_ranges) |e, range| {
            const t: Index = switch (e) {
                .@"return" => |v| if (v) |x| res.exprs[@backingInt(x)].ty else continue,
                .prefix => |p| if (p.op == .keyword_try) res.exprs[@backingInt(p.operand)].ty else continue,
                else => continue,
            };
            // Branches known at comptime not to execute (including code after a noreturn
            // statement) are not merged into the error set
            if (isInactive(body, res, range)) continue;
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

/// Whether `range` lies in a branch that is inactive at comptime or after a noreturn statement
/// (see `Infer.Result.inactive` / `dead_spans`)
fn isInactive(body: *const Body, res: *const infer.Result, range: Body.Range) bool {
    for (res.inactive) |e| {
        const r = body.range(e);
        if (range.start >= r.start and range.end <= r.end) return true;
    }
    for (res.dead_spans) |r| {
        if (range.start >= r.start and range.end <= r.end) return true;
    }
    return false;
}

/// Adds the errors the type can carry (an error set, the error set of an error union) to `names`;
/// returns false when anyerror or something unknown is involved. With `required`, the type must
/// carry errors (the operand of `try`).
fn collectErrors(r: *Resolver, t: Index, names: *std.ArrayList([]const u8), required: bool) resolve.Error!bool {
    const ip = r.ctx.db.env.ip;
    if (t == .unknown) return false;
    switch (ip.key(t)) {
        .error_union_type => |eu| return collectErrors(r, eu.err, names, true),
        .error_set_type => |set| {
            try names.appendSlice(r.arena, set.names);
            return true;
        },
        .inferred_error_set => {
            const set = try errorSetMembers(r, t) orelse return false;
            try names.appendSlice(r.arena, set);
            return true;
        },
        .simple_type => |s| return s != .anyerror and !required,
        // Other values of `return` (payloads) carry no errors
        else => return !required,
    }
}

/// Members of an error set (in the order of `InternPool.ErrorSet.names`); null for anyerror or
/// when they cannot be computed
pub fn errorSetMembers(r: *Resolver, t: Index) resolve.Error!?[]const []const u8 {
    return if (try errorSetOf(r, t)) |es| es.names else null;
}

/// The members of an error set or of the inferred error set of a function; null for anyerror or
/// when they cannot be computed
pub fn errorSetOf(r: *Resolver, t: Index) resolve.Error!?InternPool.ErrorSet {
    const ip = r.ctx.db.env.ip;
    switch (ip.key(t)) {
        .error_set_type => |es| return es,
        .inferred_error_set => |s| {
            const set = try r.ctx.get(ErrorSetOf, .{ .owner = .{ .file = s.file, .item = s.decl }, .inst = s.inst });
            return switch (ip.key(set)) {
                .error_set_type => |es| es,
                else => null,
            };
        },
        else => return null,
    }
}

/// Whether the return type of the function is `!T` (an inferred error set)
fn inferredErrorSet(r: *Resolver, owner: hir.OwnerKey) resolve.Error!bool {
    const tree = try r.itemTree(owner.file);
    for (tree.items) |it| if (it.ast_id == owner.item) return it.flags.inferred_error_set;
    return false;
}

/// Whether a type can exist only at comptime (see `eval.computeComptimeOnly`), cached per type.
/// A recursive type referring to itself through a pointer forms a cycle: the cycle itself does
/// not make the type comptime-only, so the least fixpoint is taken.
pub const ComptimeOnly = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = Index;
    pub const Value = bool;
    pub const fixpoint = true;

    pub fn compute(ctx: *Db.Ctx, key: Key) engine.Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        return eval.computeComptimeOnly(&r, key);
    }

    pub fn cycleFallback(_: Key) Value {
        return false;
    }

    pub fn depthFallback(_: Key) Value {
        return false;
    }
};

/// Result of a comptime call: the interpreter executes the function body, and the result is
/// cached per instance and arguments
pub const CallEval = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = eval.CallKey;
    pub const Value = TypedValue;

    pub fn compute(ctx: *Db.Ctx, key: Key) engine.Error!Value {
        return eval.compute(ctx, key);
    }

    pub fn cycleFallback(_: Key) Value {
        return .unknown;
    }
};

/// Value of a `.zon` file without a result type (see `zon.lower`)
pub const ZonValue = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = FileId;
    pub const Value = TypedValue;

    pub fn compute(ctx: *Db.Ctx, file: Key) engine.Error!Value {
        // Both parsing and conversion recurse level by level
        if (ctx.stackExhausted()) {
            ctx.exhausted();
            return .unknown;
        }
        const source = try ctx.get(database.syntax.SourceText, file);
        return zon.lower(ctx.db.gpa, ctx.db.env.ip, file, source.text);
    }
};

/// How the files that may import a `.zon` file import it: the `@import` call sites in the files of
/// the module graph that import it directly (see `infer.Result.zon_imports`; build scripts and files
/// outside the modules are not searched).
pub const ZonImports = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = FileId;
    pub const Value = struct {
        /// The one type the sites with a result type give, free of abstract parameters and unknown
        /// parts. Types that differ only in the optionals and single-item pointers around the value
        /// (`T`, `*const T`, `?T`) parse the value the same way (see `zonValueType`), and the result
        /// is the type of the value. Sites without a result type do not constrain the value.
        result_type: ?Index = null,
        /// Some sites give a result type, but no single one can be named: they differ, or one is
        /// abstract or unknown (no guessing)
        unresolved: bool = false,
    };

    pub fn cycleFallback(_: Key) Value {
        return .{};
    }

    pub fn compute(ctx: *Db.Ctx, file: Key) engine.Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        var out: Value = .{};
        const ip = ctx.db.env.ip;
        for (try owners(&r, file)) |owner| {
            const res = try ctx.get(Infer, .{ .owner = owner.key, .mode = .full });
            for (res.zon_imports) |site| {
                if (site.file != file) continue;
                const ty = site.ty;
                if (!@import("value.zig").isConcrete(ip, ty)) {
                    out.unresolved = true;
                } else if (out.result_type) |t| {
                    if (t != ty) {
                        const value_type = zonValueType(ip, t);
                        if (value_type == zonValueType(ip, ty)) out.result_type = value_type else out.unresolved = true;
                    }
                } else out.result_type = ty;
            }
        }
        if (out.unresolved) out.result_type = null;
        return out;
    }

    pub const Owner = struct { file: FileId, item: u32, key: hir.OwnerKey };

    /// The members that contain an `@import` call importing the `.zon` file. The files that may
    /// import it are the project files (excluding the standard library) and the user's source files
    /// under the workspace roots, which include files in no build graph (single-file mode, build
    /// scripts).
    pub fn owners(r: *Resolver, file: FileId) resolve.Error![]const Owner {
        const ctx = r.ctx;
        var importers: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty;
        if (try ctx.get(database.ModuleGraph.Input, {})) |graph| for (graph.files) |entry| {
            if (entry.module != database.ModuleGraph.std_module) try importers.put(r.arena, entry.file, {});
        };
        for (try ctx.get(database.inputs.WorkspaceFiles, {})) |f| try importers.put(r.arena, f, {});
        var out: std.ArrayList(Owner) = .empty;
        for (importers.keys()) |importer| {
            // Only Zig source files can `@import` (the root of a module can also be a `.zon` or
            // another data file)
            if (!std.mem.endsWith(u8, ctx.db.env.vfs.path(importer), ".zig")) continue;
            const index = try ctx.get(database.FileIndex.Query, importer);
            const imports = for (index.imports) |spec| {
                // A path ending in `.zig` names a Zig file, never a `.zon` file
                if (std.mem.endsWith(u8, spec, ".zig")) continue;
                if (try r.resolveImport(importer, spec) == file) break true;
            } else false;
            if (!imports) continue;
            try out.appendSlice(r.arena, try importOwners(r, importer, file));
        }
        return out.items;
    }

    /// The type a ZON value is parsed as for the result type `t`: the compiler (`LowerZon`) parses
    /// the value of an optional as the payload and the value of a single-item pointer as the
    /// pointee
    fn zonValueType(ip: *InternPool, t: Index) Index {
        var cur = t;
        while (true) cur = switch (ip.key(cur)) {
            .optional_type => |child| child,
            .ptr_type => |p| if (p.size == .one) p.child else return cur,
            else => return cur,
        };
    }

    /// The members of `importer` that contain an `@import` call importing `target` (deduplicated)
    fn importOwners(r: *Resolver, importer: FileId, target: FileId) resolve.Error![]const Owner {
        var owners_of: std.ArrayList(Owner) = .empty;
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        var stack: std.ArrayList(ast.SyntaxNode) = .empty;
        try stack.append(r.arena, (try r.ctx.get(database.syntax.ParseFile, importer)).rootNode());
        while (stack.pop()) |node| {
            if (ast.cast(ast.BuiltinCall, node)) |call| if (call.name()) |n| if (std.mem.eql(u8, n.text, "@import")) {
                var args = call.args();
                if (args.next()) |arg| if (arg.firstToken()) |t| if (t.kind == .string_literal) {
                    const spec = std.zig.string_literal.parseAlloc(r.arena, t.text) catch continue;
                    if (try r.resolveImport(importer, spec) == target) {
                        if (try r.ownerAt(importer, node.offset, false)) |item| if (!(try seen.getOrPut(r.arena, item)).found_existing) {
                            try owners_of.append(r.arena, .{ .file = importer, .item = item, .key = try r.ownerKey(importer, item) });
                        };
                    }
                };
            };
            var it = node.children();
            while (it.nextNode()) |c| try stack.append(r.arena, c);
        }
        return owners_of.items;
    }
};

/// The result type of the root expression of a `.zon` file (see `ZonImports.Value.result_type`), read
/// by the inference of that root expression and by the schema check of `build.zig.zon`
/// (`manifest.active`). Separate from `ZonImports` so that these do not depend on how the other
/// import sites look.
pub const ZonResultType = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = FileId;
    pub const Value = ?Index;

    pub fn cycleFallback(_: Key) Value {
        return null;
    }

    pub fn compute(ctx: *Db.Ctx, file: Key) engine.Error!Value {
        return (try ctx.get(ZonImports, file)).result_type;
    }
};

/// Value of `@import`: for a `.zon` file, the value in it (see `ZonValue`); for a `.zig` file,
/// the file container type
pub fn importValue(r: *Resolver, target: FileId) resolve.Error!TypedValue {
    if (r.isZon(target)) return r.ctx.get(ZonValue, target);
    return TypedValue.ofType(try containerType(r, .{ .file = target, .container = 0 }, null));
}

/// A local binding of an inference in progress (read directly within the same owner, to avoid
/// cycles)
pub const LocalKey = struct {
    owner: hir.OwnerKey,
    target: union(enum) {
        binding: Body.BindingId,
        /// An expression evaluated in a comptime context (such as the argument of `enum(u8)`
        /// in a body)
        expr: Body.ExprId,
    },
    inst: ?Index = null,
};

/// Type and value of one local binding (or one comptime expression) in a member: infers only this
/// binding (a parameter is taken from the instance; a local constant / variable infers its type
/// annotation and initializer expression, and other local bindings referenced there are queried
/// on demand in the same way).
///
/// A container defined in a body that refers to local names of the enclosing function (e.g.
/// `const T = struct {...}; ... struct { fn f(x: T) }`) goes through this query instead of
/// depending on the whole body of the enclosing function: otherwise a cycle forms when the
/// enclosing function body in turn refers to the inner member, and since results within a cycle
/// are not written to the memo, every read would recompute them.
pub const LocalValue = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = LocalKey;
    pub const Value = TypedValue;

    pub fn compute(ctx: anytype, key: Key) engine.Error!Value {
        return infer.runLocal(ctx, key.owner, key.target, key.inst);
    }

    pub fn cycleFallback(_: Key) Value {
        return .unknown;
    }
};

/// Value of a local constant of a function as the function body computes it: the interpreter
/// executes the function in its instance `inst` and takes the value of the constant once it is
/// defined (see `eval.localValue`). A container defined in a function body captures the values
/// the body has computed for the locals it refers to (the compiler's `getCaptures`), which can
/// depend on the statements before the definition (a local variable modified in a loop, an array
/// sorted in place); `LocalValue` infers only the initializer and cannot see those statements.
pub const LocalEval = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = LocalKey;
    pub const Value = TypedValue;

    pub fn compute(ctx: *Db.Ctx, key: Key) engine.Error!Value {
        return eval.localValue(ctx, key);
    }

    pub fn cycleFallback(_: Key) Value {
        return .unknown;
    }
};

/// A local variable of a function as a container defined in the function body captures it
pub const CaptureKey = struct {
    owner: hir.OwnerKey,
    binding: Body.BindingId,
    /// The container (an index into `ItemTree.containers`) defined directly in the body of `owner`
    container: u32,
    inst: ?Index = null,
};

/// Value of a local variable of a function as a container defined in its body captures it: the
/// value the variable has when the body reaches the container, which the compiler's
/// `getCaptures` loads there (`comptime var`, or a `var` in a comptime scope). Containers
/// defined before and after a modification capture different values, so the value belongs to
/// the container rather than to the variable. The interpreter executes the function in its
/// instance `inst` up to the container (see `eval.capturedValue`).
pub const CapturedVar = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = CaptureKey;
    pub const Value = TypedValue;

    pub fn compute(ctx: *Db.Ctx, key: Key) engine.Error!Value {
        return eval.capturedValue(ctx, key);
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

/// Type of a name resolution result. `inst` is the instance context where the resolution takes
/// place, and `current` the member it takes place in, when known.
pub fn defType(r: *Resolver, def: resolve.Def, current: ?LocalScope, inst: ?Index) resolve.Error!TypedValue {
    switch (def) {
        .item => |it| {
            const tree = try r.itemTree(it.file);
            return r.ctx.get(DeclType, .{ .owner = .{ .file = it.file, .item = tree.items[it.item].ast_id }, .inst = try declInst(r, it.file, it.item, inst) });
        },
        .local => |l| {
            const c = current orelse return outerLocal(r, l, null, inst);
            if (c.file == l.file and c.item == l.item) return c.bindings[@backingInt(l.binding)];
            return outerLocal(r, l, try memberNamespace(r, c.file, c.item), inst);
        },
        .file => |f| return importValue(r, f),
    }
}

pub const Local = @FieldType(resolve.Def, "local");

/// Type of local `l` of another member, read from a member of container `from` (null when not
/// known) in instance context `inst`. Such a read comes from a container defined in the body of
/// member `l.item` (a function, or the initializer of a declaration), which captured the values
/// the body computed for the locals it refers to when the body reached the container (the
/// compiler's `getCaptures`):
/// - a constant has one value: `LocalValue` infers its initializer, and when that gives no value,
///   `LocalEval` takes it from an execution of the function;
/// - a variable can change between containers, so its value is the one the container defined
///   directly in the body around `from` captured (`CapturedVar`); without `from`, only its type
///   is known.
/// A container in a loop of the body has the values it captured in its instance
/// (`InternPool.Instance.captured`), one set per iteration; the locals it did not capture, and
/// those whose captured value is unknown, are computed as above in the instance the body runs in.
pub fn outerLocal(r: *Resolver, l: Local, from: ?Namespace, inst: ?Index) resolve.Error!TypedValue {
    const ip = r.ctx.db.env.ip;
    const owner = try r.ownerKey(l.file, l.item);
    var owner_inst = try innerInst(r, l.file, l.item, inst);
    if (owner_inst) |i| switch (ip.key(i)) {
        .instance => |k| if (k.captured.len != 0 and k.file == owner.file and k.decl == owner.item) {
            for (k.captured) |c| if (c.binding == @backingInt(l.binding) and c.val != .unknown) return .{ .ty = c.ty, .val = c.val };
            // A function body runs in the function's instance without the captured values, the
            // body of another member in the instance enclosing the member
            const is_fn = (try r.itemTree(l.file)).items[l.item].kind == .@"fn";
            owner_inst = if (is_fn) try withoutCaptured(ip, i) else try normalizeInst(r, l.file, l.item, i);
        },
        else => {},
    };
    const key: LocalKey = .{ .owner = owner, .target = .{ .binding = l.binding }, .inst = owner_inst };
    const tv = try r.ctx.get(LocalValue, key);
    if (tv.val != null or r.ctx.incomplete()) return tv;
    const run = switch ((try r.body(l.file, l.item)).binding(l.binding).kind) {
        .local_const => try r.ctx.get(LocalEval, key),
        .local_var => blk: {
            const ns = from orelse return tv;
            if (ns.file != l.file) return tv;
            const site = try captureSite(r, ns, l.item) orelse return tv;
            break :blk try r.ctx.get(CapturedVar, .{ .owner = key.owner, .binding = l.binding, .container = site, .inst = key.inst });
        },
        .param, .capture => return tv,
    };
    return if (run.val != null and (tv.ty == .unknown or run.ty == tv.ty)) run else tv;
}

/// Instance `inst` of a function without the values a container in one of its loops captured:
/// the instance the function body runs in
pub fn withoutCaptured(ip: *InternPool, inst: Index) Allocator.Error!Index {
    var k = switch (ip.key(inst)) {
        .instance => |x| x,
        else => return inst,
    };
    if (k.captured.len == 0) return inst;
    k.captured = &.{};
    return ip.get(.{ .instance = k });
}

/// The container a member of the file belongs to
pub fn memberNamespace(r: *Resolver, file: FileId, item: u32) resolve.Error!Namespace {
    return .{ .file = file, .container = (try r.itemTree(file)).items[item].container };
}

/// The container defined directly in the body of member `item` that is or encloses container `ns`
/// (through the members of nested containers): the one whose definition captures the locals of
/// `item` that `ns` refers to. Null when `ns` is not inside `item`.
fn captureSite(r: *Resolver, ns: Namespace, item: u32) resolve.Error!?u32 {
    const tree = try r.itemTree(ns.file);
    var c = ns.container;
    while (true) {
        const parent = tree.containers[c].parent_item orelse return null;
        if (parent == item) return c;
        c = tree.items[parent].container;
    }
}

/// The instance in an instance context that applies to member `item`: the first instance along
/// the instance chain that belongs to `item` itself (a function) or to an enclosing function.
/// When the member is not inside any generic function, the compilation context (`rootInst`),
/// which ensures the same member is not inferred repeatedly for different instances. The instance
/// of a member that is not a function (see `InternPool.Instance.captured`) belongs to containers
/// its body defines (`innerInst`), not to the body itself, which runs in the enclosing instance.
pub fn normalizeInst(r: *Resolver, file: FileId, item: u32, inst: ?Index) resolve.Error!?Index {
    return applicableInst(r, file, item, inst, false);
}

/// `normalizeInst` for the code of a container defined in the body of member `item`: when `item`
/// is not a function, its own instance applies too (see `InternPool.Instance.captured`)
pub fn innerInst(r: *Resolver, file: FileId, item: u32, inst: ?Index) resolve.Error!?Index {
    return applicableInst(r, file, item, inst, true);
}

fn applicableInst(r: *Resolver, file: FileId, item: u32, inst: ?Index, inner: bool) resolve.Error!?Index {
    const ip = r.ctx.db.env.ip;
    var cur = inst;
    while (cur) |c| {
        const i = switch (ip.key(c)) {
            .instance => |i| i,
            else => break,
        };
        if (i.file == file and try enclosedBy(r, file, item, i.decl)) {
            if (inner or i.captured.len == 0 or !isMemberInstOf(try r.itemTree(file), item, i)) return c;
        }
        cur = i.parent;
    }
    return rootInst(r, file, inst);
}

/// Whether `k` (an instance in the file of `tree`) is the instance of member `item` when that
/// member is not a function: the instance of the containers its body defines in a loop, with the
/// values they captured (see `InternPool.Instance.captured`)
fn isMemberInstOf(tree: *const ItemTree, item: u32, k: InternPool.Instance) bool {
    return k.captured.len != 0 and k.iteration == null and k.decl == tree.items[item].ast_id and tree.items[item].kind != .@"fn";
}

/// Whether `k` is the instance of a member that is not a function (see `isMemberInstOf`)
pub fn isMemberInst(r: *Resolver, k: InternPool.Instance) resolve.Error!bool {
    if (k.captured.len == 0 or k.iteration != null) return false;
    const tree = try r.itemTree(k.file);
    for (tree.items, 0..) |it, i| if (it.ast_id == k.decl) return isMemberInstOf(tree, @intCast(i), k);
    return false;
}

/// The instance context of code in `file` outside every generic function, reached from instance
/// context `inst`: null when the computation runs in the file's own compilation (or nothing is
/// known about compilations), otherwise the `context` key of the compilation. The compilation is
/// that of the current computation (`Resolver.context`), else the one `inst` belongs to.
pub fn rootInst(r: *Resolver, file: FileId, inst: ?Index) resolve.Error!?Index {
    const c = r.context orelse try chainContext(r, inst) orelse return null;
    if (try r.fileContext(file) == c) return null;
    return try r.ctx.db.env.ip.get(.{ .context = c });
}

/// The compilation instance context `inst` belongs to: the `context` key ending its chain, else
/// the own compilation of the file of its instances; null for no instance context
fn chainContext(r: *Resolver, inst: ?Index) resolve.Error!?u32 {
    const ip = r.ctx.db.env.ip;
    var cur = inst;
    var file: ?FileId = null;
    while (cur) |c| switch (ip.key(c)) {
        .context => |x| return x,
        .instance => |i| {
            file = i.file;
            cur = i.parent;
        },
        else => break,
    };
    return if (file) |f| try r.fileContext(f) else null;
}

/// The compilation a computation for code in `file` with instance context `inst` runs in
pub fn contextOf(r: *Resolver, file: FileId, inst: ?Index) resolve.Error!?u32 {
    return try chainContext(r, inst) orelse try r.fileContext(file);
}

/// Runs the rest of a computation for code in `file` with instance context `inst` in its
/// compilation (`contextOf`): `@import` of std, builtin and root resolves in it
/// (`Resolver.context`), and value computations on this thread use its target until `leave`.
/// Reads the target input to record the dependency.
pub fn enterContext(r: *Resolver, file: FileId, inst: ?Index) resolve.Error!ContextScope {
    const c = try contextOf(r, file, inst);
    if (c) |i| _ = try r.ctx.get(ContextTarget, i) else _ = try r.ctx.get(TargetAbi, {});
    const scope: ContextScope = .{ .r = r, .context = r.context, .target = r.ctx.db.env.ip.enterContext(c) };
    r.context = c;
    return scope;
}

pub const ContextScope = struct {
    r: *Resolver,
    context: ?u32,
    target: ?*const InternPool.Target,

    pub fn leave(s: ContextScope) void {
        s.r.context = s.context;
        InternPool.leaveContext(s.target);
    }
};

/// `inst` when it is an instance of a generic function, null when it is only a compilation
/// context (or null)
pub fn genericInst(ip: *InternPool, inst: ?Index) ?Index {
    const i = inst orelse return null;
    return if (ip.key(i) == .instance) i else null;
}

/// The instance that applies to a member declaration (DeclType). A function takes the instance of
/// its container (that of the generic function containing it), not its own instance: when a
/// function body refers to itself recursively, the function value must not carry the instance of
/// the current call (otherwise every level of recursion would be a new instance, and the cycle
/// could not be recognized).
pub fn declInst(r: *Resolver, file: FileId, item: u32, inst: ?Index) resolve.Error!?Index {
    const tree = try r.itemTree(file);
    if (tree.items[item].kind != .@"fn") return normalizeInst(r, file, item, inst);
    const parent = tree.containers[tree.items[item].container].parent_item orelse return rootInst(r, file, inst);
    return innerInst(r, file, parent, inst);
}

/// Whether `item` is `fn_decl` itself or lies inside it (through containers defined in its body)
pub fn enclosedBy(r: *Resolver, file: FileId, item: u32, fn_decl: @import("../syntax/ItemTree.zig").AstId) resolve.Error!bool {
    const tree = try r.itemTree(file);
    var cur: ?u32 = item;
    while (cur) |it| {
        if (tree.items[it].ast_id == fn_decl) return true;
        cur = tree.containers[tree.items[it].container].parent_item;
    }
    return false;
}

/// Container type of a namespace (a container in a file); when the container is defined in a
/// generic function body, it carries the applicable instance (see `abstractInst` when there is
/// none), and otherwise the compilation context (`rootInst`)
pub fn containerType(r: *Resolver, ns: Namespace, inst: ?Index) resolve.Error!Index {
    const tree = try r.itemTree(ns.file);
    return containerTypeIn(r, tree, ns, tree.containers[ns.container], try containerInst(r, ns, inst));
}

/// The instance that container `ns` carries in instance context `inst` (see `containerType`)
pub fn containerInst(r: *Resolver, ns: Namespace, inst: ?Index) resolve.Error!?Index {
    const c = (try r.itemTree(ns.file)).containers[ns.container];
    const p = c.parent_item orelse return rootInst(r, ns.file, inst);
    return abstractInst(r, ns.file, p, c.in_signature, try innerInst(r, ns.file, p, inst));
}

/// The type of a container as the function's own type sees it, when evaluating the prototype that
/// contains it: outside the abstract instance, which is made from that function type, so that the
/// type is concrete and arguments coerce to it
pub fn prototypeContainerType(r: *Resolver, ns: Namespace, inst: ?Index) resolve.Error!Index {
    const tree = try r.itemTree(ns.file);
    const c = tree.containers[ns.container];
    if (!c.in_signature) return containerType(r, ns, inst);
    return containerTypeIn(r, tree, ns, c, try normalizeInst(r, ns.file, c.parent_item.?, inst));
}

fn containerTypeIn(r: *Resolver, tree: *const ItemTree, ns: Namespace, c: ItemTree.Container, container_inst: ?Index) resolve.Error!Index {
    if (c.kind == .@"struct") if (try tupleDecl(r, tree, ns, container_inst)) |t| return t;
    return r.ctx.db.env.ip.get(.{ .container_type = .{ .file = ns.file, .ast_id = c.ast_id, .kind = switch (c.kind) {
        .file => .file,
        .@"struct" => .@"struct",
        .@"enum" => .@"enum",
        .@"union" => .@"union",
        .@"opaque" => .@"opaque",
    }, .inst = container_inst } });
}

/// The instance of a container defined in member `item`. Inside a generic function that `inst`
/// (normalized, see `normalizeInst`) is not an instance of, it is the function's abstract
/// instance, whose arguments are the function's own parameters (abstract type parameters,
/// unknown values): the instance the call `Pair(A, B)` written in the body of
/// `fn Pair(comptime A: type, comptime B: type) type` refers to, so `@This()` there is the same
/// type, as in the compiler. A container in the function's prototype (`in_signature`) goes through
/// `SignatureInst`. The instance of `item` or of a member between it and the function that is
/// not a function itself (see `InternPool.Instance.captured`) is kept: it lies inside an instance
/// of the function.
fn abstractInst(r: *Resolver, file: FileId, item: u32, in_signature: bool, inst: ?Index) resolve.Error!?Index {
    const ip = r.ctx.db.env.ip;
    const tree = try r.itemTree(file);
    const member: ?InternPool.Instance = if (inst) |i| switch (ip.key(i)) {
        .instance => |k| if (k.file == file) k else null,
        else => null,
    } else null;
    var cur: ?u32 = item;
    var signature = in_signature;
    const f: u32 = while (cur) |it| {
        if (tree.items[it].kind == .@"fn") break it;
        if (member) |k| if (isMemberInstOf(tree, it, k)) return inst;
        const outer = tree.containers[tree.items[it].container];
        signature = outer.in_signature;
        cur = outer.parent_item;
    } else return inst;
    if (inst) |i| switch (ip.key(i)) {
        .instance => |k| if (k.file == file and k.decl == tree.items[f].ast_id) return inst,
        else => {},
    };
    if (signature) return r.ctx.get(SignatureInst, .{ .owner = .{ .file = file, .item = tree.items[f].ast_id }, .inst = inst });
    return functionInst(r, file, f, inst);
}

/// The abstract instance of a container in the prototype of function `owner`. It is made from the
/// function's type and parameters, which are evaluated from that container: inside this query the
/// container keeps `inst`. The instance only takes the kinds of the parameters and the values of
/// comptime ones, so one computation at the entry of the cycle gives the result. As a fixpoint it
/// is written to a memo; otherwise every read of the function's type would compute the cycle again.
pub const SignatureInst = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = DeclKey;
    pub const Value = ?Index;
    pub const fixpoint = true;

    pub fn compute(ctx: *Db.Ctx, key: Key) engine.Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        const scope = try enterContext(&r, key.owner.file, key.inst);
        defer scope.leave();
        const tree = try r.itemTree(key.owner.file);
        const f: u32 = for (tree.items, 0..) |it, i| {
            if (it.ast_id == key.owner.item) break @intCast(i);
        } else return key.inst;
        return functionInst(&r, key.owner.file, f, key.inst);
    }

    pub fn cycleFallback(key: Key) Value {
        return key.inst;
    }

    pub fn depthFallback(key: Key) Value {
        return key.inst;
    }
};

/// The abstract instance of function member `f` under `inst`
fn functionInst(r: *Resolver, file: FileId, f: u32, inst: ?Index) resolve.Error!?Index {
    const ip = r.ctx.db.env.ip;
    const callee = try defType(r, .{ .item = .{ .file = file, .item = f } }, null, inst);
    const fn_type = switch (ip.key(callee.ty)) {
        .fn_type => |x| x,
        else => return inst,
    };
    const g = try infer.genericCallee(r, r.arena, callee, fn_type) orelse return inst;
    const args = try r.arena.alloc(TypedValue, g.body.params.len);
    for (g.body.params, args) |p, *a| a.* = try defType(r, .{ .local = .{ .file = file, .item = f, .binding = p } }, null, inst);
    return try infer.instanceOf(r, r.arena, g, fn_type, args);
}

/// Tuple declaration `struct { A, B }`: matching the compiler, it is a structural tuple type
/// (declarations with the same field types are the same type). Null when there are field names
/// or declarations, since it is then not a tuple declaration.
fn tupleDecl(r: *Resolver, tree: *const ItemTree, ns: Namespace, inst: ?Index) resolve.Error!?Index {
    const members = tree.containerMembers(ns.container);
    if (members.len == 0) return null;
    for (members) |m| if (tree.items[m].kind != .field or tree.items[m].name != null) return null;
    const types = try r.arena.alloc(Index, members.len);
    const values = try r.arena.alloc(Index, members.len);
    for (members, types, values) |m, *t, *v| {
        t.* = (try defType(r, .{ .item = .{ .file = ns.file, .item = m } }, null, inst)).ty;
        // The values of comptime fields belong to the type and are not evaluated here
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

/// The instance a container type belongs to
pub fn instOfType(ip: *InternPool, t: Index) ?Index {
    return switch (ip.key(t)) {
        .container_type => |c| c.inst,
        else => null,
    };
}

test {
    _ = @import("sema_test.zig");
}
