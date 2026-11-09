//! Expression type inference: bidirectional, with expected types pushed down from parameters,
//! return values, type annotations, and field initializers; a common subset of peer type
//! resolution where branches merge. Unknown parts are `unknown`, which absorbs everything and
//! produces no diagnostics.
//!
//! Type expressions (`?*const T`, `[]u8`, `struct {...}`) are expressions too; they evaluate to
//! values of type `type`.
//!
//! comptime evaluation: calling a function with comptime / anytype parameters or one that returns
//! `type` creates an instance (an InternPool `instance`), and the function body is inferred in the
//! instance: parameters are bound to the argument values, `if` / `switch` with a known condition
//! takes only the branch actually executed, integer, boolean, and type equality comparisons are
//! constant-folded, and a function returning `type` takes the value of the `return` actually
//! reached. Without a concrete instance, `comptime T: type` is the abstract parameter `T`.

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
const bigint = @import("bigint.zig");
const eval = @import("eval.zig");
const zon = @import("zon.zig");
const SyntaxKind = @import("../syntax/kind.zig").SyntaxKind;

pub const Error = resolve.Error;

/// Inference result of one BodyOwner
pub const Result = struct {
    arena: std.heap.ArenaAllocator.State,
    /// Parallel to `Body.exprs`
    exprs: []const TypedValue,
    /// Parallel to `Body.bindings`
    bindings: []const TypedValue,
    /// Parallel to `Body.exprs`: the member (field or declaration) a field access resolves to
    members: []const ?hir.OwnerKey,
    /// Value of the `return` the function actually reaches (the result of a type constructor)
    ret: TypedValue,
    /// Fields that field names in initializer expressions resolve to (the `x` in `.{ .x = 1 }`)
    field_refs: []const FieldRef = &.{},
    /// Enum literals with an expected type (including decl literals, a bare `.` with no name
    /// written yet, and the operand of `try .foo`, which gets the result type of the `try`), error
    /// values (`error.X`), and anonymous initializers (`.{ ... }`), along with their expected
    /// types: completion uses them to list members, error names, and fields
    literal_expected: []const LiteralExpected = &.{},
    /// Enum literals (including the callees of decl literal calls) and anonymous initializers whose
    /// result type exists but is unknown: they may name members of whatever type it is (reference
    /// search cannot confirm whether they refer to a declaration)
    unknown_expected: []const ExprId = &.{},
    /// `if` / `switch` branches known at comptime not to execute, and the right-hand sides of
    /// `and` / `or` whose left-hand side already decides the result (the outermost ones): code
    /// that is not compiled under the current build configuration
    inactive: []const ExprId = &.{},
    /// Statements after a noreturn statement in the same block (ranges relative to the owner): not
    /// compiled either. Examples are the code after a selected
    /// `if (!@hasDecl(T, "x")) @compileError(...);` and after a `return` under a comptime
    /// condition.
    dead_spans: []const Body.Range = &.{},
    /// The type each parameter of enum literal type (a `.x` received by anytype) is coerced to in
    /// the function body, taking the first coercion for each parameter: the literal at the call
    /// site refers to a member of this type (`testing.expectEqual(.x, actual)` coerces it to the
    /// type of actual through `@TypeOf(expected, actual)`)
    param_coercions: []const ParamCoercion = &.{},
    /// With per-iteration inference (`LoopSeed`), the values at the end of this iteration of the
    /// outer `comptime var`s modified by the loop body: the next iteration starts from them
    iteration_vars: []const IterationVar = &.{},
    /// The target and result type of each reachable `@import` call that has a result type and
    /// targets a `.zon` file: the root expression of the `.zon` file is inferred with it (see
    /// `queries.ZonImports`)
    zon_imports: []const ZonImport = &.{},
    /// References (names, member accesses, enum literals) and builtin calls whose value is changed
    /// by their result type coercion, with their own value before it: `a` of type `u8` in `take(a)`
    /// with `take(o: ?u8)` is `u8` (the compiler adds a separate coercion to `?u8`), `.red` coerced
    /// to `?Color` is a `Color`. `exprs` holds the coerced values.
    uncoerced: []const Uncoerced = &.{},

    pub const Uncoerced = struct { expr: ExprId, tv: TypedValue };
    pub const LiteralExpected = struct {
        expr: ExprId,
        ty: Index,
        /// The type comes from peer type resolution, not from a result type (an enum literal in a
        /// branch without a result type, an operand of a comparison): the literal names a tag of
        /// it, never a declaration, since decl literals need a result type
        tags_only: bool = false,
    };
    pub const ZonImport = struct { file: FileId, ty: Index };
    pub const IterationVar = struct { binding: Body.BindingId, val: ?Index };
    pub const ParamCoercion = struct { param: u32, ty: Index };

    pub const FieldRef = struct {
        /// The `init` expression
        init: ExprId,
        /// Index into `Body.Expr.init.fields`
        index: u32,
        member: hir.OwnerKey,
    };

    /// The value of `e` before its result type coercion (see `uncoerced`)
    pub fn uncoercedValue(r: *const Result, e: ExprId) TypedValue {
        for (r.uncoerced) |u| if (u.expr == e) return u.tv;
        return if (@backingInt(e) < r.exprs.len) r.exprs[@backingInt(e)] else .unknown;
    }

    pub fn eql(a: *const Result, b: *const Result) bool {
        return deepEql(a.exprs, b.exprs) and deepEql(a.bindings, b.bindings) and deepEql(a.members, b.members) and deepEql(a.ret, b.ret) and deepEql(a.field_refs, b.field_refs) and deepEql(a.literal_expected, b.literal_expected) and deepEql(a.unknown_expected, b.unknown_expected) and deepEql(a.inactive, b.inactive) and deepEql(a.dead_spans, b.dead_spans) and deepEql(a.param_coercions, b.param_coercions) and deepEql(a.iteration_vars, b.iteration_vars) and deepEql(a.zon_imports, b.zon_imports) and deepEql(a.uncoerced, b.uncoerced);
    }

    pub fn deinit(r: *Result, gpa: Allocator) void {
        var arena = r.arena.promote(gpa);
        arena.deinit();
        r.* = undefined;
    }
};

pub const Mode = enum {
    /// Infers only the signature: parameter types, the return type, and type annotations of
    /// variables and fields
    signature,
    full,
};

/// Per-iteration inference: the loop variable `binding` of a loop (`inline for`, or `for` at
/// comptime) takes the `index`-th element of the list, and the capture `binding` of an `inline`
/// switch prong takes the value of the `index`-th prong item (see `queries.InferKey.loop`).
///
/// In an instance with an undetermined iteration (that of the containers in a loop body when not
/// inferring per iteration, see `splitIteration`), `index` is
/// `InternPool.Instance.Iteration.unknown_index`. That is no iteration: the loop is inferred as
/// without a seed, so its loop variables have their types and no values (the compiler gives them
/// a value only in each unrolled iteration), see `Inferrer.iterationSeed`. The seed still keeps
/// the inference apart from the member's own one, which is in progress when a container in the
/// loop body reads a loop variable.
pub const LoopSeed = struct { binding: u32, index: u32 };

pub fn run(ctx: *Db.Ctx, owner: hir.OwnerKey, mode: Mode, inst: ?Index, loop_seed: ?LoopSeed, zon_type: ?Index) Error!Result {
    const gpa = ctx.db.gpa;
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
    const scope = try queries.enterContext(&r, owner.file, inst);
    defer scope.leave();
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
        .zon_type = zon_type,
    };
    @memset(inf.exprs, .unknown);
    @memset(inf.bindings, .unknown);
    @memset(inf.members, null);
    try inf.runOwner(tree.items[item].kind, mode);
    const ret = try inf.returnValue();
    const field_refs = try a.dupe(Result.FieldRef, inf.field_refs.items);
    const literal_expected = try a.dupe(Result.LiteralExpected, inf.literal_expected.items);
    const unknown_expected = try a.dupe(ExprId, inf.unknown_expected.items);
    const inactive = try a.dupe(ExprId, inf.inactive.items);
    const dead_spans = try a.dupe(Body.Range, inf.dead_spans.items);
    const param_coercions = try a.dupe(Result.ParamCoercion, inf.param_coercions.items);
    const iteration_vars = try a.dupe(Result.IterationVar, inf.iteration_vars.items);
    const zon_imports = try a.dupe(Result.ZonImport, inf.zon_imports.items);
    const uncoerced = try a.dupe(Result.Uncoerced, inf.uncoerced.items);
    return .{ .arena = arena.state, .exprs = inf.exprs, .bindings = inf.bindings, .members = inf.members, .ret = ret, .field_refs = field_refs, .literal_expected = literal_expected, .unknown_expected = unknown_expected, .inactive = inactive, .dead_spans = dead_spans, .param_coercions = param_coercions, .iteration_vars = iteration_vars, .zon_imports = zon_imports, .uncoerced = uncoerced };
}

