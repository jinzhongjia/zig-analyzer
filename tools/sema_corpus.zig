//! Runs type inference over the standard library: full inference for every member (checking that
//! nothing crashes), reporting the share of known types and the time taken.
//!
//! Usage: zig build sema-corpus [-- <std dir>]
//!
//! All standard library files belong to the std module: `@import("std")` resolves; `builtin` is
//! the builtin.zig for the native target, Debug, `zig test` (needs zig in PATH); `root` does not
//! resolve.
//! After each file, caches are evicted on demand as in the server; results must be the same as
//! without eviction.

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

    // Collect the files; all of them belong to the std module
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
    // `@import("builtin")`: native target, Debug, `zig test` (needs zig in PATH)
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

    // Find references (cold cache): commonly used declarations of the standard library
    const ref_targets = [_][2][]const u8{ .{ "mem.zig", "Allocator" }, .{ "mem.zig", "eql" }, .{ "std.zig", "ArrayList" } };
    for (ref_targets) |target| {
        const path = try std.fs.path.join(gpa, &.{ std_dir, target[0] });
        defer gpa.free(path);
        try findRefs(gpa, io, &db, files.items, try vfs.intern(path), target[1]);
    }
    // Search again after evicting the parse results (function bodies are still cached): files must
    // not be parsed again
    {
        _ = db.trySweep();
        const before = db.executions(database.syntax.ParseFile);
        for (ref_targets) |target| {
            const path = try std.fs.path.join(gpa, &.{ std_dir, target[0] });
            defer gpa.free(path);
            try findRefs(gpa, io, &db, files.items, try vfs.intern(path), target[1]);
        }
        std.debug.print("files re-parsed by references after evicting parses: {d}\n", .{db.executions(database.syntax.ParseFile) - before});
    }

    var locals: Counts = .{};
    var decls: Counts = .{};
    var exprs: Counts = .{};
    // Distribution of unknown expressions: inactive code, generic functions, members of containers
    // returned by generic functions (e.g. methods of `ArrayList(T)`), other
    var unknown: struct { inactive: usize = 0, generic: usize = 0, generic_member: usize = 0, other: usize = 0 } = .{};
    // Number of unknown expressions in generic code that get a type when inferred with the instance
    // from a call site in the same file (used by hover, completion, etc. in editors)
    var seeded: usize = 0;
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
            var r: za.names.resolve.Resolver = .{ .ctx = &ctx, .arena = scratch.allocator() };
            // Inactive code in the file (including members of containers defined in branches that
            // are not executed)
            const inactive_ranges = try za.ide.inactive.ranges(&r, file);
            for (tree.items, 0..) |item, item_index| {
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
                const generic = isGenericFn(item, body);
                const generic_member = try inGenericFn(&ctx, file, tree, item);
                const base = (try r.itemNode(file, @intCast(item_index))).?.offset;
                var seed: ?za.ide_db.seed.Seed = null;
                var seed_looked = false;
                for (body.exprs, res.exprs, 0..) |e, tv, ei| {
                    switch (e) {
                        // Count only expressions that have a value (not statement-level control
                        // flow or type expressions); the `_` in `_ = x;` is a discard, not a value
                        .name_ref => |n| if (std.mem.eql(u8, n, "_")) continue,
                        .field_access, .call, .builtin_call, .literal, .index, .slice, .deref, .unwrap_optional, .prefix, .binary, .@"catch", .init => {},
                        else => continue,
                    }
                    exprs.add(tv.ty);
                    if (tv.ty != .unknown) continue;
                    const range = body.expr_ranges[ei];
                    const inactive = for (inactive_ranges) |rr| {
                        if (rr.start <= base + range.start and base + range.end <= rr.end) break true;
                    } else false;
                    if (inactive) unknown.inactive += 1 else if (generic) unknown.generic += 1 else if (generic_member) unknown.generic_member += 1 else unknown.other += 1;
                    if (!inactive and (generic or generic_member)) {
                        if (!seed_looked) {
                            seed = try za.ide_db.seed.find(&r, file, @intCast(item_index));
                            seed_looked = true;
                        }
                        if (seed) |sd| if (ei < sd.res.exprs.len and sd.res.exprs[ei].ty != .unknown) {
                            seeded += 1;
                        };
                    }
                }
            }
        }
        // As in the server: evict on demand after the read transaction ends (which also checks that
        // results restored after eviction match those that were never evicted)
        if (db.wantsSweep()) {
            _ = db.trySweep();
            sweeps += 1;
        }
    }
    // Find references again: most parse results have been evicted in the meantime, and find
    // references must not reparse because of that
    const parses_before = db.executions(database.syntax.ParseFile);
    for (ref_targets) |target| {
        const path = try std.fs.path.join(gpa, &.{ std_dir, target[0] });
        defer gpa.free(path);
        try findRefs(gpa, io, &db, files.items, try vfs.intern(path), target[1]);
    }
    std.debug.print("files re-parsed by references after eviction: {d}\n", .{db.executions(database.syntax.ParseFile) - parses_before});
    const secs = @as(f64, @floatFromInt(t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds)) / std.time.ns_per_s;
    std.debug.print(
        \\files: {d}, members: {d}, time {d:.2}s, sweeps {d}
        \\declarations with known type: {d}/{d} ({d:.1}%)
        \\local variables with known type: {d}/{d} ({d:.1}%)
        \\expressions with known type: {d}/{d} ({d:.1}%)
        \\unknown expressions: {d} in inactive code, {d} in generic functions, {d} in members of types returned by generic functions, {d} elsewhere
        \\  of those in generic code, known when inferred from a call site in the same file: {d}
        \\
    , .{ files.items.len, members, secs, sweeps, decls.known, decls.total, decls.pct(), locals.known, locals.total, locals.pct(), exprs.known, exprs.total, exprs.pct(), unknown.inactive, unknown.generic, unknown.generic_member, unknown.other, seeded });
    // Time of each query, sorted by self time, to locate the most expensive parts of inference
    {
        var stats: [database.Db.query_types.len]za.db.QueryStats = undefined;
        _ = db.stats(&stats);
        var names: [database.Db.query_types.len][]const u8 = undefined;
        inline for (database.Db.query_types, &names) |Q, *n| n.* = @typeName(Q);
        var buf: [8192]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try za.db_report.writeTable(&w, &names, &stats, 12);
        std.debug.print("{s}", .{w.buffered()});
    }
    return 0;
}

