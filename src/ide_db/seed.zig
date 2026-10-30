//! Call-site seeding: when a generic function body has no concrete instance (abstract parameters,
//! unknown), infer it under the instance from one call site, and hover notes the call site it is
//! based on. The same file is searched first in source order, then other files via the file index;
//! the first call that yields a concrete instance is taken, so the result is deterministic and
//! reproducible.

const std = @import("std");
const engine = @import("../db/engine.zig");
const resolve = @import("../names/resolve.zig");
const Resolver = resolve.Resolver;
const database = @import("../database.zig");
const hir = database.hir;
const Body = @import("../hir/Body.zig");
const queries = @import("../sema/queries.zig");
const infer = @import("../sema/infer.zig");
const eval = @import("../sema/eval.zig");
const value = @import("../sema/value.zig");
const InternPool = @import("../sema/InternPool.zig");
const Index = InternPool.Index;
const TypedValue = InternPool.TypedValue;
const FileId = @import("../base/Vfs.zig").FileId;
const search = @import("search.zig");
const FileIndex = @import("../syntax/FileIndex.zig");

pub const Seed = struct {
    /// Inference result of member `item` under the call-site instance
    res: *const infer.Result,
    /// The instance used
    inst: ?Index,
    /// Position of the call expression; the position of the loop when `iteration` is not null
    file: FileId,
    offset: u32,
    /// Inferred for this iteration (0-based) of a loop over a list of types
    iteration: ?u32 = null,
};

/// Result of inferring member `item` (inside some generic function) under the instance of the first
/// call site: the same file is searched first, then the other files of the project that can
/// reference the function, in file order
pub fn find(r: *Resolver, file: FileId, item: u32) resolve.Error!?Seed {
    if (!r.ctx.db.env.callsite_seeding.load(.monotonic)) return null;
    const owner = try r.ownerKey(file, item);
    const found = try r.ctx.get(Query, .{ .owner = owner, .depth = max_depth }) orelse return null;
    return present(r, owner, found);
}

/// The part at the cursor that must resolve to a concrete type: an expression or a local binding
pub const Subject = union(enum) { expr: Body.ExprId, binding: Body.BindingId };

/// One member analysis shares call-site candidates and per-iteration inference; each position
/// chooses among the combinations of call sites and loop iterations.
pub const Refiner = struct {
    r: *Resolver,
    owner: hir.OwnerKey,
    node_offset: u32,
    body: *const Body,
    abstract: Variant,
    candidates: std.ArrayList(Variant) = .empty,
    loaded: u8 = 0,
    stage_ends: [3]usize = @splat(0),
    loop_regions: ?[]const LoopRegion = null,

    /// Region inferred per iteration: a `for` loop body, or the body of an `inline` switch prong
    /// (`prong` is the prong index)
    const LoopRegion = struct { expr: Body.ExprId, prong: ?u32 = null, range: Body.Range };

    const Variant = struct {
        res: ?*const infer.Result = null,
        inst: ?Index = null,
        origin: ?Found = null,
        presentation: ?Seed = null,
        loops: std.ArrayList(LoopResults) = .empty,
    };
    const LoopResults = struct {
        expr: Body.ExprId,
        prong: ?u32,
        binding: u32,
        results: []?*const infer.Result,
    };

    pub fn init(r: *Resolver, file: FileId, item: u32, node_offset: u32, body: *const Body, res: *const infer.Result) resolve.Error!Refiner {
        return .{ .r = r, .owner = try r.ownerKey(file, item), .node_offset = node_offset, .body = body, .abstract = .{ .res = res } };
    }

    pub fn at(f: *Refiner, rel: u32, subject: ?Subject) resolve.Error!?Seed {
        if (!f.r.ctx.db.env.callsite_seeding.load(.monotonic)) return null;
        if (subject != null and fits(f.r.ctx.db.env.ip, f.body, f.abstract.res.?, rel, subject)) return null;
        var fallback: ?Seed = null;
        if (try f.tryVariant(&f.abstract, rel, subject, &fallback)) |s| return s;
        var checked: usize = 0;
        // Each position goes through the same stages independently; deeper candidates warmed up by
        // earlier positions do not change the selection order.
        for (0..3) |stage| {
            if (f.loaded <= stage) {
                switch (stage) {
                    0 => if (try f.r.ctx.get(Query, .{ .owner = f.owner, .depth = max_depth })) |found| try f.add(found),
                    1 => for (try f.r.ctx.get(Instances, .{ .owner = f.owner, .depth = max_depth })) |found| try f.add(found),
                    // All instances: branches that run only in some instances (the prongs of
                    // `switch (@typeInfo(T))`) are refined by them
                    2 => for (try allFound(f.r, f.owner)) |found| try f.add(found),
                    else => unreachable,
                }
                f.stage_ends[stage] = f.candidates.items.len;
                f.loaded += 1;
            }
            while (checked < f.stage_ends[stage]) : (checked += 1) {
                if (try f.tryVariant(&f.candidates.items[checked], rel, subject, &fallback)) |s| return s;
            }
        }
        return fallback;
    }

    fn add(f: *Refiner, found: Found) resolve.Error!void {
        for (f.candidates.items) |candidate| if (candidate.inst == found.inst) return;
        try f.candidates.append(f.r.arena, .{
            .inst = found.inst,
            .origin = found,
        });
    }

    fn presented(f: *Refiner, candidate: *Variant) resolve.Error!?Seed {
        if (candidate.presentation) |cached| return cached;
        const origin = candidate.origin orelse return null;
        candidate.presentation = try present(f.r, f.owner, origin);
        return candidate.presentation;
    }

    fn regions(f: *Refiner) resolve.Error![]const LoopRegion {
        if (f.loop_regions) |cached| return cached;
        var out: std.ArrayList(LoopRegion) = .empty;
        for (f.body.exprs, 0..) |expr, ei| {
            const id: Body.ExprId = @fromBackingInt(@as(u32, @intCast(ei)));
            switch (expr) {
                .loop => |loop| if (loop.kind == .@"for") try out.append(f.r.arena, .{ .expr = id, .range = f.body.range(loop.body) }),
                .@"switch" => |sw| for (sw.prongs, 0..) |prong, pi| {
                    if (prong.is_inline and prong.capture.len > 0) try out.append(f.r.arena, .{ .expr = id, .prong = @intCast(pi), .range = f.body.range(prong.body) });
                },
                else => {},
            }
        }
        f.loop_regions = out.items;
        return out.items;
    }

    fn tryVariant(f: *Refiner, candidate: *Variant, rel: u32, subject: ?Subject, fallback: *?Seed) resolve.Error!?Seed {
        const ip = f.r.ctx.db.env.ip;
        const res = candidate.res orelse blk: {
            const inferred = try f.r.ctx.get(queries.Infer, .{ .owner = f.owner, .mode = .full, .inst = candidate.inst });
            candidate.res = inferred;
            break :blk inferred;
        };
        if (fits(ip, f.body, res, rel, subject) and candidate.origin != null) return f.presented(candidate);
        // Pick only the innermost heterogeneous loop containing this position; Infer refines the
        // other captures of the same loop along with it.
        var best: ?LoopResults = null;
        var best_len: u32 = std.math.maxInt(u32);
        for (try f.regions()) |region| {
            const range = region.range;
            if (rel < range.start or rel > range.end or range.end - range.start >= best_len) continue;
            const id = region.expr;
            const cached = for (candidate.loops.items) |entry| {
                if (entry.expr == id and entry.prong == region.prong) break entry;
            } else blk: {
                const empty: LoopResults = .{ .expr = id, .prong = region.prong, .binding = 0, .results = &.{} };
                const entry: LoopResults = if (region.prong) |pi| prong: {
                    const sw = f.body.expr(id).@"switch";
                    const n = try prongIterations(f.r, f.body, res, sw, pi) orelse break :prong empty;
                    const results = try f.r.arena.alloc(?*const infer.Result, n);
                    @memset(results, null);
                    break :prong .{ .expr = id, .prong = pi, .binding = @backingInt(sw.prongs[pi].capture[0]), .results = results };
                } else for (f.body.expr(id).loop.capture, 0..) |capture, k| {
                    const n = try iterations(f.r, res, f.body.expr(id).loop, k) orelse continue;
                    const results = try f.r.arena.alloc(?*const infer.Result, n);
                    @memset(results, null);
                    break .{ .expr = id, .prong = null, .binding = @backingInt(capture), .results = results };
                } else empty;
                try candidate.loops.append(f.r.arena, entry);
                break :blk entry;
            };
            if (cached.results.len == 0) continue;
            best = cached;
            best_len = range.end - range.start;
        }
        if (best) |loop| for (loop.results, 0..) |*result, idx| {
            if (result.* == null) result.* = try f.r.ctx.get(queries.Infer, .{
                .owner = f.owner,
                .mode = .full,
                .inst = candidate.inst,
                .loop = .{ .binding = loop.binding, .index = @intCast(idx) },
            });
            const s: Seed = .{
                .res = result.*.?,
                .inst = candidate.inst,
                .file = f.owner.file,
                .offset = f.node_offset + f.body.range(loop.expr).start,
                .iteration = @intCast(idx),
            };
            if (fits(ip, f.body, s.res, rel, subject)) return s;
            if (fallback.* == null and !inactiveAt(f.body, s.res, rel)) fallback.* = s;
        };
        if (fallback.* == null and !inactiveAt(f.body, res, rel)) {
            fallback.* = try f.presented(candidate);
        }
        return null;
    }
};