/// Infers only one local binding or comptime expression in the member `owner` (see
/// `queries.LocalValue`)
pub fn runLocal(ctx: *Db.Ctx, owner: hir.OwnerKey, target_ref: @FieldType(queries.LocalKey, "target"), inst: ?Index) Error!TypedValue {
    const gpa = ctx.db.gpa;
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var r: Resolver = .{ .ctx = ctx, .arena = a };
    const scope = try queries.enterContext(&r, owner.file, inst);
    defer scope.leave();
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
        for (body.params, 0..) |p, i| inf.bindings[@backingInt(p)] = try inf.paramValue(p, own, i);
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
            // Local bindings outside the initializer are queried on demand (see `nameRef`)
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
        // A capture's value depends on control flow: it is the binding the whole member's
        // inference gives it
        .capture => {
            // In one iteration of a loop or `inline` prong, the reader is a container defined in
            // that iteration (`Inferrer.containerInst`), reached by the member's inference of the
            // iteration, which is still in progress: the same inference runs here, up to where the
            // capture is bound
            if (inf.iterationSeed() != null) {
                inf.stop_at = binding;
                try inf.runOwner(tree.items[item].kind, .full);
                return inf.bindings[@backingInt(binding)];
            }
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
    /// Return type of the function (the expected type of return)
    ret_type: ?Index = null,
    /// Labeled blocks and loops: types of the break values
    labels: std.ArrayList(LabelFrame) = .empty,
    /// Method calls: field accesses that resolve to a function declaration on an instance
    /// (the self parameter is skipped in the call)
    bound: std.AutoHashMapUnmanaged(ExprId, void) = .empty,
    /// References from field names in initializer expressions (see `Result.field_refs`)
    field_refs: std.ArrayList(Result.FieldRef) = .empty,
    /// The init expression being inferred
    current_init: ?ExprId = null,
    /// Range of the initializer expression when inferring only one local binding (`runLocal`):
    /// local bindings outside the range are not inferred and are queried on demand
    lazy: ?Body.Range = null,
    /// See `Result.literal_expected`
    literal_expected: std.ArrayList(Result.LiteralExpected) = .empty,
    /// See `Result.unknown_expected`
    unknown_expected: std.ArrayList(ExprId) = .empty,
    /// See `Result.inactive`
    inactive: std.ArrayList(ExprId) = .empty,
    /// See `Result.dead_spans`
    dead_spans: std.ArrayList(Body.Range) = .empty,
    /// See `Result.param_coercions`
    param_coercions: std.ArrayList(Result.ParamCoercion) = .empty,
    /// See `Result.zon_imports`
    zon_imports: std.ArrayList(Result.ZonImport) = .empty,
    /// See `Result.uncoerced`
    uncoerced: std.ArrayList(Result.Uncoerced) = .empty,
    /// Instance context (the instance of the owner itself or of an outer generic function)
    inst: ?Index,
    /// See `LoopSeed`
    loop_seed: ?LoopSeed = null,
    /// Greater than 0 inside a branch known at comptime not to execute: returns there do not count
    /// toward the result
    dead: u32 = 0,
    /// Nesting depth of control flow left undetermined by inference: branches of if / switch whose
    /// condition cannot be evaluated, and loop bodies not inferred per iteration.
    /// `comptime var` can only be modified under comptime-known control flow, so a modification in
    /// these places stems from a condition that inference cannot evaluate; the modified value is
    /// treated as unknown.
    uncertain: u32 = 0,
    /// `uncertain` at the declaration of each `comptime var` (parallel to `bindings`, allocated on
    /// the first declaration)
    var_levels: []u32 = &.{},
    /// See `Result.iteration_vars`
    iteration_vars: std.ArrayList(Result.IterationVar) = .empty,
    /// Inference mode (used to get the previous iteration's result in per-iteration inference)
    mode: Mode = .full,
    /// The owner is the root expression of a `.zon` file: values are converted to the result type
    /// by the rules of ZON (see `zonExpected`)
    zon: bool = false,
    /// See `queries.InferKey.zon_type`
    zon_type: ?Index = null,
    /// Values of the returns actually reached
    returns: std.ArrayList(TypedValue) = .empty,
    /// Greater than 0 inside a comptime context (type expressions, array lengths, comptime
    /// arguments, etc.): function calls there are evaluated by the interpreter
    comptime_depth: u32 = 0,
    /// Inside the operands of `@TypeOf` and not in a comptime context nested in them: the
    /// compiler analyzes these operands in a block without a comptime reason
    /// (`Sema.zirTypeofBuiltin`), so calls there are not executed even where the surrounding code
    /// is evaluated at comptime (see `comptimeOperand`)
    in_typeof: bool = false,
    /// Backward-branch quota of comptime evaluations started directly in the member (see
    /// `eval.bodyQuota`), computed on first use
    quota: ?u32 = null,
    /// Inferring the member only up to where this capture is bound (see `runLocal`): once it is
    /// bound, `stopped` is set and the rest of the member is not inferred
    stop_at: ?Body.BindingId = null,
    stopped: bool = false,

    /// Target of break. Only breaks actually reached are recorded (not those in branches known at
    /// comptime not to execute).
    const LabelFrame = struct {
        name: ?[]const u8,
        is_loop: bool,
        expected: ?Index = null,
        types: std.ArrayList(Index) = .empty,
        values: std.ArrayList(TypedValue) = .empty,
        /// The break value expressions: enum literals among them take the peer type (see
        /// `peerLiteral`)
        exprs: std.ArrayList(ExprId) = .empty,
    };

    fn runOwner(inf: *Inferrer, kind: ItemTree.Item.Kind, mode: Mode) Error!void {
        const b = inf.body;
        inf.mode = mode;
        switch (kind) {
            .@"fn" => {
                const own = inf.ownInstance();
                for (b.params, 0..) |p, i| inf.bindings[@backingInt(p)] = try inf.paramValue(p, own, i);
                if (b.type_expr) |t| inf.ret_type = (try inf.inferComptime(t, null)).asType();
                // The calling convention belongs to the signature: the function type reads it
                for (b.clauses) |c| if (c.kind == .@"callconv") {
                    _ = try inf.inferComptime(c.expr, try inf.clauseType(.@"callconv"));
                };
                if (mode == .full) if (b.value) |v| {
                    _ = try inf.infer(v, null);
                };
            },
            .@"const", .@"var", .field => {
                const annotation: ?Index = if (b.type_expr) |t| (try inf.inferComptime(t, null)).asType() else if (kind == .field) try inf.enumValueType() else null;
                // Alignment belongs to the signature: field layout reads it
                if (b.align_expr) |e| _ = try inf.inferComptime(e, try inf.clauseType(.@"align"));
                if (mode == .full) if (b.value) |v| {
                    _ = try inf.infer(v, annotation);
                };
            },
            .@"test", .@"comptime" => if (mode == .full) if (b.value) |v| {
                _ = try inf.infer(v, null);
            },
            // Inferred with the result type of the import sites, as the compiler parses ZON with
            // the result type
            .zon => if (mode == .full) if (b.value) |v| {
                inf.zon = true;
                _ = try inf.infer(v, inf.zon_type orelse try inf.r.ctx.get(queries.ZonResultType, inf.file));
            },
        }
        // Clauses are not part of the expression tree: infer them with the clause's result type
        if (mode == .full) for (b.clauses) |c| {
            _ = try inf.infer(c.expr, try inf.clauseType(c.kind));
        };
    }

    /// Result type of an enum member's value (`a = 1`): the explicitly given tag type
    fn enumValueType(inf: *Inferrer) Error!?Index {
        const tree = try inf.r.itemTree(inf.file);
        const container = tree.items[inf.item].container;
        if (tree.containers[container].kind != .@"enum") return null;
        const t = try queries.containerType(inf.r, .{ .file = inf.file, .container = container }, inf.inst);
        return eval.explicitTagType(inf.r, t);
    }

    /// Result type of the expression in a clause (matches the compiler)
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

    /// Attributes of the written pointer type `p` (with child `child`): its clauses are inferred
    /// with their result types and evaluated at comptime
    fn ptrAttrs(inf: *Inferrer, p: Body.PtrType, child: Index) Error!InternPool.PtrAttrs {
        if (p.@"align" == null and p.@"addrspace" == null) return .{ .is_volatile = p.is_volatile, .is_allowzero = p.is_allowzero };
        var vals: eval.PtrClauseValues = .{};
        if (p.@"align") |x| vals.@"align" = (try inf.inferComptime(x, try inf.clauseType(.@"align"))).val;
        if (p.bit_offset) |x| vals.bit_offset = (try inf.inferComptime(x, try inf.clauseType(.bit_range))).val;
        if (p.host_size) |x| vals.host_size = (try inf.inferComptime(x, try inf.clauseType(.bit_range))).val;
        if (p.@"addrspace") |x| vals.@"addrspace" = (try inf.inferComptime(x, try inf.clauseType(.@"addrspace"))).val;
        return eval.ptrAttrs(inf.r, child, p, vals);
    }

    fn branchQuota(inf: *Inferrer) u32 {
        if (inf.quota) |q| return q;
        const q = eval.bodyQuota(inf.r, inf.body, inf.exprs);
        inf.quota = q;
        return q;
    }

    /// Instance of this member when inferred per iteration (`loop_seed`), see
    /// `InternPool.Instance.iteration`; null when not inferred per iteration. For an undetermined
    /// iteration, the instance with `unknown_index`: the locals it queries on demand stay apart
    /// from the member's own inference too (see `LoopSeed`).
    fn iterationInstance(inf: *Inferrer) Error!?Index {
        const seed = inf.loop_seed orelse return null;
        return try inf.instanceAt(seed.binding, seed.index);
    }

    /// The loop seed when inferring one actual iteration; null when not inferred per iteration
    /// and for an undetermined iteration, which has no particular value of the loop variable
    /// (see `LoopSeed`)
    fn iterationSeed(inf: *const Inferrer) ?LoopSeed {
        const seed = inf.loop_seed orelse return null;
        return if (seed.index == InternPool.Instance.Iteration.unknown_index) null else seed;
    }

    /// Instance of this member at the `index`-th iteration of the loop variable `binding`
    fn instanceAt(inf: *Inferrer, binding: u32, index: u32) Error!Index {
        if (inf.ownInstance()) |own| {
            var key = own;
            key.iteration = .{ .binding = binding, .index = index, .abstract = false };
            return inf.ip.get(.{ .instance = key });
        }
        const decl = (try inf.r.itemTree(inf.file)).items[inf.item].ast_id;
        return inf.ip.get(.{ .instance = .{ .file = inf.file, .decl = decl, .args = &.{}, .parent = inf.inst, .iteration = .{ .binding = binding, .index = index, .abstract = true } } });
    }

    /// Instance of the container defined at `e` in this member. Field types of a container inside
    /// a loop body analyzed separately for each iteration (`inline for`, `inline` switch prong)
    /// may depend on the loop variable: per-iteration inference uses this iteration's instance;
    /// otherwise the instance with an undetermined iteration is used (its types are not concrete).
    fn containerInst(inf: *Inferrer, e: ExprId) Error!?Index {
        const at = inf.body.range(e).start;
        if (inf.iterationSeed()) |seed| if (seedRegion(inf.body, seed.binding)) |rg| if (rg.contains(at)) return try inf.instanceAt(seed.binding, seed.index);
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
        const key = switch (inf.ip.key(i)) {
            .instance => |x| x,
            else => return null,
        };
        if (key.file != inf.file) return null;
        const tree = inf.r.itemTree(inf.file) catch return null;
        return if (key.decl == tree.items[inf.item].ast_id) key else null;
    }

    /// Value of the `i`-th parameter `p` in the function's own instance `own`: in an instance, a
    /// comptime parameter takes the argument value (coerced to the parameter type), an anytype
    /// parameter recorded by value (such as `comptime x: anytype`, see
    /// `InternPool.Instance.arg_types`) takes the argument value and the argument type the
    /// instance records, and another anytype parameter takes the type of the argument;
    /// without a concrete argument, a type parameter (`comptime T: type`, or `T: type` without
    /// comptime) is an abstract parameter
    fn paramValue(inf: *Inferrer, p: Body.BindingId, own: ?InternPool.Instance, i: usize) Error!TypedValue {
        const arg: ?Index = if (own) |o| (if (i < o.args.len) o.args[i] else .unknown) else null;
        const binding = inf.body.binding(p);
        const ty_e = binding.ty orelse {
            const a = arg orelse return .unknown;
            if (binding.is_comptime or own.?.byValue(i)) {
                // The value does not always give back the argument type (a non-null optional is
                // its payload): without a recorded type the parameter is unknown
                const t = own.?.argType(i);
                if (t == .unknown) return .unknown;
                return .{ .ty = t, .val = if (a == .unknown or a == .runtime) null else a };
            }
            if (a == .runtime or a == .unknown) return .unknown;
            // anytype: the instance records the argument type
            return .{ .ty = a, .val = try value.comptimeFieldsValue(inf.ip, inf.scratch, a) };
        };
        const ty: Index = (try inf.inferComptime(ty_e, null)).asType() orelse .unknown;
        if (arg) |a| if (a != .unknown and a != .runtime) return .{ .ty = ty, .val = (try value.coerceValue(inf.ip, try inf.paramTag(a, ty), ty)) orelse a };
        if (ty == .type_type and (arg == null or arg.? == .unknown)) return TypedValue.ofType(try inf.ip.get(.{ .opaque_param = .{ .file = inf.file, .owner = try inf.body_owner(), .binding = @backingInt(p), .name = binding.name } }));
        return .{ .ty = ty, .val = try value.comptimeFieldsValue(inf.ip, inf.scratch, ty) };
    }

    /// An enum defined in the signature (`comptime sign: enum { pos, neg }`) has a type per
    /// instance: the argument the instance records was coerced to the parameter type of the
    /// signature the caller saw, and is the same value of the parameter type here
    fn paramTag(inf: *Inferrer, a: Index, ty: Index) Error!Index {
        const ip = inf.ip;
        const enum_ty = switch (ip.key(a)) {
            .enum_tag => |t| t.ty,
            .enum_unnamed => |u| u.ty,
            else => return a,
        };
        const x = switch (ip.key(enum_ty)) {
            .container_type => |c| c,
            else => return a,
        };
        const y = switch (ip.key(ty)) {
            .container_type => |c| c,
            else => return a,
        };
        if (enum_ty == ty or x.file != y.file or x.ast_id != y.ast_id) return a;
        return switch (ip.key(a)) {
            .enum_unnamed => |u| ip.get(.{ .enum_unnamed = .{ .ty = ty, .int = u.int } }),
            else => ip.get(.{ .enum_tag = .{ .ty = ty, .name = ip.key(a).enum_tag.name } }),
        };
    }

    /// Reading the ItemTree is a query: even when it is cached, `error.Canceled` is returned when
    /// the read transaction is canceled by a write transaction or by the client
    fn body_owner(inf: *Inferrer) Error!ItemTree.AstId {
        return (try inf.r.itemTree(inf.file)).items[inf.item].ast_id;
    }

    /// Value of the returns actually reached: carries the value when they are all the same;
    /// otherwise the peer type of their types
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

    /// When the returns under conditions that cannot be evaluated are all different instances of
    /// the same container definition (a self-recursive type function, such as
    /// `return Aligned(T, null)` and `return struct {...}` in `Aligned`), takes the one in this
    /// instance
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

    /// Whether a condition whose value cannot be evaluated is comptime-known (e.g. because it
    /// depends on an abstract parameter): with a comptime-only result type, or when the condition
    /// is comptime-known (see `comptimeKnown`)
    fn comptimeCond(inf: *Inferrer, cond: ExprId, result: Index) Error!bool {
        if (value.isComptimeOnly(inf.ip, result)) return true;
        return inf.comptimeKnown(cond);
    }

    /// Whether the value of `e` is comptime-known even when inference cannot compute it: in a
    /// comptime context, in initializers of container-level constants and variables and in fields
    /// (evaluated at comptime), or when `knownness` finds it comptime-known
    fn comptimeKnown(inf: *Inferrer, e: ExprId) Error!bool {
        if (inf.comptime_depth > 0) return true;
        const kind = (try inf.r.itemTree(inf.file)).items[inf.item].kind;
        if (kind != .@"fn" and kind != .@"test") return true;
        return try inf.knownness(e, 0) == .comptime_known;
    }

    /// A comptime-known condition: a bool value, or whether an optional is null (the value of a
    /// non-null optional is its payload value)
    fn isCompileError(inf: *Inferrer, e: ExprId) bool {
        return switch (inf.body.expr(e)) {
            .builtin_call => |c| std.mem.eql(u8, c.name, "@compileError"),
            else => false,
        };
    }

    fn condValue(inf: *Inferrer, cond: TypedValue) ?bool {
        const v = cond.val orelse return null;
        switch (inf.ip.key(cond.ty)) {
            // Non-null optionals and successful error unions are represented by their payload
            // values; a `false` payload still means success
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

    /// The operand `e` of `catch` / `orelse` (inferred as `tv`) with its comptime value. With a
    /// comptime-known operand the compiler analyzes only the side that is taken
    /// (`Sema.zirCondbr`), so the type of the whole expression depends on this value. Inference
    /// executes calls only in comptime contexts, but the compiler also evaluates the
    /// initializers of container-level constants and variables, fields and `comptime` blocks at
    /// comptime: there the interpreter computes the operand. Operands of `@TypeOf` are analyzed
    /// without a comptime reason, so calls in them stay runtime.
    fn comptimeOperand(inf: *Inferrer, e: ExprId, tv: TypedValue) Error!TypedValue {
        if (tv.val) |v| if (v != .unknown) return tv;
        switch (inf.ip.key(tv.ty)) {
            .error_union_type, .optional_type => {},
            else => return tv,
        }
        if (inf.in_typeof or inf.dead != 0 or inf.r.ctx.incomplete()) return tv;
        if (inf.comptime_depth == 0) {
            const kind = (try inf.r.itemTree(inf.file)).items[inf.item].kind;
            if (kind == .@"fn" or kind == .@"test") return tv;
        }
        const ev = try eval.exprValue(inf.r, inf.file, inf.item, inf.body, e, inf.inst, inf.bindings, null, inf.branchQuota());
        return if (ev.val != null and ev.ty == tv.ty) ev else tv;
    }

    /// Branch of an `if` / `switch`: a branch that will not execute is recorded as inactive code
    /// (see `Result.inactive`)
    fn inferArm(inf: *Inferrer, e: ExprId, expected: ?Index, dead_branch: bool) Error!TypedValue {
        if (dead_branch and inf.dead == 0) try inf.inactive.append(inf.scratch, e);
        return inf.inferBranch(e, expected, dead_branch);
    }

    /// Infers in the "will not execute" state when `dead_branch` is true
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
        return inf.inferWith(e, expected, true);
    }

    /// Infers `e` with the result type `expected` without coercing the result to it, for operands
    /// the compiler type-checks as written before coercing them (the operand of a rounding
    /// builtin, see `roundCast`)
    fn inferUncoerced(inf: *Inferrer, e: ExprId, expected: ?Index) Error!TypedValue {
        return inf.inferWith(e, expected, false);
    }

    fn inferWith(inf: *Inferrer, e: ExprId, expected: ?Index, comptime coerce_result: bool) Error!TypedValue {
        if (inf.stopped) return .unknown;
        const i = @backingInt(e);
        if (inf.done.isSet(i)) return inf.exprs[i];
        inf.done.set(i);
        // Nesting too deep (deep expressions or query recursion): end with unknown without
        // caching the result
        if (inf.r.ctx.stackExhausted()) {
            inf.r.ctx.exhausted();
            return .unknown;
        }
        const want = if (inf.zon) try inf.zonExpected(e, expected) else expected;
        const raw = try inf.inferInner(e, want);
        if (inf.var_levels.len != 0) if (try inf.indirectlyModifiedVar(inf.body.expr(e))) |v| inf.untrackComptimeVar(v);
        const tv = if (coerce_result) try inf.coerce(raw, want) else raw;
        inf.exprs[i] = tv;
        // Enum literals coerced to an enum / union (`.red`, `.a =>` in a `switch`) refer to the
        // corresponding member
        if (inf.members[i] == null and inf.body.expr(e) == .enum_literal) try inf.recordTagMember(e, tv.ty);
        if (raw.ty == .enum_literal_type) if (want) |w| try inf.noteParamCoercion(e, w);
        if (want) |w| if (!deepEql(raw, tv)) try inf.noteUncoerced(e, raw, w);
        // A ZON value parsed as the pointee or as an array has the result type (pointer, slice)
        if (want != expected) inf.exprs[i] = .{ .ty = expected.? };
        return inf.exprs[i];
    }

    /// See `Result.uncoerced`: `raw` is the value of `e` before its coercion to `want`
    fn noteUncoerced(inf: *Inferrer, e: ExprId, raw: TypedValue, want: Index) Error!void {
        const own: TypedValue = switch (inf.body.expr(e)) {
            // Primitive values (`null`, `undefined`) refer to no definition: they keep the type
            // they are coerced to
            .name_ref => |name| if (!inf.body.nameRefIsEscaped(e) and try primitive(inf.ip, name) != null) return else raw,
            .field_access, .builtin_call => raw,
            // An enum literal is a tag of the enum it is coerced to, without the optional or
            // error union around it
            .enum_literal => if (raw.ty == .enum_literal_type) try inf.coerce(raw, inf.destType(want, .eu_opt) orelse return) else raw,
            else => return,
        };
        if (deepEql(own, inf.get(e))) return;
        try inf.uncoerced.append(inf.scratch, .{ .expr = e, .tv = own });
    }

    /// When the compiler parses a ZON value with a result type (`LowerZon`), the value of an
    /// optional is parsed as the payload type and the value of a single-item pointer as the pointee
    /// type, and the value of a slice is an array literal (a `[]const u8` may also be a string):
    /// `.{ a, b }` is inferred as `[2]T`. Returns the type the value is parsed as when it goes
    /// through a pointer, otherwise `expected` unchanged (each kind of value handles optionals
    /// itself, as in Zig source)
    fn zonExpected(inf: *Inferrer, e: ExprId, expected: ?Index) Error!?Index {
        const ip = inf.ip;
        const x = expected orelse return null;
        var t = x;
        var through_ptr = false;
        while (true) switch (ip.key(t)) {
            .optional_type => |c| t = c,
            .ptr_type => |p| switch (p.size) {
                .one => {
                    t = p.child;
                    through_ptr = true;
                },
                .slice => {
                    const init = switch (inf.body.expr(e)) {
                        .init => |init| init,
                        else => break,
                    };
                    if (init.ty != null) break;
                    return try ip.get(.{ .array_type = .{ .len = init.fields.len, .child = p.child, .sentinel = p.sentinel } });
                },
                .many, .c => break,
            },
            else => break,
        };
        return if (through_ptr) t else x;
    }

    /// Records the result type of a literal: see `Result.literal_expected`, and
    /// `Result.unknown_expected` when the result type is unknown
    fn noteExpected(inf: *Inferrer, e: ExprId, want: Index) Error!void {
        if (want == .unknown) return inf.unknown_expected.append(inf.scratch, e);
        try inf.literal_expected.append(inf.scratch, .{ .expr = e, .ty = want });
    }

    /// `e` has a result type that is unknown (the target of an assignment, a parameter of an
    /// unknown callee, a field of an unknown container): a literal that takes its members from its
    /// result type (an enum literal, the callee of a decl literal call, an anonymous initializer)
    /// is recorded in `Result.unknown_expected`
    fn noteUnknownResult(inf: *Inferrer, e: ExprId) Error!void {
        const b = inf.body;
        switch (b.expr(e)) {
            .enum_literal => {},
            .init => |x| if (x.ty != null) return,
            .call => |c| return if (b.expr(c.callee) == .enum_literal) inf.noteUnknownResult(c.callee),
            .prefix => |p| return if (p.op == .keyword_try) inf.noteUnknownResult(p.operand),
            else => return,
        }
        try inf.unknown_expected.append(inf.scratch, e);
    }

    /// Branch results without a result type are coerced to the peer type
    /// (`if (b.op()) |t| t.kind else .invalid`): enum literals in the branches refer to members of
    /// the peer type and use it as their expected type (naming only its tags)
    fn peerLiteral(inf: *Inferrer, e: ExprId, ty: Index) Error!void {
        if (ty == .unknown or ty == .enum_literal_type) return;
        if (inf.body.expr(e) != .enum_literal or inf.members[@backingInt(e)] != null) return;
        if (inf.get(e).ty != .enum_literal_type) return;
        try inf.literal_expected.append(inf.scratch, .{ .expr = e, .ty = ty, .tags_only = true });
        try inf.recordTagMember(e, ty);
    }

    /// Operand `e` (inferred as `tv`) of a comparison whose other operand has type `other`.
    /// Matching the compiler, comparison operands have no result type and are coerced to their
    /// peer type: an enum literal compared with an enum or a tagged union names one of its tags
    /// (never a declaration), and has no value when it names none (a compile error); a comptime
    /// number compared with a float is rounded to it; an error value takes the other side's type
    /// as its expected type (for completing error names).
    fn comparedOperand(inf: *Inferrer, e: ExprId, tv: TypedValue, other: Index) Error!TypedValue {
        switch (tv.ty) {
            .enum_literal_type => if (try inf.comparedType(other)) |t| if (t != .enum_literal_type) {
                try inf.peerLiteral(e, t);
                const v = tv.val orelse return tv;
                if (!try inf.hasTag(t, inf.ip.key(v).enum_literal)) return tv;
                const c = try inf.coerce(tv, t);
                if (inf.body.expr(e) == .enum_literal) inf.exprs[@backingInt(e)] = c;
                return c;
            },
            .comptime_int_type, .comptime_float_type => if (inf.ip.isFloat(other)) return inf.coerce(tv, other),
            else => if (inf.body.expr(e) == .error_value) if (try inf.comparedType(other)) |t| {
                try inf.literal_expected.append(inf.scratch, .{ .expr = e, .ty = t });
            },
        }
        return tv;
    }

    /// Whether the enum `t` (or the tag enum of a tagged union, or either through an optional)
    /// has the tag `name`
    fn hasTag(inf: *Inferrer, t: Index, name: []const u8) Error!bool {
        const ip = inf.ip;
        var x = t;
        if (ip.key(x) == .optional_type) x = ip.key(x).optional_type;
        if (ip.key(x) == .union_tag_type) x = ip.key(x).union_tag_type;
        switch (ip.key(x)) {
            .container_type => |c| {
                if (c.kind != .@"enum" and c.kind != .@"union") return false;
                const ns = try queries.namespaceOfType(inf.r, x) orelse return false;
                return fieldItem(try inf.r.itemTree(ns.file), ns.container, name) != null;
            },
            .reified_type => |rt| return rt.kind != .@"struct" and hasName(rt.names, name),
            else => return false,
        }
    }

    /// See `Result.param_coercions`: `e` is a reference to a parameter of this member, used with
    /// the expected type `want`
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

    /// Expression in a comptime context (type annotations, parameter and return types, array
    /// lengths). When inference cannot determine its value, the outermost one is handed to the
    /// interpreter to evaluate with the current bindings (e.g.
    /// `fn f(comptime T: type) switch (@typeInfo(T)) {...}`).
    fn inferComptime(inf: *Inferrer, e: ExprId, expected: ?Index) Error!TypedValue {
        const outermost = inf.comptime_depth == 0;
        const in_typeof = inf.in_typeof;
        inf.comptime_depth += 1;
        inf.in_typeof = false;
        const tv = blk: {
            defer {
                inf.comptime_depth -= 1;
                inf.in_typeof = in_typeof;
            }
            break :blk try inf.infer(e, expected);
        };
        if (tv.val != null or inf.dead > 0 or inf.stopped) return tv;
        // String literals in comptime arguments (the inferrer normally produces no values for
        // strings): matching the interpreter, the type of the value is `*const [N:0]u8`
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
        // When the result type is `E!U`, `?U`, or `E!?U`, coerce to U
        // (`fn parse() Error!Value { return .null_val; }`)
        const want = inf.destType(t, .eu_opt) orelse return;
        // Tag enum generated by `union(enum)`: its members are the fields of the union
        const want_union = switch (inf.ip.key(want)) {
            .union_tag_type => |u| u,
            else => want,
        };
        return inf.recordTagMemberOf(e, want_union);
    }

    fn recordTagMemberOf(inf: *Inferrer, e: ExprId, want: Index) Error!void {
        const name = inf.body.expr(e).enum_literal;
        const c = switch (inf.ip.key(want)) {
            .container_type => |c| c,
            // A tag of an enum or union constructed from the members of a container
            // (`std.meta.FieldEnum(T)` builds its tags from the fields of T): the member it is
            // named after, which a rename of that member has to follow
            .reified_type => |rt| {
                if (rt.kind == .@"struct") return;
                for (rt.names) |n| {
                    if (std.mem.eql(u8, n, name)) break;
                } else return;
                const def = try typeInfoMember(inf.r, rt, name) orelse return;
                inf.members[@backingInt(e)] = try defKey(inf.r, def);
                return;
            },
            else => return,
        };
        if (c.kind != .@"enum" and c.kind != .@"union") return;
        const ns = try queries.namespaceOfType(inf.r, want) orelse return;
        const tree = try inf.r.itemTree(ns.file);
        const f = fieldItem(tree, ns.container, name) orelse return;
        inf.members[@backingInt(e)] = .{ .file = ns.file, .item = tree.items[f].ast_id };
    }

    /// Result type coercion: literal-like values take the expected type when there is one (with an
    /// optional expected type, they are first coerced to the payload type), and values of `T` are
    /// coerced to `?T`
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
                // `E!T`: the literal is coerced to the payload type T (and then wrapped into an
                // error union by the compiler)
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
        // A value of `T` coerced to `?T` is the payload of a non-null optional (a null `?u8`
        // coerced to `??u8` is not null)
        if (target != want and tv.ty == target) return .{ .ty = want, .val = if (tv.val) |v| try value.wrapOptional(ip, want, v) else null };
        // An error coerced to an error union keeps its value, which marks the union as failed; a
        // payload keeps its value coerced to the payload type, which marks the union as successful
        if (tv.val) |v| switch (ip.key(want)) {
            .error_union_type => |eu| {
                if (ip.key(v) == .error_value) return .{ .ty = want, .val = v };
                const payload = try inf.coerce(tv, eu.payload);
                if (payload.ty == eu.payload) return .{ .ty = want, .val = payload.val };
            },
            else => {},
        };
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
                if (expected) |want| try inf.noteExpected(e, want);
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
                inf.captureBound(x.capture);
                inf.captureBound(x.else_capture);
                const taken = inf.condValue(cond);
                if (taken == null) inf.uncertain += 1;
                const then = try inf.inferArm(x.then, expected, taken == false);
                const other: TypedValue = if (x.@"else") |el| try inf.inferArm(el, expected, taken == true) else .{ .ty = .void_type };
                if (taken == null) inf.uncertain -= 1;
                if (taken) |t| {
                    // The chosen branch is `@compileError`: a declaration that is used cannot be a
                    // compile error (otherwise compilation would fail), so the code using it is
                    // compiled only in configurations where the other branch applies. For example,
                    // `std.testing.allocator = if (builtin.is_test) .. else @compileError(..)`
                    // used in a test block of a non-test module: take the other branch.
                    if (x.@"else") |el| {
                        const chosen, const rest = if (t) .{ x.then, el } else .{ el, x.then };
                        if (inf.isCompileError(chosen) and !inf.isCompileError(rest)) return if (t) other else then;
                    }
                    return if (t) then else other;
                }
                const ty = try inf.peer(&.{ then.ty, other.ty });
                try inf.peerLiteral(x.then, ty);
                if (x.@"else") |el| try inf.peerLiteral(el, ty);
                return .{ .ty = ty, .val = if (try inf.comptimeCond(x.cond, ty)) try sameLiveValue(ip, &.{ then, other }, ty) else null };
            },
            .loop => |l| return inf.loop(l, expected),
            .@"switch" => |s| {
                const operand = try inf.infer(s.operand, null);
                // A tagged union is matched by its tag: prong items are inferred with the tag
                // type, since coercing them to the union itself would lose the value and no
                // executed prong could be chosen
                const item_ty = try inf.comparedType(operand.ty);
                for (s.prongs) |prong| for (prong.items) |item| {
                    // Items of a switch on a value of unknown type have an unknown result type
                    if (operand.ty == .unknown) try inf.noteUnknownResult(item);
                    // `a...b`: the compiler coerces both bounds to the item type, like a scalar item
                    if (switchRange(inf.body, item)) |range| for (range) |bound| {
                        _ = try inf.infer(bound, item_ty);
                    };
                    _ = try inf.infer(item, item_ty);
                };
                // Labeled switch: the value of `break :label value` is also a result
                const label = inf.switchLabel(e, s.operand);
                // comptime-known operand: only the matching prong executes. `continue :label`
                // jumps to other prongs, so no prong is chosen when it is present.
                const chosen = if (label != null and inf.continuesTo(label.?)) null else try inf.chooseProng(s.prongs, operand);
                if (label) |name| try inf.labels.append(inf.scratch, .{ .name = name, .is_loop = false, .expected = expected });
                var types: std.ArrayList(Index) = .empty;
                var values: std.ArrayList(TypedValue) = .empty;
                var chosen_tv: TypedValue = .unknown;
                if (chosen == null) inf.uncertain += 1;
                defer if (chosen == null) {
                    inf.uncertain -= 1;
                };
                for (s.prongs, 0..) |prong, i| {
                    try inf.bindSwitchCapture(s.prongs, i, s.operand, operand, chosen != null and chosen.? == i);
                    inf.captureBound(prong.capture);
                    const tv = try inf.inferArm(prong.body, expected, chosen != null and chosen.? != i);
                    if (chosen != null and chosen.? == i) chosen_tv = tv;
                    try types.append(inf.scratch, tv.ty);
                    try values.append(inf.scratch, tv);
                }
                var break_exprs: []const ExprId = &.{};
                if (label != null) {
                    const frame = inf.labels.pop().?;
                    break_exprs = frame.exprs.items;
                    // When a prong is chosen, only its breaks are recorded (the other prongs are
                    // inferred as not executing)
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
                        try inf.peerLiteral(s.prongs[chosen.?].body, t);
                        for (frame.exprs.items) |x| try inf.peerLiteral(x, t);
                        return .{ .ty = t, .val = sameValue(live_values.items, t) };
                    }
                    try types.appendSlice(inf.scratch, frame.types.items);
                    try values.appendSlice(inf.scratch, frame.values.items);
                }
                if (chosen != null) return chosen_tv;
                const ty = try inf.peer(types.items);
                for (s.prongs) |prong| try inf.peerLiteral(prong.body, ty);
                for (break_exprs) |x| try inf.peerLiteral(x, ty);
                return .{ .ty = ty, .val = if (try inf.comptimeCond(s.operand, ty)) try sameLiveValue(ip, values.items, ty) else null };
            },
            .@"catch" => |c| {
                const lhs = try inf.comptimeOperand(c.lhs, try inf.infer(c.lhs, null));
                const payload, const err = inf.unwrapErrorUnion(lhs.ty);
                // When comptime-known, only one side is evaluated, and a right-hand side that is
                // taken gets only the result type of the whole expression
                const ok = inf.condValue(lhs);
                // The capture of a comptime-known error is that error
                if (c.capture) |cap| {
                    inf.bindings[@backingInt(cap)] = .{ .ty = err, .val = if (ok == false) lhs.val else null };
                    inf.captureBound(&.{cap});
                }
                const rhs = try inf.inferBranch(c.rhs, inf.fallbackType(expected, if (ok == false) .unknown else payload, c.rhs), ok == true);
                if (ok) |o| return if (o) .{ .ty = payload, .val = lhs.val } else rhs;
                return .{ .ty = try inf.peer(&.{ payload, rhs.ty }) };
            },
            .binary => |bin| return inf.binary(e, bin.op, bin.lhs, bin.rhs, expected),
            .prefix => |p| return inf.prefix(p.op, p.operand, expected),
            .assign => |a| {
                const lhs = try inf.infer(a.lhs, null);
                if (lhs.ty == .unknown) try inf.noteUnknownResult(a.rhs);
                const rhs = try inf.infer(a.rhs, try inf.assignRhsType(a.op, lhs.ty));
                if (try inf.comptimeVarOf(a.lhs)) |v| try inf.assignComptimeVar(v, a.op, rhs);
                return .{ .ty = .void_type };
            },
            .index => |x| {
                const lhs = try inf.infer(x.lhs, null);
                const i = try inf.infer(x.index, .usize_type);
                // Tuples (including pointers to tuples): with a comptime-known index, take the
                // field's type; values of comptime fields belong to the type
                if (tupleOf(ip, lhs.ty)) |tt| if (value.intOf(ip, i.val)) |n| if (std.math.cast(usize, n)) |k| if (k < tt.types.len) {
                    if (lhs.val != null) if (try eval.elemValue(inf.r, lhs, k)) |ev| return .{ .ty = tt.types[k], .val = ev.val };
                    const v = InternPool.fieldValue(tt.values, k);
                    return .{ .ty = tt.types[k], .val = if (v == .runtime or v == .unknown) null else v };
                };
                const elem = inf.elementType(lhs.ty);
                // comptime-known aggregate and index: extract the element
                if (lhs.val != null) if (value.intOf(ip, i.val)) |n| if (std.math.cast(usize, n)) |k| if (try eval.elemValue(inf.r, lhs, k)) |ev| {
                    return .{ .ty = if (elem != .unknown) elem else ev.ty, .val = ev.val };
                };
                return .{ .ty = elem };
            },
            .slice => |s| return inf.slice(e, s.lhs, s.start, s.end, s.sentinel),
            .deref => |x| {
                const p = try inf.infer(x, null);
                const pt = switch (ip.key(p.ty)) {
                    // C pointers can be dereferenced too (`[*c]T` generated by translate-c)
                    .ptr_type => |pt| if (pt.size != .many) pt else return .unknown,
                    else => return .unknown,
                };
                // A comptime-known slice dereferences to the array of its elements
                // (`[len:sentinel]T`); a runtime-known one cannot be dereferenced
                const child = if (pt.size == .slice) child: {
                    if (p.val == null) {
                        // Inference does not compute every comptime-known slice (`&.{ 1, 2 }`
                        // coerced to a slice): the interpreter evaluates the dereference
                        if (inf.dead != 0 or inf.r.ctx.incomplete()) return .unknown;
                        const tv = try eval.exprValue(inf.r, inf.file, inf.item, inf.body, e, inf.inst, inf.bindings, null, inf.branchQuota());
                        return if (tv.val != null and ip.key(tv.ty) == .array_type) tv else .unknown;
                    }
                    const len = try eval.elemCount(inf.r, p) orelse return .unknown;
                    break :child try ip.get(.{ .array_type = .{ .len = len, .child = pt.child, .sentinel = pt.sentinel } });
                } else pt.child;
                // comptime-known pointer to a constant: the interpreter reads the pointee
                if (pt.is_const) if (try inf.knownValue(e, p.val, child)) |tv| return tv;
                return .{ .ty = child };
            },
            .unwrap_optional => |x| {
                const o = try inf.infer(x, null);
                const child: Index = switch (ip.key(o.ty)) {
                    .optional_type => |c| c,
                    else => .unknown,
                };
                // A known non-null optional value is its payload value
                return .{ .ty = child, .val = if (child != .unknown and inf.condValue(o) == true) value.optionalPayload(ip, o.val.?) else null };
            },
            .init => |x| {
                if (x.ty == null) if (expected) |want| try inf.noteExpected(e, want);
                const saved = inf.current_init;
                inf.current_init = e;
                defer inf.current_init = saved;
                return inf.initExpr(x.ty, x.fields, expected);
            },
            .container => |c| {
                if (c.arg) |arg| _ = try inf.infer(arg, null);
                const ns = try inf.containerAt(e) orelse return .unknown;
                const inst = try inf.containerInst(e);
                return TypedValue.ofType(if (inf.mode == .signature) try queries.prototypeContainerType(inf.r, ns, inst) else try queries.containerType(inf.r, ns, inst));
            },
            .fn_type => |f| {
                const params = try inf.scratch.alloc(Index, f.params.len);
                for (f.params, params) |p, *out| out.* = if (p.ty) |t| (try inf.infer(t, null)).asType() orelse .unknown else .unknown;
                const ret = if (f.ret) |r| (try inf.infer(r, null)).asType() orelse .unknown else .unknown;
                const cc: InternPool.CallConv = if (f.@"callconv") |x| try eval.writtenCallConv(inf.r, inf.body, x, (try inf.inferComptime(x, try inf.clauseType(.@"callconv"))).val) else .auto;
                const bits = eval.fnTypeBits(f.params);
                return TypedValue.ofType(try ip.get(.{ .fn_type = .{ .params = params, .ret = ret, .varargs = f.varargs, .cc = cc, .comptime_bits = bits.comptime_bits, .noalias_bits = bits.noalias_bits, .generic_bits = bits.generic_bits } }));
            },
            .@"return" => |v| {
                const ret: TypedValue = if (v) |x| try inf.infer(x, inf.ret_type) else .{ .ty = .void_type };
                if (inf.dead == 0) try inf.returns.append(inf.scratch, ret);
                return .{ .ty = .noreturn_type };
            },
            .@"break" => |br| {
                // Find the target first: the break value is inferred with the block's expected type
                const frame_index = inf.labelFrame(br.label);
                const want: ?Index = if (frame_index) |fi| inf.labels.items[fi].expected else null;
                const brk: TypedValue = if (br.value) |v| try inf.infer(v, want) else .{ .ty = .void_type };
                // labels may grow during inference, so re-fetch the frame by index
                if (frame_index) |fi| if (inf.dead == 0) {
                    const frame = &inf.labels.items[fi];
                    try frame.types.append(inf.scratch, brk.ty);
                    try frame.values.append(inf.scratch, brk);
                    if (br.value) |v| try frame.exprs.append(inf.scratch, v);
                };
                return .{ .ty = .noreturn_type };
            },
            .@"continue" => |c| {
                // `continue :l value` of a labeled switch: the value is inferred with the type
                // of the switch operand
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
                // When the error set cannot be evaluated (`B.Error` of an abstract parameter),
                // keep the payload type: the result of `try` can still be determined
                if (payload == .unknown) return typeUnknown();
                return TypedValue.ofType(try ip.get(.{ .error_union_type = .{ .err = err, .payload = payload } }));
            },
            .ptr_type => |p| {
                const child = (try inf.infer(p.child, null)).asType() orelse return typeUnknown();
                const sentinel: ?Index = if (p.sentinel) |x| (try inf.infer(x, child)).val else null;
                const attrs = try inf.ptrAttrs(p, child);
                if (child == .unknown) return typeUnknown();
                return TypedValue.ofType(try ip.get(.{ .ptr_type = .{ .child = child, .size = @fromBackingInt(@intCast(@backingInt(p.size))), .is_const = p.is_const, .sentinel = sentinel, .attrs = attrs } }));
            },
            .array_type => |arr| {
                const len = try inf.inferComptime(arr.len, .usize_type);
                const child = (try inf.infer(arr.child, null)).asType() orelse return typeUnknown();
                const sentinel: ?Index = if (arr.sentinel) |x| (try inf.infer(x, child)).val else null;
                const n: u64 = if (len.val) |v| switch (ip.key(v)) {
                    .int_value => |iv| std.math.cast(u64, iv.value) orelse return typeUnknown(),
                    else => return typeUnknown(),
                } else {
                    // The length cannot be evaluated; the element type is known. When the length
                    // depends on an abstract parameter, it is shown as in the source; otherwise
                    // (in a concrete instance, where the source text would belong to the
                    // declaration, not to the instance) no instance determines it, and it is
                    // unknown
                    if (child == .unknown or (arr.sentinel != null and sentinel == null)) return typeUnknown();
                    if (!try inf.dependsOnAbstract(arr.len, 0)) return TypedValue.ofType(try ip.get(.{ .abstract_array_type = .{ .len = null, .child = child, .sentinel = sentinel } }));
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

    // ── Names ────────────────────────────────────────────────────────

    fn nameRef(inf: *Inferrer, e: ExprId, name: []const u8) Error!TypedValue {
        const b = inf.body;
        if (!b.nameRefIsEscaped(e)) if (try primitive(inf.ip, name)) |tv| return tv;
        const def = try inf.r.resolveName(inf.file, inf.item, b, b.expr_scopes[@backingInt(e)], name) orelse return .unknown;
        if (inf.lazy) |range| if (def == .local) {
            const l = def.local;
            // A local binding of this member (those of outer members are queried by defType
            // through LocalValue)
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
            else => if (Body.zonFloatValue(text)) |x| {
                return .{ .ty = .comptime_float_type, .val = try value.floatValue(ip, .comptime_float_type, x) };
            } else switch (std.zig.parseNumberLiteral(text)) {
                .int => |v| return .{ .ty = .comptime_int_type, .val = try ip.get(.{ .int_value = .{ .ty = .comptime_int_type, .value = v } }) },
                .big_int => |base| {
                    const b = try bigint.fromLiteral(inf.scratch, text, @backingInt(base)) orelse return .{ .ty = .comptime_int_type };
                    return .{ .ty = .comptime_int_type, .val = try value.internInt(ip, inf.scratch, .comptime_int_type, b) };
                },
                .float => {
                    const x = std.fmt.parseFloat(f128, text) catch return .{ .ty = .comptime_float_type };
                    return .{ .ty = .comptime_float_type, .val = try value.floatValue(ip, .comptime_float_type, x) };
                },
                .failure => return .unknown,
            },
        }
    }

    // ── Member access ────────────────────────────────────────────────

    fn fieldAccess(inf: *Inferrer, e: ExprId, lhs_e: ExprId, field: ?[]const u8) Error!TypedValue {
        const ip = inf.ip;
        const lhs = try inf.infer(lhs_e, null);
        const name = field orelse return .unknown;
        // Members on a type: declarations, enum members, error set members
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
                // Members of constructed enums (`@Enum`, the tag enum of a union(enum))
                .reified_type, .union_tag_type => return try eval.typeMember(inf.r, t, name) orelse .unknown,
                // The value under the current configuration is not a container (`std.c.EVFILT`
                // is void on linux)
                else => return try inf.otherBranchMember(e, lhs_e, t, name) orelse .unknown,
            }
        }
        var tv = try inf.instanceMember(e, lhs, name);
        if (tv.ty == .unknown and inf.members[@backingInt(e)] == null and lhs.ty != .unknown) {
            if (try inf.otherBranchField(e, lhs_e, lhs.ty, name)) |x| tv = x;
        }
        // comptime-known values (structs, unions, tuples, `len`): extract the field value
        if (tv.val == null and lhs.val != null) if (try eval.fieldValue(inf.r, lhs, name)) |fv| {
            return .{ .ty = if (tv.ty != .unknown) tv.ty else fv.ty, .val = fv.val };
        };
        if (tv.val == null and lhs.val == null) if (try inf.declInitFieldValue(lhs_e, name)) |fv| {
            return .{ .ty = if (tv.ty != .unknown) tv.ty else fv.ty, .val = fv.val };
        };
        return tv;
    }

    /// When the left-hand side is a container-level constant initialized with a struct literal but
    /// its value as a whole cannot be evaluated (because other fields cannot): takes the value of
    /// the field's initializer expression. For example, `featureSet` cannot be evaluated in the
    /// wasm target's `builtin.cpu = .{ .arch = .wasm32, .features = featureSet(..) }`, yet
    /// `builtin.cpu.arch` is still `.wasm32`.
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
        const res = try inf.r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full, .inst = try queries.rootInst(inf.r, owner.file, inf.inst) });
        if (res.exprs.len != body.exprs.len) return null;
        const fv = res.exprs[@backingInt(field.value)];
        return if (fv.val != null) fv else null;
    }

    /// Field access on the type of a tagged union (`Value.null_val`): the value is the tag of that
    /// field and the type is the union's tag type, which can be coerced to the union (matches the
    /// compiler); the referenced member is the union field
    fn unionTagMember(inf: *Inferrer, e: ExprId, t: Index, ns: Namespace, name: []const u8) Error!?TypedValue {
        const tree = try inf.r.itemTree(ns.file);
        if (tree.containers[ns.container].kind != .@"union") return null;
        const fi = fieldItem(tree, ns.container, name) orelse return null;
        const tag = try eval.unionTag(inf.r, t) orelse return null;
        inf.members[@backingInt(e)] = .{ .file = ns.file, .item = tree.items[fi].ast_id };
        return .{ .ty = tag, .val = try inf.ip.get(.{ .enum_tag = .{ .ty = tag, .name = name } }) };
    }

    /// A member that does not exist under the current build configuration, in a namespace chosen
    /// per target by an `if` / `switch` in a declaration (e.g. `posix.system` is `linux` on linux,
    /// and `std.c` etc. on other targets): looks it up in the containers chosen by the other
    /// branches. Such code is compiled only on other targets; the definition there is given
    /// instead of unknown.
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

    /// A member on an instance that does not exist under the current build configuration, when
    /// the instance's type comes from a namespace chosen per target (`state: platform.State`,
    /// `var state = platform.State.init()`, where platform selects a file per target;
    /// `var t = try posix.tcgetattr(fd)`, whose return type `termios` is chosen per target):
    /// looks up fields and methods in the types under other configurations
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

    /// Members on an instance (value): fields and methods, with single-item pointers dereferenced
    /// automatically
    fn instanceMember(inf: *Inferrer, e: ExprId, lhs: TypedValue, name: []const u8) Error!TypedValue {
        const ip = inf.ip;
        var t = lhs.ty;
        switch (ip.key(t)) {
            .ptr_type => |p| if (p.size == .one) {
                // `ptr` of a pointer to an array: a many-item pointer to its elements, with the
                // sentinel of the array and the other attributes of the pointer
                if (std.mem.eql(u8, name, "ptr")) {
                    const elem: ?struct { Index, ?Index } = switch (ip.key(p.child)) {
                        .array_type => |arr| .{ arr.child, arr.sentinel },
                        .abstract_array_type => |arr| .{ arr.child, arr.sentinel },
                        else => null,
                    };
                    if (elem) |el| return .{ .ty = try ip.get(.{ .ptr_type = .{ .child = el[0], .size = .many, .is_const = p.is_const, .sentinel = el[1], .attrs = p.attrs } }) };
                }
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
                // Methods
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
                if (std.mem.eql(u8, name, "ptr")) return .{ .ty = try ip.get(.{ .ptr_type = .{ .child = p.child, .size = .many, .is_const = p.is_const, .sentinel = p.sentinel, .attrs = p.attrs } }) };
            },
            // Tuples, anonymous structs, and constructed structs and unions
            .tuple_type, .anon_struct_type, .reified_type => {
                if (ip.key(t) == .tuple_type and std.mem.eql(u8, name, "len")) return .{ .ty = .usize_type, .val = try ip.get(.{ .int_value = .{ .ty = .usize_type, .value = ip.key(t).tuple_type.types.len } }) };
                const ty = try eval.fieldType(inf.r, t, name) orelse .unknown;
                // comptime fields of literals: the value belongs to the type
                return .{ .ty = ty, .val = literalFieldValue(ip, t, name) };
            },
            else => {},
        }
        return .unknown;
    }

    /// decl literal: when the result type (with error unions, optionals, and single-item pointers
    /// stripped, matching the compiler) is a container, `.name` is that type's declaration
    /// `T.name` (for enums, a member with the same name takes precedence)
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

    /// A type in the standard library looked up by path (e.g. `builtin.Type`)
    fn stdType(inf: *Inferrer, path: []const []const u8) Error!?Index {
        var ns: Namespace = .{ .file = try inf.r.ctx.get(database.ModuleGraph.StdRoot, inf.r.context) orelse return null, .container = 0 };
        var t: Index = .unknown;
        for (path, 0..) |name, i| {
            const def = try inf.r.memberDef(ns, name) orelse return null;
            t = (try queries.defType(inf.r, def, null, null)).asType() orelse return null;
            if (i + 1 < path.len) ns = try queries.namespaceOfType(inf.r, t) orelse return null;
        }
        return t;
    }

    // ── Calls ────────────────────────────────────────────────────────

    fn call(inf: *Inferrer, callee_e: ExprId, args: []const ExprId, expected: ?Index) Error!TypedValue {
        // `.init(...)`: the decl literal is looked up in the result type
        const callee = try inf.infer(callee_e, if (inf.body.expr(callee_e) == .enum_literal) expected else null);
        const f = switch (inf.ip.key(callee.ty)) {
            .fn_type => |f| f,
            // Function pointers
            .ptr_type => |p| if (p.size == .one and inf.ip.key(p.child) == .fn_type) inf.ip.key(p.child).fn_type else {
                for (args) |a| _ = try inf.infer(a, null);
                return .unknown;
            },
            else => {
                for (args) |a| {
                    // The parameter types of an unknown callee are unknown
                    if (callee.ty == .unknown) try inf.noteUnknownResult(a);
                    _ = try inf.infer(a, null);
                }
                return .unknown;
            },
        };
        const skip: usize = if (inf.bound.contains(callee_e)) 1 else 0;
        const g = try genericCallee(inf.r, inf.scratch, callee, f) orelse {
            for (args, 0..) |a, i| _ = try inf.infer(a, paramType(f, i + skip));
            const evaluate = inf.comptime_depth > 0 or (f.cc == .@"inline" and allKnown(try inf.argValues(callee_e, args, skip, args.len + skip)));
            if (evaluate) if (try inf.comptimeCall(callee, callee_e, args, skip)) |tv| return tv;
            return .{ .ty = f.ret };
        };
        // Generic call: comptime arguments determine the instance, so infer them first; parameter
        // types in the abstract signature that depend on other parameters cannot serve as expected
        // types. anytype arguments take part in the instance only by their types; they are in a
        // comptime context only when the whole call executes at comptime, where the interpreter
        // needs their values.
        for (args, 0..) |a, i| switch (g.kind(i + skip)) {
            .comptime_value => _ = try inf.inferComptime(a, inf.concrete(paramType(f, i + skip))),
            .comptime_anytype => _ = try inf.inferComptime(a, null),
            .anytype_type => _ = if (g.comptime_call) try inf.inferComptime(a, null) else try inf.infer(a, null),
            .runtime => {},
        };
        const inst = try instanceOf(inf.r, inf.scratch, g, f, try inf.argValues(callee_e, args, skip, g.body.params.len));
        const sig = try inf.r.ctx.get(queries.Infer, .{ .owner = g.owner, .mode = .signature, .inst = inst });
        // The remaining arguments are inferred with the parameter types in the instance
        for (args, 0..) |a, i| if (g.kind(i + skip) == .runtime) {
            _ = try inf.infer(a, instParamType(sig, g.body, i + skip) orelse inf.concrete(paramType(f, i + skip)));
        };
        const result = try inf.callResult(g, inst, sig, try inf.argValues(callee_e, args, skip, g.body.params.len), f.cc == .@"inline");
        try inf.literalArgTargets(g, inst, args, skip);
        return result;
    }

    /// Enum literals received by anytype parameters (`testing.expectEqual(.x, actual)`): the
    /// literal refers to a member of whatever type the callee's instance coerces the parameter to,
    /// and uses that type as its expected type (for completion and members of constructed types)
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

    /// Arguments parallel to the parameters (a method call's receiver comes first)
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

    /// Result of an instantiated call: the return type is evaluated in the instance. When the
    /// function returns a comptime-only type (such as `type`) or the call is in a comptime
    /// context, the interpreter executes the function body to compute the value; when the
    /// interpreter gives up, a function returning `type` takes the value of the `return` actually
    /// reached during inference. An inline call whose arguments are all known at comptime is
    /// evaluated too: its result is known at comptime when the body computes it from them (as in
    /// `std.fmt.comptimePrint`).
    fn callResult(inf: *Inferrer, g: Generic, inst: Index, sig: *const Result, args: []const TypedValue, is_inline: bool) Error!TypedValue {
        const ret = try queries.returnType(inf.r, g.owner, g.body, sig, inst);
        const evaluate = try eval.isComptimeOnly(inf.r, ret) or inf.comptime_depth > 0 or (is_inline and allKnown(args));
        if (evaluate and !inf.r.ctx.incomplete()) {
            const tv = try eval.call(inf.r, inst, args, inf.branchQuota());
            if (tv.val != null and (ret == .unknown or tv.ty == ret)) return tv;
        }
        if (ret == .type_type) {
            const full = try inf.r.ctx.get(queries.Infer, .{ .owner = g.owner, .mode = .full, .inst = inst });
            return if (full.ret.ty == .type_type) full.ret else .{ .ty = .type_type };
        }
        return .{ .ty = ret };
    }

    /// A call to a non-generic function in a comptime context (such as `double(4)` in an array
    /// length): evaluated by the interpreter
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

    /// Type free of abstract parameters and unknown parts (usable as the caller's expected type)
    fn concrete(inf: *Inferrer, t: ?Index) ?Index {
        const ty = t orelse return null;
        return if (value.isConcrete(inf.ip, ty)) ty else null;
    }

    /// The prong that executes when both the switch operand and the prong items are comptime-known.
    /// A range item `a...b` matches an operand between its bounds, both inclusive.
    fn chooseProng(inf: *Inferrer, prongs: []const Body.Prong, operand: TypedValue) Error!?usize {
        const v = operand.val orelse return null;
        var else_prong: ?usize = null;
        var under_prong: ?usize = null;
        for (prongs, 0..) |prong, i| {
            if (prong.is_else) {
                else_prong = i;
                continue;
            }
            for (prong.items) |item| {
                if (inf.body.isUnderscore(item)) {
                    under_prong = i;
                    continue;
                }
                const hit = if (switchRange(inf.body, item)) |range|
                    (try inf.compare(.angle_bracket_right_equal, operand, inf.get(range[0])) orelse return null) and
                        (try inf.compare(.angle_bracket_left_equal, operand, inf.get(range[1])) orelse return null)
                else
                    try eval.eqlValues(inf.r, inf.get(item).val orelse return null, v) orelse return null;
                if (hit) return i;
            }
        }
        return eval.otherProng(inf.ip, v, else_prong, under_prong);
    }

    /// comptime-known comparison
    fn compare(inf: *Inferrer, op: SyntaxKind, lhs: TypedValue, rhs: TypedValue) Error!?bool {
        const ip = inf.ip;
        var a = lhs.val orelse return null;
        var b = rhs.val orelse return null;
        // Optionals of different depths are compared at the deeper one, their peer type: a null
        // `?u8` equals a `??u8` holding it
        switch (value.deeperOptional(ip, lhs.ty, rhs.ty)) {
            .lhs => b = try value.coerceValueFrom(ip, b, rhs.ty, lhs.ty) orelse return null,
            .rhs => a = try value.coerceValueFrom(ip, a, lhs.ty, rhs.ty) orelse return null,
            .neither => {},
        }
        if (value.intOf(ip, a)) |x| if (value.intOf(ip, b)) |y| return value.compareInts(ip, op, lhs.ty, rhs.ty, x, y);
        if (ip.key(a) == .float_value or ip.key(b) == .float_value) if (value.floatOf(ip, a)) |x| if (value.floatOf(ip, b)) |y| return order(op, x, y);
        // Integers outside i128's range
        if (ip.key(a) == .big_int or ip.key(b) == .big_int) {
            const x = try value.bigValueOf(ip, inf.scratch, a) orelse return null;
            const y = try value.bigValueOf(ip, inf.scratch, b) orelse return null;
            const ord = bigint.order(x, y);
            return switch (op) {
                .equal_equal => ord == .eq,
                .bang_equal => ord != .eq,
                .angle_bracket_left => ord == .lt,
                .angle_bracket_right => ord == .gt,
                .angle_bracket_left_equal => ord != .gt,
                else => ord != .lt,
            };
        }
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
            const tv = try queries.importValue(inf.r, target);
            // With a result type, the compiler parses ZON according to the result type: for values
            // other than scalars, only the result type is taken (see `zon.isScalar`)
            if (inf.r.isZon(target)) if (expected) |want| {
                if (inf.dead == 0) try inf.zon_imports.append(inf.scratch, .{ .file = target, .ty = want });
                if (want != .unknown and want != tv.ty and !zon.isScalar(tv.ty)) return .{ .ty = want };
            };
            return tv;
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
        // The module name is decided by the build system (see `std.builtin.SourceLocation.module`)
        // and is absent from the project model, so only the type is given
        // GPU, wasm and C variadic builtins: the result types of the compiler's Sema and Air
        if (eq(u8, name, "@workItemId") or eq(u8, name, "@workGroupId") or eq(u8, name, "@workGroupSize")) {
            const u32_type = try ip.intType(.unsigned, 32);
            for (args) |a| _ = try inf.infer(a, u32_type);
            return .{ .ty = u32_type };
        }
        if (eq(u8, name, "@wasmMemorySize") or eq(u8, name, "@wasmMemoryGrow")) {
            const u32_type = try ip.intType(.unsigned, 32);
            for (args, 0..) |a, i| _ = try inf.infer(a, if (i == 0) u32_type else .usize_type);
            return .{ .ty = if (eq(u8, name, "@wasmMemorySize")) .usize_type else .isize_type };
        }
        if (eq(u8, name, "@cVaStart") or eq(u8, name, "@cVaCopy")) {
            for (args) |a| _ = try inf.infer(a, null);
            return .{ .ty = (try inf.stdType(&.{ "lang", "VaList" })) orelse .unknown };
        }
        if (eq(u8, name, "@cVaEnd")) {
            for (args) |a| _ = try inf.infer(a, null);
            return .{ .ty = .void_type };
        }
        if (eq(u8, name, "@cVaArg")) {
            for (args) |a| _ = try inf.infer(a, null);
            if (args.len != 2) return .unknown;
            return .{ .ty = inf.get(args[1]).asType() orelse .unknown };
        }
        // A SPIR-V type: a type whose value is not modeled
        if (eq(u8, name, "@SpirvType")) {
            for (args) |a| _ = try inf.infer(a, (try inf.stdType(&.{ "lang", "Type", "Spirv" })));
            return typeUnknown();
        }
        if (eq(u8, name, "@src")) return .{ .ty = try inf.stdType(&.{ "builtin", "SourceLocation" }) orelse .unknown };
        if (eq(u8, name, "@as")) {
            if (args.len != 2) return .unknown;
            const t = (try inf.infer(args[0], null)).asType() orelse .unknown;
            const v = try inf.infer(args[1], if (t != .unknown) t else null);
            return .{ .ty = t, .val = if (v.ty == t) v.val else null };
        }
        if (eq(u8, name, "@TypeOf")) {
            const in_typeof = inf.in_typeof;
            inf.in_typeof = true;
            defer inf.in_typeof = in_typeof;
            var types: std.ArrayList(Index) = .empty;
            for (args) |a| try types.append(inf.scratch, (try inf.infer(a, null)).ty);
            const t = try inf.peer(types.items);
            return if (t == .unknown) typeUnknown() else TypedValue.ofType(t);
        }
        if (eq(u8, name, "@Int")) {
            if (args.len != 2) return typeUnknown();
            // The signedness is any known `std.lang.Signedness` value (or an enum literal), the
            // bit count a `u16`
            const sign_tv = try inf.infer(args[0], null);
            const sign: ?std.builtin.Signedness = if (sign_tv.val) |v| switch (ip.key(v)) {
                .enum_literal => |n| std.meta.stringToEnum(std.builtin.Signedness, n),
                .enum_tag => |t| std.meta.stringToEnum(std.builtin.Signedness, t.name),
                else => null,
            } else null;
            const bits = try inf.infer(args[1], try ip.intType(.unsigned, 16));
            const n: ?u16 = if (bits.val) |v| switch (ip.key(v)) {
                .int_value => |iv| std.math.cast(u16, iv.value),
                else => null,
            } else null;
            if (sign == null or n == null) return typeUnknown();
            // Sema rejects a signed integer type with bit width 0
            if (sign.? == .signed and n.? == 0) return typeUnknown();
            return TypedValue.ofType(try ip.intType(sign.?, n.?));
        }
        // The length of `@Vector` is a u32
        if (eq(u8, name, "@Vector") and args.len == 2) _ = try inf.infer(args[0], try ip.intType(.unsigned, 32));
        // Builtins that construct types: evaluated by the interpreter (their arguments are
        // all comptime-known values)
        const reifying = [_][]const u8{ "@Pointer", "@Tuple", "@Enum", "@Struct", "@Union", "@Fn", "@Vector", "@EnumLiteral" };
        for (reifying) |n| if (eq(u8, name, n)) {
            for (args) |a| _ = try inf.infer(a, null);
            if (inf.dead > 0 or inf.r.ctx.incomplete()) return typeUnknown();
            const tv = try eval.exprValue(inf.r, inf.file, inf.item, inf.body, e, inf.inst, inf.bindings, null, inf.branchQuota());
            return if (tv.val != null) tv else typeUnknown();
        };
        if (eq(u8, name, "@sizeOf") or eq(u8, name, "@alignOf") or eq(u8, name, "@bitSizeOf")) {
            const t = (if (args.len == 1) (try inf.infer(args[0], null)).asType() else null) orelse return .{ .ty = .comptime_int_type };
            // A container's layout reads the inferred field types: once the current result is
            // already incomplete, do not go deeper
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
            // A vector of bools gives a vector of u1
            if (args.len == 1) switch (ip.key(inf.get(args[0]).ty)) {
                .vector_type => |v| return .{ .ty = try ip.get(.{ .vector_type = .{ .len = v.len, .child = .u1_type } }) },
                else => {},
            };
            const b = if (args.len == 1) inf.condValue(inf.get(args[0])) else null;
            return .{ .ty = .u1_type, .val = if (b) |x| try ip.get(.{ .int_value = .{ .ty = .u1_type, .value = @intFromBool(x) } }) else null };
        }
        // The result is a type defined in the standard library: only the type is given (no
        // value is constructed)
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
            // The field name is a string literal or a comptime-known string
            const field_name = try inf.infer(args[1], null);
            return inf.fieldAccess(e, args[0], try inf.stringArg(args[1]) orelse try eval.stringValue(inf.r, field_name));
        }
        if (try inf.typedArgsBuiltin(name, args, expected)) |tv| return tv;
        // Nested pointer casts are merged into one cast in the compiler (`@ptrCast(@alignCast(p))`,
        // `@alignCast(@fieldParentPtr(...))`): the inner cast takes the outer one's result type
        if (isPtrCast(name) and args.len == 1) switch (inf.body.expr(args[0])) {
            .builtin_call => |inner| if (isPtrCast(inner.name) or eq(u8, inner.name, "@fieldParentPtr")) {
                _ = try inf.infer(args[0], inf.destType(expected, .eu));
            },
            else => {},
        };
        // The operand of a float math builtin has the float or float vector in the result type
        // (`float_op_result_ty` / `round_op_ty`). The compiler checks that the operand of a
        // rounding builtin is a float before coercing it (see `roundCast`), so that operand is
        // not coerced: `3` in `@ceil(3)` stays a comptime_int, a compile error with any result type.
        if (args.len == 1 and isFloatMath(name)) if (expected) |t| if (value.floatOperandType(ip, t)) |ft| {
            _ = if (isRounding(name)) try inf.inferUncoerced(args[0], ft) else try inf.infer(args[0], ft);
        };
        for (args) |a| _ = try inf.infer(a, null);
        // Casts: the result type is determined by the expected type (with error union / optional
        // stripped as in the compiler's `resolveDestType`)
        if (eval.castDestStrip(name)) |strip| {
            if (inf.destType(expected, strip)) |t| return .{ .ty = t };
            // `@alignCast` / `@addrSpaceCast` without a result type (an error in the compiler)
            // take the type of the argument
            if ((eq(u8, name, "@alignCast") or eq(u8, name, "@addrSpaceCast")) and args.len == 1) return .{ .ty = inf.get(args[0]).ty };
            return .unknown;
        }
        // Stripping const / volatile: the result depends only on the argument's type
        // (matches the compiler)
        if (eq(u8, name, "@constCast") or eq(u8, name, "@volatileCast")) {
            if (args.len != 1) return .unknown;
            const t = inf.get(args[0]).ty;
            // Merged with a cast below that takes the result type, the chain has that cast's type
            if (qualifierCastTakesResultType(inf.body, args[0])) return .{ .ty = t };
            return .{ .ty = try qualifierCastDest(ip, t, name) orelse t };
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
        // `struct { T, u1 }`: T is the peer type of both sides (the left-hand side's type for
        // `@shlWithOverflow`); for vectors, the overflow bit is a vector too
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
        // `@Vector(n, T)`: n is the length of `pred` / `mask`
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
        // Integer value of an error: as wide as the error codes, which the error limit sets
        if (eq(u8, name, "@intFromError")) return .{ .ty = try ip.intType(.unsigned, ip.errorBits() orelse return .unknown) };
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
            const sentinel = try ip.get(.{ .int_value = .{ .ty = .u8_type, .value = 0 } });
            // The name of a type is always comptime-known (`*const [N:0]u8`), even when it
            // cannot be evaluated here
            if (eq(u8, name, "@typeName")) return .{ .ty = try ip.ptrTo(try ip.get(.{ .abstract_array_type = .{ .len = null, .child = .u8_type, .sentinel = sentinel } }), .one, true) };
            // Only a runtime operand gives `[:0]const u8`; a comptime-known one gives the string
            // literal `*const [N:0]u8` (`Sema.zirTagName`, `Sema.zirErrorName`). When inference
            // has no value for a comptime-known operand (a tagged union literal, `@enumFromInt`,
            // a call in a container-level initializer), the interpreter evaluates the name; when
            // it cannot, the length of the result is unknown.
            if (args.len == 1 and inf.dead == 0 and !inf.r.ctx.incomplete() and try inf.comptimeKnown(args[0])) {
                const tv = try eval.exprValue(inf.r, inf.file, inf.item, inf.body, e, inf.inst, inf.bindings, null, inf.branchQuota());
                return if (tv.val != null) tv else .unknown;
            }
            return .{ .ty = try ip.get(.{ .ptr_type = .{ .child = .u8_type, .size = .slice, .is_const = true, .sentinel = sentinel } }) };
        }
        // With a result type, the rounding builtins convert to it (see `roundCast`); without one,
        // they have the type of the operand like the other float math builtins below
        if (isRounding(name)) if (expected) |want| return inf.roundCast(name, args, want);
        // The result has the type of the first argument (for division and remainder, the
        // peer type of both sides)
        const same = [_][]const u8{ "@abs", "@sqrt", "@sin", "@cos", "@tan", "@exp", "@exp2", "@log", "@log2", "@log10", "@floor", "@ceil", "@trunc", "@round", "@byteSwap", "@bitReverse", "@min", "@max", "@mod", "@rem", "@divExact", "@divFloor", "@divTrunc", "@divCeil" };
        for (same) |n| if (eq(u8, name, n)) {
            if (args.len == 0) return .unknown;
            if (try inf.pureValue(name, args)) |tv| return tv;
            var types: std.ArrayList(Index) = .empty;
            for (args) |a| try types.append(inf.scratch, inf.get(a).ty);
            if (eq(u8, name, "@min") or eq(u8, name, "@max")) {
                // Matches the compiler: with float arguments, take the float type with the
                // largest bit width; for integers, take the smallest integer type that holds the
                // result range
                for (types.items) |t| if (ip.isFloat(t)) return .{ .ty = value.minMaxFloatType(ip, types.items) orelse try inf.peer(types.items) };
                const operands = try inf.scratch.alloc(TypedValue, args.len);
                for (args, operands) |a, *o| o.* = inf.get(a);
                return .{ .ty = try value.minMaxIntType(ip, inf.scratch, eq(u8, name, "@min"), operands) orelse try inf.peer(types.items) };
            }
            // The absolute value of a signed integer is the unsigned integer of the same bit width
            if (eq(u8, name, "@abs")) return .{ .ty = try value.absType(ip, types.items[0]) orelse .unknown };
            // Division and remainder: the peer type of both sides
            if (args.len == 2) return .{ .ty = try inf.peer(types.items) };
            return .{ .ty = types.items[0] };
        };
        return .unknown;
    }

    /// Builtins whose arguments have result types (matches the compiler): the arguments are
    /// inferred with their respective result types; null for other builtins
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
            // A known scalar splatted into a vector gives a known vector
            if (dest) |d| if (ip.key(d) == .vector_type and args.len == 1) {
                const scalar = inf.get(args[0]);
                if (scalar.val) |v| if (scalar.ty == elem.? and v != .unknown and v != .undefined_value) {
                    const elems = try inf.scratch.alloc(Index, ip.key(d).vector_type.len);
                    @memset(elems, v);
                    return .{ .ty = d, .val = try value.aggregate(ip, inf.scratch, d, elems) };
                };
            };
            return .{ .ty = dest orelse .unknown };
        }
        // The argument's result type is the backing integer of the destination type
        if (eq(u8, name, "@fromBackingInt")) {
            const dest = inf.destType(expected, .eu_opt);
            const int_ty: ?Index = if (dest) |d| try eval.backingIntType(inf.r, d) else null;
            for (args) |a| _ = try inf.infer(a, int_ty);
            return .{ .ty = dest orelse .unknown };
        }
        // The right-hand side is `Log2Int(T)`
        if (eq(u8, name, "@shlExact") or eq(u8, name, "@shrExact")) {
            const lhs: TypedValue = if (args.len > 0) try inf.infer(args[0], null) else .unknown;
            for (args[@min(args.len, 1)..]) |a| _ = try inf.infer(a, try value.log2IntType(inf.ip, lhs.ty));
            return try inf.pureValue(name, args) orelse .{ .ty = lhs.ty };
        }
        // The result type of the init value is the field's type
        if (eq(u8, name, "@unionInit")) {
            if (args.len != 3) return null;
            const t = (try inf.infer(args[0], null)).asType();
            const field_name = try inf.infer(args[1], null);
            const field = try inf.stringArg(args[1]) orelse try eval.stringValue(inf.r, field_name);
            const field_ty: ?Index = if (t != null and field != null) try inf.unionFieldType(t.?, field.?) else null;
            _ = try inf.infer(args[2], field_ty);
            return .{ .ty = t orelse .unknown };
        }
        // The result type of the fill value is the element type
        if (eq(u8, name, "@memset")) {
            const dest: TypedValue = if (args.len > 0) try inf.infer(args[0], null) else .unknown;
            const elem = inf.elementType(dest.ty);
            for (args[@min(args.len, 1)..]) |a| _ = try inf.infer(a, if (elem != .unknown) elem else null);
            return .{ .ty = .void_type };
        }
        // Result types of the arguments; `elem` is the type given by the first argument
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

    /// Destination type of cast builtins: the expected type, with error union / optional stripped
    /// as in the compiler's `resolveDestType`; null without an expected type
    fn destType(inf: *Inferrer, expected: ?Index, strip: eval.DestStrip) ?Index {
        return eval.destType(inf.ip, expected, strip);
    }

    /// Result type of `@clz` / `@ctz` / `@popCount`: the smallest unsigned integer that holds 0
    /// through the bit width, element-wise for vectors
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

    /// `@floor` / `@ceil` / `@trunc` / `@round` with the result type `want` (matches the
    /// compiler's `zirRoundCast`): the call has the result type without its error unions and
    /// optionals, however deeply nested (`Type.optEuBaseType`), and an unknown result type gives
    /// an unknown result. The operand must be a float: a float destination takes it coerced to
    /// the destination before rounding, an integer destination takes it rounded in its own type
    /// and converted to the integer.
    fn roundCast(inf: *Inferrer, name: []const u8, args: []const ExprId, want: Index) Error!TypedValue {
        const ip = inf.ip;
        if (want == .unknown) return .unknown;
        var dest = want;
        while (true) dest = switch (ip.key(dest)) {
            .optional_type => |child| child,
            .error_union_type => |eu| eu.payload,
            else => break,
        };
        const result: TypedValue = .{ .ty = dest };
        if (args.len != 1 or inf.dead > 0 or inf.r.ctx.incomplete()) return result;
        const operand = inf.get(args[0]);
        const v = operand.val orelse return result;
        if (!ip.isFloat(operand.ty)) return result;
        if (ip.isFloat(dest)) {
            const x = try value.coerceValue(ip, v, dest) orelse return result;
            return try eval.builtinValue(inf.r, name, &.{.{ .ty = dest, .val = x }}) orelse result;
        }
        if (!ip.isInt(dest)) return result;
        const rounded = try eval.builtinValue(inf.r, name, &.{operand}) orelse return result;
        return .{ .ty = dest, .val = try value.coerceValue(ip, rounded.val.?, dest) };
    }

    /// Return type of a function (or function pointer); unknown when it depends on the parameters
    fn fnReturnType(inf: *Inferrer, t: Index) Index {
        const ip = inf.ip;
        const f = switch (ip.key(t)) {
            .fn_type => |f| f,
            .ptr_type => |p| if (p.size == .one and ip.key(p.child) == .fn_type) ip.key(p.child).fn_type else return .unknown,
            else => return .unknown,
        };
        return inf.concrete(f.ret) orelse .unknown;
    }

    /// Value of a purely computational builtin (math functions, layout) when all arguments are
    /// known, computed by the interpreter
    fn pureValue(inf: *Inferrer, name: []const u8, args: []const ExprId) Error!?TypedValue {
        if (inf.dead > 0 or inf.r.ctx.incomplete()) return null;
        const tvs = try inf.scratch.alloc(TypedValue, args.len);
        for (args, tvs) |a, *o| {
            o.* = inf.get(a);
            if (o.val == null) return null;
        }
        return eval.builtinValue(inf.r, name, tvs);
    }

    /// Contents of a string literal argument
    fn stringArg(inf: *Inferrer, e: ExprId) Error!?[]const u8 {
        return switch (inf.body.expr(e)) {
            .literal => |text| if (text.len > 0 and text[0] == '"') std.zig.string_literal.parseAlloc(inf.scratch, text) catch null else null,
            else => null,
        };
    }

    // ── Blocks and control flow ──────────────────────────────────────

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
            // Reaching the end of the block yields void
            if (last != .noreturn_type and inf.dead == 0) {
                try frame.types.append(inf.scratch, .void_type);
                try frame.values.append(inf.scratch, .{ .ty = .void_type, .val = .void_value });
            }
            const t = try inf.peer(frame.types.items);
            for (frame.exprs.items) |x| try inf.peerLiteral(x, t);
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
                // The value of a `comptime var` is tracked through its modifications
                // (see `assignComptimeVar`)
                const keeps_value = binding.kind == .local_const or binding.is_comptime;
                inf.bindings[@backingInt(b)] = if (annotation) |t|
                    .{ .ty = t, .val = if (!keeps_value) null else if (init.ty == t) init.val else try value.arrayPtrAsSlice(inf.ip, init, t) }
                else if (keeps_value)
                    init
                else
                    .{ .ty = init.ty };
                if (binding.kind == .local_var and binding.is_comptime) {
                    if (inf.var_levels.len == 0) inf.var_levels = try inf.scratch.alloc(u32, inf.body.bindings.len);
                    inf.var_levels[@backingInt(b)] = inf.uncertain;
                }
                return .void_type;
            },
            .@"defer", .@"errdefer" => |e| {
                _ = try inf.infer(e, null);
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

    /// The `i`-th element of the destructuring `const a, const b = x;`: a field of a tuple, or an
    /// element of an array or vector
    fn destructureElem(inf: *Inferrer, v: TypedValue, i: usize) Error!TypedValue {
        const ip = inf.ip;
        const ty: Index = switch (ip.key(v.ty)) {
            .tuple_type => |tt| if (i < tt.types.len) tt.types[i] else return .unknown,
            .array_type => |a| a.child,
            .vector_type => |vt| vt.child,
            else => return .unknown,
        };
        if (v.val != null) if (try eval.elemValue(inf.r, v, i)) |ev| return .{ .ty = ty, .val = ev.val };
        // comptime fields of a tuple: the value belongs to the type
        const x: Index = switch (ip.key(v.ty)) {
            .tuple_type => |tt| InternPool.fieldValue(tt.values, i),
            else => .runtime,
        };
        return .{ .ty = ty, .val = if (x == .runtime or x == .unknown) null else x };
    }

    fn loop(inf: *Inferrer, l: Body.Loop, expected: ?Index) Error!TypedValue {
        var iteration: ?u32 = null;
        // A `while` whose condition is comptime-known to hold and cannot change (no `comptime var`
        // is modified by the loop) ends only through its breaks: the compiler analyzes only the
        // taken branch of the condition, so the `else` branch (`void` when absent) is not a peer
        var endless = false;
        switch (l.kind) {
            .@"while" => {
                const cond = try inf.infer(l.inputs[0], null);
                try inf.bindCaptures(l.capture, l.inputs[0], cond, .if_then);
                try inf.bindCaptures(l.else_capture, l.inputs[0], cond, .if_else);
                inf.captureBound(l.capture);
                inf.captureBound(l.else_capture);
                endless = inf.condValue(cond) == true and !try inf.assignsOuterComptimeVar(l.body) and
                    (if (l.cont) |c| !try inf.assignsOuterComptimeVar(c) else true);
            },
            .@"for" => {
                // Inferring this loop for one iteration (see `LoopSeed`): every loop variable
                // takes its value in this iteration. An undetermined iteration is inferred as the
                // whole loop.
                const seed = inf.iterationSeed();
                iteration = if (seed) |s|
                    (if (std.mem.indexOfScalar(Body.BindingId, l.capture, @fromBackingInt(s.binding)) != null) s.index else null)
                else
                    null;
                // When the loop body modifies an outer `comptime var`, at the start of iteration n
                // it takes its value at the end of iteration n - 1. Inferring only up to a loop
                // variable of this loop (see `runLocal`) does not read it: the compiler evaluates
                // the operands once, before the loop (`AstGen.forExpr`), so the loop variables do
                // not depend on what earlier iterations modify.
                if (iteration) |n| if (n > 0) if (!inf.stopsAt(l.capture)) if (try inf.assignsOuterComptimeVar(l.body)) {
                    const prev = try inf.r.ctx.get(queries.Infer, .{
                        .owner = .{ .file = inf.file, .item = try inf.body_owner() },
                        .mode = inf.mode,
                        .inst = inf.inst,
                        .loop = .{ .binding = seed.?.binding, .index = n - 1 },
                    });
                    for (prev.iteration_vars) |v| inf.bindings[@backingInt(v.binding)].val = v.val;
                };
                try inf.bindForCaptures(l, iteration);
                inf.captureBound(l.capture);
            },
        }
        // Without per-iteration inference, the number of times the loop body runs is
        // undetermined: outer `comptime var`s modified by the loop body are unknown at the
        // start of any iteration
        if (iteration == null) {
            inf.uncertain += 1;
            try inf.forgetOuterComptimeVars(l.body);
        }
        if (l.cont) |c| _ = try inf.infer(c, null);
        // break values and the else branch take the loop's result type
        try inf.labels.append(inf.scratch, .{ .name = l.label, .is_loop = true, .expected = expected });
        _ = try inf.infer(l.body, null);
        var frame = inf.labels.pop().?;
        if (iteration == null) inf.uncertain -= 1;
        // After the loop, a modified `comptime var` holds its value after all iterations, but only
        // one iteration is inferred here: record its value at the end of this iteration (the next
        // iteration starts from it), then set it to unknown
        if (iteration != null) {
            var vars: std.ArrayList(Body.BindingId) = .empty;
            _ = try inf.outerComptimeVars(l.body, &vars);
            for (vars.items) |v| {
                try inf.iteration_vars.append(inf.scratch, .{ .binding = v, .val = inf.bindings[@backingInt(v)].val });
                inf.bindings[@backingInt(v)].val = null;
            }
        }
        if (endless) {
            if (l.@"else") |el| _ = try inf.inferArm(el, expected, true);
        } else if (l.@"else") |el| {
            try frame.types.append(inf.scratch, (try inf.infer(el, expected)).ty);
            try frame.exprs.append(inf.scratch, el);
        } else try frame.types.append(inf.scratch, .void_type);
        const ty = try inf.peer(frame.types.items);
        for (frame.exprs.items) |x| try inf.peerLiteral(x, ty);
        return .{ .ty = ty };
    }

    /// Inferring only up to the capture `stop_at`, which is one of `caps`
    fn stopsAt(inf: *const Inferrer, caps: []const Body.BindingId) bool {
        const target = inf.stop_at orelse return false;
        return std.mem.indexOfScalar(Body.BindingId, caps, target) != null;
    }

    /// `caps` have just been bound: when inferring only up to the capture `stop_at`, stops there
    fn captureBound(inf: *Inferrer, caps: []const Body.BindingId) void {
        if (inf.stopsAt(caps)) inf.stopped = true;
    }

    /// Loop variables of a `for` loop; when inferring the `iteration`-th iteration, they take the
    /// value and type of that iteration
    fn bindForCaptures(inf: *Inferrer, l: Body.Loop, iteration: ?u32) Error!void {
        const ip = inf.ip;
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
                const attrs: InternPool.PtrAttrs = if (ptr) try inf.forCaptureAttrs(l, input, list.ty, elem, iteration) else .{};
                const ty = if (ptr) try singlePtr(ip, elem, is_const, attrs) else elem;
                inf.bindings[@backingInt(cap)] = if (elem == .type_type and !ptr)
                    try inf.typeCapture(cap, list, iteration)
                else if (iteration) |n| blk: {
                    const it_ty = try inf.iterationType(list.ty, elem, n, ptr, is_const, attrs);
                    const v = try inf.iterationValue(list, start, n);
                    // A pointer capture takes a pointer to this iteration's element; elements of a
                    // mutable list change at runtime, so no value is taken
                    const val = if (!ptr) v else if (is_const) (if (v) |x| try ip.get(.{ .ptr_value = .{ .ty = it_ty, .pointee = x } }) else null) else null;
                    break :blk .{ .ty = it_ty, .val = val };
                } else .{ .ty = ty };
            }
        }
    }

    /// Attributes of a pointer capture of `for` over `input` (of type `list`, elements of type
    /// `elem`): those of a pointer to the element at the loop index, which is runtime-known
    /// except when inferring one iteration (`iteration`). Without an iteration, the capture of
    /// an `inline for` differs between iterations when the first element is aligned differently
    /// from the others, so its alignment is unknown then.
    fn forCaptureAttrs(inf: *Inferrer, l: Body.Loop, input: ExprId, list: Index, elem: Index, iteration: ?u32) Error!InternPool.PtrAttrs {
        if (elem == .unknown) return .{};
        const parent = switch (inf.ip.key(list)) {
            .ptr_type => |p| p.attrs,
            else => try inf.placeAttrs(input),
        };
        if (iteration) |n| return eval.elemPtrAttrs(inf.r, parent, elem, n);
        var attrs = try eval.elemPtrAttrs(inf.r, parent, elem, null);
        if (l.is_inline and attrs.alignment != (try eval.elemPtrAttrs(inf.r, parent, elem, 0)).alignment) attrs.alignment = .unknown;
        return attrs;
    }

    /// The binding when the name `e` refers to a `comptime var` of this member
    fn comptimeVarOf(inf: *Inferrer, e: ExprId) Error!?Body.BindingId {
        const b = inf.body;
        const name = switch (b.expr(e)) {
            .name_ref => |n| n,
            else => return null,
        };
        // Declarations come first: when no `comptime var` has been declared yet, the name
        // cannot refer to one
        if (inf.var_levels.len == 0) return null;
        const def = try inf.r.resolveName(inf.file, inf.item, b, b.expr_scopes[@backingInt(e)], name) orelse return null;
        const l = switch (def) {
            .local => |l| l,
            else => return null,
        };
        if (l.file != inf.file or l.item != inf.item) return null;
        const binding = b.binding(l.binding);
        return if (binding.kind == .local_var and binding.is_comptime) l.binding else null;
    }

    /// The `comptime var` of this member whose storage place `e` lies in: the variable itself, or
    /// a field or element of it (`v`, `v.f`, `v[i]`)
    fn comptimeVarPlace(inf: *Inferrer, e: ExprId) Error!?Body.BindingId {
        var cur = e;
        while (true) switch (inf.body.expr(cur)) {
            .field_access => |fa| cur = fa.lhs,
            .index => |x| cur = x.lhs,
            .@"comptime" => |x| cur = x,
            else => return inf.comptimeVarOf(cur),
        };
    }

    /// The `comptime var` that expression `x` can modify other than by assigning to the
    /// variable itself (`v = a`, `v += a`): an assignment to a field or element of it, its
    /// address (`&v`, which a callee or a pointer capture can write through), a method call on it
    /// (a `*Self` receiver takes its address), or a pointer capture of its payload
    fn indirectlyModifiedVar(inf: *Inferrer, x: Body.Expr) Error!?Body.BindingId {
        const b = inf.body;
        const place = switch (x) {
            .assign => |a| if (b.expr(a.lhs) == .name_ref) return null else a.lhs,
            .prefix => |p| if (p.op == .ampersand) p.operand else return null,
            .call => |c| switch (b.expr(c.callee)) {
                .field_access => |fa| fa.lhs,
                else => return null,
            },
            .@"if" => |i| if (i.capture.len > 0 and b.binding(i.capture[0]).is_ptr) i.cond else return null,
            else => return null,
        };
        return inf.comptimeVarPlace(place);
    }

    /// A `comptime var` that may be modified through a pointer or a part of it: its value is
    /// unknown from here on, also after later direct assignments (a pointer to it may still
    /// write)
    fn untrackComptimeVar(inf: *Inferrer, b: Body.BindingId) void {
        if (inf.dead > 0) return;
        inf.bindings[@backingInt(b)].val = null;
        if (@backingInt(b) < inf.var_levels.len) inf.var_levels[@backingInt(b)] = std.math.maxInt(u32);
    }

    /// Assignment to a `comptime var`: under control flow as determined as at its declaration (see
    /// `uncertain`), the assignment updates its value; otherwise the value becomes unknown
    fn assignComptimeVar(inf: *Inferrer, b: Body.BindingId, op: SyntaxKind, rhs: TypedValue) Error!void {
        if (inf.dead > 0) return;
        const slot = &inf.bindings[@backingInt(b)];
        const level = if (@backingInt(b) < inf.var_levels.len) inf.var_levels[@backingInt(b)] else 0;
        if (inf.uncertain != level) {
            slot.val = null;
            return;
        }
        const ty = slot.ty;
        if (op == .equal) {
            slot.val = if (rhs.ty == ty) rhs.val else if (value.intOf(inf.ip, rhs.val)) |n| (if (ty == .comptime_int_type or inf.ip.isInt(ty)) try inf.ip.get(.{ .int_value = .{ .ty = ty, .value = n } }) else null) else null;
            return;
        }
        const bin: SyntaxKind = switch (op) {
            .plus_equal => .plus,
            .minus_equal => .minus,
            .asterisk_equal => .asterisk,
            .slash_equal => .slash,
            .percent_equal => .percent,
            .plus_percent_equal => .plus_percent,
            .minus_percent_equal => .minus_percent,
            .asterisk_percent_equal => .asterisk_percent,
            .plus_pipe_equal => .plus_pipe,
            .minus_pipe_equal => .minus_pipe,
            .asterisk_pipe_equal => .asterisk_pipe,
            .ampersand_equal => .ampersand,
            .pipe_equal => .pipe,
            .caret_equal => .caret,
            .angle_bracket_angle_bracket_left_equal => .angle_bracket_angle_bracket_left,
            .angle_bracket_angle_bracket_right_equal => .angle_bracket_angle_bracket_right,
            .angle_bracket_angle_bracket_left_pipe_equal => .angle_bracket_angle_bracket_left_pipe,
            else => {
                slot.val = null;
                return;
            },
        };
        slot.val = (try inf.foldInt(bin, ty, slot.*, rhs)).val;
    }

    /// Assignments within `e` to `comptime var`s declared outside it
    fn outerComptimeVars(inf: *Inferrer, e: ExprId, out: ?*std.ArrayList(Body.BindingId)) Error!bool {
        const b = inf.body;
        // When the member has no `comptime var`, the left-hand sides of assignments need not be
        // resolved one by one
        if (inf.var_levels.len == 0) {
            for (b.bindings) |x| {
                if (x.kind == .local_var and x.is_comptime) break;
            } else return false;
        }
        const range = b.range(e);
        var any = false;
        for (b.exprs, b.expr_ranges) |x, rg| {
            if (rg.start < range.start or rg.end > range.end) continue;
            const v = (if (x == .assign) try inf.comptimeVarOf(x.assign.lhs) else null) orelse
                try inf.indirectlyModifiedVar(x) orelse continue;
            if (range.contains(b.binding(v).range.start)) continue;
            any = true;
            const list = out orelse return true;
            try list.append(inf.scratch, v);
        }
        return any;
    }

    fn assignsOuterComptimeVar(inf: *Inferrer, e: ExprId) Error!bool {
        return inf.outerComptimeVars(e, null);
    }

    fn forgetOuterComptimeVars(inf: *Inferrer, e: ExprId) Error!void {
        var vars: std.ArrayList(Body.BindingId) = .empty;
        _ = try inf.outerComptimeVars(e, &vars);
        for (vars.items) |v| inf.bindings[@backingInt(v)].val = null;
    }

    /// A loop variable whose values are types (`inline for (.{ f32, f64 }) |T|`): the type
    /// differs in each iteration, so it is inferred as an abstract parameter, like
    /// `comptime T: type` of a generic function. When inferring one iteration (`loop_seed`), it
    /// takes that element of the list.
    fn typeCapture(inf: *Inferrer, cap: Body.BindingId, list: TypedValue, iteration: ?u32) Error!TypedValue {
        if (iteration) |n| if (list.val != null) {
            if (try eval.elemValue(inf.r, list, n)) |ev| if (ev.val) |t| return TypedValue.ofType(t);
        };
        return TypedValue.ofType(try inf.ip.get(.{ .opaque_param = .{ .file = inf.file, .owner = try inf.body_owner(), .binding = @backingInt(cap), .name = inf.body.binding(cap).name } }));
    }

    /// Whether a pointer capture of `for` is const: when iterating over a pointer (slice,
    /// many-item pointer, pointer to array), the pointer's own `is_const`; when iterating over an
    /// array value, whether the iterated value is a const place
    fn forCaptureConst(inf: *Inferrer, input: ExprId, list: Index) Error!bool {
        return switch (inf.ip.key(list)) {
            .ptr_type => |p| p.is_const,
            .array_type, .vector_type, .tuple_type => inf.isConstPlace(input),
            else => false,
        };
    }

    /// Type of a non-type loop variable when inferring the `n`-th iteration: for a tuple whose
    /// items have different types (`.{ &posix, &windows }`), the type of the `n`-th item
    fn iterationType(inf: *Inferrer, list: Index, elem: Index, n: u32, ptr: bool, is_const: bool, attrs: InternPool.PtrAttrs) Error!Index {
        var t = elem;
        if (t == .unknown) if (tupleOf(inf.ip, list)) |tt| if (n < tt.types.len) {
            t = tt.types[n];
        };
        return if (ptr) singlePtr(inf.ip, t, is_const, attrs) else t;
    }

    /// Value of a non-type loop variable when inferring the `n`-th iteration: `start + n` for a
    /// range (`start..`), the `n`-th element for a list
    fn iterationValue(inf: *Inferrer, list: TypedValue, start: TypedValue, n: u32) Error!?Index {
        if (value.intOf(inf.ip, start.val)) |s| return try inf.ip.get(.{ .int_value = .{ .ty = .usize_type, .value = s + n } });
        if (list.val == null) return null;
        return if (try eval.elemValue(inf.r, list, n)) |ev| ev.val else null;
    }

    /// The operand type when the target of `continue :label` is a labeled switch
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

    /// Expected type of the right-hand side of `catch` / `orelse`. The compiler uses the result
    /// type of the whole expression; without a result type, both sides go through peer type
    /// resolution, and here the payload type serves as the expected type of right-hand side
    /// literals (`0`, `.red`), which gives the same result as the peer. `null` is the exception:
    /// its peer with the payload is an optional (`parseInt(u8, s, 10) catch null` is `?u8`), so it
    /// cannot be coerced to the payload type.
    fn fallbackType(inf: *Inferrer, expected: ?Index, payload: Index, rhs: ExprId) ?Index {
        if (expected) |want| if (want != .unknown) return want;
        if (payload == .unknown) return null;
        switch (inf.body.expr(rhs)) {
            .name_ref => |name| if (std.mem.eql(u8, name, "null")) return null,
            else => {},
        }
        return payload;
    }

    /// Whether the function body has a `continue :label` (through which a labeled switch jumps to
    /// another prong)
    fn continuesTo(inf: *Inferrer, label: []const u8) bool {
        for (inf.body.exprs) |x| switch (x) {
            .@"continue" => |c| if (c.label) |l| if (std.mem.eql(u8, l, label)) return true,
            else => {},
        };
        return false;
    }

    /// Label of a switch: lowering pushes a labeled scope targeting this switch before the operand
    fn switchLabel(inf: *Inferrer, e: ExprId, operand: ExprId) ?[]const u8 {
        const b = inf.body;
        var s: ?Body.ScopeId = b.expr_scopes[@backingInt(operand)];
        while (s) |id| : (s = b.scope(id).parent) {
            const l = b.scope(id).label orelse continue;
            if (l.expr == e) return l.name;
        }
        return null;
    }

    /// Target of a break (an index into `labels`)
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

    /// Captures of if / while: the child type of an optional, the payload of an error union (the
    /// error set in the else branch)
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
        if (is_ptr and inf.var_levels.len != 0) if (try inf.comptimeVarPlace(cond_e)) |v| inf.untrackComptimeVar(v);
        // A known non-null optional value is its payload value
        const val: ?Index = if (!is_ptr and source == .if_then and ip.key(cond) == .optional_type and inf.condValue(cond_tv) == true) value.optionalPayload(ip, cond_tv.val.?) else null;
        if (!is_ptr) {
            inf.bindings[@backingInt(cap)] = .{ .ty = t, .val = val };
            return;
        }
        // The payload of an optional is at its start; a pointer to the payload of an error union
        // keeps only the address space
        const place = try inf.placeAttrs(cond_e);
        const attrs: InternPool.PtrAttrs = if (ip.key(cond) == .optional_type) place else .{ .address_space = place.address_space };
        inf.bindings[@backingInt(cap)] = .{ .ty = try singlePtr(ip, t, try inf.isConstPlace(cond_e), attrs) };
    }

    /// Captures of a switch. For a tagged union, the capture of an ordinary prong is the peer of
    /// the field types of the prong items (matching the compiler); it is unknown for the `else`
    /// prong and for prong items that cannot be evaluated. An `inline` prong is instantiated for
    /// each of its payloads (see `inlineUnionPayloads`): inferred for one of them (see
    /// `LoopSeed`), the capture has that field's type and the tag capture that tag; otherwise the
    /// capture has their common type, unknown when they differ. The second capture is the tag.
    /// `chosen`: the operand is comptime-known and this is the prong that executes, so the
    /// capture takes the actual payload value (and its type, when the capture's type is unknown).
    fn bindSwitchCapture(inf: *Inferrer, prongs: []const Body.Prong, pi: usize, operand_e: ExprId, operand_tv: TypedValue, chosen: bool) Error!void {
        const prong = prongs[pi];
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
        const cap = prong.capture[0];
        // The tag of this instance of an inline prong
        var inline_tag: ?[]const u8 = null;
        var t: Index = if (is_union and prong.is_inline) blk: {
            const payloads = try inlineUnionPayloads(inf.r, inf.body, inf.exprs, prongs, pi, operand) orelse break :blk .unknown;
            if (inf.iterationSeed()) |seed| if (seed.binding == @backingInt(cap)) {
                if (seed.index >= payloads.len) break :blk .unknown;
                inline_tag = payloads[seed.index].name;
                break :blk payloads[seed.index].ty;
            };
            if (payloads.len == 0) break :blk .unknown;
            for (payloads[1..]) |p| if (p.ty != payloads[0].ty) break :blk .unknown;
            break :blk payloads[0].ty;
        } else if (is_union)
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
        const is_ptr = inf.body.binding(cap).is_ptr;
        if (is_ptr and inf.var_levels.len != 0) if (try inf.comptimeVarPlace(operand_e)) |v| inf.untrackComptimeVar(v);
        // Inferring for one value of an inline prong (see `LoopSeed`): the capture takes the value
        // of this prong item
        if (prong.is_inline and !is_union and !is_error_set and !is_ptr) if (inf.iterationSeed()) |seed| if (seed.binding == @backingInt(cap)) {
            if ((try inlineProngValues(ip, inf.body, inf.exprs, prong, operand, seed.index)).value) |v| val = v;
        };
        if (is_ptr) {
            const attrs = try inf.switchCaptureAttrs(prongs, pi, operand_e, operand, t, is_union, inline_tag);
            inf.bindings[@backingInt(cap)] = .{ .ty = try singlePtr(ip, t, try inf.isConstPlace(operand_e), attrs) };
        } else inf.bindings[@backingInt(cap)] = .{ .ty = t, .val = val };
        if (prong.capture.len > 1) {
            const tag: Index = if (is_union) try eval.unionTag(inf.r, operand) orelse .unknown else .unknown;
            const tag_val: ?Index = if (inline_tag) |name| (if (tag != .unknown) try ip.get(.{ .enum_tag = .{ .ty = tag, .name = name } }) else null) else null;
            inf.bindings[@backingInt(prong.capture[1])] = .{ .ty = tag, .val = tag_val };
        }
    }

    /// Attributes of the pointer capture of a switch prong (with payload type `t`): for a tagged
    /// union, those of a pointer to the field of the prong's items (the alignment is unknown when
    /// they differ between the items); otherwise those of a pointer to the operand
    fn switchCaptureAttrs(inf: *Inferrer, prongs: []const Body.Prong, pi: usize, operand_e: ExprId, operand: Index, t: Index, is_union: bool, inline_tag: ?[]const u8) Error!InternPool.PtrAttrs {
        const prong = prongs[pi];
        if (!is_union) return inf.placeAttrs(operand_e);
        if (t == .unknown) return .{};
        if (inline_tag) |name| return inf.fieldPlaceAttrs(operand_e, name, t);
        var names: std.ArrayList([]const u8) = .empty;
        if (prong.is_inline) {
            const payloads = try inlineUnionPayloads(inf.r, inf.body, inf.exprs, prongs, pi, operand) orelse return .{ .alignment = .unknown };
            for (payloads) |p| try names.append(inf.scratch, p.name);
        } else for (prong.items) |item| {
            try names.append(inf.scratch, itemTagName(inf.ip, inf.body, inf.exprs, item) orelse return .{ .alignment = .unknown });
        }
        if (names.items.len == 0) return .{};
        var attrs = try inf.fieldPlaceAttrs(operand_e, names.items[0], t);
        for (names.items[1..]) |name| {
            if ((try inf.fieldPlaceAttrs(operand_e, name, t)).alignment != attrs.alignment) attrs.alignment = .unknown;
        }
        return attrs;
    }

    /// Type of a prong capture in a switch on an error set: for an ordinary prong, the set of the
    /// errors in its items; for `else`, the operand's members minus the errors listed by other
    /// prongs; unknown when the members cannot be evaluated (`anyerror`)
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
            const name = itemTagName(inf.ip, inf.body, inf.exprs, item) orelse return .unknown;
            t.* = try inf.unionFieldType(operand, name) orelse return .unknown;
        }
        return inf.peer(types);
    }

    /// Type of a union field
    fn unionFieldType(inf: *Inferrer, t: Index, name: []const u8) Error!?Index {
        if (inf.ip.key(t) != .container_type) return eval.fieldType(inf.r, t, name);
        const ns = try queries.namespaceOfType(inf.r, t) orelse return null;
        const tree = try inf.r.itemTree(ns.file);
        const f = fieldItem(tree, ns.container, name) orelse return null;
        return (try queries.defType(inf.r, .{ .item = .{ .file = ns.file, .item = f } }, null, queries.instOfType(inf.ip, t))).ty;
    }

    // ── Operations ───────────────────────────────────────────────────

    /// Result type of the other side of a comparison: a tagged union is compared with a tag, so
    /// the other side takes the tag type (`u == .none`)
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
                const lhs = try inf.comptimeOperand(lhs_e, try inf.infer(lhs_e, null));
                const child: Index = switch (ip.key(lhs.ty)) {
                    .optional_type => |c| c,
                    else => .unknown,
                };
                // When comptime-known, only one side is evaluated, and a right-hand side that is
                // taken gets only the result type of the whole expression
                const non_null = inf.condValue(lhs);
                const rhs = try inf.inferBranch(rhs_e, inf.fallbackType(expected, if (non_null == false) .unknown else child, rhs_e), non_null == true);
                if (non_null) |n| return if (n) .{ .ty = child, .val = value.optionalPayload(ip, lhs.val.?) } else rhs;
                return .{ .ty = try inf.peer(&.{ child, rhs.ty }) };
            },
            .keyword_and, .keyword_or => {
                const is_and = op == .keyword_and;
                const lhs = inf.condValue(try inf.infer(lhs_e, .bool_type));
                // When the left-hand side is comptime-known and decides the result, the right-hand
                // side is not compiled (`@hasDecl(T, "x") and T.x`)
                const rhs = inf.condValue(try inf.inferArm(rhs_e, .bool_type, if (lhs) |l| l != is_and else false));
                // Short-circuit: one side has already decided the result
                if (lhs) |l| if (l != is_and) return boolValue(l);
                if (rhs) |r| if (r != is_and) return boolValue(r);
                if (lhs != null and rhs != null) return boolValue(is_and);
                return .{ .ty = .bool_type };
            },
            .equal_equal, .bang_equal, .angle_bracket_left, .angle_bracket_right, .angle_bracket_left_equal, .angle_bracket_right_equal => {
                // Matches the compiler: the operands have no result type (see `comparedOperand`)
                const l = try inf.infer(lhs_e, null);
                const r = try inf.infer(rhs_e, null);
                // A literal compared with a value of unknown type may name a member of that type
                if (l.ty == .unknown) try inf.noteUnknownResult(rhs_e);
                if (r.ty == .unknown) try inf.noteUnknownResult(lhs_e);
                const lhs = try inf.comparedOperand(lhs_e, l, r.ty);
                const rhs = try inf.comparedOperand(rhs_e, r, l.ty);
                // An enum literal compared with a value that has no tag of that name: not a
                // comparison the compiler accepts, so it has no value
                if ((lhs.ty == .enum_literal_type) != (rhs.ty == .enum_literal_type)) return .{ .ty = .bool_type };
                // Vectors are compared element-wise; the result is a vector of bool
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
            // Matches the compiler: the left-hand side has no result type; the right-hand side of
            // `<<` / `>>` is inferred with `Log2Int(T)` as its result type, and that of `<<|` has
            // no result type
            .angle_bracket_angle_bracket_left, .angle_bracket_angle_bracket_right, .angle_bracket_angle_bracket_left_pipe => {
                const lhs = try inf.infer(lhs_e, null);
                const rhs = try inf.infer(rhs_e, if (op == .angle_bracket_angle_bracket_left_pipe) null else try value.log2IntType(ip, lhs.ty));
                return inf.foldInt(op, lhs.ty, lhs, rhs);
            },
            .plus_plus => return inf.concat(e, try inf.infer(lhs_e, null), try inf.infer(rhs_e, null)),
            // Pointer arithmetic (matches the compiler): `[*]T ± usize` is the original pointer
            // type with the alignment of the element at the offset, and the difference of two
            // pointers is usize
            .plus, .minus => {
                const lhs = try inf.infer(lhs_e, null);
                if (!isNonSlicePtr(ip, lhs.ty)) return inf.arith(op, lhs, rhs_e);
                const rhs = try inf.infer(rhs_e, .usize_type);
                if (isNonSlicePtr(ip, rhs.ty)) return .{ .ty = if (op == .minus) .usize_type else .unknown };
                return .{ .ty = if (isManyPtr(ip, lhs.ty)) try inf.ptrArithmetic(lhs.ty, rhs) else .unknown };
            },
            // Merging error sets
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

    /// Arithmetic and bitwise operations: the peer of both sides; when both sides are known
    /// integers, the result is folded with the bit width of the peer type. Matching the compiler,
    /// the operands have no result type (`const m: u8 = (0xFF << 4) >> 4` is computed as
    /// comptime_int, giving 255, and only then converted to u8; `b + @intCast(y)` has no type).
    fn arith(inf: *Inferrer, op: SyntaxKind, lhs: TypedValue, rhs_e: ExprId) Error!TypedValue {
        const rhs = try inf.infer(rhs_e, null);
        return inf.foldInt(op, try inf.peer(&.{ lhs.ty, rhs.ty }), lhs, rhs);
    }

    /// `++` (matches the compiler's `zirArrayCat`): concatenating tuples gives a tuple;
    /// concatenating arrays and pointers to arrays gives an array, whose element type is the
    /// peer of both sides' element types, or `*const [N]T` when either side is a pointer. When
    /// the values of both sides are known, the interpreter evaluates the result.
    fn concat(inf: *Inferrer, e: ExprId, lhs: TypedValue, rhs: TypedValue) Error!TypedValue {
        const ty = try inf.concatType(lhs.ty, rhs.ty);
        if (ty == .unknown) return .unknown;
        if (lhs.val != null and rhs.val != null and inf.dead == 0 and !inf.r.ctx.incomplete()) {
            const tv = try eval.exprValue(inf.r, inf.file, inf.item, inf.body, e, inf.inst, inf.bindings, null, inf.branchQuota());
            if (tv.val != null and tv.ty == ty) return tv;
        }
        return .{ .ty = ty };
    }

    /// When the operand value `operand` is known, the interpreter evaluates `e`; null when it
    /// cannot be evaluated or its type is not `ty`
    fn knownValue(inf: *Inferrer, e: ExprId, operand: ?Index, ty: Index) Error!?TypedValue {
        if (operand == null or inf.dead != 0 or inf.r.ctx.incomplete()) return null;
        const tv = try eval.exprValue(inf.r, inf.file, inf.item, inf.body, e, inf.inst, inf.bindings, null, inf.branchQuota());
        return if (tv.val != null and tv.ty == ty) tv else null;
    }

    fn concatType(inf: *Inferrer, a: Index, b: Index) Error!Index {
        const ip = inf.ip;
        if (ip.key(a) == .tuple_type and ip.key(b) == .tuple_type) {
            // comptime fields stay comptime fields
            const x = ip.key(a).tuple_type;
            const y = ip.key(b).tuple_type;
            const types = try std.mem.concat(inf.scratch, Index, &.{ x.types, y.types });
            const values = try inf.scratch.alloc(Index, types.len);
            for (values, 0..) |*v, i| v.* = if (i < x.types.len) InternPool.fieldValue(x.values, i) else InternPool.fieldValue(y.values, i - x.types.len);
            return ip.get(.{ .tuple_type = .{ .types = types, .values = InternPool.fieldValues(values) } });
        }
        // When concatenating a tuple with an array, the tuple is treated as an array with the
        // element type of the other side
        const x = concatOperand(ip, a, b) orelse return .unknown;
        const y = concatOperand(ip, b, a) orelse return .unknown;
        const elem = try inf.peer(&.{ x.elem, y.elem });
        if (elem == .unknown) return .unknown;
        // Sentinels are converted to the result's element type before being compared
        const xs: ?Index = if (x.sentinel) |v| try value.coerceValue(ip, v, elem) orelse return .unknown else null;
        const ys: ?Index = if (y.sentinel) |v| try value.coerceValue(ip, v, elem) orelse return .unknown else null;
        // The length is a u64; a concatenation whose length cannot be represented gives no result
        const len = std.math.add(u64, x.len, y.len) catch return .unknown;
        const array = try ip.get(.{ .array_type = .{ .len = len, .child = elem, .sentinel = eval.concatSentinel(xs, ys) } });
        return if (x.is_ptr or y.is_ptr) ip.ptrTo(array, .one, true) else array;
    }

    /// Integer operations: the result type is `ty`; it carries a value when the values of both
    /// sides are known and the result is defined
    fn foldInt(inf: *Inferrer, op: SyntaxKind, ty: Index, lhs: TypedValue, rhs: TypedValue) Error!TypedValue {
        const ip = inf.ip;
        if (ip.isFloat(ty)) {
            // Comptime operands are coerced (rounded) to the peer type first
            const a = value.floatOf(ip, if (lhs.val) |v| try value.coerceValue(ip, v, ty) else null) orelse return .{ .ty = ty };
            const b = value.floatOf(ip, if (rhs.val) |v| try value.coerceValue(ip, v, ty) else null) orelse return .{ .ty = ty };
            return .{ .ty = ty, .val = try value.binaryFloat(ip, op, ty, a, b) };
        }
        if (ty != .comptime_int_type and !ip.isInt(ty)) return .{ .ty = ty };
        if (value.intOf(ip, lhs.val)) |a| {
            if (value.intOf(ip, rhs.val)) |b| {
                if (value.binaryInt(ip, op, ty, a, b)) |v| return .{ .ty = ty, .val = try ip.get(.{ .int_value = .{ .ty = ty, .value = v } }) };
            }
        }
        // A comptime_int operand may not fit i128 (or the result may not), and types wider than
        // 128 bits are computed at arbitrary precision
        if (lhs.val != null and rhs.val != null and value.isBigIntType(ip, ty)) {
            const a = try value.bigValueOf(ip, inf.scratch, lhs.val) orelse return .{ .ty = ty };
            const b = try value.bigValueOf(ip, inf.scratch, rhs.val) orelse return .{ .ty = ty };
            const r = try value.binaryBig(ip, inf.scratch, op, ty, a, b) orelse return .{ .ty = ty };
            return .{ .ty = ty, .val = try value.internInt(ip, inf.scratch, ty, r) };
        }
        return .{ .ty = ty };
    }

    fn prefix(inf: *Inferrer, op: SyntaxKind, operand_e: ExprId, expected: ?Index) Error!TypedValue {
        const ip = inf.ip;
        switch (op) {
            .keyword_try => {
                // Matches the compiler: the result type is only used for looking up decl literals
                // in `try .foo(...)`
                const decl_call = switch (inf.body.expr(operand_e)) {
                    .call => |c| inf.body.expr(c.callee) == .enum_literal,
                    else => false,
                };
                // A bare `try .foo` is no decl literal, but it is `try .foo(...)` being typed: its
                // result type is recorded for completion without being used for inference
                if (expected) |want| if (want != .unknown and inf.body.expr(operand_e) == .enum_literal) {
                    try inf.literal_expected.append(inf.scratch, .{ .expr = operand_e, .ty = want });
                };
                const v = try inf.infer(operand_e, if (decl_call) expected else null);
                const payload, _ = inf.unwrapErrorUnion(v.ty);
                return .{ .ty = payload };
            },
            .bang => {
                const operand = try inf.infer(operand_e, .bool_type);
                // A vector of bools is negated element-wise
                if (ip.key(operand.ty) == .vector_type) return .{ .ty = operand.ty };
                if (inf.condValue(operand)) |b| if (operand.ty == .bool_type) return boolValue(!b);
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
                        // `&.{ a, b }` coerced to a slice or many-item pointer: inferred as `[2]T`
                        .slice, .many, .c => switch (inf.body.expr(operand_e)) {
                            .init => |init| if (init.ty == null) try ip.get(.{ .array_type = .{ .len = init.fields.len, .child = p.child, .sentinel = p.sentinel } }) else null,
                            else => null,
                        },
                    },
                    else => null,
                } else null;
                var v = try inf.infer(operand_e, child_expected);
                const is_const = try inf.isConstPlace(operand_e);
                const ty: Index = if (v.ty == .unknown) .unknown else try ip.get(.{ .ptr_type = .{ .child = v.ty, .size = .one, .is_const = is_const, .attrs = try inf.placeAttrs(operand_e) } });
                // Typed aggregate literals get no value from inference: a pointer to an array
                // literal whose elements are all comptime-known (`&.{ 1, 2 }` coerced to a slice)
                // gets the array from the interpreter
                if (is_const and v.val == null and ip.key(v.ty) == .array_type and inf.dead == 0 and !inf.r.ctx.incomplete()) switch (inf.body.expr(operand_e)) {
                    .init => |init| known: {
                        for (init.fields) |f| if (inf.get(f.value).val == null) break :known;
                        const tv = try eval.exprValue(inf.r, inf.file, inf.item, inf.body, operand_e, inf.inst, inf.bindings, v.ty, inf.branchQuota());
                        if (tv.ty == v.ty) v = tv;
                    },
                    else => {},
                };
                // A pointer to a comptime-known constant (`parseEx(Id, &params, ...)`,
                // `@field(x, &name)`) is comptime-known: its value points to the constant's value,
                // and to its place when that is inside a container-level declaration
                if (is_const) if (v.val) |pointee| {
                    if (try inf.mayBeInDeclaration(operand_e))
                        return .{ .ty = ty, .val = try eval.addressValue(inf.r, inf.file, inf.item, inf.body, operand_e, inf.inst, inf.bindings, ty, pointee) };
                    return .{ .ty = ty, .val = try eval.constPointer(inf.r, ty, pointee) };
                };
                return .{ .ty = ty };
            },
            .minus, .minus_percent, .tilde => {
                // Matches the compiler: the operand has no result type, and the result is then
                // converted to the expected type (`const x: i8 = -128`, `@as(i8, -(1 << 7))`)
                const v = try inf.infer(operand_e, null);
                if (op == .minus and ip.isFloat(v.ty)) {
                    const x = value.floatOf(ip, v.val) orelse return .{ .ty = v.ty };
                    return .{ .ty = v.ty, .val = try value.floatValue(ip, v.ty, -x) };
                }
                if (value.intOf(ip, v.val)) |a| {
                    if (switch (op) {
                        .tilde => value.bitNot(ip, v.ty, a),
                        else => value.negate(ip, v.ty, a, op == .minus_percent),
                    }) |r| return .{ .ty = v.ty, .val = try ip.get(.{ .int_value = .{ .ty = v.ty, .value = r } }) };
                }
                if (v.val != null and value.isBigIntType(ip, v.ty)) {
                    const a = try value.bigValueOf(ip, inf.scratch, v.val) orelse return .{ .ty = v.ty };
                    const r = try value.unaryBig(ip, inf.scratch, op, v.ty, a) orelse return .{ .ty = v.ty };
                    return .{ .ty = v.ty, .val = try value.internInt(ip, inf.scratch, v.ty, r) };
                }
                return .{ .ty = v.ty };
            },
            else => return .{ .ty = (try inf.infer(operand_e, expected)).ty },
        }
    }

    fn initExpr(inf: *Inferrer, ty_e: ?ExprId, fields: []const Body.FieldInit, expected: ?Index) Error!TypedValue {
        const ip = inf.ip;
        // The type of `.{ ... }` is the result type with error union and optional stripped
        // (matches the compiler)
        const want = inf.destType(expected, .eu_opt);
        if (ty_e == null and want == null) return inf.anonInit(fields);
        const t: Index = if (ty_e) |te|
            try inf.inferredLenArray(te, fields.len) orelse (try inf.infer(te, null)).asType() orelse .unknown
        else
            want.?;
        const ns: ?Namespace = if (t != .unknown and ip.key(t) == .container_type) try queries.namespaceOfType(inf.r, t) else null;
        for (fields, 0..) |f, fi_index| {
            const field = try initField(inf.r, t, ns, fi_index, f.name);
            if (field.member) |m| if (inf.current_init) |init_e| try inf.field_refs.append(inf.scratch, .{ .init = init_e, .index = @intCast(fi_index), .member = m });
            if (t == .unknown or field.ty == .unknown) try inf.noteUnknownResult(f.value);
            _ = try inf.infer(f.value, if (field.ty) |x| (if (x != .unknown) x else null) else null);
        }
        return .{ .ty = t };
    }

    /// `.{ ... }` without a result type: a tuple (`struct { A, B }`) or an anonymous struct;
    /// it carries a value when all elements are known
    fn anonInit(inf: *Inferrer, fields: []const Body.FieldInit) Error!TypedValue {
        const ip = inf.ip;
        const types = try inf.scratch.alloc(Index, fields.len);
        const vals = try inf.scratch.alloc(Index, fields.len);
        for (fields, types, vals) |f, *t, *v| {
            const tv = try inf.infer(f.value, null);
            t.* = tv.ty;
            v.* = tv.val orelse .unknown;
        }
        for (types) |t| if (t == .unknown) return .unknown;
        // comptime-known fields are comptime fields, and their values belong to the type
        // (matches the compiler)
        const values = try inf.scratch.alloc(Index, fields.len);
        for (fields, types, vals, values) |f, t, *v, *o| {
            o.* = try inf.literalField(f.value, t, v.*);
            // A value the interpreter computed for the field is also part of the literal's value
            if (v.* == .unknown) if (inf.get(f.value).val) |x| {
                v.* = x;
            };
        }
        const known = for (vals) |v| {
            if (v == .unknown) break false;
        } else true;
        const field_values = InternPool.fieldValues(values);
        const named = fields.len > 0 and fields[0].name != null;
        const ty = if (named) blk: {
            const names = try inf.scratch.alloc([]const u8, fields.len);
            for (fields, names) |f, *n| n.* = f.name orelse return .unknown;
            break :blk try ip.get(.{ .anon_struct_type = .{ .names = names, .types = types, .values = field_values } });
        } else try ip.get(.{ .tuple_type = .{ .types = types, .values = field_values } });
        return .{ .ty = ty, .val = if (known) try value.aggregate(ip, inf.scratch, ty, vals) else null };
    }

    /// comptime value of a literal field (see `InternPool.fieldValue`): that value when it is
    /// known or the type has only one possible value, `runtime` for a runtime value, and `unknown`
    /// when it cannot be determined
    fn literalField(inf: *Inferrer, e: ExprId, ty: Index, val: Index) Error!Index {
        if (val != .unknown) return val;
        if (ty == .void_type) return .void_value;
        // String literals (the inferrer does not produce values for strings)
        switch (inf.body.expr(e)) {
            .literal => |text| if (try Body.stringLiteralValue(inf.scratch, text)) |str| {
                return inf.ip.get(.{ .bytes = .{ .ty = ty, .bytes = str } });
            },
            else => {},
        }
        if (value.intInfo(inf.ip, ty)) |info| if (info.bits == 0) return inf.ip.get(.{ .int_value = .{ .ty = ty, .value = 0 } });
        if (inf.comptime_depth > 0) return .unknown;
        if (try inf.knownness(e, 0) == .runtime) return .runtime;
        // The compiler makes every field whose value is comptime-known a comptime field, including
        // values inference does not compute (slices of strings: `.{@as([]const u8, "abc")}`)
        if (try inf.interpretedValue(e, ty)) |v| return v;
        return .unknown;
    }

    /// comptime value of `e` (of type `ty`) computed by the interpreter under the current bindings,
    /// for a value that inference does not compute outside a comptime context; it becomes the
    /// value of the expression
    fn interpretedValue(inf: *Inferrer, e: ExprId, ty: Index) Error!?Index {
        if (inf.dead > 0 or inf.r.ctx.incomplete()) return null;
        switch (inf.body.expr(e)) {
            .missing, .other => return null,
            else => {},
        }
        const ev = try eval.exprValue(inf.r, inf.file, inf.item, inf.body, e, inf.inst, inf.bindings, null, inf.branchQuota());
        const v = ev.val orelse return null;
        if (ev.ty != ty) return null;
        inf.exprs[@backingInt(e)] = ev;
        return v;
    }

    const Knownness = enum { comptime_known, runtime, uncertain };

    /// Whether the value of an expression is comptime-known, covering common cases with the same
    /// judgment as the compiler; `uncertain` when it cannot be determined
    fn knownness(inf: *Inferrer, e: ExprId, depth: u32) Error!Knownness {
        const ip = inf.ip;
        const tv = inf.get(e);
        if (tv.val != null) return .comptime_known;
        // Values of comptime-only types are always comptime-known
        if (tv.ty != .unknown and value.isComptimeOnly(ip, tv.ty)) return .comptime_known;
        if (depth > 8) return .uncertain;
        const b = inf.body;
        switch (b.expr(e)) {
            .name_ref => |name| {
                const def = try inf.r.resolveName(inf.file, inf.item, b, b.expr_scopes[@backingInt(e)], name) orelse return .uncertain;
                switch (def) {
                    .local => |l| {
                        // A local of the outer function (referenced in a member of a container in
                        // the body): matching the compiler, it can only be a comptime-known one
                        if (l.file != inf.file or l.item != inf.item) return .comptime_known;
                        const binding = b.binding(l.binding);
                        return switch (binding.kind) {
                            .local_var => if (binding.is_comptime) .comptime_known else .runtime,
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
                // A declaration of a container
                if (inf.members[@backingInt(e)]) |owner| {
                    const tree = try inf.r.itemTree(owner.file);
                    for (tree.items) |it| if (it.ast_id == owner.item) return declKnownness(it);
                    return .uncertain;
                }
                return inf.anyRuntime(&.{fa.lhs}, depth);
            },
            .call => |c| {
                // Calls to ordinary functions execute at runtime (calls that return comptime-only
                // types have been handled above)
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
                // Cast builtins depend on the value being cast (the last argument), and `@field`
                // on the object
                const casts = [_][]const u8{ "@as", "@intCast", "@truncate", "@bitCast", "@floatCast", "@floatFromInt", "@intFromFloat", "@ptrCast", "@alignCast", "@constCast", "@volatileCast", "@intFromEnum", "@enumFromInt", "@intFromBool", "@intFromPtr", "@errorCast" };
                for (casts) |n| if (std.mem.eql(u8, c.name, n)) return inf.anyRuntime(c.args[c.args.len - 1 ..], depth);
                if (std.mem.eql(u8, c.name, "@field")) return inf.anyRuntime(c.args[0..1], depth);
                return .uncertain;
            },
            else => return .uncertain,
        }
    }

    /// Runtime if any of the values is runtime
    fn anyRuntime(inf: *Inferrer, es: []const ExprId, depth: u32) Error!Knownness {
        for (es) |x| if (try inf.knownness(x, depth + 1) == .runtime) return .runtime;
        return .uncertain;
    }

    /// Non-comptime parameters: a function returning a comptime-only type is called at comptime,
    /// so its parameters are all comptime-known; parameters of inline functions depend on the
    /// call site
    fn paramKnownness(inf: *Inferrer) Error!Knownness {
        const it = (try inf.r.itemTree(inf.file)).items[inf.item];
        if (it.kind != .@"fn" or it.flags.is_inline) return .uncertain;
        const ret = inf.ret_type orelse return .uncertain;
        if (ret == .unknown) return .uncertain;
        return if (try eval.isComptimeOnly(inf.r, ret)) .comptime_known else .runtime;
    }

    /// Captures: a capture of a non-inline loop differs in each iteration and is determined at
    /// runtime; captures of if, catch and switch depend on their source (switch looks only at the
    /// payload: the tag capture of an inline prong is comptime-known)
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

    /// `&x`: addresses of local variables and parameters are determined at runtime; addresses of
    /// global declarations are comptime-known
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

    /// Whether the inferred expression `e` depends on an abstract parameter: a parameter of this
    /// member without a settled argument in the instance, a type that is not settled (such as an
    /// abstract type parameter or a type loop variable), or a name of an enclosing scope without a
    /// value outside a settled instance (see `value.isSettled`)
    fn dependsOnAbstract(inf: *Inferrer, e: ExprId, depth: u32) Error!bool {
        if (depth > 8) return true;
        const b = inf.body;
        const tv = inf.get(e);
        if (tv.val) |v| return tv.isType() and !value.isSettled(inf.ip, v);
        switch (b.expr(e)) {
            .name_ref => |name| {
                if (!b.nameRefIsEscaped(e)) if (try primitive(inf.ip, name) != null) return false;
                const def = try inf.r.resolveName(inf.file, inf.item, b, b.expr_scopes[@backingInt(e)], name) orelse return false;
                const l = switch (def) {
                    .local => |l| l,
                    .item, .file => return !inf.concreteContext(),
                };
                if (l.file != inf.file or l.item != inf.item) return !inf.concreteContext();
                const binding = b.binding(l.binding);
                switch (binding.kind) {
                    .param => {
                        const own = inf.ownInstance() orelse return true;
                        const i = std.mem.indexOfScalar(Body.BindingId, b.params, l.binding) orelse return true;
                        return i >= own.args.len or (own.args[i] != .runtime and !value.isSettled(inf.ip, own.args[i]));
                    },
                    .local_const, .local_var => return if (binding.init) |init| inf.dependsOnAbstract(init, depth + 1) else false,
                    .capture => return false,
                }
            },
            .field_access => |fa| return inf.dependsOnAbstract(fa.lhs, depth + 1),
            .call => |c| {
                if (try inf.dependsOnAbstract(c.callee, depth + 1)) return true;
                for (c.args) |x| if (try inf.dependsOnAbstract(x, depth + 1)) return true;
                return false;
            },
            .builtin_call => |c| {
                for (c.args) |x| if (try inf.dependsOnAbstract(x, depth + 1)) return true;
                return false;
            },
            .binary => |x| return try inf.dependsOnAbstract(x.lhs, depth + 1) or try inf.dependsOnAbstract(x.rhs, depth + 1),
            else => return false,
        }
    }

    /// Every parameter of the enclosing instances has a settled argument
    fn concreteContext(inf: *Inferrer) bool {
        const i = inf.inst orelse return false;
        return value.isSettled(inf.ip, i);
    }

    /// Source form of an expression (used to display arrays of unknown length): names, field
    /// accesses, literals, calls and binary operations; false for other forms
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
                // Nested operations get parentheses (HIR does not keep parentheses)
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

    /// `[_]T{ ... }`: the array length is determined by the number of elements. Returns null
    /// when the expression is not in this form.
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

    // ── Type utilities ───────────────────────────────────────────────

    /// Element type iterated by `for`: `elementType`, plus tuples whose fields all have the same
    /// type (the element of `.{ f32, f64 }` is `type`)
    fn forElement(inf: *Inferrer, t: Index) Index {
        const tt = tupleOf(inf.ip, t) orelse return inf.elementType(t);
        if (tt.types.len == 0) return .unknown;
        for (tt.types[1..]) |x| if (x != tt.types[0]) return .unknown;
        return tt.types[0];
    }

    /// Element type of arrays, vectors, slices, many-item pointers and pointers to arrays
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

    /// Slicing (matches the compiler's `analyzeSlice`): a pointer to an array when the length is
    /// comptime-known, a slice otherwise; slicing a many-item pointer without an end is pointer
    /// arithmetic. Slicing up to the end of an array or slice keeps its original sentinel. The
    /// result has the attributes of a pointer to the start element (see `elemPtrAttrs`).
    fn slice(inf: *Inferrer, e: ExprId, lhs_e: ExprId, start_e: ExprId, end_e: ?ExprId, sentinel_e: ?ExprId) Error!TypedValue {
        const ip = inf.ip;
        const lhs = try inf.infer(lhs_e, null);
        const start = try inf.infer(start_e, .usize_type);
        const end: ?TypedValue = if (end_e) |x| try inf.infer(x, .usize_type) else null;
        const Source = struct { elem: Index, sentinel: ?Index = null, len: ?u64 = null, is_const: bool = false, attrs: InternPool.PtrAttrs = .{} };
        const src: Source = switch (ip.key(lhs.ty)) {
            .array_type => |a| .{ .elem = a.child, .sentinel = a.sentinel, .len = a.len, .is_const = try inf.isConstPlace(lhs_e), .attrs = try inf.placeAttrs(lhs_e) },
            .abstract_array_type => |a| .{ .elem = a.child, .sentinel = a.sentinel, .is_const = try inf.isConstPlace(lhs_e), .attrs = try inf.placeAttrs(lhs_e) },
            .ptr_type => |p| switch (p.size) {
                .one => switch (ip.key(p.child)) {
                    .array_type => |a| .{ .elem = a.child, .sentinel = a.sentinel, .len = a.len, .is_const = p.is_const, .attrs = p.attrs },
                    .abstract_array_type => |a| .{ .elem = a.child, .sentinel = a.sentinel, .is_const = p.is_const, .attrs = p.attrs },
                    // A pointer to a single element is sliced as an array of length 1
                    else => .{ .elem = p.child, .len = 1, .is_const = p.is_const, .attrs = p.attrs },
                },
                .slice, .many, .c => .{ .elem = p.child, .sentinel = p.sentinel, .is_const = p.is_const, .attrs = p.attrs },
            },
            else => .{ .elem = .unknown },
        };
        const explicit: ?TypedValue = if (sentinel_e) |x| try inf.infer(x, if (src.elem != .unknown) src.elem else null) else null;
        if (src.elem == .unknown) return .unknown;
        if (end == null and isManyPtr(ip, lhs.ty)) return .{ .ty = try inf.ptrArithmetic(lhs.ty, start) };
        const start_n = std.math.cast(u64, value.intOf(ip, start.val) orelse -1);
        const end_n: ?u64 = if (end) |x| std.math.cast(u64, value.intOf(ip, x.val) orelse -1) else src.len;
        const end_is_len = end == null or (src.len != null and end_n != null and end_n.? == src.len.?);
        const sentinel: ?Index = if (explicit) |x| (x.val orelse return .unknown) else if (end_is_len) src.sentinel else null;
        const attrs = try eval.elemPtrAttrs(inf.r, src.attrs, src.elem, start_n);
        if (start_n != null and end_n != null and end_n.? >= start_n.?) {
            const array = try ip.get(.{ .array_type = .{ .len = end_n.? - start_n.?, .child = src.elem, .sentinel = sentinel } });
            const ty = try ip.get(.{ .ptr_type = .{ .child = array, .size = .one, .is_const = src.is_const, .attrs = attrs } });
            // comptime-known constant and range: the interpreter computes the value of the slice
            if (src.is_const) if (try inf.knownValue(e, lhs.val, ty)) |tv| return tv;
            return .{ .ty = ty };
        }
        return .{ .ty = try ip.get(.{ .ptr_type = .{ .child = src.elem, .size = .slice, .is_const = src.is_const, .sentinel = sentinel, .attrs = attrs } }) };
    }

    /// Type of `ptr + offset` / `ptr - offset` for a many-item or C pointer type `ptr` (the
    /// compiler's `analyzePtrArithmetic`): the same pointer type with the attributes of a pointer
    /// to the element at `offset`
    fn ptrArithmetic(inf: *Inferrer, ptr: Index, offset: TypedValue) Error!Index {
        var p = inf.ip.key(ptr).ptr_type;
        const index = std.math.cast(u64, value.intOf(inf.ip, offset.val) orelse -1);
        p.attrs = try eval.elemPtrAttrs(inf.r, p.attrs, p.child, index);
        return inf.ip.get(.{ .ptr_type = p });
    }

    /// Result type of the right-hand side of an assignment (matches the compiler): `Log2Int(T)`
    /// for `<<=` / `>>=`, none for `<<|=`, and usize for `+=` / `-=` on many-item pointers
    fn assignRhsType(inf: *Inferrer, op: SyntaxKind, lhs: Index) Error!?Index {
        if (lhs == .unknown) return null;
        return switch (op) {
            .angle_bracket_angle_bracket_left_equal, .angle_bracket_angle_bracket_right_equal => try value.log2IntType(inf.ip, lhs),
            .angle_bracket_angle_bracket_left_pipe_equal => null,
            .plus_equal, .minus_equal => if (isManyPtr(inf.ip, lhs)) .usize_type else lhs,
            else => lhs,
        };
    }

    /// `&x`: see `placeIsConst`
    fn isConstPlace(inf: *Inferrer, e: ExprId) Error!bool {
        return placeIsConst(inf.r, inf.file, inf.item, inf.body, inf, e);
    }

    /// Whether place `e` may be inside a container-level declaration: a declaration, a member of
    /// a type, or a field or element reached from one or through a pointer
    fn mayBeInDeclaration(inf: *Inferrer, e: ExprId) Error!bool {
        const b = inf.body;
        return switch (b.expr(e)) {
            .name_ref => |name| {
                if (inf.ip.key(inf.get(e).ty) == .ptr_type) return true;
                const def = try inf.r.resolveName(inf.file, inf.item, b, b.expr_scopes[@backingInt(e)], name) orelse return false;
                return def == .item;
            },
            .field_access => |fa| inf.get(fa.lhs).isType() or try inf.mayBeInDeclaration(fa.lhs),
            .index => |x| inf.mayBeInDeclaration(x.lhs),
            .@"comptime" => |x| inf.mayBeInDeclaration(x),
            .deref => true,
            else => false,
        };
    }

    /// Attributes of a pointer to the place `e` (`&e`, pointer captures): the `align(...)` of a
    /// variable; for a field or an element, those of the pointer or place it is reached through,
    /// adjusted for its offset (the compiler's `fieldPtrType` / `elemPtrType`)
    fn placeAttrs(inf: *Inferrer, e: ExprId) Error!InternPool.PtrAttrs {
        const ip = inf.ip;
        const b = inf.body;
        switch (b.expr(e)) {
            .name_ref => |name| {
                const def = try inf.r.resolveName(inf.file, inf.item, b, b.expr_scopes[@backingInt(e)], name) orelse return .{};
                return inf.defAttrs(def);
            },
            .field_access => |fa| {
                const field = fa.field orelse return .{};
                // A member of a namespace is a declaration
                if (inf.get(fa.lhs).asType()) |t| {
                    const ns = try queries.namespaceOfType(inf.r, t) orelse return .{};
                    return inf.defAttrs(try inf.r.memberDef(ns, field) orelse return .{});
                }
                return inf.fieldPlaceAttrs(fa.lhs, field, inf.get(e).ty);
            },
            .builtin_call => |c| {
                if (!std.mem.eql(u8, c.name, "@field") or c.args.len != 2) return .{};
                const written: ?[]const u8 = switch (b.expr(c.args[1])) {
                    .literal => |text| if (try Body.stringLiteralValue(inf.scratch, text)) |s| s else null,
                    else => null,
                };
                const field = written orelse try eval.stringValue(inf.r, inf.get(c.args[1])) orelse return .{ .alignment = .unknown };
                return inf.fieldPlaceAttrs(c.args[0], field, inf.get(e).ty);
            },
            .index => |x| {
                const lhs = inf.get(x.lhs).ty;
                const index: ?u64 = if (value.intOf(ip, inf.get(x.index).val)) |n| std.math.cast(u64, n) else null;
                // An element of a tuple is a field
                if (tupleOf(ip, lhs) != null) {
                    var buf: [20]u8 = undefined;
                    const name = std.fmt.bufPrint(&buf, "{d}", .{index orelse return .{ .alignment = .unknown }}) catch unreachable;
                    return inf.fieldPlaceAttrs(x.lhs, name, inf.get(e).ty);
                }
                const parent = switch (ip.key(lhs)) {
                    .ptr_type => |p| p.attrs,
                    else => try inf.placeAttrs(x.lhs),
                };
                return eval.elemPtrAttrs(inf.r, parent, inf.get(e).ty, index);
            },
            .deref => |x| return switch (ip.key(inf.get(x).ty)) {
                .ptr_type => |p| p.attrs,
                else => .{},
            },
            // The payload of an optional is at its start
            .unwrap_optional => |x| return inf.placeAttrs(x),
            .binary => |bin| return if (bin.op == .keyword_orelse and inf.get(bin.rhs).ty == .noreturn_type) inf.placeAttrs(bin.lhs) else .{},
            // A pointer to the payload of an error union keeps only the address space
            .@"catch" => |c| return if (inf.get(c.rhs).ty == .noreturn_type) .{ .address_space = (try inf.placeAttrs(c.lhs)).address_space } else .{},
            else => return .{},
        }
    }

    /// `placeAttrs` of the field `name` (of type `field_ty`) of `base`: through a pointer or of
    /// the place `base`
    fn fieldPlaceAttrs(inf: *Inferrer, base: ExprId, name: []const u8, field_ty: Index) Error!InternPool.PtrAttrs {
        const t = inf.get(base).ty;
        const parent: InternPool.PtrAttrs, const agg: Index = switch (inf.ip.key(t)) {
            .ptr_type => |p| if (p.size == .one or p.size == .c) .{ p.attrs, p.child } else .{ try inf.placeAttrs(base), t },
            else => .{ try inf.placeAttrs(base), t },
        };
        if (agg == .unknown) return .{ .alignment = .unknown };
        return eval.fieldPtrAttrs(inf.r, parent, agg, name, field_ty);
    }

    /// Attributes of a pointer to a variable: its `align(...)`
    fn defAttrs(inf: *Inferrer, def: resolve.Def) Error!InternPool.PtrAttrs {
        switch (def) {
            .local => |l| {
                if (l.file != inf.file or l.item != inf.item) {
                    // A local of the outer function: its alignment is inferred there
                    const outer = (try inf.r.body(l.file, l.item)).binding(l.binding);
                    return if (outer.@"align" != null) .{ .alignment = .unknown } else .{};
                }
                const a = inf.body.binding(l.binding).@"align" orelse return .{};
                return .{ .alignment = eval.alignmentOf(inf.ip, (try inf.inferComptime(a, try inf.clauseType(.@"align"))).val) };
            },
            .item => |it| return .{ .alignment = try eval.declAlignment(inf.r, it.file, it.item, inf.inst) },
            .file => return .{},
        }
    }

    /// Type of an inferred subexpression (for `placeIsConst`)
    fn exprType(inf: *Inferrer, e: ExprId) TypedValue {
        return inf.get(e);
    }

    fn unwrapErrorUnion(inf: *Inferrer, t: Index) struct { Index, Index } {
        return switch (inf.ip.key(t)) {
            .error_union_type => |eu| .{ eu.payload, eu.err },
            else => .{ .unknown, .unknown },
        };
    }

    /// Peer type resolution (matches the compiler's strategies for error sets and error unions, C
    /// pointers, numbers, enum literals, optionals, pointers, arrays, vectors and tuples); unknown
    /// when the types cannot be unified
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
            // An error set or error union on either side: the error sets merge and the other
            // types are the payload
            if (isErrorSet(ip, cur) or isErrorSet(ip, t) or ip.key(cur) == .error_union_type or ip.key(t) == .error_union_type) {
                result = try inf.peerErrors(cur, t);
                if (result.? == .unknown) return .unknown;
                continue;
            }
            // A C pointer on either side: the other side is a pointer, an optional pointer or an
            // integer, and the result is a C pointer
            if (isCPtr(ip, cur) or isCPtr(ip, t)) {
                result = try peerCPtr(inf.r, ip, cur, t) orelse return .unknown;
                continue;
            }
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
            // An enum literal with an enum or a tagged union: take the latter
            if (cur == .enum_literal_type and isTagged(ip, t)) {
                result = t;
                continue;
            }
            if (t == .enum_literal_type and isTagged(ip, cur)) continue;
            // Between integers: with the same signedness, take the wider (the former for equal bit
            // widths); a narrower unsigned one is put into the signed one (matches the compiler)
            if (value.peerIntType(ip, cur, t)) |p| {
                result = p;
                continue;
            }
            // Between floats, take the wider one (c_longdouble's bit width depends on the target)
            if (ip.isFloat(cur) and ip.isFloat(t)) {
                const x = value.floatBits(ip, cur) orelse return .unknown;
                const y = value.floatBits(ip, t) orelse return .unknown;
                if (y > x) result = t;
                continue;
            }
            // A fixed-width float with an integer: the float, when every value of the integer
            // type is exact in it (a comptime-known integer value always is, but values are not
            // part of peer resolution here)
            if (ip.isInt(cur) and t != .comptime_float_type and ip.isFloat(t)) {
                if (!intFitsFloat(ip, cur, t)) return .unknown;
                result = t;
                continue;
            }
            if (ip.isInt(t) and cur != .comptime_float_type and ip.isFloat(cur)) {
                if (!intFitsFloat(ip, t, cur)) return .unknown;
                continue;
            }
            // One side is an optional: the peer of the payload and the other side is wrapped back
            // into an optional
            if (ip.key(cur) == .optional_type or ip.key(t) == .optional_type) {
                const p = try inf.peer(&.{ optionalChild(ip, cur), optionalChild(ip, t) });
                if (p == .unknown) return .unknown;
                result = try ip.optionalOf(p);
                continue;
            }
            if (try peerPtr(inf.r, ip, cur, t)) |p| {
                result = p;
                continue;
            }
            if (ip.key(cur) == .tuple_type and ip.key(t) == .tuple_type) {
                result = try inf.peerTuple(cur, t) orelse return .unknown;
                continue;
            }
            if (try inf.peerArrayLike(cur, t)) |p| {
                result = p;
                continue;
            }
            return .unknown;
        }
        // Only noreturn and undefined peers: they must all be the same type
        const t = result orelse return if (has_null) .null_type else if (types.len == 0) .void_type else if (allEqual(types)) types[0] else .unknown;
        if (has_null) switch (ip.key(t)) {
            .optional_type => {},
            // A C pointer can already hold null
            .ptr_type => |p| if (p.size != .c) return ip.optionalOf(t),
            // The null goes into the payload of an error union
            .error_union_type => |eu| return ip.get(.{ .error_union_type = .{ .err = eu.err, .payload = try inf.peer(&.{ eu.payload, .null_type }) } }),
            else => return if (isErrorSet(ip, t)) ip.get(.{ .error_union_type = .{ .err = t, .payload = .null_type } }) else ip.optionalOf(t),
        };
        return t;
    }

    /// Peer of two tuples (matches the compiler's `tuple` strategy): field by field, and a comptime
    /// field stays one only when both tuples hold the same value in it; null when the number of
    /// fields differs or a field has no peer
    fn peerTuple(inf: *Inferrer, a: Index, b: Index) Error!?Index {
        const x = inf.ip.key(a).tuple_type;
        const y = inf.ip.key(b).tuple_type;
        if (x.types.len != y.types.len) return null;
        const types = try inf.scratch.alloc(Index, x.types.len);
        const values = try inf.scratch.alloc(Index, x.types.len);
        for (types, values, 0..) |*ty, *v, i| {
            ty.* = try inf.peer(&.{ x.types[i], y.types[i] });
            if (ty.* == .unknown) return null;
            const value_x = InternPool.fieldValue(x.values, i);
            v.* = if (value_x == InternPool.fieldValue(y.values, i)) value_x else .runtime;
        }
        return try inf.ip.get(.{ .tuple_type = .{ .types = types, .values = InternPool.fieldValues(values) } });
    }

    /// Peer of two types where at least one is an error set or an error union (matches the
    /// compiler's `error_set` / `error_union` strategies): the error sets merge, the payloads
    /// (and the types that are neither) resolve as peers
    fn peerErrors(inf: *Inferrer, a: Index, b: Index) Error!Index {
        const ip = inf.ip;
        const set_a, const payload_a = splitErrors(ip, a);
        const set_b, const payload_b = splitErrors(ip, b);
        const set = if (set_a) |x| (if (set_b) |y| try inf.mergeErrorSets(x, y) else x) else set_b.?;
        if (set == .unknown) return .unknown;
        const payload = if (payload_a) |x| (if (payload_b) |y| try inf.peer(&.{ x, y }) else x) else payload_b orelse return set;
        if (payload == .unknown) return .unknown;
        return ip.get(.{ .error_union_type = .{ .err = set, .payload = payload } });
    }

    /// Error set and payload of a peer: an error set has no payload, an error union both, and any
    /// other type is a payload
    fn splitErrors(ip: *InternPool, t: Index) struct { ?Index, ?Index } {
        if (isErrorSet(ip, t)) return .{ t, null };
        return switch (ip.key(t)) {
            .error_union_type => |eu| .{ eu.err, eu.payload },
            else => .{ null, t },
        };
    }

    /// Merge of two error sets (matches the compiler's `maybeMergeErrorSets`): a set that holds
    /// the other is the result as is, otherwise the union of the members; unknown when the
    /// members cannot be computed
    fn mergeErrorSets(inf: *Inferrer, a: Index, b: Index) Error!Index {
        if (a == b or a == .anyerror_type) return a;
        if (b == .anyerror_type) return b;
        const x = try queries.errorSetMembers(inf.r, a) orelse return .unknown;
        const y = try queries.errorSetMembers(inf.r, b) orelse return .unknown;
        if (isSubset(y, x)) return a;
        if (isSubset(x, y)) return b;
        return inf.ip.errorSet(inf.scratch, try std.mem.concat(inf.scratch, []const u8, &.{ x, y }));
    }

    fn isSubset(sub: []const []const u8, set: []const []const u8) bool {
        outer: for (sub) |name| {
            for (set) |n| if (std.mem.eql(u8, n, name)) continue :outer;
            return false;
        }
        return true;
    }

    /// Peer of two types where at least one is an array or a vector (matches the compiler's
    /// `array` / `vector` strategies): the lengths must agree; with a vector, the element types
    /// resolve as peers into a vector; between arrays, the element types must be the same and
    /// the sentinel is kept when both have it; a tuple of the same length takes the element type
    /// of the other side. Null when they cannot be unified.
    fn peerArrayLike(inf: *Inferrer, a: Index, b: Index) Error!?Index {
        const ip = inf.ip;
        const x = arrayLike(ip, a) orelse return null;
        const y = arrayLike(ip, b) orelse return null;
        if ((x.kind == .tuple and y.kind == .tuple) or x.len != y.len) return null;
        if (x.kind == .vector or y.kind == .vector) {
            const child = if (x.child) |cx| (if (y.child) |cy| try inf.peer(&.{ cx, cy }) else cx) else y.child.?;
            if (child == .unknown) return null;
            return try ip.get(.{ .vector_type = .{ .len = @intCast(x.len), .child = child } });
        }
        const child = if (x.child) |cx| (if (y.child) |cy| (if (cx == cy) cx else return null) else cx) else y.child.?;
        const sentinel: ?Index = if (x.sentinel != null and y.sentinel != null and x.sentinel.? == y.sentinel.?) x.sentinel else null;
        return try ip.get(.{ .array_type = .{ .len = x.len, .child = child, .sentinel = sentinel } });
    }

    const ArrayLike = struct { kind: enum { array, vector, tuple }, len: u64, child: ?Index, sentinel: ?Index = null };

    fn arrayLike(ip: *InternPool, t: Index) ?ArrayLike {
        return switch (ip.key(t)) {
            .array_type => |arr| .{ .kind = .array, .len = arr.len, .child = arr.child, .sentinel = arr.sentinel },
            .vector_type => |v| .{ .kind = .vector, .len = v.len, .child = v.child },
            .tuple_type => |tt| .{ .kind = .tuple, .len = tt.types.len, .child = null },
            else => null,
        };
    }

    /// Types an enum literal can coerce to: enums and unions
    fn isTagged(ip: *InternPool, t: Index) bool {
        if (value.isEnumType(ip, t)) return true;
        return switch (ip.key(t)) {
            .container_type => |c| c.kind == .@"union",
            .reified_type => |rt| rt.kind == .@"union",
            else => false,
        };
    }

    fn allEqual(types: []const Index) bool {
        for (types[1..]) |t| if (t != types[0]) return false;
        return true;
    }

    fn containerAt(inf: *Inferrer, e: ExprId) Error!?Namespace {
        return inf.r.containerAt(inf.file, inf.item, inf.body.range(e).start);
    }
};

