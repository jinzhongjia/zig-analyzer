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
    /// Values of the arguments: an `aggregate` (of type unknown) whose elements correspond
    /// one-to-one to the parameters, with unknown for unknown values
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
    for (args, values) |a, *v| v.* = a.val orelse .unknown;
    const key: CallKey = .{ .inst = inst, .values = try ip.get(.{ .aggregate = .{ .ty = .unknown, .elems = values } }), .quota = quota };
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
    const args = switch (ip.key(key.values)) {
        .aggregate => |agg| agg.elems,
        else => &.{},
    };
    const vals = try ev.a.alloc(Val, args.len);
    for (args, vals) |x, *v| v.* = if (x == .unknown) .unknown else Val.of(value.typeOfValue(ip, x), x);
    const result = ev.runFunction(.{ .file = inst.file, .item = inst.decl }, key.inst, vals) catch |err| return giveUp(err);
    return ev.toTyped(result) catch |err| giveUp(err);
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

/// Pointer value pointing to the comptime constant value `pointee` (consistent with the
/// interpreter's representation: a pointer to an array is represented by its elements)
pub fn constPointer(r: *Resolver, ptr_ty: Index, pointee: Index) Error!Index {
    var ev: Evaluator = .{ .r = r, .ip = r.ctx.db.env.ip, .a = r.arena };
    defer ev.deinit();
    return ev.pointerTo(ptr_ty, pointee);
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
/// is the same type across instances)
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
        const va = (try queries.defType(r, def, null, ia)).val orelse return null;
        const vb = (try queries.defType(r, def, null, ib)).val orelse return null;
        const eq = value.eqlValues(ip, va, vb) orelse {
            unknown = true;
            continue;
        };
        if (!eq) return false;
    }
    return if (unknown) null else true;
}