/// Inference results of member `item` at position `rel` (relative to the member) under every
/// instance of the generic function containing it (see `allFound`; each instance once, at its first
/// call site) whose code at `rel` executes, in discovery order. In a region inferred per iteration
/// (see `iterationResults`), the results of each iteration of the abstract inference `res` and of
/// every instance. Used where an answer must cover all instances, such as goto, which lists the
/// target under each of them.
pub fn allSeeds(r: *Resolver, file: FileId, item: u32, body: *const Body, res: *const infer.Result, rel: u32) resolve.Error![]const Seed {
    if (!r.ctx.db.env.callsite_seeding.load(.monotonic)) return &.{};
    const owner = try r.ownerKey(file, item);
    const node_offset = try r.itemOffset(file, item) orelse return &.{};
    var out: std.ArrayList(Seed) = .empty;
    var instances: std.ArrayList(?Seed) = .empty;
    try instances.append(r.arena, null);
    var seen: std.AutoHashMapUnmanaged(Index, void) = .empty;
    for (try allFound(r, owner)) |found| {
        const inst = found.inst orelse continue;
        if (seen.contains(inst)) continue;
        try instances.append(r.arena, try present(r, owner, found) orelse continue);
        try seen.put(r.arena, inst, {});
    }
    for (instances.items) |instance| {
        const inst_res = if (instance) |s| s.res else res;
        if (instance) |s| if (!inactiveAt(body, s.res, rel)) try out.append(r.arena, s);
        if (inst_res.exprs.len != body.exprs.len) continue;
        const inst = if (instance) |s| s.inst else null;
        const per = try iterationResults(r, owner, body, inst_res, inst, rel);
        for (per.results, 0..) |it, idx| {
            if (inactiveAt(body, it, rel)) continue;
            try out.append(r.arena, .{ .res = it, .inst = inst, .file = file, .offset = node_offset + per.start, .iteration = @intCast(idx) });
        }
    }
    return out.items;
}

/// Per-iteration inference results of a region inferred per iteration
pub const Iterations = struct {
    /// Start of the loop or switch (relative to the member)
    start: u32 = 0,
    results: []const *const infer.Result = &.{},
};

/// Per-iteration inference results, under instance `inst` (whose result is `res`), of the innermost
/// region containing `rel` (relative to the member) that is inferred per iteration: a loop whose
/// loop variable differs per iteration (see `iterations`), or an `inline` switch prong (see
/// `prongIterations`); empty when there is none. As in `Refiner`, the first loop variable that needs
/// it is chosen, and Infer refines the other captures of the same loop along with it.
pub fn iterationResults(r: *Resolver, owner: hir.OwnerKey, body: *const Body, res: *const infer.Result, inst: ?Index, rel: u32) resolve.Error!Iterations {
    var best: ?struct { expr: Body.ExprId, binding: u32, n: u32 } = null;
    var best_len: u32 = std.math.maxInt(u32);
    for (body.exprs, 0..) |expr, ei| switch (expr) {
        .loop => |loop| if (loop.kind == .@"for") {
            const range = body.range(loop.body);
            if (rel < range.start or rel > range.end or range.end - range.start >= best_len) continue;
            for (loop.capture, 0..) |capture, k| {
                const n = try iterations(r, res, loop, k) orelse continue;
                best = .{ .expr = @fromBackingInt(@as(u32, @intCast(ei))), .binding = @backingInt(capture), .n = n };
                best_len = range.end - range.start;
                break;
            }
        },
        .@"switch" => |sw| for (sw.prongs, 0..) |prong, pi| {
            if (!prong.is_inline or prong.capture.len == 0) continue;
            const range = body.range(prong.body);
            if (rel < range.start or rel > range.end or range.end - range.start >= best_len) continue;
            const n = try prongIterations(r, body, res, sw, @intCast(pi)) orelse continue;
            best = .{ .expr = @fromBackingInt(@as(u32, @intCast(ei))), .binding = @backingInt(prong.capture[0]), .n = n };
            best_len = range.end - range.start;
        },
        else => {},
    };
    const b = best orelse return .{};
    const out = try r.arena.alloc(*const infer.Result, b.n);
    for (out, 0..) |*o, idx| o.* = try r.ctx.get(queries.Infer, .{
        .owner = owner,
        .mode = .full,
        .inst = inst,
        .loop = .{ .binding = b.binding, .index = @intCast(idx) },
    });
    return .{ .start = body.range(b.expr).start, .results = out };
}

/// Number of per-value inferences for an `inline` switch prong (the `pi`-th of `sw`), when the
/// capture has no value in the inference: on a tagged union, the number of payloads the prong is
/// instantiated for when their types differ (see `infer.inlineUnionPayloads`); on an operand that
/// is neither a union nor an error set, the number of values after expanding the prong items (see
/// `infer.inlineProngValues`), unless the capture is a pointer
fn prongIterations(r: *Resolver, body: *const Body, res: *const infer.Result, sw: @FieldType(Body.Expr, "switch"), pi: u32) resolve.Error!?u32 {
    const ip = r.ctx.db.env.ip;
    const prong = sw.prongs[pi];
    if (!prong.is_inline or prong.capture.len == 0 or res.exprs.len != body.exprs.len) return null;
    const cap = prong.capture[0];
    if (@backingInt(cap) >= res.bindings.len or res.bindings[@backingInt(cap)].val != null) return null;
    const operand = res.exprs[@backingInt(sw.operand)].ty;
    const is_union = switch (ip.key(operand)) {
        .container_type => |c| c.kind == .@"union",
        .reified_type => |rt| rt.kind == .@"union",
        .error_set_type, .inferred_error_set => return null,
        else => false,
    };
    if (is_union) {
        const payloads = try infer.inlineUnionPayloads(r, body, res.exprs, sw.prongs, pi, operand) orelse return null;
        for (payloads) |p| if (p.ty != payloads[0].ty) return @intCast(payloads.len);
        return null;
    }
    if (body.binding(cap).is_ptr) return null;
    const n = (try infer.inlineProngValues(ip, body, res.exprs, prong, operand, null)).count orelse return null;
    return if (n > 0) n else null;
}

/// Number of iterations when the `k`-th loop variable of loop `l` needs per-iteration inference:
/// iterating a comptime-known list of types (`inline for`, or `for` in comptime; the loop variable
/// is an abstract type in the inference), a comptime-known list of values (the loop variable has a
/// type but no value), or a tuple whose items have different types
/// (`inline for (.{ &posix, &windows }) |cases|`; the loop variable's type cannot be resolved)
fn iterations(r: *Resolver, res: *const infer.Result, l: Body.Loop, k: usize) resolve.Error!?u32 {
    if (k >= l.inputs.len or k >= l.capture.len) return null;
    const ip = r.ctx.db.env.ip;
    const cap = l.capture[k];
    if (@backingInt(cap) >= res.bindings.len or @backingInt(l.inputs[k]) >= res.exprs.len) return null;
    const list = res.exprs[@backingInt(l.inputs[k])];
    const binding = res.bindings[@backingInt(cap)];
    const by_value = if (binding.val) |v| ip.key(v) == .opaque_param else binding.ty != .unknown and list.val != null;
    if (by_value) {
        // Bounded by the element count: an element whose value is `undefined` still has a value
        // (`undefined`), so checking only whether elements have values would never find the end
        const count = try eval.elemCount(r, list) orelse return null;
        var n: u32 = 0;
        while (n < count and try eval.elemValue(r, list, n) != null) n += 1;
        return if (n > 0) n else null;
    }
    if (binding.ty != .unknown) return null;
    const tt = infer.tupleOf(ip, list.ty) orelse return null;
    if (tt.types.len == 0) return null;
    return @intCast(tt.types.len);
}

/// Calls mentioning `names` inside loops of member `i` (in `in`) whose loop variable type differs
/// per iteration (see `iterations`) and inside `inline` switch prongs (see `prongIterations`): the
/// arguments do not resolve to a concrete instance, so each iteration is inferred (the result
/// under instance `inst` is `res`) and searched again. Collects when `all` is not null.
fn loopCall(r: *Resolver, in: FileId, i: u32, owner: hir.OwnerKey, body: *const Body, res: *const infer.Result, inst: ?Index, names: []const []const u8, file: FileId, item: u32, root_key: hir.OwnerKey, all: ?*Collector, strict: bool) resolve.Error!?Found {
    if (res.exprs.len != body.exprs.len) return null;
    for (body.exprs) |e| {
        const l = switch (e) {
            .loop => |l| l,
            .@"switch" => |sw| {
                for (sw.prongs, 0..) |prong, pi| {
                    if (!prong.is_inline or !mentionsWithin(body, prong.body, names)) continue;
                    const n = try prongIterations(r, body, res, sw, @intCast(pi)) orelse continue;
                    for (0..n) |idx| {
                        const res_i = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full, .inst = inst, .loop = .{ .binding = @backingInt(prong.capture[0]), .index = @intCast(idx) } });
                        if (try callIn(r, in, i, body, res_i, file, item, root_key, all, strict)) |found| return found;
                        if (all) |c| if (c.full()) return null;
                    }
                }
                continue;
            },
            else => continue,
        };
        if (l.kind != .@"for" or !mentionsWithin(body, l.body, names)) continue;
        for (l.capture, 0..) |cap, k| {
            const n = try iterations(r, res, l, k) orelse continue;
            for (0..n) |idx| {
                const res_i = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full, .inst = inst, .loop = .{ .binding = @backingInt(cap), .index = @intCast(idx) } });
                if (try callIn(r, in, i, body, res_i, file, item, root_key, all, strict)) |found| return found;
                if (all) |c| if (c.full()) return null;
            }
        }
    }
    return null;
}

/// The range of `e` references a name in `names` (as a name or a member name)
fn mentionsWithin(body: *const Body, e: Body.ExprId, names: []const []const u8) bool {
    const range = body.range(e);
    for (body.exprs, body.expr_ranges) |x, rg| {
        if (rg.start < range.start or rg.end > range.end) continue;
        const name = switch (x) {
            .name_ref => |n| n,
            .field_access => |fa| fa.field orelse continue,
            else => continue,
        };
        if (contains(names, name)) return true;
    }
    return false;
}

/// In the instance's inference result `res`, the code at `rel` executes and `subject` has a
/// concrete type. An enum literal not yet coerced to an enum (`.input =>` in `switch (Q.kind)`,
/// whose type is still `@Type(.enum_literal)`) does not know yet which member it refers to, so it
/// does not count.
fn fits(ip: *InternPool, body: *const Body, res: *const infer.Result, rel: u32, subject: ?Subject) bool {
    if (inactiveAt(body, res, rel)) return false;
    const tv = switch (subject orelse return true) {
        .expr => |e| if (@backingInt(e) < res.exprs.len) res.exprs[@backingInt(e)] else return false,
        .binding => |b| if (@backingInt(b) < res.bindings.len) res.bindings[@backingInt(b)] else return false,
    };
    // Type is noreturn: this instance or iteration never gets past this point
    // (e.g. `const T = switch (x) { .none => continue, ... }`)
    return !wanted(ip, tv) and tv.ty != .enum_literal_type and tv.ty != .noreturn_type;
}

