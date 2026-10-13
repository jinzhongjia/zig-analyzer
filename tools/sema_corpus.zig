//! 在标准库上运行类型推导：每个成员做完整推导（检验不崩溃），统计类型已知的比例与耗时。
//!
//! 用法：zig build sema-corpus [-- <std 目录>]
//!
//! 标准库的全部文件都归入 std 模块（`@import("std")` 可解析，`builtin` 与 `root` 不可解析）。
//! 依赖 comptime 求值的部分（泛型类型构造、依赖 comptime 参数的返回类型）属于 M5，计入未知。

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
        g.* = .{ .arena = arena.state, .std_root = std_root, .modules = root_module, .files = entries };
        db.beginWrite();
        defer db.endWrite();
        try db.set(ModuleGraph.Input, {}, g, .high);
    }

    var locals: Counts = .{};
    var decls: Counts = .{};
    var exprs: Counts = .{};
    var members: usize = 0;
    const t0 = std.Io.Clock.awake.now(io);
    for (files.items) |file| {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
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
                // 只统计有值的表达式（不含语句级的控制流与类型表达式）
                .name_ref, .field_access, .call, .builtin_call, .literal, .index, .slice, .deref, .unwrap_optional, .prefix, .binary, .@"catch", .init => exprs.add(tv.ty),
                else => {},
            };
        }
    }
    const secs = @as(f64, @floatFromInt(t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds)) / std.time.ns_per_s;
    std.debug.print(
        \\files: {d}, members: {d}, time {d:.2}s
        \\declarations with known type: {d}/{d} ({d:.1}%)
        \\local variables with known type: {d}/{d} ({d:.1}%)
        \\expressions with known type: {d}/{d} ({d:.1}%)
        \\
    , .{ files.items.len, members, secs, decls.known, decls.total, decls.pct(), locals.known, locals.total, locals.pct(), exprs.known, exprs.total, exprs.pct() });
    return 0;
}
