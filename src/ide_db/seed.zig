//! 调用点种子：泛型函数体内没有具体实例时（抽象参数、未知），取一个调用点的实例
//! 推导，hover 注明所依据的调用点。先按源码顺序找同一文件，再经由文件索引找其他文件，取第一个
//! 能求出具体实例的调用，结果确定、可复现。

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
    /// 成员 `item` 在调用点实例下的推导结果
    res: *const infer.Result,
    /// 所用的实例
    inst: ?Index,
    /// 调用表达式的位置；`iteration` 不为 null 时为循环的位置
    file: FileId,
    offset: u32,
    /// 按遍历类型列表的循环的这次迭代（从 0 开始）推导
    iteration: ?u32 = null,
};

/// 成员 `item`（位于某个泛型函数内）以第一个调用点的实例推导的结果：先找同一文件，再按文件顺序找
/// 项目中其他能引用到该函数的文件
pub fn find(r: *Resolver, file: FileId, item: u32) resolve.Error!?Seed {
    if (!r.ctx.db.env.callsite_seeding.load(.monotonic)) return null;
    const owner = try r.ownerKey(file, item);
    const found = try r.ctx.get(Query, .{ .owner = owner, .depth = max_depth }) orelse return null;
    return present(r, owner, found);
}

/// 光标处须能求出具体类型的部分：表达式或局部绑定
pub const Subject = union(enum) { expr: Body.ExprId, binding: Body.BindingId };