/// The relative position `rel` falls in an inactive branch of the inference result. The end of the
/// branch counts too: the completion position is often right after a just-typed `a.`, i.e. at the
/// end of the branch.
fn inactiveAt(body: *const Body, res: *const infer.Result, rel: u32) bool {
    for (res.inactive) |e| {
        const rg = body.range(e);
        if (rg.start <= rel and rel <= rg.end) return true;
    }
    for (res.dead_spans) |rg| if (rg.start <= rel and rel <= rg.end) return true;
    return false;
}

/// Expression `e` lies entirely in inactive code of inference result `res`
fn withinInactive(body: *const Body, res: *const infer.Result, e: Body.ExprId) bool {
    const er = body.range(e);
    for (res.inactive) |x| {
        const rg = body.range(x);
        if (rg.start <= er.start and er.end <= rg.end) return true;
    }
    for (res.dead_spans) |rg| if (rg.start <= er.start and er.end <= rg.end) return true;
    return false;
}

/// A call site keeps only the stable member and expression identities; the current position is
/// resolved when results are returned to the IDE.
pub const Found = struct { inst: ?Index, owner: hir.OwnerKey, expr: Body.ExprId };

fn present(r: *Resolver, target: hir.OwnerKey, found: Found) resolve.Error!?Seed {
    const tree = try r.itemTree(found.owner.file);
    const item: u32 = for (tree.items, 0..) |it, i| {
        if (it.ast_id == found.owner.item) break @intCast(i);
    } else return null;
    const offset = try r.itemOffset(found.owner.file, item) orelse return null;
    const body = try r.ctx.get(hir.ItemBody, found.owner);
    if (@backingInt(found.expr) >= body.exprs.len) return null;
    return .{
        .res = try r.ctx.get(queries.Infer, .{ .owner = target, .mode = .full, .inst = found.inst }),
        .inst = found.inst,
        .file = found.owner.file,
        .offset = offset + body.range(found.expr).start,
    };
}

/// Maximum number of levels passed through generic callers: z2d's `toRGBA` is called by the generic
/// `hue`, which in turn is dispatched by the generic `run`; websocket.zig's `_handleClientData`
/// goes through `handleClientData`, a method of `NonBlockingBase`, a field of `NonBlocking`,
/// `listen`, and `listenInNewThread` (passed to `Thread.spawn`) before reaching the concrete
/// `Server(TestHandler)`
pub const max_depth = 16;

/// Call-site lookups are cached per member and depth: frequent requests such as completion and
/// inlay hints need not search again every time. The lookup is strict first and is relaxed when it
/// finds nothing (see `callIn`).
/// A lookup at depth d uses the lookup at depth d - 1 to get instances for callers located inside
/// generic functions (depth 0 only looks at call sites whose arguments are concrete by themselves).
/// The depth strictly decreases, so no cycles form: if mutually calling generic functions
/// (`execute` and `init` in http.zig) recursed with the same key, results within the cycle would
/// not be written to the memo, and every request would recompute them, amplified at every level.
pub const Query = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = struct { owner: hir.OwnerKey, depth: u8 };
    pub const Value = ?Found;

    pub fn compute(ctx: *database.Db.Ctx, key: Key) engine.Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        return try search_(&r, key.owner, key.depth, true) orelse search_(&r, key.owner, key.depth, false);
    }

    pub fn cycleFallback(_: Key) Value {
        return null;
    }
};

/// Number of instances kept by `Instances`: they are tried in turn when the first does not apply;
/// with many call sites only the first few are taken
pub const max_seeds = 32;

/// The first `max_seeds` distinct instances of the member across call sites (in lookup order,
/// deduplicated): tried in turn when the first instance does not apply (the code at the cursor does
/// not execute, the expression's type cannot be resolved, the call is in a branch the instance does
/// not execute). When the caller itself is inside a generic function, the caller's instances are
/// used (one level less). Like `Query`, relaxes when the strict lookup finds nothing. Use
/// `AllInstances` when all instances must be covered.
pub const Instances = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = struct { owner: hir.OwnerKey, depth: u8 };
    pub const Value = []const Found;

    pub fn compute(ctx: *database.Db.Ctx, key: Key) engine.Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        var out: Collector = .{ .limit = max_seeds };
        try collect(&r, key.owner, key.depth, &out);
        if (out.found.items.len == 0) {
            out.strict = false;
            try collect(&r, key.owner, key.depth, &out);
        }
        return ctx.db.gpa.dupe(Found, out.found.items);
    }

    pub fn eql(a: Value, b: Value) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }

    pub fn cycleFallback(_: Key) Value {
        return &.{};
    }

    pub fn deinit(v: *Value, gpa: std.mem.Allocator) void {
        gpa.free(v.*);
    }
};

/// All concrete instances in the project of member `item` (inside some generic function; see
/// `AllInstances`). Used where every instance must be covered (find references and rename): when
/// `complete` is false there may be other instances.
pub fn allInstances(r: *Resolver, file: FileId, item: u32) resolve.Error!struct { insts: []const Index, complete: bool } {
    if (!r.ctx.db.env.callsite_seeding.load(.monotonic)) return .{ .insts = &.{}, .complete = true };
    const root = try genericRoot(r, file, item) orelse return .{ .insts = &.{}, .complete = true };
    const all = try r.ctx.get(AllInstances, try r.ownerKey(file, root));
    const insts = try r.arena.alloc(Index, all.found.len);
    for (all.found, insts) |f, *inst| inst.* = (try queries.normalizeInst(r, file, item, f.inst.?)).?;
    return .{ .insts = insts, .complete = all.complete };
}

/// Callers of the generic function (`root`), in order: the instances each caller gives directly
/// when inferred outside generic functions; callers inside other generic functions also record
/// that function (`from`), and the closure infers them under each of its instances (see
/// `CallsIn`). Last come the instances given by type flow (starting at `flow_start`).
/// Depends only on the target function, `strict` and `target`, so it is shared by the closures of
/// all targets. When `target` is not null (the target function is in a file that does not import
/// `target`; see `Closure.importers`), only callers that can pass arguments leading to `target`
/// are taken: callers in files that import `target`, and callers in generic functions.
pub const RootCallers = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = struct { root: hir.OwnerKey, strict: bool, target: ?FileId = null };
    pub const Caller = struct { in: FileId, i: u32, from: ?hir.OwnerKey, found_start: usize, found_len: usize };
    pub const Value = struct { found: []const Found, callers: []const Caller, flow_start: usize, cut: bool };

    pub fn compute(ctx: *database.Db.Ctx, key: Key) engine.Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        const empty: Value = .{ .found = &.{}, .callers = &.{}, .flow_start = 0, .cut = false };
        const tree = try r.itemTree(key.root.file);
        const item: u32 = for (tree.items, 0..) |it, i| {
            if (it.ast_id == key.root.item) break @intCast(i);
        } else return empty;
        const candidates = try ctx.get(Candidates, key.root);
        const files = candidates.all_files;
        var importers: std.AutoHashMapUnmanaged(FileId, void) = .empty;
        for (candidates.files) |f| try importers.put(r.arena, f, {});
        var target_importers: std.AutoHashMapUnmanaged(FileId, void) = .empty;
        if (key.target) |t| {
            for (try ctx.get(search.ProjectImporters, t)) |f| try target_importers.put(r.arena, f, {});
            try target_importers.put(r.arena, t, {});
        }
        var out: Collector = .{ .limit = std.math.maxInt(usize), .strict = key.strict };
        var callers: std.ArrayList(Caller) = .empty;
        for (0..files.len + 1) |fi| {
            const f = if (fi == 0) key.root.file else files[fi - 1];
            if (fi != 0 and (f == key.root.file or !try containsAny(&r, f, candidates.names))) continue;
            for (try ctx.get(Callers, .{ .root = key.root, .in = f })) |i| {
                // In a file that does not import the target's file, code outside generic functions
                // cannot name the target's types, so it does not call the target; likewise it
                // cannot pass arguments leading to `target`
                const outside = (f != key.root.file and !importers.contains(f)) or
                    (key.target != null and !target_importers.contains(f));
                if (outside and try genericRoot(&r, f, i) == null) continue;
                const owner = try r.ownerKey(f, i);
                const body = try ctx.get(hir.ItemBody, owner);
                const res = try ctx.get(queries.Infer, .{ .owner = owner, .mode = .full });
                const start = out.found.items.len;
                _ = try callIn(&r, f, i, body, res, key.root.file, item, key.root, &out, key.strict);
                _ = try loopCall(&r, f, i, owner, body, res, null, candidates.names, key.root.file, item, key.root, &out, key.strict);
                const outer = try genericRoot(&r, f, i);
                const from: ?hir.OwnerKey = if (outer != null and mayCall(ctx.db.env.ip, body, res, key.root)) try r.ownerKey(f, outer.?) else null;
                if (from == null and out.found.items.len == start) continue;
                try callers.append(r.arena, .{ .in = f, .i = i, .from = from, .found_start = start, .found_len = out.found.items.len - start });
            }
        }
        const flow_start = out.found.items.len;
        var cut = false;
        _ = try typeFlow(&r, key.root.file, item, item, files, max_closure_flow_depth, &out, key.strict, &cut);
        const gpa = ctx.db.gpa;
        const found = try gpa.dupe(Found, out.found.items);
        errdefer gpa.free(found);
        return .{ .found = found, .callers = try gpa.dupe(Caller, callers.items), .flow_start = flow_start, .cut = cut };
    }

    pub fn eql(a: Value, b: Value) bool {
        if (a.cut != b.cut or a.flow_start != b.flow_start or a.found.len != b.found.len or a.callers.len != b.callers.len) return false;
        for (a.found, b.found) |x, y| if (!std.meta.eql(x, y)) return false;
        for (a.callers, b.callers) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }

    pub fn deinit(v: *Value, gpa: std.mem.Allocator) void {
        gpa.free(v.found);
        gpa.free(v.callers);
    }
};

