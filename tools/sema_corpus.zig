//! 在标准库上运行类型推导：每个成员做完整推导（检验不崩溃），统计类型已知的比例与耗时。
//!
//! 用法：zig build sema-corpus [-- <std 目录>]
//!
//! 标准库的全部文件都归入 std 模块：`@import("std")` 可解析，`builtin` 为本机目标、Debug、`zig test`
//! 的 builtin.zig（需要 PATH 中的 zig），`root` 不可解析。
//! 依赖 comptime 求值的部分（泛型类型构造、依赖 comptime 参数的返回类型）属于 M5，计入未知。
//! 每个文件之后与服务器一样按需淘汰缓存（§6.6），结果须与不淘汰时相同。

const std = @import("std");
const za = @import("zig_analyzer");
const database = za.database;
const Vfs = za.base.Vfs;
const FileId = Vfs.FileId;
const InternPool = za.sema.InternPool;
const ModuleGraph = za.names.ModuleGraph;
const queries = za.sema.queries;

const Counts = struct {
    known: usize = 0,
    total: usize = 0,

    fn add(c: *Counts, t: InternPool.Index) void {
        c.total += 1;
        if (t != .unknown) c.known += 1;
    }

    fn pct(c: Counts) f64 {
        return if (c.total == 0) 0 else 100 * @as(f64, @floatFromInt(c.known)) / @as(f64, @floatFromInt(c.total));
    }
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: {s} <std dir>\n", .{args[0]});
        return 2;
    }
    const std_dir = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], gpa);
    defer gpa.free(std_dir);

    var vfs: Vfs = .init(io, gpa);
    defer vfs.deinit();
    var ip: InternPool = try .init(gpa, io);
    defer ip.deinit();
    var env: database.Env = .{ .vfs = &vfs, .ip = &ip };
    var db: database.Db = .init(io, gpa, &env);
    defer db.deinit();

    // 收集文件，全部归入 std 模块
    var files: std.ArrayList(FileId) = .empty;
    defer files.deinit(gpa);
    {
        var dir = try std.Io.Dir.cwd().openDir(io, std_dir, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            const path = try std.fs.path.join(gpa, &.{ std_dir, entry.path });
            defer gpa.free(path);
            try files.append(gpa, try vfs.intern(path));
        }
    }
    const std_root_path = try std.fs.path.join(gpa, &.{ std_dir, "std.zig" });
    defer gpa.free(std_root_path);
    const std_root = try vfs.intern(std_root_path);
    // `@import("builtin")`：本机目标、Debug、`zig test`（需要 PATH 中的 zig）
    const default_builtin: ?FileId = blk: {
        var zig_env = za.project.ZigEnv.query(gpa, io, null) catch break :blk null;
        defer zig_env.deinit(gpa);
        const path = try za.project.builtin.generate(gpa, io, &zig_env, &.{"test"}) orelse break :blk null;
        defer gpa.free(path);
        break :blk try vfs.intern(path);
    };
    {
        const g = try gpa.create(ModuleGraph);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        const entries = try arena.allocator().alloc(ModuleGraph.FileEntry, files.items.len);
        for (files.items, entries) |f, *e| e.* = .{ .file = f, .module = ModuleGraph.std_module, .root_module = 0 };
        std.mem.sort(ModuleGraph.FileEntry, entries, {}, struct {
            fn lt(_: void, a: ModuleGraph.FileEntry, b: ModuleGraph.FileEntry) bool {
                return @backingInt(a.file) < @backingInt(b.file);
            }
        }.lt);
        const root_module = try arena.allocator().dupe(ModuleGraph.Module, &.{.{ .root = std_root, .imports = &.{} }});
        g.* = .{ .arena = arena.state, .std_root = std_root, .modules = root_module, .files = entries, .default_builtin = default_builtin };
        db.beginWrite();
        defer db.endWrite();
        try db.set(ModuleGraph.Input, {}, g, .high);
    }

    // 查找引用（冷缓存）：标准库中常用的声明
    const ref_targets = [_][2][]const u8{ .{ "mem.zig", "Allocator" }, .{ "mem.zig", "eql" }, .{ "std.zig", "ArrayList" } };
    for (ref_targets) |target| {
        const path = try std.fs.path.join(gpa, &.{ std_dir, target[0] });
        defer gpa.free(path);
        try findRefs(gpa, io, &db, files.items, try vfs.intern(path), target[1]);
    }
    // 淘汰解析结果后再查一次（函数体仍在缓存中）：不应重新解析
    {
        _ = db.trySweep();
        var counts_before: [database.Db.query_types.len]u64 = undefined;
        _ = db.stats(&counts_before);
        const before = db.executions[database.Db.queryIndex(database.syntax.ParseFile)].load(.monotonic);
        for (ref_targets) |target| {
            const path = try std.fs.path.join(gpa, &.{ std_dir, target[0] });
            defer gpa.free(path);
            try findRefs(gpa, io, &db, files.items, try vfs.intern(path), target[1]);
        }
        std.debug.print("files re-parsed by references after evicting parses: {d}\n", .{db.executions[database.Db.queryIndex(database.syntax.ParseFile)].load(.monotonic) - before});
        var counts_after: [database.Db.query_types.len]u64 = undefined;
        _ = db.stats(&counts_after);
        inline for (database.Db.query_types, 0..) |Q, qi| if (counts_after[qi] != counts_before[qi]) std.debug.print("  {s}: +{d}\n", .{ @typeName(Q), counts_after[qi] - counts_before[qi] });
    }

    var locals: Counts = .{};
    var decls: Counts = .{};
    var exprs: Counts = .{};
    var members: usize = 0;
    var sweeps: usize = 0;
    const t0 = std.Io.Clock.awake.now(io);
    for (files.items) |file| {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        {
            var ctx = db.beginRead(scratch.allocator());
            defer ctx.end();
            const tree = try ctx.get(database.syntax.FileItemTree, file);
            for (tree.items) |item| {
                const owner: database.hir.OwnerKey = .{ .file = file, .item = item.ast_id };
                members += 1;
                const decl = try ctx.get(queries.DeclType, .{ .owner = owner });
                switch (item.kind) {
                    .@"const", .@"var", .@"fn" => decls.add(decl.ty),
                    else => {},
                }
                const res = try ctx.get(queries.Infer, .{ .owner = owner, .mode = .full });
                const body = try ctx.get(database.hir.ItemBody, owner);
                for (body.bindings, res.bindings) |b, tv| if (b.kind == .local_const or b.kind == .local_var) locals.add(tv.ty);
                for (body.exprs, res.exprs) |e, tv| switch (e) {
                    // 只统计有值的表达式（不含语句级的控制流与类型表达式）；`_ = x;` 的 `_` 是丢弃，不是值
                    .name_ref => |n| if (!std.mem.eql(u8, n, "_")) exprs.add(tv.ty),
                    .field_access, .call, .builtin_call, .literal, .index, .slice, .deref, .unwrap_optional, .prefix, .binary, .@"catch", .init => exprs.add(tv.ty),
                    else => {},
                };
            }
        }
        // 与服务器相同：读事务结束后按需淘汰（同时检验淘汰后恢复的结果与从未淘汰时一致）
        if (db.wantsSweep()) {
            _ = db.trySweep();
            sweeps += 1;
        }
    }
    // 再次查找引用：期间大部分解析结果已被淘汰，引用查找不应因此重新解析
    const parses_before = db.executions[database.Db.queryIndex(database.syntax.ParseFile)].load(.monotonic);
    for (ref_targets) |target| {
        const path = try std.fs.path.join(gpa, &.{ std_dir, target[0] });
        defer gpa.free(path);
        try findRefs(gpa, io, &db, files.items, try vfs.intern(path), target[1]);
    }
    std.debug.print("files re-parsed by references after eviction: {d}\n", .{db.executions[database.Db.queryIndex(database.syntax.ParseFile)].load(.monotonic) - parses_before});
    const secs = @as(f64, @floatFromInt(t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds)) / std.time.ns_per_s;
    std.debug.print(
        \\files: {d}, members: {d}, time {d:.2}s, sweeps {d}
        \\declarations with known type: {d}/{d} ({d:.1}%)
        \\local variables with known type: {d}/{d} ({d:.1}%)
        \\expressions with known type: {d}/{d} ({d:.1}%)
        \\
    , .{ files.items.len, members, secs, sweeps, decls.known, decls.total, decls.pct(), locals.known, locals.total, locals.pct(), exprs.known, exprs.total, exprs.pct() });
    return 0;
}

/// 统计 `file` 顶层声明 `name` 的引用数与耗时
fn findRefs(gpa: std.mem.Allocator, io: std.Io, db: *database.Db, files: []const FileId, file: FileId, name: []const u8) !void {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var ctx = db.beginRead(scratch.allocator());
    defer ctx.end();
    var r: za.names.resolve.Resolver = .{ .ctx = &ctx, .arena = scratch.allocator() };
    const tree = try r.itemTree(file);
    const item = za.names.resolve.Resolver.lookupDecl(tree, 0, name) orelse return;
    const t0 = std.Io.Clock.awake.now(io);
    const refs = try za.ide_db.search.findReferences(&r, .{ .item = .{ .file = file, .item = item } }, .{ .scope = files });
    const ms = @as(f64, @floatFromInt(t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds)) / std.time.ns_per_ms;
    std.debug.print("references of {s}: {d} in {d:.0}ms\n", .{ name, refs.len, ms });
}
