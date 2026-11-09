//! comptime interpreter: interprets on HIR the function calls evaluated at comptime (type
//! constructors, calls in a comptime context) and the initializer expressions of container-level
//! constants; values are types and values in the InternPool.
//!
//! Values inside the interpreter are mutable: locals, elements of arrays and structs, and writes
//! through pointers (a pointer is represented as a storage cell + an element path). Values are
//! interned only when they leave the interpreter (return values, query results), so intermediate
//! results do not pile up in the grow-only InternPool. Evaluation gives up on an unknown value, an
//! operation that can only be determined at runtime, unsupported syntax, or `@compileError`, and
//! the result is unknown. Fuel: each evaluation has a step limit, nested calls inside the
//! interpreter have a depth limit, and calls through queries and deep recursion are guarded by
//! the query engine's stack depth limit.

const std = @import("std");
const Allocator = std.mem.Allocator;
const database = @import("../database.zig");
const Db = database.Db;
const engine = @import("../db/engine.zig");
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
const ast = @import("../syntax/ast.zig");
const SyntaxKind = @import("../syntax/kind.zig").SyntaxKind;
const queries = @import("queries.zig");
const infer = @import("infer.zig");
const value = @import("value.zig");
const bigint = @import("bigint.zig");
const zon = @import("zon.zig");

/// Default quota of backward branches (each loop iteration, each call), same as the compiler;
/// raised by `@setEvalBranchQuota`. When the quota is exceeded the compiler reports an error;
/// here evaluation gives up.
pub const default_branch_quota = 1000;
/// Limit on the nesting depth of declarations expanded when finding the origin of a string:
/// mutually referencing declarations never terminate; past the limit the origin is just not
/// tracked
const max_tracked_decls = 64;
/// Memory limit of a single evaluation (bytes): evaluation gives up when it is exceeded, e.g. by
/// copying large arrays or concatenating long strings in a loop. Same as the memory limit of
/// rust-analyzer's const evaluation.
const max_eval_bytes = 1024 * 1024 * 1024;
/// Depth limit of containers nested by value when computing layouts (a type that contains itself
/// by value is invalid and would never terminate)
const max_layout_depth = 64;
/// Nesting depth limit of values when interning (levels of aggregates and pointers). Interned
/// values are uniquely represented by their content and have no cycles, so expanding a
/// self-referencing value (such as `n.next = &n`) along its pointers would never terminate.
const max_freeze_depth = 256;

const Error = resolve.Error;
/// Giving up evaluation, and control flow
const EvalError = Error || error{ Abort, Break, Continue, Return };

/// comptime call: the instance of the callee and the values of the arguments
pub const CallKey = struct {
    /// Same as the instance in type inference (comptime parameters take the value, anytype takes
    /// the type, others are `runtime`); determines the identity of containers defined in the body
    inst: Index,
    /// Values of the arguments: an `aggregate` whose elements correspond one-to-one to the
    /// parameters, with unknown for unknown values. Its type is the tuple of the argument types:
    /// a value does not always give back its type (a null `?u8` passed to a `??u8` parameter is
    /// a non-null `??u8`, while `null` itself is the null of `??u8`).
    values: Index,
    /// Backward branch quota: the current quota at the call site. In the compiler the callee shares
    /// the backward branch count with the caller; here the callee starts counting anew, so it never
    /// gives up before the compiler does.
    quota: u32 = default_branch_quota,
};

/// Executes a comptime call with instance `inst` and arguments `args` (one-to-one with the
/// parameters), with backward branch quota `quota`
pub fn call(r: *Resolver, inst: Index, args: []const TypedValue, quota: u32) Error!TypedValue {
    const ip = r.ctx.db.env.ip;
    const values = try r.arena.alloc(Index, args.len);
    const types = try r.arena.alloc(Index, args.len);
    for (args, values, types) |a, *v, *t| {
        v.* = a.val orelse .unknown;
        t.* = a.ty;
    }
    const types_ty = try ip.get(.{ .tuple_type = .{ .types = types } });
    const key: CallKey = .{ .inst = inst, .values = try ip.get(.{ .aggregate = .{ .ty = types_ty, .elems = values } }), .quota = quota };
    return r.ctx.get(queries.CallEval, key);
}

/// The largest quota set by `@setEvalBranchQuota` in the member's body (at least the default
/// quota): used by the evaluations that inference and goto start directly in the member. Where
/// the call appears is not distinguished, so it never gives up before the compiler does. When
/// an argument cannot be evaluated, the maximum value is taken. `exprs` is the member's
/// inference result (possibly incomplete).
pub fn bodyQuota(r: *Resolver, body: *const Body, exprs: []const TypedValue) u32 {
    const ip = r.ctx.db.env.ip;
    var quota: u32 = default_branch_quota;
    for (body.exprs) |e| {
        const b = switch (e) {
            .builtin_call => |b| b,
            else => continue,
        };
        if (!std.mem.eql(u8, b.name, "@setEvalBranchQuota") or b.args.len != 1) continue;
        const arg = b.args[0];
        const n: ?i128 = switch (body.expr(arg)) {
            .literal => |text| switch (std.zig.parseNumberLiteral(text)) {
                .int => |v| v,
                else => null,
            },
            else => if (@backingInt(arg) < exprs.len) value.intOf(ip, exprs[@backingInt(arg)].val) else null,
        };
        const v = n orelse return std.math.maxInt(u32);
        quota = @max(quota, std.math.cast(u32, v) orelse std.math.maxInt(u32));
    }
    return quota;
}

/// Computation of `CallEval`
pub fn compute(ctx: *Db.Ctx, key: CallKey) Error!TypedValue {
    var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
    defer scratch.deinit();
    var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
    const ip = ctx.db.env.ip;
    const inst = ip.key(key.inst).instance;
    const scope = try queries.enterContext(&r, inst.file, key.inst);
    defer scope.leave();
    var ev: Evaluator = .{ .r = &r, .ip = ip, .a = scratch.allocator(), .arena = &scratch, .quota = key.quota };
    defer ev.deinit();
    const args, const types = switch (ip.key(key.values)) {
        .aggregate => |agg| .{ agg.elems, switch (ip.key(agg.ty)) {
            .tuple_type => |t| t.types,
            else => &.{},
        } },
        else => .{ &.{}, &.{} },
    };
    const vals = try ev.a.alloc(Val, args.len);
    for (args, vals, 0..) |x, *v, i| {
        const ty = if (i < types.len and types[i] != .unknown) types[i] else value.typeOfValue(ip, x);
        v.* = if (x == .unknown) .unknown else Val.of(ty, x);
    }
    const result = ev.runFunction(.{ .file = inst.file, .item = inst.decl }, key.inst, vals) catch |err| return giveUp(err);
    return ev.toTyped(result) catch |err| giveUp(err);
}

/// Computation of `LocalEval`: executes function `key.owner` in its instance `key.inst`, with the
/// argument values the instance records, and stops once the frame of the function defines local
/// constant `key.target`. Only a constant defined at most once per call (outside the bodies,
/// conditions and continue expressions of loops) has one value per instance; such a constant
/// also has that value in every iteration of a loop inferred per iteration, so an iteration
/// instance stands for the instance of its function. The call sites that produce the instance
/// are not known, so the backward branch quota is the default one (`@setEvalBranchQuota` in the
/// function raises it as usual).
pub fn localValue(ctx: *Db.Ctx, key: queries.LocalKey) Error!TypedValue {
    const binding = switch (key.target) {
        .binding => |b| b,
        .expr => return .unknown,
    };
    const ip = ctx.db.env.ip;
    var run = key.inst orelse return .unknown;
    var inst = switch (ip.key(run)) {
        .instance => |i| i,
        else => return .unknown,
    };
    if (inst.file != key.owner.file or inst.decl != key.owner.item) return .unknown;
    if (inst.iteration) |it| {
        if (it.abstract) return .unknown;
        inst.iteration = null;
        run = try ip.get(.{ .instance = inst });
    }
    const body = try ctx.get(hir.ItemBody, key.owner);
    if (@backingInt(binding) >= body.bindings.len) return .unknown;
    const b = body.binding(binding);
    if (b.kind != .local_const or repeats(body, b.range.start)) return .unknown;
    var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
    defer scratch.deinit();
    var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
    const scope = try queries.enterContext(&r, key.owner.file, run);
    defer scope.leave();
    var stop: Stop = .{ .binding = binding };
    var ev: Evaluator = .{ .r = &r, .ip = ip, .a = scratch.allocator(), .arena = &scratch, .stop = &stop };
    defer ev.deinit();
    const vals = try ev.a.alloc(Val, body.params.len);
    for (body.params, vals, 0..) |p, *v, i| {
        const x: Index = if (i < inst.args.len) inst.args[i] else .unknown;
        // The instance records only the type of the argument of an anytype parameter, which
        // `runFunction` takes from the instance
        const param = body.binding(p);
        const type_only = param.ty == null and !param.is_comptime;
        v.* = if (x == .unknown or x == .runtime or type_only) .unknown else Val.of(value.typeOfValue(ip, x), x);
    }
    _ = ev.runFunction(key.owner, run, vals) catch |err| switch (err) {
        error.Abort, error.Break, error.Continue, error.Return => {},
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return stop.value orelse .unknown;
}

/// Whether code at offset `pos` of a body can run more than once per execution of the body: in
/// the body, the condition or the continue expression of a loop
fn repeats(body: *const Body, pos: u32) bool {
    const within = struct {
        fn f(b: *const Body, e: ExprId, at: u32) bool {
            const rg = b.range(e);
            return rg.start <= at and at < rg.end;
        }
    }.f;
    for (body.exprs) |x| switch (x) {
        .loop => |l| {
            if (within(body, l.body, pos)) return true;
            if (l.cont) |c| if (within(body, c, pos)) return true;
            if (l.kind == .@"while") for (l.inputs) |i| if (within(body, i, pos)) return true;
        },
        else => {},
    };
    return false;
}

/// comptime value of the body of a member (container-level constant, field default value).
/// `want` is the type annotation.
pub fn ownerValue(r: *Resolver, owner: hir.OwnerKey, inst: ?Index, want: ?Index) Error!TypedValue {
    const scope = if (r.context == null) try queries.enterContext(r, owner.file, inst) else null;
    defer if (scope) |s| s.leave();
    var arena: std.heap.ArenaAllocator = .init(r.ctx.db.gpa);
    defer arena.deinit();
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = arena.allocator(), .arena = &arena };
    defer ev.deinit();
    const item = try ev.itemIndex(owner) orelse return .unknown;
    const body = try r.ctx.get(hir.ItemBody, owner);
    const main = body.value orelse return .unknown;
    var frame = try ev.newFrame(owner.file, item, body, inst);
    const v = ev.eval(&frame, main, want) catch |err| return giveUp(err);
    return ev.toTyped(v) catch |err| giveUp(err);
}

/// comptime value of an expression under the given bindings: used when type inference cannot
/// evaluate a value in a comptime context. `quota` is the backward branch quota (see
/// `bodyQuota`).
pub fn exprValue(r: *Resolver, file: FileId, item: u32, body: *const Body, e: ExprId, inst: ?Index, bindings: []const TypedValue, want: ?Index, quota: u32) Error!TypedValue {
    // Evaluations started outside a computation in a compilation (such as by goto) run in the
    // compilation of `file` and `inst`
    const scope = if (r.context == null) try queries.enterContext(r, file, inst) else null;
    defer if (scope) |s| s.leave();
    var arena: std.heap.ArenaAllocator = .init(r.ctx.db.gpa);
    defer arena.deinit();
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = arena.allocator(), .arena = &arena, .quota = quota };
    defer ev.deinit();
    var frame = try ev.newFrame(file, item, body, inst);
    for (bindings, frame.slots) |b, *slot| slot.* = Evaluator.thaw(b);
    const v = ev.eval(&frame, e, want) catch |err| return giveUp(err);
    return ev.toTyped(v) catch |err| giveUp(err);
}

pub const StringOrigin = struct {
    file: FileId,
    /// Member containing the literal (index into `ItemTree.items`)
    item: u32,
    /// The string literal
    expr: ExprId,
    /// Offset into the decoded content of the literal
    offset: u32,
};

/// Finds the string literal that the string reached along `path` (element indices level by
/// level, transparent through pointers) in the comptime value of expression `e` comes from.
/// Re-evaluates with origin tracking: string literals are placed in separate storage cells,
/// slices keep referencing them, and calls are expanded within this evaluation; when the string
/// is copied (e.g. by `++` or by building it byte by byte), the origin is lost and null is
/// returned.
pub fn stringOrigin(r: *Resolver, file: FileId, item: u32, body: *const Body, e: ExprId, path: []const u32) Error!?StringOrigin {
    var arena: std.heap.ArenaAllocator = .init(r.ctx.db.gpa);
    defer arena.deinit();
    var tracking: Tracking = .{};
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = arena.allocator(), .arena = &arena, .track = &tracking };
    defer ev.deinit();
    var frame = try ev.newFrame(file, item, body, null);
    const origin = ev.followOrigin(&frame, e, path) catch |err| switch (err) {
        error.Abort, error.Break, error.Continue, error.Return => return null,
        else => |x| return x,
    };
    return origin;
}

/// Searches the interned value for a string whose content is `needle`; `path` holds the element
/// indices level by level (transparent through pointers, consistent with `stringOrigin`);
/// `chain` holds the values passed through along the path, in order (excluding the root and the
/// string itself)
pub fn findString(ip: *InternPool, a: Allocator, root: Index, needle: []const u8, path: *std.ArrayList(u32), chain: *std.ArrayList(Index)) Allocator.Error!bool {
    var budget: u32 = 4096;
    if (try findStringIn(ip, a, root, needle, path, chain, &budget, 0, false)) return true;
    // A single-character name may also be made of a single byte (`@as(*const [1]u8, &c)`): when
    // there is no such string, look for a u8 whose value is that character
    if (needle.len != 1) return false;
    path.clearRetainingCapacity();
    chain.clearRetainingCapacity();
    budget = 4096;
    return findStringIn(ip, a, root, needle, path, chain, &budget, 0, true);
}

fn findStringIn(ip: *InternPool, a: Allocator, v: Index, needle: []const u8, path: *std.ArrayList(u32), chain: *std.ArrayList(Index), budget: *u32, depth: u32, byte: bool) Allocator.Error!bool {
    if (budget.* == 0 or depth > 12) return false;
    budget.* -= 1;
    switch (ip.key(v)) {
        .int_value => |x| return byte and x.ty == .u8_type and x.value == needle[0],
        .bytes => |b| switch (ip.key(b.ty)) {
            // Strings (arrays and pointers to arrays)
            .array_type, .ptr_type => return !byte and std.mem.eql(u8, b.bytes, needle),
            // Structs etc. whose elements are all u8 are also represented as bytes: check each
            // element
            else => {
                if (!byte) return false;
                const i = std.mem.indexOfScalar(u8, b.bytes, needle[0]) orelse return false;
                try path.append(a, @intCast(i));
                return true;
            },
        },
        .ptr_value => |p| return findStringIn(ip, a, p.pointee, needle, path, chain, budget, depth + 1, byte),
        .aggregate => |agg| for (agg.elems, 0..) |x, i| {
            try path.append(a, @intCast(i));
            if (depth > 0) try chain.append(a, v);
            if (try findStringIn(ip, a, x, needle, path, chain, budget, depth + 1, byte)) return true;
            _ = path.pop();
            if (depth > 0) _ = chain.pop();
        },
        else => {},
    }
    return false;
}

/// Field of a value (aggregates, unions, `len` of slices and arrays); null when it cannot be
/// evaluated
pub fn fieldValue(r: *Resolver, base: TypedValue, name: []const u8) Error!?TypedValue {
    var arena: std.heap.ArenaAllocator = .init(r.ctx.db.gpa);
    defer arena.deinit();
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = arena.allocator(), .arena = &arena };
    defer ev.deinit();
    const v = ev.fieldAccess(Evaluator.thaw(base), name) catch |err| return abortToNull(err);
    const tv = ev.toTyped(v) catch |err| return abortToNull(err);
    return if (tv.val != null) tv else null;
}

/// Element `i` of a value; null when it cannot be evaluated
pub fn elemValue(r: *Resolver, base: TypedValue, i: usize) Error!?TypedValue {
    var arena: std.heap.ArenaAllocator = .init(r.ctx.db.gpa);
    defer arena.deinit();
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = arena.allocator(), .arena = &arena };
    defer ev.deinit();
    const v = ev.elemAt(Evaluator.thaw(base), i) catch |err| return abortToNull(err);
    const tv = ev.toTyped(v) catch |err| return abortToNull(err);
    return if (tv.val != null) tv else null;
}

/// Number of elements of a value (arrays, slices, tuples, structs, etc.; determined by the type
/// when the value is `undefined`); null when it cannot be evaluated
pub fn elemCount(r: *Resolver, base: TypedValue) Error!?usize {
    var arena: std.heap.ArenaAllocator = .init(r.ctx.db.gpa);
    defer arena.deinit();
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = arena.allocator(), .arena = &arena };
    defer ev.deinit();
    return ev.elemCount(Evaluator.thaw(base)) catch |err| switch (err) {
        error.Abort, error.Break, error.Continue, error.Return => null,
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Size, alignment, and bit width of a type (`@sizeOf` / `@alignOf` / `@bitSizeOf`), including
/// the layout of containers; null when it cannot be evaluated
pub fn typeLayout(r: *Resolver, t: Index) Error!?value.Layout {
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = r.arena };
    defer ev.deinit();
    return ev.typeLayout(t, 0) catch |err| switch (err) {
        error.Abort, error.Break, error.Continue, error.Return => null,
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Result type of `@backingInt` (matches the compiler): the tag integer for enums, the integer
/// of the tag enum for tagged unions, the explicitly given backing integer for packed
/// containers; null for other types or when it cannot be evaluated
pub fn backingIntType(r: *Resolver, t: Index) Error!?Index {
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = r.arena };
    defer ev.deinit();
    return ev.backingIntType(t) catch |err| switch (err) {
        error.Abort, error.Break, error.Continue, error.Return => null,
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Explicitly given tag type of an enum (the `u8` of `enum(u8)`); null when there is none. Does
/// not read the values of the members.
pub fn explicitTagType(r: *Resolver, t: Index) Error!?Index {
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = r.arena };
    defer ev.deinit();
    if (!value.isEnumType(ev.ip, t)) return null;
    const decl = ev.containerSyntax(t) catch |err| switch (err) {
        error.Abort, error.Break, error.Continue, error.Return => return null,
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return decl.arg;
}

/// The `T` of the source enum `ns` declared `enum(T)`, in instance `inst`, for display: null when
/// the declaration gives no tag type, `.unknown` when it cannot be evaluated
pub fn writtenTagType(r: *Resolver, ns: Namespace, inst: ?Index) Error!?Index {
    const arg = try containerArgValue(r, ns, inst) orelse return null;
    return arg.asType() orelse .unknown;
}

/// The value written for member `item` of a source enum (`a = 5`), as the compiler evaluates it:
/// null when the member has none, `.unknown` when it cannot be evaluated
pub fn writtenEnumValue(r: *Resolver, file: FileId, item: u32, inst: ?Index) Error!?Index {
    const owner = try r.ownerKey(file, item);
    const body = try r.ctx.get(hir.ItemBody, owner);
    if (body.value == null) return null;
    return (try ownerValue(r, owner, inst, null)).val orelse .unknown;
}

/// Value of the argument of `enum(u8)` / `union(E)` / `packed struct(u32)` (in the inference
/// result of the enclosing member); null when the declaration has no argument
fn containerArgValue(r: *Resolver, ns: Namespace, inst: ?Index) Error!?TypedValue {
    const tree = try r.itemTree(ns.file);
    const parent = tree.containers[ns.container].parent_item orelse return null;
    const rel = try r.containerRel(ns) orelse return null;
    const body = try r.body(ns.file, parent);
    for (body.exprs, 0..) |x, i| switch (x) {
        .container => |c| if (body.expr_ranges[i].start == rel) {
            const arg = c.arg orelse return null;
            // Infer only the argument expression: inference of the enclosing member as a whole
            // may be in progress (for a container in a body), and taking it would form a cycle
            const owner = try r.ownerKey(ns.file, parent);
            return try r.ctx.get(queries.LocalValue, .{ .owner = owner, .target = .{ .expr = arg }, .inst = try queries.normalizeInst(r, ns.file, parent, inst) });
        },
        else => {},
    };
    return null;
}

/// Pointer value pointing to the comptime constant value `pointee` (consistent with the
/// interpreter's representation: a pointer to an array is represented by its elements)
pub fn constPointer(r: *Resolver, ptr_ty: Index, pointee: Index) Error!Index {
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = r.arena };
    defer ev.deinit();
    return ev.pointerTo(ptr_ty, pointee, null);
}

/// `&e` where `e` has the comptime-known value `pointee`, under the given bindings: a pointer of
/// type `ptr_ty` to that value (see `constPointer`), which records its place when `e` is a
/// container-level declaration or a field or element inside one (`InternPool.Key.ptr_base`), as
/// the interpreter's `&` does
pub fn addressValue(r: *Resolver, file: FileId, item: u32, body: *const Body, e: ExprId, inst: ?Index, bindings: []const TypedValue, ptr_ty: Index, pointee: Index) Error!Index {
    const scope = if (r.context == null) try queries.enterContext(r, file, inst) else null;
    defer if (scope) |s| s.leave();
    var arena: std.heap.ArenaAllocator = .init(r.ctx.db.gpa);
    defer arena.deinit();
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = arena.allocator(), .arena = &arena };
    defer ev.deinit();
    var frame = try ev.newFrame(file, item, body, inst);
    for (bindings, frame.slots) |b, *slot| slot.* = Evaluator.thaw(b);
    const base = ev.addressBase(&frame, e, pointee) catch |err| switch (err) {
        error.Abort, error.Break, error.Continue, error.Return => null,
        else => |x| return x,
    };
    return ev.pointerTo(ptr_ty, pointee, base);
}

/// Tag type of a union (E for `union(E)`, the generated tag enum for `union(enum)`); null when
/// it is not a tagged union
pub fn unionTag(r: *Resolver, t: Index) Error!?Index {
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = r.arena };
    defer ev.deinit();
    if (!ev.isUnion(t)) return null;
    return ev.unionTagType(t) catch |err| switch (err) {
        error.Abort, error.Break, error.Continue, error.Return => null,
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Content of a comptime-known string; null when it is not one
pub fn stringValue(r: *Resolver, tv: TypedValue) Error!?[]const u8 {
    const v = tv.val orelse return null;
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = r.arena };
    defer ev.deinit();
    return ev.stringOf(Val.of(tv.ty, v)) catch |err| switch (err) {
        error.Abort, error.Break, error.Continue, error.Return => null,
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Bit offset of a struct field (`@bitOffsetOf`); null when it cannot be evaluated
pub fn bitOffsetOf(r: *Resolver, t: Index, field: []const u8) Error!?u64 {
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = r.arena };
    defer ev.deinit();
    return ev.bitOffsetOf(t, field) catch |err| switch (err) {
        error.Abort, error.Break, error.Continue, error.Return => null,
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Value of a builtin that only computes (math functions, layout) when its arguments are all
/// known, used by the inferrer; null when it is not such a builtin or cannot be evaluated
pub fn builtinValue(r: *Resolver, name: []const u8, args: []const TypedValue) Error!?TypedValue {
    var arena: std.heap.ArenaAllocator = .init(r.ctx.db.gpa);
    defer arena.deinit();
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = arena.allocator(), .arena = &arena };
    defer ev.deinit();
    const vals = try ev.a.alloc(Val, args.len);
    for (args, vals) |a, *o| o.* = Evaluator.thaw(a);
    const v = (ev.pureBuiltin(name, vals) catch |err| return abortToNull(err)) orelse return null;
    const tv = ev.toTyped(v) catch |err| return abortToNull(err);
    return if (tv.val != null) tv else null;
}

/// `@embedFile(path)`: content of the file in the directory of `file`, with the same type as a
/// string literal (`*const [len:0]u8`). Null when the file does not exist (see `embeddedFile`).
pub fn embedFile(r: *Resolver, file: FileId, path: []const u8) Error!?TypedValue {
    const text = (try embeddedFile(r, file, path) orelse return null).text;
    const ip = r.ctx.db.env.ip;
    const ty = try ip.stringLiteralType(text.len);
    return .{ .ty = ty, .val = try ip.get(.{ .bytes = .{ .ty = ty, .bytes = text } }) };
}

/// The file `@embedFile(path)` in `file` reads, and its content. For an open document the buffer
/// is authoritative; otherwise the file is read from disk (see `SourceText`). When the file does
/// not exist the compiler reports an error, and the result is null.
pub fn embeddedFile(r: *Resolver, file: FileId, path: []const u8) Error!?struct { file: FileId, text: []const u8 } {
    const target = try r.relativeFile(file, path) orelse return null;
    const source = try r.ctx.get(syntax.SourceText, target);
    // Not open, and could not be read from disk either: the file does not exist (reading an empty
    // file yields empty content)
    if (!source.owned and try r.ctx.get(database.inputs.FileText, target) == null) return null;
    return .{ .file = target, .text = source.text };
}

/// Type of a field in a tuple, anonymous struct, constructed type, or source container (of a
/// source container, only the type of that field is computed)
pub fn fieldType(r: *Resolver, t: Index, name: []const u8) Error!?Index {
    const ip = r.ctx.db.env.ip;
    switch (ip.key(t)) {
        .container_type => |c| {
            if (c.kind == .@"enum" or c.kind == .@"opaque") return null;
            const ns = try queries.namespaceOfType(r, t) orelse return null;
            const tree = try r.itemTree(ns.file);
            for (tree.containerMembers(ns.container)) |m| {
                const it = tree.items[m];
                if (it.kind != .field or !std.mem.eql(u8, it.name orelse "", name)) continue;
                return (try queries.defType(r, .{ .item = .{ .file = ns.file, .item = m } }, null, c.inst)).ty;
            }
            return null;
        },
        else => {},
    }
    var ev: Evaluator = .{ .r = r, .ip = ip, .a = r.arena };
    defer ev.deinit();
    const fields = try ev.fieldsOf(t) orelse return null;
    for (fields) |f| if (std.mem.eql(u8, f.name, name)) return f.ty;
    return null;
}

/// Field names (in declaration order): for completing the members of constructed types, tuples,
/// and anonymous structs
pub fn fieldNames(r: *Resolver, t: Index) Error![]const Field {
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = r.arena };
    defer ev.deinit();
    return try ev.fieldsOf(t) orelse &.{};
}

/// Member names of a constructed enum (`@Enum`, the tag enum of `union(enum)`)
pub fn enumMemberNames(r: *Resolver, t: Index) Error![]const []const u8 {
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = r.arena };
    defer ev.deinit();
    return try ev.enumNames(t) orelse &.{};
}

/// Member of a type (declarations, enum members)
pub fn typeMember(r: *Resolver, t: Index, name: []const u8) Error!?TypedValue {
    var arena: std.heap.ArenaAllocator = .init(r.ctx.db.gpa);
    defer arena.deinit();
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = arena.allocator(), .arena = &arena };
    defer ev.deinit();
    const v = ev.typeMember(t, name) catch |err| return abortToNull(err);
    return ev.toTyped(v) catch |err| abortToNull(err);
}