/// Instances given by the calls of caller `owner` to generic function `target` under instance
/// `inst` (including calls in loops inferred per iteration). Shared by the closures of all targets.
pub const CallsIn = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = struct { target: hir.OwnerKey, owner: hir.OwnerKey, inst: Index, strict: bool };
    pub const Value = []const Found;

    pub fn compute(ctx: *database.Db.Ctx, key: Key) engine.Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        const target_tree = try r.itemTree(key.target.file);
        const item: u32 = for (target_tree.items, 0..) |it, i| {
            if (it.ast_id == key.target.item) break @intCast(i);
        } else return &.{};
        const tree = try r.itemTree(key.owner.file);
        const i: u32 = for (tree.items, 0..) |it, k| {
            if (it.ast_id == key.owner.item) break @intCast(k);
        } else return &.{};
        const names = (try ctx.get(Candidates, key.target)).names;
        const body = try ctx.get(hir.ItemBody, key.owner);
        const seeded = try ctx.get(queries.Infer, .{ .owner = key.owner, .mode = .full, .inst = key.inst });
        var out: Collector = .{ .limit = std.math.maxInt(usize), .strict = key.strict };
        _ = try callIn(&r, key.owner.file, i, body, seeded, key.target.file, item, key.target, &out, key.strict);
        _ = try loopCall(&r, key.owner.file, i, key.owner, body, seeded, key.inst, names, key.target.file, item, key.target, &out, key.strict);
        return ctx.db.gpa.dupe(Found, out.found.items);
    }

    pub fn eql(a: Value, b: Value) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }

    pub fn deinit(v: *Value, gpa: std.mem.Allocator) void {
        gpa.free(v.*);
    }
};

/// Call sites of all instances of member `owner` (see `AllInstances`), with the instances
/// normalized for the member
pub fn allFound(r: *Resolver, owner: hir.OwnerKey) resolve.Error![]const Found {
    const tree = try r.itemTree(owner.file);
    const item: u32 = for (tree.items, 0..) |it, i| {
        if (it.ast_id == owner.item) break @intCast(i);
    } else return &.{};
    const root = try genericRoot(r, owner.file, item) orelse return &.{};
    const all = try r.ctx.get(AllInstances, try r.ownerKey(owner.file, root));
    const out = try r.arena.alloc(Found, all.found.len);
    for (all.found, out) |f, *o| {
        o.* = f;
        o.inst = try queries.normalizeInst(r, owner.file, item, f.inst.?);
    }
    return out;
}

/// Limit on the argument nesting depth of instances in the closure: code that compiles instantiates
/// a finite set, while argument types nesting ever deeper with recursion (`grow(?T)`) mean the
/// instantiation grows without bound; it is truncated beyond the limit
const max_closure_depth = 64;
/// Limit on the total number of instances in the closure: arguments that do not get deeper but
/// grow without bound in number (comptime integers increasing with recursion) likewise only occur
/// in code that does not compile. Projects with many tests (each test type propagating through
/// dozens of levels of generic functions) can reach tens of thousands of instances, so the limit
/// must be far above that.
const max_closure = 1 << 18;
/// Depth limit of type flow in the closure (see `typeFlow`; an instance already entered is not
/// entered again, so the depth only matters for code whose instantiation grows without bound)
const max_closure_flow_depth = 64;

/// All concrete instances in the project of the generic function (key), in discovery order:
/// starting from calls outside generic functions (plus type flow and dispatch sites in std), the
/// closure is taken along the calls to it in each instance of its generic callers until no new
/// instances appear. `complete` is false when truncated because instantiation grows without bound.
pub const AllInstances = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = hir.OwnerKey;
    pub const Value = struct { found: []const Found, complete: bool };

    pub fn compute(ctx: *database.Db.Ctx, key: Key) engine.Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        var c: Closure = .{ .r = &r };
        for ((try ctx.get(Candidates, key)).files) |f| try c.importers.put(r.arena, f, {});
        try c.importers.put(r.arena, key.file, {});
        c.target_file = key.file;
        const target = try c.root(key) orelse return .{ .found = &.{}, .complete = true };
        try c.run();
        return .{ .found = try ctx.db.gpa.dupe(Found, c.roots.items[target].found.found.items), .complete = c.complete };
    }

    pub fn eql(a: Value, b: Value) bool {
        if (a.complete != b.complete or a.found.len != b.found.len) return false;
        for (a.found, b.found) |x, y| if (!std.meta.eql(x, y)) return false;
        return true;
    }

    pub fn cycleFallback(_: Key) Value {
        return .{ .found = &.{}, .complete = false };
    }

    pub fn deinit(v: *Value, gpa: std.mem.Allocator) void {
        gpa.free(v.found);
    }
};

/// Computation of `AllInstances`: the instance sets of each participating generic function (the
/// target and its generic callers, level by level upward), propagated with a work queue to a
/// fixpoint
const Closure = struct {
    r: *Resolver,
    /// Files that can reach the target's file via `@import` chains: instances of generic functions
    /// in them all take part in propagation; generic functions in other files cannot name the
    /// target's types and can only call the target when instance arguments lead to types defined
    /// in these files (see `reaches`)
    importers: std.AutoHashMapUnmanaged(FileId, void) = .empty,
    target_file: FileId = undefined,
    reach_memo: std.AutoHashMapUnmanaged(Index, bool) = .empty,
    roots: std.ArrayList(Root) = .empty,
    /// Generic functions waiting to be scanned (for their callers)
    unscanned: std.ArrayList(usize) = .empty,
    /// Newly found instances not yet propagated: the generic function and the `found` index
    queue: std.ArrayList(struct { root: usize, index: usize }) = .empty,
    total: usize = 0,
    complete: bool = true,

    const Root = struct {
        key: hir.OwnerKey,
        file: FileId,
        item: u32,
        found: Collector,
        /// Callers inside generic function `from` (member `i` in `in`): the caller is inferred
        /// under each instance of `from` to find the calls to this function
        callers: std.ArrayList(Edge) = .empty,
        /// Callers to infer under this function's instances: indices into the `callers` of generic
        /// function `to`
        outs: std.ArrayList(struct { to: usize, edge: usize }) = .empty,
        scanned: bool = false,
        dispatch_tried: bool = false,
        /// In a file that does not import the target's file: keep only instances whose arguments
        /// lead to the target
        filtered: bool,
        /// Some instance was found (including filtered ones): dispatch sites and the relaxed
        /// lookup are used only when none was, the same as without filtering
        seen: bool = false,
    };
    const Edge = struct { in: FileId, i: u32, from: usize };

    /// Whether type or value `x` can lead to types defined in `importers`: containers defined in
    /// them, or instances whose arguments lead to them; pointers, arrays, tuples, function types
    /// and the like are judged by their components. Unresolvable values, abstract parameters and
    /// kinds not listed count as leading there.
    fn reaches(c: *Closure, x: Index) resolve.Error!bool {
        if (x == .runtime) return false;
        if (x == .unknown) return true;
        if (c.reach_memo.get(x)) |v| return v;
        const v = try c.reachesInner(x);
        try c.reach_memo.put(c.r.arena, x, v);
        return v;
    }

    fn reachesInner(c: *Closure, x: Index) resolve.Error!bool {
        const ip = c.r.ctx.db.env.ip;
        return switch (ip.key(x)) {
            .simple_type, .int_type, .error_set_type, .simple_value, .int_value, .float_value, .enum_literal, .error_value, .runtime, .context => false,
            .unknown, .opaque_param => true,
            .ptr_type => |p| c.reaches(p.child),
            .array_type => |a| c.reaches(a.child),
            .abstract_array_type => |a| c.reaches(a.child),
            .vector_type => |v| c.reaches(v.child),
            .optional_type => |o| c.reaches(o),
            .error_union_type => |e| c.reaches(e.payload),
            .inferred_error_set => |e| c.importers.contains(e.file) or (if (e.inst) |i| try c.reaches(i) else false),
            .fn_type => |f| blk: {
                for (f.params) |t| if (try c.reaches(t)) break :blk true;
                break :blk c.reaches(f.ret);
            },
            .container_type => |k| c.importers.contains(k.file) or (if (k.inst) |i| try c.reaches(i) else false),
            .tuple_type => |t| c.anyReaches(t.types, t.values),
            .anon_struct_type => |t| c.anyReaches(t.types, t.values),
            .reified_type => |t| c.importers.contains(t.file) or (if (t.inst) |i| try c.reaches(i) else false) or try c.anyReaches(t.types, &.{}),
            .union_tag_type => |u| c.reaches(u),
            .enum_tag => |e| c.reaches(e.ty),
            .fn_value => |f| c.importers.contains(f.file) or (if (f.inst) |i| try c.reaches(i) else false) or try c.reaches(f.ty),
            .aggregate => |a| (try c.reaches(a.ty)) or try c.anyReaches(a.elems, &.{}),
            .bytes => |b| c.reaches(b.ty),
            .union_value => |u| (try c.reaches(u.ty)) or try c.reaches(u.payload),
            .ptr_value => |p| (try c.reaches(p.ty)) or try c.reaches(p.pointee),
            .instance => |i| blk: {
                if (try c.anyReaches(i.args, &.{})) break :blk true;
                break :blk if (i.parent) |p| try c.reaches(p) else false;
            },
        };
    }

    fn anyReaches(c: *Closure, a: []const Index, b: []const Index) resolve.Error!bool {
        for (a) |x| if (try c.reaches(x)) return true;
        for (b) |x| if (try c.reaches(x)) return true;
        return false;
    }

    /// Index of generic function `key` in `roots`, added (pending scan) on first appearance
    fn root(c: *Closure, key: hir.OwnerKey) resolve.Error!?usize {
        for (c.roots.items, 0..) |x, k| if (std.meta.eql(x.key, key)) return k;
        const r = c.r;
        const tree = try r.itemTree(key.file);
        const item: u32 = for (tree.items, 0..) |it, i| {
            if (it.ast_id == key.item) break @intCast(i);
        } else return null;
        try c.roots.append(r.arena, .{ .key = key, .file = key.file, .item = item, .found = .{ .limit = std.math.maxInt(usize) }, .filtered = !c.importers.contains(key.file) });
        try c.unscanned.append(r.arena, c.roots.items.len - 1);
        return c.roots.items.len - 1;
    }

    fn run(c: *Closure) resolve.Error!void {
        while (true) {
            while (true) {
                if (c.unscanned.pop()) |g| {
                    try c.scan(g);
                } else if (c.queue.pop()) |p| {
                    for (c.roots.items[p.root].outs.items) |o| try c.propagate(o.to, o.edge, p.index);
                } else break;
            }
            // Fixpoint: functions without instances first take dispatch sites in std; those still
            // without any relax the strict lookup (see `callIn`)
            var progressed = false;
            for (0..c.roots.items.len) |g| {
                const st = &c.roots.items[g];
                if (st.seen) continue;
                if (!st.dispatch_tried) {
                    st.dispatch_tried = true;
                    if (try dispatched(c.r, st.file, st.item, st.item)) |found| {
                        try c.add(g, found);
                        progressed = true;
                        continue;
                    }
                }
                if (c.roots.items[g].found.strict) {
                    c.roots.items[g].found.strict = false;
                    try c.rescan(g);
                    progressed = true;
                }
            }
            if (!progressed) return;
        }
    }

    /// Callers of generic function `g` (see `RootCallers`): directly given instances are added;
    /// callers inside other generic functions are registered as depending on that function's
    /// instances and are inferred under the instances it already has
    fn scan(c: *Closure, g: usize) resolve.Error!void {
        const r = c.r;
        if (c.roots.items[g].scanned) return;
        c.roots.items[g].scanned = true;
        const rc = try r.ctx.get(RootCallers, .{
            .root = c.roots.items[g].key,
            .strict = c.roots.items[g].found.strict,
            .target = if (c.roots.items[g].filtered) c.target_file else null,
        });
        if (rc.cut) c.complete = false;
        for (rc.callers) |caller| {
            for (rc.found[caller.found_start..][0..caller.found_len]) |found| try c.add(g, found);
            const from = caller.from orelse continue;
            const h = try c.root(from) orelse continue;
            const edge = c.roots.items[g].callers.items.len;
            try c.roots.items[g].callers.append(r.arena, .{ .in = caller.in, .i = caller.i, .from = h });
            try c.roots.items[h].outs.append(r.arena, .{ .to = g, .edge = edge });
            for (0..c.roots.items[h].found.found.items.len) |k| try c.propagate(g, edge, k);
        }
        for (rc.found[rc.flow_start..]) |found| try c.add(g, found);
    }

    /// Rescan after relaxing: registered generic callers get registered again, so clear them first
    fn rescan(c: *Closure, g: usize) resolve.Error!void {
        c.roots.items[g].scanned = false;
        for (c.roots.items[g].callers.items) |e| {
            const outs = &c.roots.items[e.from].outs;
            var k: usize = 0;
            while (k < outs.items.len) {
                if (outs.items[k].to == g) _ = outs.swapRemove(k) else k += 1;
            }
        }
        c.roots.items[g].callers.clearRetainingCapacity();
        try c.scan(g);
    }

    /// Calls to `g` by generic caller `g.callers[edge]` under the `k`-th instance of its enclosing
    /// function (see `CallsIn`)
    fn propagate(c: *Closure, g: usize, edge: usize, k: usize) resolve.Error!void {
        const r = c.r;
        const e = c.roots.items[g].callers.items[edge];
        const inst = c.roots.items[e.from].found.found.items[k].inst.?;
        const found = try r.ctx.get(CallsIn, .{
            .target = c.roots.items[g].key,
            .owner = try r.ownerKey(e.in, e.i),
            .inst = inst,
            .strict = c.roots.items[g].found.strict,
        });
        for (found) |f| try c.add(g, f);
    }

    fn add(c: *Closure, g: usize, found: Found) resolve.Error!void {
        if (found.inst != null) c.roots.items[g].seen = true;
        if (found.inst) |inst| if (depthExceeds(c.r.ctx.db.env.ip, inst, max_closure_depth)) {
            c.complete = false;
            return;
        };
        if (c.roots.items[g].filtered) if (found.inst) |inst| if (!try c.reaches(inst)) return;
        const before = c.roots.items[g].found.found.items.len;
        try c.roots.items[g].found.add(c.r.arena, found);
        try c.queueFrom(g, before);
    }

    /// Queues the instances newly added to `g` from `before` on for propagation; once the total
    /// exceeds the limit, they are no longer propagated
    fn queueFrom(c: *Closure, g: usize, before: usize) resolve.Error!void {
        const now = c.roots.items[g].found.found.items.len;
        for (before..now) |k| {
            c.total += 1;
            if (c.total > max_closure) {
                c.complete = false;
                continue;
            }
            try c.queue.append(c.r.arena, .{ .root = g, .index = k });
        }
    }
};