pub const FnType = @FieldType(InternPool.Key, "fn_type");

/// Value of a container's declaration: var and extern declarations are read at runtime, and the
/// rest (const, functions) are comptime-known
fn declKnownness(it: ItemTree.Item) Inferrer.Knownness {
    return if (it.kind == .@"var" or it.flags.is_extern) .runtime else .comptime_known;
}

fn contains(list: []const Body.BindingId, b: Body.BindingId) bool {
    return std.mem.indexOfScalar(Body.BindingId, list, b) != null;
}

/// Result expressions of the branches of `if` / `switch` (including nested ones)
/// Possible values (container types) of the declaration `owner` across build configurations: when
/// the initializer is an `if` / `switch` selected by a comptime condition, take each branch; when
/// a branch or the initializer itself is an alias (`linux`, `std.c`, `system.SO`), follow the
/// alias. Used for members that do not exist in the current configuration.
fn alternativeContainers(r: *Resolver, a: Allocator, owner: hir.OwnerKey, out: *std.ArrayList(Index), depth: u32) Error!void {
    if (depth > max_alternative_depth) return;
    const item = try itemOfKey(r, owner) orelse return;
    const body = try r.ctx.get(hir.ItemBody, owner);
    const init = body.value orelse return;
    const res = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full });
    if (res.exprs.len != body.exprs.len) return;
    var leaves: std.ArrayList(ExprId) = .empty;
    try branchLeaves(a, body, init, &leaves, 0);
    for (leaves.items) |leaf| try leafAlternatives(r, a, owner.file, item, body, res.exprs, leaf, out, depth);
}