fn abortToNull(err: EvalError) Error!?TypedValue {
    return switch (err) {
        error.Abort, error.Break, error.Continue, error.Return => null,
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Whether two values are equal: beyond `value.eqlValues`, two containers at the same location
/// in different instances are compared by the values they capture (in Zig the identity of a
/// container = definition location + captured values: a container that captures no arguments
/// is the same type across instances). Captured values are compared as the compiler interns
/// them: values of different types are different captures even when `==` holds for them
/// (`@as(u8, 3)` and `@as(u16, 3)`).
pub fn eqlValues(r: *Resolver, a: Index, b: Index) Error!?bool {
    const ip = r.ctx.db.env.ip;
    if (value.eqlValues(ip, a, b)) |eq| return eq;
    const ca = switch (ip.key(a)) {
        .container_type => |c| c,
        else => return null,
    };
    const cb = switch (ip.key(b)) {
        .container_type => |c| c,
        else => return null,
    };
    if (ca.file != cb.file or ca.ast_id != cb.ast_id) return false;
    const ia = ca.inst orelse return null;
    const ib = cb.inst orelse return null;
    const ns = try queries.namespaceOfType(r, a) orelse return null;
    var unknown = false;
    for (try captures(r, ns)) |cap| {
        const def: resolve.Def = .{ .local = .{ .file = ns.file, .item = cap.item, .binding = cap.binding } };
        const ta = try queries.defType(r, def, null, ia);
        const tb = try queries.defType(r, def, null, ib);
        const va = ta.val orelse return null;
        const vb = tb.val orelse return null;
        const same_value = value.eqlValues(ip, va, vb);
        const same_type = value.eqlTypes(ip, ta.ty, tb.ty);
        if (same_value == false or same_type == false) return false;
        if (same_value == null or same_type == null) unknown = true;
    }
    return if (unknown) null else true;
}

pub const Capture = struct { item: u32, binding: Body.BindingId };

/// The prong a switch takes when no item equals the operand `v`: with both `else` and `_` (a
/// non-exhaustive enum), `else` takes the values a member has and `_` the others; otherwise the
/// one present takes them all (matches the compiler's comptime switch)
pub fn otherProng(ip: *InternPool, v: ?Index, else_prong: ?usize, under_prong: ?usize) ?usize {
    const under = under_prong orelse return else_prong;
    if (else_prong == null) return under;
    const unnamed = if (v) |x| ip.key(x) == .enum_unnamed else false;
    return if (unnamed) under else else_prong;
}

/// Parameters and locals of the enclosing function that are referenced by the members of the
/// container (including nested containers)
pub fn captures(r: *Resolver, ns: Namespace) Error![]const Capture {
    const tree = try r.itemTree(ns.file);
    var out: std.ArrayList(Capture) = .empty;
    for (tree.items, 0..) |_, i| {
        // Whether the member lies inside the container (through nested containers)
        var c: u32 = tree.items[i].container;
        const inside = while (true) {
            if (c == ns.container) break true;
            const parent = tree.containers[c].parent_item orelse break false;
            c = tree.items[parent].container;
        };
        if (!inside) continue;
        const body = try r.body(ns.file, @intCast(i));
        for (body.exprs, 0..) |e, ei| {
            const name = switch (e) {
                .name_ref => |n| n,
                else => continue,
            };
            const def = try r.resolveName(ns.file, @intCast(i), body, body.expr_scopes[ei], name) orelse continue;
            const l = switch (def) {
                .local => |l| l,
                else => continue,
            };
            // The member's own locals are not captures
            if (l.item == i) continue;
            for (out.items) |x| {
                if (x.item == l.item and x.binding == l.binding) break;
            } else try out.append(r.arena, .{ .item = l.item, .binding = l.binding });
        }
    }
    return out.items;
}

/// Types that can only exist at comptime, including structs and unions with fields of such
/// types (e.g. `std.builtin.Type`, the result of `std.meta.fieldInfo`): calls returning them
/// are executed at comptime
pub fn isComptimeOnly(r: *Resolver, t: Index) Error!bool {
    return r.ctx.get(queries.ComptimeOnly, t);
}

/// Computation of `ComptimeOnly`: the fields of structs and unions (excluding comptime fields)
/// and the types in pointers (except function pointers), arrays, optionals, error unions, and
/// tuples; the type is comptime-only if any of them is
pub fn computeComptimeOnly(r: *Resolver, t: Index) Error!bool {
    const ip = r.ctx.db.env.ip;
    if (value.isComptimeOnly(ip, t)) return true;
    switch (ip.key(t)) {
        .container_type => |c| {
            if (!c.kind.isStruct() and c.kind != .@"union") return false;
            const ns = try queries.namespaceOfType(r, t) orelse return false;
            const tree = try r.itemTree(ns.file);
            for (tree.containerMembers(ns.container)) |m| {
                const it = tree.items[m];
                if (it.kind != .field or it.flags.is_comptime) continue;
                const ty = (try queries.defType(r, .{ .item = .{ .file = ns.file, .item = m } }, null, c.inst)).ty;
                if (try isComptimeOnly(r, ty)) return true;
            }
            return false;
        },
        .ptr_type => |p| return ip.key(p.child) != .fn_type and try isComptimeOnly(r, p.child),
        .array_type => |a| return isComptimeOnly(r, a.child),
        .abstract_array_type => |a| return isComptimeOnly(r, a.child),
        .optional_type => |c| return isComptimeOnly(r, c),
        .error_union_type => |e| return isComptimeOnly(r, e.payload),
        .tuple_type => |tt| return anyRuntimeFieldComptimeOnly(r, tt.types, tt.values),
        .anon_struct_type => |as| return anyRuntimeFieldComptimeOnly(r, as.types, as.values),
        .reified_type => |rt| {
            if (rt.kind == .@"enum") return false;
            for (rt.types, 0..) |field_ty, i| {
                if (i < rt.comptime_fields.len and rt.comptime_fields[i]) continue;
                if (try isComptimeOnly(r, field_ty)) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Fields of tuples and anonymous structs whose values are not comptime-known (comptime fields
/// do not make the type comptime-only)
fn anyRuntimeFieldComptimeOnly(r: *Resolver, types: []const Index, values: []const Index) Error!bool {
    for (types, 0..) |t, i| {
        const v = InternPool.fieldValue(values, i);
        if ((v == .runtime or v == .unknown) and try isComptimeOnly(r, t)) return true;
    }
    return false;
}

/// Value of `@typeInfo(t)`; null when `t` has unknown parts
pub fn typeInfo(r: *Resolver, t: Index) Error!?Index {
    var arena: std.heap.ArenaAllocator = .init(r.ctx.db.gpa);
    defer arena.deinit();
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = arena.allocator(), .arena = &arena };
    defer ev.deinit();
    return ev.typeInfo(t) catch |err| switch (err) {
        error.Abort, error.Break, error.Continue, error.Return => null,
        else => |e| e,
    };
}

fn giveUp(err: EvalError) Error!TypedValue {
    return switch (err) {
        error.Abort, error.Break, error.Continue, error.Return => .unknown,
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
    };
}

// ── Values ───────────────────────────────────────────────────────────

/// A value in the interpreter
const Val = struct {
    ty: Index,
    /// When tracking origins, the origin of a byte taken from a string literal (index into
    /// `Tracking.bytes` plus one); 0 means none. Occupies the alignment padding after `ty`, so it
    /// does not enlarge `Val`.
    origin: u32 = 0,
    v: Repr = .unknown,

    const unknown: Val = .{ .ty = .unknown };
    const void_val: Val = .{ .ty = .void_type, .v = .{ .ip = .void_value } };

    fn of(ty: Index, v: Index) Val {
        return .{ .ty = ty, .v = if (v == .undefined_value) .undef else .{ .ip = v } };
    }

    fn ofType(t: Index) Val {
        return .{ .ty = .type_type, .v = .{ .ip = t } };
    }

    fn ofInt(ty: Index, x: i128) Val {
        return .{ .ty = ty, .v = .{ .int = x } };
    }

    /// An integer of type `ty` that may not fit i128 (`ty` is comptime_int or wider than 128
    /// bits); a value that fits is stored inline
    fn ofBig(ty: Index, b: bigint.Big) Val {
        return if (bigint.toInt(b)) |x| .{ .ty = ty, .v = .{ .int = x } } else .{ .ty = ty, .v = .{ .big = b } };
    }

    /// Whether `v` is the interned value `x` (integers are not interned)
    fn is(v: Val, x: Index) bool {
        return v.v == .ip and v.v.ip == x;
    }
};

const Repr = union(enum) {
    unknown,
    undef,
    /// An interned value
    ip: Index,
    /// Integer: intermediate results of arithmetic are not interned; they are interned only when
    /// `freeze` hands out the result, so large comptime loops do not bloat the InternPool
    int: i128 align(8),
    /// An integer outside the range of i128 (comptime_int, or a type wider than 128 bits):
    /// intermediate results are not interned
    big: bigint.Big,
    /// Mutable aggregate inside the interpreter: arrays, vectors, tuples, structs (in field order)
    agg: *Agg,
    /// Pointer: points to an element inside a storage cell
    ref: Ref,
};

const Agg = struct { elems: []Val };

const Ref = struct {
    cell: *Val,
    /// Element indices taken level by level from the value of the storage cell
    path: []const u32,
    /// Slice: points to the range `[start, start + len)` of the aggregate at `path` (shares
    /// storage with the original array); with `as_array`, of the one-element array view
    window: ?Window = null,
    /// The place cannot be written: a constant, a temporary, or a place reached through a
    /// `*const` pointer. A pointer taken to it with `&` is `*const`.
    is_const: bool = false,
    /// A single-item pointer coerced to a pointer to a one-element array (`*T` → `*[1]T`): the
    /// place at `path` itself is the only element of the array pointed to, so reads and writes
    /// through the pointer reach that place
    as_array: bool = false,
    /// The storage cell never changes after it is initialized: the slot of a binding other than a
    /// `var`, or a new cell reachable only through `*const` pointers. A property of the cell, not
    /// of the access path: a place reached through a `*const` pointer to a `var` is const but not
    /// immutable.
    immutable: bool = false,

    const Window = struct { start: u32, len: u32 };
};

/// What the storage of a cell is in the compiler, which decides what pointers into it are equal
/// to (see `pointerEql`)
const CellOrigin = enum {
    /// Other storage created by this evaluation: the result of an operation, or a copy of data
    /// whose identity is not known here (`addressOfValue`)
    storage,
    /// A local variable: a comptime allocation in the compiler, distinct from every anonymous
    /// constant unless it has no bits (the compiler stores a variable of a zero-bit type as the
    /// anonymous constant of its only value)
    variable,
    /// A container-level declaration (a `Nav` in the compiler): every `&` of it gives a pointer
    /// to the same storage
    decl,
    /// An `extern` declaration: other `extern` declarations may name the same symbol
    extern_decl,
    /// A `threadlocal` variable: its address is known only at runtime
    thread_local,
    /// A comptime-known value that is not a place: the compiler's `analyzeRef` makes an
    /// anonymous constant of it, the same constant for equal values of the same type. A `++`
    /// result that is a pointer points to such a constant too (`Sema.zirArrayCat`).
    temporary,
    /// A copy of storage outside this evaluation whose place is not known here (a field reached
    /// through an interned pointer that records no place, a value captured from an enclosing
    /// function): pointers into it compare as an interned pointer to that data would
    copy,
    /// A constant local, a parameter, or a capture (see `constantCell`): an anonymous constant
    /// in the compiler like `temporary`, the same constant as a temporary with an equal value
    constant,
    /// A constant local declared with `align`: an anonymous constant whose alignment is part of
    /// its identity. The alignment is not tracked here, so whether it is the same constant as
    /// another one with an equal value is not known.
    aligned_constant,

    /// An anonymous constant (`temporary`, `constant`, `aligned_constant`)
    fn isAnonymous(o: CellOrigin) bool {
        return switch (o) {
            .temporary, .constant, .aligned_constant => true,
            .storage, .variable, .decl, .extern_decl, .thread_local, .copy => false,
        };
    }
};

/// A container-level declaration under the instance it belongs to (`queries.declInst`)
const DeclKey = struct { file: FileId, item: u32, inst: ?Index };

/// The anonymous constant a constant binding's pointers point to, and the binding's value when
/// it was made (see `constantCell`)
const ConstantCell = struct { value: Val, cell: *Val };

/// Storage cells of the string literals created during evaluation, and their locations
const Tracking = struct {
    literals: std.ArrayList(Literal) = .empty,
    /// Single bytes taken from literals: the index into `literals` and the byte's offset within
    /// the literal's content
    bytes: std.ArrayList(Byte) = .empty,

    const Literal = struct { cell: *Val, file: FileId, item: u32, expr: ExprId };
    const Byte = struct { literal: u32, offset: u32 };
};

comptime {
    std.debug.assert(@sizeOf(Val) == @sizeOf(Index) * 2 + @sizeOf(Repr));
}

/// Results of `scalarCall`: the key is the byte representation of the instance, the quota, and
/// the arguments (types and values); a value of `.unknown` means it could not be evaluated.
/// Affects only speed: cleared when the number of entries reaches the limit, so memory does not
/// grow with the number of calls; not counted toward the evaluation's memory limit.
const CallMemo = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged(Val) = .empty,

    const max_entries = 1 << 16;

    fn put(m: *CallMemo, key: []const u8, v: Val) Allocator.Error!void {
        if (m.map.count() >= max_entries) {
            m.map = .empty;
            _ = m.arena.reset(.retain_capacity);
        }
        const a = m.arena.allocator();
        try m.map.put(a, try a.dupe(u8, key), v);
    }
};

const Frame = struct {
    file: FileId,
    item: u32,
    body: *const Body,
    inst: ?Index,
    /// Corresponds one-to-one with `body.bindings`
    slots: []Val,
    ret_type: ?Index = null,
    labels: std.ArrayList(Label) = .empty,
};

/// Target of break / continue
const Label = struct {
    name: ?[]const u8,
    kind: enum { block, loop, @"switch" },
    want: ?Index,
};

pub const Field = struct { name: []const u8, ty: Index, item: ?u32 = null };

/// Where `localValue` stops the evaluation: once the frame of the function it executes defines
/// local constant `binding`
const Stop = struct {
    binding: Body.BindingId,
    /// The frame of the function `localValue` executes (the first frame `runFunction` creates)
    frame: ?*const Frame = null,
    /// The value of the constant once defined; every later step then aborts
    value: ?TypedValue = null,
};

const Evaluator = struct {
    r: *Resolver,
    ip: *InternPool,
    a: Allocator,
    /// Source of `a`: used to check how much memory the evaluation uses
    arena: ?*std.heap.ArenaAllocator = null,
    /// Number of expressions evaluated: cancellation and memory are checked at intervals
    steps: u32 = 0,
    /// Number of backward branches and the quota (see `default_branch_quota`)
    branches: u32 = 0,
    quota: u32 = default_branch_quota,
    /// Nesting depth of declarations expanded by `trackedDecl`
    tracked_decls: u32 = 0,
    /// Current nesting depth of `freeze`
    freeze_depth: u32 = 0,
    /// Tracking of string literal origins (see `stringOrigin`)
    track: ?*Tracking = null,
    /// Results of calls whose arguments contain non-interned integers (see `scalarCall`); shared
    /// by the calls at every level of this evaluation
    calls: ?*CallMemo = null,
    /// `calls` is created by this interpreter and freed in `deinit`
    owns_calls: bool = false,
    /// Target (index into `Frame.labels`) and value of break / continue; the value of return
    jump_target: usize = 0,
    jump_value: Val = .unknown,
    /// Stops the evaluation at the definition of a local constant (see `localValue`)
    stop: ?*Stop = null,
    /// Storage cells of the container-level declarations whose address `&` takes in this
    /// evaluation, so that every `&` of a declaration points to the same cell
    decl_cells: std.AutoHashMapUnmanaged(DeclKey, *Val) = .empty,
    /// Origins of the cells that are not `.storage` (see `CellOrigin`)
    cell_origins: std.AutoHashMapUnmanaged(*const Val, CellOrigin) = .empty,
    /// The declaration of each cell in `decl_cells`: an interned pointer into one records it
    /// (`ptrBase`)
    cell_decls: std.AutoHashMapUnmanaged(*const Val, DeclKey) = .empty,
    /// Anonymous constants of constant bindings, by the binding's slot (see `constantCell`)
    constant_cells: std.AutoHashMapUnmanaged(*const Val, ConstantCell) = .empty,

    fn deinit(ev: *Evaluator) void {
        if (!ev.owns_calls) return;
        const memo = ev.calls.?;
        memo.arena.deinit();
        ev.r.ctx.db.gpa.destroy(memo);
    }

    fn tick(ev: *Evaluator) EvalError!void {
        const ctx = ev.r.ctx;
        if (ev.stop) |s| if (s.value != null) return error.Abort;
        ev.steps +%= 1;
        if (ev.steps % 256 == 0) {
            try ctx.checkCanceled();
            if (ev.arena) |arena| if (arena.queryCapacity() > max_eval_bytes) return error.Abort;
        }
        // Nested too deeply (recursive calls expanded inside the interpreter): the result depends
        // on the stack depth at evaluation time, so it is not written to the memo
        if (ctx.stackExhausted()) {
            ctx.exhausted();
            return error.Abort;
        }
    }

    /// Backward branch (one loop iteration, one call): gives up when the quota is exceeded; the
    /// compiler reports an error here
    fn backwardBranch(ev: *Evaluator) EvalError!void {
        ev.branches += 1;
        if (ev.branches > ev.quota) return error.Abort;
    }

    fn itemIndex(ev: *Evaluator, owner: hir.OwnerKey) Error!?u32 {
        const tree = try ev.r.itemTree(owner.file);
        for (tree.items, 0..) |it, i| if (it.ast_id == owner.item) return @intCast(i);
        return null;
    }

    fn newFrame(ev: *Evaluator, file: FileId, item: u32, body: *const Body, inst: ?Index) Error!Frame {
        const slots = try ev.a.alloc(Val, body.bindings.len);
        @memset(slots, .unknown);
        return .{ .file = file, .item = item, .body = body, .inst = inst, .slots = slots };
    }

    // ── Interning ────────────────────────────────────────────────────

    fn toTyped(ev: *Evaluator, v: Val) EvalError!TypedValue {
        return .{ .ty = v.ty, .val = try ev.freeze(v) };
    }

    fn thaw(tv: TypedValue) Val {
        return if (tv.val) |x| Val.of(tv.ty, x) else .{ .ty = tv.ty };
    }

    /// Interned value; null when the value is unknown. Self-referencing values and values nested
    /// deeper than `max_freeze_depth` are treated as unknown.
    fn freeze(ev: *Evaluator, v: Val) EvalError!?Index {
        switch (v.v) {
            .unknown => return null,
            .undef => return .undefined_value,
            .ip => |x| return x,
            .int => |x| return try ev.ip.get(.{ .int_value = .{ .ty = v.ty, .value = x } }),
            .big => |b| return try value.internInt(ev.ip, ev.a, v.ty, b),
            .agg, .ref => {},
        }
        if (ev.freeze_depth >= max_freeze_depth) return null;
        ev.freeze_depth += 1;
        defer ev.freeze_depth -= 1;
        switch (v.v) {
            .agg => |agg| {
                const elems = try ev.a.alloc(Index, agg.elems.len);
                for (agg.elems, elems) |e, *out| out.* = try ev.freeze(e) orelse return null;
                return try ev.aggregate(v.ty, elems);
            },
            .ref => |ref| {
                const target = if (ref.as_array) blk: {
                    const elems = try ev.viewElems(v, ref);
                    break :blk try ev.makeAgg(try ev.ip.get(.{ .array_type = .{ .len = elems.len, .child = ev.elemTypeOf(v.ty, 0) } }), elems);
                } else try ev.load(ref);
                const pointee = try ev.freeze(target) orelse return null;
                return try ev.pointerTo(v.ty, pointee, try ev.ptrBase(ref));
            },
            .unknown, .undef, .ip, .int, .big => unreachable,
        }
    }

    /// The `ptr_base` of a pointer to `ref`: null when the cell is not the storage of a
    /// container-level declaration
    fn ptrBase(ev: *Evaluator, ref: Ref) Error!?Index {
        const decl = ev.cell_decls.get(ref.cell) orelse return null;
        return try ev.ip.get(.{ .ptr_base = .{
            .file = decl.file,
            .item = decl.item,
            .inst = decl.inst,
            .path = ref.path,
            .window = if (ref.window) |w| .{ .start = w.start, .len = w.len } else null,
            .as_array = ref.as_array,
        } });
    }

    /// The `ptr_base` of `&e` when `e` is a place inside a container-level declaration and holds
    /// `pointee` there; null for other operands, and for functions, which are the identity of
    /// pointers to them (`functionPointer`)
    fn addressBase(ev: *Evaluator, f: *Frame, e: ExprId, pointee: Index) EvalError!?Index {
        if (ev.ip.key(pointee) == .fn_value) return null;
        const ref = try ev.placeFor(f, e, .address);
        if (try ev.freeze(try ev.load(ref)) != pointee) return null;
        return ev.ptrBase(ref);
    }

    /// The place interned pointer `p` points to when it records one (`InternPool.Key.ptr_base`):
    /// in this evaluation's cell of that declaration (`declPlace`), which cannot be written. Null
    /// for other values.
    fn basePlace(ev: *Evaluator, p: Val) EvalError!?Ref {
        const x = switch (p.v) {
            .ip => |x| x,
            else => return null,
        };
        const base = switch (ev.ip.key(x)) {
            .ptr_value => |v| v.base,
            .aggregate => |v| v.base,
            .bytes => |v| v.base,
            else => null,
        } orelse return null;
        const b = ev.ip.key(base).ptr_base;
        const decl = try ev.declPlace(b.file, b.item, b.inst);
        return .{
            .cell = decl.cell,
            .path = b.path,
            .window = if (b.window) |w| .{ .start = w.start, .len = w.len } else null,
            .is_const = true,
            .as_array = b.as_array,
            .immutable = decl.immutable,
        };
    }

    /// The place pointer `p` points to: its reference, or the place an interned pointer records
    fn pointerPlace(ev: *Evaluator, p: Val) EvalError!?Ref {
        return switch (p.v) {
            .ref => |r| r,
            else => ev.basePlace(p),
        };
    }

    /// Interned value (integers are interned here); null when it is neither an interned value nor
    /// an integer
    fn ipOf(ev: *Evaluator, v: Val) Error!?Index {
        return switch (v.v) {
            .ip => |x| x,
            .int => |x| try ev.ip.get(.{ .int_value = .{ .ty = v.ty, .value = x } }),
            .big => |b| try value.internInt(ev.ip, ev.a, v.ty, b),
            else => null,
        };
    }

    /// Integer value; null when it is not a known integer
    fn intOf(ev: *Evaluator, v: Val) ?i128 {
        return switch (v.v) {
            .int => |x| x,
            .ip => |x| value.intOf(ev.ip, x),
            else => null,
        };
    }

    /// Integer value at arbitrary precision; null when it is not a known integer
    fn bigOf(ev: *Evaluator, v: Val) EvalError!?bigint.Big {
        return switch (v.v) {
            .big => |b| b,
            .int => |x| try value.bigOfInt(ev.ip, ev.a, v.ty, x),
            .ip => |x| try value.bigValueOf(ev.ip, ev.a, x),
            else => null,
        };
    }

    /// `a op b` for a comparison operator `op` on integer values: as machine integers when both
    /// are (reading u128 values above i128's range as unsigned), otherwise at arbitrary precision.
    /// Null when either is not a known integer.
    fn compareIntVals(ev: *Evaluator, op: SyntaxKind, a: Val, b: Val) EvalError!?bool {
        if (ev.intOf(a)) |x| if (ev.intOf(b)) |y| return value.compareInts(ev.ip, op, a.ty, b.ty, x, y);
        const x = try ev.bigOf(a) orelse return null;
        const y = try ev.bigOf(b) orelse return null;
        return compareBig(op, x, y);
    }

    /// Float value (integers as floats); null when it is not a known number
    fn floatOf(ev: *Evaluator, v: Val) ?f128 {
        return switch (v.v) {
            .int => |x| if (x < 0 and value.isUnsigned128(ev.ip, v.ty)) @floatFromInt(@as(u128, @bitCast(x))) else @floatFromInt(x),
            .big => |b| bigint.toFloat(b),
            .ip => |x| value.floatOf(ev.ip, x),
            else => null,
        };
    }

    fn aggregate(ev: *Evaluator, ty: Index, elems: []const Index) Error!Index {
        return value.aggregate(ev.ip, ev.a, ty, elems);
    }

    /// Pointer value: pointers to arrays and slices are represented by the pointed-to elements,
    /// others by `ptr_value`; `base` is the place pointed to when it is known (`ptrBase`)
    fn pointerTo(ev: *Evaluator, ptr_ty: Index, pointee: Index, base: ?Index) Error!Index {
        const ip = ev.ip;
        if (ev.isArrayPtr(ptr_ty)) switch (ip.key(pointee)) {
            .aggregate => |agg| return ip.get(.{ .aggregate = .{ .ty = ptr_ty, .elems = agg.elems, .base = base } }),
            .bytes => |b| return ip.get(.{ .bytes = .{ .ty = ptr_ty, .bytes = b.bytes, .base = base } }),
            else => {},
        };
        return ip.get(.{ .ptr_value = .{ .ty = ptr_ty, .pointee = pointee, .base = base } });
    }

    /// Slice, many-item pointer, or single-item pointer to an array / tuple / vector
    fn isArrayPtr(ev: *Evaluator, t: Index) bool {
        return switch (ev.ip.key(t)) {
            .ptr_type => |p| p.size != .one or switch (ev.ip.key(p.child)) {
                .array_type, .tuple_type, .vector_type => true,
                else => false,
            },
            else => false,
        };
    }

    /// Deep-copies a mutable aggregate (value semantics)
    fn copy(ev: *Evaluator, v: Val) EvalError!Val {
        const agg = switch (v.v) {
            .agg => |x| x,
            else => return v,
        };
        const out = try ev.a.create(Agg);
        out.* = .{ .elems = try ev.allocElems(agg.elems.len) };
        for (agg.elems, out.elems) |e, *o| o.* = try ev.copy(e);
        return .{ .ty = v.ty, .v = .{ .agg = out } };
    }

    /// Whether the value is or contains a pointer through which storage inside the interpreter
    /// can change: a pointer to a cell that is not immutable, or to an immutable cell whose
    /// content in turn contains such a pointer. The same rule as the compiler's
    /// `Value.canMutateComptimeVarState`. Past `depth` levels of pointers the answer is yes.
    fn refersToMutableStorage(v: Val, depth: u32) bool {
        return switch (v.v) {
            .ref => |r| !r.immutable or depth == 0 or refersToMutableStorage(pointeeOf(r), depth - 1),
            .agg => |agg| for (agg.elems) |e| {
                if (refersToMutableStorage(e, depth)) break true;
            } else false,
            .unknown, .undef, .ip, .int, .big => false,
        };
    }

    /// The value at the end of the reference's path, without copying (for a range, the whole
    /// aggregate it is a range of); an interned level contains no pointers into the interpreter,
    /// so the walk stops there
    fn pointeeOf(r: Ref) Val {
        var cur = r.cell.*;
        for (r.path) |i| switch (cur.v) {
            .agg => |agg| cur = if (i < agg.elems.len) agg.elems[i] else return .unknown,
            else => return .unknown,
        };
        return cur;
    }

    // ── Aggregates ───────────────────────────────────────────────────

    /// Type of element `i` (arrays, slices, pointers to arrays, vectors, tuples, structs)
    fn elemTypeOf(ev: *Evaluator, t: Index, i: usize) Index {
        const ip = ev.ip;
        return switch (ip.key(t)) {
            .array_type => |a| a.child,
            .vector_type => |v| v.child,
            .tuple_type => |tt| if (i < tt.types.len) tt.types[i] else .unknown,
            .anon_struct_type => |s| if (i < s.types.len) s.types[i] else .unknown,
            .reified_type => |rt| if (i < rt.types.len) rt.types[i] else .unknown,
            .ptr_type => |p| if (p.size != .one) p.child else ev.elemTypeOf(p.child, i),
            .container_type => blk: {
                const fields = ev.fieldsOf(t) catch break :blk .unknown;
                break :blk if (fields != null and i < fields.?.len) fields.?[i].ty else .unknown;
            },
            else => .unknown,
        };
    }

    /// Number of elements determined by the type (arrays, vectors, tuples, structs)
    fn typeElemCount(ev: *Evaluator, t: Index) Error!?usize {
        return switch (ev.ip.key(t)) {
            .array_type => |a| std.math.cast(usize, a.len),
            .vector_type => |v| v.len,
            .tuple_type => |tt| tt.types.len,
            .anon_struct_type => |s| s.names.len,
            .reified_type => |rt| if (rt.kind == .@"struct") rt.names.len else null,
            .ptr_type => |p| if (p.size == .one) try ev.typeElemCount(p.child) else null,
            .container_type => |c| if (c.kind.isStruct()) (if (try ev.fieldsOf(t)) |f| f.len else null) else null,
            else => null,
        };
    }

    /// Number of elements; when the value is unknown, the number determined by the type
    fn elemCount(ev: *Evaluator, v: Val) EvalError!?usize {
        switch (v.v) {
            .agg => |agg| return agg.elems.len,
            // The length of a range is known without taking out its elements
            .ref => |ref| return if (ref.window) |w| w.len else if (ref.as_array) 1 else ev.elemCount(try ev.load(ref)),
            .ip => |x| switch (ev.ip.key(x)) {
                .aggregate => |agg| return agg.elems.len,
                .bytes => |b| return b.bytes.len,
                .ptr_value => |p| return ev.elemCount(Val.of(ev.pointeeType(v.ty), p.pointee)),
                else => {},
            },
            else => {},
        }
        return ev.typeElemCount(v.ty);
    }

    fn pointeeType(ev: *Evaluator, t: Index) Index {
        return switch (ev.ip.key(t)) {
            .ptr_type => |p| p.child,
            else => .unknown,
        };
    }

    /// The sentinel when `i` is its index in an array of type `t`
    fn sentinelElem(ev: *Evaluator, t: Index, i: usize) ?Val {
        const a = switch (ev.ip.key(t)) {
            .array_type => |a| a,
            else => return null,
        };
        const s = a.sentinel orelse return null;
        return if (i == a.len) Val.of(a.child, s) else null;
    }

    /// The sentinel after the elements of a sequence of type `t`: an array, the array a
    /// single-item pointer points to, a slice, or a many-item pointer
    fn seqSentinel(ev: *Evaluator, t: Index) ?Index {
        const ip = ev.ip;
        return switch (ip.key(t)) {
            .array_type => |a| a.sentinel,
            .abstract_array_type => |a| a.sentinel,
            .ptr_type => |p| switch (p.size) {
                .one => switch (ip.key(p.child)) {
                    .array_type => |a| a.sentinel,
                    .abstract_array_type => |a| a.sentinel,
                    else => null,
                },
                .slice, .many, .c => p.sentinel,
            },
            else => null,
        };
    }

    /// Whether a pointer of type `t` reads the element right after the elements it holds. A slice
    /// with a sentinel reads it there (`Sema.elemValSlice` accepts index `len`); a many-item or C
    /// pointer reads whatever its storage holds there (`Sema.elemVal` loads through it, and the
    /// loaded storage includes the sentinel of an array: `Type.arrayBase` counts it).
    fn readsPastEnd(ev: *Evaluator, t: Index) bool {
        return switch (ev.ip.key(t)) {
            .ptr_type => |p| switch (p.size) {
                .slice => p.sentinel != null,
                .many, .c => true,
                .one => false,
            },
            else => false,
        };
    }

    /// Element `i` of an interned slice or many-item pointer of type `t` holding `len` elements,
    /// for `i` past them; `storage` is the type the elements were interned with. Only the element
    /// right after them is known, as a sentinel: for a slice its own, which the language
    /// guarantees the storage holds there; for a many-item pointer that of the storage, since the
    /// pointer type does not bound the read (`[*]const u8` pointing to `"ab"` reads its `0`).
    fn elemPastEnd(ev: *Evaluator, t: Index, storage: Index, i: usize, len: usize) EvalError!Val {
        if (i != len or !ev.readsPastEnd(t)) return error.Abort;
        const p = ev.ip.key(t).ptr_type;
        const s = (if (p.size == .slice) p.sentinel else ev.seqSentinel(storage)) orelse return error.Abort;
        return Val.of(p.child, s);
    }

    /// Element `i`; unknown when the value is unknown
    fn elemAt(ev: *Evaluator, v: Val, i: usize) EvalError!Val {
        const ty = ev.elemTypeOf(v.ty, i);
        // The sentinel of an array is part of its type, and so is that of the array a single-item
        // pointer points to: index `len` reads it whatever the value (`Sema.elemValArray`, and
        // the single-item pointer case of `Sema.elemVal`)
        if (ev.sentinelElem(ev.arrayOf(v.ty), i)) |s| return s;
        switch (v.v) {
            .unknown => return .{ .ty = ty },
            .undef => return .{ .ty = ty, .v = .undef },
            .int, .big => return error.Abort,
            .agg => |agg| return if (i < agg.elems.len) agg.elems[i] else error.Abort,
            .ref => |ref| {
                // Range: the index is relative to the start of the range; take the element
                // directly from the containing aggregate, which also holds the element right after
                // the range (the sentinel position of `buf[0..n :0]`)
                const base = try ev.loadPath(ref);
                const index = if (ref.window) |w| blk: {
                    if (i > w.len or (i == w.len and !ev.readsPastEnd(v.ty))) return error.Abort;
                    break :blk w.start + i;
                } else i;
                // `*T` → `*[1]T`: the place itself is element 0, read as the pointer's element
                // type
                if (ref.as_array) return if (index == 0) ev.readAs(base, ty) else error.Abort;
                var elem = try ev.elemAt(base, index);
                // When tracking origins, a byte from a literal records its position, so a name
                // built byte by byte (`&[1]u8{c}`) can also be traced back to the literal
                if (ev.track) |t| if (ref.path.len == 0) for (t.literals.items, 0..) |lit, li| {
                    if (lit.cell != ref.cell) continue;
                    try t.bytes.append(ev.a, .{ .literal = @intCast(li), .offset = @intCast(index) });
                    elem.origin = @intCast(t.bytes.items.len);
                    break;
                };
                return elem;
            },
            .ip => |x| switch (ev.ip.key(x)) {
                .aggregate => |agg| return if (i < agg.elems.len) Val.of(ty, agg.elems[i]) else ev.elemPastEnd(v.ty, agg.ty, i, agg.elems.len),
                // Aggregates whose elements are all u8 are also represented as bytes (e.g. a
                // value of `struct { short: ?u8 }`): use the declared type of the element
                .bytes => |b| return if (i < b.bytes.len) Val.of(if (ty != .unknown) ty else .u8_type, try ev.ip.get(.{ .int_value = .{ .ty = .u8_type, .value = b.bytes[i] } })) else ev.elemPastEnd(v.ty, b.ty, i, b.bytes.len),
                .ptr_value => |p| return ev.elemAt(Val.of(ev.pointeeType(v.ty), p.pointee), i),
                // Field `i` of a union (the place of `&u.y`): only the active field has a value
                .union_value => |u| {
                    const fields = try ev.fieldsOf(u.ty) orelse return error.Abort;
                    if (i >= fields.len or !std.mem.eql(u8, fields[i].name, u.tag)) return error.Abort;
                    return Val.of(fields[i].ty, u.payload);
                },
                else => return error.Abort,
            },
        }
    }

    /// The value the pointer points to. A range has its elements taken out into an array (copied
    /// on read; writes reach the original storage through `extend`); to get only an element or the
    /// length, use `elemAt` / `elemCount`, which do not copy the range.
    fn load(ev: *Evaluator, ref: Ref) EvalError!Val {
        var cur = try ev.loadPath(ref);
        // `*T` → `*[1]T`: an array whose only element is the place, as stored (`deref` reads the
        // elements as the pointer's element type)
        if (ref.as_array) {
            const elems = try ev.allocElems(1);
            elems[0] = cur;
            cur = try ev.makeAgg(try ev.ip.get(.{ .array_type = .{ .len = 1, .child = cur.ty } }), elems);
        }
        const w = ref.window orelse return cur;
        const elems = try ev.allocElems(w.len);
        for (elems, w.start..) |*o, i| o.* = try ev.elemAt(cur, i);
        const array = try ev.ip.get(.{ .array_type = .{ .len = w.len, .child = ev.elemTypeOf(cur.ty, w.start) } });
        return ev.makeAgg(array, elems);
    }

    /// Elements read through a pointer `p` to a `*T` → `*[1]T` view (see `Ref.as_array`), as its
    /// element type
    fn viewElems(ev: *Evaluator, p: Val, ref: Ref) EvalError![]Val {
        const elems = try ev.allocElems(if (ref.window) |w| w.len else 1);
        for (elems, 0..) |*o, i| o.* = try ev.elemAt(p, i);
        return elems;
    }

    /// Value read through a pointer to `child` from a place holding `v`. A pointer to the payload
    /// of an optional (`if (opt) |*x|`) points to where the optional is: it reads the optional's
    /// payload.
    fn readAs(ev: *Evaluator, v: Val, child: Index) EvalError!Val {
        if (child != .unknown and v.ty != child) switch (ev.ip.key(v.ty)) {
            .optional_type => |c| if (c == child) return try ev.unwrapOptional(v, child) orelse error.Abort,
            else => {},
        };
        return v;
    }

    /// Value obtained by taking elements level by level along `path`; for a range, the aggregate
    /// containing it (without taking out the range)
    fn loadPath(ev: *Evaluator, ref: Ref) EvalError!Val {
        var cur = ref.cell.*;
        for (ref.path) |i| cur = try ev.elemAt(cur, i);
        return cur;
    }

    /// Expands an aggregate of `n` elements: checks this evaluation's memory limit before
    /// allocating (`tick` checks memory only at intervals, and a large aggregate expanded in a
    /// single step would get past it)
    fn allocElems(ev: *Evaluator, n: usize) EvalError![]Val {
        const used = if (ev.arena) |arena| arena.queryCapacity() else 0;
        if (n > (max_eval_bytes - @min(used, max_eval_bytes)) / @sizeOf(Val)) return error.Abort;
        return ev.a.alloc(Val, n);
    }

    fn store(ev: *Evaluator, ref: Ref, v: Val) EvalError!void {
        // Comptime code cannot write a container-level declaration: a constant, or a variable
        // whose contents are known only at runtime
        if (ev.cell_decls.contains(ref.cell)) return error.Abort;
        if (ref.window) |w| {
            // Write element by element: each element counts as one step
            for (0..w.len) |i| {
                try ev.tick();
                try ev.store(try ev.extend(ref, @intCast(i)), try ev.elemAt(v, i));
            }
            return;
        }
        // `*T` → `*[1]T`: the place itself is the only element
        if (ref.as_array) return ev.store(try ev.extend(ref, 0), try ev.elemAt(v, 0));
        var cell = ref.cell;
        for (ref.path, 0..) |i, depth| {
            // The sentinel of an array (`buf[buf.len] = 0` in std.fmt.comptimePrint) is part of
            // the type: storing the same value changes nothing, storing another is an error
            if (depth == ref.path.len - 1) if (ev.sentinelElem(cell.ty, i)) |s| {
                const x = try ev.freeze(try ev.coerce(v, s.ty)) orelse return error.Abort;
                if (try eqlValues(ev.r, x, s.v.ip) != true) return error.Abort;
                return;
            };
            const agg = try ev.mutableAgg(cell);
            if (i >= agg.elems.len) return error.Abort;
            cell = &agg.elems[i];
        }
        cell.* = try ev.copy(try ev.coerce(v, if (cell.ty != .unknown) cell.ty else null));
    }

    /// Expands the value in a storage cell into a mutable aggregate
    fn mutableAgg(ev: *Evaluator, cell: *Val) EvalError!*Agg {
        if (cell.v == .agg) return cell.v.agg;
        if (cell.v == .ref) return error.Abort;
        const n = try ev.elemCount(cell.*) orelse return error.Abort;
        const agg = try ev.a.create(Agg);
        agg.* = .{ .elems = try ev.allocElems(n) };
        for (agg.elems, 0..) |*e, i| e.* = try ev.elemAt(cell.*, i);
        cell.v = .{ .agg = agg };
        return agg;
    }

    /// Fields of a container type (in declaration order)
    fn fieldsOf(ev: *Evaluator, t: Index) Error!?[]const Field {
        const ip = ev.ip;
        switch (ip.key(t)) {
            .container_type => |c| {
                if (c.kind == .@"enum" or c.kind == .@"opaque") return &.{};
                const ns = try queries.namespaceOfType(ev.r, t) orelse return null;
                const tree = try ev.r.itemTree(ns.file);
                var out: std.ArrayList(Field) = .empty;
                for (tree.containerMembers(ns.container)) |m| {
                    const it = tree.items[m];
                    if (it.kind != .field) continue;
                    const ty = (try queries.defType(ev.r, .{ .item = .{ .file = ns.file, .item = m } }, null, c.inst)).ty;
                    try out.append(ev.a, .{ .name = it.name orelse "", .ty = ty, .item = m });
                }
                return out.items;
            },
            .tuple_type => |tt| {
                const out = try ev.a.alloc(Field, tt.types.len);
                for (tt.types, out, 0..) |ty, *o, i| o.* = .{ .name = try std.fmt.allocPrint(ev.a, "{d}", .{i}), .ty = ty };
                return out;
            },
            .anon_struct_type => |s| {
                const out = try ev.a.alloc(Field, s.names.len);
                for (s.names, s.types, out) |n, ty, *o| o.* = .{ .name = n, .ty = ty };
                return out;
            },
            .reified_type => |rt| {
                if (rt.kind == .@"enum") return &.{};
                const out = try ev.a.alloc(Field, rt.names.len);
                for (rt.names, out, 0..) |n, *o, i| o.* = .{ .name = n, .ty = if (i < rt.types.len) rt.types[i] else .unknown };
                return out;
            },
            else => return null,
        }
    }

    fn fieldIndex(ev: *Evaluator, t: Index, name: []const u8) Error!?usize {
        const fields = try ev.fieldsOf(t) orelse return null;
        for (fields, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) return i;
        return null;
    }

    /// Default value of a struct field
    fn fieldDefault(ev: *Evaluator, t: Index, field: Field) EvalError!Val {
        const item = field.item orelse return error.Abort;
        const ns = try queries.namespaceOfType(ev.r, t) orelse return error.Abort;
        const owner = try ev.r.ownerKey(ns.file, item);
        const body = try ev.r.ctx.get(hir.ItemBody, owner);
        const default = body.value orelse return error.Abort;
        const inst = queries.instOfType(ev.ip, t);
        const res = try ev.r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full, .inst = inst });
        if (@backingInt(default) < res.exprs.len) if (res.exprs[@backingInt(default)].val) |v| return try ev.coerce(Val.of(res.exprs[@backingInt(default)].ty, v), field.ty);
        return thaw(try ownerValue(ev.r, owner, inst, field.ty));
    }

    // ── Evaluation ───────────────────────────────────────────────────

    fn eval(ev: *Evaluator, f: *Frame, e: ExprId, want: ?Index) EvalError!Val {
        try ev.tick();
        return ev.coerce(try ev.evalInner(f, e, want), want);
    }

    /// Operand of a rounding builtin with the result type `want` (matches the compiler's
    /// `zirRoundCast`): Sema checks that the operand is a float before coercing it, so `@ceil(3)`
    /// is a compile error even with the result type f32, and coerces a float operand to a float
    /// destination before rounding, so `const h: f16 = @round(0.4999999)` rounds the f16 0.5
    fn roundOperand(ev: *Evaluator, f: *Frame, e: ExprId, want: ?Index) EvalError!Val {
        try ev.tick();
        const v = try ev.evalInner(f, e, want);
        const dest = want orelse return v;
        return if (ev.ip.isFloat(v.ty)) ev.coerce(v, dest) else v;
    }

    /// Evaluates to a type
    fn evalType(ev: *Evaluator, f: *Frame, e: ExprId) EvalError!Index {
        const v = try ev.eval(f, e, null);
        if (v.ty != .type_type) return error.Abort;
        return (try ev.ipOf(v)) orelse error.Abort;
    }

    /// Value of the `callconv(...)` expression `e` of a function type; null when it cannot be
    /// evaluated or is not needed (`.c` and the tags without options, see `writtenCallConv`)
    fn callConvValue(ev: *Evaluator, f: *Frame, e: ExprId) EvalError!?Index {
        switch (f.body.expr(e)) {
            .enum_literal => |n| if (InternPool.CallConv.fromName(n) != null) return null,
            else => {},
        }
        const want = ev.stdType(&.{ "builtin", "CallingConvention" }) catch |err| switch (err) {
            error.Abort => return null,
            else => |x| return x,
        };
        const v = ev.eval(f, e, want) catch |err| switch (err) {
            error.Abort => return null,
            else => |x| return x,
        };
        return ev.freeze(v);
    }

    fn evalInt(ev: *Evaluator, f: *Frame, e: ExprId, want: ?Index) EvalError!i128 {
        const v = try ev.eval(f, e, want);
        return ev.intOf(v) orelse error.Abort;
    }

    fn evalInner(ev: *Evaluator, f: *Frame, e: ExprId, want: ?Index) EvalError!Val {
        const ip = ev.ip;
        const b = f.body;
        switch (b.expr(e)) {
            .missing, .other, .@"unreachable" => return error.Abort,
            .name_ref => |name| return ev.nameRef(f, e, name),
            .literal => |text| return if (ev.track != null) ev.trackedLiteral(f, e, text) else ev.literal(text),
            .field_access => |fa| return ev.fieldAccess(try ev.eval(f, fa.lhs, null), fa.field orelse return error.Abort),
            .enum_literal => |name| {
                if (want) |t| if (try ev.declLiteral(t, name)) |v| return v;
                return Val.of(.enum_literal_type, try ip.get(.{ .enum_literal = name }));
            },
            .error_value => |name| return Val.of(try ip.errorSet(ev.a, &.{name}), try ip.get(.{ .error_value = name })),
            .builtin_call => |bc| return ev.builtin(f, e, bc.name, bc.args, want),
            .call => |c| return ev.callExpr(f, c.callee, c.args, want),
            .block => |blk| return ev.block(f, blk, want),
            .@"if" => |x| {
                const cond = try ev.eval(f, x.cond, null);
                const taken = try ev.condition(cond);
                if (taken.yes) {
                    if (x.capture.len != 0) {
                        const cap = x.capture[0];
                        if (b.binding(cap).is_ptr and ip.key(cond.ty) == .optional_type) {
                            try ev.bindPayloadPtr(f, cap, x.cond, taken.payload);
                        } else try ev.bindCapture(f, cap, taken.payload);
                    }
                    return ev.eval(f, x.then, want);
                }
                if (x.else_capture.len != 0) try ev.bindCapture(f, x.else_capture[0], taken.payload);
                return if (x.@"else") |el| ev.eval(f, el, want) else Val.void_val;
            },
            .loop => |l| return ev.loop(f, l, want),
            .@"switch" => |s| return ev.switchExpr(f, e, s, want),
            .@"catch" => |c| {
                const lhs = try ev.eval(f, c.lhs, null);
                if (ip.key(lhs.ty) != .error_union_type) return error.Abort;
                // The payload may be storage inside the interpreter (a pointer to an element of a
                // local array, etc.); as with `try`, `condition` tells it apart from an error
                const taken = try ev.condition(lhs);
                if (taken.yes) return taken.payload;
                if (c.capture) |cap| f.slots[@backingInt(cap)] = taken.payload;
                // The handler gets the result type of the whole expression, not the payload type
                // (AstGen `orelseCatchExpr`); with a comptime-known error only the handler is
                // analyzed, so the result has the handler's type
                return ev.eval(f, c.rhs, want);
            },
            .binary => |bin| return ev.binary(f, bin.op, bin.lhs, bin.rhs, want),
            .prefix => |p| return ev.prefix(f, p.op, p.operand, want),
            .assign => |a| {
                try ev.assign(f, a.op, a.lhs, a.rhs);
                return Val.void_val;
            },
            .index => |x| {
                const lhs = try ev.eval(f, x.lhs, null);
                const i = try ev.evalInt(f, x.index, .usize_type);
                return ev.elemAt(lhs, std.math.cast(usize, i) orelse return error.Abort);
            },
            .slice => |s| return ev.slice(f, s),
            .deref => |x| return ev.deref(try ev.eval(f, x, null)),
            .unwrap_optional => |x| {
                const v = try ev.eval(f, x, null);
                const child = switch (ip.key(v.ty)) {
                    .optional_type => |c| c,
                    else => return error.Abort,
                };
                return try ev.unwrapOptional(v, child) orelse error.Abort;
            },
            .init => |x| return ev.initExpr(f, x.ty, x.fields, want),
            .container => |c| {
                if (c.arg) |arg| _ = try ev.eval(f, arg, null);
                const ns = try ev.containerAt(f, e) orelse return error.Abort;
                return Val.ofType(try queries.containerType(ev.r, ns, f.inst));
            },
            .fn_type => |ft| {
                const params = try ev.a.alloc(Index, ft.params.len);
                for (ft.params, params) |p, *out| out.* = if (p.ty) |t| try ev.evalType(f, t) else .unknown;
                const ret = if (ft.ret) |rt| try ev.evalType(f, rt) else .void_type;
                const cc: InternPool.CallConv = if (ft.@"callconv") |x| try writtenCallConv(ev.r, f.body, x, try ev.callConvValue(f, x)) else .auto;
                const bits = fnTypeBits(ft.params);
                return Val.ofType(try ip.get(.{ .fn_type = .{ .params = params, .ret = ret, .varargs = ft.varargs, .cc = cc, .comptime_bits = bits.comptime_bits, .noalias_bits = bits.noalias_bits, .generic_bits = bits.generic_bits } }));
            },
            .@"return" => |x| {
                ev.jump_value = if (x) |rv| try ev.eval(f, rv, f.ret_type) else Val.void_val;
                return error.Return;
            },
            .@"break" => |br| {
                const target = labelTarget(f, br.label) orelse return error.Abort;
                ev.jump_value = if (br.value) |v| try ev.eval(f, v, f.labels.items[target].want) else Val.void_val;
                ev.jump_target = target;
                return error.Break;
            },
            .@"continue" => |c| {
                const target = labelTarget(f, c.label) orelse return error.Abort;
                ev.jump_value = if (c.value) |v| try ev.eval(f, v, null) else Val.void_val;
                ev.jump_target = target;
                return error.Continue;
            },
            .@"comptime" => |x| return ev.eval(f, x, want),
            .optional_type => |x| return Val.ofType(try ip.optionalOf(try ev.evalType(f, x))),
            .error_union_type => |eu| {
                const err = try ev.evalType(f, eu.err);
                const payload = try ev.evalType(f, eu.payload);
                return Val.ofType(try ip.get(.{ .error_union_type = .{ .err = err, .payload = payload } }));
            },
            .ptr_type => |p| {
                const child = try ev.evalType(f, p.child);
                const sentinel = if (p.sentinel) |s| try ev.freeze(try ev.eval(f, s, child)) orelse return error.Abort else null;
                var vals: PtrClauseValues = .{};
                if (p.@"align") |x| vals.@"align" = try ev.clauseValue(f, x);
                if (p.bit_offset) |x| vals.bit_offset = try ev.clauseValue(f, x);
                if (p.host_size) |x| vals.host_size = try ev.clauseValue(f, x);
                if (p.@"addrspace") |x| vals.@"addrspace" = try ev.clauseValue(f, x);
                const attrs = try ptrAttrs(ev.r, child, p, vals);
                return Val.ofType(try ip.get(.{ .ptr_type = .{ .child = child, .size = @fromBackingInt(@intCast(@backingInt(p.size))), .is_const = p.is_const, .sentinel = sentinel, .attrs = attrs } }));
            },
            .array_type => |arr| {
                const len = try ev.evalInt(f, arr.len, .usize_type);
                const child = try ev.evalType(f, arr.child);
                const sentinel = if (arr.sentinel) |s| try ev.freeze(try ev.eval(f, s, child)) orelse return error.Abort else null;
                return Val.ofType(try ip.get(.{ .array_type = .{ .len = std.math.cast(u64, len) orelse return error.Abort, .child = child, .sentinel = sentinel } }));
            },
            .error_set => |names| return Val.ofType(try ip.errorSet(ev.a, names)),
        }
    }

    /// Value of an expression in a clause of a pointer type; null when it cannot be evaluated
    /// (the attribute is then unknown)
    fn clauseValue(ev: *Evaluator, f: *Frame, e: ExprId) EvalError!?Index {
        const v = ev.eval(f, e, null) catch |err| switch (err) {
            error.Abort => return null,
            else => |x| return x,
        };
        return ev.freeze(v);
    }

    fn nameRef(ev: *Evaluator, f: *Frame, e: ExprId, name: []const u8) EvalError!Val {
        if (!f.body.nameRefIsEscaped(e)) if (try infer.primitive(ev.ip, name)) |tv| return thaw(tv);
        const def = try ev.r.resolveName(f.file, f.item, f.body, f.body.expr_scopes[@backingInt(e)], name) orelse return error.Abort;
        switch (def) {
            .local => |l| if (l.file == f.file and l.item == f.item) return f.slots[@backingInt(l.binding)],
            else => {},
        }
        return ev.declValue(def, f.inst);
    }

    /// Value of a name that is not a local of the current frame
    fn declValue(ev: *Evaluator, def: resolve.Def, inst: ?Index) EvalError!Val {
        const tv = try queries.defType(ev.r, def, null, inst);
        if (ev.track != null) if (try ev.trackedDecl(def, tv)) |v| return v;
        return thaw(tv);
    }

    /// When tracking origins, a global constant whose value is a string is evaluated again within
    /// this evaluation (only then is the origin of the literal kept)
    fn trackedDecl(ev: *Evaluator, def: resolve.Def, tv: TypedValue) EvalError!?Val {
        const v = tv.val orelse return null;
        if (ev.ip.key(v) != .bytes) return null;
        const it = switch (def) {
            .item => |x| x,
            else => return null,
        };
        const tree = try ev.r.itemTree(it.file);
        const owner: hir.OwnerKey = .{ .file = it.file, .item = tree.items[it.item].ast_id };
        const body = try ev.r.ctx.get(hir.ItemBody, owner);
        const main = body.value orelse return null;
        if (ev.tracked_decls >= max_tracked_decls) return null;
        ev.tracked_decls += 1;
        defer ev.tracked_decls -= 1;
        var frame = try ev.newFrame(it.file, it.item, body, null);
        return try ev.eval(&frame, main, tv.ty);
    }

    fn followOrigin(ev: *Evaluator, f: *Frame, e: ExprId, path: []const u32) EvalError!?StringOrigin {
        var v = try ev.eval(f, e, null);
        for (path) |i| v = try ev.elemAt(v, i);
        // A single byte taken from a literal
        if (v.origin != 0) {
            const byte = ev.track.?.bytes.items[v.origin - 1];
            const lit = ev.track.?.literals.items[byte.literal];
            return .{ .file = lit.file, .item = lit.item, .expr = lit.expr, .offset = byte.offset };
        }
        const ref = switch (v.v) {
            .ref => |x| x,
            else => return null,
        };
        if (ref.path.len != 0 or ref.as_array) return null;
        for (ev.track.?.literals.items) |lit| if (lit.cell == ref.cell) return .{
            .file = lit.file,
            .item = lit.item,
            .expr = lit.expr,
            .offset = if (ref.window) |w| w.start else 0,
        };
        return null;
    }

    /// String literal when tracking origins: a pointer to a separate storage cell, which slices
    /// keep referencing
    fn trackedLiteral(ev: *Evaluator, f: *Frame, e: ExprId, text: []const u8) EvalError!Val {
        const v = try ev.literal(text);
        const ptr = switch (ev.ip.key(v.ty)) {
            .ptr_type => |p| p,
            else => return v,
        };
        const bytes = switch (ev.ip.key((try ev.ipOf(v)) orelse return v)) {
            .bytes => |b| b.bytes,
            else => return v,
        };
        const array = Val.of(ptr.child, try ev.ip.get(.{ .bytes = .{ .ty = ptr.child, .bytes = bytes } }));
        const out = try ev.pointerToNew(v.ty, array);
        try ev.track.?.literals.append(ev.a, .{ .cell = out.v.ref.cell, .file = f.file, .item = f.item, .expr = e });
        return out;
    }

    fn literal(ev: *Evaluator, text: []const u8) EvalError!Val {
        const ip = ev.ip;
        if (text.len == 0) return error.Abort;
        switch (text[0]) {
            '"', '\\' => {
                const s = try Body.stringLiteralValue(ev.a, text) orelse return error.Abort;
                const ty = try ip.stringLiteralType(s.len);
                return Val.of(ty, try ip.get(.{ .bytes = .{ .ty = ty, .bytes = s } }));
            },
            '\'' => switch (std.zig.parseCharLiteral(text)) {
                .success => |c| return Val.of(.comptime_int_type, try ip.get(.{ .int_value = .{ .ty = .comptime_int_type, .value = c } })),
                .failure => return error.Abort,
            },
            else => if (Body.zonFloatValue(text)) |x| {
                return Val.of(.comptime_float_type, (try value.floatValue(ip, .comptime_float_type, x)).?);
            } else switch (std.zig.parseNumberLiteral(text)) {
                .int => |v| return Val.of(.comptime_int_type, try ip.get(.{ .int_value = .{ .ty = .comptime_int_type, .value = v } })),
                .float => {
                    const x = std.fmt.parseFloat(f128, text) catch return error.Abort;
                    return Val.of(.comptime_float_type, (try value.floatValue(ip, .comptime_float_type, x)).?);
                },
                .big_int => |base| return Val.ofBig(.comptime_int_type, try bigint.fromLiteral(ev.a, text, @backingInt(base)) orelse return error.Abort),
                .failure => return error.Abort,
            },
        }
    }

    // ── Members ──────────────────────────────────────────────────────

    fn fieldAccess(ev: *Evaluator, base: Val, name: []const u8) EvalError!Val {
        const ip = ev.ip;
        if (base.ty == .type_type) return ev.typeMember((try ev.ipOf(base)) orelse return error.Abort, name);
        var v = base;
        // Automatically dereference single-item pointers to non-arrays
        switch (ip.key(v.ty)) {
            .ptr_type => |p| if (p.size == .one and !ev.isArrayPtr(v.ty)) {
                v = try ev.deref(v);
            },
            else => {},
        }
        // A pointer to a type (`tables.T` with `tables: *const type` in std.fmt.float)
        if (v.ty == .type_type) return ev.typeMember((try ev.ipOf(v)) orelse return error.Abort, name);
        if (std.mem.eql(u8, name, "len")) if (ev.isSequence(v.ty)) {
            const n = try ev.elemCount(v) orelse return .{ .ty = .usize_type };
            return Val.of(.usize_type, try ip.get(.{ .int_value = .{ .ty = .usize_type, .value = n } }));
        };
        // `ptr` of a slice or a pointer to an array: a many-item pointer that shares its
        // representation (used for pointer comparison; see `pointerEql`), with the sentinel of
        // the array
        if (std.mem.eql(u8, name, "ptr")) switch (ip.key(v.ty)) {
            .ptr_type => |p| switch (p.size) {
                .slice => {
                    var q = p;
                    q.size = .many;
                    return .{ .ty = try ip.get(.{ .ptr_type = q }), .v = v.v };
                },
                .one => switch (ip.key(p.child)) {
                    .array_type => |arr| {
                        var q = p;
                        q.size = .many;
                        q.child = arr.child;
                        q.sentinel = arr.sentinel;
                        return .{ .ty = try ip.get(.{ .ptr_type = q }), .v = v.v };
                    },
                    else => {},
                },
                else => {},
            },
            else => {},
        };
        switch (ip.key(v.ty)) {
            .container_type => |c| if (c.kind == .@"union") {
                const x = (try ev.ipOf(v)) orelse return error.Abort;
                const u = switch (ip.key(x)) {
                    .union_value => |u| u,
                    else => return error.Abort,
                };
                if (!std.mem.eql(u8, u.tag, name)) return error.Abort;
                return Val.of(try ev.unionFieldType(v.ty, name), u.payload);
            },
            .reified_type => |rt| if (rt.kind == .@"union") {
                const x = (try ev.ipOf(v)) orelse return error.Abort;
                const u = ip.key(x).union_value;
                if (!std.mem.eql(u8, u.tag, name)) return error.Abort;
                return Val.of(try ev.unionFieldType(v.ty, name), u.payload);
            },
            else => {},
        }
        const i = try ev.fieldIndex(v.ty, name) orelse return error.Abort;
        return ev.elemAt(v, i);
    }

    fn isSequence(ev: *Evaluator, t: Index) bool {
        return switch (ev.ip.key(t)) {
            .array_type, .vector_type, .tuple_type => true,
            .ptr_type => ev.isArrayPtr(t),
            else => false,
        };
    }

    fn unionFieldType(ev: *Evaluator, t: Index, name: []const u8) Error!Index {
        const fields = try ev.fieldsOf(t) orelse return .unknown;
        for (fields) |fl| if (std.mem.eql(u8, fl.name, name)) return fl.ty;
        return .unknown;
    }

    /// Members of a type: declarations, enum members, error set members
    fn typeMember(ev: *Evaluator, t: Index, name: []const u8) EvalError!Val {
        const ip = ev.ip;
        switch (ip.key(t)) {
            .container_type => {
                const ns = try queries.namespaceOfType(ev.r, t) orelse return error.Abort;
                const def = try ev.r.memberDef(ns, name) orelse return error.Abort;
                return thaw(try queries.defType(ev.r, def, null, queries.instOfType(ip, t)));
            },
            .error_set_type => return Val.of(t, try ip.get(.{ .error_value = name })),
            .reified_type, .union_tag_type => if (value.isEnumType(ip, t)) {
                for (try ev.enumNames(t) orelse return error.Abort) |n| if (std.mem.eql(u8, n, name)) {
                    return Val.of(t, try ip.get(.{ .enum_tag = .{ .ty = t, .name = name } }));
                };
                return error.Abort;
            },
            else => {},
        }
        return error.Abort;
    }

    /// decl literal: the declaration `.name` in the result type
    fn declLiteral(ev: *Evaluator, t: Index, name: []const u8) EvalError!?Val {
        const ip = ev.ip;
        if (ip.key(t) != .container_type) return null;
        if (value.isEnumType(ip, t)) {
            const ns = try queries.namespaceOfType(ev.r, t) orelse return null;
            if (infer.fieldItem(try ev.r.itemTree(ns.file), ns.container, name) != null) return null;
        }
        const ns = try queries.namespaceOfType(ev.r, t) orelse return null;
        const m = Resolver.lookupDecl(try ev.r.itemTree(ns.file), ns.container, name) orelse return null;
        return thaw(try queries.defType(ev.r, .{ .item = .{ .file = ns.file, .item = m } }, null, queries.instOfType(ip, t)));
    }

    /// Enum member names (in declaration order)
    fn enumNames(ev: *Evaluator, t: Index) Error!?[]const []const u8 {
        const ip = ev.ip;
        switch (ip.key(t)) {
            .container_type => |c| {
                if (c.kind != .@"enum") return null;
                const ns = try queries.namespaceOfType(ev.r, t) orelse return null;
                const tree = try ev.r.itemTree(ns.file);
                var out: std.ArrayList([]const u8) = .empty;
                for (tree.containerMembers(ns.container)) |m| {
                    const it = tree.items[m];
                    if (it.kind == .field and it.name != null) try out.append(ev.a, it.name.?);
                }
                return out.items;
            },
            .reified_type => |rt| return if (rt.kind == .@"enum") rt.names else null,
            .union_tag_type => |u| {
                const fields = try ev.fieldsOf(u) orelse return null;
                const out = try ev.a.alloc([]const u8, fields.len);
                for (fields, out) |fl, *o| o.* = fl.name;
                return out;
            },
            else => return null,
        }
    }

    /// Integer values of the enum members (in the order of `enumNames`)
    fn enumValues(ev: *Evaluator, t: Index) EvalError![]const i128 {
        const ip = ev.ip;
        switch (ip.key(t)) {
            .reified_type => |rt| if (rt.values.len == rt.names.len) return rt.values,
            .container_type => |c| {
                const ns = try queries.namespaceOfType(ev.r, t) orelse return error.Abort;
                const tree = try ev.r.itemTree(ns.file);
                var out: std.ArrayList(i128) = .empty;
                var next: i128 = 0;
                for (tree.containerMembers(ns.container)) |m| {
                    const it = tree.items[m];
                    if (it.kind != .field or it.name == null) continue;
                    // Explicit value `a = 5`
                    const owner = try ev.r.ownerKey(ns.file, m);
                    const body = try ev.r.ctx.get(hir.ItemBody, owner);
                    if (body.value != null) {
                        const tv = try ownerValue(ev.r, owner, c.inst, null);
                        next = value.intOf(ip, tv.val) orelse return error.Abort;
                    }
                    try out.append(ev.a, next);
                    next += 1;
                }
                return out.items;
            },
            else => {},
        }
        const names = try ev.enumNames(t) orelse return error.Abort;
        const out = try ev.a.alloc(i128, names.len);
        for (out, 0..) |*o, i| o.* = @intCast(i);
        return out;
    }

    /// Method: a function declaration in the value's type (through a single-item pointer)
    fn method(ev: *Evaluator, lhs: Val, name: []const u8) EvalError!?Val {
        var t = lhs.ty;
        switch (ev.ip.key(t)) {
            .ptr_type => |p| if (p.size == .one) {
                t = p.child;
            },
            else => {},
        }
        const ns = try queries.namespaceOfType(ev.r, t) orelse return null;
        const def = try ev.r.memberDef(ns, name) orelse return null;
        const tv = try queries.defType(ev.r, def, null, queries.instOfType(ev.ip, t));
        if (ev.ip.key(tv.ty) != .fn_type) return null;
        return thaw(tv);
    }

    // ── Calls ────────────────────────────────────────────────────────

    fn callExpr(ev: *Evaluator, f: *Frame, callee_e: ExprId, args: []const ExprId, want: ?Index) EvalError!Val {
        const ip = ev.ip;
        var self: ?Val = null;
        const callee: Val = switch (f.body.expr(callee_e)) {
            .field_access => |fa| blk: {
                const name = fa.field orelse return error.Abort;
                const lhs = try ev.eval(f, fa.lhs, null);
                if (lhs.ty != .type_type) if (try ev.method(lhs, name)) |m| {
                    self = lhs;
                    // The receiver is passed as the type of the first parameter: take its address
                    // when a pointer is required
                    const fty = ip.key(m.ty).fn_type;
                    if (fty.params.len > 0) switch (ip.key(fty.params[0])) {
                        .ptr_type => |p| if (p.size == .one and ip.key(lhs.ty) != .ptr_type) {
                            self = try ev.addressOf(f, fa.lhs, lhs);
                        },
                        else => {},
                    };
                    break :blk m;
                };
                break :blk try ev.fieldAccess(lhs, name);
            },
            .enum_literal => |name| blk: {
                const t = want orelse return error.Abort;
                break :blk try ev.declLiteral(t, name) orelse return error.Abort;
            },
            else => try ev.eval(f, callee_e, null),
        };
        const fty = switch (ip.key(callee.ty)) {
            .fn_type => |ft| ft,
            else => return error.Abort,
        };
        const skip: usize = if (self != null) 1 else 0;
        const vals = try ev.a.alloc(Val, args.len + skip);
        if (self) |s| vals[0] = s;
        for (args, vals[skip..], skip..) |a, *out, i| {
            const pt = if (i < fty.params.len and value.isConcrete(ip, fty.params[i])) fty.params[i] else null;
            out.* = try ev.eval(f, a, pt);
        }
        return ev.callFn(callee, fty, vals);
    }

    /// Calls a function value: through `CallEval` (results are cached) when all arguments can be
    /// interned; otherwise executes it in the current interpreter: when an argument of a runtime
    /// parameter is an aggregate or a pointer inside the interpreter, or an argument of an anytype
    /// or comptime parameter refers to storage that can change (the callee may write through it)
    fn callFn(ev: *Evaluator, callee: Val, fty: infer.FnType, args: []const Val) EvalError!Val {
        const ip = ev.ip;
        const fv = switch (ip.key((try ev.ipOf(callee)) orelse return error.Abort)) {
            .fn_value => |v| v,
            else => return error.Abort,
        };
        const callee_tv: TypedValue = .{ .ty = callee.ty, .val = try ev.ipOf(callee) };
        const g = try infer.genericCallee(ev.r, ev.a, callee_tv, fty);
        // Arguments are interned and the call goes through a query (results are cached). Mutable
        // aggregates and pointers passed to runtime parameters are not interned: the callee may
        // write through the pointers, and large intermediate values should not stay in the
        // grow-only InternPool either.
        const tvs = try ev.a.alloc(TypedValue, args.len);
        var local = false;
        // Integers passed to non-comptime parameters are not interned; the call is executed
        // through `scalarCall`
        var scalar = false;
        for (args, tvs, 0..) |a, *tv, i| {
            const kind: infer.ParamKind = if (g) |gg| gg.kind(i) else .runtime;
            if (kind == .runtime and (a.v == .agg or a.v == .ref)) {
                local = true;
                tv.* = .{ .ty = a.ty };
                continue;
            }
            if (kind == .runtime and a.v == .int) {
                scalar = true;
                tv.* = .{ .ty = a.ty };
                continue;
            }
            // A pointer to storage that can change, directly or inside an aggregate, passed to an
            // anytype or comptime parameter: the callee may write through it or return it, so the
            // call runs on the caller's storage, as in the compiler, which does not memoize a
            // comptime call when an argument can mutate comptime state. The instance of an anytype
            // parameter records only the type; a comptime parameter still takes the value.
            if (refersToMutableStorage(a, max_freeze_depth)) {
                local = true;
                if (kind == .anytype_type) {
                    tv.* = .{ .ty = a.ty };
                    continue;
                }
            }
            tv.* = .{ .ty = a.ty, .val = try ev.freeze(a) };
        }
        const inst = if (g) |gg|
            try infer.instanceOf(ev.r, ev.a, gg, fty, tvs)
        else
            try infer.runtimeInstance(ip, ev.a, fv, args.len);
        try ev.backwardBranch();
        // When tracking origins, expand the call within this evaluation: the result of a call
        // through a query is an interned value, which loses the origin of literals
        if (!local and ev.track == null) {
            // Call through a query once half of the native stack is used: the query engine
            // interrupts very deep recursion when the stack is nearly exhausted and computes it in
            // segments from where it was interrupted
            if (scalar and ev.r.ctx.stackUsed() < ev.r.ctx.stack_budget / 2) {
                // Aggregates and pointers passed to comptime parameters are interned (they
                // determine the instance): pass the interned values
                const scalar_args = try ev.a.dupe(Val, args);
                for (scalar_args, tvs) |*a, tv| if (a.v == .agg or a.v == .ref) {
                    a.* = thaw(tv);
                };
                return ev.scalarCall(.{ .file = fv.file, .item = fv.decl }, inst, scalar_args);
            }
            for (args, tvs) |a, *tv| if (a.v == .int) {
                tv.val = try ev.freeze(a);
            };
            const tv = try call(ev.r, inst, tvs, ev.quota);
            if (tv.val == null) return error.Abort;
            return thaw(tv);
        }
        return ev.runFunction(.{ .file = fv.file, .item = fv.decl }, inst, args);
    }

    /// A call whose arguments contain non-interned integers but no storage inside the interpreter:
    /// as with `CallEval`, it runs in a new interpreter (with its own memory and backward branch
    /// count, and the call site's quota), and the result is cached within this evaluation. The
    /// arguments are not interned, so repeated calls in a loop do not bloat the InternPool.
    fn scalarCall(ev: *Evaluator, owner: hir.OwnerKey, inst: Index, args: []const Val) EvalError!Val {
        _ = try if (ev.r.context) |c| ev.r.ctx.get(queries.ContextTarget, c) else ev.r.ctx.get(queries.TargetAbi, {});
        const memo = ev.calls orelse blk: {
            const gpa = ev.r.ctx.db.gpa;
            const m = try gpa.create(CallMemo);
            m.* = .{ .arena = .init(gpa) };
            ev.calls = m;
            ev.owns_calls = true;
            break :blk m;
        };
        // The key is built on the stack, so a hit uses none of the evaluation's memory (at most
        // 21 bytes per argument)
        var buf: [512]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const ka = if (8 + args.len * 21 <= buf.len) fba.allocator() else ev.a;
        var key: std.ArrayList(u8) = .empty;
        try key.appendSlice(ka, std.mem.asBytes(&[2]u32{ @backingInt(inst), ev.quota }));
        for (args) |a| {
            const ty: u32 = @backingInt(a.ty);
            try key.appendSlice(ka, std.mem.asBytes(&ty));
            switch (a.v) {
                .int => |x| {
                    try key.append(ka, 1);
                    try key.appendSlice(ka, std.mem.asBytes(&x));
                },
                .big => |b| {
                    const i: u32 = @backingInt(try value.internInt(ev.ip, ev.a, a.ty, b));
                    try key.append(ka, 2);
                    try key.appendSlice(ka, std.mem.asBytes(&i));
                },
                .ip => |x| {
                    const i: u32 = @backingInt(x);
                    try key.append(ka, 2);
                    try key.appendSlice(ka, std.mem.asBytes(&i));
                },
                .unknown => try key.append(ka, 3),
                .undef => try key.append(ka, 4),
                .agg, .ref => unreachable,
            }
        }
        if (memo.map.get(key.items)) |v| return if (v.v == .unknown) error.Abort else v;

        var scratch: std.heap.ArenaAllocator = .init(ev.r.ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ev.r.ctx, .arena = scratch.allocator() };
        var callee: Evaluator = .{ .r = &r, .ip = ev.ip, .a = scratch.allocator(), .arena = &scratch, .quota = ev.quota, .calls = memo };
        defer callee.deinit();
        const out: Val = blk: {
            const v = callee.runFunction(owner, inst, args) catch |err| switch (err) {
                error.Abort, error.Break, error.Continue, error.Return => break :blk .unknown,
                else => |e| return e,
            };
            // The result must not reference storage that is about to be freed: intern aggregates
            // and pointers
            break :blk switch (v.v) {
                .int, .ip, .undef, .unknown => v,
                .big, .agg, .ref => thaw(callee.toTyped(v) catch |err| switch (err) {
                    error.Abort, error.Break, error.Continue, error.Return => break :blk .unknown,
                    else => |e| return e,
                }),
            };
        };
        try memo.put(key.items, out);
        return if (out.v == .unknown) error.Abort else out;
    }

    /// Executes the function body in instance `inst`
    fn runFunction(ev: *Evaluator, owner: hir.OwnerKey, inst: Index, args: []const Val) EvalError!Val {
        const ip = ev.ip;
        const item = try ev.itemIndex(owner) orelse return error.Abort;
        const body = try ev.r.ctx.get(hir.ItemBody, owner);
        const sig = try ev.r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .signature, .inst = inst });
        const inst_key = ip.key(inst).instance;
        const inst_args = inst_key.args;
        var frame = try ev.newFrame(owner.file, item, body, inst);
        if (ev.stop) |s| if (s.frame == null) {
            s.frame = &frame;
        };
        for (body.params, 0..) |p, i| {
            const arg: Val = if (i < args.len) args[i] else .unknown;
            // The type of an anytype parameter is the type of the argument (also what the instance
            // records; for comptime anytype the instance records the argument's value, and its
            // type in `arg_types`)
            const binding = body.binding(p);
            const comptime_anytype = binding.ty == null and binding.is_comptime;
            const recorded = i < inst_args.len and inst_args[i] != .unknown and inst_args[i] != .runtime;
            const ty: Index = if (comptime_anytype)
                inst_key.argType(i)
            else if (binding.ty == null)
                (if (!recorded) arg.ty else inst_args[i])
            else if (@backingInt(p) < sig.bindings.len) sig.bindings[@backingInt(p)].ty else .unknown;
            // The type of a `CallEval` argument is taken from its value, which does not always give
            // back the argument type (a non-null optional is its payload): without a recorded type
            // the parameter is unknown
            if (comptime_anytype and ty == .unknown) {
                frame.slots[@backingInt(p)] = .unknown;
                continue;
            }
            frame.slots[@backingInt(p)] = try ev.copy(try ev.coerce(.{ .ty = if (arg.ty == .unknown) ty else arg.ty, .v = arg.v }, if (ty != .unknown) ty else null));
        }
        frame.ret_type = try queries.returnType(ev.r, owner, body, sig, inst);
        if (frame.ret_type == .unknown) frame.ret_type = null;
        const main = body.value orelse return error.Abort;
        _ = ev.eval(&frame, main, null) catch |err| switch (err) {
            error.Return => return ev.coerce(ev.jump_value, frame.ret_type),
            else => |e| return e,
        };
        // Execution reached the end of the function body: return void (coerced to an error union
        // when the return type is `E!void`)
        return ev.coerce(Val.void_val, frame.ret_type);
    }

    // ── Blocks and control flow ──────────────────────────────────────

    /// Target of break / continue: with a label, the block, loop, or switch of the same name;
    /// otherwise the innermost loop
    fn labelTarget(f: *Frame, label: ?[]const u8) ?usize {
        var i = f.labels.items.len;
        while (i > 0) {
            i -= 1;
            const l = f.labels.items[i];
            if (label) |name| {
                if (l.name != null and std.mem.eql(u8, l.name.?, name)) return i;
            } else if (l.kind == .loop) return i;
        }
        return null;
    }

    fn block(ev: *Evaluator, f: *Frame, blk: Body.Block, want: ?Index) EvalError!Val {
        const index = f.labels.items.len;
        try f.labels.append(ev.a, .{ .name = blk.label, .kind = .block, .want = want });
        defer f.labels.shrinkRetainingCapacity(index);
        var defers: std.ArrayList(Defer) = .empty;
        ev.statements(f, blk.stmts, &defers) catch |err| {
            // Run the defers when leaving the block (the value of break is already saved in
            // jump_value); errdefers run when the function returns an error
            const saved_value = ev.jump_value;
            const saved_target = ev.jump_target;
            const failing = err == error.Return and try ev.isErrorReturn(defers.items, saved_value);
            try ev.runDefers(f, defers.items, failing);
            ev.jump_value = saved_value;
            ev.jump_target = saved_target;
            if (err == error.Break and ev.jump_target == index) return ev.coerce(ev.jump_value, want);
            return err;
        };
        try ev.runDefers(f, defers.items, false);
        return Val.void_val;
    }

    /// A `defer` or `errdefer` statement whose block has been reached
    const Defer = struct { body: ExprId, on_error: bool };

    /// Whether the returned value `v` is an error (only decided when an errdefer depends on it)
    fn isErrorReturn(ev: *Evaluator, defers: []const Defer, v: Val) EvalError!bool {
        for (defers) |d| {
            if (!d.on_error) continue;
            if (v.v == .unknown or v.v == .undef) return error.Abort;
            const x = try ev.ipOf(v) orelse return false;
            return ev.ip.key(x) == .error_value;
        }
        return false;
    }

    fn runDefers(ev: *Evaluator, f: *Frame, defers: []const Defer, failing: bool) EvalError!void {
        var i = defers.len;
        while (i > 0) {
            i -= 1;
            if (defers[i].on_error and !failing) continue;
            _ = try ev.eval(f, defers[i].body, null);
        }
    }

    fn statements(ev: *Evaluator, f: *Frame, stmts: []const Body.Stmt, defers: *std.ArrayList(Defer)) EvalError!void {
        for (stmts) |s| switch (s.kind) {
            .expr => |x| _ = try ev.eval(f, x, null),
            .local => |bid| {
                const binding = f.body.binding(bid);
                const ty: ?Index = if (binding.ty) |t| try ev.evalType(f, t) else null;
                const init: Val = if (binding.init) |x| try ev.eval(f, x, ty) else .{ .ty = ty orelse .unknown, .v = .undef };
                f.slots[@backingInt(bid)] = try ev.copy(.{ .ty = ty orelse init.ty, .v = init.v });
                if (binding.kind == .local_var) try ev.cell_origins.put(ev.a, &f.slots[@backingInt(bid)], .variable);
                try ev.defined(f, bid);
            },
            .@"defer" => |x| try defers.append(ev.a, .{ .body = x, .on_error = false }),
            .@"errdefer" => |x| try defers.append(ev.a, .{ .body = x, .on_error = true }),
            .destructure => |d| {
                const v = try ev.eval(f, d.value, null);
                for (d.targets, 0..) |t, i| {
                    const elem = try ev.elemAt(v, i);
                    switch (t) {
                        .binding => |bid| {
                            const ty: ?Index = if (f.body.binding(bid).ty) |te| try ev.evalType(f, te) else null;
                            f.slots[@backingInt(bid)] = try ev.copy(try ev.coerce(elem, ty));
                            if (f.body.binding(bid).kind == .local_var) try ev.cell_origins.put(ev.a, &f.slots[@backingInt(bid)], .variable);
                            try ev.defined(f, bid);
                        },
                        .expr => |x| {
                            if (f.body.expr(x) == .name_ref and std.mem.eql(u8, f.body.expr(x).name_ref, "_")) continue;
                            try ev.store(try ev.place(f, x), elem);
                        },
                    }
                }
            },
        };
    }

    /// A statement of frame `f` has defined local `bid`: when it is where the evaluation stops
    /// (see `Stop`), keeps its value and ends the evaluation
    fn defined(ev: *Evaluator, f: *const Frame, bid: Body.BindingId) EvalError!void {
        const s = ev.stop orelse return;
        if (s.frame != f or s.binding != bid) return;
        const tv = try ev.toTyped(f.slots[@backingInt(bid)]);
        s.value = tv;
        return error.Abort;
    }

    const Condition = struct { yes: bool, payload: Val = .unknown };

    /// Condition of if / while: bool, optional (the payload when not null), error union (the
    /// payload on success, otherwise the error)
    fn condition(ev: *Evaluator, v: Val) EvalError!Condition {
        const ip = ev.ip;
        const x = try ev.ipOf(v);
        switch (ip.key(v.ty)) {
            .simple_type => |s| if (s == .bool) {
                if (x == .true_value) return .{ .yes = true };
                if (x == .false_value) return .{ .yes = false };
                return error.Abort;
            },
            .optional_type => |child| {
                const payload = try ev.unwrapOptional(v, child) orelse return .{ .yes = false };
                return .{ .yes = true, .payload = payload };
            },
            .error_union_type => |eu| {
                if (v.v == .unknown or v.v == .undef) return error.Abort;
                if (x != null and ip.key(x.?) == .error_value) return .{ .yes = false, .payload = Val.of(eu.err, x.?) };
                return .{ .yes = true, .payload = .{ .ty = eu.payload, .v = v.v } };
            },
            else => {},
        }
        return error.Abort;
    }

    fn bindCapture(ev: *Evaluator, f: *Frame, b: Body.BindingId, v: Val) EvalError!void {
        if (f.body.binding(b).is_ptr) return error.Abort;
        f.slots[@backingInt(b)] = try ev.copy(v);
    }

    /// `if (opt) |*x|`: x points to the payload of the optional. An optional is represented by its
    /// payload, so the pointer points to where the optional is (for reads see `deref`; writes are
    /// coerced back to an optional according to the type of the storage cell); when the condition
    /// is not a place, it points to a copy of the payload.
    fn bindPayloadPtr(ev: *Evaluator, f: *Frame, b: Body.BindingId, cond_e: ExprId, payload: Val) EvalError!void {
        var is_const = false;
        const ref = ev.place(f, cond_e) catch |err| switch (err) {
            error.Abort => blk: {
                is_const = true;
                const cell = try ev.a.create(Val);
                cell.* = try ev.copy(payload);
                break :blk Ref{ .cell = cell, .path = &.{} };
            },
            else => |x| return x,
        };
        f.slots[@backingInt(b)] = .{ .ty = try ev.ip.ptrTo(payload.ty, .one, is_const), .v = .{ .ref = ref } };
    }

    fn loop(ev: *Evaluator, f: *Frame, l: Body.Loop, want: ?Index) EvalError!Val {
        const index = f.labels.items.len;
        try f.labels.append(ev.a, .{ .name = l.label, .kind = .loop, .want = want });
        defer f.labels.shrinkRetainingCapacity(index);
        switch (l.kind) {
            .@"while" => while (true) {
                try ev.tick();
                const taken = try ev.condition(try ev.eval(f, l.inputs[0], null));
                if (!taken.yes) {
                    if (l.else_capture.len != 0) try ev.bindCapture(f, l.else_capture[0], taken.payload);
                    break;
                }
                if (l.capture.len != 0) try ev.bindCapture(f, l.capture[0], taken.payload);
                if (try ev.loopBody(f, l.body, index)) |v| return ev.coerce(v, want);
                if (l.cont) |c| _ = try ev.eval(f, c, null);
                // Going back to the condition is a backward branch (once per completed iteration)
                try ev.backwardBranch();
            },
            .@"for" => {
                const Input = union(enum) { range: i128, seq: Val };
                const inputs = try ev.a.alloc(Input, l.inputs.len);
                var n: ?usize = null;
                for (l.inputs, inputs) |x, *in| {
                    const len: ?usize = switch (f.body.expr(x)) {
                        // `a..b` / `a..`
                        .other => |range| blk: {
                            if (range.len == 0 or range.len > 2) return error.Abort;
                            const start = try ev.evalInt(f, range[0], .usize_type);
                            in.* = .{ .range = start };
                            if (range.len == 1) break :blk null;
                            const end = try ev.evalInt(f, range[1], .usize_type);
                            break :blk std.math.cast(usize, end - start) orelse return error.Abort;
                        },
                        else => blk: {
                            const v = try ev.eval(f, x, null);
                            // Unknown elements: the loop body cannot be executed
                            if (v.v == .unknown or v.v == .undef) return error.Abort;
                            in.* = .{ .seq = v };
                            break :blk try ev.elemCount(v) orelse return error.Abort;
                        },
                    };
                    if (len) |m| {
                        if (n != null and n.? != m) return error.Abort;
                        n = m;
                    }
                }
                for (0..n orelse return error.Abort) |i| {
                    try ev.tick();
                    try ev.backwardBranch();
                    for (inputs, 0..) |in, k| {
                        if (k >= l.capture.len) break;
                        const cap = l.capture[k];
                        const elem: Val = switch (in) {
                            .range => |start| Val.ofInt(.usize_type, start + @as(i128, @intCast(i))),
                            .seq => |v| if (f.body.binding(cap).is_ptr) try ev.elemRef(v, i) else try ev.elemAt(v, i),
                        };
                        f.slots[@backingInt(cap)] = try ev.copy(elem);
                    }
                    if (try ev.loopBody(f, l.body, index)) |v| return ev.coerce(v, want);
                }
            },
        }
        if (l.@"else") |el| return ev.eval(f, el, want);
        return Val.void_val;
    }

    /// Executes the loop body once: returns the value of a break to this loop, and continues on a
    /// continue to this loop
    fn loopBody(ev: *Evaluator, f: *Frame, body: ExprId, index: usize) EvalError!?Val {
        _ = ev.eval(f, body, null) catch |err| switch (err) {
            error.Break => if (ev.jump_target == index) return ev.jump_value else return err,
            error.Continue => if (ev.jump_target == index) return null else return err,
            else => |e| return e,
        };
        return null;
    }

    /// Pointer capture `|*x|`: a pointer to element `i` of the sequence
    fn elemRef(ev: *Evaluator, seq: Val, i: usize) EvalError!Val {
        const ref = switch (seq.v) {
            .ref => |r| r,
            else => return error.Abort,
        };
        // The element type comes from the containing aggregate, without taking out the range; the
        // place of a `*T` → `*[1]T` view is itself the element
        const child = if (ref.as_array) ev.elemTypeOf(seq.ty, i) else ev.elemTypeOf((try ev.loadPath(ref)).ty, if (ref.window) |w| w.start + i else i);
        const is_const = switch (ev.ip.key(seq.ty)) {
            .ptr_type => |p| p.is_const,
            else => false,
        };
        return .{ .ty = try ev.ip.ptrTo(child, .one, is_const), .v = .{ .ref = try ev.extend(ref, std.math.cast(u32, i) orelse return error.Abort) } };
    }

    fn switchExpr(ev: *Evaluator, f: *Frame, e: ExprId, s: @FieldType(Body.Expr, "switch"), want: ?Index) EvalError!Val {
        const index = f.labels.items.len;
        // Labeled switch: `continue :sw x` dispatches again with a new operand
        const label: ?[]const u8 = for (f.body.scopes) |sc| {
            if (sc.label) |lab| if (lab.expr == e) break lab.name;
        } else null;
        try f.labels.append(ev.a, .{ .name = label, .kind = .@"switch", .want = want });
        defer f.labels.shrinkRetainingCapacity(index);
        var operand = try ev.eval(f, s.operand, null);
        var first = true;
        while (true) {
            try ev.tick();
            // A labeled switch dispatched again by `continue :label`: a backward branch
            if (!first) try ev.backwardBranch();
            first = false;
            const chosen = try ev.chooseProng(f, s.prongs, operand) orelse return error.Abort;
            const prong = s.prongs[chosen];
            if (prong.capture.len > 0) try ev.bindCapture(f, prong.capture[0], try ev.switchPayload(operand));
            if (prong.capture.len > 1) f.slots[@backingInt(prong.capture[1])] = try ev.switchTag(operand);
            return ev.eval(f, prong.body, want) catch |err| switch (err) {
                error.Continue => if (ev.jump_target == index) {
                    operand = ev.jump_value;
                    continue;
                } else return err,
                error.Break => if (ev.jump_target == index) return ev.coerce(ev.jump_value, want) else return err,
                else => |x| return x,
            };
        }
    }

    fn chooseProng(ev: *Evaluator, f: *Frame, prongs: []const Body.Prong, operand: Val) EvalError!?usize {
        // Integer operands are not interned; they are compared with the prong items by value
        const v: ?Index = if (operand.v == .int) null else try ev.freeze(operand) orelse return error.Abort;
        var else_prong: ?usize = null;
        var under_prong: ?usize = null;
        // Prong items that cannot be evaluated: the values of prong items are all distinct
        // (duplicates are a compile error), so if another prong item equals the operand, this one
        // cannot also be equal; therefore keep searching. Only when none is equal is the result
        // undetermined (it must not fall back to else). For example:
        // `switch (T) { vector.T => .., Scalar => .. }`.
        var unknown = false;
        for (prongs, 0..) |prong, i| {
            if (prong.is_else) {
                else_prong = i;
                continue;
            }
            for (prong.items) |item| {
                if (f.body.isUnderscore(item)) {
                    under_prong = i;
                    continue;
                }
                const hit = ev.prongItemMatches(f, item, operand, v) catch |err| switch (err) {
                    error.Abort => {
                        unknown = true;
                        continue;
                    },
                    else => |x| return x,
                };
                if (hit) return i;
            }
        }
        if (unknown) return error.Abort;
        return otherProng(ev.ip, v, else_prong, under_prong);
    }

    fn prongItemMatches(ev: *Evaluator, f: *Frame, item: ExprId, operand: Val, v: ?Index) EvalError!bool {
        switch (f.body.expr(item)) {
            // `a...b`
            .other => |range| {
                if (range.len != 2) return error.Abort;
                const lo = try ev.eval(f, range[0], operand.ty);
                const hi = try ev.eval(f, range[1], operand.ty);
                const above = try ev.compareIntVals(.angle_bracket_right_equal, operand, lo) orelse return error.Abort;
                const below = try ev.compareIntVals(.angle_bracket_left_equal, operand, hi) orelse return error.Abort;
                return above and below;
            },
            else => {
                // The prong items of a union are tags
                const item_want: ?Index = if (ev.isUnion(operand.ty)) null else operand.ty;
                const item_v = try ev.eval(f, item, item_want);
                if (ev.intOf(operand)) |x| if (ev.intOf(item_v)) |y| return x == y;
                const iv = try ev.freeze(item_v) orelse return error.Abort;
                const ov = v orelse try ev.freeze(operand) orelse return error.Abort;
                return try eqlValues(ev.r, iv, ov) orelse return error.Abort;
            },
        }
    }

    fn switchPayload(ev: *Evaluator, operand: Val) EvalError!Val {
        if (operand.v == .int) return operand;
        const x = (try ev.ipOf(operand)) orelse return operand;
        return switch (ev.ip.key(x)) {
            .union_value => |u| Val.of(try ev.unionFieldType(operand.ty, u.tag), u.payload),
            else => operand,
        };
    }

    fn switchTag(ev: *Evaluator, operand: Val) EvalError!Val {
        if (operand.v == .int) return operand;
        const x = (try ev.ipOf(operand)) orelse return .unknown;
        return switch (ev.ip.key(x)) {
            .union_value => |u| blk: {
                const tag_ty = try ev.unionTagType(operand.ty) orelse break :blk Val.of(.enum_literal_type, try ev.ip.get(.{ .enum_literal = u.tag }));
                break :blk Val.of(tag_ty, try ev.ip.get(.{ .enum_tag = .{ .ty = tag_ty, .name = u.tag } }));
            },
            else => operand,
        };
    }

    // ── Operations ───────────────────────────────────────────────────

    fn binary(ev: *Evaluator, f: *Frame, op: SyntaxKind, lhs_e: ExprId, rhs_e: ExprId, want: ?Index) EvalError!Val {
        const ip = ev.ip;
        switch (op) {
            .keyword_and, .keyword_or => {
                const lhs = try ev.condition(try ev.eval(f, lhs_e, .bool_type));
                if (lhs.yes != (op == .keyword_and)) return boolVal(lhs.yes);
                return boolVal((try ev.condition(try ev.eval(f, rhs_e, .bool_type))).yes);
            },
            .keyword_orelse => {
                const lhs = try ev.eval(f, lhs_e, null);
                if (ip.key(lhs.ty) != .optional_type) return error.Abort;
                const c = try ev.condition(lhs);
                if (c.yes) return c.payload;
                // As with `catch`, the handler gets the result type of the whole expression
                return ev.eval(f, rhs_e, want);
            },
            .equal_equal, .bang_equal, .angle_bracket_left, .angle_bracket_right, .angle_bracket_left_equal, .angle_bracket_right_equal => {
                // Matching the compiler, the operands have no result type and are coerced to their
                // peer type: an enum literal to the other side's enum (by tag name, never as a
                // decl literal; a name that is not a tag is a compile error), a comptime number to
                // the other side's float type (rounding it). A tagged union compared with a tag
                // keeps the literal as it is.
                var lhs = try ev.eval(f, lhs_e, null);
                var rhs = try ev.eval(f, rhs_e, null);
                if (ev.peerOperand(lhs.ty, rhs.ty)) lhs = try ev.coerce(lhs, rhs.ty);
                if (ev.peerOperand(rhs.ty, lhs.ty)) rhs = try ev.coerce(rhs, lhs.ty);
                // Optionals of different depths are compared at the deeper one, their peer type:
                // a null `?u8` equals a `??u8` holding it
                switch (value.deeperOptional(ip, lhs.ty, rhs.ty)) {
                    .lhs => rhs = try ev.coerce(rhs, lhs.ty),
                    .rhs => lhs = try ev.coerce(lhs, rhs.ty),
                    .neither => {},
                }
                if ((op == .equal_equal or op == .bang_equal) and ip.key(lhs.ty) == .ptr_type and ip.key(rhs.ty) == .ptr_type) {
                    const eq = try ev.pointerEql(lhs, rhs) orelse return error.Abort;
                    return boolVal(eq == (op == .equal_equal));
                }
                if (ev.intOf(lhs)) |x| if (ev.intOf(rhs)) |y| return boolVal(value.compareInts(ip, op, lhs.ty, rhs.ty, x, y));
                if (lhs.v == .big or rhs.v == .big or value.isBigIntType(ip, lhs.ty) or value.isBigIntType(ip, rhs.ty)) {
                    if (try ev.bigOf(lhs)) |x| {
                        if (try ev.bigOf(rhs)) |y| return boolVal(compareBig(op, x, y));
                    }
                }
                const a = try ev.freeze(lhs) orelse return error.Abort;
                const b = try ev.freeze(rhs) orelse return error.Abort;
                if (value.intOf(ip, a)) |x| if (value.intOf(ip, b)) |y| return boolVal(value.compareInts(ip, op, value.typeOfValue(ip, a), value.typeOfValue(ip, b), x, y));
                if (ip.key(a) == .float_value or ip.key(b) == .float_value) if (value.floatOf(ip, a)) |x| if (value.floatOf(ip, b)) |y| return boolVal(compareNumbers(op, x, y));
                if (op != .equal_equal and op != .bang_equal) return error.Abort;
                const eq = try eqlValues(ev.r, a, b) orelse return error.Abort;
                return boolVal(eq == (op == .equal_equal));
            },
            .plus_plus => return ev.concat(try ev.eval(f, lhs_e, null), try ev.eval(f, rhs_e, null)),
            .pipe_pipe => {
                const a = try ev.evalType(f, lhs_e);
                const b = try ev.evalType(f, rhs_e);
                const x = try queries.errorSetMembers(ev.r, a) orelse return error.Abort;
                const y = try queries.errorSetMembers(ev.r, b) orelse return error.Abort;
                const names = try std.mem.concat(ev.a, []const u8, &.{ x, y });
                return Val.ofType(try ip.errorSet(ev.a, names));
            },
            else => {
                // Matching the compiler, the operands have no result type:
                // `const m: u8 = (0xFF << 4) >> 4` is computed as comptime_int and gives 255 when
                // coerced to u8. The exception is the right operand of `<<` / `>>`, which has the
                // result type `Log2Int(T)` of the left operand's type (`x >> @intCast(n)`); that
                // of `<<|` has none.
                const lhs = try ev.eval(f, lhs_e, null);
                const rhs_want: ?Index = if (op == .angle_bracket_angle_bracket_left or op == .angle_bracket_angle_bracket_right) try value.log2IntType(ip, lhs.ty) else null;
                const rhs = try ev.eval(f, rhs_e, rhs_want);
                return ev.arith(op, lhs, rhs);
            },
        }
    }

    /// Arithmetic, bitwise and shift operator `op` on evaluated operands: the binary expression
    /// `a op b`, and the operator of the compound assignment `a op= b`
    fn arith(ev: *Evaluator, op: SyntaxKind, lhs: Val, rhs: Val) EvalError!Val {
        const ip = ev.ip;
        const is_shift = op == .angle_bracket_angle_bracket_left or op == .angle_bracket_angle_bracket_right or op == .angle_bracket_angle_bracket_left_pipe;
        // Bitwise operations on bool
        if (lhs.ty == .bool_type and rhs.ty == .bool_type) {
            const x = (try ev.condition(lhs)).yes;
            const y = (try ev.condition(rhs)).yes;
            return boolVal(switch (op) {
                .ampersand => x and y,
                .pipe => x or y,
                .caret => x != y,
                else => return error.Abort,
            });
        }
        if (!is_shift and (ip.isFloat(lhs.ty) or ip.isFloat(rhs.ty))) {
            const ty = peerFloatType(ip, lhs.ty, rhs.ty) orelse return error.Abort;
            // Comptime operands are coerced (rounded) to the peer type first
            const x = ev.floatOf(try ev.coerce(lhs, ty)) orelse return error.Abort;
            const y = ev.floatOf(try ev.coerce(rhs, ty)) orelse return error.Abort;
            return Val.of(ty, try value.binaryFloat(ip, op, ty, x, y) orelse return error.Abort);
        }
        const ty = if (is_shift) lhs.ty else value.peerIntType(ip, lhs.ty, rhs.ty) orelse return error.Abort;
        if (ev.intOf(lhs)) |a| {
            if (ev.intOf(rhs)) |b| {
                if (value.binaryInt(ip, op, ty, a, b)) |r| return Val.ofInt(ty, r);
            }
        }
        // A comptime_int operand may not fit i128 (or the result may not), and types wider than
        // 128 bits are computed at arbitrary precision
        if (value.isBigIntType(ip, ty)) {
            const a = try ev.bigOf(lhs) orelse return error.Abort;
            const b = try ev.bigOf(rhs) orelse return error.Abort;
            const r = try value.binaryBig(ip, ev.a, op, ty, a, b) orelse return error.Abort;
            return Val.ofBig(ty, r);
        }
        return error.Abort;
    }

    /// Whether two comptime pointers are equal; null when it cannot be determined. As in the
    /// compiler, pointers are equal when they point to the same location of the same storage;
    /// what the storage of a cell is in the compiler is its `CellOrigin`. An interned pointer
    /// that records the declaration it points into is compared at that place (`basePlace`).
    /// Other interned constant data is distinguished by value (equal values are the same data,
    /// matching the compiler's deduplication of identical literals) and carries no other
    /// identity: compared with a pointer into a declaration or an anonymous constant, it is
    /// unequal only when its data cannot be stored at that location (`mayAlias`).
    fn pointerEql(ev: *Evaluator, a_in: Val, b_in: Val) EvalError!?bool {
        const a = try ev.withPlace(a_in);
        const b = try ev.withPlace(b_in);
        switch (a.v) {
            .ref => |x| switch (b.v) {
                .ref => |y| return ev.refEql(x, a, y, b),
                .ip => |y| return ev.refEqlInterned(x, y),
                else => return null,
            },
            .ip => |x| switch (b.v) {
                .ip => |y| return x == y,
                .ref => |y| return ev.refEqlInterned(y, x),
                else => return null,
            },
            else => return null,
        }
    }

    /// `p` as a reference to the place it records, when it is an interned pointer that records
    /// one (`basePlace`); `p` otherwise
    fn withPlace(ev: *Evaluator, p: Val) EvalError!Val {
        const r = try ev.basePlace(p) orelse return p;
        return .{ .ty = p.ty, .v = .{ .ref = r } };
    }

    fn cellOrigin(ev: *Evaluator, cell: *const Val) CellOrigin {
        return ev.cell_origins.get(cell) orelse .storage;
    }

    /// Pointers `a` (into `x`) and `b` (into `y`)
    fn refEql(ev: *Evaluator, x: Ref, a: Val, y: Ref, b: Val) EvalError!?bool {
        if (x.cell == y.cell) return samePlace(x, y);
        const ox = ev.cellOrigin(x.cell);
        const oy = ev.cellOrigin(y.cell);
        if (ox == .thread_local or oy == .thread_local) return null;
        if (ox == .copy) return ev.copyEql(a, y, oy);
        if (oy == .copy) return ev.copyEql(b, x, ox);
        if (ox.isAnonymous() and oy.isAnonymous()) {
            const eq = try ev.temporaryEql(x, y) orelse return null;
            // The alignment of an aligned constant is part of its identity
            if (eq and (ox == .aligned_constant or oy == .aligned_constant)) return null;
            return eq;
        }
        if (ox == .variable and oy.isAnonymous()) return if (try ev.hasBits(x)) false else null;
        if (oy == .variable and ox.isAnonymous()) return if (try ev.hasBits(y)) false else null;
        // Other storage of this evaluation (the result of an operation) may hold the same data
        // as an anonymous constant
        if (ox.isAnonymous() and oy == .storage) return ev.mayAliasPointer(x, b);
        if (oy.isAnonymous() and ox == .storage) return ev.mayAliasPointer(y, a);
        // Two `extern` declarations may name the same symbol
        if ((ox == .extern_decl and oy == .extern_decl) or (ox == .extern_decl and oy == .decl) or (ox == .decl and oy == .extern_decl)) return null;
        // Distinct storage of this evaluation, distinct declarations, or a declaration and
        // something that is not one
        return false;
    }

    /// Pointer `c` into a copy, and a pointer into `r`, a cell of origin `o`. The copy may be any
    /// storage outside this evaluation that holds the same data, but not storage this evaluation
    /// created: a variable (unless it has no bits) or the result of an operation.
    fn copyEql(ev: *Evaluator, c: Val, r: Ref, o: CellOrigin) EvalError!?bool {
        return switch (o) {
            .storage => false,
            .variable => if (try ev.hasBits(r)) false else null,
            else => ev.mayAliasPointer(r, c),
        };
    }

    /// Pointer into a storage cell `r` and interned pointer `q`
    fn refEqlInterned(ev: *Evaluator, r: Ref, q: Index) EvalError!?bool {
        switch (ev.cellOrigin(r.cell)) {
            .storage, .variable => return false,
            .thread_local => return null,
            .decl, .extern_decl, .temporary, .copy, .constant, .aligned_constant => {},
        }
        return if (try ev.mayAlias(r, q)) null else false;
    }

    /// Whether what `r` points to, and the cell it is in, are known to take memory
    fn hasBits(ev: *Evaluator, r: Ref) EvalError!bool {
        for ([_]Index{ r.cell.ty, (try ev.loadPath(r)).ty }) |t| {
            if (t == .unknown) return false;
            const l = try ev.typeLayout(t, 0) orelse return false;
            if (l.size == 0) return false;
        }
        return true;
    }

    /// Two pointers into the same storage cell: the same location when they take the same path
    /// and start at the same element; paths that part at some level reach different elements
    fn samePlace(x: Ref, y: Ref) ?bool {
        const n = @min(x.path.len, y.path.len);
        if (!std.mem.eql(u32, x.path[0..n], y.path[0..n])) return false;
        if (x.path.len != y.path.len) return null;
        const xs = if (x.window) |w| w.start else 0;
        const ys = if (y.window) |w| w.start else 0;
        // A `*T` → `*[1]T` view counts positions in units of the place, a pointer into the place
        // in units of its elements: only their starts are known to coincide
        if (x.as_array != y.as_array) return if (xs == 0 and ys == 0) true else null;
        return xs == ys;
    }

    /// Pointers into two anonymous constants: the same constant when the values (with their
    /// types) are the same. A value holding a pointer is not compared, since an interned pointer
    /// does not keep which storage it points to.
    fn temporaryEql(ev: *Evaluator, x: Ref, y: Ref) EvalError!?bool {
        if (x.cell.ty == .unknown or y.cell.ty == .unknown) return null;
        if (x.cell.ty != y.cell.ty) return false;
        if (!(try ev.sameValue(x.cell.*, y.cell.*) orelse return null)) return false;
        return samePlace(x, y);
    }

    /// Whether `x` and `y` are the same value: false when they are known to differ, null when
    /// that is not known or when they are equal but hold a pointer. Integers and aggregates are
    /// compared in place, element by element, so that comparing the values of constants does
    /// not intern them; other values are compared as interned values.
    fn sameValue(ev: *Evaluator, x: Val, y: Val) EvalError!?bool {
        if (x.ty == y.ty) switch (x.v) {
            .int => |a| if (y.v == .int) return a == y.v.int,
            .agg => |a| if (y.v == .agg and a.elems.len == y.v.agg.elems.len) {
                var eq: ?bool = true;
                for (a.elems, y.v.agg.elems) |ex, ey| {
                    const e = try ev.sameValue(ex, ey);
                    if (e == false) return false;
                    if (e == null) eq = null;
                }
                return eq;
            },
            else => {},
        };
        const vx = try ev.freeze(x) orelse return null;
        const vy = try ev.freeze(y) orelse return null;
        if (vx != vy) return if (try ev.differ(vx, vy)) false else null;
        return if (holdsPointer(ev.ip, vx)) null else true;
    }

    /// Pointer into a declaration, an anonymous constant or a copy `r`, and pointer `p` into
    /// storage that may hold the same data: unequal when what `p` points to cannot be where `r`
    /// points
    fn mayAliasPointer(ev: *Evaluator, r: Ref, p: Val) EvalError!?bool {
        const q = try ev.freeze(p) orelse return null;
        return if (try ev.mayAlias(r, q)) null else false;
    }

    /// Whether interned pointer `q` can point to where `r` points in a declaration, an anonymous
    /// constant or a copy: what `q` points to, and the sentinel its type places after its
    /// elements, must be what that storage holds from there on. A string literal
    /// (`*const [n:0]u8`) can thus never point into an array without that sentinel.
    fn mayAlias(ev: *Evaluator, r: Ref, q: Index) EvalError!bool {
        const ip = ev.ip;
        switch (ip.key(q)) {
            .aggregate, .bytes => {},
            .ptr_value => |p| {
                const x = try ev.freeze(try ev.load(r)) orelse return true;
                return !try ev.differ(x, p.pointee);
            },
            else => return true,
        }
        const q_ty = value.typeOfValue(ip, q);
        if (ip.key(q_ty) != .ptr_type) return true;
        const view = Val.of(q_ty, q);
        const len = try ev.elemCount(view) orelse return true;
        // A `*T` → `*[1]T` view holds the place as the only element of an array
        const base = if (r.as_array) try ev.load(.{ .cell = r.cell, .path = r.path, .as_array = true }) else try ev.loadPath(r);
        const start: usize = if (r.window) |w| w.start else 0;
        const n = try ev.elemCount(base) orelse return true;
        if (start + len > n) return false;
        if (ev.seqSentinel(q_ty)) |s| {
            const after = ev.elemAt(base, start + len) catch |err| switch (err) {
                error.Abort => return false,
                else => |e| return e,
            };
            if (try ev.freeze(after)) |x| if (try ev.differ(x, s)) return false;
        }
        for (0..len) |i| {
            const x = try ev.freeze(try ev.elemAt(base, start + i)) orelse continue;
            const y = try ev.freeze(try ev.elemAt(view, i)) orelse continue;
            if (try ev.differ(x, y)) return false;
        }
        return true;
    }

    /// Whether two interned values are known to be different values
    fn differ(ev: *Evaluator, x: Index, y: Index) EvalError!bool {
        if (x == y) return false;
        return try eqlValues(ev.r, x, y) == false;
    }

    /// Whether an interned value is or contains a pointer
    fn holdsPointer(ip: *InternPool, x: Index) bool {
        if (ip.key(value.typeOfValue(ip, x)) == .ptr_type) return true;
        return switch (ip.key(x)) {
            .ptr_value => true,
            .aggregate => |agg| for (agg.elems) |e| {
                if (holdsPointer(ip, e)) break true;
            } else false,
            .union_value => |u| holdsPointer(ip, u.payload),
            else => false,
        };
    }

    /// `++`: concatenation of arrays, strings, and tuples
    fn concat(ev: *Evaluator, lhs: Val, rhs: Val) EvalError!Val {
        const ip = ev.ip;
        if (lhs.v == .unknown or rhs.v == .unknown) return error.Abort;
        const n = try ev.elemCount(lhs) orelse return error.Abort;
        const m = try ev.elemCount(rhs) orelse return error.Abort;
        const total = std.math.add(usize, n, m) catch return error.Abort;
        const elems = try ev.allocElems(total);
        for (0..n) |i| elems[i] = try ev.elemAt(lhs, i);
        for (0..m) |i| elems[n + i] = try ev.elemAt(rhs, i);
        const lt = ev.arrayOf(lhs.ty);
        const rt = ev.arrayOf(rhs.ty);
        var ty: Index = undefined;
        if (ip.key(lt) == .array_type and ip.key(rt) == .array_type) {
            const la = ip.key(lt).array_type;
            const ra = ip.key(rt).array_type;
            const sentinel = concatSentinel(la.sentinel, ra.sentinel);
            const array = try ip.get(.{ .array_type = .{ .len = std.math.cast(u64, total) orelse return error.Abort, .child = la.child, .sentinel = sentinel } });
            // If either side is a pointer, the result is a pointer to an array (a string literal)
            ty = if (ip.key(lhs.ty) == .ptr_type or ip.key(rhs.ty) == .ptr_type) try ip.ptrTo(array, .one, true) else array;
        } else {
            const types = try ev.a.alloc(Index, total);
            for (elems, types) |e, *t| t.* = e.ty;
            ty = try ip.get(.{ .tuple_type = .{ .types = types, .values = try ev.comptimeFieldValues(elems) } });
        }
        // A pointer points to an anonymous constant holding the result (`uavRef` in
        // `Sema.zirArrayCat`). When both operands are interned, the result is interned as a string
        // literal is, so it is the same interned value as an equal literal and compares with
        // interned pointers as literals do. Otherwise it stays inside the interpreter in a
        // temporary cell: freezing the operands could copy what their pointers point to.
        if (ip.key(ty) == .ptr_type) {
            const array = ip.key(ty).ptr_type.child;
            interned: {
                if (lhs.v != .ip or rhs.v != .ip) break :interned;
                const frozen = try ev.a.alloc(Index, total);
                for (elems, frozen) |e, *o| o.* = try ev.freeze(e) orelse break :interned;
                // An empty string is `bytes` like the literal `""`
                const data = if (total == 0 and ip.key(array).array_type.child == .u8_type)
                    try ip.get(.{ .bytes = .{ .ty = array, .bytes = "" } })
                else
                    try ev.aggregate(array, frozen);
                return Val.of(ty, try ev.pointerTo(ty, data, null));
            }
            const p = try ev.pointerToNew(ty, try ev.makeAgg(array, elems));
            try ev.cell_origins.put(ev.a, p.v.ref.cell, .temporary);
            return p;
        }
        return ev.makeAgg(ty, elems);
    }

    /// Pointer to a new storage cell (holding `target`); the cell is reachable only through this
    /// pointer and its copies, so with a `*const` type it never changes
    fn pointerToNew(ev: *Evaluator, ptr_ty: Index, target: Val) Error!Val {
        const cell = try ev.a.create(Val);
        cell.* = target;
        const immutable = switch (ev.ip.key(ptr_ty)) {
            .ptr_type => |p| p.is_const,
            else => false,
        };
        return .{ .ty = ptr_ty, .v = .{ .ref = .{ .cell = cell, .path = &.{}, .immutable = immutable } } };
    }

    /// Array type: a pointer to an array yields the array it points to; a slice is treated as an
    /// array of its element type and known length
    fn arrayOf(ev: *Evaluator, t: Index) Index {
        return switch (ev.ip.key(t)) {
            .ptr_type => |p| if (p.size == .one) p.child else t,
            else => t,
        };
    }

    fn prefix(ev: *Evaluator, f: *Frame, op: SyntaxKind, operand_e: ExprId, want: ?Index) EvalError!Val {
        const ip = ev.ip;
        switch (op) {
            .bang => return boolVal(!(try ev.condition(try ev.eval(f, operand_e, .bool_type))).yes),
            .minus, .minus_percent, .tilde => {
                // Matches the compiler: the operand has no result type
                const v = try ev.eval(f, operand_e, null);
                if (op == .minus and ip.isFloat(v.ty)) {
                    const x = ev.floatOf(v) orelse return error.Abort;
                    return Val.of(v.ty, try value.floatValue(ip, v.ty, -x) orelse return error.Abort);
                }
                if (ev.intOf(v)) |a| {
                    if (switch (op) {
                        .tilde => value.bitNot(ip, v.ty, a),
                        else => value.negate(ip, v.ty, a, op == .minus_percent),
                    }) |r| return Val.ofInt(v.ty, r);
                }
                if (value.isBigIntType(ip, v.ty)) {
                    const a = try ev.bigOf(v) orelse return error.Abort;
                    const r = try value.unaryBig(ip, ev.a, op, v.ty, a) orelse return error.Abort;
                    return Val.ofBig(v.ty, r);
                }
                return error.Abort;
            },
            .ampersand => {
                // `&s.*` for a slice `s`: a single-item pointer to its array, with the constness
                // of the slice
                switch (f.body.expr(operand_e)) {
                    .deref => |x| {
                        const p = try ev.eval(f, x, null);
                        const pt = switch (ip.key(p.ty)) {
                            .ptr_type => |pt| pt,
                            else => return error.Abort,
                        };
                        if (pt.size == .slice) {
                            const arr = try ev.deref(p);
                            const ty = try ip.ptrTo(arr.ty, .one, pt.is_const);
                            if (try ev.pointerPlace(p)) |r| return .{ .ty = ty, .v = .{ .ref = r } };
                            return ev.pointerToNew(ty, arr);
                        }
                        // `&p.*` of a single-item pointer is `p` itself (`Sema.zirRefDeref`),
                        // once `p` is known to point to something
                        if (pt.size == .one) {
                            switch (p.v) {
                                .ref => |r| _ = try ev.loadPath(r),
                                .ip => |q| switch (ip.key(q)) {
                                    .ptr_value, .aggregate, .bytes => {},
                                    else => return error.Abort,
                                },
                                else => return error.Abort,
                            }
                            return p;
                        }
                        return ev.addressOf(f, operand_e, try ev.deref(p));
                    },
                    else => {},
                }
                if (try ev.addressPlace(f, operand_e)) |p| return p;
                // The operand takes the child of the result type, except `anyopaque`: the pointer
                // is coerced instead (the compiler's `coerce_ptr_elem_ty`)
                const child_want: ?Index = if (want) |w| switch (ip.key(w)) {
                    .ptr_type => |p| if (p.size == .one and p.child != .anyopaque_type) p.child else null,
                    else => null,
                } else null;
                return ev.addressOfValue(f, operand_e, try ev.addressOperand(f, operand_e, child_want));
            },
            .keyword_try => {
                const v = try ev.eval(f, operand_e, null);
                const c = try ev.condition(v);
                if (c.yes) return c.payload;
                // Return the error at comptime
                ev.jump_value = c.payload;
                return error.Return;
            },
            else => return error.Abort,
        }
    }

    /// Operand of `&` whose result type points to `want` (`Sema.zirCoercePtrElemTy`): a `T`
    /// referenced as the element of a `*[n]T` is not coerced to the array, the pointer is coerced
    /// instead (`*T` → `*[1]T`)
    fn addressOperand(ev: *Evaluator, f: *Frame, e: ExprId, want: ?Index) EvalError!Val {
        const t = want orelse return ev.eval(f, e, null);
        const elem = switch (ev.ip.key(t)) {
            .array_type => |a| a.child,
            else => return ev.eval(f, e, t),
        };
        try ev.tick();
        const v = try ev.evalInner(f, e, t);
        return if (v.ty == elem) v else ev.coerce(v, t);
    }

    /// `&x` where `v` is the value of x: a pointer to the storage x denotes (`addressPlace`),
    /// otherwise to a constant holding `v` (`addressOfValue`)
    fn addressOf(ev: *Evaluator, f: *Frame, e: ExprId, v: Val) EvalError!Val {
        if (try ev.addressPlace(f, e)) |p| return p;
        return ev.addressOfValue(f, e, v);
    }

    /// `&x` when x denotes storage: a local, a container-level declaration, or a field or element
    /// of one; null otherwise
    fn addressPlace(ev: *Evaluator, f: *Frame, e: ExprId) EvalError!?Val {
        const ref = ev.placeFor(f, e, .address) catch |err| switch (err) {
            error.Abort => return null,
            else => |x| return x,
        };
        const v = try ev.load(ref);
        // A function declaration, or a constant holding a function: the compiler takes the
        // address of the function's own declaration (`analyzeRef`, `analyzeNavRef`), so the
        // function is the pointer's identity
        if (ref.path.len == 0 and ref.is_const and ev.cellOrigin(ref.cell) != .extern_decl) if (try ev.functionPointer(v)) |p| return p;
        return .{ .ty = try ev.ip.ptrTo(v.ty, .one, ref.is_const), .v = .{ .ref = ref } };
    }

    /// `&x` when x is not storage: a pointer to a new constant cell holding `v`. A value that is
    /// not a place (`isTemporary`) is a temporary constant; other operands (a field reached
    /// through a pointer that records no place, a value captured from an enclosing function)
    /// copy storage whose place is not known here (`CellOrigin.copy`).
    fn addressOfValue(ev: *Evaluator, f: *Frame, e: ExprId, v: Val) EvalError!Val {
        const temporary = isTemporary(f.body, e);
        if (temporary or f.body.expr(e) == .name_ref) if (try ev.functionPointer(v)) |p| return p;
        const cell = try ev.a.create(Val);
        cell.* = try ev.copy(v);
        try ev.cell_origins.put(ev.a, cell, if (temporary) .temporary else .copy);
        return .{ .ty = try ev.ip.ptrTo(v.ty, .one, true), .v = .{ .ref = .{ .cell = cell, .path = &.{}, .is_const = true, .immutable = true } } };
    }

    /// Whether `&e` takes the address of a value that is not a place. A block, `if`, `switch`,
    /// `catch`, `orelse` or `@field` passes the address-of on to its operands in the compiler.
    fn isTemporary(body: *const Body, e: ExprId) bool {
        return switch (body.expr(e)) {
            .literal, .init, .call, .enum_literal, .error_value => true,
            .builtin_call => |b| !std.mem.eql(u8, b.name, "@field"),
            .binary => |b| b.op != .keyword_orelse,
            else => false,
        };
    }

    /// Pointer to function value `v` (`*const fn`), interned: the function is its identity, as
    /// two pointers to one function point to its single declaration. Null when `v` is not a
    /// function. The address of an `extern` function may be shared with other declarations of
    /// the same symbol, so it is not evaluated.
    fn functionPointer(ev: *Evaluator, v: Val) EvalError!?Val {
        const x = switch (v.v) {
            .ip => |x| x,
            else => return null,
        };
        const func = switch (ev.ip.key(x)) {
            .fn_value => |func| func,
            else => return null,
        };
        const item = try ev.itemIndex(.{ .file = func.file, .item = func.decl }) orelse return error.Abort;
        if ((try ev.r.itemTree(func.file)).items[item].flags.is_extern) return error.Abort;
        const ty = try ev.ip.ptrTo(v.ty, .one, true);
        return Val.of(ty, try ev.pointerTo(ty, x, null));
    }

    /// What a place is resolved for
    const PlaceUse = enum {
        /// An assignment target: storage of this evaluation only
        write,
        /// The operand of `&`: also the storage of container-level declarations (which comptime
        /// code cannot write)
        address,
    };

    /// Place of assignment targets
    fn place(ev: *Evaluator, f: *Frame, e: ExprId) EvalError!Ref {
        return ev.placeFor(f, e, .write);
    }

    fn placeFor(ev: *Evaluator, f: *Frame, e: ExprId, use: PlaceUse) EvalError!Ref {
        switch (f.body.expr(e)) {
            .name_ref => |name| {
                if (use == .address and !f.body.nameRefIsEscaped(e)) if (try infer.primitive(ev.ip, name) != null) return error.Abort;
                const def = try ev.r.resolveName(f.file, f.item, f.body, f.body.expr_scopes[@backingInt(e)], name) orelse return error.Abort;
                switch (def) {
                    .local => |l| if (l.file == f.file and l.item == f.item) return ev.localPlace(f, l.binding),
                    .item => |it| if (use == .address) return ev.declPlace(it.file, it.item, f.inst),
                    else => {},
                }
                return error.Abort;
            },
            .field_access => |fa| {
                const name = fa.field orelse return error.Abort;
                const base = ev.placeOrPointee(f, fa.lhs, use) catch |err| switch (err) {
                    // `@This().x`, `@import("m.zig").x`: evaluating the type has no effects
                    error.Abort => if (use == .address and isTypeBuiltin(f.body, fa.lhs)) return ev.memberPlace(try ev.eval(f, fa.lhs, null), name) else return err,
                    else => return err,
                };
                const target = try ev.load(base);
                if (use == .address and target.ty == .type_type) return ev.memberPlace(target, name);
                const i = try ev.fieldIndex(target.ty, name) orelse return error.Abort;
                return ev.extend(base, @intCast(i));
            },
            .index => |x| {
                const base = try ev.placeOrPointee(f, x.lhs, use);
                const i = try ev.evalInt(f, x.index, .usize_type);
                return ev.extend(base, std.math.cast(u32, i) orelse return error.Abort);
            },
            .deref => |x| {
                const p = try ev.eval(f, x, null);
                return switch (p.v) {
                    .ref => |r| ev.through(r, p.ty),
                    // Declarations are not assignment targets
                    else => if (use == .address) try ev.basePlace(p) orelse error.Abort else error.Abort,
                };
            },
            .@"comptime" => |x| return ev.placeFor(f, x, use),
            else => return error.Abort,
        }
    }

    fn isTypeBuiltin(body: *const Body, e: ExprId) bool {
        return switch (body.expr(e)) {
            .builtin_call => |b| std.mem.eql(u8, b.name, "@This") or std.mem.eql(u8, b.name, "@import"),
            else => false,
        };
    }

    /// Place; when its value is a pointer to storage of this evaluation, or for `&` to a place an
    /// interned pointer records (`basePlace`), the place it points to instead (automatic
    /// dereferencing)
    fn placeOrPointee(ev: *Evaluator, f: *Frame, e: ExprId, use: PlaceUse) EvalError!Ref {
        const ref = try ev.placeFor(f, e, use);
        // The value of a range, or of a `*T` → `*[1]T` view, is an array, not a pointer
        if (ref.window != null or ref.as_array) return ref;
        const v = try ev.load(ref);
        switch (v.v) {
            .ref => |r| return ev.through(r, v.ty),
            else => {},
        }
        if (use == .address) if (try ev.basePlace(v)) |r| return r;
        // A pointer that records no place, held by a declaration, a temporary or a copy, points to
        // storage outside it, whose identity is not known here. A local holding an interned
        // pointer is the base itself (element paths are taken through the pointer, see `elemAt`).
        return if (use == .address and ev.ip.key(v.ty) == .ptr_type and switch (ev.cellOrigin(ref.cell)) {
            .decl, .extern_decl, .thread_local, .temporary, .copy => true,
            .storage, .variable, .constant, .aligned_constant => false,
        }) error.Abort else ref;
    }

    /// The storage of local `b`: a variable is storage of this evaluation, and pointers to a
    /// constant point to its anonymous constant (`constantCell`)
    fn localPlace(ev: *Evaluator, f: *Frame, b: Body.BindingId) EvalError!Ref {
        if (f.body.binding(b).kind == .local_var) return .{ .cell = &f.slots[@backingInt(b)], .path = &.{} };
        return .{ .cell = try ev.constantCell(f, b), .path = &.{}, .is_const = true, .immutable = true };
    }

    /// The anonymous constant that pointers to constant binding `b` (a constant local, a
    /// parameter, or a capture) point to. In the compiler, `&` of a comptime-known constant is
    /// `analyzeRef` of its value, and a constant initialized through a result pointer becomes an
    /// anonymous constant as well (`resolveComptimeKnownAllocPtr`), so constants with equal
    /// values are one constant, the same as a temporary with that value. Each execution of the
    /// binding has its own cell: pointers taken in an earlier iteration of a loop keep pointing
    /// to the value of that iteration.
    fn constantCell(ev: *Evaluator, f: *Frame, b: Body.BindingId) EvalError!*Val {
        const slot = &f.slots[@backingInt(b)];
        const gop = try ev.constant_cells.getOrPut(ev.a, slot);
        if (gop.found_existing and sameRepr(gop.value_ptr.value, slot.*)) return gop.value_ptr.cell;
        const cell = try ev.a.create(Val);
        cell.* = slot.*;
        gop.value_ptr.* = .{ .value = slot.*, .cell = cell };
        try ev.cell_origins.put(ev.a, cell, if (f.body.binding(b).@"align" != null) .aligned_constant else .constant);
        return cell;
    }

    /// Whether `x` and `y` are the same representation of one value. Aggregates are compared by
    /// identity: a binding executed again holds a new copy.
    fn sameRepr(x: Val, y: Val) bool {
        if (x.ty != y.ty) return false;
        return switch (x.v) {
            .unknown => y.v == .unknown,
            .undef => y.v == .undef,
            .ip => |a| y.v == .ip and y.v.ip == a,
            .int => |a| y.v == .int and y.v.int == a,
            .big => |a| y.v == .big and a.eql(y.v.big),
            .agg => |a| y.v == .agg and y.v.agg == a,
            .ref => |a| y.v == .ref and a.cell == y.v.ref.cell and std.mem.eql(u32, a.path, y.v.ref.path) and std.meta.eql(a.window, y.v.ref.window) and a.as_array == y.v.ref.as_array,
        };
    }

    /// The storage of container-level declaration `item` (in instance context `inst`): one cell
    /// per declaration in this evaluation, holding its value. Not a place when the declaration
    /// is not a constant, variable or function. The cell never changes (`store` aborts on it), and
    /// its value is interned, so it holds no pointer to storage that can change: as in the
    /// compiler (`Value.canMutateComptimeVarState` of a `nav` pointer), a call passed a pointer
    /// into it may be memoized.
    fn declPlace(ev: *Evaluator, file: FileId, item: u32, inst: ?Index) EvalError!Ref {
        const it = (try ev.r.itemTree(file)).items[item];
        switch (it.kind) {
            .@"const", .@"var", .@"fn" => {},
            else => return error.Abort,
        }
        const key: DeclKey = .{ .file = file, .item = item, .inst = try queries.declInst(ev.r, file, item, inst) };
        const cell = ev.decl_cells.get(key) orelse cell: {
            // Computed before the cell is registered: tracking may evaluate the declaration's
            // initializer, which may take addresses of declarations itself
            const v = try ev.declValue(.{ .item = .{ .file = file, .item = item } }, inst);
            const gop = try ev.decl_cells.getOrPut(ev.a, key);
            if (gop.found_existing) break :cell gop.value_ptr.*;
            const cell = try ev.a.create(Val);
            cell.* = v;
            gop.value_ptr.* = cell;
            const origin: CellOrigin = if (it.flags.is_threadlocal) .thread_local else if (it.flags.is_extern) .extern_decl else .decl;
            try ev.cell_origins.put(ev.a, cell, origin);
            try ev.cell_decls.put(ev.a, cell, key);
            break :cell cell;
        };
        return .{ .cell = cell, .path = &.{}, .is_const = true, .immutable = true };
    }

    /// `T.x`: the storage of declaration x of container type `t`
    fn memberPlace(ev: *Evaluator, t: Val, name: []const u8) EvalError!Ref {
        const ty = try ev.ipOf(t) orelse return error.Abort;
        if (ev.ip.key(ty) != .container_type) return error.Abort;
        const ns = try queries.namespaceOfType(ev.r, ty) orelse return error.Abort;
        const def = try ev.r.memberDef(ns, name) orelse return error.Abort;
        return switch (def) {
            .item => |it| ev.declPlace(it.file, it.item, queries.instOfType(ev.ip, ty)),
            else => error.Abort,
        };
    }

    /// The place a pointer of type `ptr_ty` points to: writable as the pointer allows
    fn through(ev: *Evaluator, r: Ref, ptr_ty: Index) Ref {
        var out = r;
        out.is_const = switch (ev.ip.key(ptr_ty)) {
            .ptr_type => |p| p.is_const,
            else => r.is_const,
        };
        return out;
    }

    /// Place of element `i`; for a range, the index is relative to the start of the range
    fn extend(ev: *Evaluator, base: Ref, i: u32) EvalError!Ref {
        const index = if (base.window) |w| blk: {
            if (i >= w.len) return error.Abort;
            break :blk w.start + i;
        } else i;
        // `*T` → `*[1]T`: element 0 is the place itself
        if (base.as_array) return if (index == 0) .{ .cell = base.cell, .path = base.path, .is_const = base.is_const, .immutable = base.immutable } else error.Abort;
        const path = try ev.a.alloc(u32, base.path.len + 1);
        @memcpy(path[0..base.path.len], base.path);
        path[base.path.len] = index;
        return .{ .cell = base.cell, .path = path, .is_const = base.is_const, .immutable = base.immutable };
    }

    fn assign(ev: *Evaluator, f: *Frame, op: SyntaxKind, lhs_e: ExprId, rhs_e: ExprId) EvalError!void {
        // `_ = x`
        if (f.body.expr(lhs_e) == .name_ref and std.mem.eql(u8, f.body.expr(lhs_e).name_ref, "_")) {
            _ = try ev.eval(f, rhs_e, null);
            return;
        }
        switch (f.body.expr(lhs_e)) {
            .field_access => |fa| if (fa.field != null and std.mem.eql(u8, fa.field.?, "len")) {
                if (try ev.assignSliceLen(f, op, fa.lhs, rhs_e)) return;
            },
            else => {},
        }
        var ref: Ref = undefined;
        var old: Val = undefined;
        switch (f.body.expr(lhs_e)) {
            // `p.* = x`: read the old value through the pointer; a pointer to the payload of an
            // optional (`if (opt) |*x|`) reads it as the payload type
            .deref => |x| {
                const p = try ev.eval(f, x, null);
                ref = switch (p.v) {
                    .ref => |r| r,
                    else => return error.Abort,
                };
                old = try ev.deref(p);
            },
            // `r.? *= 10` (std.fmt's Parser.number): the payload of a non-null optional, written
            // back as the optional
            .unwrap_optional => |x| {
                ref = try ev.place(f, x);
                const opt = try ev.load(ref);
                const child = switch (ev.ip.key(opt.ty)) {
                    .optional_type => |c| c,
                    else => return error.Abort,
                };
                old = try ev.unwrapOptional(opt, child) orelse return error.Abort;
            },
            else => {
                ref = try ev.place(f, lhs_e);
                old = try ev.load(ref);
            },
        }
        const rhs_want: ?Index = if (old.ty != .unknown) old.ty else null;
        if (op == .equal) return ev.store(ref, try ev.eval(f, rhs_e, rhs_want));
        // Compound assignment `a op= b`: as in the compiler (`AstGen.assignOp`), the old value and
        // the right operand go through the operator of `a op b`, and the result is stored (and
        // coerced to the type of `a`)
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
            else => return error.Abort,
        };
        // Matching the compiler, the right operand of `<<=` / `>>=` has the result type
        // `Log2Int(T)`, and that of `<<|=` has none
        const rhs = try ev.eval(f, rhs_e, switch (bin) {
            .angle_bracket_angle_bracket_left, .angle_bracket_angle_bracket_right => try value.log2IntType(ev.ip, old.ty),
            .angle_bracket_angle_bracket_left_pipe => null,
            else => ev.compoundRhsType(bin, rhs_want),
        });
        try ev.store(ref, try ev.arith(bin, old, rhs));
    }

    /// Result type of the right operand of the compound assignment with operator `bin` to a place
    /// of type `t` (`Sema.zirInplaceArithResultTy`): the type of the place, except that `+=` on a
    /// many-item or C pointer adds a `usize`, and `-=` on one subtracts either an integer or a
    /// pointer, so its right operand has no result type
    fn compoundRhsType(ev: *Evaluator, bin: SyntaxKind, t: ?Index) ?Index {
        if (bin == .plus or bin == .minus) if (t) |ty| switch (ev.ip.key(ty)) {
            .ptr_type => |p| if (p.size == .many or p.size == .c) return if (bin == .plus) .usize_type else null,
            else => {},
        };
        return t;
    }

    /// Modifies the `len` of a slice (`list.items.len += 1`): when the slice points to storage
    /// inside the interpreter, adjusts the length of the range, which must not exceed the
    /// containing array. Returns false when the slice is not in storage inside the interpreter.
    fn assignSliceLen(ev: *Evaluator, f: *Frame, op: SyntaxKind, slice_e: ExprId, rhs_e: ExprId) EvalError!bool {
        const ip = ev.ip;
        const ref = ev.place(f, slice_e) catch |err| switch (err) {
            error.Abort => return false,
            else => return err,
        };
        const s = try ev.load(ref);
        switch (ip.key(s.ty)) {
            .ptr_type => |p| if (p.size != .slice) return false,
            else => return false,
        }
        const r = switch (s.v) {
            .ref => |r| r,
            else => return false,
        };
        // A `*T` → `*[1]T` view without a range covers its only element
        const w: Ref.Window = r.window orelse if (r.as_array) .{ .start = 0, .len = 1 } else return false;
        const rhs = try ev.evalInt(f, rhs_e, .usize_type);
        const len: i128 = switch (op) {
            .equal => rhs,
            .plus_equal => @as(i128, w.len) + rhs,
            .minus_equal => @as(i128, w.len) - rhs,
            else => return error.Abort,
        };
        const n = if (r.as_array) 1 else try ev.elemCount(try ev.load(.{ .cell = r.cell, .path = r.path })) orelse return error.Abort;
        if (len < 0 or w.start + len > n) return error.Abort;
        try ev.store(ref, .{ .ty = s.ty, .v = .{ .ref = .{ .cell = r.cell, .path = r.path, .window = .{ .start = w.start, .len = @intCast(len) }, .as_array = r.as_array, .immutable = r.immutable } } });
        return true;
    }

    fn deref(ev: *Evaluator, p: Val) EvalError!Val {
        const ip = ev.ip;
        const child = ev.pointeeType(p.ty);
        switch (p.v) {
            .ref => |r| {
                // `*T` → `*[1]T`: the elements are read as the pointer's element type
                if (r.as_array) {
                    const elems = try ev.viewElems(p, r);
                    return ev.makeAgg(try ev.derefType(p.ty, elems.len), elems);
                }
                return ev.readAs(try ev.load(r), child);
            },
            .ip => |x| switch (ip.key(x)) {
                .ptr_value => |pv| return Val.of(child, pv.pointee),
                // Array pointers and slices are represented by their elements; dereferencing
                // yields the array (for a slice, `[len:sentinel]T`)
                .aggregate => |agg| {
                    const t = try ev.derefType(p.ty, agg.elems.len);
                    return Val.of(t, try ip.get(.{ .aggregate = .{ .ty = t, .elems = agg.elems } }));
                },
                .bytes => |b| {
                    const t = try ev.derefType(p.ty, b.bytes.len);
                    return Val.of(t, try ip.get(.{ .bytes = .{ .ty = t, .bytes = b.bytes } }));
                },
                else => return error.Abort,
            },
            else => return error.Abort,
        }
    }

    /// Type of `p.*` for a pointer of type `t` to `len` elements: the child type, and for a slice
    /// the array `[len:sentinel]T`
    fn derefType(ev: *Evaluator, t: Index, len: usize) Error!Index {
        return switch (ev.ip.key(t)) {
            .ptr_type => |p| if (p.size == .slice) try ev.ip.get(.{ .array_type = .{ .len = len, .child = p.child, .sentinel = p.sentinel } }) else p.child,
            else => .unknown,
        };
    }

    fn slice(ev: *Evaluator, f: *Frame, s: @FieldType(Body.Expr, "slice")) EvalError!Val {
        const ip = ev.ip;
        const base = try ev.eval(f, s.lhs, null);
        // Do not expand the elements when the value is unknown
        if (base.v == .unknown) return error.Abort;
        const start = std.math.cast(usize, try ev.evalInt(f, s.start, .usize_type)) orelse return error.Abort;
        const count = try ev.elemCount(base) orelse return error.Abort;
        const end = if (s.end) |e| std.math.cast(usize, try ev.evalInt(f, e, .usize_type)) orelse return error.Abort else count;
        if (start > end or end > count) return error.Abort;
        const child = ev.elemTypeOf(base.ty, 0);
        const is_const = switch (ip.key(base.ty)) {
            .ptr_type => |p| p.is_const,
            else => true,
        };
        // Consistent with the inference path: an explicit sentinel takes precedence; slicing to
        // the end keeps the sentinel of the source array
        const src_sentinel = ev.seqSentinel(base.ty);
        const explicit: ?Index = if (s.sentinel) |se| blk: {
            const v = try ev.eval(f, se, child);
            break :blk try ev.freeze(v) orelse return error.Abort;
        } else null;
        const sentinel: ?Index = if (explicit) |x| x else if (end == count) src_sentinel else null;
        // Range known at comptime: a pointer to an array
        const array = try ip.get(.{ .array_type = .{ .len = end - start, .child = child, .sentinel = sentinel } });
        const ptr_ty = try ip.ptrTo(array, .one, is_const);
        // Slicing storage of a local variable (or reached through a pointer): reference a range of
        // the original storage, so writes are reflected in the original array
        if (try ev.sliceTarget(f, s.lhs, base)) |target| {
            const offset = if (target.window) |tw| tw.start else 0;
            var ref = target;
            ref.window = .{ .start = std.math.cast(u32, offset + start) orelse return error.Abort, .len = std.math.cast(u32, end - start) orelse return error.Abort };
            return .{ .ty = ptr_ty, .v = .{ .ref = ref } };
        }
        // Otherwise (interned constants, etc.): the elements are copies and are not interned. A
        // pointer that records no place points to storage that is not known here.
        const elems = try ev.allocElems(end - start);
        for (elems, start..) |*o, i| o.* = try ev.elemAt(base, i);
        const p = try ev.pointerToNew(ptr_ty, try ev.makeAgg(array, elems));
        if (ev.ip.key(base.ty) == .ptr_type) try ev.cell_origins.put(ev.a, p.v.ref.cell, .copy);
        return p;
    }

    /// Storage being sliced: the storage the pointer points to (or the place an interned pointer
    /// records), or the array itself, a local variable or a container-level declaration (slicing
    /// takes its address in the compiler); null when there is no storage to reference
    fn sliceTarget(ev: *Evaluator, f: *Frame, lhs: ExprId, base: Val) EvalError!?Ref {
        if (try ev.pointerPlace(base)) |r| return r;
        if (ev.ip.key(base.ty) != .array_type) return null;
        return ev.placeFor(f, lhs, .address) catch |err| switch (err) {
            error.Abort => null,
            else => |x| x,
        };
    }

    // ── Initialization ───────────────────────────────────────────────

    fn initExpr(ev: *Evaluator, f: *Frame, ty_e: ?ExprId, fields: []const Body.FieldInit, want: ?Index) EvalError!Val {
        const ip = ev.ip;
        var t: ?Index = want;
        if (ty_e) |te| t = switch (f.body.expr(te)) {
            // `[_]T{ ... }`
            .array_type => |arr| if (f.body.expr(arr.len) == .name_ref and std.mem.eql(u8, f.body.expr(arr.len).name_ref, "_")) blk: {
                const child = try ev.evalType(f, arr.child);
                const sentinel = if (arr.sentinel) |x| try ev.freeze(try ev.eval(f, x, child)) orelse return error.Abort else null;
                break :blk try ip.get(.{ .array_type = .{ .len = fields.len, .child = child, .sentinel = sentinel } });
            } else try ev.evalType(f, te),
            else => try ev.evalType(f, te),
        };
        const target = t orelse return ev.anonInit(f, fields);
        switch (ip.key(target)) {
            .optional_type => |child| {
                const inner = try ev.initExpr(f, null, fields, child);
                return ev.wrapOptional(target, inner);
            },
            .error_union_type => |eu| {
                const inner = try ev.initExpr(f, null, fields, eu.payload);
                return .{ .ty = target, .v = inner.v };
            },
            .array_type, .vector_type, .tuple_type => {
                if (try ev.typeElemCount(target)) |n| if (n != fields.len) return error.Abort;
                const elems = try ev.a.alloc(Val, fields.len);
                for (fields, elems, 0..) |fl, *o, i| o.* = try ev.copy(try ev.eval(f, fl.value, ev.elemTypeOf(target, i)));
                return ev.makeAgg(target, elems);
            },
            .container_type, .reified_type, .anon_struct_type => {
                if (ev.isUnion(target)) {
                    if (fields.len != 1) return error.Abort;
                    const name = fields[0].name orelse return error.Abort;
                    const payload = try ev.eval(f, fields[0].value, try ev.unionFieldType(target, name));
                    return Val.of(target, try ip.get(.{ .union_value = .{ .ty = target, .tag = name, .payload = try ev.freeze(payload) orelse return error.Abort } }));
                }
                const decl = try ev.fieldsOf(target) orelse return error.Abort;
                const elems = try ev.a.alloc(Val, decl.len);
                for (decl, elems) |d, *o| {
                    o.* = for (fields) |fl| {
                        if (fl.name != null and std.mem.eql(u8, fl.name.?, d.name)) break try ev.copy(try ev.eval(f, fl.value, d.ty));
                    } else try ev.fieldDefault(target, d);
                }
                // Fields that do not exist
                for (fields) |fl| if ((fl.name == null and ip.key(target) != .tuple_type) or (fl.name != null and try ev.fieldIndex(target, fl.name.?) == null)) return error.Abort;
                return ev.makeAgg(target, elems);
            },
            else => return error.Abort,
        }
    }

    /// `.{ ... }` without a result type: a tuple or an anonymous struct
    fn anonInit(ev: *Evaluator, f: *Frame, fields: []const Body.FieldInit) EvalError!Val {
        const ip = ev.ip;
        const elems = try ev.a.alloc(Val, fields.len);
        const types = try ev.a.alloc(Index, fields.len);
        for (fields, elems, types) |fl, *o, *t| {
            o.* = try ev.copy(try ev.eval(f, fl.value, null));
            t.* = o.ty;
        }
        const named = fields.len > 0 and fields[0].name != null;
        const values = try ev.comptimeFieldValues(elems);
        const ty = if (named) blk: {
            const names = try ev.a.alloc([]const u8, fields.len);
            for (fields, names) |fl, *n| n.* = fl.name orelse return error.Abort;
            break :blk try ip.get(.{ .anon_struct_type = .{ .names = names, .types = types, .values = values } });
        } else try ip.get(.{ .tuple_type = .{ .types = types, .values = values } });
        return ev.makeAgg(ty, elems);
    }

    /// Tuples and anonymous structs constructed in the interpreter: all values are evaluated at
    /// comptime and all fields are comptime fields (matching the compiler)
    fn comptimeFieldValues(ev: *Evaluator, elems: []const Val) EvalError![]const Index {
        const values = try ev.a.alloc(Index, elems.len);
        for (elems, values) |e, *v| v.* = ev.freeze(e) catch |err| switch (err) {
            error.Abort => .unknown,
            else => |x| return x,
        } orelse .unknown;
        return values;
    }

    fn makeAgg(ev: *Evaluator, ty: Index, elems: []Val) Error!Val {
        const agg = try ev.a.create(Agg);
        agg.* = .{ .elems = elems };
        return .{ .ty = ty, .v = .{ .agg = agg } };
    }

    fn isUnion(ev: *Evaluator, t: Index) bool {
        return switch (ev.ip.key(t)) {
            .container_type => |c| c.kind == .@"union",
            .reified_type => |rt| rt.kind == .@"union",
            else => false,
        };
    }

    /// Whether a comparison operand of type `t` is coerced to the other operand's type `other` by
    /// peer type resolution: an enum literal compared with an enum (or an optional enum), and a
    /// comptime number compared with a float
    fn peerOperand(ev: *Evaluator, t: Index, other: Index) bool {
        if (other == .unknown or other == t) return false;
        return switch (t) {
            .enum_literal_type => other != .enum_literal_type and !ev.isUnion(other),
            .comptime_int_type, .comptime_float_type => ev.ip.isFloat(other),
            else => false,
        };
    }

    // ── Coercion ─────────────────────────────────────────────────────

    /// Coerces to the result type
    fn coerce(ev: *Evaluator, v: Val, want: ?Index) EvalError!Val {
        var out = try ev.coerceValue(v, want);
        // The origin of a byte is kept through coercion (`u8` → `?u8`, `comptime_int` → `u8`):
        // the value is unchanged
        if (v.origin != 0 and out.origin == 0) if (ev.intOf(v)) |a| if (ev.intOf(out)) |b| if (a == b) {
            out.origin = v.origin;
        };
        return out;
    }

    fn coerceValue(ev: *Evaluator, v: Val, want: ?Index) EvalError!Val {
        const t = want orelse return v;
        if (t == .unknown or v.ty == t) return v;
        const ip = ev.ip;
        if (v.v == .undef) return .{ .ty = t, .v = .undef };
        switch (ip.key(t)) {
            .optional_type => |child| {
                if (v.v == .unknown) return .{ .ty = t };
                // `null` itself, or an optional that coerces in memory (`?*T` to `?*const T`),
                // keeps its null; other values become the payload (`?u8` to `??u8`, where a
                // null becomes a non-null optional with a null payload)
                const route = value.optionalCoercion(ip, v.ty, t) orelse if (ev.isNullRepr(v)) return error.Abort else .wrap;
                const payload: Val = switch (route) {
                    .wrap => v,
                    .keep => switch (ip.key(v.ty)) {
                        .optional_type => |c| try ev.unwrapOptional(v, c) orelse return Val.of(t, .null_value),
                        else => if (v.is(.null_value)) return Val.of(t, .null_value) else v,
                    },
                };
                return ev.wrapOptional(t, try ev.coerce(payload, child));
            },
            .error_union_type => |eu| {
                if (v.v == .ip and ip.key(v.v.ip) == .error_value) return Val.of(t, v.v.ip);
                // An error union coerced to another one (`E!?u8` to `anyerror!?u8`) has its
                // payload coerced; any other value is the payload
                const payload: Val = switch (ip.key(v.ty)) {
                    .error_union_type => |from| .{ .ty = from.payload, .v = v.v },
                    else => v,
                };
                const inner = try ev.coerce(payload, eu.payload);
                return .{ .ty = t, .v = inner.v };
            },
            else => {},
        }
        if (v.v == .int) {
            if (ip.isInt(t)) return try ev.convertInt(v.ty, t, v.v.int) orelse error.Abort;
            // Coercion to floats, enums, etc.: coerce the interned value
            return ev.coerceValue(Val.of(v.ty, (try ev.ipOf(v)).?), want);
        }
        if (v.v == .big) return ev.coerceValue(Val.of(v.ty, try value.internInt(ip, ev.a, v.ty, v.v.big)), want);
        switch (v.v) {
            .ip => |x| switch (ip.key(x)) {
                .int_value, .enum_literal => {
                    // Integer out of range, not an enum member, etc.: compile error
                    const cx = try value.coerceValue(ip, x, t) orelse return error.Abort;
                    if (ip.key(cx) == .enum_tag and !try ev.isEnumMember(t, ip.key(cx).enum_tag.name)) return error.Abort;
                    if (ip.key(x) == .enum_literal and cx == x) {
                        // Tag of a void field in a union
                        if (ev.isUnion(t)) return Val.of(t, try ip.get(.{ .union_value = .{ .ty = t, .tag = ip.key(x).enum_literal, .payload = .void_value } }));
                    }
                    return Val.of(t, cx);
                },
                // An integer outside i128: an integer type takes the value if it fits, a float
                // type rounds it
                .big_int => if (ip.isFloat(t) or ip.isInt(t)) {
                    const cx = try value.coerceValue(ip, x, t) orelse return error.Abort;
                    return Val.of(t, cx);
                },
                // Float value to a float / integer type: round to the target precision or convert
                // to an integer; changing only the type tag is not enough
                .float_value => if (ip.isFloat(t) or ip.isInt(t)) {
                    const cx = try value.coerceValue(ip, x, t) orelse return error.Abort;
                    return Val.of(t, cx);
                },
                .union_value => |u| if (value.isEnumType(ip, t)) {
                    // A union coerces to its tag
                    return Val.of(t, try ip.get(.{ .enum_tag = .{ .ty = t, .name = u.tag } }));
                },
                // An enum defined in a signature (`comptime sign: enum { pos, neg }`) has a type per
                // instance of the function, and they are one type in the compiler unless the
                // captures differ: the value must carry the type it is coerced to
                .enum_tag => |tag| if (value.isEnumType(ip, t) and try eqlValues(ev.r, tag.ty, t) != false) {
                    return Val.of(t, try ip.get(.{ .enum_tag = .{ .ty = t, .name = tag.name } }));
                },
                .enum_unnamed => |u| if (value.isEnumType(ip, t) and try eqlValues(ev.r, u.ty, t) != false) {
                    return Val.of(t, try ip.get(.{ .enum_unnamed = .{ .ty = t, .int = u.int } }));
                },
                else => {},
            },
            .unknown => return .{ .ty = t },
            else => {},
        }
        // Pointer to a tuple → slice: coerce the elements one by one; tuple / anonymous struct
        // literal → array, struct
        switch (ip.key(t)) {
            // `*T` → `*[1]T` (`Sema.coerceExtra`): the same place viewed as a one-element array.
            // An interned pointer points to immutable data, which is copied into an interned
            // array.
            .ptr_type => |p| if (p.size == .one and ip.key(p.child) == .array_type and
                ip.key(p.child).array_type.len == 1 and ip.key(v.ty) == .ptr_type and
                ip.key(v.ty).ptr_type.size == .one and ip.key(v.ty).ptr_type.child == ip.key(p.child).array_type.child)
            {
                // An interned pointer that records its place views that place
                const viewed = try ev.pointerPlace(v);
                switch (v.v) {
                    .ref, .ip => if (viewed) |r| {
                        // The pointee is itself an array (`*[n]U` → `*[1][n]U`) taken from a
                        // range or a view, which has no place of its own to view
                        if (r.window != null or r.as_array) return error.Abort;
                        var view = r;
                        view.as_array = true;
                        return .{ .ty = t, .v = .{ .ref = view } };
                    } else {
                        const elem = try ev.freeze(try ev.deref(v)) orelse return error.Abort;
                        const array = try ip.get(.{ .aggregate = .{ .ty = p.child, .elems = &.{elem} } });
                        return Val.of(t, try ev.pointerTo(t, array, null));
                    },
                    else => return error.Abort,
                }
            } else if (p.size == .slice or p.size == .many) {
                const target_ty = ev.pointeeType(v.ty);
                if (target_ty != .unknown and (ip.key(target_ty) == .tuple_type or ip.key(target_ty) == .anon_struct_type)) {
                    const n = try ev.elemCount(v) orelse return error.Abort;
                    const elems = try ev.allocElems(n);
                    for (elems, 0..) |*o, i| o.* = try ev.coerce(try ev.elemAt(v, i), p.child);
                    const array = try ip.get(.{ .array_type = .{ .len = n, .child = p.child, .sentinel = p.sentinel } });
                    const frozen = try ev.freeze(try ev.makeAgg(array, elems)) orelse return error.Abort;
                    return Val.of(t, try ev.pointerTo(t, frozen, null));
                }
            },
            .array_type, .vector_type => if (ev.isAnon(v.ty)) {
                const n = try ev.elemCount(v) orelse return error.Abort;
                const elems = try ev.allocElems(n);
                for (elems, 0..) |*o, i| o.* = try ev.coerce(try ev.elemAt(v, i), ev.elemTypeOf(t, i));
                return ev.makeAgg(t, elems);
            },
            .container_type, .reified_type => if (ev.isAnon(v.ty)) {
                const src = try ev.fieldsOf(v.ty) orelse return error.Abort;
                if (ev.isUnion(t)) {
                    if (src.len != 1) return error.Abort;
                    const payload = try ev.coerce(try ev.elemAt(v, 0), try ev.unionFieldType(t, src[0].name));
                    return Val.of(t, try ip.get(.{ .union_value = .{ .ty = t, .tag = src[0].name, .payload = try ev.freeze(payload) orelse return error.Abort } }));
                }
                const decl = try ev.fieldsOf(t) orelse return error.Abort;
                const elems = try ev.a.alloc(Val, decl.len);
                for (decl, elems) |d, *o| {
                    o.* = for (src, 0..) |s, i| {
                        if (std.mem.eql(u8, s.name, d.name)) break try ev.coerce(try ev.elemAt(v, i), d.ty);
                    } else try ev.fieldDefault(t, d);
                }
                return ev.makeAgg(t, elems);
            },
            else => {},
        }
        return .{ .ty = t, .v = v.v };
    }

    /// Whether `v` is represented as null (see `value.isNullRepr`)
    fn isNullRepr(ev: *Evaluator, v: Val) bool {
        return v.v == .ip and value.isNullRepr(ev.ip, v.v.ip);
    }

    /// The payload (of type `child`) of optional `v`; null when `v` is null
    fn unwrapOptional(ev: *Evaluator, v: Val, child: Index) EvalError!?Val {
        switch (v.v) {
            .unknown, .undef => return error.Abort,
            .ip => |x| {
                if (x == .null_value) return null;
                switch (ev.ip.key(x)) {
                    .opt_payload => |o| return Val.of(child, o.payload),
                    else => {},
                }
            },
            else => {},
        }
        return .{ .ty = child, .v = v.v };
    }

    /// The non-null value of optional type `ty` with payload `payload` (see
    /// `value.wrapOptional`)
    fn wrapOptional(ev: *Evaluator, ty: Index, payload: Val) Error!Val {
        if (ev.isNullRepr(payload)) return Val.of(ty, try value.wrapOptional(ev.ip, ty, payload.v.ip));
        return .{ .ty = ty, .v = payload.v };
    }

    fn isAnon(ev: *Evaluator, t: Index) bool {
        return switch (ev.ip.key(t)) {
            .tuple_type, .anon_struct_type => true,
            else => false,
        };
    }

    fn isEnumMember(ev: *Evaluator, t: Index, name: []const u8) Error!bool {
        const names = try ev.enumNames(t) orelse return true;
        for (names) |n| if (std.mem.eql(u8, n, name)) return true;
        // Unnamed members of a non-exhaustive enum cannot be referenced by name
        return false;
    }

    // ── Positions ────────────────────────────────────────────────────

    fn containerAt(ev: *Evaluator, f: *Frame, e: ExprId) Error!?Namespace {
        return ev.r.containerAt(f.file, f.item, f.body.range(e).start);
    }

    // ── Builtin functions ────────────────────────────────────────────

    fn builtin(ev: *Evaluator, f: *Frame, e: ExprId, name: []const u8, args: []const ExprId, want: ?Index) EvalError!Val {
        const ip = ev.ip;
        const eq = std.mem.eql;
        if (eq(u8, name, "@import")) {
            const target = try ev.r.importTarget(f.file, f.body, args) orelse return error.Abort;
            const tv = try queries.importValue(ev.r, target);
            if (tv.ty == .unknown) return error.Abort;
            // With a result type, the compiler parses ZON according to the result type: values
            // other than scalars cannot be produced by conversion (see `zon.isScalar`)
            if (ev.r.isZon(target)) if (want) |t| if (t != .unknown and t != tv.ty and !zon.isScalar(tv.ty)) return error.Abort;
            return thaw(tv);
        }
        if (eq(u8, name, "@embedFile")) {
            if (args.len != 1) return error.Abort;
            const path = try ev.stringOf(try ev.eval(f, args[0], null));
            return thaw(try embedFile(ev.r, f.file, path) orelse return error.Abort);
        }
        if (eq(u8, name, "@This")) {
            const tree = try ev.r.itemTree(f.file);
            return Val.ofType(try queries.containerType(ev.r, .{ .file = f.file, .container = tree.items[f.item].container }, f.inst));
        }
        if (eq(u8, name, "@compileError") or eq(u8, name, "@panic") or eq(u8, name, "@trap") or eq(u8, name, "@breakpoint")) return error.Abort;
        // Hints that do not affect the comptime result
        if (eq(u8, name, "@setEvalBranchQuota")) {
            if (args.len != 1) return error.Abort;
            const n = try ev.evalInt(f, args[0], null);
            // Has no effect when smaller than the current quota (same as the compiler)
            ev.quota = @max(ev.quota, std.math.cast(u32, n) orelse return error.Abort);
            return Val.void_val;
        }
        const hints = [_][]const u8{ "@compileLog", "@setRuntimeSafety", "@setFloatMode", "@branchHint", "@disableInstrumentation", "@declareSideEffect", "@prefetch", "@export" };
        for (hints) |h| if (eq(u8, name, h)) return Val.void_val;
        if (eq(u8, name, "@inComptime")) return boolVal(true);
        if (eq(u8, name, "@EnumLiteral")) return Val.ofType(.enum_literal_type);
        if (eq(u8, name, "@as")) {
            if (args.len != 2) return error.Abort;
            const t = try ev.evalType(f, args[0]);
            return ev.eval(f, args[1], t);
        }
        if (eq(u8, name, "@constCast") or eq(u8, name, "@volatileCast")) {
            if (args.len != 1) return error.Abort;
            // Merged with a cast below that takes the result type: that cast converts to the
            // destination of the whole chain
            if (infer.qualifierCastTakesResultType(f.body, args[0])) return ev.eval(f, args[0], want);
            // Otherwise the destination comes from the operand, whose value is unchanged; `eval`
            // then coerces it to the result type (`*u8` to `error{E}!*u8` or `*const [1]u8`)
            const v = try ev.eval(f, args[0], null);
            // An operand of unknown type gives an unknown value, which still takes the result type
            if (v.ty == .unknown) return Val.unknown;
            const t = try infer.qualifierCastDest(ip, v.ty, name) orelse return error.Abort;
            return .{ .ty = t, .v = v.v };
        }
        // The compiler merges the casts above `@fieldParentPtr` into it: the chain is one
        // `@fieldParentPtr` whose destination comes from the result type of the outermost cast
        if (mergedFieldParentPtr(f.body, e)) |inner| return ev.eval(f, inner, want);
        if (eq(u8, name, "@Fn")) return ev.reifyFn(f, args);
        const vals = try ev.a.alloc(Val, args.len);
        // Result types of the arguments
        const operand = operand_results.get(name);
        for (args, vals, 0..) |a, *o, i| {
            const t = try ev.builtinArgType(name, operand, i, vals[0..i], want);
            o.* = if (operand == .round_op) try ev.roundOperand(f, a, t) else try ev.eval(f, a, t);
        }
        if (try ev.pureBuiltin(name, vals)) |v| return v;
        if (eq(u8, name, "@TypeOf")) {
            if (vals.len == 0) return error.Abort;
            var t = vals[0].ty;
            for (vals[1..]) |v| t = value.peerIntType(ip, t, v.ty) orelse if (t == v.ty) t else return error.Abort;
            if (t == .unknown) return error.Abort;
            return Val.ofType(t);
        }
        if (eq(u8, name, "@typeInfo")) {
            if (vals.len != 1) return error.Abort;
            const info = try ev.typeInfo(try asType(vals[0]));
            return Val.of(ip.key(info).union_value.ty, info);
        }
        if (eq(u8, name, "@tagName") or eq(u8, name, "@errorName")) {
            if (vals.len != 1) return error.Abort;
            const x = try ev.freeze(vals[0]) orelse return error.Abort;
            return ev.string(switch (ip.key(x)) {
                .enum_tag => |t| t.name,
                .enum_literal => |n| n,
                .union_value => |u| u.tag,
                .error_value => |n| n,
                else => return error.Abort,
            });
        }
        if (eq(u8, name, "@field")) {
            if (vals.len != 2) return error.Abort;
            return ev.fieldAccess(vals[0], try ev.stringOf(vals[1]));
        }
        if (eq(u8, name, "@fieldParentPtr")) {
            if (vals.len != 2) return error.Abort;
            return ev.fieldParentPtr(try ev.stringOf(vals[0]), vals[1], want orelse return error.Abort);
        }
        if (eq(u8, name, "@hasDecl") or eq(u8, name, "@hasField")) {
            if (vals.len != 2) return error.Abort;
            const t = try asType(vals[0]);
            // Type parameter in a generic body without an instance: which members it has depends
            // on the instance (same as `infer.hasMember`)
            if (ip.key(t) == .opaque_param) return error.Abort;
            const field = try ev.stringOf(vals[1]);
            if (eq(u8, name, "@hasField")) {
                if (value.sliceArrayHasField(ip, t, field)) |has| return boolVal(has);
                return boolVal(try ev.fieldIndex(t, field) != null or (value.isEnumType(ip, t) and try ev.isEnumMember(t, field)));
            }
            const ns = try queries.namespaceOfType(ev.r, t) orelse return boolVal(false);
            const tree = try ev.r.itemTree(ns.file);
            const m = Resolver.lookupDecl(tree, ns.container, field) orelse return boolVal(false);
            return boolVal(tree.items[m].flags.is_pub);
        }
        if (eq(u8, name, "@FieldType")) {
            if (vals.len != 2) return error.Abort;
            const t = try asType(vals[0]);
            const field = try ev.stringOf(vals[1]);
            const fields = try ev.fieldsOf(t) orelse return error.Abort;
            for (fields) |fl| if (eq(u8, fl.name, field)) return Val.ofType(fl.ty);
            return error.Abort;
        }
        if (eq(u8, name, "@Int")) {
            if (vals.len != 2) return error.Abort;
            const sign = try ev.tagName(vals[0]);
            const bits = std.math.cast(u16, try ev.intArg(vals[1])) orelse return error.Abort;
            const s = std.meta.stringToEnum(std.builtin.Signedness, sign) orelse return error.Abort;
            // Sema rejects a signed integer type with bit width 0
            if (s == .signed and bits == 0) return error.Abort;
            return Val.ofType(try ip.intType(s, bits));
        }
        if (eq(u8, name, "@Vector")) {
            if (vals.len != 2) return error.Abort;
            const len = std.math.cast(u32, try ev.intArg(vals[0])) orelse return error.Abort;
            return Val.ofType(try ip.get(.{ .vector_type = .{ .len = len, .child = try asType(vals[1]) } }));
        }
        if (eq(u8, name, "@Tuple")) {
            if (vals.len != 1) return error.Abort;
            return Val.ofType(try ip.get(.{ .tuple_type = .{ .types = try ev.typesOf(vals[0]) } }));
        }
        if (eq(u8, name, "@Pointer")) {
            if (vals.len != 4) return error.Abort;
            const size = std.meta.stringToEnum(InternPool.PtrSize, try ev.tagName(vals[0])) orelse return error.Abort;
            const is_const = try ev.boolField(vals[1], "const");
            const child = try asType(vals[2]);
            const sentinel = try ev.freeze(try ev.coerce(vals[3], try ip.optionalOf(child))) orelse return error.Abort;
            const attrs: InternPool.PtrAttrs = .{
                .is_volatile = try ev.boolField(vals[1], "volatile"),
                .is_allowzero = try ev.boolField(vals[1], "allowzero"),
                .alignment = switch (try ev.optionalAttr(vals[1], "align")) {
                    .null_value => .natural,
                    else => |v| alignmentOf(ip, v),
                },
                .address_space = switch (try ev.optionalAttr(vals[1], "addrspace")) {
                    .null_value => .generic,
                    else => |v| addressSpaceOf(ip, v),
                },
            };
            return Val.ofType(try ip.get(.{ .ptr_type = .{ .child = child, .size = size, .is_const = is_const, .sentinel = if (sentinel == .null_value) null else sentinel, .attrs = attrs } }));
        }
        if (eq(u8, name, "@Enum")) {
            if (vals.len != 4) return error.Abort;
            const names = try ev.stringsOf(vals[2]);
            // When the member values cannot be evaluated, number them in declaration order
            const values = ev.intsOf(vals[3]) catch |err| switch (err) {
                error.Abort => blk: {
                    const out = try ev.a.alloc(i128, names.len);
                    for (out, 0..) |*o, i| o.* = @intCast(i);
                    break :blk out;
                },
                else => |x| return x,
            };
            if (values.len != names.len) return error.Abort;
            return Val.ofType(try ev.reify(f, e, .{ .kind = .@"enum", .tag = try asType(vals[0]), .names = names, .values = values, .nonexhaustive = std.mem.eql(u8, try ev.tagName(vals[1]), "nonexhaustive") }));
        }
        if (eq(u8, name, "@Struct") or eq(u8, name, "@Union")) {
            if (vals.len != 5) return error.Abort;
            const layout = std.meta.stringToEnum(InternPool.Reified.Layout, try ev.tagName(vals[0])) orelse return error.Abort;
            const tag = try ev.freeze(vals[1]) orelse return error.Abort;
            const names = try ev.stringsOf(vals[2]);
            const types = try ev.typesOf(vals[3]);
            if (types.len != names.len) return error.Abort;
            const is_union = eq(u8, name, "@Union");
            const attrs = try ev.reifiedAttrs(vals[4], names.len, is_union);
            return Val.ofType(try ev.reify(f, e, .{
                .kind = if (is_union) .@"union" else .@"struct",
                .layout = layout,
                .tag = if (tag == .null_value) null else tag,
                .names = names,
                .types = types,
                .field_aligns = attrs.aligns,
                .comptime_fields = attrs.comptimes,
                .attrs_unknown = attrs.unknown,
            }));
        }
        if (eq(u8, name, "@intCast") or eq(u8, name, "@truncate") or eq(u8, name, "@bitCast") or eq(u8, name, "@enumFromInt") or eq(u8, name, "@fromBackingInt") or eq(u8, name, "@ptrCast") or eq(u8, name, "@alignCast") or eq(u8, name, "@errorCast") or eq(u8, name, "@errSetCast") or eq(u8, name, "@floatCast") or eq(u8, name, "@floatFromInt") or eq(u8, name, "@intFromFloat")) {
            if (vals.len != 1) return error.Abort;
            // Pointer casts do not change the value: without a result type (e.g. the nested
            // `@ptrCast(@alignCast(p))`), pass it through unchanged
            const pointer_cast = eq(u8, name, "@ptrCast") or eq(u8, name, "@alignCast");
            if (want == null and pointer_cast) return vals[0];
            // The cast produces its destination type, the result type without its error union
            // and / or optional (`?u8` gives `u8` to `@intCast`); `eval` coerces the result to the
            // result type afterwards. `@fromBackingInt` strips both (`.remove_eu_opt`) and needs
            // a known result type.
            const t = if (eq(u8, name, "@fromBackingInt"))
                destType(ip, want, .eu_opt) orelse return error.Abort
            else if (castDestStrip(name)) |strip|
                destType(ip, want, strip) orelse want orelse return error.Abort
            else
                want orelse return error.Abort;
            const src = if (pointer_cast) try ev.unerase(vals[0], t) else vals[0];
            if (pointer_cast and !try ev.keepsPointee(src, t)) return .{ .ty = t };
            return ev.cast(name, src, t);
        }
        if (eq(u8, name, "@intFromBool")) {
            if (vals.len != 1) return error.Abort;
            return ev.int(.u1_type, @intFromBool((try ev.condition(vals[0])).yes));
        }
        if (eq(u8, name, "@splat")) {
            // The destination type drops the error union and optional of the result type
            const t = destType(ip, want, .eu_opt) orelse want orelse return error.Abort;
            if (vals.len != 1) return error.Abort;
            const n = try ev.typeElemCount(t) orelse return error.Abort;
            const elems = try ev.allocElems(n);
            for (elems) |*o| o.* = try ev.coerce(vals[0], ev.elemTypeOf(t, 0));
            return ev.makeAgg(t, elems);
        }
        if (eq(u8, name, "@unionInit")) {
            if (vals.len != 3) return error.Abort;
            const t = try asType(vals[0]);
            const field = try ev.stringOf(vals[1]);
            const payload = try ev.freeze(try ev.coerce(vals[2], try ev.unionFieldType(t, field))) orelse return error.Abort;
            return Val.of(t, try ip.get(.{ .union_value = .{ .ty = t, .tag = field, .payload = payload } }));
        }
        if (eq(u8, name, "@memcpy")) {
            if (vals.len != 2) return error.Abort;
            const dest = switch (vals[0].v) {
                .ref => |r| r,
                else => return error.Abort,
            };
            const n = try ev.elemCount(vals[1]) orelse return error.Abort;
            // Write element by element: each element counts as one step
            for (0..n) |i| {
                try ev.tick();
                try ev.store(try ev.extend(dest, @intCast(i)), try ev.elemAt(vals[1], i));
            }
            return Val.void_val;
        }
        if (eq(u8, name, "@memset")) {
            if (vals.len != 2) return error.Abort;
            const dest = switch (vals[0].v) {
                .ref => |r| r,
                else => return error.Abort,
            };
            const n = try ev.elemCount(vals[0]) orelse return error.Abort;
            for (0..n) |i| {
                try ev.tick();
                try ev.store(try ev.extend(dest, @intCast(i)), vals[1]);
            }
            return Val.void_val;
        }
        if (eq(u8, name, "@memmove")) {
            if (vals.len != 2) return error.Abort;
            const dest = switch (vals[0].v) {
                .ref => |r| r,
                else => return error.Abort,
            };
            // Source and destination may overlap: read all elements before writing
            const n = try ev.elemCount(vals[1]) orelse return error.Abort;
            const elems = try ev.a.alloc(Val, n);
            for (elems, 0..) |*x, i| {
                try ev.tick();
                x.* = try ev.copy(try ev.elemAt(vals[1], i));
            }
            for (elems, 0..) |x, i| {
                try ev.tick();
                try ev.store(try ev.extend(dest, @intCast(i)), x);
            }
            return Val.void_val;
        }
        if (eq(u8, name, "@call")) {
            if (vals.len != 3) return error.Abort;
            const fty = switch (ip.key(vals[1].ty)) {
                .fn_type => |ft| ft,
                else => return error.Abort,
            };
            const n = try ev.elemCount(vals[2]) orelse return error.Abort;
            const call_args = try ev.a.alloc(Val, n);
            for (call_args, 0..) |*x, i| x.* = try ev.elemAt(vals[2], i);
            return ev.callFn(vals[1], fty, call_args);
        }
        return error.Abort;
    }

    /// Builtins that only compute (math functions, layout): the arguments are all evaluated, and
    /// the evaluation context is not read. Returns null for any other builtin.
    fn pureBuiltin(ev: *Evaluator, name: []const u8, vals: []const Val) EvalError!?Val {
        const ip = ev.ip;
        const eq = std.mem.eql;
        if (eq(u8, name, "@typeName")) {
            if (vals.len != 1) return error.Abort;
            const t = try asType(vals[0]);
            if (!value.isConcrete(ip, t)) return error.Abort;
            const n = try @import("render.zig").typeName(ev.r, ev.a, t) orelse return error.Abort;
            return try ev.stringLiteral(n);
        }
        if (eq(u8, name, "@tagName") or eq(u8, name, "@errorName")) {
            if (vals.len != 1) return error.Abort;
            // A runtime operand has no usable name; the caller treats it as a slice
            const x = (try ev.freeze(vals[0])) orelse return null;
            const s = switch (ip.key(x)) {
                .enum_tag => |t| t.name,
                .enum_literal => |n| n,
                .union_value => |u| u.tag,
                .error_value => |n| n,
                else => return null,
            };
            return try ev.stringLiteral(s);
        }
        if (eq(u8, name, "@sizeOf") or eq(u8, name, "@alignOf") or eq(u8, name, "@bitSizeOf")) {
            if (vals.len != 1) return error.Abort;
            const l = try ev.typeLayout(try asType(vals[0]), 0) orelse return error.Abort;
            const n = if (eq(u8, name, "@sizeOf")) l.size else if (eq(u8, name, "@alignOf")) l.alignment else l.bits orelse return error.Abort;
            return try ev.int(.comptime_int_type, n);
        }
        if (eq(u8, name, "@intFromEnum") or eq(u8, name, "@backingInt")) {
            if (vals.len != 1) return error.Abort;
            return try ev.enumInt(vals[0]);
        }
        if (eq(u8, name, "@offsetOf") or eq(u8, name, "@bitOffsetOf")) {
            if (vals.len != 2) return error.Abort;
            const bits = try ev.bitOffsetOf(try asType(vals[0]), try ev.stringOf(vals[1])) orelse return error.Abort;
            return try ev.int(.comptime_int_type, if (eq(u8, name, "@offsetOf")) bits / 8 else bits);
        }
        if (eq(u8, name, "@min") or eq(u8, name, "@max")) {
            if (vals.len == 0) return error.Abort;
            const op: value.FloatBinFn = if (eq(u8, name, "@min")) .min else .max;
            // All comptime_int operands may be arbitrary-precision values
            var all_comptime = true;
            for (vals) |v| if (v.ty != .comptime_int_type) {
                all_comptime = false;
                break;
            };
            if (all_comptime) {
                var best = try ev.bigOf(vals[0]) orelse return error.Abort;
                for (vals[1..]) |v| {
                    const x = try ev.bigOf(v) orelse return error.Abort;
                    const ord = bigint.order(x, best);
                    if ((op == .min and ord == .lt) or (op == .max and ord == .gt)) best = x;
                }
                return Val.ofBig(.comptime_int_type, best);
            }
            const operands = try ev.a.alloc(TypedValue, vals.len);
            for (vals, operands) |v, *o| o.* = .{ .ty = v.ty, .val = try ev.ipOf(v) };
            if (anyFloat(ip, vals)) {
                const types = try ev.a.alloc(Index, vals.len);
                for (vals, types) |v, *t| t.* = v.ty;
                const ty = value.minMaxFloatType(ip, types) orelse return error.Abort;
                var best = try ev.floatArg(vals[0]);
                for (vals[1..]) |v| best = value.floatOf(ip, try value.floatBinary(ip, op, ty, best, try ev.floatArg(v))) orelse return error.Abort;
                return try ev.float(ty, best);
            }
            // The result type is the smallest integer type that can hold the result (e.g.
            // `@min(@as(u8, 3), @as(u16, 5))` is u2)
            const ty = try value.minMaxIntType(ip, ev.a, op == .min, operands) orelse return error.Abort;
            // Values outside i128 (including u128 values stored as the bit pattern) are compared
            // at arbitrary precision
            for (vals) |v| if (v.v == .big or value.isBigIntType(ip, v.ty) or value.isUnsigned128(ip, v.ty)) {
                var best = try ev.bigOf(vals[0]) orelse return error.Abort;
                for (vals[1..]) |w| {
                    const x = try ev.bigOf(w) orelse return error.Abort;
                    const ord = bigint.order(x, best);
                    if ((op == .min and ord == .lt) or (op == .max and ord == .gt)) best = x;
                }
                return ev.intFromBig(ty, best);
            };
            var best = try ev.intArg(vals[0]);
            for (vals[1..]) |v| {
                const x = try ev.intArg(v);
                best = if (op == .min) @min(best, x) else @max(best, x);
            }
            return try ev.int(ty, best);
        }
        if (eq(u8, name, "@abs")) {
            if (vals.len != 1) return error.Abort;
            if (ip.isFloat(vals[0].ty)) return try floatResult(vals[0].ty, try value.floatUnary(ip, .abs, vals[0].ty, try ev.floatArg(vals[0])));
            const ty = try value.absType(ip, vals[0].ty) orelse return error.Abort;
            if (ev.intOf(vals[0])) |x| if (x != std.math.minInt(i128) and !value.isUnsigned128(ip, vals[0].ty)) return try ev.int(ty, @abs(x));
            // Values outside i128, the minimum of i128, and u128 values stored as the bit pattern
            const b = try ev.bigOf(vals[0]) orelse return error.Abort;
            return ev.intFromBig(ty, if (b.positive) b else bigint.negate(b));
        }
        // Unary float math functions: compute in the float type of the argument
        if (name.len > 1) if (std.meta.stringToEnum(value.FloatFn, name[1..])) |op| {
            if (vals.len != 1) return error.Abort;
            return try floatResult(vals[0].ty, try value.floatUnary(ip, op, vals[0].ty, try ev.floatArg(vals[0])));
        };
        if (eq(u8, name, "@mulAdd")) {
            if (vals.len != 4) return error.Abort;
            const ty = try asType(vals[0]);
            return try floatResult(ty, try value.floatMulAdd(ip, ty, try ev.floatArg(vals[1]), try ev.floatArg(vals[2]), try ev.floatArg(vals[3])));
        }
        const division = [_]struct { []const u8, value.FloatBinFn }{
            .{ "@divTrunc", .div_trunc }, .{ "@divFloor", .div_floor }, .{ "@divCeil", .div_ceil },
            .{ "@divExact", .div_exact }, .{ "@mod", .mod },            .{ "@rem", .rem },
        };
        for (division) |d| if (eq(u8, name, d[0])) {
            if (vals.len != 2) return error.Abort;
            if (anyFloat(ip, vals)) {
                const ty = floatPeer(ip, vals[0].ty, vals[1].ty) orelse return error.Abort;
                return try floatResult(ty, try value.floatBinary(ip, d[1], ty, try ev.floatArg(vals[0]), try ev.floatArg(vals[1])));
            }
            const ty = value.peerIntType(ip, vals[0].ty, vals[1].ty) orelse return error.Abort;
            // The minimum of i128 divided by -1 overflows i128, and u128 values above i128's range
            // are stored as the bit pattern: both are computed at arbitrary precision
            if (!value.isBigIntType(ip, ty) and !value.isUnsigned128(ip, ty)) if (ev.intOf(vals[0])) |x| if (ev.intOf(vals[1])) |y| if (x != std.math.minInt(i128)) {
                if (y == 0) return error.Abort;
                const r: i128 = switch (d[1]) {
                    .div_trunc => @divTrunc(x, y),
                    .div_floor => @divFloor(x, y),
                    .div_ceil => @divCeil(x, y),
                    .div_exact => if (@divTrunc(x, y) * y != x) return error.Abort else @divTrunc(x, y),
                    .mod => @mod(x, y),
                    .rem => @rem(x, y),
                    .min, .max => unreachable,
                };
                if (!value.intFits(ip, ty, r)) return error.Abort;
                return try ev.int(ty, r);
            };
            const a = try ev.bigOf(vals[0]) orelse return error.Abort;
            const b = try ev.bigOf(vals[1]) orelse return error.Abort;
            const mode: bigint.DivMode = switch (d[1]) {
                .div_trunc => .trunc,
                .div_floor => .floor,
                .div_ceil => .ceil,
                .div_exact => .exact,
                .mod => .mod,
                .rem => .rem,
                else => unreachable,
            };
            const r = if (ty == .comptime_int_type)
                try bigint.divide(ev.a, mode, a, b)
            else
                try bigint.divideTyped(ev.a, mode, value.intInfo(ip, ty) orelse return error.Abort, a, b);
            return ev.intFromBig(ty, r orelse return error.Abort);
        };
        const overflow_ops = [_]struct { []const u8, value.OverflowOp }{
            .{ "@addWithOverflow", .add }, .{ "@subWithOverflow", .sub }, .{ "@mulWithOverflow", .mul }, .{ "@shlWithOverflow", .shl },
        };
        for (overflow_ops) |o| if (eq(u8, name, o[0])) {
            if (vals.len != 2) return error.Abort;
            // The result type is the peer type of both sides (for `@shlWithOverflow`, the type of
            // the left side)
            const ty = if (o[1] == .shl) vals[0].ty else value.peerIntType(ip, vals[0].ty, vals[1].ty) orelse return error.Abort;
            const result: Val, const overflow: bool = if (value.wideIntType(ip, ty)) |t| blk: {
                const a = try ev.bigOf(vals[0]) orelse return error.Abort;
                const b = try ev.bigOf(vals[1]) orelse return error.Abort;
                const bin: SyntaxKind = switch (o[1]) {
                    .add => .plus,
                    .sub => .minus,
                    .mul => .asterisk,
                    .shl => .angle_bracket_angle_bracket_left,
                };
                const r, const overflow = try bigint.overflowTyped(ev.a, bin, t, a, b) orelse return error.Abort;
                break :blk .{ Val.ofBig(ty, r), overflow };
            } else blk: {
                const r, const overflow = value.overflowInt(ip, o[1], ty, try ev.intArg(vals[0]), try ev.intArg(vals[1])) orelse return error.Abort;
                break :blk .{ try ev.int(ty, r), overflow };
            };
            const tuple = try ip.get(.{ .tuple_type = .{ .types = &.{ ty, .u1_type } } });
            const elems = [_]Index{ (try ev.freeze(result)).?, (try ev.freeze(try ev.int(.u1_type, @intFromBool(overflow)))).? };
            return Val.of(tuple, try ev.aggregate(tuple, &elems));
        };
        if (eq(u8, name, "@shlExact") or eq(u8, name, "@shrExact")) {
            if (vals.len != 2) return error.Abort;
            const left = eq(u8, name, "@shlExact");
            if (vals[0].ty == .comptime_int_type) {
                const a = try ev.bigOf(vals[0]) orelse return error.Abort;
                const n = try ev.intArg(vals[1]);
                const r = try bigint.exactShift(ev.a, left, a, std.math.cast(usize, n) orelse return error.Abort) orelse return error.Abort;
                return Val.ofBig(vals[0].ty, r);
            }
            if (value.wideIntType(ip, vals[0].ty)) |t| {
                const a = try ev.bigOf(vals[0]) orelse return error.Abort;
                const b = try ev.bigOf(vals[1]) orelse return error.Abort;
                return Val.ofBig(vals[0].ty, try bigint.exactShiftTyped(ev.a, left, t, a, b) orelse return error.Abort);
            }
            const r = value.exactShift(ip, left, vals[0].ty, try ev.intArg(vals[0]), try ev.intArg(vals[1])) orelse return error.Abort;
            return try ev.int(vals[0].ty, r);
        }
        if (eq(u8, name, "@byteSwap") or eq(u8, name, "@bitReverse")) {
            if (vals.len != 1) return error.Abort;
            const bytes = eq(u8, name, "@byteSwap");
            if (value.wideIntType(ip, vals[0].ty)) |t| {
                const a = try ev.bigOf(vals[0]) orelse return error.Abort;
                return Val.ofBig(vals[0].ty, try bigint.reverseBitsTyped(ev.a, bytes, t, a) orelse return error.Abort);
            }
            const r = value.reverseBits(ip, bytes, vals[0].ty, try ev.intArg(vals[0])) orelse return error.Abort;
            return try ev.int(vals[0].ty, r);
        }
        if (eq(u8, name, "@clz") or eq(u8, name, "@ctz") or eq(u8, name, "@popCount")) {
            if (vals.len != 1) return error.Abort;
            const info = value.intInfo(ip, vals[0].ty) orelse return error.Abort;
            // Result type: an unsigned integer that can hold the bit width
            const result_ty = try ip.intType(.unsigned, @intCast(128 - @clz(@as(u128, info.bits))));
            if (info.bits > 128) {
                const a = try ev.bigOf(vals[0]) orelse return error.Abort;
                const which: bigint.BitCount = if (eq(u8, name, "@popCount")) .pop_count else if (eq(u8, name, "@clz")) .clz else .ctz;
                return try ev.int(result_ty, bigint.bitCountTyped(info, a, which) orelse return error.Abort);
            }
            const x = try ev.intArg(vals[0]);
            // Take the two's complement representation at the bit width
            const bits: u128 = if (info.bits == 128) @bitCast(x) else @as(u128, @bitCast(x)) & ((@as(u128, 1) << @intCast(info.bits)) - 1);
            const n: u16 = if (eq(u8, name, "@popCount"))
                @popCount(bits)
            else if (bits == 0)
                info.bits
            else if (eq(u8, name, "@clz"))
                @intCast(@clz(bits) - (128 - info.bits))
            else
                @ctz(bits);
            return try ev.int(result_ty, n);
        }
        return null;
    }

    fn float(ev: *Evaluator, ty: Index, x: f128) EvalError!Val {
        return Val.of(ty, try value.floatValue(ev.ip, ty, x) orelse return error.Abort);
    }

    fn floatArg(ev: *Evaluator, v: Val) EvalError!f128 {
        return ev.floatOf(v) orelse error.Abort;
    }

    /// `@Fn(param_types, param_attrs, ReturnType, attrs)`. As in the compiler, the arguments
    /// have the result types `[]const type`, `*const [param_types.len]ParamAttributes`, `type`
    /// and `Attributes` (of `std.builtin.Type.Fn`).
    fn reifyFn(ev: *Evaluator, f: *Frame, args: []const ExprId) EvalError!Val {
        const ip = ev.ip;
        if (args.len != 4) return error.Abort;
        const fn_ty = try ev.stdType(&.{ "builtin", "Type", "Fn" });
        const params = try ev.typesOf(try ev.eval(f, args[0], try ip.ptrTo(.type_type, .slice, true)));
        const pa_ty = try ev.member(fn_ty, "ParamAttributes");
        const pa = try ev.eval(f, args[1], try ip.ptrTo(try ip.get(.{ .array_type = .{ .len = params.len, .child = pa_ty } }), .one, true));
        if (try ev.elemCount(pa) != params.len) return error.Abort;
        var noalias_bits: u32 = 0;
        for (0..params.len) |i| if (try ev.boolField(try ev.elemAt(pa, i), "noalias")) {
            noalias_bits |= InternPool.FnType.bitOf(i) orelse return error.Abort;
        };
        const ret = try ev.evalType(f, args[2]);
        var cc: InternPool.CallConv = .auto;
        var varargs = false;
        switch (f.body.expr(args[3])) {
            // A struct literal: absent fields keep their defaults. As in `callconv(...)`, `.c`
            // and the tags without options are known from the syntax.
            .init => |x| if (x.ty == null) {
                for (x.fields) |fl| {
                    const field = fl.name orelse return error.Abort;
                    if (std.mem.eql(u8, field, "callconv")) {
                        cc = try writtenCallConv(ev.r, f.body, fl.value, try ev.callConvValue(f, fl.value));
                    } else if (std.mem.eql(u8, field, "varargs")) {
                        varargs = switch (try ev.freeze(try ev.eval(f, fl.value, .bool_type)) orelse return error.Abort) {
                            .true_value => true,
                            .false_value => false,
                            else => return error.Abort,
                        };
                    } else return error.Abort;
                }
                return Val.ofType(try ip.get(.{ .fn_type = .{ .params = params, .ret = ret, .varargs = varargs, .cc = cc, .noalias_bits = noalias_bits } }));
            },
            else => {},
        }
        const attrs = try ev.eval(f, args[3], try ev.member(fn_ty, "Attributes"));
        cc = try callConv(ev.r, try ev.freeze(try ev.fieldAccess(attrs, "callconv")));
        varargs = try ev.boolField(attrs, "varargs");
        return Val.ofType(try ip.get(.{ .fn_type = .{ .params = params, .ret = ret, .varargs = varargs, .cc = cc, .noalias_bits = noalias_bits } }));
    }

    /// Result type of argument `i` of a builtin (matches the compiler's `AstGen.builtinCall`):
    /// `operand` classifies the builtin, `prev` holds the preceding arguments and `want` is the
    /// result type of the call. In builtins that construct types, arguments given per field get
    /// `*const [n]T`, which forms such as `&@splat(.{})` need.
    fn builtinArgType(ev: *Evaluator, name: []const u8, operand: ?OperandResult, i: usize, prev: []const Val, want: ?Index) EvalError!?Index {
        const eq = std.mem.eql;
        const is_struct = eq(u8, name, "@Struct");
        const elem: ?Index = if ((is_struct or eq(u8, name, "@Union")) and (i == 3 or i == 4)) blk: {
            if (i == 3) break :blk .type_type;
            break :blk ev.stdType(&.{ "builtin", "Type", if (is_struct) "Struct" else "Union", "FieldAttributes" }) catch |err| switch (err) {
                error.Abort => return null,
                else => |x| return x,
            };
        } else if (eq(u8, name, "@Enum") and i == 3) asType(prev[0]) catch return null else null;
        if (elem) |t| {
            const n = try ev.elemCount(prev[2]) orelse return null;
            return try ev.ip.ptrTo(try ev.ip.get(.{ .array_type = .{ .len = n, .child = t } }), .one, true);
        }
        if (operand) |kind| {
            const t = try ev.operandResultType(kind, i, prev, want) orelse return null;
            return if (t == .unknown) null else t;
        }
        return builtinParamType(name, i);
    }

    /// Builtins whose arguments have result types given by the result type of the call or by the
    /// preceding arguments (see `operandResultType`)
    const OperandResult = enum { from_backing_int, union_init, memset, splat, float_op, round_op, mul_add, int, vector, shift_exact };

    const operand_results = std.StaticStringMap(OperandResult).initComptime(.{
        .{ "@fromBackingInt", .from_backing_int },
        .{ "@unionInit", .union_init },
        .{ "@memset", .memset },
        .{ "@splat", .splat },
        .{ "@sqrt", .float_op },
        .{ "@sin", .float_op },
        .{ "@cos", .float_op },
        .{ "@tan", .float_op },
        .{ "@exp", .float_op },
        .{ "@exp2", .float_op },
        .{ "@log", .float_op },
        .{ "@log2", .float_op },
        .{ "@log10", .float_op },
        .{ "@floor", .round_op },
        .{ "@ceil", .round_op },
        .{ "@trunc", .round_op },
        .{ "@round", .round_op },
        .{ "@mulAdd", .mul_add },
        .{ "@Int", .int },
        .{ "@Vector", .vector },
        .{ "@shlExact", .shift_exact },
        .{ "@shrExact", .shift_exact },
    });

    /// Result type of argument `i` of a builtin classified as `kind`; null when it has none
    fn operandResultType(ev: *Evaluator, kind: OperandResult, i: usize, prev: []const Val, want: ?Index) EvalError!?Index {
        const ip = ev.ip;
        switch (kind) {
            // The operand is coerced to the backing integer of the destination type, which is the
            // result type without one error union and one optional (`destType` with `.eu_opt`;
            // the compiler's `from_backing_int_arg_ty`): the tag type of an enum, the backing
            // integer of a packed struct or union. `@fromBackingInt(@intCast(i))` needs it.
            .from_backing_int => if (i == 0) {
                const dest = destType(ip, want, .eu_opt) orelse return null;
                return ev.backingIntType(dest) catch |err| switch (err) {
                    error.Abort => null,
                    else => |x| return x,
                };
            },
            // The init value has the type of the named field
            .union_init => if (i == 2) return try ev.unionFieldType(try asType(prev[0]), try ev.stringOf(prev[1])),
            // The fill value has the element type of the destination
            .memset => if (i == 1) return indexablePtrElemType(ip, prev[0].ty),
            // The scalar has the element type of the array or vector the result type holds, with
            // error unions and optionals removed however deeply nested (`splat_op_result_ty`)
            .splat => if (i == 0) return switch (ip.key(value.optEuBaseType(ip, want orelse return null))) {
                .array_type => |a| a.child,
                .vector_type => |v| v.child,
                else => null,
            },
            // A float or a vector of floats in the result type (`float_op_result_ty` /
            // `round_op_ty`). With an integer result type, a rounding builtin converts its float
            // operand to the integer, and the operand has no result type; for the other builtins
            // a result type that is not a float is a compile error.
            .float_op, .round_op => if (i == 0) return value.floatOperandType(ip, want orelse return null),
            // The multiplicands and the addend have the float type given by the first argument
            .mul_add => if (i == 0) return .type_type else if (i <= 3) return try asType(prev[0]),
            // The bit count of `@Int` is a u16, the length of `@Vector` a u32
            .int => if (i == 1) return try ip.intType(.unsigned, 16),
            .vector => if (i == 0) return try ip.intType(.unsigned, 32),
            // The shift amount of `@shlExact` / `@shrExact` has the result type `Log2Int(T)` of the
            // shifted operand's type
            .shift_exact => if (i == 1) return value.log2IntType(ip, prev[0].ty),
        }
        return null;
    }

    /// Element type of the destination of `@memset` (matches the compiler's
    /// `zirIndexablePtrElemType`): the child of a slice or many-item pointer, the element of the
    /// array or vector a single-item pointer points to; null for other types
    fn indexablePtrElemType(ip: *InternPool, t: Index) ?Index {
        const p = switch (ip.key(t)) {
            .ptr_type => |p| p,
            else => return null,
        };
        if (p.size != .one) return p.child;
        return switch (ip.key(p.child)) {
            .array_type => |a| a.child,
            .vector_type => |v| v.child,
            else => null,
        };
    }

    /// Result type of a builtin parameter
    fn builtinParamType(name: []const u8, i: usize) ?Index {
        const eq = std.mem.eql;
        if (i == 0 and (eq(u8, name, "@as") or eq(u8, name, "@typeInfo") or eq(u8, name, "@sizeOf") or eq(u8, name, "@alignOf") or eq(u8, name, "@bitSizeOf") or eq(u8, name, "@offsetOf") or eq(u8, name, "@bitOffsetOf"))) return .type_type;
        return null;
    }

    /// Whether pointer `v` cast to type `to` points to the same elements: values are not
    /// reinterpreted in memory, so a cast that changes the element type (`*const [2][1]u8` to
    /// `*const [2]u8` in std.mem.asBytes) gives an unknown value. A cast to `*anyopaque` keeps
    /// the value, which cannot be read through it; a cast back from it is checked on the pointer
    /// it was erased from (`unerase`).
    fn keepsPointee(ev: *Evaluator, v: Val, to: Index) EvalError!bool {
        const ip = ev.ip;
        if (v.is(.null_value)) return true;
        const a = pointerType(ip, v.ty) orelse return false;
        const b = pointerType(ip, to) orelse return false;
        if (b.child == .anyopaque_type) return true;
        // An erased pointer `unerase` left as it is: what it points to is unknown
        if (a.child == .anyopaque_type) return false;
        const x = castPointee(ip, a);
        const y = castPointee(ip, b);
        // Pointers to arrays, slices and many-pointers are represented by the elements, other
        // single-item pointers by the pointed-to value
        if (x.single != y.single) return false;
        if (x.len != null and y.len != null and x.len.? != y.len.?) return false;
        return value.eqlTypes(ip, x.elem, y.elem) == true;
    }

    /// Pointer `v` erased to `*anyopaque` (or `?*anyopaque`), typed as the pointer it was erased
    /// from, for a pointer cast to `to`. The compiler's comptime pointers keep what they point to
    /// when coercion or `@ptrCast` changes their type, and a load compares the loaded type with
    /// the value there, so a cast back from `*anyopaque` is checked as a cast of the original
    /// pointer. The type comes from the representation: the value in the storage (`.ref`; a
    /// range is an array), the pointer type an interned pointer was created with, or the type of
    /// the pointed-to value (`sentinel_ptr` and `default_value_ptr` of `@typeInfo`). The child of
    /// `to` only chooses between the types the representation leaves open: an interned value of
    /// an optional or an error union is its payload, and a pointer to the payload of an optional
    /// (`if (opt) |*x|`) points to where the optional is. Other values are returned unchanged.
    fn unerase(ev: *Evaluator, v: Val, to: Index) EvalError!Val {
        const ip = ev.ip;
        const a = pointerType(ip, v.ty) orelse return v;
        const b = pointerType(ip, to) orelse return v;
        if (a.child != .anyopaque_type or b.child == .anyopaque_type) return v;
        var from: InternPool.PtrType = .{ .child = .unknown, .size = .one, .is_const = a.is_const, .attrs = a.attrs };
        var repr = v.v;
        switch (v.v) {
            .ref => |r| {
                const target = ev.loadPath(r) catch |err| switch (err) {
                    error.Abort => return v,
                    else => |e| return e,
                };
                if (r.window) |w| {
                    const elem = ev.elemTypeOf(target.ty, w.start);
                    if (elem == .unknown) return v;
                    from.child = try ip.get(.{ .array_type = .{ .len = w.len, .child = elem } });
                } else {
                    from.child = target.ty;
                    // A pointer to the payload of an optional points to the optional and is read
                    // as the payload (see `deref`)
                    switch (ip.key(target.ty)) {
                        .optional_type => |c| if (c == b.child and !target.is(.null_value)) {
                            from.child = c;
                        },
                        else => {},
                    }
                }
            },
            .ip => |x| switch (ip.key(x)) {
                .ptr_value => |pv| {
                    const p = pointerType(ip, pv.ty) orelse return v;
                    if (p.child != .anyopaque_type) {
                        from = p;
                    } else {
                        if (pv.pointee == .unknown) return v;
                        from.child = if (valueOfType(ip, pv.pointee, b.child)) b.child else value.typeOfValue(ip, pv.pointee);
                        if (from.child == .unknown) return v;
                        repr = .{ .ip = try ev.pointerTo(try ip.get(.{ .ptr_type = from }), pv.pointee, pv.base) };
                    }
                },
                .aggregate => |agg| from = pointerType(ip, agg.ty) orelse return v,
                .bytes => |bytes| from = pointerType(ip, bytes.ty) orelse return v,
                else => return v,
            },
            else => return v,
        }
        if (from.child == .unknown) return v;
        // Slices cannot be erased; the elements of one are erased through its `ptr`
        if (from.size == .slice) from.size = .many;
        const ptr = try ip.get(.{ .ptr_type = from });
        return .{ .ty = if (ip.key(v.ty) == .optional_type) try ip.optionalOf(ptr) else ptr, .v = repr };
    }

    /// Whether interned value `x` is a value of type `t`: optionals and error unions are
    /// represented by their payloads (or `null` / the error), errors have no type of their own,
    /// and `undefined` is a value of every type
    fn valueOfType(ip: *InternPool, x: Index, t: Index) bool {
        if (x == .undefined_value) return true;
        if (value.eqlTypes(ip, value.typeOfValue(ip, x), t) == true) return true;
        const is_error = ip.key(x) == .error_value;
        return switch (ip.key(t)) {
            .optional_type => |c| x == .null_value or valueOfType(ip, x, c),
            .error_union_type => |eu| is_error or valueOfType(ip, x, eu.payload),
            .error_set_type, .inferred_error_set => is_error,
            else => t == .anyerror_type and is_error,
        };
    }

    /// The pointer type of a pointer or an optional pointer
    fn pointerType(ip: *InternPool, t: Index) ?@FieldType(InternPool.Key, "ptr_type") {
        return switch (ip.key(t)) {
            .ptr_type => |p| p,
            .optional_type => |c| switch (ip.key(c)) {
                .ptr_type => |p| p,
                else => null,
            },
            else => null,
        };
    }

    const Pointee = struct { elem: Index, len: ?u64, single: bool };

    fn castPointee(ip: *InternPool, p: @FieldType(InternPool.Key, "ptr_type")) Pointee {
        if (p.size != .one) return .{ .elem = p.child, .len = null, .single = false };
        return switch (ip.key(p.child)) {
            .array_type => |arr| .{ .elem = arr.child, .len = arr.len, .single = false },
            else => .{ .elem = p.child, .len = null, .single = true },
        };
    }

    /// `@fieldParentPtr(name, field_ptr)` with result type `result_ty` (the compiler's
    /// `zirFieldParentPtr`). The destination type is the result type without its error union: a
    /// pointer or an optional pointer to a struct or union. The result points to the value that
    /// contains the field `field_ptr` points to, which must be field `name` of a value of the
    /// parent type, or in an extern or packed union (whose fields all start at the union's
    /// address) another field of the same type. Gives up otherwise: with an auto layout the
    /// compiler rejects it, and with the other layouts the result reinterprets memory, which the
    /// interpreter does not model. A comptime field is rejected as in the compiler. Qualifiers
    /// and alignment are not checked against the field pointer.
    fn fieldParentPtr(ev: *Evaluator, name: []const u8, field_ptr: Val, result_ty: Index) EvalError!Val {
        const ip = ev.ip;
        const dest = switch (ip.key(result_ty)) {
            .error_union_type => |eu| eu.payload,
            else => result_ty,
        };
        const parent_ptr = pointerType(ip, dest) orelse return error.Abort;
        if (parent_ptr.size != .one) return error.Abort;
        const parent_ty = parent_ptr.child;
        const fields = try ev.fieldsOf(parent_ty) orelse return error.Abort;
        const index = for (fields, 0..) |field, i| {
            if (std.mem.eql(u8, field.name, name)) break i;
        } else return error.Abort;
        const is_comptime = if (fields[index].item) |m| blk: {
            const ns = try queries.namespaceOfType(ev.r, parent_ty) orelse return error.Abort;
            break :blk (try ev.r.itemTree(ns.file)).items[m].flags.is_comptime;
        } else (try ev.fieldAttrs(parent_ty, index, fields[index])).is_comptime;
        if (is_comptime) return error.Abort;
        const ref = try ev.pointerPlace(field_ptr) orelse return error.Abort;
        // A `*T` → `*[1]T` view points to an array, which does not coerce to a pointer to the
        // field
        if (ref.window != null or ref.as_array or ref.path.len == 0) return error.Abort;
        const parent: Ref = .{ .cell = ref.cell, .path = ref.path[0 .. ref.path.len - 1], .is_const = ref.is_const or parent_ptr.is_const, .immutable = ref.immutable };
        if (value.eqlTypes(ip, (try ev.loadPath(parent)).ty, parent_ty) != true) return error.Abort;
        const at = ref.path[ref.path.len - 1];
        if (at != index) {
            if (!ev.isUnion(parent_ty) or try ev.layoutOf(parent_ty) == .auto) return error.Abort;
            if (at >= fields.len or value.eqlTypes(ip, fields[at].ty, fields[index].ty) != true) return error.Abort;
        }
        return .{ .ty = dest, .v = .{ .ref = parent } };
    }

    fn cast(ev: *Evaluator, name: []const u8, v: Val, t: Index) EvalError!Val {
        const ip = ev.ip;
        const eq = std.mem.eql;
        if (eq(u8, name, "@bitCast")) if (try ev.floatBitCast(v, t)) |r| return r;
        if (eq(u8, name, "@intCast") or eq(u8, name, "@truncate") or eq(u8, name, "@bitCast")) {
            if (ev.intOf(v)) |x| {
                if (eq(u8, name, "@intCast")) return try ev.convertInt(v.ty, t, x) orelse error.Abort;
                const info = value.intInfo(ip, t) orelse return error.Abort;
                if (eq(u8, name, "@bitCast")) {
                    const src = value.intInfo(ip, v.ty) orelse return error.Abort;
                    if (src.bits != info.bits) return error.Abort;
                }
                if (info.bits > 128) return ev.intFromBig(t, try bigint.wrap(ev.a, try value.bigOfInt(ip, ev.a, v.ty, x), info));
                const r = value.binaryInt(ip, .plus_percent, t, x, 0) orelse return error.Abort;
                return ev.int(t, r);
            }
            // An integer outside i128
            if (try ev.bigOf(v)) |b| {
                if (!ip.isInt(t)) return error.Abort;
                const info = value.intInfo(ip, t) orelse return error.Abort;
                if (eq(u8, name, "@intCast")) {
                    if (!bigint.fits(b, info)) return error.Abort;
                    return ev.intFromBig(t, b);
                }
                if (eq(u8, name, "@bitCast")) {
                    const src = value.intInfo(ip, v.ty) orelse return error.Abort;
                    if (src.bits != info.bits) return error.Abort;
                }
                return ev.intFromBig(t, try bigint.wrap(ev.a, b, info));
            }
            return .{ .ty = t };
        }
        if (eq(u8, name, "@enumFromInt") or eq(u8, name, "@fromBackingInt")) {
            const x = ev.intOf(v) orelse return .{ .ty = t };
            if (!value.isEnumType(ip, t)) return error.Abort;
            const names = try ev.enumNames(t) orelse return error.Abort;
            const values = try ev.enumValues(t);
            for (names, values) |n, val| if (val == x) return Val.of(t, try ip.get(.{ .enum_tag = .{ .ty = t, .name = n } }));
            // A non-exhaustive enum also has every other integer of its tag type, which is always
            // given explicitly; an integer that does not fit in it is a compile error (as is one
            // that no member of an exhaustive enum has)
            if (!try ev.nonexhaustive(t)) return error.Abort;
            const tag = (try ev.containerSyntax(t)).arg orelse return .{ .ty = t };
            if (!value.intFitsFrom(ip, v.ty, tag, x)) return error.Abort;
            const tag_int = try ip.get(.{ .int_value = .{ .ty = tag, .value = x } });
            return Val.of(t, try ip.get(.{ .enum_unnamed = .{ .ty = t, .int = tag_int } }));
        }
        if (eq(u8, name, "@floatCast") or eq(u8, name, "@floatFromInt")) {
            const x = ev.floatOf(v) orelse return .{ .ty = t };
            return Val.of(t, try value.floatValue(ip, t, x) orelse return error.Abort);
        }
        if (eq(u8, name, "@intFromFloat")) {
            const x = ev.floatOf(v) orelse return .{ .ty = t };
            if (std.math.isNan(x)) return error.Abort;
            if (@abs(x) > 1e38) {
                // Types wider than 128 bits hold larger values
                const info = value.wideIntType(ip, t) orelse return error.Abort;
                const b = try bigint.fromFloat(ev.a, x) orelse return error.Abort;
                if (!bigint.fits(b, info)) return error.Abort;
                return ev.intFromBig(t, b);
            }
            const i: i128 = @intFromFloat(@trunc(x));
            if (!value.intFits(ip, t, i)) return error.Abort;
            return ev.int(t, i);
        }
        return .{ .ty = t, .v = v.v };
    }

    /// `@bitCast` between a float and an integer of the same bit width (as std.fmt.float does to
    /// read the parts of a float); null when neither side is a float
    fn floatBitCast(ev: *Evaluator, v: Val, t: Index) EvalError!?Val {
        const ip = ev.ip;
        if (ip.isFloat(v.ty) and ip.isInt(t)) {
            const x = ev.floatOf(v) orelse return .{ .ty = t };
            const bits = value.floatToBits(ip, v.ty, x) orelse return .{ .ty = t };
            const info = value.intInfo(ip, t) orelse return error.Abort;
            if (info.bits != value.floatBits(ip, v.ty)) return error.Abort;
            const n: i128 = if (info.signed) switch (info.bits) {
                16 => @as(i16, @bitCast(@as(u16, @truncate(bits)))),
                32 => @as(i32, @bitCast(@as(u32, @truncate(bits)))),
                64 => @as(i64, @bitCast(@as(u64, @truncate(bits)))),
                80 => @as(i80, @bitCast(@as(u80, @truncate(bits)))),
                128 => @bitCast(bits),
                else => return error.Abort,
            } else if (info.bits == 128) @bitCast(bits) else std.math.cast(i128, bits) orelse return .{ .ty = t };
            return try ev.int(t, n);
        }
        if (ip.isInt(v.ty) and ip.isFloat(t)) {
            const x = ev.intOf(v) orelse return .{ .ty = t };
            const info = value.intInfo(ip, v.ty) orelse return error.Abort;
            const width = value.floatBits(ip, t) orelse return .{ .ty = t };
            if (info.bits != width) return error.Abort;
            const mask: u128 = if (width == 128) std.math.maxInt(u128) else (@as(u128, 1) << @intCast(width)) - 1;
            const bits = @as(u128, @bitCast(x)) & mask;
            const f = value.floatFromBits(ip, t, bits) orelse return .{ .ty = t };
            return Val.of(t, try value.floatValue(ip, t, f) orelse return error.Abort);
        }
        return null;
    }

    fn enumInt(ev: *Evaluator, v: Val) EvalError!Val {
        const ip = ev.ip;
        const x = try ev.freeze(v) orelse return error.Abort;
        const enum_ty: Index, const tag_name: []const u8 = switch (ip.key(x)) {
            .enum_tag => |t| .{ t.ty, t.name },
            .enum_unnamed => |u| return ev.int(value.typeOfValue(ip, u.int), value.intOf(ip, u.int) orelse return error.Abort),
            // Tagged union: the integer of the tag
            .union_value => |u| .{ try ev.unionTagType(u.ty) orelse return error.Abort, u.tag },
            else => return error.Abort,
        };
        const names = try ev.enumNames(enum_ty) orelse return error.Abort;
        const values = try ev.enumValues(enum_ty);
        const int_ty = try ev.enumTagType(enum_ty) orelse .comptime_int_type;
        for (names, values) |n, val| if (std.mem.eql(u8, n, tag_name)) return ev.int(int_ty, val);
        return error.Abort;
    }

    fn int(ev: *Evaluator, ty: Index, x: anytype) Error!Val {
        _ = ev;
        return Val.ofInt(ty, @intCast(x));
    }

    /// A value of the integer type `ty` (or comptime_int) from an arbitrary-precision value in its
    /// range; a u128 value above i128's range is stored as the bit pattern
    fn intFromBig(ev: *Evaluator, ty: Index, b: bigint.Big) Val {
        if (bigint.toInt(b)) |x| return Val.ofInt(ty, x);
        if (value.isUnsigned128(ev.ip, ty)) if (b.toInt(u128)) |x| return Val.ofInt(ty, @bitCast(x)) else |_| {};
        return .{ .ty = ty, .v = .{ .big = b } };
    }

    /// The integer `x`, stored as a value of type `from` (an integer type or comptime_int), as a
    /// value of the integer type `to`; null when it is out of range
    fn convertInt(ev: *Evaluator, from: Index, to: Index, x: i128) EvalError!?Val {
        const ip = ev.ip;
        // A u128 value above i128's range is stored as its bit pattern (a negative i128)
        if (x < 0 and value.isUnsigned128(ip, from)) {
            if (value.isUnsigned128(ip, to)) return Val.ofInt(to, x);
            if (!value.isBigIntType(ip, to)) return null;
            return Val.ofBig(to, try value.bigOfInt(ip, ev.a, from, x));
        }
        if (!value.intFits(ip, to, x)) return null;
        return Val.ofInt(to, x);
    }

    fn intArg(ev: *Evaluator, v: Val) EvalError!i128 {
        return ev.intOf(v) orelse error.Abort;
    }

    fn asType(v: Val) EvalError!Index {
        if (v.ty != .type_type) return error.Abort;
        const t = switch (v.v) {
            .ip => |x| x,
            else => return error.Abort,
        };
        if (t == .unknown) return error.Abort;
        return t;
    }

    /// String value: `[:0]const u8`
    fn string(ev: *Evaluator, s: []const u8) Error!Val {
        const ty = try ev.stringSliceType();
        return Val.of(ty, try ev.ip.get(.{ .bytes = .{ .ty = ty, .bytes = s } }));
    }

    /// String literal value: `*const [len:0]u8`
    fn stringLiteral(ev: *Evaluator, s: []const u8) Error!Val {
        const ty = try ev.ip.stringLiteralType(s.len);
        return Val.of(ty, try ev.ip.get(.{ .bytes = .{ .ty = ty, .bytes = s } }));
    }

    fn stringSliceType(ev: *Evaluator) Error!Index {
        const zero = try ev.ip.get(.{ .int_value = .{ .ty = .u8_type, .value = 0 } });
        return ev.ip.get(.{ .ptr_type = .{ .child = .u8_type, .size = .slice, .is_const = true, .sentinel = zero } });
    }

    /// Content of a string
    fn stringOf(ev: *Evaluator, v: Val) EvalError![]const u8 {
        const x = try ev.freeze(v) orelse return error.Abort;
        return switch (ev.ip.key(x)) {
            .bytes => |b| b.bytes,
            .aggregate => |agg| blk: {
                const out = try ev.a.alloc(u8, agg.elems.len);
                for (agg.elems, out) |e, *o| o.* = std.math.cast(u8, value.intOf(ev.ip, e) orelse return error.Abort) orelse return error.Abort;
                break :blk out;
            },
            .ptr_value => |p| ev.stringOf(Val.of(ev.pointeeType(v.ty), p.pointee)),
            else => error.Abort,
        };
    }

    fn stringsOf(ev: *Evaluator, v: Val) EvalError![]const []const u8 {
        const n = try ev.elemCount(v) orelse return error.Abort;
        const out = try ev.a.alloc([]const u8, n);
        for (out, 0..) |*o, i| o.* = try ev.stringOf(try ev.elemAt(v, i));
        return out;
    }

    fn typesOf(ev: *Evaluator, v: Val) EvalError![]const Index {
        const n = try ev.elemCount(v) orelse return error.Abort;
        const out = try ev.a.alloc(Index, n);
        for (out, 0..) |*o, i| {
            const elem = try ev.elemAt(v, i);
            // Optional payloads in `[]const ?type`
            o.* = if (try ev.ipOf(elem)) |x| (if (x == .null_value) return error.Abort else x) else return error.Abort;
        }
        return out;
    }

    fn intsOf(ev: *Evaluator, v: Val) EvalError![]const i128 {
        const n = try ev.elemCount(v) orelse return error.Abort;
        const out = try ev.a.alloc(i128, n);
        for (out, 0..) |*o, i| o.* = try ev.intArg(try ev.elemAt(v, i));
        return out;
    }

    fn tagName(ev: *Evaluator, v: Val) EvalError![]const u8 {
        const x = try ev.freeze(v) orelse return error.Abort;
        return switch (ev.ip.key(x)) {
            .enum_tag => |t| t.name,
            .enum_literal => |n| n,
            .union_value => |u| u.tag,
            else => error.Abort,
        };
    }

    fn boolField(ev: *Evaluator, v: Val, name: []const u8) EvalError!bool {
        const fv = ev.fieldAccess(v, name) catch |err| switch (err) {
            error.Abort => return false,
            else => |x| return x,
        };
        return (try ev.condition(fv)).yes;
    }

    /// Value of an optional field of the attributes passed to a reifying builtin: `null_value`
    /// when it is null or absent (a struct literal leaves it at its default); unknown when it
    /// cannot be evaluated
    fn optionalAttr(ev: *Evaluator, v: Val, name: []const u8) EvalError!Index {
        const fields = try ev.fieldsOf(v.ty) orelse return .unknown;
        for (fields) |fl| {
            if (!std.mem.eql(u8, fl.name, name)) continue;
            const fv = ev.fieldAccess(v, name) catch |err| switch (err) {
                error.Abort => return .unknown,
                else => |x| return x,
            };
            return try ev.freeze(fv) orelse .unknown;
        }
        return .null_value;
    }

    /// Constructed type: its identity includes the construction site and the instance in which it
    /// was constructed
    fn reify(ev: *Evaluator, f: *Frame, e: ExprId, spec: struct {
        kind: InternPool.Reified.Kind,
        layout: InternPool.Reified.Layout = .auto,
        tag: ?Index = null,
        names: []const []const u8,
        types: []const Index = &.{},
        values: []const i128 = &.{},
        nonexhaustive: bool = false,
        field_aligns: []const u64 = &.{},
        comptime_fields: []const bool = &.{},
        attrs_unknown: bool = false,
    }) Error!Index {
        const tree = try ev.r.itemTree(f.file);
        return ev.ip.get(.{ .reified_type = .{
            .kind = spec.kind,
            .file = f.file,
            .owner = tree.items[f.item].ast_id,
            .expr = @backingInt(e),
            .inst = f.inst,
            .layout = spec.layout,
            .tag = spec.tag,
            .names = spec.names,
            .types = spec.types,
            .values = spec.values,
            .nonexhaustive = spec.nonexhaustive,
            .field_aligns = spec.field_aligns,
            .comptime_fields = spec.comptime_fields,
            .attrs_unknown = spec.attrs_unknown,
        } });
    }

    // ── Layout ───────────────────────────────────────────────────────

    /// Type layout; containers follow the compiler's layout algorithm (Sema/type_resolution.zig)
    fn typeLayout(ev: *Evaluator, t: Index, depth: u32) EvalError!?value.Layout {
        const ip = ev.ip;
        if (depth > max_layout_depth) return null;
        switch (ip.key(t)) {
            .optional_type => |c| return value.optionalLayout(ip, c, try ev.typeLayout(c, depth + 1) orelse return null),
            .array_type => |a| return value.arrayLayout(try ev.typeLayout(a.child, depth + 1) orelse return null, a, try ev.hasBitRepr(a.child)),
            .error_union_type => |eu| return value.errorUnionLayout(ip, try ev.typeLayout(eu.payload, depth + 1) orelse return null),
            .container_type, .reified_type, .union_tag_type, .tuple_type, .anon_struct_type => {},
            else => return value.typeLayout(ip, t),
        }
        // Enum: its tag integer
        if (value.isEnumType(ip, t)) return value.typeLayout(ip, try ev.enumTagType(t) orelse return null);
        const fields = try ev.layoutFields(t, depth) orelse return null;
        if (ev.isUnion(t)) return ev.unionLayout(t, try ev.containerSyntax(t), fields, depth);
        return (try ev.structLayoutOf(t, fields) orelse return null).layout;
    }

    /// Bit offset of a struct field; null for comptime fields and when it cannot be evaluated
    fn bitOffsetOf(ev: *Evaluator, t: Index, field: []const u8) EvalError!?u64 {
        // Only structs have field offsets
        if (ev.isUnion(t) or value.isEnumType(ev.ip, t)) return null;
        const i = try ev.fieldIndex(t, field) orelse return null;
        const fields = try ev.layoutFields(t, 0) orelse return null;
        const sl = try ev.structLayoutOf(t, fields) orelse return null;
        return sl.bit_offsets[i];
    }

    /// Attributes of a pointer to the field `name` (of type `field_ty`) of a value of type `agg`
    /// reached through a pointer with attributes `parent` (the compiler's `Type.fieldPtrType` and
    /// `fieldPtrAlign`): a field of a packed struct is a bit pointer into the host integer, and the
    /// alignment follows the field's offset in an extern struct and the aggregate's alignment
    /// where that is lower than the field's
    fn fieldPtrAttrs(ev: *Evaluator, parent: InternPool.PtrAttrs, agg: Index, name: []const u8, field_ty: Index) EvalError!InternPool.PtrAttrs {
        var out = parent;
        if (parent.alignment == .unknown) return out;
        // Slices (`ptr`, `len`) have the default layout and no explicit field alignment
        const fields = try ev.fieldsOf(agg) orelse return ev.autoFieldPtrAttrs(out, agg, field_ty, null);
        const i = for (fields, 0..) |fl, i| {
            if (std.mem.eql(u8, fl.name, name)) break i;
        } else return withUnknownAlign(out);
        const attrs = ev.fieldAttrs(agg, i, fields[i]) catch |err| switch (err) {
            error.Abort => return withUnknownAlign(out),
            else => |x| return x,
        };
        // A comptime field: exactly the alignment specified
        if (attrs.is_comptime) {
            out.alignment = if (attrs.alignment) |a| .fromBytes(a) else .natural;
            return out;
        }
        const layout = (try ev.containerSyntax(agg)).layout;
        if (layout == .auto) return ev.autoFieldPtrAttrs(out, agg, field_ty, attrs.alignment);
        if (ev.isUnion(agg)) {
            // An extern or packed union: the alignment of the union pointer
            if (parent.alignment == .natural) {
                const field_align = try ev.abiAlign(field_ty) orelse return withUnknownAlign(out);
                const agg_align = try ev.abiAlign(agg) orelse return withUnknownAlign(out);
                if (field_align != agg_align) out.alignment = .fromBytes(agg_align);
            }
            return out;
        }
        const lf = try ev.layoutFields(agg, 0) orelse return withUnknownAlign(out);
        const sl = try ev.structLayoutOf(agg, lf) orelse return withUnknownAlign(out);
        const agg_align = parent.alignment.bytes() orelse sl.layout.alignment;
        const bit_offset = sl.bit_offsets[i] orelse return withUnknownAlign(out);
        if (layout == .@"extern") {
            const offset = bit_offset / 8;
            const field_align = if (offset == 0) agg_align else @min(agg_align, @as(u64, 1) << @intCast(@ctz(offset)));
            const natural = lf[i].layout.?.alignment;
            out.alignment = if (parent.alignment == .natural and attrs.alignment == null and field_align == natural) .natural else .fromBytes(field_align);
            return out;
        }
        // A packed struct: a bit pointer into the host integer, aligned as the aggregate
        out.alignment = .fromBytes(agg_align);
        const field_bits = lf[i].layout.?.bits orelse return withUnknownAlign(out);
        const host: u64 = if (parent.host_size != 0) parent.host_size else packedHostSize(ev.ip, sl.layout) orelse return withUnknownAlign(out);
        const offset = @as(u64, parent.bit_offset) + bit_offset;
        if (host * 8 == field_bits) {
            out.host_size = 0;
            out.bit_offset = 0;
        } else {
            out.host_size = std.math.cast(u16, host) orelse return withUnknownAlign(out);
            out.bit_offset = std.math.cast(u16, offset) orelse return withUnknownAlign(out);
        }
        return out;
    }

    /// `fieldPtrAttrs` for an aggregate of the default layout: the lower of the aggregate's and
    /// the field's alignment, explicit unless it is the field type's own
    fn autoFieldPtrAttrs(ev: *Evaluator, parent: InternPool.PtrAttrs, agg: Index, field_ty: Index, explicit: ?u64) EvalError!InternPool.PtrAttrs {
        var out = parent;
        // The alignment of an aggregate is at least that of each field
        if (parent.alignment == .natural and explicit == null) return out;
        const natural = try ev.abiAlign(field_ty) orelse return withUnknownAlign(out);
        const field_align = explicit orelse natural;
        const agg_align = parent.alignment.bytes() orelse try ev.abiAlign(agg) orelse return withUnknownAlign(out);
        out.alignment = if (agg_align < field_align)
            .fromBytes(agg_align)
        else if (explicit == null and field_align == natural)
            .natural
        else
            .fromBytes(field_align);
        return out;
    }

    /// Attributes of a pointer to the element at `index` (null: a runtime index) of elements of
    /// type `elem` reached through a pointer with attributes `parent` (the compiler's
    /// `Type.elemPtrType`): with an explicit alignment, the alignment of the element's offset
    fn elemPtrAttrs(ev: *Evaluator, parent: InternPool.PtrAttrs, elem: Index, index: ?u64) EvalError!InternPool.PtrAttrs {
        var out = parent;
        out.is_allowzero = parent.is_allowzero and (index == null or index.? == 0);
        const bytes = parent.alignment.bytes() orelse return out;
        const l = try ev.typeLayout(elem, 0) orelse return withUnknownAlign(out);
        // Zero-size elements share the address of the first one
        if (l.size == 0) return out;
        // A runtime index gives the lowest alignment of any element but the first
        const i = index orelse 1;
        if (i == 0) return out;
        const offset = std.math.mul(u64, i, l.size) catch return withUnknownAlign(out);
        out.alignment = .fromBytes(@min(bytes, @as(u64, 1) << @intCast(@ctz(offset))));
        return out;
    }

    fn abiAlign(ev: *Evaluator, t: Index) EvalError!?u64 {
        return if (try ev.typeLayout(t, 0)) |l| l.alignment else null;
    }

    /// Whether the type has a bit representation: the bit width of an array requires its elements
    /// to have one (error sets and enums without a specified tag type have none, although
    /// `@bitSizeOf` can be evaluated on them)
    fn hasBitRepr(ev: *Evaluator, t: Index) EvalError!bool {
        switch (ev.ip.key(t)) {
            .error_set_type, .inferred_error_set => return false,
            .simple_type => |s| return s != .anyerror,
            .array_type => |a| return ev.hasBitRepr(a.child),
            .union_tag_type => |u| return (try ev.containerSyntax(u)).arg != null,
            .container_type => |c| return c.kind != .@"enum" or (try ev.containerSyntax(t)).arg != null,
            else => return true,
        }
    }

    /// Field types a packed container can contain: integers, floats, bool, void, enums with a
    /// specified tag type, and packed containers
    fn packable(ev: *Evaluator, t: Index) EvalError!bool {
        const ip = ev.ip;
        switch (ip.key(t)) {
            .int_type => return true,
            .simple_type => |s| return s == .void or s == .bool or value.intInfo(ip, t) != null or (ip.isFloat(t) and s != .comptime_float),
            .container_type, .reified_type, .union_tag_type => {
                if (value.isEnumType(ip, t)) return ev.hasBitRepr(t);
                return (try ev.containerSyntax(t)).layout == .@"packed";
            },
            else => return false,
        }
    }

    /// Field taking part in the layout: comptime fields take no space. `alignment` is the explicit
    /// alignment, or the type's alignment when none is specified.
    const LayoutField = struct { ty: Index, layout: ?value.Layout, alignment: u64 = 0, explicit_align: bool = false, is_comptime: bool = false };

    /// Layout of each field of a struct (including tuples and anonymous structs) or union; null
    /// when the layout or attributes of a field cannot be evaluated
    fn layoutFields(ev: *Evaluator, t: Index, depth: u32) EvalError!?[]const LayoutField {
        switch (ev.ip.key(t)) {
            .container_type => |c| if (c.kind == .@"opaque") return null,
            .reified_type, .tuple_type, .anon_struct_type => {},
            else => return null,
        }
        const fields = try ev.fieldsOf(t) orelse return null;
        const out = try ev.a.alloc(LayoutField, fields.len);
        for (fields, out, 0..) |fl, *o, i| {
            const attrs = try ev.fieldAttrs(t, i, fl);
            o.* = .{ .ty = fl.ty, .layout = null, .is_comptime = attrs.is_comptime };
            if (attrs.is_comptime) continue;
            const l = try ev.typeLayout(fl.ty, depth + 1) orelse return null;
            o.layout = l;
            o.alignment = attrs.alignment orelse l.alignment;
            o.explicit_align = attrs.alignment != null;
        }
        return out;
    }

    const FieldAttrs = struct { is_comptime: bool = false, alignment: ?u64 = null };

    /// The comptime flag and explicit alignment of fields in source code and of fields of
    /// constructed types; gives up when they cannot be evaluated
    fn fieldAttrs(ev: *Evaluator, t: Index, i: usize, fl: Field) EvalError!FieldAttrs {
        if (fl.item) |m| {
            const ns = try queries.namespaceOfType(ev.r, t) orelse return error.Abort;
            if ((try ev.r.itemTree(ns.file)).items[m].flags.is_comptime) return .{ .is_comptime = true };
            return .{ .alignment = try ev.explicitAlign(t, ns.file, m) };
        }
        return switch (ev.ip.key(t)) {
            .reified_type => |rt| if (rt.attrs_unknown) error.Abort else .{
                .is_comptime = i < rt.comptime_fields.len and rt.comptime_fields[i],
                .alignment = if (i < rt.field_aligns.len and rt.field_aligns[i] != 0) rt.field_aligns[i] else null,
            },
            // Give up when it cannot be determined whether a literal's field is comptime
            .tuple_type => |tt| literalFieldAttrs(tt.values, i),
            .anon_struct_type => |a| literalFieldAttrs(a.values, i),
            else => .{},
        };
    }

    /// Explicit alignment `align(N)` of a field in source code (in the signature-mode inference
    /// result); null when there is none, and gives up when it cannot be evaluated
    fn explicitAlign(ev: *Evaluator, t: Index, file: FileId, item: u32) EvalError!?u64 {
        const owner = try ev.r.ownerKey(file, item);
        const body = try ev.r.ctx.get(hir.ItemBody, owner);
        const e = body.align_expr orelse return null;
        const inst = try queries.declInst(ev.r, file, item, queries.instOfType(ev.ip, t));
        const res = try ev.r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .signature, .inst = inst });
        if (@backingInt(e) >= res.exprs.len) return error.Abort;
        return try alignValue(ev.ip, res.exprs[@backingInt(e)].val);
    }

    const StructLayout = struct { layout: value.Layout, bit_offsets: []const ?u64 };

    /// Layout and field bit offsets of a struct (including tuples and anonymous structs)
    fn structLayoutOf(ev: *Evaluator, t: Index, fields: []const LayoutField) EvalError!?StructLayout {
        if (ev.ip.key(t) == .tuple_type) return try ev.tupleLayout(fields);
        return ev.structLayout(try ev.containerSyntax(t), fields);
    }

    /// Layout of a tuple (the tuple branches of `Type.structFieldOffset` and `abiAlignment`): in
    /// declaration order, without reordering; comptime fields and zero-size fields take no space.
    /// The alignment counts zero-size fields, but the size is padded only to the alignment of the
    /// fields that have a size (matching the compiler: `struct { u8, [0]u64 }` has size 1 and
    /// alignment 8).
    fn tupleLayout(ev: *Evaluator, fields: []const LayoutField) Error!?StructLayout {
        const offsets = try ev.a.alloc(?u64, fields.len);
        var end: u64 = 0;
        var size_align: u64 = 1;
        var alignment: u64 = 1;
        for (fields, offsets) |fl, *o| {
            if (fl.is_comptime) {
                o.* = null;
                continue;
            }
            alignment = @max(alignment, fl.alignment);
            if (fl.layout.?.size == 0) {
                o.* = 0;
                continue;
            }
            size_align = @max(size_align, fl.alignment);
            const offset = value.alignForward(end, fl.alignment) orelse return null;
            o.* = value.bitsOf(offset) orelse return null;
            end = std.math.add(u64, offset, fl.layout.?.size) catch return null;
        }
        return .{ .layout = .{ .size = value.alignForward(end, size_align) orelse return null, .alignment = alignment, .bits = null }, .bit_offsets = offsets };
    }

    /// Layout of a struct and the bit offset of each field (null for comptime fields). The auto
    /// layout reorders fields by descending alignment, using `sortUnstable` like the compiler, so
    /// the order of fields with equal alignment matches as well.
    fn structLayout(ev: *Evaluator, decl: ContainerSyntax, fields: []const LayoutField) EvalError!?StructLayout {
        const offsets = try ev.a.alloc(?u64, fields.len);
        @memset(offsets, null);
        if (decl.layout == .@"packed") {
            var bits: u64 = 0;
            for (fields, offsets) |fl, *o| {
                const l = fl.layout orelse return null;
                // Packed fields cannot have an explicit alignment (the compiler reports an error)
                if (fl.explicit_align or !try ev.packable(fl.ty)) return null;
                o.* = bits;
                bits = std.math.add(u64, bits, l.bits orelse return null) catch return null;
            }
            // An explicit backing integer must match the sum of the fields' bit widths
            if (decl.arg) |arg| if ((value.intInfo(ev.ip, arg) orelse return null).bits != bits) return null;
            return .{ .layout = value.intLayout(ev.ip, std.math.cast(u16, bits) orelse return null) orelse return null, .bit_offsets = offsets };
        }
        const order = try ev.a.alloc(u32, fields.len);
        var struct_align: u64 = 1;
        for (fields, order, 0..) |fl, *o, i| {
            if (fl.is_comptime) {
                o.* = RuntimeOrder.omitted;
                continue;
            }
            o.* = @intCast(i);
            struct_align = @max(struct_align, fl.alignment);
        }
        if (decl.layout == .auto) std.mem.sortUnstable(u32, order, fields, RuntimeOrder.lessThan);
        var end: u64 = 0;
        for (order) |i| {
            if (i == RuntimeOrder.omitted) continue;
            const offset = value.alignForward(end, fields[i].alignment) orelse return null;
            offsets[i] = value.bitsOf(offset) orelse return null;
            end = std.math.add(u64, offset, fields[i].layout.?.size) catch return null;
        }
        return .{ .layout = .{ .size = value.alignForward(end, struct_align) orelse return null, .alignment = struct_align, .bits = null }, .bit_offsets = offsets };
    }

    /// In-memory order of fields: matches the compiler's comparison function; comptime fields last
    const RuntimeOrder = struct {
        const omitted = std.math.maxInt(u32);

        fn lessThan(fields: []const LayoutField, a: u32, b: u32) bool {
            if (a == omitted) return false;
            if (b == omitted) return true;
            return fields[a].alignment > fields[b].alignment;
        }
    };

    /// Layout of a union: for auto and extern, the largest field (plus the tag); for packed, all
    /// fields have the same bit width
    fn unionLayout(ev: *Evaluator, t: Index, decl: ContainerSyntax, fields: []const LayoutField, depth: u32) EvalError!?value.Layout {
        var payload_size: u64 = 0;
        var payload_align: u64 = 1;
        for (fields) |fl| {
            const l = fl.layout orelse return null;
            payload_size = @max(payload_size, l.size);
            payload_align = @max(payload_align, fl.alignment);
        }
        const payload: value.Layout = .{ .size = value.alignForward(payload_size, payload_align) orelse return null, .alignment = payload_align, .bits = null };
        switch (decl.layout) {
            .@"packed" => {
                if (fields.len == 0) return null;
                for (fields) |fl| if (fl.explicit_align or !try ev.packable(fl.ty)) return null;
                const bits = fields[0].layout.?.bits orelse return null;
                for (fields[1..]) |fl| if ((fl.layout.?.bits orelse return null) != bits) return null;
                if (decl.arg) |arg| if ((value.intInfo(ev.ip, arg) orelse return null).bits != bits) return null;
                return value.intLayout(ev.ip, std.math.cast(u16, bits) orelse return null);
            },
            .@"extern" => return payload,
            .auto => {},
        }
        // No tag when there is only one field
        if (fields.len < 2) return payload;
        const tag: value.Layout = if (try ev.unionTagType(t)) |tag_ty|
            try ev.typeLayout(tag_ty, depth + 1) orelse return null
        else if (try ev.safetyTagged(t) orelse return null)
            // The hidden tag is the same as that of `union(enum)`: the smallest unsigned integer
            // that holds the field index
            value.intLayout(ev.ip, @intCast(64 - @clz(@as(u64, fields.len - 1)))) orelse return null
        else
            return payload;
        const alignment = @max(tag.alignment, payload_align);
        const size = std.math.add(u64, tag.size, payload_size) catch return null;
        return .{ .size = value.alignForward(size, alignment) orelse return null, .alignment = alignment, .bits = null };
    }

    const ReifiedAttrs = struct { aligns: []const u64 = &.{}, comptimes: []const bool = &.{}, unknown: bool = false };

    /// Whether an untagged auto union has a hidden tag for safety checks (matching the compiler's
    /// `wantSafeTypes`): it does when the optimize mode of its module is Debug or ReleaseSafe. When
    /// the declaration is in a function body (including test and comptime blocks) that calls
    /// `@setRuntimeSafety`, it depends on the call's location and argument, so the result is null.
    fn safetyTagged(ev: *Evaluator, t: Index) EvalError!?bool {
        const file: FileId, const item: ?u32 = switch (ev.ip.key(t)) {
            .container_type => blk: {
                const ns = try queries.namespaceOfType(ev.r, t) orelse return null;
                break :blk .{ ns.file, (try ev.r.itemTree(ns.file)).containers[ns.container].parent_item };
            },
            .reified_type => |rt| blk: {
                const tree = try ev.r.itemTree(rt.file);
                for (tree.items, 0..) |it, i| if (it.ast_id == rt.owner) break :blk .{ rt.file, @as(?u32, @intCast(i)) };
                return null;
            },
            else => return null,
        };
        if (item) |i| switch ((try ev.r.itemTree(file)).items[i].kind) {
            .@"fn", .@"test", .@"comptime" => for ((try ev.r.body(file, i)).exprs) |e| switch (e) {
                .builtin_call => |c| if (std.mem.eql(u8, c.name, "@setRuntimeSafety")) return null,
                else => {},
            },
            else => {},
        };
        const builtin_file = try ev.r.resolveImport(file, "builtin") orelse return null;
        const builtin_ty = try queries.containerType(ev.r, .{ .file = builtin_file, .container = 0 }, null);
        const optimize = try ev.freeze(try ev.typeMember(builtin_ty, "optimize")) orelse return null;
        const name = switch (ev.ip.key(optimize)) {
            .enum_tag => |tag| tag.name,
            else => return null,
        };
        for ([_][]const u8{ "debug", "safe" }) |n| if (std.mem.eql(u8, name, n)) return true;
        for ([_][]const u8{ "fast", "small" }) |n| if (std.mem.eql(u8, name, n)) return false;
        return null;
    }

    /// Explicit alignments and comptime fields in the field attributes of `@Struct` / `@Union`
    /// (empty when all take the default)
    fn reifiedAttrs(ev: *Evaluator, attrs: Val, n: usize, is_union: bool) EvalError!ReifiedAttrs {
        return ev.readAttrs(attrs, n, is_union) catch |err| switch (err) {
            error.Abort => .{ .unknown = true },
            else => |x| x,
        };
    }

    fn readAttrs(ev: *Evaluator, attrs: Val, n: usize, is_union: bool) EvalError!ReifiedAttrs {
        if (try ev.elemCount(attrs) != n) return error.Abort;
        const aligns = try ev.a.alloc(u64, n);
        const comptimes = try ev.a.alloc(bool, n);
        var any_align = false;
        var any_comptime = false;
        for (aligns, comptimes, 0..) |*al, *ct, i| {
            const attr = try ev.elemAt(attrs, i);
            const x = try ev.freeze(try ev.fieldAccess(attr, "align")) orelse return error.Abort;
            al.* = if (x == .null_value) 0 else try alignValue(ev.ip, x);
            ct.* = !is_union and (try ev.condition(try ev.fieldAccess(attr, "comptime"))).yes;
            any_align = any_align or al.* != 0;
            any_comptime = any_comptime or ct.*;
        }
        return .{ .aligns = if (any_align) aligns else &.{}, .comptimes = if (any_comptime) comptimes else &.{} };
    }

    // ── @typeInfo ────────────────────────────────────────────────────

    /// Type in the standard library looked up by path (e.g. `builtin.Type`)
    fn stdType(ev: *Evaluator, path: []const []const u8) EvalError!Index {
        const std_root = try ev.r.ctx.get(database.ModuleGraph.StdRoot, ev.r.context) orelse return error.Abort;
        var t = try queries.containerType(ev.r, .{ .file = std_root, .container = 0 }, null);
        for (path) |name| t = try asType(try ev.typeMember(t, name));
        return t;
    }

    fn member(ev: *Evaluator, t: Index, name: []const u8) EvalError!Index {
        return asType(try ev.typeMember(t, name));
    }

    /// Value of type `t`: fields given by name, the rest take their default values
    fn structValue(ev: *Evaluator, t: Index, fields: []const struct { []const u8, Index }) EvalError!Index {
        const decl = try ev.fieldsOf(t) orelse return error.Abort;
        const elems = try ev.a.alloc(Index, decl.len);
        for (decl, elems) |d, *o| {
            o.* = for (fields) |fl| {
                if (std.mem.eql(u8, fl[0], d.name)) break fl[1];
            } else try ev.freeze(try ev.fieldDefault(t, d)) orelse return error.Abort;
        }
        return ev.aggregate(t, elems);
    }

    fn enumTag(ev: *Evaluator, t: Index, name: []const u8) Error!Index {
        return ev.ip.get(.{ .enum_tag = .{ .ty = t, .name = name } });
    }

    /// `[]const [:0]const u8`
    fn namesValue(ev: *Evaluator, names: []const []const u8) Error!Index {
        const ip = ev.ip;
        const str = try ev.stringSliceType();
        const ty = try ip.ptrTo(str, .slice, true);
        const elems = try ev.a.alloc(Index, names.len);
        for (names, elems) |n, *o| o.* = try ip.get(.{ .bytes = .{ .ty = str, .bytes = n } });
        return ip.get(.{ .aggregate = .{ .ty = ty, .elems = elems } });
    }

    fn sliceValue(ev: *Evaluator, child: Index, elems: []const Index) Error!Index {
        return ev.aggregate(try ev.ip.ptrTo(child, .slice, true), elems);
    }

    fn typeInfo(ev: *Evaluator, t: Index) EvalError!Index {
        const ip = ev.ip;
        const type_ty = try ev.stdType(&.{ "builtin", "Type" });
        const Payload = struct { []const u8, Index };
        const payload: Payload = switch (ip.key(t)) {
            .simple_type => |s| switch (s) {
                .type, .void, .bool, .noreturn, .comptime_int, .comptime_float, .null, .undefined, .enum_literal => .{ @tagName(s), .void_value },
                .anyerror => .{ "error_set", try ev.structValue(try ev.member(type_ty, "ErrorSet"), &.{.{ "error_names", .null_value }}) },
                .anyopaque => .{ "opaque", try ev.structValue(try ev.member(type_ty, "Opaque"), &.{.{ "decl_names", try ev.namesValue(&.{}) }}) },
                .f16, .f32, .f64, .f80, .f128 => .{ "float", try ev.structValue(try ev.member(type_ty, "Float"), &.{.{ "bits", try ev.intIndex(try ip.intType(.unsigned, 16), value.floatBits(ip, t).?) }}) },
                else => .{ "int", try ev.intInfoValue(type_ty, value.intInfo(ip, t) orelse return error.Abort) },
            },
            .int_type => .{ "int", try ev.intInfoValue(type_ty, value.intInfo(ip, t).?) },
            .ptr_type => |p| .{ "pointer", try ev.structValue(try ev.member(type_ty, "Pointer"), &.{
                .{ "size", try ev.enumTag(try ev.member(try ev.member(type_ty, "Pointer"), "Size"), @tagName(p.size)) },
                .{ "attrs", try ev.ptrAttrsInfo(try ev.member(try ev.member(type_ty, "Pointer"), "Attributes"), p) },
                .{ "child", p.child },
                .{ "sentinel_ptr", try ev.sentinelPtr(p.sentinel) },
            }) },
            .array_type => |a| .{ "array", try ev.structValue(try ev.member(type_ty, "Array"), &.{
                .{ "len", try ev.intIndex(.comptime_int_type, a.len) },
                .{ "child", a.child },
                .{ "sentinel_ptr", try ev.sentinelPtr(a.sentinel) },
            }) },
            .vector_type => |v| .{ "vector", try ev.structValue(try ev.member(type_ty, "Vector"), &.{
                .{ "len", try ev.intIndex(.comptime_int_type, v.len) },
                .{ "child", v.child },
            }) },
            .optional_type => |c| .{ "optional", try ev.structValue(try ev.member(type_ty, "Optional"), &.{.{ "child", c }}) },
            .error_union_type => |eu| .{ "error_union", try ev.structValue(try ev.member(type_ty, "ErrorUnion"), &.{ .{ "error_set", eu.err }, .{ "payload", eu.payload } }) },
            .error_set_type => |es| .{ "error_set", try ev.structValue(try ev.member(type_ty, "ErrorSet"), &.{.{ "error_names", try ev.namesValue(es.names) }}) },
            .inferred_error_set => .{ "error_set", try ev.structValue(try ev.member(type_ty, "ErrorSet"), &.{.{ "error_names", if (try queries.errorSetMembers(ev.r, t)) |names| try ev.namesValue(names) else .null_value }}) },
            .fn_type => |ft| blk: {
                const fn_ty = try ev.member(type_ty, "Fn");
                const cc = try ev.stdType(&.{ "builtin", "CallingConvention" });
                // As in the compiler, a function is generic when it has comptime parameters, or
                // parameter or return types that are generic or comptime-only; generic types are
                // null. Whether a type that is not fully known is comptime-only is unknown.
                var is_generic = ft.hasGenericParams() or ft.generic_ret;
                var undecided = false;
                const params = try ev.a.alloc(Index, ft.params.len);
                for (ft.params, params, 0..) |p, *o, i| {
                    if (InternPool.FnType.paramBit(ft.generic_bits, i)) {
                        o.* = .null_value;
                        continue;
                    }
                    o.* = p;
                    if (is_generic) continue;
                    if (try isComptimeOnly(ev.r, p)) is_generic = true else if (!value.isConcrete(ip, p)) undecided = true;
                }
                if (!is_generic) {
                    if (try isComptimeOnly(ev.r, ft.ret)) is_generic = true else if (!value.isConcrete(ip, ft.ret)) undecided = true;
                }
                const param_attrs = try ev.a.alloc(Index, ft.params.len);
                const pa_ty = try ev.member(fn_ty, "ParamAttributes");
                for (param_attrs, 0..) |*o, i| o.* = try ev.structValue(pa_ty, &.{
                    .{ "noalias", if (InternPool.FnType.paramBit(ft.noalias_bits, i)) .true_value else .false_value },
                });
                break :blk .{ "fn", try ev.structValue(fn_ty, &.{
                    .{ "attrs", try ev.structValue(try ev.member(fn_ty, "Attributes"), &.{
                        .{ "callconv", try ev.callConvInfo(cc, ft.cc) },
                        .{ "varargs", if (ft.varargs) .true_value else .false_value },
                    }) },
                    .{ "is_generic", if (is_generic) .true_value else if (undecided) .unknown else .false_value },
                    .{ "return_type", if (ft.generic_ret) .null_value else ft.ret },
                    .{ "param_types", try ev.sliceValue(try ip.optionalOf(.type_type), params) },
                    .{ "param_attrs", try ev.sliceValue(pa_ty, param_attrs) },
                }) };
            },
            .container_type, .reified_type, .tuple_type, .anon_struct_type, .union_tag_type => try ev.containerInfo(type_ty, t),
            else => return error.Abort,
        };
        return ip.get(.{ .union_value = .{ .ty = type_ty, .tag = payload[0], .payload = payload[1] } });
    }

    /// The value of `std.builtin.CallingConvention` (`cc_ty`) of a calling convention; unknown
    /// when it cannot be evaluated (`.c` on a target whose C calling convention is not known)
    fn callConvInfo(ev: *Evaluator, cc_ty: Index, cc: InternPool.CallConv) EvalError!Index {
        return switch (cc) {
            .other => |v| v,
            .unknown => .unknown,
            .c => blk: {
                const v = ev.typeMember(cc_ty, "c") catch |err| switch (err) {
                    error.Abort => break :blk .unknown,
                    else => |x| return x,
                };
                break :blk try ev.freeze(v) orelse .unknown;
            },
            else => ev.ip.get(.{ .union_value = .{ .ty = cc_ty, .tag = @tagName(cc), .payload = .void_value } }),
        };
    }

    /// `std.builtin.Type.Pointer.Attributes` of a pointer type: the address space is always given
    /// (`.generic` by default), the alignment only when written; attributes that cannot be
    /// evaluated are unknown
    fn ptrAttrsInfo(ev: *Evaluator, attrs_ty: Index, p: InternPool.PtrType) EvalError!Index {
        const a = p.attrs;
        const space: Index = if (a.address_space) |s| try ev.enumTag(try ev.stdType(&.{ "builtin", "AddressSpace" }), @tagName(s)) else .unknown;
        const alignment: Index = switch (a.alignment) {
            .natural => .null_value,
            .unknown => .unknown,
            _ => try ev.intIndex(.usize_type, a.alignment.bytes().?),
        };
        return ev.structValue(attrs_ty, &.{
            .{ "const", if (p.is_const) .true_value else .false_value },
            .{ "volatile", if (a.is_volatile) .true_value else .false_value },
            .{ "allowzero", if (a.is_allowzero or p.size == .c) .true_value else .false_value },
            .{ "addrspace", space },
            .{ "align", alignment },
        });
    }

    fn intIndex(ev: *Evaluator, ty: Index, x: anytype) Error!Index {
        return ev.ip.get(.{ .int_value = .{ .ty = ty, .value = @intCast(x) } });
    }

    fn intInfoValue(ev: *Evaluator, type_ty: Index, info: value.IntInfo) EvalError!Index {
        const signedness = try ev.stdType(&.{ "builtin", "Signedness" });
        return ev.structValue(try ev.member(type_ty, "Int"), &.{
            .{ "signedness", try ev.enumTag(signedness, if (info.signed) "signed" else "unsigned") },
            .{ "bits", try ev.intIndex(try ev.ip.intType(.unsigned, 16), info.bits) },
        });
    }

    /// Pointer to the sentinel value (`?*const anyopaque`)
    fn sentinelPtr(ev: *Evaluator, sentinel: ?Index) Error!Index {
        const s = sentinel orelse return .null_value;
        const ty = try ev.ip.ptrTo(.anyopaque_type, .one, true);
        return ev.ip.get(.{ .ptr_value = .{ .ty = ty, .pointee = s } });
    }

    /// `@typeInfo` of a container (struct, enum, union, opaque, tuple)
    fn containerInfo(ev: *Evaluator, type_ty: Index, t: Index) EvalError!struct { []const u8, Index } {
        const ip = ev.ip;
        const layout_ty = try ev.member(type_ty, "ContainerLayout");
        const decls = try ev.namesValue(try ev.declNames(t));
        if (value.isEnumType(ip, t)) {
            const names = try ev.enumNames(t) orelse return error.Abort;
            const values = try ev.enumValues(t);
            const value_elems = try ev.a.alloc(Index, values.len);
            for (values, value_elems) |v, *o| o.* = try ev.intIndex(.comptime_int_type, v);
            const enum_ty = try ev.member(type_ty, "Enum");
            return .{ "enum", try ev.structValue(enum_ty, &.{
                .{ "tag_type", try ev.enumTagType(t) orelse return error.Abort },
                .{ "mode", try ev.enumTag(try ev.member(enum_ty, "Mode"), if (try ev.nonexhaustive(t)) "nonexhaustive" else "exhaustive") },
                .{ "field_names", try ev.namesValue(names) },
                .{ "field_values", try ev.sliceValue(.comptime_int_type, value_elems) },
                .{ "decl_names", decls },
            }) };
        }
        switch (ip.key(t)) {
            .container_type => |c| if (c.kind == .@"opaque") return .{ "opaque", try ev.structValue(try ev.member(type_ty, "Opaque"), &.{.{ "decl_names", decls }}) },
            else => {},
        }
        const fields = try ev.fieldsOf(t) orelse return error.Abort;
        const names = try ev.a.alloc([]const u8, fields.len);
        const types = try ev.a.alloc(Index, fields.len);
        for (fields, names, types) |fl, *n, *ty| {
            n.* = fl.name;
            ty.* = fl.ty;
            if (fl.ty == .unknown) return error.Abort;
        }
        const layout = try ev.layoutOf(t);
        if (ev.isUnion(t)) {
            const union_ty = try ev.member(type_ty, "Union");
            const fa_ty = try ev.member(union_ty, "FieldAttributes");
            const attrs = try ev.a.alloc(Index, fields.len);
            for (fields, attrs, 0..) |fl, *o, i| {
                const fa = try ev.fieldAttrs(t, i, fl);
                o.* = try ev.structValue(fa_ty, &.{.{ "align", try ev.alignAttr(fa.alignment) }});
            }
            const tag = try ev.unionTagType(t);
            return .{ "union", try ev.structValue(union_ty, &.{
                .{ "layout", try ev.enumTag(layout_ty, @tagName(layout)) },
                .{ "tag_type", tag orelse .null_value },
                .{ "backing_integer", try ev.backingInteger(t, layout, types, true) },
                .{ "field_names", try ev.namesValue(names) },
                .{ "field_types", try ev.sliceValue(.type_type, types) },
                .{ "field_attrs", try ev.sliceValue(fa_ty, attrs) },
                .{ "decl_names", decls },
            }) };
        }
        const struct_ty = try ev.member(type_ty, "Struct");
        const fa_ty = try ev.member(struct_ty, "FieldAttributes");
        const attrs = try ev.a.alloc(Index, fields.len);
        for (fields, attrs, 0..) |fl, *o, i| {
            const fa = try ev.fieldAttrs(t, i, fl);
            // Comptime fields of tuple / anonymous struct literals: the value belongs to the type
            const literal_value: ?Index = switch (ip.key(t)) {
                .tuple_type => |tt| InternPool.fieldValue(tt.values, i),
                .anon_struct_type => |a| InternPool.fieldValue(a.values, i),
                else => null,
            };
            o.* = try ev.structValue(fa_ty, &.{
                .{ "comptime", if (fa.is_comptime) .true_value else .false_value },
                .{ "align", try ev.alignAttr(fa.alignment) },
                .{ "default_value_ptr", if (fa.is_comptime and literal_value != null) try ev.anyopaquePtr(literal_value.?) else try ev.defaultPtr(t, fl) },
            });
        }
        return .{ "struct", try ev.structValue(struct_ty, &.{
            .{ "is_tuple", if (ip.key(t) == .tuple_type) .true_value else .false_value },
            .{ "layout", try ev.enumTag(layout_ty, @tagName(layout)) },
            .{ "backing_integer", try ev.backingInteger(t, layout, types, false) },
            .{ "field_names", try ev.namesValue(names) },
            .{ "field_types", try ev.sliceValue(.type_type, types) },
            .{ "field_attrs", try ev.sliceValue(fa_ty, attrs) },
            .{ "decl_names", decls },
        }) };
    }

    /// `*const anyopaque` pointing to a value (the default value of a field)
    fn anyopaquePtr(ev: *Evaluator, v: Index) Error!Index {
        const ty = try ev.ip.ptrTo(.anyopaque_type, .one, true);
        return ev.ip.get(.{ .ptr_value = .{ .ty = ty, .pointee = v } });
    }

    /// `align` in the field attributes (`?usize`)
    fn alignAttr(ev: *Evaluator, alignment: ?u64) Error!Index {
        return if (alignment) |a| ev.intIndex(.usize_type, a) else .null_value;
    }

    /// Pointer to the default value of a field; points to an unknown value when there is a default
    /// value that cannot be evaluated
    fn defaultPtr(ev: *Evaluator, t: Index, field: Field) EvalError!Index {
        const item = field.item orelse return .null_value;
        const ns = try queries.namespaceOfType(ev.r, t) orelse return .null_value;
        const body = try ev.r.ctx.get(hir.ItemBody, try ev.r.ownerKey(ns.file, item));
        if (body.value == null) return .null_value;
        const v = ev.fieldDefault(t, field) catch |err| switch (err) {
            error.Abort => Val.unknown,
            else => |x| return x,
        };
        const ty = try ev.ip.ptrTo(.anyopaque_type, .one, true);
        return ev.ip.get(.{ .ptr_value = .{ .ty = ty, .pointee = try ev.freeze(v) orelse .unknown } });
    }

    /// Names of the pub declarations of a source container
    fn declNames(ev: *Evaluator, t: Index) Error![]const []const u8 {
        const ns = try queries.namespaceOfType(ev.r, t) orelse return &.{};
        const tree = try ev.r.itemTree(ns.file);
        var out: std.ArrayList([]const u8) = .empty;
        for (tree.containerMembers(ns.container)) |m| {
            const it = tree.items[m];
            switch (it.kind) {
                .@"fn", .@"const", .@"var" => if (it.flags.is_pub) if (it.name) |n| try out.append(ev.a, n),
                else => {},
            }
        }
        return out.items;
    }

    const ContainerSyntax = struct { layout: InternPool.Reified.Layout = .auto, auto_enum: bool = false, arg: ?Index = null };

    /// Syntactic information of a container declaration: layout, `union(enum)`, and the value of
    /// the argument expression
    fn containerSyntax(ev: *Evaluator, t: Index) EvalError!ContainerSyntax {
        const ip = ev.ip;
        switch (ip.key(t)) {
            .reified_type => |rt| return .{ .layout = rt.layout, .arg = rt.tag },
            .container_type => |c| {
                const ns = try queries.namespaceOfType(ev.r, t) orelse return .{};
                // The layout modifier is recorded in the ItemTree (it does not change with edits
                // while the structure stays the same); the syntax tree is not read
                const container = (try ev.r.itemTree(ns.file)).containers[ns.container];
                var out: ContainerSyntax = .{
                    .layout = switch (container.layout) {
                        .auto => .auto,
                        .@"packed" => .@"packed",
                        .@"extern" => .@"extern",
                    },
                    .auto_enum = container.auto_enum,
                };
                out.arg = try ev.containerArg(ns, c.inst);
                return out;
            },
            else => return .{},
        }
    }

    /// Argument of `enum(u8)` / `union(E)` / `packed struct(u32)` (in the inference result of the
    /// enclosing member)
    fn containerArg(ev: *Evaluator, ns: Namespace, inst: ?Index) Error!?Index {
        return (try containerArgValue(ev.r, ns, inst) orelse return null).asType();
    }

    fn layoutOf(ev: *Evaluator, t: Index) EvalError!InternPool.Reified.Layout {
        return (try ev.containerSyntax(t)).layout;
    }

    /// Tag integer type of an enum: the explicit one of `enum(u8)`, otherwise the unsigned integer
    /// that holds the largest value
    fn enumTagType(ev: *Evaluator, t: Index) EvalError!?Index {
        const ip = ev.ip;
        switch (ip.key(t)) {
            .container_type, .reified_type => if ((try ev.containerSyntax(t)).arg) |arg| return arg,
            // Tag enum of `union(enum(u8))`
            .union_tag_type => |u| if ((try ev.containerSyntax(u)).arg) |arg| return arg,
            else => {},
        }
        const values = try ev.enumValues(t);
        // An exhaustive enum without members has no values: the compiler gives it `noreturn`
        if (values.len == 0) return .noreturn_type;
        var max: i128 = 0;
        for (values) |v| max = @max(max, v);
        const bits: u16 = if (max == 0) 0 else @intCast(128 - @clz(@as(u128, @intCast(max))));
        return try ip.intType(.unsigned, bits);
    }

    fn nonexhaustive(ev: *Evaluator, t: Index) Error!bool {
        switch (ev.ip.key(t)) {
            .reified_type => |rt| return rt.nonexhaustive,
            .container_type => {
                const ns = try queries.namespaceOfType(ev.r, t) orelse return false;
                const tree = try ev.r.itemTree(ns.file);
                return tree.containers[ns.container].nonexhaustive;
            },
            else => return false,
        }
    }

    /// Tag type of a union: E for `union(E)`, the automatically generated tag enum for
    /// `union(enum)`, otherwise null. The argument of a packed union is its backing integer, not
    /// a tag type.
    fn unionTagType(ev: *Evaluator, t: Index) EvalError!?Index {
        const s = try ev.containerSyntax(t);
        if (s.auto_enum) return try ev.ip.get(.{ .union_tag_type = t });
        if (s.layout == .@"packed") return null;
        return s.arg;
    }

    fn backingIntType(ev: *Evaluator, t: Index) EvalError!?Index {
        const ip = ev.ip;
        if (value.isEnumType(ip, t)) return ev.enumTagType(t);
        switch (ip.key(t)) {
            .container_type, .reified_type => {},
            else => return null,
        }
        const decl = try ev.containerSyntax(t);
        // Packed container without an explicit backing integer: the compiler reports an error for
        // `@backingInt`
        if (decl.layout == .@"packed") return decl.arg;
        if (ev.isUnion(t)) if (try ev.unionTagType(t)) |tag| return ev.enumTagType(tag);
        return null;
    }

    /// Backing integer of a packed struct or union (a value of `?type`): the explicit argument,
    /// otherwise an unsigned integer as wide as the fields together (struct) or as the widest
    /// field (union)
    fn backingInteger(ev: *Evaluator, t: Index, layout: InternPool.Reified.Layout, types: []const Index, is_union: bool) EvalError!Index {
        if (layout != .@"packed") return .null_value;
        if ((try ev.containerSyntax(t)).arg) |arg| return arg;
        var bits: u64 = 0;
        for (types) |ty| {
            const field_bits = (try ev.typeLayout(ty, 0) orelse return error.Abort).bits orelse return error.Abort;
            bits = if (is_union) @max(bits, field_bits) else std.math.add(u64, bits, field_bits) catch return error.Abort;
        }
        return ev.ip.intType(.unsigned, std.math.cast(u16, bits) orelse return error.Abort);
    }
};