/// The nesting depth of type or value `x` (level by level through instance arguments, pointer and
/// optional child types, aggregate elements, etc.) exceeds `limit`
fn depthExceeds(ip: *InternPool, x: Index, limit: u32) bool {
    if (limit == 0) return true;
    const sub = limit - 1;
    return switch (ip.key(x)) {
        .ptr_type => |p| depthExceeds(ip, p.child, sub),
        .array_type => |a| depthExceeds(ip, a.child, sub),
        .abstract_array_type => |a| depthExceeds(ip, a.child, sub),
        .vector_type => |v| depthExceeds(ip, v.child, sub),
        .optional_type => |o| depthExceeds(ip, o, sub),
        .error_union_type => |e| depthExceeds(ip, e.payload, sub),
        .fn_type => |f| anyExceeds(ip, f.params, sub) or depthExceeds(ip, f.ret, sub),
        .container_type => |k| if (k.inst) |i| depthExceeds(ip, i, sub) else false,
        .reified_type => |t| anyExceeds(ip, t.types, sub) or (if (t.inst) |i| depthExceeds(ip, i, sub) else false),
        .tuple_type => |t| anyExceeds(ip, t.types, sub),
        .anon_struct_type => |t| anyExceeds(ip, t.types, sub),
        .aggregate => |a| anyExceeds(ip, a.elems, sub),
        .ptr_value => |p| depthExceeds(ip, p.pointee, sub),
        .union_value => |u| depthExceeds(ip, u.payload, sub),
        .instance => |i| anyExceeds(ip, i.args, sub) or (if (i.parent) |p| depthExceeds(ip, p, sub) else false),
        else => false,
    };
}

fn anyExceeds(ip: *InternPool, xs: []const Index, limit: u32) bool {
    for (xs) |x| if (depthExceeds(ip, x, limit)) return true;
    return false;
}

/// Collected instances: deduplicated by instance, at most `limit` of them
const Collector = struct {
    found: std.ArrayList(Found) = .empty,
    limit: usize,
    /// See `callIn`
    strict: bool = true,

    fn full(c: *const Collector) bool {
        return c.found.items.len >= c.limit;
    }

    fn add(c: *Collector, a: std.mem.Allocator, f: Found) std.mem.Allocator.Error!void {
        if (f.inst == null or c.full()) return;
        for (c.found.items) |x| if (x.inst == f.inst) return;
        try c.found.append(a, f);
    }
};

fn collect(r: *Resolver, key: hir.OwnerKey, depth: u8, out: *Collector) resolve.Error!void {
    const tree = try r.itemTree(key.file);
    const item: u32 = for (tree.items, 0..) |it, i| {
        if (it.ast_id == key.item) break @intCast(i);
    } else return;
    const root = try genericRoot(r, key.file, item) orelse return;
    const root_key = try r.ownerKey(key.file, root);
    const candidates = try r.ctx.get(Candidates, root_key);
    const files = candidates.files;
    for (0..files.len + 1) |fi| {
        const f = if (fi == 0) key.file else files[fi - 1];
        if (fi != 0 and (f == key.file or !try containsAny(r, f, candidates.names))) continue;
        for (try r.ctx.get(Callers, .{ .root = root_key, .in = f })) |i| {
            if (out.full()) return;
            try collectIn(r, f, i, key.file, item, root_key, candidates.names, depth, out);
        }
    }
    // The type flow depth is not bounded by the collection depth: it only enters instances whose
    // arguments contain the target container, so it does not grow multiplicatively
    _ = try typeFlow(r, key.file, item, root, files, max_depth, out, out.strict, null);
    if (out.found.items.len == 0) if (try dispatched(r, key.file, item, root)) |found| try out.add(r.arena, found);
}

/// Like `findIn`, but collects all instances
fn collectIn(r: *Resolver, in: FileId, i: u32, file: FileId, item: u32, root_key: hir.OwnerKey, names: []const []const u8, depth: u8, out: *Collector) resolve.Error!void {
    const owner = try r.ownerKey(in, i);
    const body = try r.ctx.get(hir.ItemBody, owner);
    const res = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full });
    _ = try callIn(r, in, i, body, res, file, item, root_key, out, out.strict);
    _ = try loopCall(r, in, i, owner, body, res, null, names, file, item, root_key, out, out.strict);
    if (depth == 0 or try genericRoot(r, in, i) == null) return;
    if (!mayCall(r.ctx.db.env.ip, body, res, root_key)) return;
    for (try r.ctx.get(Instances, .{ .owner = owner, .depth = depth - 1 })) |o| {
        if (out.full()) return;
        const seeded = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full, .inst = o.inst });
        _ = try callIn(r, in, i, body, seeded, file, item, root_key, out, out.strict);
        _ = try loopCall(r, in, i, owner, body, seeded, o.inst, names, file, item, root_key, out, out.strict);
    }
}

/// The first call site of member `key` that yields a concrete instance. See `callIn` for `strict`.
fn search_(r: *Resolver, key: hir.OwnerKey, depth: u8, strict: bool) resolve.Error!?Found {
    const tree = try r.itemTree(key.file);
    const item: u32 = for (tree.items, 0..) |it, i| {
        if (it.ast_id == key.item) break @intCast(i);
    } else return null;
    const root = try genericRoot(r, key.file, item) orelse return null;
    const root_key = try r.ownerKey(key.file, root);
    const candidates = try r.ctx.get(Candidates, root_key);
    const files = candidates.files;
    for (0..files.len + 1) |fi| {
        const f = if (fi == 0) key.file else files[fi - 1];
        if (fi != 0 and (f == key.file or !try containsAny(r, f, candidates.names))) continue;
        for (try r.ctx.get(Callers, .{ .root = root_key, .in = f })) |i| {
            if (try findIn(r, f, i, key.file, item, root_key, candidates.names, depth, strict)) |s| return s;
        }
    }
    if (try typeFlow(r, key.file, item, root, files, depth, null, strict, null)) |s| return s;
    return dispatched(r, key.file, item, root);
}