pub const Capture = struct { item: u32, binding: Body.BindingId };

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
    /// storage with the original array)
    window: ?Window = null,

    const Window = struct { start: u32, len: u32 };
};

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

    fn deinit(ev: *Evaluator) void {
        if (!ev.owns_calls) return;
        const memo = ev.calls.?;
        memo.arena.deinit();
        ev.r.ctx.db.gpa.destroy(memo);
    }

    fn tick(ev: *Evaluator) EvalError!void {
        const ctx = ev.r.ctx;
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
                const target = try ev.load(ref);
                const pointee = try ev.freeze(target) orelse return null;
                return try ev.pointerTo(v.ty, pointee);
            },
            .unknown, .undef, .ip, .int => unreachable,
        }
    }

    /// Interned value (integers are interned here); null when it is neither an interned value nor
    /// an integer
    fn ipOf(ev: *Evaluator, v: Val) Error!?Index {
        return switch (v.v) {
            .ip => |x| x,
            .int => |x| try ev.ip.get(.{ .int_value = .{ .ty = v.ty, .value = x } }),
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

    /// Float value (integers as floats); null when it is not a known number
    fn floatOf(ev: *Evaluator, v: Val) ?f128 {
        return switch (v.v) {
            .int => |x| @floatFromInt(x),
            .ip => |x| value.floatOf(ev.ip, x),
            else => null,
        };
    }

    fn aggregate(ev: *Evaluator, ty: Index, elems: []const Index) Error!Index {
        return value.aggregate(ev.ip, ev.a, ty, elems);
    }

    /// Pointer value: pointers to arrays and slices are represented by the pointed-to elements,
    /// others by `ptr_value`
    fn pointerTo(ev: *Evaluator, ptr_ty: Index, pointee: Index) Error!Index {
        const ip = ev.ip;
        if (ev.isArrayPtr(ptr_ty)) switch (ip.key(pointee)) {
            .aggregate => |agg| return ip.get(.{ .aggregate = .{ .ty = ptr_ty, .elems = agg.elems } }),
            .bytes => |b| return ip.get(.{ .bytes = .{ .ty = ptr_ty, .bytes = b.bytes } }),
            else => {},
        };
        return ip.get(.{ .ptr_value = .{ .ty = ptr_ty, .pointee = pointee } });
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
            .ref => |ref| return if (ref.window) |w| w.len else ev.elemCount(try ev.load(ref)),
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

    /// Element `i`; unknown when the value is unknown
    fn elemAt(ev: *Evaluator, v: Val, i: usize) EvalError!Val {
        const ty = ev.elemTypeOf(v.ty, i);
        switch (v.v) {
            .unknown => return .{ .ty = ty },
            .undef => return .{ .ty = ty, .v = .undef },
            .int => return error.Abort,
            .agg => |agg| return if (i < agg.elems.len) agg.elems[i] else error.Abort,
            .ref => |ref| {
                // Range: the index is relative to the start of the range; take the element
                // directly from the containing aggregate
                const base = try ev.loadPath(ref);
                const index = if (ref.window) |w| blk: {
                    if (i >= w.len) return error.Abort;
                    break :blk w.start + i;
                } else i;
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
                .aggregate => |agg| return if (i < agg.elems.len) Val.of(ty, agg.elems[i]) else error.Abort,
                // Aggregates whose elements are all u8 are also represented as bytes (e.g. a
                // value of `struct { short: ?u8 }`): use the declared type of the element
                .bytes => |b| return if (i < b.bytes.len) Val.of(if (ty != .unknown) ty else .u8_type, try ev.ip.get(.{ .int_value = .{ .ty = .u8_type, .value = b.bytes[i] } })) else error.Abort,
                .ptr_value => |p| return ev.elemAt(Val.of(ev.pointeeType(v.ty), p.pointee), i),
                .union_value => |u| return if (i == 0) Val.of(ty, u.payload) else error.Abort,
                else => return error.Abort,
            },
        }
    }

    /// The value the pointer points to. A range has its elements taken out into an array (copied
    /// on read; writes reach the original storage through `extend`); to get only an element or the
    /// length, use `elemAt` / `elemCount`, which do not copy the range.
    fn load(ev: *Evaluator, ref: Ref) EvalError!Val {
        const cur = try ev.loadPath(ref);
        const w = ref.window orelse return cur;
        const elems = try ev.allocElems(w.len);
        for (elems, w.start..) |*o, i| o.* = try ev.elemAt(cur, i);
        const array = try ev.ip.get(.{ .array_type = .{ .len = w.len, .child = ev.elemTypeOf(cur.ty, w.start) } });
        return ev.makeAgg(array, elems);
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
        if (ref.window) |w| {
            // Write element by element: each element counts as one step
            for (0..w.len) |i| {
                try ev.tick();
                try ev.store(try ev.extend(ref, @intCast(i)), try ev.elemAt(v, i));
            }
            return;
        }
        var cell = ref.cell;
        for (ref.path) |i| {
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
        const raw = try ev.evalInner(f, e, want);
        return ev.coerce(raw, want);
    }

    /// Evaluates to a type
    fn evalType(ev: *Evaluator, f: *Frame, e: ExprId) EvalError!Index {
        const v = try ev.eval(f, e, null);
        if (v.ty != .type_type) return error.Abort;
        return (try ev.ipOf(v)) orelse error.Abort;
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
                const eu = switch (ip.key(lhs.ty)) {
                    .error_union_type => |eu| eu,
                    else => return error.Abort,
                };
                // The payload may be storage inside the interpreter (a pointer to an element of a
                // local array, etc.); as with `try`, `condition` tells it apart from an error
                const taken = try ev.condition(lhs);
                if (taken.yes) return taken.payload;
                if (c.capture) |cap| f.slots[@backingInt(cap)] = taken.payload;
                return ev.eval(f, c.rhs, eu.payload);
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
                if (v.is(.null_value) or v.v == .unknown or v.v == .undef) return error.Abort;
                return .{ .ty = child, .v = v.v };
            },
            .init => |x| return ev.initExpr(f, x.ty, x.fields, want),
            .container => |c| {
                if (c.arg) |arg| _ = try ev.eval(f, arg, null);
                const ns = try ev.containerAt(f, e) orelse return error.Abort;
                return Val.ofType(try queries.containerType(ev.r, ns, f.inst));
            },
            .fn_type => |ft| {
                const params = try ev.a.alloc(Index, ft.params.len);
                for (ft.params, params) |p, *out| out.* = try ev.evalType(f, p);
                const ret = if (ft.ret) |rt| try ev.evalType(f, rt) else .void_type;
                return Val.ofType(try ip.get(.{ .fn_type = .{ .params = params, .ret = ret } }));
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
                return Val.ofType(try ip.get(.{ .ptr_type = .{ .child = child, .size = @fromBackingInt(@intCast(@backingInt(p.size))), .is_const = p.is_const, .sentinel = sentinel } }));
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

    fn nameRef(ev: *Evaluator, f: *Frame, e: ExprId, name: []const u8) EvalError!Val {
        if (!f.body.nameRefIsEscaped(e)) if (try infer.primitive(ev.ip, name)) |tv| return thaw(tv);
        const def = try ev.r.resolveName(f.file, f.item, f.body, f.body.expr_scopes[@backingInt(e)], name) orelse return error.Abort;
        switch (def) {
            .local => |l| if (l.file == f.file and l.item == f.item) return f.slots[@backingInt(l.binding)],
            else => {},
        }
        const tv = try queries.defType(ev.r, def, null, f.inst);
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
        if (ref.path.len != 0) return null;
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
                .big_int, .failure => return error.Abort,
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
        if (std.mem.eql(u8, name, "len")) if (ev.isSequence(v.ty)) {
            const n = try ev.elemCount(v) orelse return .{ .ty = .usize_type };
            return Val.of(.usize_type, try ip.get(.{ .int_value = .{ .ty = .usize_type, .value = n } }));
        };
        // `ptr` of a slice: a many-item pointer that shares the slice's representation (used for
        // pointer comparison; see `pointerEql`)
        if (std.mem.eql(u8, name, "ptr")) switch (ip.key(v.ty)) {
            .ptr_type => |p| if (p.size == .slice) {
                var q = p;
                q.size = .many;
                return .{ .ty = try ip.get(.{ .ptr_type = q }), .v = v.v };
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
    /// interned; otherwise (an argument contains a pointer to storage inside the interpreter,
    /// through which the callee may write) executes it in the current interpreter
    fn callFn(ev: *Evaluator, callee: Val, fty: infer.FnType, args: []const Val) EvalError!Val {
        const ip = ev.ip;
        const fv = switch (ip.key((try ev.ipOf(callee)) orelse return error.Abort)) {
            .fn_value => |v| v,
            else => return error.Abort,
        };
        const callee_tv: TypedValue = .{ .ty = callee.ty, .val = try ev.ipOf(callee) };
        const g = try infer.genericCallee(ev.r, ev.a, callee_tv, fty);
        // Arguments are interned and the call goes through a query (results are cached). Mutable
        // aggregates and pointers passed to non-comptime parameters are not interned: the callee
        // may write through the pointers, and large intermediate values should not stay in the
        // grow-only InternPool either.
        const tvs = try ev.a.alloc(TypedValue, args.len);
        var local = false;
        // Integers passed to non-comptime parameters are not interned; the call is executed
        // through `scalarCall`
        var scalar = false;
        for (args, tvs, 0..) |a, *tv, i| {
            const comptime_param = if (g) |gg| gg.kind(i) != .runtime else false;
            if (!comptime_param and (a.v == .agg or a.v == .ref)) {
                local = true;
                tv.* = .{ .ty = a.ty };
                continue;
            }
            if (!comptime_param and a.v == .int) {
                scalar = true;
                tv.* = .{ .ty = a.ty };
                continue;
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
            if (scalar and ev.r.ctx.stackUsed() < ev.r.ctx.stack_budget / 2) return ev.scalarCall(.{ .file = fv.file, .item = fv.decl }, inst, args);
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
                .agg, .ref => thaw(callee.toTyped(v) catch |err| switch (err) {
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
        const inst_args = ip.key(inst).instance.args;
        var frame = try ev.newFrame(owner.file, item, body, inst);
        for (body.params, 0..) |p, i| {
            const arg: Val = if (i < args.len) args[i] else .unknown;
            // The type of an anytype parameter is the type of the argument (also what the instance
            // records; for comptime anytype the instance records the argument's value)
            const binding = body.binding(p);
            const recorded = i < inst_args.len and inst_args[i] != .unknown and inst_args[i] != .runtime;
            const ty: Index = if (binding.ty == null)
                (if (!recorded) arg.ty else if (binding.is_comptime) value.typeOfValue(ip, inst_args[i]) else inst_args[i])
            else if (@backingInt(p) < sig.bindings.len) sig.bindings[@backingInt(p)].ty else .unknown;
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
        var defers: std.ArrayList(ExprId) = .empty;
        ev.statements(f, blk.stmts, &defers) catch |err| {
            // Run the defers when leaving the block (the value of break is already saved in
            // jump_value)
            const saved_value = ev.jump_value;
            const saved_target = ev.jump_target;
            try ev.runDefers(f, defers.items);
            ev.jump_value = saved_value;
            ev.jump_target = saved_target;
            if (err == error.Break and ev.jump_target == index) return ev.coerce(ev.jump_value, want);
            return err;
        };
        try ev.runDefers(f, defers.items);
        return Val.void_val;
    }

    fn runDefers(ev: *Evaluator, f: *Frame, defers: []const ExprId) EvalError!void {
        var i = defers.len;
        while (i > 0) {
            i -= 1;
            _ = try ev.eval(f, defers[i], null);
        }
    }

    fn statements(ev: *Evaluator, f: *Frame, stmts: []const Body.Stmt, defers: *std.ArrayList(ExprId)) EvalError!void {
        for (stmts) |s| switch (s.kind) {
            .expr => |x| _ = try ev.eval(f, x, null),
            .local => |bid| {
                const binding = f.body.binding(bid);
                const ty: ?Index = if (binding.ty) |t| try ev.evalType(f, t) else null;
                const init: Val = if (binding.init) |x| try ev.eval(f, x, ty) else .{ .ty = ty orelse .unknown, .v = .undef };
                f.slots[@backingInt(bid)] = try ev.copy(.{ .ty = ty orelse init.ty, .v = init.v });
            },
            .@"defer" => |x| try defers.append(ev.a, x),
            .@"errdefer" => {},
            .destructure => |d| {
                const v = try ev.eval(f, d.value, null);
                for (d.targets, 0..) |t, i| {
                    const elem = try ev.elemAt(v, i);
                    switch (t) {
                        .binding => |bid| {
                            const ty: ?Index = if (f.body.binding(bid).ty) |te| try ev.evalType(f, te) else null;
                            f.slots[@backingInt(bid)] = try ev.copy(try ev.coerce(elem, ty));
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
                if (x == .null_value) return .{ .yes = false };
                if (v.v == .unknown or v.v == .undef) return error.Abort;
                return .{ .yes = true, .payload = .{ .ty = child, .v = v.v } };
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
                try ev.backwardBranch();
                const taken = try ev.condition(try ev.eval(f, l.inputs[0], null));
                if (!taken.yes) {
                    if (l.else_capture.len != 0) try ev.bindCapture(f, l.else_capture[0], taken.payload);
                    break;
                }
                if (l.capture.len != 0) try ev.bindCapture(f, l.capture[0], taken.payload);
                if (try ev.loopBody(f, l.body, index)) |v| return ev.coerce(v, want);
                if (l.cont) |c| _ = try ev.eval(f, c, null);
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
        // The element type comes from the containing aggregate, without taking out the range
        const target = try ev.loadPath(ref);
        const child = ev.elemTypeOf(target.ty, if (ref.window) |w| w.start + i else i);
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
        return else_prong;
    }

    fn prongItemMatches(ev: *Evaluator, f: *Frame, item: ExprId, operand: Val, v: ?Index) EvalError!bool {
        switch (f.body.expr(item)) {
            // `a...b`
            .other => |range| {
                if (range.len != 2) return error.Abort;
                const x = ev.intOf(operand) orelse return error.Abort;
                const lo = try ev.evalInt(f, range[0], operand.ty);
                const hi = try ev.evalInt(f, range[1], operand.ty);
                return lo <= x and x <= hi;
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
                const child = switch (ip.key(lhs.ty)) {
                    .optional_type => |c| c,
                    else => return error.Abort,
                };
                const c = try ev.condition(lhs);
                if (c.yes) return c.payload;
                return ev.eval(f, rhs_e, if (child != .unknown) child else want);
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
                if ((op == .equal_equal or op == .bang_equal) and ip.key(lhs.ty) == .ptr_type and ip.key(rhs.ty) == .ptr_type) {
                    const eq = pointerEql(lhs, rhs) orelse return error.Abort;
                    return boolVal(eq == (op == .equal_equal));
                }
                if (ev.intOf(lhs)) |x| if (ev.intOf(rhs)) |y| return boolVal(compareNumbers(op, x, y));
                const a = try ev.freeze(lhs) orelse return error.Abort;
                const b = try ev.freeze(rhs) orelse return error.Abort;
                if (value.intOf(ip, a)) |x| if (value.intOf(ip, b)) |y| return boolVal(compareNumbers(op, x, y));
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
                // coerced to u8
                const lhs = try ev.eval(f, lhs_e, null);
                const is_shift = op == .angle_bracket_angle_bracket_left or op == .angle_bracket_angle_bracket_right or op == .angle_bracket_angle_bracket_left_pipe;
                const rhs = try ev.eval(f, rhs_e, null);
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
                const a = ev.intOf(lhs) orelse return error.Abort;
                const b = ev.intOf(rhs) orelse return error.Abort;
                const r = value.binaryInt(ip, op, ty, a, b) orelse return error.Abort;
                return Val.ofInt(ty, r);
            },
        }
    }

    /// Whether two comptime pointers are equal; null when it cannot be determined. Storage cells
    /// in the interpreter are all distinct; interned constant data is distinguished by value (equal
    /// values are the same data, matching the compiler's deduplication of identical literals).
    fn pointerEql(a: Val, b: Val) ?bool {
        switch (a.v) {
            .ref => |x| switch (b.v) {
                .ref => |y| {
                    if (x.cell != y.cell) return false;
                    if (!std.mem.eql(u32, x.path, y.path)) return null;
                    const xs = if (x.window) |w| w.start else 0;
                    const ys = if (y.window) |w| w.start else 0;
                    return xs == ys;
                },
                .ip => return false,
                else => return null,
            },
            .ip => |x| switch (b.v) {
                .ip => |y| return x == y,
                .ref => return false,
                else => return null,
            },
            else => return null,
        }
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
        // Intermediate results stay inside the interpreter and are not interned
        if (ip.key(ty) == .ptr_type) return ev.pointerToNew(ty, try ev.makeAgg(ip.key(ty).ptr_type.child, elems));
        return ev.makeAgg(ty, elems);
    }

    /// Pointer to a new storage cell (holding `target`)
    fn pointerToNew(ev: *Evaluator, ptr_ty: Index, target: Val) Error!Val {
        const cell = try ev.a.create(Val);
        cell.* = target;
        return .{ .ty = ptr_ty, .v = .{ .ref = .{ .cell = cell, .path = &.{} } } };
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
                const v = try ev.eval(f, operand_e, if (f.body.expr(operand_e) == .literal) null else want);
                if (op == .minus and ip.isFloat(v.ty)) {
                    const x = ev.floatOf(v) orelse return error.Abort;
                    return Val.of(v.ty, try value.floatValue(ip, v.ty, -x) orelse return error.Abort);
                }
                const a = ev.intOf(v) orelse return error.Abort;
                const r = switch (op) {
                    .tilde => value.bitNot(ip, v.ty, a),
                    else => value.negate(ip, v.ty, a, op == .minus_percent),
                } orelse return error.Abort;
                return Val.ofInt(v.ty, r);
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
                            return switch (p.v) {
                                .ref => |r| .{ .ty = ty, .v = .{ .ref = r } },
                                else => ev.pointerToNew(ty, arr),
                            };
                        }
                        return ev.addressOf(f, operand_e, try ev.deref(p));
                    },
                    else => {},
                }
                const child_want: ?Index = if (want) |w| switch (ip.key(w)) {
                    .ptr_type => |p| if (p.size == .one) p.child else null,
                    else => null,
                } else null;
                return ev.addressOf(f, operand_e, try ev.eval(f, operand_e, child_want));
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

    /// `&x`: points to x when x is a local variable (or an element of one), otherwise to a
    /// temporary storage cell
    fn addressOf(ev: *Evaluator, f: *Frame, e: ExprId, v: Val) EvalError!Val {
        const ref = ev.place(f, e) catch |err| switch (err) {
            error.Abort => blk: {
                const cell = try ev.a.create(Val);
                cell.* = try ev.copy(v);
                break :blk Ref{ .cell = cell, .path = &.{} };
            },
            else => |x| return x,
        };
        return .{ .ty = try ev.ip.ptrTo(v.ty, .one, false), .v = .{ .ref = ref } };
    }

    /// Place of assignment targets and address-of operands
    fn place(ev: *Evaluator, f: *Frame, e: ExprId) EvalError!Ref {
        switch (f.body.expr(e)) {
            .name_ref => |name| {
                const def = try ev.r.resolveName(f.file, f.item, f.body, f.body.expr_scopes[@backingInt(e)], name) orelse return error.Abort;
                switch (def) {
                    .local => |l| if (l.file == f.file and l.item == f.item) return .{ .cell = &f.slots[@backingInt(l.binding)], .path = &.{} },
                    else => {},
                }
                return error.Abort;
            },
            .field_access => |fa| {
                const name = fa.field orelse return error.Abort;
                const base = try ev.placeOrPointee(f, fa.lhs);
                const target = try ev.load(base);
                const i = try ev.fieldIndex(target.ty, name) orelse return error.Abort;
                return ev.extend(base, @intCast(i));
            },
            .index => |x| {
                const base = try ev.placeOrPointee(f, x.lhs);
                const i = try ev.evalInt(f, x.index, .usize_type);
                return ev.extend(base, std.math.cast(u32, i) orelse return error.Abort);
            },
            .deref => |x| {
                const p = try ev.eval(f, x, null);
                return switch (p.v) {
                    .ref => |r| r,
                    else => error.Abort,
                };
            },
            .@"comptime" => |x| return ev.place(f, x),
            else => return error.Abort,
        }
    }

    /// Place; when its value is a pointer to local storage, the place it points to instead
    /// (automatic dereferencing)
    fn placeOrPointee(ev: *Evaluator, f: *Frame, e: ExprId) EvalError!Ref {
        const ref = try ev.place(f, e);
        // The value of a range is an array, not a pointer
        if (ref.window != null) return ref;
        const v = try ev.load(ref);
        return switch (v.v) {
            .ref => |r| r,
            else => ref,
        };
    }

    /// Place of element `i`; for a range, the index is relative to the start of the range
    fn extend(ev: *Evaluator, base: Ref, i: u32) EvalError!Ref {
        const index = if (base.window) |w| blk: {
            if (i >= w.len) return error.Abort;
            break :blk w.start + i;
        } else i;
        const path = try ev.a.alloc(u32, base.path.len + 1);
        @memcpy(path[0..base.path.len], base.path);
        path[base.path.len] = index;
        return .{ .cell = base.cell, .path = path };
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
            else => {
                ref = try ev.place(f, lhs_e);
                old = try ev.load(ref);
            },
        }
        const rhs_want: ?Index = if (old.ty != .unknown) old.ty else null;
        if (op == .equal) return ev.store(ref, try ev.eval(f, rhs_e, rhs_want));
        // Compound assignment `a += b`
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
            else => return error.Abort,
        };
        const rhs = try ev.eval(f, rhs_e, if (bin == .angle_bracket_angle_bracket_left or bin == .angle_bracket_angle_bracket_right) null else rhs_want);
        if (old.ty == .bool_type) {
            const x = (try ev.condition(old)).yes;
            const y = (try ev.condition(rhs)).yes;
            return ev.store(ref, boolVal(switch (bin) {
                .ampersand => x and y,
                .pipe => x or y,
                .caret => x != y,
                else => return error.Abort,
            }));
        }
        const a = ev.intOf(old) orelse return error.Abort;
        const b = ev.intOf(rhs) orelse return error.Abort;
        const r = value.binaryInt(ev.ip, bin, old.ty, a, b) orelse return error.Abort;
        try ev.store(ref, Val.ofInt(old.ty, r));
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
        const w = r.window orelse return false;
        const rhs = try ev.evalInt(f, rhs_e, .usize_type);
        const len: i128 = switch (op) {
            .equal => rhs,
            .plus_equal => @as(i128, w.len) + rhs,
            .minus_equal => @as(i128, w.len) - rhs,
            else => return error.Abort,
        };
        const whole = try ev.load(.{ .cell = r.cell, .path = r.path });
        const n = try ev.elemCount(whole) orelse return error.Abort;
        if (len < 0 or w.start + len > n) return error.Abort;
        try ev.store(ref, .{ .ty = s.ty, .v = .{ .ref = .{ .cell = r.cell, .path = r.path, .window = .{ .start = w.start, .len = @intCast(len) } } } });
        return true;
    }

    fn deref(ev: *Evaluator, p: Val) EvalError!Val {
        const ip = ev.ip;
        const child = ev.pointeeType(p.ty);
        switch (p.v) {
            .ref => |r| {
                const v = try ev.load(r);
                // Pointer to the payload of an optional (`if (opt) |*x|`): an optional is
                // represented by its payload, so read it as the payload type
                if (child != .unknown and v.ty != child) switch (ip.key(v.ty)) {
                    .optional_type => |c| if (c == child) return .{ .ty = child, .v = v.v },
                    else => {},
                };
                return v;
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
        const src_sentinel: ?Index = switch (ip.key(base.ty)) {
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
        // Otherwise (interned constants, etc.): the elements are copies and are not interned
        const elems = try ev.allocElems(end - start);
        for (elems, start..) |*o, i| o.* = try ev.elemAt(base, i);
        return ev.pointerToNew(ptr_ty, try ev.makeAgg(array, elems));
    }

    /// Storage being sliced: the storage the pointer points to, or the local array variable itself;
    /// null when there is no storage to reference
    fn sliceTarget(ev: *Evaluator, f: *Frame, lhs: ExprId, base: Val) EvalError!?Ref {
        switch (base.v) {
            .ref => |r| return r,
            else => {},
        }
        if (ev.ip.key(base.ty) != .array_type) return null;
        return ev.place(f, lhs) catch |err| switch (err) {
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
                if (v.is(.null_value)) return Val.of(t, .null_value);
                const inner = try ev.coerce(v, child);
                return .{ .ty = t, .v = inner.v };
            },
            .error_union_type => |eu| {
                if (v.v == .ip and ip.key(v.v.ip) == .error_value) return Val.of(t, v.v.ip);
                const inner = try ev.coerce(v, eu.payload);
                return .{ .ty = t, .v = inner.v };
            },
            else => {},
        }
        if (v.v == .int) {
            if (ip.isInt(t)) {
                if (!value.intFits(ip, t, v.v.int)) return error.Abort;
                return Val.ofInt(t, v.v.int);
            }
            // Coercion to floats, enums, etc.: coerce the interned value
            return ev.coerceValue(Val.of(v.ty, (try ev.ipOf(v)).?), want);
        }
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
                else => {},
            },
            .unknown => return .{ .ty = t },
            else => {},
        }
        // Pointer to a tuple → slice: coerce the elements one by one; tuple / anonymous struct
        // literal → array, struct
        switch (ip.key(t)) {
            // `*const T` → `*const [1]T`: take out the element and point to a constant array
            // containing only that element
            .ptr_type => |p| if (p.size == .one and p.is_const and ip.key(p.child) == .array_type and
                ip.key(p.child).array_type.len == 1 and ip.key(v.ty) == .ptr_type and
                ip.key(v.ty).ptr_type.size == .one and ip.key(v.ty).ptr_type.child == ip.key(p.child).array_type.child)
            {
                const elem = try ev.freeze(try ev.deref(v)) orelse return error.Abort;
                const array = try ip.get(.{ .aggregate = .{ .ty = p.child, .elems = &.{elem} } });
                return Val.of(t, try ev.pointerTo(t, array));
            } else if (p.size == .slice or p.size == .many) {
                const target_ty = ev.pointeeType(v.ty);
                if (target_ty != .unknown and (ip.key(target_ty) == .tuple_type or ip.key(target_ty) == .anon_struct_type)) {
                    const n = try ev.elemCount(v) orelse return error.Abort;
                    const elems = try ev.allocElems(n);
                    for (elems, 0..) |*o, i| o.* = try ev.coerce(try ev.elemAt(v, i), p.child);
                    const array = try ip.get(.{ .array_type = .{ .len = n, .child = p.child, .sentinel = p.sentinel } });
                    const frozen = try ev.freeze(try ev.makeAgg(array, elems)) orelse return error.Abort;
                    return Val.of(t, try ev.pointerTo(t, frozen));
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
        const vals = try ev.a.alloc(Val, args.len);
        // Result types of the arguments
        for (args, vals, 0..) |a, *o, i| o.* = try ev.eval(f, a, try ev.builtinArgType(name, i, vals[0..i]));
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
        if (eq(u8, name, "@hasDecl") or eq(u8, name, "@hasField")) {
            if (vals.len != 2) return error.Abort;
            const t = try asType(vals[0]);
            // Type parameter in a generic body without an instance: which members it has depends
            // on the instance (same as `infer.hasMember`)
            if (ip.key(t) == .opaque_param) return error.Abort;
            const field = try ev.stringOf(vals[1]);
            if (eq(u8, name, "@hasField")) return boolVal(try ev.fieldIndex(t, field) != null or (value.isEnumType(ip, t) and try ev.isEnumMember(t, field)));
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
            return Val.ofType(try ip.get(.{ .ptr_type = .{ .child = child, .size = size, .is_const = is_const, .sentinel = if (sentinel == .null_value) null else sentinel } }));
        }
        if (eq(u8, name, "@Fn")) {
            if (vals.len != 4) return error.Abort;
            const varargs = try ev.boolField(vals[3], "varargs");
            return Val.ofType(try ip.get(.{ .fn_type = .{ .params = try ev.typesOf(vals[0]), .ret = try asType(vals[2]), .varargs = varargs } }));
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
        if (eq(u8, name, "@intCast") or eq(u8, name, "@truncate") or eq(u8, name, "@bitCast") or eq(u8, name, "@enumFromInt") or eq(u8, name, "@fromBackingInt") or eq(u8, name, "@ptrCast") or eq(u8, name, "@alignCast") or eq(u8, name, "@constCast") or eq(u8, name, "@volatileCast") or eq(u8, name, "@errorCast") or eq(u8, name, "@errSetCast") or eq(u8, name, "@floatCast") or eq(u8, name, "@floatFromInt") or eq(u8, name, "@intFromFloat")) {
            if (vals.len != 1) return error.Abort;
            // Pointer casts do not change the value: without a result type (e.g. the nested
            // `@ptrCast(@alignCast(p))`), pass it through unchanged
            const pointer_cast = eq(u8, name, "@ptrCast") or eq(u8, name, "@alignCast") or eq(u8, name, "@constCast") or eq(u8, name, "@volatileCast");
            if (want == null and pointer_cast) return vals[0];
            return ev.cast(name, vals[0], want orelse return error.Abort);
        }
        if (eq(u8, name, "@intFromBool")) {
            if (vals.len != 1) return error.Abort;
            return ev.int(.u1_type, @intFromBool((try ev.condition(vals[0])).yes));
        }
        if (eq(u8, name, "@splat")) {
            const t = want orelse return error.Abort;
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
            const ty = try value.minMaxIntType(ip, op == .min, operands) orelse return error.Abort;
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
            const x = try ev.intArg(vals[0]);
            if (x == std.math.minInt(i128)) return error.Abort;
            const ty = if (value.intInfo(ip, vals[0].ty)) |info| (if (info.signed) try ip.intType(.unsigned, info.bits) else vals[0].ty) else vals[0].ty;
            return try ev.int(ty, @abs(x));
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
            const x = try ev.intArg(vals[0]);
            const y = try ev.intArg(vals[1]);
            // The minimum of i128 divided by -1 overflows (the safety check in the interpreter
            // would crash the process)
            if (y == 0 or x == std.math.minInt(i128)) return error.Abort;
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
        const overflow_ops = [_]struct { []const u8, value.OverflowOp }{
            .{ "@addWithOverflow", .add }, .{ "@subWithOverflow", .sub }, .{ "@mulWithOverflow", .mul }, .{ "@shlWithOverflow", .shl },
        };
        for (overflow_ops) |o| if (eq(u8, name, o[0])) {
            if (vals.len != 2) return error.Abort;
            // The result type is the peer type of both sides (for `@shlWithOverflow`, the type of
            // the left side)
            const ty = if (o[1] == .shl) vals[0].ty else value.peerIntType(ip, vals[0].ty, vals[1].ty) orelse return error.Abort;
            const result, const overflow = value.overflowInt(ip, o[1], ty, try ev.intArg(vals[0]), try ev.intArg(vals[1])) orelse return error.Abort;
            const tuple = try ip.get(.{ .tuple_type = .{ .types = &.{ ty, .u1_type } } });
            const elems = [_]Index{ (try ev.freeze(try ev.int(ty, result))).?, (try ev.freeze(try ev.int(.u1_type, @intFromBool(overflow)))).? };
            return Val.of(tuple, try ev.aggregate(tuple, &elems));
        };
        if (eq(u8, name, "@shlExact") or eq(u8, name, "@shrExact")) {
            if (vals.len != 2) return error.Abort;
            const r = value.exactShift(ip, eq(u8, name, "@shlExact"), vals[0].ty, try ev.intArg(vals[0]), try ev.intArg(vals[1])) orelse return error.Abort;
            return try ev.int(vals[0].ty, r);
        }
        if (eq(u8, name, "@byteSwap") or eq(u8, name, "@bitReverse")) {
            if (vals.len != 1) return error.Abort;
            const r = value.reverseBits(ip, eq(u8, name, "@byteSwap"), vals[0].ty, try ev.intArg(vals[0])) orelse return error.Abort;
            return try ev.int(vals[0].ty, r);
        }
        if (eq(u8, name, "@clz") or eq(u8, name, "@ctz") or eq(u8, name, "@popCount")) {
            if (vals.len != 1) return error.Abort;
            const info = value.intInfo(ip, vals[0].ty) orelse return error.Abort;
            if (info.bits > 128) return error.Abort;
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
            // Result type: an unsigned integer that can hold the bit width
            const result_bits: u16 = @intCast(128 - @clz(@as(u128, info.bits)));
            return try ev.int(try ip.intType(.unsigned, result_bits), n);
        }
        return null;
    }

    fn float(ev: *Evaluator, ty: Index, x: f128) EvalError!Val {
        return Val.of(ty, try value.floatValue(ev.ip, ty, x) orelse return error.Abort);
    }

    fn floatArg(ev: *Evaluator, v: Val) EvalError!f128 {
        return ev.floatOf(v) orelse error.Abort;
    }

    /// Result type of argument `i` of a builtin (`prev` holds the preceding arguments). In
    /// builtins that construct types, arguments given per field get `*const [n]T`, which forms
    /// such as `&@splat(.{})` need.
    fn builtinArgType(ev: *Evaluator, name: []const u8, i: usize, prev: []const Val) EvalError!?Index {
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
        return builtinParamType(name, i);
    }

    /// Result type of a builtin parameter
    fn builtinParamType(name: []const u8, i: usize) ?Index {
        const eq = std.mem.eql;
        if (i == 0 and (eq(u8, name, "@as") or eq(u8, name, "@typeInfo") or eq(u8, name, "@sizeOf") or eq(u8, name, "@alignOf") or eq(u8, name, "@bitSizeOf") or eq(u8, name, "@offsetOf") or eq(u8, name, "@bitOffsetOf") or eq(u8, name, "@mulAdd"))) return .type_type;
        return null;
    }

    fn cast(ev: *Evaluator, name: []const u8, v: Val, t: Index) EvalError!Val {
        const ip = ev.ip;
        const eq = std.mem.eql;
        if (eq(u8, name, "@intCast") or eq(u8, name, "@truncate") or eq(u8, name, "@bitCast")) {
            const x = ev.intOf(v) orelse return .{ .ty = t };
            if (eq(u8, name, "@intCast")) {
                if (!value.intFits(ip, t, x)) return error.Abort;
                return ev.int(t, x);
            }
            const info = value.intInfo(ip, t) orelse return error.Abort;
            if (eq(u8, name, "@bitCast")) {
                const src = value.intInfo(ip, v.ty) orelse return error.Abort;
                if (src.bits != info.bits) return error.Abort;
            }
            const r = value.binaryInt(ip, .plus_percent, t, x, 0) orelse return error.Abort;
            return ev.int(t, r);
        }
        if (eq(u8, name, "@enumFromInt") or eq(u8, name, "@fromBackingInt")) {
            const x = ev.intOf(v) orelse return .{ .ty = t };
            if (!value.isEnumType(ip, t)) return error.Abort;
            const names = try ev.enumNames(t) orelse return error.Abort;
            const values = try ev.enumValues(t);
            for (names, values) |n, val| if (val == x) return Val.of(t, try ip.get(.{ .enum_tag = .{ .ty = t, .name = n } }));
            return error.Abort;
        }
        if (eq(u8, name, "@floatCast") or eq(u8, name, "@floatFromInt")) {
            const x = ev.floatOf(v) orelse return .{ .ty = t };
            return Val.of(t, try value.floatValue(ip, t, x) orelse return error.Abort);
        }
        if (eq(u8, name, "@intFromFloat")) {
            const x = ev.floatOf(v) orelse return .{ .ty = t };
            if (@abs(x) > 1e38) return error.Abort;
            const i: i128 = @intFromFloat(@trunc(x));
            if (!value.intFits(ip, t, i)) return error.Abort;
            return ev.int(t, i);
        }
        return .{ .ty = t, .v = v.v };
    }

    fn enumInt(ev: *Evaluator, v: Val) EvalError!Val {
        const ip = ev.ip;
        const x = try ev.freeze(v) orelse return error.Abort;
        const enum_ty: Index, const tag_name: []const u8 = switch (ip.key(x)) {
            .enum_tag => |t| .{ t.ty, t.name },
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
                .{ "attrs", try ev.structValue(try ev.member(try ev.member(type_ty, "Pointer"), "Attributes"), &.{.{ "const", if (p.is_const) .true_value else .false_value }}) },
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
            .error_set_type => |names| .{ "error_set", try ev.structValue(try ev.member(type_ty, "ErrorSet"), &.{.{ "error_names", try ev.namesValue(names) }}) },
            .inferred_error_set => .{ "error_set", try ev.structValue(try ev.member(type_ty, "ErrorSet"), &.{.{ "error_names", if (try queries.errorSetMembers(ev.r, t)) |names| try ev.namesValue(names) else .null_value }}) },
            .fn_type => |ft| blk: {
                const fn_ty = try ev.member(type_ty, "Fn");
                const cc = try ev.stdType(&.{ "builtin", "CallingConvention" });
                const params = try ev.a.alloc(Index, ft.params.len);
                @memcpy(params, ft.params);
                const param_attrs = try ev.a.alloc(Index, ft.params.len);
                const pa_ty = try ev.member(fn_ty, "ParamAttributes");
                for (param_attrs) |*o| o.* = try ev.structValue(pa_ty, &.{});
                break :blk .{ "fn", try ev.structValue(fn_ty, &.{
                    .{ "attrs", try ev.structValue(try ev.member(fn_ty, "Attributes"), &.{
                        .{ "callconv", try ip.get(.{ .union_value = .{ .ty = cc, .tag = "auto", .payload = .void_value } }) },
                        .{ "varargs", if (ft.varargs) .true_value else .false_value },
                    }) },
                    .{ "is_generic", .false_value },
                    .{ "return_type", ft.ret },
                    .{ "param_types", try ev.sliceValue(try ip.optionalOf(.type_type), params) },
                    .{ "param_attrs", try ev.sliceValue(pa_ty, param_attrs) },
                }) };
            },
            .container_type, .reified_type, .tuple_type, .anon_struct_type, .union_tag_type => try ev.containerInfo(type_ty, t),
            else => return error.Abort,
        };
        return ip.get(.{ .union_value = .{ .ty = type_ty, .tag = payload[0], .payload = payload[1] } });
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
                .{ "backing_integer", .null_value },
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
            .{ "backing_integer", try ev.backingInteger(t, layout, types) },
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
        const tree = try ev.r.itemTree(ns.file);
        const parent = tree.containers[ns.container].parent_item orelse return null;
        const rel = try ev.r.containerRel(ns) orelse return null;
        const body = try ev.r.body(ns.file, parent);
        for (body.exprs, 0..) |x, i| switch (x) {
            .container => |c| if (body.expr_ranges[i].start == rel) {
                const arg = c.arg orelse return null;
                // Infer only the argument expression: inference of the enclosing member as a whole
                // may be in progress (for a container in a body), and taking it would form a cycle
                const owner = try ev.r.ownerKey(ns.file, parent);
                const v = try ev.r.ctx.get(queries.LocalValue, .{ .owner = owner, .target = .{ .expr = arg }, .inst = try queries.normalizeInst(ev.r, ns.file, parent, inst) });
                return v.asType();
            },
            else => {},
        };
        return null;
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
    /// `union(enum)`, otherwise null
    fn unionTagType(ev: *Evaluator, t: Index) EvalError!?Index {
        const s = try ev.containerSyntax(t);
        if (s.auto_enum) return try ev.ip.get(.{ .union_tag_type = t });
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

    /// Backing integer of a packed struct (a value of `?type`)
    fn backingInteger(ev: *Evaluator, t: Index, layout: InternPool.Reified.Layout, types: []const Index) EvalError!Index {
        if (layout != .@"packed") return .null_value;
        if ((try ev.containerSyntax(t)).arg) |arg| return arg;
        var bits: u64 = 0;
        for (types) |ty| {
            const field_bits = (try ev.typeLayout(ty, 0) orelse return error.Abort).bits orelse return error.Abort;
            bits = std.math.add(u64, bits, field_bits) catch return error.Abort;
        }
        return ev.ip.intType(.unsigned, std.math.cast(u16, bits) orelse return error.Abort);
    }
};

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