/// 一次成员分析共享调用点候选与迭代推导；每个位置在调用点和循环迭代的组合中选择。
pub const Refiner = struct {
    r: *Resolver,
    owner: hir.OwnerKey,
    node_offset: u32,
    body: *const Body,
    abstract: Variant,
    candidates: std.ArrayList(Variant) = .empty,
    loaded: u8 = 0,
    stage_ends: [4]usize = @splat(0),
    loop_regions: ?[]const LoopRegion = null,

    const LoopRegion = struct { expr: Body.ExprId, range: Body.Range };

    const Variant = struct {
        res: ?*const infer.Result = null,
        inst: ?Index = null,
        origin: ?Found = null,
        presentation: ?Seed = null,
        loops: std.ArrayList(LoopResults) = .empty,
    };
    const LoopResults = struct {
        expr: Body.ExprId,
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
        // 每个位置独立经过相同层级；之前的位置预热了更深的候选也不改变选择顺序。
        for (0..4) |stage| {
            if (stage == 3 and (fallback != null or f.stage_ends[2] == 0)) return fallback;
            if (f.loaded <= stage) {
                switch (stage) {
                    0 => if (try f.r.ctx.get(Query, .{ .owner = f.owner, .depth = max_depth })) |found| try f.add(found),
                    1 => for (try f.r.ctx.get(Instances, .{ .owner = f.owner, .depth = max_depth })) |found| try f.add(found),
                    2 => for (try f.r.ctx.get(Instances, .{ .owner = f.owner, .depth = max_collect_depth, .all = true })) |found| try f.add(found),
                    // 深层活动分支的有界回退同样在成员内共享，不按位置递归搜索项目。
                    3 => for (try f.r.ctx.get(Instances, .{ .owner = f.owner, .depth = max_depth, .all = true })) |found| try f.add(found),
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
            const loop = switch (expr) {
                .loop => |l| l,
                else => continue,
            };
            if (loop.kind != .@"for") continue;
            try out.append(f.r.arena, .{
                .expr = @fromBackingInt(@as(u32, @intCast(ei))),
                .range = f.body.range(loop.body),
            });
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
        // 只选择包含此位置的最内层异构循环；同一循环的其他捕获由 Infer 一并细化。
        var best: ?LoopResults = null;
        var best_len: u32 = std.math.maxInt(u32);
        for (try f.regions()) |region| {
            const range = region.range;
            if (rel < range.start or rel > range.end or range.end - range.start >= best_len) continue;
            const id = region.expr;
            const loop = f.body.expr(id).loop;
            const cached = for (candidate.loops.items) |entry| {
                if (entry.expr == id) break entry;
            } else blk: {
                const entry: LoopResults = for (loop.capture, 0..) |capture, k| {
                    const n = try iterations(f.r, res, loop, k) orelse continue;
                    const results = try f.r.arena.alloc(?*const infer.Result, n);
                    @memset(results, null);
                    break .{ .expr = id, .binding = @backingInt(capture), .results = results };
                } else .{ .expr = id, .binding = 0, .results = &.{} };
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

/// 循环按迭代推导时尝试的迭代次数上限
const max_iterations = 64;

/// 循环 `l` 的第 `k` 个循环变量需要按迭代推导时的迭代次数（至多 `max_iterations`）：遍历 comptime 已知的类型列表
/// （`inline for`，或 comptime 中的 `for`；循环变量在推导中是抽象的类型），或遍历各项类型不同的元组（`inline for
/// (.{ &posix, &windows }) |cases|`；循环变量的类型求不出）
fn iterations(r: *Resolver, res: *const infer.Result, l: Body.Loop, k: usize) resolve.Error!?u32 {
    if (k >= l.inputs.len or k >= l.capture.len) return null;
    const ip = r.ctx.db.env.ip;
    const cap = l.capture[k];
    if (@backingInt(cap) >= res.bindings.len or @backingInt(l.inputs[k]) >= res.exprs.len) return null;
    const list = res.exprs[@backingInt(l.inputs[k])];
    const binding = res.bindings[@backingInt(cap)];
    if (binding.val) |v| if (ip.key(v) == .opaque_param) {
        var n: u32 = 0;
        while (n < max_iterations and try eval.elemValue(r, list, n) != null) n += 1;
        return if (n > 0) n else null;
    };
    if (binding.ty != .unknown) return null;
    const tt = infer.tupleOf(ip, list.ty) orelse return null;
    if (tt.types.len == 0) return null;
    return @intCast(@min(tt.types.len, max_iterations));
}

/// 成员 `i`（位于 `in`）中每次迭代的循环变量类型不同的循环（见 `iterations`）内提到 `names` 的调用：实参求不出
/// 具体的实例；按各次迭代推导（实例 `inst` 下的结果为 `res`）再找。`all` 不为 null 时收集
fn loopCall(r: *Resolver, in: FileId, i: u32, owner: hir.OwnerKey, body: *const Body, res: *const infer.Result, inst: ?Index, names: []const []const u8, file: FileId, item: u32, root_key: hir.OwnerKey, all: ?*Collector, strict: bool) resolve.Error!?Found {
    if (res.exprs.len != body.exprs.len) return null;
    for (body.exprs) |e| {
        const l = switch (e) {
            .loop => |l| l,
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

/// `e` 的范围内引用了 `names` 中的名字（名字或成员名）
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

/// 实例的推导结果 `res` 中，`rel` 处的代码会执行，且 `subject` 有具体的类型。没有转换为枚举的枚举字面量
/// （`switch (Q.kind)` 的 `.input =>`，类型仍为 `@Type(.enum_literal)`）还不知道指向哪个成员，不算
fn fits(ip: *InternPool, body: *const Body, res: *const infer.Result, rel: u32, subject: ?Subject) bool {
    if (inactiveAt(body, res, rel)) return false;
    const tv = switch (subject orelse return true) {
        .expr => |e| if (@backingInt(e) < res.exprs.len) res.exprs[@backingInt(e)] else return false,
        .binding => |b| if (@backingInt(b) < res.bindings.len) res.bindings[@backingInt(b)] else return false,
    };
    return !wanted(ip, tv) and tv.ty != .enum_literal_type;
}

/// 相对位置 `rel` 落在推导结果的非活动分支中。分支的末尾也算在内：补全的位置常在刚输入的 `a.` 之后，
/// 即分支的末尾
fn inactiveAt(body: *const Body, res: *const infer.Result, rel: u32) bool {
    for (res.inactive) |e| {
        const rg = body.range(e);
        if (rg.start <= rel and rel <= rg.end) return true;
    }
    for (res.dead_spans) |rg| if (rg.start <= rel and rel <= rg.end) return true;
    return false;
}

/// 表达式 `e` 整个位于推导结果 `res` 的非活动代码中
fn withinInactive(body: *const Body, res: *const infer.Result, e: Body.ExprId) bool {
    const er = body.range(e);
    for (res.inactive) |x| {
        const rg = body.range(x);
        if (rg.start <= er.start and er.end <= rg.end) return true;
    }
    for (res.dead_spans) |rg| if (rg.start <= er.start and er.end <= rg.end) return true;
    return false;
}

/// 调用点只保留稳定的成员和表达式身份；当前位置在向 IDE 返回结果时求出。
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

/// 经由泛型调用者传递的最大层数：z2d 的 `toRGBA` 由泛型的 `hue` 调用，`hue` 又由泛型的 `run` 分派；
/// websocket.zig 的 `_handleClientData` 经 `handleClientData`、`NonBlockingBase` 的方法、`NonBlocking` 的字段、
/// `listen`、`listenInNewThread`（`Thread.spawn` 传入）才到具体的 `Server(TestHandler)`
pub const max_depth = 6;

/// 收集全部实例时的最大层数：每层取调用者的全部实例，实例数随层数成倍增长（http.zig 的查找引用在 6 层时
/// 要数秒）
const max_collect_depth = 3;

/// 调用点的查找按成员与层数缓存：补全、inlay hints 等频繁的请求不必每次重新查找。先严格查找，没有结果时放宽
/// （见 `callIn`）。
/// 层数为 d 的查找为位于泛型函数内的调用者取实例时使用层数 d - 1 的查找（0 层只看实参本身具体的调用点）。
/// 层数严格递减，不会成环：互相调用的泛型函数（http.zig 的 `execute` 与 `init`）若以同一个 key 递归，
/// 环中的结果不写入 memo，每次请求都重新计算且层层放大
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

/// `Instances` 保留的实例个数：第一个实例不适用时依次尝试，调用点很多时只取前几个
pub const max_seeds = 8;

/// 成员在各调用点的不同实例（按查找顺序，去重）。调用者自身位于泛型函数内时取调用者的实例（同样的 `all`，
/// 层数少一层）。`all` 为 false 时只取前 `max_seeds` 个：第一个实例不适用时（光标处的代码不执行、表达式求不出
/// 类型、调用位于该实例不执行的分支中）依次尝试；为 true 时至多 `max_instances` 个，用于需要覆盖所有实例的
/// 场合（`allInstances`）。与 `Query` 一样，严格查找没有结果时放宽
pub const Instances = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = struct { owner: hir.OwnerKey, depth: u8, all: bool = false };
    pub const Value = []const Found;

    pub fn compute(ctx: *database.Db.Ctx, key: Key) engine.Error!Value {
        var scratch: std.heap.ArenaAllocator = .init(ctx.db.gpa);
        defer scratch.deinit();
        var r: Resolver = .{ .ctx = ctx, .arena = scratch.allocator() };
        var out: Collector = .{ .limit = if (key.all) max_instances else max_seeds, .all = key.all };
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

/// 成员 `item`（位于某个泛型函数内）在各调用点的全部具体实例（去重，按查找顺序）。调用者自身位于泛型函数内时
/// 取调用者的全部实例（最多 `max_collect_depth` 层）。用于需要覆盖所有实例的场合（引用查找与重命名）
pub fn allInstances(r: *Resolver, file: FileId, item: u32) resolve.Error![]const Index {
    if (!r.ctx.db.env.callsite_seeding.load(.monotonic)) return &.{};
    const found = try r.ctx.get(Instances, .{ .owner = try r.ownerKey(file, item), .depth = max_collect_depth, .all = true });
    const insts = try r.arena.alloc(Index, found.len);
    for (found, insts) |f, *inst| inst.* = f.inst.?;
    return insts;
}

/// 实例个数的上限：超过时截断（调用点极多的泛型函数）
const max_instances = 64;

/// 收集的实例：按实例去重，至多 `limit` 个
const Collector = struct {
    found: std.ArrayList(Found) = .empty,
    limit: usize,
    /// 见 `Instances.Key`
    all: bool,
    /// 见 `callIn`
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
    // 类型流的层数不受收集层数限制：它只进入实参含有目标容器的实例，不会成倍增长
    _ = try typeFlow(r, key.file, item, root, files, max_depth, out, out.strict);
    if (out.found.items.len == 0) if (try dispatched(r, key.file, item, root)) |found| try out.add(r.arena, found);
}

/// 同 `findIn`，收集全部实例
fn collectIn(r: *Resolver, in: FileId, i: u32, file: FileId, item: u32, root_key: hir.OwnerKey, names: []const []const u8, depth: u8, out: *Collector) resolve.Error!void {
    const owner = try r.ownerKey(in, i);
    const body = try r.ctx.get(hir.ItemBody, owner);
    const res = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full });
    _ = try callIn(r, in, i, body, res, file, item, root_key, out, out.strict);
    _ = try loopCall(r, in, i, owner, body, res, null, names, file, item, root_key, out, out.strict);
    if (depth == 0 or try genericRoot(r, in, i) == null) return;
    if (!mayCall(r.ctx.db.env.ip, body, res, root_key)) return;
    for (try r.ctx.get(Instances, .{ .owner = owner, .depth = depth - 1, .all = out.all })) |o| {
        if (out.full()) return;
        const seeded = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full, .inst = o.inst });
        _ = try callIn(r, in, i, body, seeded, file, item, root_key, out, out.strict);
        _ = try loopCall(r, in, i, owner, body, seeded, o.inst, names, file, item, root_key, out, out.strict);
    }
}

/// 成员 `key` 的第一个能求出具体实例的调用点。`strict` 见 `callIn`。
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
    if (try typeFlow(r, key.file, item, root, files, depth, null, strict)) |s| return s;
    return dispatched(r, key.file, item, root);
}

/// 目标所在的容器作为 comptime 类型实参传入泛型函数，再经类型参数调用目标（`ctx.get(hir.ItemBody, k)` →
/// `get` → … → `execute` 中的 `Q.compute(ctx, key)`）。分派处所在的文件不必 import 目标所在的文件，按导入链
/// 找不到：从实参中传入这个容器类型的调用出发，逐层进入实参中仍含有它的泛型调用，直到调用目标处。
/// `all` 不为 null 时收集全部这样找到的实例，返回 null
fn typeFlow(r: *Resolver, file: FileId, item: u32, root: u32, files: []const FileId, depth: u8, all: ?*Collector, strict: bool) resolve.Error!?Found {
    const tree = try r.itemTree(file);
    const container = tree.items[root].container;
    const decl_item = tree.containers[container].parent_item orelse return null;
    const name = tree.items[decl_item].name orelse return null;
    if (try genericRoot(r, file, decl_item) != null) return null;
    const target = try queries.containerType(r, .{ .file = file, .container = container }, null);
    const root_key = try r.ownerKey(file, root);
    const names = [_][]const u8{name};
    var flow: Flow = .{ .r = r, .target = target, .file = file, .item = item, .root_key = root_key, .all = all, .strict = strict };
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

/// `typeFlow` 的一次查找：已进入过的实例不再进入（互相调用的泛型函数）
const Flow = struct {
    r: *Resolver,
    target: Index,
    file: FileId,
    item: u32,
    root_key: hir.OwnerKey,
    all: ?*Collector,
    strict: bool,
    visited: std.ArrayList(Index) = .empty,

    fn full(fl: *const Flow) bool {
        const c = fl.all orelse return false;
        return c.full();
    }

    /// 推导结果 `res` 中实参含有目标容器类型的泛型调用：在被调函数的该实例中找对目标的调用
    fn from(fl: *Flow, body: *const Body, res: *const infer.Result, depth: u8) resolve.Error!?Found {
        if (depth == 0 or res.exprs.len != body.exprs.len) return null;
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

/// 标准库中按方法名分派到实参的方法的函数：`printValue` 对 `{f}` 等调用 `value.format(w)`、
/// `value.formatNumber(w, ...)`。泛型方法（如 `format(self, writer: anytype)`）在项目中没有调用点时，
/// 以这些分派处的调用求实例
const dispatchers = [_]struct { path: []const []const u8, func: []const u8 }{
    .{ .path = &.{ "Io", "Writer" }, .func = "printValue" },
};

/// 泛型方法 `root`（成员 `item` 位于其中）在标准库分派处的实例：分派函数中对 anytype 参数调用同名方法，
/// 接收者为方法所在的容器（不在泛型函数内），其余实参取分派处推导的类型
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
    const std_root = try r.ctx.get(database.ModuleGraph.StdRoot, {}) orelse return null;
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
            // 接收者是分派函数的 anytype 参数
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
            const norm = try queries.normalizeInst(r, file, item, inst);
            return .{ .inst = norm, .owner = owner, .expr = @fromBackingInt(@as(u32, @intCast(ei))) };
        }
    }
    return null;
}

/// 泛型函数 `root` 的调用点查找在文件 `in` 中要推导的调用者（成员下标，按顺序）：提到函数名或别名的成员，不含
/// 函数自身及其体内的成员。与层数、严格与否、是否收集全部实例无关：各层的 `Query` 与 `Instances` 共享，不必每次
/// 重新扫描文件。按文件缓存：找到调用点即停止的查找不扫描其余文件
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
            // 泛型函数自身体内的调用（递归）也是抽象的
            if (key.in == file and try enclosedBy(&r, file, @intCast(i), root)) continue;
            if (!try mayMentionAny(&r, key.in, @intCast(i), names)) continue;
            const body = try ctx.get(hir.ItemBody, try r.ownerKey(key.in, @intCast(i)));
            if (!mentionsAny(body, names)) continue;
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

/// 各层种子查找共享与目标函数有关的导入候选和别名闭包，不缓存任何展示位置。
pub const Candidates = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = hir.OwnerKey;
    pub const Value = *const Data;

    pub const Data = struct {
        arena: std.heap.ArenaAllocator,
        files: []const FileId,
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
            data.names = &.{};
            return data;
        };
        const allocator = data.arena.allocator();
        data.files = try allocator.dupe(FileId, try ctx.get(search.ProjectImporters, key.file));
        const names = try callNames(&r, key.file, root, data.files);
        const owned = try allocator.alloc([]const u8, names.len);
        for (names, owned) |name, *out| out.* = try allocator.dupe(u8, name);
        data.names = owned;
        return data;
    }

    pub fn eql(a: Value, b: Value) bool {
        if (!std.mem.eql(FileId, a.files, b.files) or a.names.len != b.names.len) return false;
        for (a.names, b.names) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        return true;
    }

    pub fn deinit(v: *Value, gpa: std.mem.Allocator) void {
        const data = @constCast(v.*);
        data.arena.deinit();
        gpa.destroy(data);
    }
};

/// 调用泛型函数 `root` 可能使用的名字：函数名，以及 `files` 中指向它的容器级别名
/// （`const biggest = lib.max;`，含别名的别名）。只检查文件索引中出现这些名字的文件
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

/// 先用成员摘要粗筛，避免为不相关的成员生成 Body
fn mayMentionAny(r: *Resolver, f: FileId, item: u32, names: []const []const u8) resolve.Error!bool {
    for (names) |n| if (try r.mayMention(f, item, n)) return true;
    return false;
}

fn mentionsAny(body: *const Body, names: []const []const u8) bool {
    for (names) |n| if (search.mentions(body, n)) return true;
    return false;
}

/// 调用者 `i`（位于 `in`，见 `Callers`）中第一个能求出具体实例的对泛型函数 `root_key` 的调用
fn findIn(r: *Resolver, in: FileId, i: u32, file: FileId, item: u32, root_key: hir.OwnerKey, names: []const []const u8, depth: u8, strict: bool) resolve.Error!?Found {
    const owner = try r.ownerKey(in, i);
    const body = try r.ctx.get(hir.ItemBody, owner);
    const res = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full });
    if (try callIn(r, in, i, body, res, file, item, root_key, null, strict)) |s| return s;
    if (try loopCall(r, in, i, owner, body, res, null, names, file, item, root_key, null, strict)) |s| return s;
    // 调用者自身位于泛型函数内（如按枚举分派到各个泛型实现的 `run(op, dst: anytype, ...)`）：
    // 实参是抽象的，改用调用者的调用点实例推导后再找；调用者的实例取自少一层的查找
    if (depth == 0 or try genericRoot(r, in, i) == null) return null;
    if (!mayCall(r.ctx.db.env.ip, body, res, root_key)) return null;
    const outer = try r.ctx.get(Query, .{ .owner = owner, .depth = depth - 1 }) orelse return null;
    const seeded = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full, .inst = outer.inst });
    if (try callIn(r, in, i, body, seeded, file, item, root_key, null, strict)) |s| return s;
    if (try loopCall(r, in, i, owner, body, seeded, outer.inst, names, file, item, root_key, null, strict)) |s| return s;
    // 第一个实例下没有有效的调用（如调用位于该实例不执行的 `switch (Q.kind)` 分支中）：依次尝试调用者的其他实例
    for (try r.ctx.get(Instances, .{ .owner = owner, .depth = depth - 1 })) |other| {
        if (other.inst == outer.inst) continue;
        const res3 = try r.ctx.get(queries.Infer, .{ .owner = owner, .mode = .full, .inst = other.inst });
        if (try callIn(r, in, i, body, res3, file, item, root_key, null, strict)) |s| return s;
        if (try loopCall(r, in, i, owner, body, res3, other.inst, names, file, item, root_key, null, strict)) |s| return s;
    }
    return null;
}