/// The target's container is passed to a generic function as a comptime type argument, and the
/// target is then called through the type parameter (`ctx.get(hir.ItemBody, k)` → `get` → ... →
/// `Q.compute(ctx, key)` in `execute`). The file of the dispatch site need not import the target's
/// file, so following import chains does not find it: starting from calls that pass this
/// container type in their arguments, generic calls whose arguments still contain it are entered
/// level by level until the target is called.
/// When `all` is not null, collects all instances found this way and returns null.
fn typeFlow(r: *Resolver, file: FileId, item: u32, root: u32, files: []const FileId, depth: u8, all: ?*Collector, strict: bool, cut: ?*bool) resolve.Error!?Found {
    const tree = try r.itemTree(file);
    const container = tree.items[root].container;
    const decl_item = tree.containers[container].parent_item orelse return null;
    const name = tree.items[decl_item].name orelse return null;
    if (try genericRoot(r, file, decl_item) != null) return null;
    const target = try queries.containerType(r, .{ .file = file, .container = container }, null);
    const root_key = try r.ownerKey(file, root);
    const names = [_][]const u8{name};
    var flow: Flow = .{ .r = r, .target = target, .file = file, .item = item, .root_key = root_key, .all = all, .strict = strict, .cut = cut };
    for (files) |f| {
        if (!try containsAny(r, f, &names)) continue;
        const ft = try r.itemTree(f);
        for (ft.items, 0..) |_, i| {
            if (flow.full()) return null;
            if (!try mayMentionAny(r, f, @intCast(i), &names)) continue;
            const owner = try r.ownerKey(f, @intCast(i));
            const body = try r.ctx.get(hir.ItemBody, owner);
            if (!mentionsAny(body, &names)) continue;
            const res = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full });
            if (try flow.from(body, res, depth)) |found| return found;
        }
    }
    return null;
}

/// One `typeFlow` search: instances already entered are not entered again (mutually calling
/// generic functions)
const Flow = struct {
    r: *Resolver,
    target: Index,
    file: FileId,
    item: u32,
    root_key: hir.OwnerKey,
    all: ?*Collector,
    strict: bool,
    /// When not null, set to true when the depth is used up and entering stops
    cut: ?*bool,
    visited: std.ArrayList(Index) = .empty,

    fn full(fl: *const Flow) bool {
        const c = fl.all orelse return false;
        return c.full();
    }

    /// Generic calls in inference result `res` whose arguments contain the target container type:
    /// the calls to the target are searched for in that instance of the callee
    fn from(fl: *Flow, body: *const Body, res: *const infer.Result, depth: u8) resolve.Error!?Found {
        if (depth == 0) {
            if (fl.cut) |c| c.* = true;
            return null;
        }
        if (res.exprs.len != body.exprs.len) return null;
        const r = fl.r;
        const ip = r.ctx.db.env.ip;
        for (body.exprs, 0..) |e, ei| {
            if (fl.full()) return null;
            const c = switch (e) {
                .call => |c| c,
                else => continue,
            };
            if (fl.strict and withinInactive(body, res, @fromBackingInt(@as(u32, @intCast(ei))))) continue;
            const receiver: ?TypedValue = switch (body.expr(c.callee)) {
                .field_access => |fa| if (!res.exprs[@backingInt(fa.lhs)].isType()) res.exprs[@backingInt(fa.lhs)] else null,
                else => null,
            };
            const called = try calleeInstance(r, res, res.exprs[@backingInt(c.callee)], receiver, c.args, null) orelse continue;
            if (std.mem.indexOfScalar(Index, ip.key(called.inst).instance.args, fl.target) == null) continue;
            if (std.mem.indexOfScalar(Index, fl.visited.items, called.inst) != null) continue;
            try fl.visited.append(r.arena, called.inst);
            const ct = try r.itemTree(called.file);
            const ci: u32 = for (ct.items, 0..) |it, k| {
                if (it.ast_id == called.decl) break @intCast(k);
            } else continue;
            const owner = try r.ownerKey(called.file, ci);
            const callee_body = try r.ctx.get(hir.ItemBody, owner);
            const norm = try queries.normalizeInst(r, called.file, ci, called.inst);
            const callee_res = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full, .inst = norm });
            if (try callIn(r, called.file, ci, callee_body, callee_res, fl.file, fl.item, fl.root_key, fl.all, fl.strict)) |found| return found;
            if (try fl.from(callee_body, callee_res, depth - 1)) |found| return found;
        }
        return null;
    }
};

/// Functions in the standard library that dispatch by method name to methods of their arguments:
/// for `{f}` and the like, `printValue` calls `value.format(w)` and `value.formatNumber(w, ...)`.
/// When a generic method (such as `format(self, writer: anytype)`) has no call site in the
/// project, its instances are computed from the calls at these dispatch sites.
const dispatchers = [_]struct { path: []const []const u8, func: []const u8 }{
    .{ .path = &.{ "Io", "Writer" }, .func = "printValue" },
};

/// Instance of generic method `root` (which contains member `item`) at a standard library
/// dispatch site: the dispatch function calls the method of the same name on an anytype
/// parameter; the receiver is the method's container (not inside a generic function), and the
/// other arguments take the types inferred at the dispatch site
fn dispatched(r: *Resolver, file: FileId, item: u32, root: u32) resolve.Error!?Found {
    const ip = r.ctx.db.env.ip;
    const tree = try r.itemTree(file);
    const name = tree.items[root].name orelse return null;
    const container = tree.items[root].container;
    if (tree.containers[container].parent_item) |p| if (try genericRoot(r, file, p) != null) return null;
    const method: resolve.Def = .{ .item = .{ .file = file, .item = root } };
    const callee = try queries.defType(r, method, null, null);
    const f = switch (ip.key(callee.ty)) {
        .fn_type => |x| x,
        else => return null,
    };
    const g = try infer.genericCallee(r, r.arena, callee, f) orelse return null;
    if (g.body.params.len == 0) return null;
    const receiver: TypedValue = .{ .ty = try queries.containerType(r, .{ .file = file, .container = container }, null) };
    const std_root = try r.ctx.get(database.ModuleGraph.StdRoot, null) orelse return null;
    for (dispatchers) |d| {
        var t = try queries.containerType(r, .{ .file = std_root, .container = 0 }, null);
        for (d.path) |part| {
            const ns = try queries.namespaceOfType(r, t) orelse return null;
            const def = try r.memberDef(ns, part) orelse return null;
            t = (try queries.defType(r, def, null, null)).asType() orelse return null;
        }
        const ns = try queries.namespaceOfType(r, t) orelse continue;
        const it = switch (try r.memberDef(ns, d.func) orelse continue) {
            .item => |x| x,
            else => continue,
        };
        const owner = try r.ownerKey(it.file, it.item);
        const body = try r.ctx.get(hir.ItemBody, owner);
        const res = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full });
        if (res.exprs.len != body.exprs.len) continue;
        for (body.exprs, 0..) |e, ei| {
            const c = switch (e) {
                .call => |c| c,
                else => continue,
            };
            const fa = switch (body.expr(c.callee)) {
                .field_access => |x| x,
                else => continue,
            };
            if (!std.mem.eql(u8, fa.field orelse continue, name)) continue;
            // The receiver is an anytype parameter of the dispatch function
            const n = switch (body.expr(fa.lhs)) {
                .name_ref => |x| x,
                else => continue,
            };
            const l = switch (try r.resolveName(it.file, it.item, body, body.expr_scopes[@backingInt(fa.lhs)], n) orelse continue) {
                .local => |x| x,
                else => continue,
            };
            const binding = body.binding(l.binding);
            if (binding.kind != .param or binding.ty != null) continue;
            const args = try r.arena.alloc(TypedValue, g.body.params.len);
            for (args, 0..) |*a, ai| a.* = if (ai == 0) receiver else if (ai - 1 < c.args.len) res.exprs[@backingInt(c.args[ai - 1])] else .unknown;
            const inst = try infer.instanceOf(r, r.arena, g, f, args);
            if (!value.isConcrete(ip, inst)) continue;
            const norm = queries.genericInst(ip, try queries.normalizeInst(r, file, item, inst));
            return .{ .inst = norm, .owner = owner, .expr = @fromBackingInt(@as(u32, @intCast(ei))) };
        }
    }
    return null;
}

/// Callers in file `in` that the call-site lookup of generic function `root` must infer (member
/// indices, in order): members that mention the function name or an alias and cannot be excluded
/// statically (see `mentionsOnlyOthers`), excluding the function itself and members inside its
/// body. Independent of depth, strictness, and whether all instances are collected: shared by the
/// `Query` and `Instances` of every depth, so files need not be rescanned each time. Cached per
/// file: a lookup that stops once a call site is found does not scan the remaining files.
pub const Callers = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = struct { root: hir.OwnerKey, in: FileId };
    pub const Value = []const u32;

    pub fn compute(ctx: *database.Db.Ctx, key: Key) engine.Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        const file = key.root.file;
        const root: u32 = for ((try r.itemTree(file)).items, 0..) |it, i| {
            if (it.ast_id == key.root.item) break @intCast(i);
        } else return &.{};
        const names = (try ctx.get(Candidates, key.root)).names;
        var out: std.ArrayList(u32) = .empty;
        const tree = try r.itemTree(key.in);
        for (tree.items, 0..) |_, i| {
            // Calls inside the generic function's own body (recursion) are abstract too
            if (key.in == file and try enclosedBy(&r, file, @intCast(i), root)) continue;
            if (!try mayMentionAny(&r, key.in, @intCast(i), names)) continue;
            const body = try ctx.get(hir.ItemBody, try r.ownerKey(key.in, @intCast(i)));
            if (!mentionsAny(body, names) or try mentionsOnlyOthers(&r, key.in, @intCast(i), body, names, key.root)) continue;
            try out.append(r.arena, @intCast(i));
        }
        return ctx.db.gpa.dupe(u32, out.items);
    }

    pub fn eql(a: Value, b: Value) bool {
        return std.mem.eql(u32, a, b);
    }

    pub fn deinit(v: *Value, gpa: std.mem.Allocator) void {
        gpa.free(v.*);
    }
};