/// Possible values (container types) of the declaration `def` across build configurations (see
/// `alternativeContainers`), the current one included: e.g. both files for
/// `const Impl = if (builtin.os.tag == .windows) @import("win.zig") else @import("posix.zig")`
pub fn declAlternatives(r: *Resolver, a: Allocator, def: resolve.Def) Error![]const Index {
    const key = try defKey(r, def) orelse return &.{};
    var out: std.ArrayList(Index) = .empty;
    try alternativeContainers(r, a, key, &out, 0);
    return out.items;
}

/// The member that a member `name` of the constructed type `rt` is named after, when the member
/// that constructs it takes the names from `@typeInfo(X)` (`std.meta.FieldEnum(T)` builds its tags
/// from `@typeInfo(T)`): the member of X with the same name (the first `@typeInfo` argument that
/// has one)
pub fn typeInfoMember(r: *Resolver, rt: InternPool.Reified, name: []const u8) Error!?resolve.Def {
    const tree = try r.itemTree(rt.file);
    const owner_item: u32 = for (tree.items, 0..) |it, i| {
        if (it.ast_id == rt.owner) break @intCast(i);
    } else return null;
    const owner = try r.ownerKey(rt.file, owner_item);
    const body = try r.ctx.get(hir.ItemBody, owner);
    const res = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full, .inst = rt.inst });
    if (res.exprs.len != body.exprs.len) return null;
    for (body.exprs) |x| switch (x) {
        .builtin_call => |call| {
            if (!std.mem.eql(u8, call.name, "@typeInfo") or call.args.len != 1) continue;
            const t = res.exprs[@backingInt(call.args[0])].asType() orelse continue;
            const ns = try queries.namespaceOfType(r, t) orelse continue;
            const f = fieldItem(try r.itemTree(ns.file), ns.container, name) orelse continue;
            return .{ .item = .{ .file = ns.file, .item = f } };
        },
        else => {},
    };
    return null;
}