/// The `@fieldParentPtr` call that the casts at `e` are merged into (the compiler's AstGen
/// `ptrCast`): `@alignCast`, `@addrSpaceCast`, `@constCast` and `@volatileCast` around
/// `@fieldParentPtr`. With `@ptrCast` in the chain nothing is merged, and `@fieldParentPtr` has
/// no result type.
fn mergedFieldParentPtr(body: *const Body, e: ExprId) ?ExprId {
    const merged = [_][]const u8{ "@alignCast", "@addrSpaceCast", "@constCast", "@volatileCast" };
    var cur = e;
    var depth: usize = 0;
    while (true) : (depth += 1) {
        const bc = switch (body.expr(cur)) {
            .builtin_call => |c| c,
            else => return null,
        };
        if (std.mem.eql(u8, bc.name, "@fieldParentPtr")) return if (depth > 0 and bc.args.len == 2) cur else null;
        for (merged) |name| {
            if (std.mem.eql(u8, bc.name, name)) break;
        } else return null;
        if (bc.args.len != 1) return null;
        cur = bc.args[0];
    }
}

fn compareBig(op: SyntaxKind, x: bigint.Big, y: bigint.Big) bool {
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

fn compareNumbers(op: SyntaxKind, x: anytype, y: @TypeOf(x)) bool {
    return switch (op) {
        .equal_equal => x == y,
        .bang_equal => x != y,
        .angle_bracket_left => x < y,
        .angle_bracket_right => x > y,
        .angle_bracket_left_equal => x <= y,
        else => x >= y,
    };
}

/// Result type of a float operation: comptime_float takes the other side's type; when integers
/// and floats are mixed, the float type
fn peerFloatType(ip: *InternPool, a: Index, b: Index) ?Index {
    if (a == b) return a;
    if (a == .comptime_float_type or a == .comptime_int_type) return if (ip.isFloat(b)) b else null;
    if (b == .comptime_float_type or b == .comptime_int_type) return if (ip.isFloat(a)) a else null;
    return null;
}

/// What a builtin whose destination type is its result type strips from the result type: the
/// strategies of the compiler's `resolveDestType`
pub const DestStrip = enum { eu_opt, eu, opt };

/// Cast builtins whose destination type is their result type, and what they strip from it (the
/// `resolveDestType` calls in the compiler's Sema); null for other builtins. `@splat` and
/// `@fromBackingInt` also strip `.eu_opt`, but give their operands result types derived from the
/// destination type, so their callers handle them.
pub fn castDestStrip(name: []const u8) ?DestStrip {
    const casts = [_]struct { []const u8, DestStrip }{
        .{ "@intCast", .eu_opt },      .{ "@truncate", .eu_opt },    .{ "@floatCast", .eu_opt }, .{ "@floatFromInt", .eu_opt },
        .{ "@intFromFloat", .eu_opt }, .{ "@enumFromInt", .eu_opt }, .{ "@bitCast", .eu_opt },   .{ "@ptrCast", .eu },
        .{ "@alignCast", .eu },        .{ "@addrSpaceCast", .eu },   .{ "@ptrFromInt", .eu },    .{ "@fieldParentPtr", .eu },
        .{ "@errorCast", .opt },
    };
    for (casts) |c| if (std.mem.eql(u8, name, c[0])) return c[1];
    return null;
}

/// Destination type of a builtin with result type `want`, as in the compiler's
/// `resolveDestType`: an error union is replaced by its payload (unless `strip` is `.opt`), then
/// an optional by its child (unless `strip` is `.eu`); null without a known result type
pub fn destType(ip: *InternPool, want: ?Index, strip: DestStrip) ?Index {
    var t = want orelse return null;
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

/// Whether a field of a tuple or anonymous struct literal is comptime; gives up when it cannot
/// be determined
fn literalFieldAttrs(values: []const Index, i: usize) EvalError!Evaluator.FieldAttrs {
    const v = InternPool.fieldValue(values, i);
    if (v == .unknown) return error.Abort;
    return .{ .is_comptime = v != .runtime };
}

/// Alignment value: must be a power of two (otherwise the compiler reports an error); gives up
/// when it cannot be evaluated
fn alignValue(ip: *InternPool, v: ?Index) EvalError!u64 {
    const x = value.intOf(ip, v) orelse return error.Abort;
    if (x <= 0 or x & (x - 1) != 0) return error.Abort;
    return std.math.cast(u64, x) orelse error.Abort;
}

/// Values of the clauses of a written pointer type: null when the clause is absent or its value
/// is not known
pub const PtrClauseValues = struct {
    @"align": ?Index = null,
    bit_offset: ?Index = null,
    host_size: ?Index = null,
    @"addrspace": ?Index = null,
};

/// Attributes of the pointer type `p` with child `child`, from the values of its clauses (see
/// `PtrClauseValues`). A clause whose value is not known gives an unknown attribute. As in the
/// compiler, a bit range covering the whole child is no bit range (`*align(1:0:1) u8` is
/// `*align(1) u8`).
pub fn ptrAttrs(r: *Resolver, child: Index, p: Body.PtrType, vals: PtrClauseValues) Error!InternPool.PtrAttrs {
    const ip = r.ctx.db.env.ip;
    var a: InternPool.PtrAttrs = .{ .is_volatile = p.is_volatile, .is_allowzero = p.is_allowzero };
    if (p.@"align" != null) a.alignment = alignmentOf(ip, vals.@"align");
    if (p.host_size != null) bits: {
        const offset = std.math.cast(u16, value.intOf(ip, vals.bit_offset) orelse -1);
        const host = std.math.cast(u16, value.intOf(ip, vals.host_size) orelse -1);
        if (offset == null or host == null) {
            // The bit range is part of the type: without it the type is not known
            a.alignment = .unknown;
            break :bits;
        }
        if (host.? == 0) break :bits;
        a.host_size = host.?;
        a.bit_offset = offset.?;
        const layout = try typeLayout(r, child) orelse break :bits;
        if (layout.bits == @as(u64, host.?) * 8) {
            a.host_size = 0;
            a.bit_offset = 0;
        }
    }
    if (p.@"addrspace" != null) a.address_space = addressSpaceOf(ip, vals.@"addrspace");
    return a;
}

/// See `Evaluator.fieldPtrAttrs`; the alignment is unknown when the layout cannot be evaluated
pub fn fieldPtrAttrs(r: *Resolver, parent: InternPool.PtrAttrs, agg: Index, name: []const u8, field_ty: Index) Error!InternPool.PtrAttrs {
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = r.arena };
    defer ev.deinit();
    return ev.fieldPtrAttrs(parent, agg, name, field_ty) catch |err| switch (err) {
        error.Abort, error.Break, error.Continue, error.Return => withUnknownAlign(parent),
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// See `Evaluator.elemPtrAttrs`; the alignment is unknown when the layout cannot be evaluated
pub fn elemPtrAttrs(r: *Resolver, parent: InternPool.PtrAttrs, elem: Index, index: ?u64) Error!InternPool.PtrAttrs {
    // A pointer without an explicit alignment needs no layout
    if (parent.alignment.bytes() == null) {
        var out = parent;
        out.is_allowzero = parent.is_allowzero and (index == null or index.? == 0);
        return out;
    }
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = r.arena };
    defer ev.deinit();
    return ev.elemPtrAttrs(parent, elem, index) catch |err| switch (err) {
        error.Abort, error.Break, error.Continue, error.Return => withUnknownAlign(parent),
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Alignment of a pointer to a container-level variable or constant: the `align(...)` of its
/// declaration (in instance `inst`)
pub fn declAlignment(r: *Resolver, file: FileId, item: u32, inst: ?Index) Error!InternPool.Alignment {
    const owner = try r.ownerKey(file, item);
    const body = try r.ctx.get(hir.ItemBody, owner);
    const e = body.align_expr orelse return .natural;
    const res = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .signature, .inst = try queries.declInst(r, file, item, inst) });
    if (@backingInt(e) >= res.exprs.len) return .unknown;
    return alignmentOf(r.ctx.db.env.ip, res.exprs[@backingInt(e)].val);
}

fn withUnknownAlign(attrs: InternPool.PtrAttrs) InternPool.PtrAttrs {
    var out = attrs;
    out.alignment = .unknown;
    return out;
}

/// Byte size of the host integer of bit pointers into a packed struct with layout `l` (the
/// compiler's `fieldPtrType`): the bytes holding its bits, except on the self-hosted x86_64 and
/// C backends, which take its ABI size; null when that differs and the backend is not known
fn packedHostSize(ip: *InternPool, l: value.Layout) ?u64 {
    const bytes = ((l.bits orelse return null) + 7) / 8;
    if (bytes == l.size) return bytes;
    return switch (ip.vectorAbi()) {
        .x86_64, .x86_64_avx, .x86_64_avx512 => l.size,
        .llvm, .llvm_stack_align_8, .llvm_stack_align_16 => bytes,
        // The C and wasm backends share a vector layout but not this rule
        .elem, .unknown => null,
    };
}

/// Alignment given by the value of an `align` expression; unknown when the value is not known or
/// not a valid alignment
pub fn alignmentOf(ip: *InternPool, v: ?Index) InternPool.Alignment {
    const x = value.intOf(ip, v) orelse return .unknown;
    return .fromBytes(std.math.cast(u64, x) orelse return .unknown);
}

/// Address space named by the value of an `addrspace` expression (a member of
/// `std.builtin.AddressSpace`, or an enum literal); null when it is not known
pub fn addressSpaceOf(ip: *InternPool, v: ?Index) ?std.builtin.AddressSpace {
    const name = switch (ip.key(v orelse return null)) {
        .enum_tag => |t| t.name,
        .enum_literal => |n| n,
        else => return null,
    };
    return std.meta.stringToEnum(std.builtin.AddressSpace, name);
}

/// Calling convention given by a value of `std.builtin.CallingConvention` (or an enum literal):
/// the target's C calling convention is `.c`, as the compiler prints and compares it; unknown
/// when the value, or for options other than a bare tag the C calling convention, cannot be
/// evaluated
pub fn callConv(r: *Resolver, v: ?Index) Error!InternPool.CallConv {
    const ip = r.ctx.db.env.ip;
    const val = v orelse return .unknown;
    const u = switch (ip.key(val)) {
        .union_value => |u| u,
        .enum_literal => |n| return InternPool.CallConv.fromName(n) orelse .unknown,
        else => return .unknown,
    };
    if (InternPool.CallConv.fromName(u.tag)) |cc| return cc;
    const c = try typeMember(r, u.ty, "c") orelse return .unknown;
    const c_val = c.val orelse return .unknown;
    return if (c_val == val) .c else .{ .other = val };
}

pub const FnTypeBits = struct { comptime_bits: u32 = 0, noalias_bits: u32 = 0, generic_bits: u32 = 0 };
/// The parameter attributes of a function type expression (`InternPool.FnType`). Its parameter
/// types cannot refer to its parameters (their names are not in scope), so only `anytype`
/// parameters are generic.
pub fn fnTypeBits(params: []const Body.FnTypeParam) FnTypeBits {
    var out: FnTypeBits = .{};
    for (params, 0..) |p, i| {
        const bit = InternPool.FnType.bitOf(i) orelse continue;
        if (p.is_comptime) out.comptime_bits |= bit;
        if (p.is_noalias) out.noalias_bits |= bit;
        if (p.ty == null) out.generic_bits |= bit;
    }
    return out;
}
/// Calling convention written as `callconv(e)`, where `e` has the value `v`: `.c` and the tags
/// without options are known from the syntax
pub fn writtenCallConv(r: *Resolver, body: *const Body, e: ExprId, v: ?Index) Error!InternPool.CallConv {
    switch (body.expr(e)) {
        .enum_literal => |n| if (InternPool.CallConv.fromName(n)) |cc| return cc,
        else => {},
    }
    return callConv(r, v);
}

/// Sentinel of the result of `++` (matching the compiler): when both sides have one, they must
/// be equal; when only one side has one, that side's sentinel
pub fn concatSentinel(a: ?Index, b: ?Index) ?Index {
    const x = a orelse return b;
    const y = b orelse return x;
    return if (x == y) x else null;
}

/// Result of a float operation; gives up when it cannot be evaluated (not a float type, division
/// by zero, etc.)
fn floatResult(ty: Index, v: ?Index) EvalError!Val {
    return Val.of(ty, v orelse return error.Abort);
}

/// Whether any argument is of a float type or comptime_float
fn anyFloat(ip: *InternPool, vals: []const Val) bool {
    for (vals) |v| if (ip.isFloat(v.ty)) return true;
    return false;
}

/// Result type of the arguments of float builtins: comptime_float when both sides are comptime
/// numbers
fn floatPeer(ip: *InternPool, a: Index, b: Index) ?Index {
    const comptime_a = a == .comptime_float_type or a == .comptime_int_type;
    const comptime_b = b == .comptime_float_type or b == .comptime_int_type;
    if (comptime_a and comptime_b) return .comptime_float_type;
    return peerFloatType(ip, a, b);
}

fn boolVal(b: bool) Val {
    return .{ .ty = .bool_type, .v = .{ .ip = if (b) .true_value else .false_value } };
}