/// Seed lookups at all depths share the import candidates and alias closure related to the
/// target function; no presentation positions are cached.
pub const Candidates = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = hir.OwnerKey;
    pub const Value = *const Data;

    pub const Data = struct {
        arena: std.heap.ArenaAllocator,
        /// Searched files (see `search.searchFiles`) that can reach the target's file via
        /// `@import` chains: lookups of the first instance and of the first few instances follow
        /// their order, so instances found earlier come first
        files: []const FileId,
        /// `files` followed by the remaining searched files: the closure of all instances does not
        /// miss calls in generic code through `anytype` values or comptime type parameters
        all_files: []const FileId,
        names: []const []const u8,
    };

    pub fn compute(ctx: *database.Db.Ctx, key: Key) engine.Error!Value {
        const data = try ctx.db.gpa.create(Data);
        errdefer ctx.db.gpa.destroy(data);
        data.arena = .init(ctx.db.gpa);
        errdefer data.arena.deinit();
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        const tree = try r.itemTree(key.file);
        const root: u32 = for (tree.items, 0..) |it, i| {
            if (it.ast_id == key.item) break @intCast(i);
        } else {
            data.files = &.{};
            data.all_files = &.{};
            data.names = &.{};
            return data;
        };
        const allocator = data.arena.allocator();
        data.files = try allocator.dupe(FileId, try ctx.get(search.ProjectImporters, key.file));
        var all: std.AutoArrayHashMapUnmanaged(FileId, void) = .empty;
        for (data.files) |f| try all.put(r.arena, f, {});
        for (try search.searchFiles(&r)) |f| try all.put(r.arena, f, {});
        data.all_files = try allocator.dupe(FileId, all.keys());
        const names = try callNames(&r, key.file, root, data.files);
        const owned = try allocator.alloc([]const u8, names.len);
        for (names, owned) |name, *out| out.* = try allocator.dupe(u8, name);
        data.names = owned;
        return data;
    }

    pub fn eql(a: Value, b: Value) bool {
        if (!std.mem.eql(FileId, a.files, b.files) or !std.mem.eql(FileId, a.all_files, b.all_files) or a.names.len != b.names.len) return false;
        for (a.names, b.names) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        return true;
    }

    pub fn deinit(v: *Value, gpa: std.mem.Allocator) void {
        const data = @constCast(v.*);
        data.arena.deinit();
        gpa.destroy(data);
    }
};

/// Names that calls to generic function `root` may use: the function name, plus container-level
/// aliases to it in `files` (`const biggest = lib.max;`, including aliases of aliases). Only files
/// whose file index contains these names are checked.
fn callNames(r: *Resolver, file: FileId, root: u32, files: []const FileId) resolve.Error![]const []const u8 {
    const target: resolve.Def = .{ .item = .{ .file = file, .item = root } };
    var names: std.ArrayList([]const u8) = .empty;
    try names.append(r.arena, (try r.itemTree(file)).items[root].name orelse return &.{});
    var changed = true;
    while (changed) {
        changed = false;
        for (files) |f| {
            if (!try containsAny(r, f, names.items)) continue;
            const tree = try r.itemTree(f);
            for (tree.items, 0..) |it, i| {
                if (it.kind != .@"const") continue;
                const name = it.name orelse continue;
                if (contains(names.items, name)) continue;
                if (!try mayMentionAny(r, f, @intCast(i), names.items)) continue;
                if (!mentionsAny(try r.body(f, @intCast(i)), names.items)) continue;
                const def = try r.aliasTarget(.{ .item = .{ .file = f, .item = @intCast(i) } });
                if (!std.meta.eql(def, target)) continue;
                try names.append(r.arena, name);
                changed = true;
            }
        }
    }
    return names.items;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn containsAny(r: *Resolver, f: FileId, names: []const []const u8) resolve.Error!bool {
    const index = try r.ctx.get(FileIndex.Query, f);
    for (names) |n| if (index.contains(n)) return true;
    return false;
}

/// Coarse filtering by the member summary first, to avoid building a Body for unrelated members
fn mayMentionAny(r: *Resolver, f: FileId, item: u32, names: []const []const u8) resolve.Error!bool {
    for (names) |n| if (try r.mayMention(f, item, n)) return true;
    return false;
}

fn mentionsAny(body: *const Body, names: []const []const u8) bool {
    for (names) |n| if (search.mentions(body, n)) return true;
    return false;
}

/// Every place where member `i` (in `in`) mentions `names` can be determined without inference to
/// refer to a function declaration other than `root_key`: the member does not call `root_key` and
/// need not be inferred (inferring members that mention common names such as `print` and `init`
/// is the main cost of call-site lookup).
/// False when a mention cannot be resolved, refers to an alias or a field (whose value may be the
/// target), is an enum literal (a decl literal may call the target), or is a field name in an
/// initializer.
fn mentionsOnlyOthers(r: *Resolver, in: FileId, i: u32, body: *const Body, names: []const []const u8, root_key: hir.OwnerKey) resolve.Error!bool {
    for (body.exprs, 0..) |e, ei| {
        switch (e) {
            .name_ref => |n| if (!contains(names, n)) continue,
            .field_access => |fa| if (!contains(names, fa.field orelse continue)) continue,
            .enum_literal => |n| if (contains(names, n)) return false else continue,
            .init => |x| {
                for (x.fields) |fi| if (fi.name) |n| if (contains(names, n)) return false;
                continue;
            },
            else => continue,
        }
        const def = try staticRef(r, in, i, body, @fromBackingInt(@as(u32, @intCast(ei)))) orelse return false;
        const it = switch (def) {
            .item => |x| x,
            else => return false,
        };
        if ((try r.itemTree(it.file)).items[it.item].kind != .@"fn") return false;
        if (std.meta.eql(try r.ownerKey(it.file, it.item), root_key)) return false;
    }
    return true;
}

/// The declaration that `e` (a name or member access) refers to, determined without inference:
/// names are resolved by lexical scope; for a member access whose left side is a namespace, or a
/// value of known type (see `staticValueType`), the member is looked up in the type's namespace.
/// Null when it cannot be resolved.
fn staticRef(r: *Resolver, in: FileId, i: u32, body: *const Body, e: Body.ExprId) resolve.Error!?resolve.Def {
    switch (body.expr(e)) {
        .name_ref => |n| return r.resolveName(in, i, body, body.expr_scopes[@backingInt(e)], n),
        .field_access => |fa| {
            const field = fa.field orelse return null;
            if (try r.evalNamespace(in, i, body, fa.lhs)) |ns| return r.memberDef(ns, field);
            const ty = try staticValueType(r, in, i, body, fa.lhs) orelse return null;
            const ns = try queries.namespaceOfType(r, ty) orelse return null;
            return r.memberDef(ns, field);
        },
        else => return null,
    }
}

/// The type of value `e` determined without inferring the function body (a single-item pointer
/// yields its pointee type): a global declaration's value takes the declaration's type, and a
/// parameter of the current member takes the type in the signature. Null when it cannot be
/// resolved, or is a type or abstract.
fn staticValueType(r: *Resolver, in: FileId, i: u32, body: *const Body, e: Body.ExprId) resolve.Error!?Index {
    switch (body.expr(e)) {
        .name_ref, .field_access => {},
        else => return null,
    }
    const tv: TypedValue = switch (try staticRef(r, in, i, body, e) orelse return null) {
        .item => |it| blk: {
            switch ((try r.itemTree(it.file)).items[it.item].kind) {
                .@"const", .@"var" => {},
                else => return null,
            }
            break :blk try queries.defType(r, .{ .item = it }, null, null);
        },
        .local => |l| blk: {
            if (l.file != in or l.item != i or body.binding(l.binding).kind != .param) return null;
            const sig = try r.ctx.get(queries.Infer, .{ .owner = try r.ownerKey(in, i), .mode = .signature });
            if (@backingInt(l.binding) >= sig.bindings.len) return null;
            break :blk sig.bindings[@backingInt(l.binding)];
        },
        .file => return null,
    };
    if (tv.ty == .unknown or tv.isType()) return null;
    const ip = r.ctx.db.env.ip;
    const ty = switch (ip.key(tv.ty)) {
        .ptr_type => |p| if (p.size == .one) p.child else return null,
        else => tv.ty,
    };
    return if (ty == .unknown) null else ty;
}

/// The first call to generic function `root_key` in caller `i` (in `in`; see `Callers`) that
/// yields a concrete instance
fn findIn(r: *Resolver, in: FileId, i: u32, file: FileId, item: u32, root_key: hir.OwnerKey, names: []const []const u8, depth: u8, strict: bool) resolve.Error!?Found {
    const owner = try r.ownerKey(in, i);
    const body = try r.ctx.get(hir.ItemBody, owner);
    const res = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full });
    if (try callIn(r, in, i, body, res, file, item, root_key, null, strict)) |s| return s;
    if (try loopCall(r, in, i, owner, body, res, null, names, file, item, root_key, null, strict)) |s| return s;
    // The caller itself is inside a generic function (such as `run(op, dst: anytype, ...)`, which
    // dispatches by enum to the generic implementations): the arguments are abstract, so infer the
    // caller under its call-site instance and search again; the caller's instance comes from the
    // lookup one level shallower
    if (depth == 0 or try genericRoot(r, in, i) == null) return null;
    if (!mayCall(r.ctx.db.env.ip, body, res, root_key)) return null;
    const outer = try r.ctx.get(Query, .{ .owner = owner, .depth = depth - 1 }) orelse return null;
    const seeded = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full, .inst = outer.inst });
    if (try callIn(r, in, i, body, seeded, file, item, root_key, null, strict)) |s| return s;
    if (try loopCall(r, in, i, owner, body, seeded, outer.inst, names, file, item, root_key, null, strict)) |s| return s;
    // No valid call under the first instance (e.g. the call is in a `switch (Q.kind)` prong that
    // the instance does not execute): try the caller's other instances in turn
    for (try r.ctx.get(Instances, .{ .owner = owner, .depth = depth - 1 })) |other| {
        if (other.inst == outer.inst) continue;
        const res3 = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full, .inst = other.inst });
        if (try callIn(r, in, i, body, res3, file, item, root_key, null, strict)) |s| return s;
        if (try loopCall(r, in, i, owner, body, res3, other.inst, names, file, item, root_key, null, strict)) |s| return s;
    }
    return null;
}