/// Generic function: has a comptime (including an implicit `T: type`) or anytype parameter, or
/// returns `type`
fn isGenericFn(item: za.syntax.ItemTree.Item, body: *const za.hir.Body) bool {
    if (item.kind != .@"fn") return false;
    for (body.params) |p| {
        const b = body.binding(p);
        if (b.is_comptime or b.ty == null or isTypeName(body, b.ty.?)) return true;
    }
    return if (body.type_expr) |t| isTypeName(body, t) else false;
}

fn isTypeName(body: *const za.hir.Body, e: za.hir.Body.ExprId) bool {
    return switch (body.expr(e)) {
        .name_ref => |n| std.mem.eql(u8, n, "type"),
        else => false,
    };
}

/// The member is in a container returned (or defined) by a generic function
fn inGenericFn(ctx: *database.Db.Ctx, file: FileId, tree: *const za.syntax.ItemTree, item: za.syntax.ItemTree.Item) !bool {
    var parent = tree.containers[item.container].parent_item;
    while (parent) |pi| {
        const p = tree.items[pi];
        if (p.kind == .@"fn" and isGenericFn(p, try ctx.get(database.hir.ItemBody, .{ .file = file, .item = p.ast_id }))) return true;
        parent = tree.containers[p.container].parent_item;
    }
    return false;
}

/// Counts the references to the top-level declaration `name` of `file` and the time taken
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
