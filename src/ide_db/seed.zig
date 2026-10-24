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
    stage_ends: [3]usize = @splat(0),
    loop_regions: ?[]const LoopRegion = null,

    /// 按迭代推导的区域：`for` 循环体，或 `inline` switch 分支（`prong` 为分支下标）的分支体
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
        // 每个位置独立经过相同层级；之前的位置预热了更深的候选也不改变选择顺序。
        for (0..3) |stage| {
            if (f.loaded <= stage) {
                switch (stage) {
                    0 => if (try f.r.ctx.get(Query, .{ .owner = f.owner, .depth = max_depth })) |found| try f.add(found),
                    1 => for (try f.r.ctx.get(Instances, .{ .owner = f.owner, .depth = max_depth })) |found| try f.add(found),
                    // 全部实例：只在某些实例中执行的分支（`switch (@typeInfo(T))` 的各分支）由它们细化
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
        // 只选择包含此位置的最内层异构循环；同一循环的其他捕获由 Infer 一并细化。
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
                    const n = try prongIterations(ip, f.body, res, sw, pi) orelse break :prong empty;
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

/// `inline` switch 分支（`sw` 的第 `pi` 个）按取值推导的次数：操作数不是 union 与错误集、捕获在推导中没有值
/// 时为分支项展开后的取值个数（见 `infer.inlineProngValues`）
fn prongIterations(ip: *InternPool, body: *const Body, res: *const infer.Result, sw: @FieldType(Body.Expr, "switch"), pi: u32) resolve.Error!?u32 {
    const prong = sw.prongs[pi];
    if (!prong.is_inline or prong.capture.len == 0 or res.exprs.len != body.exprs.len) return null;
    const cap = prong.capture[0];
    if (@backingInt(cap) >= res.bindings.len or res.bindings[@backingInt(cap)].val != null or body.binding(cap).is_ptr) return null;
    const operand = res.exprs[@backingInt(sw.operand)].ty;
    switch (ip.key(operand)) {
        .container_type => |c| if (c.kind == .@"union") return null,
        .reified_type => |rt| if (rt.kind == .@"union") return null,
        .error_set_type, .inferred_error_set => return null,
        else => {},
    }
    const n = (try infer.inlineProngValues(ip, body, res.exprs, prong, operand, null)).count orelse return null;
    return if (n > 0) n else null;
}

/// 循环 `l` 的第 `k` 个循环变量需要按迭代推导时的迭代次数：遍历 comptime 已知的类型列表
/// （`inline for`，或 comptime 中的 `for`；循环变量在推导中是抽象的类型），遍历 comptime 已知的值列表
/// （循环变量有类型但没有值），或遍历各项类型不同的元组（`inline for (.{ &posix, &windows }) |cases|`；
/// 循环变量的类型求不出）
fn iterations(r: *Resolver, res: *const infer.Result, l: Body.Loop, k: usize) resolve.Error!?u32 {
    if (k >= l.inputs.len or k >= l.capture.len) return null;
    const ip = r.ctx.db.env.ip;
    const cap = l.capture[k];
    if (@backingInt(cap) >= res.bindings.len or @backingInt(l.inputs[k]) >= res.exprs.len) return null;
    const list = res.exprs[@backingInt(l.inputs[k])];
    const binding = res.bindings[@backingInt(cap)];
    const by_value = if (binding.val) |v| ip.key(v) == .opaque_param else binding.ty != .unknown and list.val != null;
    if (by_value) {
        var n: u32 = 0;
        while (try eval.elemValue(r, list, n) != null) n += 1;
        return if (n > 0) n else null;
    }
    if (binding.ty != .unknown) return null;
    const tt = infer.tupleOf(ip, list.ty) orelse return null;
    if (tt.types.len == 0) return null;
    return @intCast(tt.types.len);
}

/// 成员 `i`（位于 `in`）中每次迭代的循环变量类型不同的循环（见 `iterations`）与 `inline` switch 分支（见
/// `prongIterations`）内提到 `names` 的调用：实参求不出具体的实例；按各次迭代推导（实例 `inst` 下的结果为
/// `res`）再找。`all` 不为 null 时收集
fn loopCall(r: *Resolver, in: FileId, i: u32, owner: hir.OwnerKey, body: *const Body, res: *const infer.Result, inst: ?Index, names: []const []const u8, file: FileId, item: u32, root_key: hir.OwnerKey, all: ?*Collector, strict: bool) resolve.Error!?Found {
    if (res.exprs.len != body.exprs.len) return null;
    const ip = r.ctx.db.env.ip;
    for (body.exprs) |e| {
        const l = switch (e) {
            .loop => |l| l,
            .@"switch" => |sw| {
                for (sw.prongs, 0..) |prong, pi| {
                    if (!prong.is_inline or !mentionsWithin(body, prong.body, names)) continue;
                    const n = try prongIterations(ip, body, res, sw, @intCast(pi)) orelse continue;
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
    // 类型为 noreturn：这个实例或这次迭代执行不到此处之后（如 `const T = switch (x) { .none => continue, ... }`）
    return !wanted(ip, tv) and tv.ty != .enum_literal_type and tv.ty != .noreturn_type;
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

/// 成员在各调用点的前 `max_seeds` 个不同实例（按查找顺序，去重）：第一个实例不适用时（光标处的代码不执行、
/// 表达式求不出类型、调用位于该实例不执行的分支中）依次尝试。调用者自身位于泛型函数内时取调用者的实例（层数
/// 少一层）。与 `Query` 一样，严格查找没有结果时放宽。需要覆盖全部实例时用 `AllInstances`
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

/// 成员 `item`（位于某个泛型函数内）在项目中的全部具体实例（见 `AllInstances`）。用于需要覆盖所有实例的场合
/// （引用查找与重命名）：`complete` 为 false 时可能还有其他实例
pub fn allInstances(r: *Resolver, file: FileId, item: u32) resolve.Error!struct { insts: []const Index, complete: bool } {
    if (!r.ctx.db.env.callsite_seeding.load(.monotonic)) return .{ .insts = &.{}, .complete = true };
    const root = try genericRoot(r, file, item) orelse return .{ .insts = &.{}, .complete = true };
    const all = try r.ctx.get(AllInstances, try r.ownerKey(file, root));
    const insts = try r.arena.alloc(Index, all.found.len);
    for (all.found, insts) |f, *inst| inst.* = (try queries.normalizeInst(r, file, item, f.inst.?)).?;
    return .{ .insts = insts, .complete = all.complete };
}

/// 泛型函数（`root`）的调用者，按顺序：各调用者在泛型函数之外推导时直接给出的实例；位于其他泛型函数中的调用者
/// 另记下那个函数（`from`），闭包按它的每个实例推导（见 `CallsIn`）。最后是类型流给出的实例（`flow_start` 起）。
/// 只取决于目标函数、`strict` 与 `target`，各个目标的闭包共享。`target` 不为 null 时（目标函数位于不导入
/// `target` 的文件中，见 `Closure.importers`）只取能传入通向 `target` 的实参的调用者：导入了 `target` 的文件中的
/// 调用者与泛型函数中的调用者
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
                // 不导入目标所在文件的文件中，泛型函数之外的代码不能指名目标的类型，不会调用目标；同样也不能传入
                // 通向 `target` 的实参
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

/// 调用者 `owner` 在实例 `inst` 下对泛型函数 `target` 的调用给出的实例（含循环中按各次迭代推导的调用）。
/// 各个目标的闭包共享
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

/// 成员 `owner` 的全部实例的调用点（见 `AllInstances`），实例按成员规范化
fn allFound(r: *Resolver, owner: hir.OwnerKey) resolve.Error![]const Found {
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

/// 闭包中实例的实参嵌套深度上限：能通过编译的代码实例化的集合是有限的，实参类型随递归越嵌越深（`grow(?T)`）
/// 是实例化无限增长，超过时截断
const max_closure_depth = 64;
/// 闭包中实例的总数上限：实参不变深、个数无限增长（comptime 整数随递归增大）同样只出现在不能编译的代码中。
/// 带大量测试的项目（每个测试类型经数十层泛型函数传播）的实例数可达数万，上限须远高于它
const max_closure = 1 << 18;
/// 闭包中类型流的层数上限（见 `typeFlow`；进入过的实例不再进入，层数只用于实例化无限增长的代码）
const max_closure_flow_depth = 64;

/// 泛型函数（key）在项目中的全部具体实例，按发现的顺序：从泛型函数之外的调用（以及类型流、std 中的分派处）出发，
/// 沿泛型调用者的每个实例中对它的调用求闭包，直到不再出现新的实例。实例化无限增长而截断时 `complete` 为 false
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

/// `AllInstances` 的计算：参与的泛型函数（目标及其泛型调用者，逐层向上）各自的实例集合，以工作队列传播到不动点
const Closure = struct {
    r: *Resolver,
    /// 能经由 `@import` 链到达目标所在文件的文件：其中的泛型函数的实例都参与传播；其余文件中的泛型函数不能
    /// 指名目标的类型，只有实例实参通向这些文件中定义的类型时（见 `reaches`）才可能调用目标
    importers: std.AutoHashMapUnmanaged(FileId, void) = .empty,
    target_file: FileId = undefined,
    reach_memo: std.AutoHashMapUnmanaged(Index, bool) = .empty,
    roots: std.ArrayList(Root) = .empty,
    /// 待扫描（求调用者）的泛型函数
    unscanned: std.ArrayList(usize) = .empty,
    /// 新发现、还未传播的实例：泛型函数与 `found` 下标
    queue: std.ArrayList(struct { root: usize, index: usize }) = .empty,
    total: usize = 0,
    complete: bool = true,

    const Root = struct {
        key: hir.OwnerKey,
        file: FileId,
        item: u32,
        found: Collector,
        /// 位于泛型函数 `from` 中的调用者（`in` 中的成员 `i`）：`from` 的每个实例下推导调用者，找对本函数的调用
        callers: std.ArrayList(Edge) = .empty,
        /// 本函数的实例下需要推导的调用者：泛型函数 `to` 的 `callers` 下标
        outs: std.ArrayList(struct { to: usize, edge: usize }) = .empty,
        scanned: bool = false,
        dispatch_tried: bool = false,
        /// 位于不导入目标所在文件的文件中：只保留实参通向目标的实例
        filtered: bool,
        /// 找到过实例（含被过滤的）：没有时才取分派处、放宽严格查找，与不过滤时相同
        seen: bool = false,
    };
    const Edge = struct { in: FileId, i: u32, from: usize };

    /// 类型或值 `x` 能否通向 `importers` 中定义的类型：容器定义在其中，或是实参通向它们的实例；指针、数组、
    /// 元组、函数类型等看其组成部分。求不出的值、抽象参数与未列出的种类按能通向
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
            .simple_type, .int_type, .error_set_type, .simple_value, .int_value, .float_value, .enum_literal, .error_value, .runtime => false,
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

    /// 泛型函数 `key` 在 `roots` 中的下标，首次出现时加入（待扫描）
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
            // 不动点：没有实例的函数先取 std 中的分派处，仍然没有的放宽严格查找（见 `callIn`）
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

    /// 泛型函数 `g` 的调用者（见 `RootCallers`）：直接给出的实例加入，位于其他泛型函数中的登记为依赖于那个函数
    /// 的实例，并以那个函数已有的实例推导
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

    /// 放宽之后重新扫描：已登记的泛型调用者会重新登记，先清除
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

    /// 泛型调用者 `g.callers[edge]` 在其所在函数的第 `k` 个实例下对 `g` 的调用（见 `CallsIn`）
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

    /// `g` 从 `before` 起新加入的实例排队传播；总数超过上限时不再传播
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

/// 类型或值 `x` 的嵌套深度（实例的实参、指针与可选的子类型、聚合的元素等逐层）超过 `limit`
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

/// 收集的实例：按实例去重，至多 `limit` 个
const Collector = struct {
    found: std.ArrayList(Found) = .empty,
    limit: usize,
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
    _ = try typeFlow(r, key.file, item, root, files, max_depth, out, out.strict, null);
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
    for (try r.ctx.get(Instances, .{ .owner = owner, .depth = depth - 1 })) |o| {
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
    if (try typeFlow(r, key.file, item, root, files, depth, null, strict, null)) |s| return s;
    return dispatched(r, key.file, item, root);
}

/// 目标所在的容器作为 comptime 类型实参传入泛型函数，再经类型参数调用目标（`ctx.get(hir.ItemBody, k)` →
/// `get` → … → `execute` 中的 `Q.compute(ctx, key)`）。分派处所在的文件不必 import 目标所在的文件，按导入链
/// 找不到：从实参中传入这个容器类型的调用出发，逐层进入实参中仍含有它的泛型调用，直到调用目标处。
/// `all` 不为 null 时收集全部这样找到的实例，返回 null
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

/// `typeFlow` 的一次查找：已进入过的实例不再进入（互相调用的泛型函数）
const Flow = struct {
    r: *Resolver,
    target: Index,
    file: FileId,
    item: u32,
    root_key: hir.OwnerKey,
    all: ?*Collector,
    strict: bool,
    /// 不为 null 时，层数用完而不再进入时置为 true
    cut: ?*bool,
    visited: std.ArrayList(Index) = .empty,

    fn full(fl: *const Flow) bool {
        const c = fl.all orelse return false;
        return c.full();
    }

    /// 推导结果 `res` 中实参含有目标容器类型的泛型调用：在被调函数的该实例中找对目标的调用
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

/// 泛型函数 `root` 的调用点查找在文件 `in` 中要推导的调用者（成员下标，按顺序）：提到函数名或别名、且不能静态
/// 排除（见 `mentionsOnlyOthers`）的成员，不含函数自身及其体内的成员。与层数、严格与否、是否收集全部实例无关：
/// 各层的 `Query` 与 `Instances` 共享，不必每次重新扫描文件。按文件缓存：找到调用点即停止的查找不扫描其余文件
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

/// 各层种子查找共享与目标函数有关的导入候选和别名闭包，不缓存任何展示位置。
pub const Candidates = struct {
    pub const kind: engine.Kind = .derived;
    pub const Key = hir.OwnerKey;
    pub const Value = *const Data;

    pub const Data = struct {
        arena: std.heap.ArenaAllocator,
        /// 能经由 `@import` 链到达目标所在文件的项目文件：第一个实例与前几个实例的查找按它们的顺序，先找到的
        /// 实例在前
        files: []const FileId,
        /// `files` 之后是项目中的其余文件（见 `search.candidateFiles`）：全部实例的闭包不遗漏泛型代码中经
        /// `anytype` 的值或 comptime 类型参数的调用
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
        for (try search.projectFiles(&r)) |f| try all.put(r.arena, f, {});
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

/// 成员 `i`（位于 `in`）提到 `names` 的每一处都不经推导就能确定指向 `root_key` 之外的函数声明：它不调用
/// `root_key`，不必推导（推导提到常见名字的成员，如 `print`、`init`，是调用点查找的主要开销）。
/// 求不出、指向别名或字段（其值可能是目标）、枚举字面量（decl literal 可能调用目标）、初始化的字段名时为 false
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

/// 不经推导就能确定的 `e`（名字或成员访问）指向的声明：名字按词法作用域解析；成员访问的左侧是命名空间，或是
/// 类型已知的值（见 `staticValueType`），在类型的命名空间中查找成员。求不出时为 null
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

/// 不经推导函数体就能确定的值 `e` 的类型（单项指针取指向的类型）：全局声明的值取声明的类型，当前成员的参数取
/// 签名中的类型。求不出、是类型或抽象时为 null
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
pub fn genericRoot(r: *Resolver, file: FileId, item: u32) resolve.Error!?u32 {
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