/// The first call to `root_key` in member `i` (in `in`) that yields a concrete instance according
/// to inference result `res`. A function passed as a value together with an argument tuple into
/// another call (`Thread.spawn(.{}, f, .{ a, b })`, `@call(.auto, f, .{ a, b })`) also counts as
/// a call with the tuple elements.
/// When `all` is not null, adds the instances of all calls (deduplicated) to it and returns null.
fn callIn(r: *Resolver, in: FileId, i: u32, body: *const Body, res: *const infer.Result, file: FileId, item: u32, root_key: hir.OwnerKey, all: ?*Collector, strict: bool) resolve.Error!?Found {
    if (res.exprs.len != body.exprs.len) return null;
    for (body.exprs, 0..) |e, ei| {
        switch (e) {
            .call, .builtin_call => {},
            else => continue,
        }
        // When `strict`, calls in code the caller does not compile under this instance (such as
        // the other prongs of `switch (Q.kind)`) produce no instances; the lookup is relaxed only
        // when the strict one finds nothing at all (all calls are in branches that no instance in
        // the project compiles), so that some instance is still available
        if (strict and withinInactive(body, res, @fromBackingInt(@as(u32, @intCast(ei))))) continue;
        const site: Site = .{ .r = r, .in = in, .i = i, .body = body, .res = res, .expr = @intCast(ei), .file = file, .item = item, .root_key = root_key, .all = all };
        switch (e) {
            .call => |c| {
                // Method call: the receiver is the first argument
                const receiver: ?TypedValue = switch (body.expr(c.callee)) {
                    .field_access => |fa| if (!res.exprs[@backingInt(fa.lhs)].isType()) res.exprs[@backingInt(fa.lhs)] else null,
                    else => null,
                };
                if (try site.instance(res.exprs[@backingInt(c.callee)], receiver, c.args)) |x| return x;
                if (try site.passed(c.args)) |x| return x;
            },
            .builtin_call => |b| if (try site.passed(b.args)) |x| return x,
            else => {},
        }
    }
    return null;
}

/// Whether inference result `res` may contain a call to `root_key`: the value of a callee
/// expression, or of a function argument passed along with a tuple (see `Site.passed`), is not a
/// known other function or other value. Values already resolved in the abstract inference are the
/// same under every instance of the caller (unknown conditions select no branch), so when all of
/// them are excluded, the caller's instances would not find a call either, and the caller's call
/// sites need not be searched.
fn mayCall(ip: *InternPool, body: *const Body, res: *const infer.Result, root_key: hir.OwnerKey) bool {
    if (res.exprs.len != body.exprs.len) return true;
    for (body.exprs) |e| switch (e) {
        .call => |c| if (mayBe(ip, res.exprs[@backingInt(c.callee)], root_key) or mayPass(ip, body, res, c.args, root_key)) return true,
        .builtin_call => |b| if (mayPass(ip, body, res, b.args, root_key)) return true,
        else => {},
    };
    return false;
}

/// Like `Site.passed`: an argument immediately followed by an anonymous tuple literal
fn mayPass(ip: *InternPool, body: *const Body, res: *const infer.Result, args: []const Body.ExprId, root_key: hir.OwnerKey) bool {
    if (args.len < 2) return false;
    for (args[0 .. args.len - 1], args[1..]) |f_e, tuple_e| {
        const init = switch (body.expr(tuple_e)) {
            .init => |x| x,
            else => continue,
        };
        if (init.ty != null) continue;
        for (init.fields) |fi| {
            if (fi.name != null) break;
        } else if (mayBe(ip, res.exprs[@backingInt(f_e)], root_key)) return true;
    }
    return false;
}

/// Value `tv` may be function `root_key` under some instance: the value is unknown or contains
/// abstract parts, or is that function itself
fn mayBe(ip: *InternPool, tv: TypedValue, root_key: hir.OwnerKey) bool {
    const v = tv.val orelse return true;
    if (!value.isConcrete(ip, v)) return true;
    return switch (ip.key(v)) {
        .fn_value => |f| f.file == root_key.file and f.decl == root_key.item,
        else => false,
    };
}

/// A call expression in `callIn`
const Site = struct {
    r: *Resolver,
    in: FileId,
    i: u32,
    body: *const Body,
    res: *const infer.Result,
    expr: u32,
    file: FileId,
    item: u32,
    root_key: hir.OwnerKey,
    all: ?*Collector,

    /// A function value in the arguments immediately followed by an anonymous tuple literal: the
    /// function is called with the tuple elements
    fn passed(s: Site, args: []const Body.ExprId) resolve.Error!?Found {
        if (args.len < 2) return null;
        for (args[0 .. args.len - 1], args[1..]) |f_e, tuple_e| {
            const init = switch (s.body.expr(tuple_e)) {
                .init => |x| x,
                else => continue,
            };
            if (init.ty != null) continue;
            const elems = try s.r.arena.alloc(Body.ExprId, init.fields.len);
            for (init.fields, elems) |fi, *out| {
                if (fi.name != null) break;
                out.* = fi.value;
            } else if (try s.instance(s.res.exprs[@backingInt(f_e)], null, elems)) |x| return x;
        }
        return null;
    }

    /// A call with `callee` (and the receiver) and arguments `args`: returns the call site when
    /// callee is `root_key` and the instance is concrete
    fn instance(s: Site, callee: TypedValue, receiver: ?TypedValue, args: []const Body.ExprId) resolve.Error!?Found {
        const r = s.r;
        const inst = (try calleeInstance(r, s.res, callee, receiver, args, s.root_key) orelse return null).inst;
        const site_owner = try r.ownerKey(s.in, s.i);
        const norm = queries.genericInst(r.ctx.db.env.ip, try queries.normalizeInst(r, s.file, s.item, inst));
        if (s.all) |c| {
            try c.add(r.arena, .{ .inst = norm, .owner = site_owner, .expr = @fromBackingInt(s.expr) });
            return null;
        }
        return .{ .inst = norm, .owner = site_owner, .expr = @fromBackingInt(s.expr) };
    }
};

/// The called generic function and concrete instance of a call: when callee is the value of a
/// generic function and the instance computed from the arguments (and receiver) is concrete. When
/// `only` is not null, only calls to it are considered (the callee is compared before computing
/// the instance).
const Called = struct { file: FileId, decl: @import("../syntax/ItemTree.zig").AstId, inst: Index };

fn calleeInstance(r: *Resolver, res: *const infer.Result, callee: TypedValue, receiver: ?TypedValue, args: []const Body.ExprId, only: ?hir.OwnerKey) resolve.Error!?Called {
    const ip = r.ctx.db.env.ip;
    const fv = switch (ip.key(callee.val orelse return null)) {
        .fn_value => |v| v,
        else => return null,
    };
    if (only) |k| if (fv.file != k.file or fv.decl != k.item) return null;
    const f = switch (ip.key(callee.ty)) {
        .fn_type => |f| f,
        else => return null,
    };
    const g = try infer.genericCallee(r, r.arena, callee, f) orelse return null;
    const skip: usize = @intFromBool(receiver != null);
    const tvs = try r.arena.alloc(TypedValue, g.body.params.len);
    for (tvs, 0..) |*a, ai| a.* = if (ai < skip) receiver.? else if (ai - skip < args.len) res.exprs[@backingInt(args[ai - skip])] else .unknown;
    const inst = try infer.instanceOf(r, r.arena, g, f, tvs);
    if (!value.isConcrete(ip, inst)) return null;
    return .{ .file = fv.file, .decl = fv.decl, .inst = inst };
}

/// The innermost generic function containing member `item` (the member itself, or an enclosing
/// function via a container defined in its body)
pub fn genericRoot(r: *Resolver, file: FileId, item: u32) resolve.Error!?u32 {
    const tree = try r.itemTree(file);
    var cur: ?u32 = item;
    while (cur) |it| : (cur = tree.containers[tree.items[it].container].parent_item) {
        if (tree.items[it].kind == .@"fn" and try isGeneric(r, file, it)) return it;
    }
    return null;
}

/// A function with comptime (including implicit) or anytype parameters, or one that returns a
/// comptime-only type
fn isGeneric(r: *Resolver, file: FileId, item: u32) resolve.Error!bool {
    const owner = try r.ownerKey(file, item);
    const body = try r.ctx.get(hir.ItemBody, owner);
    for (body.params) |p| {
        const b = body.binding(p);
        if (b.is_comptime or b.ty == null) return true;
    }
    const decl = try r.ctx.get(queries.DeclType, .{ .owner = owner });
    const f = switch (r.ctx.db.env.ip.key(decl.ty)) {
        .fn_type => |f| f,
        else => return false,
    };
    for (f.params) |p| if (try eval.isComptimeOnly(r, p)) return true;
    return eval.isComptimeOnly(r, f.ret);
}

fn enclosedBy(r: *Resolver, file: FileId, item: u32, root: u32) resolve.Error!bool {
    const tree = try r.itemTree(file);
    var cur: ?u32 = item;
    while (cur) |it| : (cur = tree.containers[tree.items[it].container].parent_item) {
        if (it == root) return true;
    }
    return false;
}

/// The type contains abstract parameters or unknown parts: worth re-inferring under a call-site
/// instance
pub fn wanted(ip: *InternPool, tv: TypedValue) bool {
    if (tv.ty == .unknown or !value.isConcrete(ip, tv.ty)) return true;
    if (tv.ty == .type_type) return tv.val == null or !value.isConcrete(ip, tv.val.?);
    return false;
}