/// 成员 `i`（位于 `in`）按推导结果 `res` 中第一个能求出具体实例的对 `root_key` 的调用。函数作为值与实参元组
/// 一起传入另一个调用（`Thread.spawn(.{}, f, .{ a, b })`、`@call(.auto, f, .{ a, b })`）也算作以元组元素调用。
/// `all` 不为 null 时把全部调用的实例（去重）加入其中，返回 null
fn callIn(r: *Resolver, in: FileId, i: u32, body: *const Body, res: *const infer.Result, file: FileId, item: u32, root_key: hir.OwnerKey, all: ?*Collector, strict: bool) resolve.Error!?Found {
    if (res.exprs.len != body.exprs.len) return null;
    for (body.exprs, 0..) |e, ei| {
        switch (e) {
            .call, .builtin_call => {},
            else => continue,
        }
        // `strict` 时调用者在该实例下不编译的代码中的调用（如 `switch (Q.kind)` 的其他分支）不产生实例；
        // 严格查找什么都找不到时（调用都位于项目中任何实例都不编译的分支中）才放宽，以便仍有实例可用
        if (strict and withinInactive(body, res, @fromBackingInt(@as(u32, @intCast(ei))))) continue;
        const site: Site = .{ .r = r, .in = in, .i = i, .body = body, .res = res, .expr = @intCast(ei), .file = file, .item = item, .root_key = root_key, .all = all };
        switch (e) {
            .call => |c| {
                // 方法调用：接收者是第一个实参
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

/// 推导结果 `res` 中是否可能有对 `root_key` 的调用：被调表达式，或随元组一起传入的函数实参（见 `Site.passed`）
/// 的值不是已知的其他函数或其他值。抽象推导中已经求出的值在调用者的各个实例下相同（未知的条件不选分支），
/// 全部排除时取调用者的实例也找不到调用，不必再查找调用者的调用点
fn mayCall(ip: *InternPool, body: *const Body, res: *const infer.Result, root_key: hir.OwnerKey) bool {
    if (res.exprs.len != body.exprs.len) return true;
    for (body.exprs) |e| switch (e) {
        .call => |c| if (mayBe(ip, res.exprs[@backingInt(c.callee)], root_key) or mayPass(ip, body, res, c.args, root_key)) return true,
        .builtin_call => |b| if (mayPass(ip, body, res, b.args, root_key)) return true,
        else => {},
    };
    return false;
}

/// 同 `Site.passed`：后面紧跟匿名元组字面量的实参
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

/// 值 `tv` 在某个实例下可能是函数 `root_key`：值未知或含抽象部分，或者就是它
fn mayBe(ip: *InternPool, tv: TypedValue, root_key: hir.OwnerKey) bool {
    const v = tv.val orelse return true;
    if (!value.isConcrete(ip, v)) return true;
    return switch (ip.key(v)) {
        .fn_value => |f| f.file == root_key.file and f.decl == root_key.item,
        else => false,
    };
}

/// `callIn` 中的一个调用表达式
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

    /// 实参中的函数值后面紧跟着匿名元组字面量：以元组元素调用该函数
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

    /// 以 `callee`（及接收者）和实参 `args` 调用：callee 为 `root_key` 且实例具体时返回调用点
    fn instance(s: Site, callee: TypedValue, receiver: ?TypedValue, args: []const Body.ExprId) resolve.Error!?Found {
        const r = s.r;
        const inst = (try calleeInstance(r, s.res, callee, receiver, args, s.root_key) orelse return null).inst;
        const site_owner = try r.ownerKey(s.in, s.i);
        const norm = try queries.normalizeInst(r, s.file, s.item, inst);
        if (s.all) |c| {
            try c.add(r.arena, .{ .inst = norm, .owner = site_owner, .expr = @fromBackingInt(s.expr) });
            return null;
        }
        return .{ .inst = norm, .owner = site_owner, .expr = @fromBackingInt(s.expr) };
    }
};

/// 调用的被调泛型函数与具体实例：callee 是泛型函数的值、由实参（及接收者）求出的实例具体时。`only` 不为 null
/// 时只看对它的调用（求实例之前先比较被调函数）
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

/// 包含成员 `item` 的最内层泛型函数（成员自身，或经由体内定义的容器的外层函数）
fn genericRoot(r: *Resolver, file: FileId, item: u32) resolve.Error!?u32 {
    const tree = try r.itemTree(file);
    var cur: ?u32 = item;
    while (cur) |it| : (cur = tree.containers[tree.items[it].container].parent_item) {
        if (tree.items[it].kind == .@"fn" and try isGeneric(r, file, it)) return it;
    }
    return null;
}

/// 有 comptime（含隐式的）或 anytype 参数，或返回 comptime-only 类型的函数
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

/// 类型中含抽象参数或未知部分：值得以调用点的实例重新推导
pub fn wanted(ip: *InternPool, tv: TypedValue) bool {
    if (tv.ty == .unknown or !value.isConcrete(ip, tv.ty)) return true;
    if (tv.ty == .type_type) return tv.val == null or !value.isConcrete(ip, tv.val.?);
    return false;
}