/// Maximum depth along alias and inference chains when looking up candidates in other
/// configurations: mutually referencing declarations would not terminate
const max_alternative_depth = 16;

/// Possible values (container types) of the expression `e` across build configurations: the
/// current value, and the values of the declaration it references in other configurations
fn leafAlternatives(r: *Resolver, a: Allocator, file: FileId, item: u32, body: *const Body, exprs: []const TypedValue, e: ExprId, out: *std.ArrayList(Index), depth: u32) Error!void {
    if (depth > max_alternative_depth) return;
    const ip = r.ctx.db.env.ip;
    if (@backingInt(e) < exprs.len) if (exprs[@backingInt(e)].asType()) |t| if (ip.key(t) == .container_type) try appendUnique(a, out, t);
    switch (body.expr(e)) {
        .name_ref => |n| {
            const def = try r.resolveName(file, item, body, body.expr_scopes[@backingInt(e)], n) orelse return;
            const key = try defKey(r, def) orelse return;
            try alternativeContainers(r, a, key, out, depth + 1);
        },
        // `X.Name`: `Name` in each possible container of X
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

/// Whether the place `e` cannot be modified, which makes `&e` a `*const T` (matches the compiler):
/// declarations other than `var`s (functions included) and locals other than `var`s (parameters
/// and captures included), members and elements of such places, and those reached through a const
/// pointer; expressions that are not places (calls, literals, and so on) are temporaries that
/// cannot be modified. `types` gives the types of the subexpressions (`types.exprType(e)`)
pub fn placeIsConst(r: *Resolver, file: FileId, item: u32, b: *const Body, types: anytype, e: ExprId) Error!bool {
    switch (b.expr(e)) {
        .name_ref => |name| {
            const def = try r.resolveName(file, item, b, b.expr_scopes[@backingInt(e)], name) orelse return false;
            return switch (def) {
                // A local of the outer function (referenced in a member of a container in the body)
                // is in the Body of the member it belongs to
                .local => |l| (if (l.file == file and l.item == item) b else try r.body(l.file, l.item)).binding(l.binding).kind != .local_var,
                .item => |it| (try r.itemTree(it.file)).items[it.item].kind != .@"var",
                .file => true,
            };
        },
        .field_access => |fa| {
            // A member of a namespace (`State.counter`, `other.global`) is a declaration: its own
            // `var` / `const` decides
            if (types.exprType(fa.lhs).asType()) |t| {
                const ns = try queries.namespaceOfType(r, t) orelse return true;
                const def = try r.memberDef(ns, fa.field orelse return true) orelse return true;
                return switch (def) {
                    .item => |it| (try r.itemTree(it.file)).items[it.item].kind != .@"var",
                    else => true,
                };
            }
            return partIsConst(r, file, item, b, types, fa.lhs);
        },
        // `@field(x, name)` is a member of `x`, as `x.name` is
        .builtin_call => |c| return if (std.mem.eql(u8, c.name, "@field") and c.args.len == 2) partIsConst(r, file, item, b, types, c.args[0]) else true,
        .index => |x| return partIsConst(r, file, item, b, types, x.lhs),
        .deref => |x| return switch (r.ctx.db.env.ip.key(types.exprType(x).ty)) {
            .ptr_type => |p| p.is_const,
            else => false,
        },
        // The payload of an optional is part of the optional
        .unwrap_optional => |x| return placeIsConst(r, file, item, b, types, x),
        // `x orelse return` / `x catch return` with a noreturn right-hand side points into the
        // payload of `x`
        .binary => |bin| return if (bin.op == .keyword_orelse and types.exprType(bin.rhs).ty == .noreturn_type) placeIsConst(r, file, item, b, types, bin.lhs) else true,
        .@"catch" => |c| return if (types.exprType(c.rhs).ty == .noreturn_type) placeIsConst(r, file, item, b, types, c.lhs) else true,
        else => return true,
    }
}

/// A member or element of `base`: through a pointer it depends on the pointer, otherwise on `base`
fn partIsConst(r: *Resolver, file: FileId, item: u32, b: *const Body, types: anytype, base: ExprId) Error!bool {
    return switch (r.ctx.db.env.ip.key(types.exprType(base).ty)) {
        .ptr_type => |p| p.is_const,
        else => placeIsConst(r, file, item, b, types, base),
    };
}

/// Expressions in an owner and their inference results
const ExprCtx = struct {
    file: FileId,
    /// Index into `ItemTree.items`
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

/// Possible types (container types) of the value of the expression `e` across build
/// configurations: the current type; the type annotation or initializer of locals and parameters;
/// the type annotation or initializer of global variables; the return type of calls (`X.Y.init()`
/// also takes `X.Y`); for field access, the types of the fields with the same name in each
/// possible type of the left-hand side
fn valueAlternatives(r: *Resolver, a: Allocator, c: ExprCtx, e: ExprId, out: *std.ArrayList(Index), depth: u32) Error!void {
    if (depth > max_alternative_depth) return;
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
            // For a constructor returning `@This()`, `X.Y` gives its type in other configurations
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

/// Possible container types of a type expression across build configurations; for optionals,
/// error unions and pointers, the type inside is taken. The alias chain of types and the
/// inference chain of values are depth-limited separately: after a value goes through several
/// variables and calls, its type may still have several levels of aliases.
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
    if (std.mem.indexOfScalar(Index, out.items, t) == null) try out.append(a, t);
}

/// Index of the item in `ItemTree.items` whose AST id is `key.item`
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

/// Pointer cast builtins (when nested, the compiler merges them into one cast)
fn isPtrCast(name: []const u8) bool {
    for ([_][]const u8{ "@ptrCast", "@alignCast", "@addrSpaceCast", "@constCast", "@volatileCast" }) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// Whether `@constCast` / `@volatileCast` applied to `operand` is merged with a cast below it that
/// takes the result type (`@constCast(@ptrCast(p))`, `@volatileCast(@constCast(@alignCast(p)))`,
/// `@constCast(@fieldParentPtr(...))`): the compiler's AstGen then emits one cast whose
/// destination is the result type (`ptr_cast_full`, `field_parent_ptr`). Below a chain of only
/// `@constCast` / `@volatileCast`, it emits `ptr_cast_no_dest`, whose destination comes from the
/// operand (see `qualifierCastDest`). Parentheses, which the compiler looks through, are not in HIR.
pub fn qualifierCastTakesResultType(body: *const Body, operand: ExprId) bool {
    var e = operand;
    while (true) {
        const c = switch (body.expr(e)) {
            .builtin_call => |c| c,
            else => return false,
        };
        if (std.mem.eql(u8, c.name, "@fieldParentPtr")) return c.args.len == 2;
        if (!isPtrCast(c.name) or c.args.len != 1) return false;
        if (!std.mem.eql(u8, c.name, "@constCast") and !std.mem.eql(u8, c.name, "@volatileCast")) return true;
        e = c.args[0];
    }
}

/// Destination type of `@constCast` / `@volatileCast` on an operand of type `t` that does not take
/// the result type (the compiler's `zirPtrCastNoDest`): `t` with `const` or `volatile` cleared, an
/// optional pointer staying optional. Null when `t` is not a pointer or an optional pointer.
pub fn qualifierCastDest(ip: *InternPool, t: Index, name: []const u8) Allocator.Error!?Index {
    switch (ip.key(t)) {
        .ptr_type => |p| {
            var q = p;
            if (std.mem.eql(u8, name, "@constCast")) q.is_const = false else q.attrs.is_volatile = false;
            return try ip.get(.{ .ptr_type = q });
        },
        .optional_type => |c| if (ip.key(c) == .ptr_type) return try ip.optionalOf((try qualifierCastDest(ip, c, name)).?),
        else => {},
    }
    return null;
}

/// Builtins whose operand has the float in the result type as its result type: the unary float
/// math builtins and the rounding builtins
fn isFloatMath(name: []const u8) bool {
    if (isRounding(name)) return true;
    for ([_][]const u8{ "@sqrt", "@sin", "@cos", "@tan", "@exp", "@exp2", "@log", "@log2", "@log10" }) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// `@floor` / `@ceil` / `@trunc` / `@round`, whose result type converts the rounded value (see
/// `Inferrer.roundCast`)
fn isRounding(name: []const u8) bool {
    for ([_][]const u8{ "@floor", "@ceil", "@trunc", "@round" }) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

fn isErrorSet(ip: *InternPool, t: Index) bool {
    return switch (ip.key(t)) {
        .error_set_type, .inferred_error_set => true,
        .simple_type => |s| s == .anyerror,
        else => false,
    };
}

fn isCPtr(ip: *InternPool, t: Index) bool {
    return switch (ip.key(t)) {
        .ptr_type => |p| p.size == .c,
        else => false,
    };
}

/// Peer of two types where at least one is a C pointer (matches the compiler's `c_ptr`
/// strategy): integers coerce to the C pointer; pointers and optional pointers must have the
/// same element type; const if either side is const, the sentinel is kept only when both sides
/// have the same one, and the attributes join as in `peerPtrAttrs`. Null when they cannot be
/// unified.
fn peerCPtr(r: *Resolver, ip: *InternPool, a: Index, b: Index) Error!?Index {
    if (ip.isInt(a)) return if (isCPtr(ip, b)) b else null;
    if (ip.isInt(b)) return if (isCPtr(ip, a)) a else null;
    const x = runtimePtr(ip, a) orelse return null;
    const y = runtimePtr(ip, b) orelse return null;
    if (x.child != y.child) return null;
    const sentinel: ?Index = if (x.sentinel != null and y.sentinel != null and x.sentinel.? == y.sentinel.?) x.sentinel else null;
    const attrs = try peerPtrAttrs(r, x, y) orelse return null;
    return try ip.get(.{ .ptr_type = .{ .child = x.child, .size = .c, .is_const = x.is_const or y.is_const, .sentinel = sentinel, .attrs = attrs } });
}

/// Attributes of the peer of the pointers `x` and `y` (the compiler's `c_ptr` and `ptr`
/// strategies): the lower of the two alignments, explicit unless neither side has an explicit
/// one, and volatile and allowzero when either side is. Null when the address spaces or the bit
/// ranges differ.
fn peerPtrAttrs(r: *Resolver, x: InternPool.PtrType, y: InternPool.PtrType) Error!?InternPool.PtrAttrs {
    const a = x.attrs;
    const b = y.attrs;
    if (a.host_size != b.host_size or a.bit_offset != b.bit_offset) return null;
    var out = a;
    if (a.address_space == null or b.address_space == null) {
        out.address_space = null;
    } else if (a.address_space.? != b.address_space.?) return null;
    out.is_volatile = a.is_volatile or b.is_volatile;
    out.is_allowzero = a.is_allowzero or b.is_allowzero;
    if (a.alignment == .natural and b.alignment == .natural) return out;
    const x_align = try ptrAlignment(r, x);
    const y_align = try ptrAlignment(r, y);
    out.alignment = if (x_align != null and y_align != null) .fromBytes(@min(x_align.?, y_align.?)) else .unknown;
    return out;
}

/// Alignment in bytes of the address of a pointer: the explicit one, or that of its child;
/// null when not known
fn ptrAlignment(r: *Resolver, p: InternPool.PtrType) Error!?u64 {
    if (p.attrs.alignment != .natural) return p.attrs.alignment.bytes();
    return if (try eval.typeLayout(r, p.child)) |l| l.alignment else null;
}

/// The pointer type of a pointer or of an optional pointer
fn runtimePtr(ip: *InternPool, t: Index) ?@FieldType(InternPool.Key, "ptr_type") {
    return switch (ip.key(optionalChild(ip, t))) {
        .ptr_type => |p| p,
        else => null,
    };
}

/// Whether every value of the integer type `int` is exact in the float type `float` (the
/// compiler's peer resolution check for runtime integers)
fn intFitsFloat(ip: *InternPool, int: Index, float: Index) bool {
    const info = value.intInfo(ip, int) orelse return false;
    const significand: u16 = switch (value.floatBits(ip, float) orelse return false) {
        16 => 11,
        32 => 24,
        64 => 53,
        80 => 64,
        128 => 113,
        else => return false,
    };
    return info.bits - @intFromBool(info.signed) <= significand;
}

fn optionalChild(ip: *InternPool, t: Index) Index {
    return switch (ip.key(t)) {
        .optional_type => |c| c,
        else => t,
    };
}

/// Peer of two pointers (matches the compiler): the element types must be the same; a single-item
/// pointer to an array unifies with a slice or many-item pointer into the latter, and array
/// pointers of different lengths unify into a slice; const if either side is const, the
/// sentinel is kept only when both sides have the same one, and the attributes join as in
/// `peerPtrAttrs`. null when they cannot be unified.
fn peerPtr(r: *Resolver, ip: *InternPool, a: Index, b: Index) Error!?Index {
    const x = switch (ip.key(a)) {
        .ptr_type => |p| p,
        else => return null,
    };
    const y = switch (ip.key(b)) {
        .ptr_type => |p| p,
        else => return null,
    };
    if (try tupleAsArray(ip, x, y)) |p| return peerPtr(r, ip, p, b);
    if (try tupleAsArray(ip, y, x)) |p| return peerPtr(r, ip, a, p);
    const xa: ?@FieldType(InternPool.Key, "array_type") = if (x.size == .one) switch (ip.key(x.child)) {
        .array_type => |arr| arr,
        else => null,
    } else null;
    const ya: ?@FieldType(InternPool.Key, "array_type") = if (y.size == .one) switch (ip.key(y.child)) {
        .array_type => |arr| arr,
        else => null,
    } else null;
    const is_const = x.is_const or y.is_const;
    const attrs = try peerPtrAttrs(r, x, y) orelse return null;
    // A single-item pointer to a non-array only unifies with the same single-item pointer type
    if ((x.size == .one and xa == null) or (y.size == .one and ya == null)) {
        if (x.size != y.size or x.child != y.child) return null;
        return try ip.get(.{ .ptr_type = .{ .child = x.child, .size = .one, .is_const = is_const, .attrs = attrs } });
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
            return try ip.get(.{ .ptr_type = .{ .child = arr, .size = .one, .is_const = is_const, .attrs = attrs } });
        }
        return try ip.get(.{ .ptr_type = .{ .child = x_elem, .size = .slice, .is_const = is_const, .sentinel = sentinel, .attrs = attrs } });
    }
    const size: InternPool.PtrSize = if (xa != null) y.size else if (ya != null) x.size else if (x.size == y.size) x.size else return null;
    return try ip.get(.{ .ptr_type = .{ .child = x_elem, .size = size, .is_const = is_const, .sentinel = sentinel, .attrs = attrs } });
}

/// The pointer to an array corresponding to the single-item pointer to a tuple `p` (`&.{}`,
/// `&.{ a, b }`) when all its items have the element type of the pointer `other` (or it has no
/// items): treated as an array in peer type resolution with slices and pointers to arrays
/// (`else => &.{}`)
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
    return try singlePtr(ip, arr, p.is_const, p.attrs);
}

/// `*T` with the given constness and attributes; unknown when `T` is
fn singlePtr(ip: *InternPool, child: Index, is_const: bool, attrs: InternPool.PtrAttrs) Allocator.Error!Index {
    if (child == .unknown) return .unknown;
    return ip.get(.{ .ptr_type = .{ .child = child, .size = .one, .is_const = is_const, .attrs = attrs } });
}

/// Pointers that support pointer arithmetic (many-item pointers and C pointers)
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

/// One side of `++`: an array, a pointer to an array, or a tuple when the other side is indexable
/// (taking the element type of the other side)
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

/// Tuple types (including single-item pointers to tuples)
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

/// Value of the comptime field named `name` in tuple and anonymous struct types
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

/// `comptime_anytype` (`comptime x: anytype`, or any anytype parameter of a function returning a
/// comptime-only type) records the argument value in the instance, and its type in
/// `InternPool.Instance.arg_types`; `anytype_type` records the argument type
pub const ParamKind = enum { runtime, comptime_value, comptime_anytype, anytype_type };

/// A callee that needs instantiation: it has comptime parameters (including implicit ones of
/// comptime-only types) or anytype parameters, or returns a comptime-only type (e.g. `type`, in
/// which case the call executes at comptime and the values of all arguments, anytype ones
/// included, take part in the instance)
pub const Generic = struct {
    owner: hir.OwnerKey,
    body: *const Body,
    parent: ?Index,
    kinds: []const ParamKind,
    /// The call executes at comptime because the callee is not inline and returns a comptime-only
    /// type: as in the compiler, all arguments are evaluated in a comptime scope
    comptime_call: bool = false,

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
    // Look only at the parameter forms first: non-generic calls (the vast majority) do not depend
    // on the callee's body
    const forms = try r.ctx.get(hir.ParamForms, owner);
    const all_comptime = try eval.isComptimeOnly(r, f.ret);
    const kinds = try scratch.alloc(ParamKind, forms.len);
    var generic = all_comptime;
    for (forms, kinds, 0..) |form, *k, i| {
        k.* = switch (form) {
            // A call that executes at comptime is memoized by the argument values in the compiler
            // (`analyzeCall`), so an anytype argument takes part in the instance by its value
            .any => if (all_comptime) .comptime_anytype else .anytype_type,
            .comptime_any => .comptime_anytype,
            .typed, .comptime_typed => if (all_comptime or form == .comptime_typed or (i < f.params.len and value.isComptimeOnly(ip, f.params[i])))
                .comptime_value
            else
                .runtime,
        };
        if (k.* != .runtime) generic = true;
    }
    if (!generic) return null;
    return .{ .owner = owner, .body = try r.ctx.get(hir.ItemBody, owner), .parent = fv.inst, .kinds = kinds, .comptime_call = all_comptime and f.cc != .@"inline" };
}

/// Instance of a call (`args` is parallel to the parameters). comptime arguments are coerced to
/// the parameter types: when a parameter type depends on other parameters (`comptime n: T`), an
/// instance is first built with the uncoerced arguments to evaluate the parameter types, then
/// the arguments are coerced, so `Box(u8, 3)` and `Box(u8, @as(u8, 3))` are the same instance.
pub fn instanceOf(r: *Resolver, scratch: Allocator, g: Generic, f: FnType, args: []const TypedValue) Error!Index {
    const ip = r.ctx.db.env.ip;
    const inst_args = try scratch.alloc(Index, g.body.params.len);
    const arg_types: []Index = for (g.kinds) |k| {
        if (k == .comptime_anytype) break try scratch.alloc(Index, inst_args.len);
    } else &.{};
    @memset(arg_types, .runtime);
    var dependent = false;
    for (inst_args, 0..) |*out, i| {
        const tv: TypedValue = if (i < args.len) args[i] else .unknown;
        switch (g.kinds[i]) {
            .runtime => out.* = .runtime,
            .anytype_type => out.* = tv.ty,
            // As in the compiler, the argument is a value of its type: values of different types
            // can have the same representation (`@as(?u8, 3)` and `@as(u8, 3)`)
            .comptime_anytype => {
                out.* = tv.val orelse .unknown;
                arg_types[i] = tv.ty;
            },
            .comptime_value => {
                out.* = tv.val orelse .unknown;
                if (out.* == .unknown) continue;
                const pt = paramType(f, i) orelse .unknown;
                if (value.isConcrete(ip, pt)) {
                    out.* = (try value.coerceValueFrom(ip, out.*, tv.ty, pt)) orelse .unknown;
                } else dependent = true;
            },
        }
    }
    var inst = try ip.get(.{ .instance = .{ .file = g.owner.file, .decl = g.owner.item, .args = inst_args, .arg_types = arg_types, .parent = g.parent } });
    if (!dependent) return inst;
    const sig = try r.ctx.get(queries.Infer, .{ .owner = g.owner, .mode = .signature, .inst = inst });
    var changed = false;
    for (inst_args, 0..) |*out, i| {
        if (g.kinds[i] != .comptime_value or out.* == .unknown or value.isConcrete(ip, paramType(f, i) orelse .unknown)) continue;
        const pt = instParamType(sig, g.body, i) orelse continue;
        const coerced = (try value.coerceValueFrom(ip, out.*, if (i < args.len) args[i].ty else .unknown, pt)) orelse .unknown;
        if (coerced != out.*) {
            out.* = coerced;
            changed = true;
        }
    }
    if (changed) inst = try ip.get(.{ .instance = .{ .file = g.owner.file, .decl = g.owner.item, .args = inst_args, .arg_types = arg_types, .parent = g.parent } });
    return inst;
}

/// When the instance is used for the member `owner` it belongs to: an instance with an iteration
/// (see `InternPool.Instance.iteration`) is split into the outer instance and the loop seed;
/// other instances are returned as is. An undetermined iteration gives a seed with
/// `unknown_index` (see `LoopSeed`).
fn splitIteration(ip: *InternPool, owner: hir.OwnerKey, inst: ?Index) Error!struct { inst: ?Index, seed: ?LoopSeed } {
    const i = inst orelse return .{ .inst = null, .seed = null };
    const key = switch (ip.key(i)) {
        .instance => |x| x,
        else => return .{ .inst = i, .seed = null },
    };
    const it = key.iteration orelse return .{ .inst = i, .seed = null };
    if (key.file != owner.file or key.decl != owner.item) return .{ .inst = i, .seed = null };
    const seed: LoopSeed = .{ .binding = it.binding, .index = it.index };
    if (it.abstract) return .{ .inst = key.parent, .seed = seed };
    var base = key;
    base.iteration = null;
    return .{ .inst = try ip.get(.{ .instance = base }), .seed = seed };
}

/// Region of a loop seed's loop variable: a `for` loop body or an `inline` switch prong body
fn seedRegion(body: *const Body, binding: u32) ?Body.Range {
    for (body.exprs) |x| switch (x) {
        .loop => |l| for (l.capture) |c| if (@backingInt(c) == binding) return body.range(l.body),
        .@"switch" => |sw| for (sw.prongs) |p| if (p.capture.len > 0 and @backingInt(p.capture[0]) == binding) return body.range(p.body),
        else => {},
    };
    return null;
}

/// Whether all arguments of a call are known at comptime
fn allKnown(args: []const TypedValue) bool {
    for (args) |a| if (a.val == null) return false;
    return true;
}

pub fn runtimeInstance(ip: *InternPool, scratch: Allocator, fv: @FieldType(InternPool.Key, "fn_value"), n: usize) Error!Index {
    const args = try scratch.alloc(Index, n);
    @memset(args, .runtime);
    return ip.get(.{ .instance = .{ .file = fv.file, .decl = fv.decl, .args = args, .parent = fv.inst } });
}

/// Compares two numbers
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

/// Ignoring noreturn branches: the value when all branches have the same value. Branches that
/// are pointer types differing only in their alignment (`if (alignment) |a| []align(a) T else
/// []T` with an undetermined condition) give that pointer type with an unknown alignment.
fn sameLiveValue(ip: *InternPool, values: []const TypedValue, ty: Index) Allocator.Error!?Index {
    var v: ?Index = null;
    var differ = false;
    for (values) |x| {
        if (x.ty == .noreturn_type) continue;
        if (x.ty != ty) return null;
        const xv = x.val orelse return null;
        if (v) |y| {
            if (y != xv) differ = true;
        } else v = xv;
    }
    if (!differ) return v;
    if (ty != .type_type) return null;
    var joined: ?InternPool.PtrType = null;
    for (values) |x| {
        if (x.ty == .noreturn_type) continue;
        const p = switch (ip.key(x.val.?)) {
            .ptr_type => |p| p,
            else => return null,
        };
        const j = &(joined orelse {
            joined = p;
            continue;
        });
        var same = p;
        same.attrs.alignment = j.attrs.alignment;
        if (!deepEql(same, j.*)) return null;
        if (p.attrs.alignment != j.attrs.alignment) j.attrs.alignment = .unknown;
    }
    return try ip.get(.{ .ptr_type = joined.? });
}

/// The value when all breaks have the same value (and its type is the merged type)
fn sameValue(values: []const TypedValue, ty: Index) ?Index {
    if (values.len == 0) return null;
    const v = values[0].val orelse return null;
    for (values) |x| if (x.ty != ty or x.val != v) return null;
    return v;
}

fn boolValue(b: bool) TypedValue {
    return .{ .ty = .bool_type, .val = if (b) .true_value else .false_value };
}

/// Type of the `i`-th parameter in the signature (null when unknown)
fn paramType(f: @FieldType(InternPool.Key, "fn_type"), i: usize) ?Index {
    return if (i < f.params.len and f.params[i] != .unknown) f.params[i] else null;
}

/// Type of the `i`-th parameter in the signature inference result of an instance
fn instParamType(sig: *const Result, body: *const Body, i: usize) ?Index {
    if (i >= body.params.len) return null;
    const b = @backingInt(body.params[i]);
    if (b >= sig.bindings.len or sig.bindings[b].ty == .unknown) return null;
    return sig.bindings[b].ty;
}

fn typeUnknown() TypedValue {
    return .{ .ty = .type_type };
}

/// `@hasDecl` (counting only pub declarations) / `@hasField`; tuples, anonymous structs and
/// constructed types have no declarations, and their field names are in the type; slices have
/// the fields `ptr` and `len`, arrays `len`, and the `_` of a non-exhaustive enum is not a field;
/// null for other types that are not containers in source code
fn hasMember(r: *Resolver, t: Index, name: []const u8, decl: bool) Error!?bool {
    const ip = r.ctx.db.env.ip;
    switch (ip.key(t)) {
        .tuple_type => |tt| {
            if (decl) return false;
            const i = std.fmt.parseInt(usize, name, 10) catch return false;
            return i < tt.types.len;
        },
        .anon_struct_type => |s| return !decl and hasName(s.names, name),
        .reified_type => |rt| return !decl and hasName(rt.names, name),
        else => if (!decl) if (value.sliceArrayHasField(ip, t, name)) |has| return has,
    }
    const ns = try queries.namespaceOfType(r, t) orelse return null;
    const tree = try r.itemTree(ns.file);
    if (!decl) return !(value.isEnumType(ip, t) and std.mem.eql(u8, name, "_")) and fieldItem(tree, ns.container, name) != null;
    const m = Resolver.lookupDecl(tree, ns.container, name) orelse return false;
    return tree.items[m].flags.is_pub;
}

/// The bounds of a switch prong item of the form `a...b`
fn switchRange(body: *const Body, item: ExprId) ?[2]ExprId {
    return switch (body.expr(item)) {
        .other => |range| if (range.len == 2) range[0..2].* else null,
        else => null,
    };
}

/// Values of an `inline` prong (for operands that are not unions or error sets): the items are
/// expanded in order, and a range `a...b` one integer at a time. `count` is the number of values
/// and `value` is the `want`-th one; `count` is null when an item cannot be evaluated or for an
/// `else` prong.
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
                // The bounds are coerced to the operand type: values of `u128` above the range of
                // i128 are stored as the bit pattern, so they are ordered in that type and their
                // distance is taken modulo 2^128
                if (value.compareInts(ip, .angle_bracket_left, int_ty, int_ty, hi, lo)) continue;
                // A range too long for a u32 count gives no count, like the total below
                const span = std.math.cast(u32, @as(u128, @bitCast(hi -% lo))) orelse return .{ .count = null, .value = null };
                const len = @as(u64, span) + 1;
                if (want) |w| if (found == null and w >= n and w < n + len) {
                    found = try ip.get(.{ .int_value = .{ .ty = int_ty, .value = lo +% @as(i128, w - n) } });
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

/// The payloads (union fields) that the `inline` prong `prongs[pi]` of a switch on the tagged
/// union `ty` is instantiated for, in order: one per item, and for `inline else`, one per field
/// that no other prong names, in declaration order. Null when the prong is not inline or an item
/// cannot be evaluated.
pub fn inlineUnionPayloads(r: *Resolver, body: *const Body, exprs: []const TypedValue, prongs: []const Body.Prong, pi: usize, ty: Index) Error!?[]const eval.Field {
    const prong = prongs[pi];
    if (!prong.is_inline) return null;
    const ip = r.ctx.db.env.ip;
    const fields = try eval.fieldNames(r, ty);
    if (!prong.is_else) {
        const out = try r.arena.alloc(eval.Field, prong.items.len);
        for (prong.items, out) |item, *o| {
            const name = itemTagName(ip, body, exprs, item) orelse return null;
            o.* = for (fields) |f| {
                if (std.mem.eql(u8, f.name, name)) break f;
            } else return null;
        }
        return out;
    }
    var named: std.ArrayList([]const u8) = .empty;
    for (prongs, 0..) |p, k| {
        if (k == pi) continue;
        for (p.items) |item| try named.append(r.arena, itemTagName(ip, body, exprs, item) orelse return null);
    }
    var out: std.ArrayList(eval.Field) = .empty;
    for (fields) |f| if (!hasName(named.items, f.name)) try out.append(r.arena, f);
    return out.items;
}

/// Tag name of a switch prong item on a tagged union: an enum literal, or a comptime-known tag
fn itemTagName(ip: *InternPool, body: *const Body, exprs: []const TypedValue, item: ExprId) ?[]const u8 {
    return switch (body.expr(item)) {
        .enum_literal => |n| n,
        else => switch (ip.key((if (@backingInt(item) < exprs.len) exprs[@backingInt(item)].val else null) orelse return null)) {
            .enum_tag => |tag| tag.name,
            else => null,
        },
    };
}

fn hasName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Result type of one item in an initializer expression, and the field its field name resolves to
pub const InitField = struct { ty: ?Index = null, member: ?hir.OwnerKey = null };

/// Result type and field of item `index` (`name` is the field name, null in tuple form) in an
/// initializer expression of type `t`; `ns` is `t`'s namespace (null when `t` is not a
/// container type)
pub fn initField(r: *Resolver, t: Index, ns: ?Namespace, index: usize, name: ?[]const u8) Error!InitField {
    const ip = r.ctx.db.env.ip;
    var field: InitField = .{ .ty = switch (ip.key(t)) {
        .array_type => |a| a.child,
        .abstract_array_type => |a| a.child,
        .vector_type => |v| v.child,
        .tuple_type => |tt| if (name == null and index < tt.types.len) tt.types[index] else null,
        else => null,
    } };
    if (name) |n| if (ns) |space| {
        const tree = try r.itemTree(space.file);
        if (fieldItem(tree, space.container, n)) |fi| {
            field.ty = (try queries.defType(r, .{ .item = .{ .file = space.file, .item = fi } }, null, queries.instOfType(ip, t))).ty;
            field.member = .{ .file = space.file, .item = tree.items[fi].ast_id };
        }
    } else switch (ip.key(t)) {
        // Fields of constructed types, tuples and anonymous structs
        .reified_type, .tuple_type, .anon_struct_type => field.ty = try eval.fieldType(r, t, n),
        else => {},
    };
    return field;
}

/// A field in a container (by name)
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

/// Names of primitive types and values
pub fn primitive(ip: *InternPool, name: []const u8) Error!?TypedValue {
    const simple = std.meta.stringToEnum(InternPool.Simple, name);
    if (simple) |s| switch (s) {
        // These are type names but not identifiers that can be written directly
        .null, .undefined, .enum_literal => {},
        else => return TypedValue.ofType(try ip.get(.{ .simple_type = s })),
    };
    if (std.mem.eql(u8, name, "true")) return .{ .ty = .bool_type, .val = .true_value };
    if (std.mem.eql(u8, name, "false")) return .{ .ty = .bool_type, .val = .false_value };
    if (std.mem.eql(u8, name, "null")) return .{ .ty = .null_type, .val = .null_value };
    if (std.mem.eql(u8, name, "undefined")) return .{ .ty = .undefined_type, .val = .undefined_value };
    // `u8`, `i32`, `u0`
    if (name.len >= 2 and (name[0] == 'u' or name[0] == 'i')) {
        const bits = std.fmt.parseInt(u16, name[1..], 10) catch return null;
        if (name[1] == '0' and name.len > 2) return null;
        // AstGen rejects a signed integer type with bit width 0
        if (name[0] == 'i' and bits == 0) return null;
        return TypedValue.ofType(try ip.intType(if (name[0] == 'u') .unsigned else .signed, bits));
    }
    return null;
}
