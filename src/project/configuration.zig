//! Converts the build graph (`std.Build.Configuration`) given by the build system protocol into a
//! `ProjectModel`.
//!
//! The binary format of the build graph is defined by the standard library and can be loaded only
//! when the user's zig is the same version as the one zig-analyzer was compiled with
//! (see `ZigEnv.matchesBuiltin`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Configuration = std.Build.Configuration;
const ProjectModel = @import("../base/ProjectModel.zig");
const ZigEnv = @import("ZigEnv.zig");

/// Reads the build graph file given by the maker (`path` is relative to the build root) and
/// converts it
pub fn load(gpa: Allocator, io: Io, build_root: []const u8, path: []const u8, env: *const ZigEnv) !ProjectModel {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var dir = try Io.Dir.cwd().openDir(io, build_root, .{});
    defer dir.close(io);
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const conf = try Configuration.loadFile(scratch.allocator(), io, file);
    return convert(gpa, &conf, build_root, try localCacheRoot(scratch.allocator(), build_root, path), env);
}

/// The local cache directory used by the maker (absolute path), derived from the path of the build
/// graph file `configuration_path` (relative to the build root, or absolute): the maker writes the
/// build graph to `c/<hash>` under the local cache directory (`tmp/<hex>` when no cache is used).
/// The local cache directory depends on `--cache-dir`, the environment variable
/// `ZIG_LOCAL_CACHE_DIR`, and the default `<build root>/.zig-cache`; inferring it from the path
/// the maker gives avoids duplicating the maker's rules for parsing arguments and environment
/// variables
pub fn localCacheRoot(a: Allocator, build_root: []const u8, configuration_path: []const u8) Allocator.Error![]u8 {
    const dir = std.fs.path.dirname(configuration_path) orelse "";
    return std.fs.path.resolveAlloc(a, &.{ build_root, std.fs.path.dirname(dir) orelse "" });
}

/// `local_cache_root` is the local cache directory used by the maker (absolute path; see
/// `localCacheRoot`)
pub fn convert(gpa: Allocator, c: *const Configuration, build_root: []const u8, local_cache_root: []const u8, env: *const ZigEnv) Allocator.Error!ProjectModel {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const a = arena_state.allocator();

    const ctx: Ctx = .{ .arena = a, .c = c, .build_root = try a.dupe(u8, build_root), .local_cache_root = try a.dupe(u8, local_cache_root), .env = env };

    // Modules are deduplicated by Configuration.Module.Index; indices follow discovery order
    var module_ids: std.AutoArrayHashMapUnmanaged(Configuration.Module.Index, void) = .empty;
    defer module_ids.deinit(gpa);

    const steps = try a.alloc(ProjectModel.Step, c.steps.len);
    for (c.steps, steps) |*src, *dst| {
        const ext = src.extended.get(c.extra);
        const deps = src.deps.slice(c);
        const dep_ids = try a.alloc(u32, deps.len);
        for (deps, dep_ids) |d, *out| out.* = @backingInt(d);
        dst.* = .{
            .name = try a.dupe(u8, src.name.slice(c)),
            .deps = dep_ids,
            .kind = switch (ext) {
                .top_level => |t| .{ .top_level = .{ .description = try a.dupe(u8, t.description.slice(c)) } },
                .compile => |comp| .{ .compile = .{ .root_module = try internModule(gpa, &module_ids, comp.root_module) } },
                else => .other,
            },
        };
    }

    // Discover all modules along the import tables (module_ids grows during the iteration)
    var modules: std.ArrayList(ProjectModel.Module) = .empty;
    var package_roots: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer package_roots.deinit(gpa);
    var i: usize = 0;
    while (i < module_ids.count()) : (i += 1) {
        const m = module_ids.keys()[i].get(c);
        const table = m.import_table.get(c).imports.mal;
        const imports = try a.alloc(ProjectModel.Import, table.len);
        for (table.items(.name), table.items(.module), imports) |name, target, *out| {
            out.* = .{ .name = try a.dupe(u8, name.slice(c)), .module = try internModule(gpa, &module_ids, target) };
        }
        const root = if (m.root_source_file.unwrap()) |lp| lp.get(c) else null;
        if (root) |lp| if (try ctx.fetchedPackageRoot(lp)) |p| try package_roots.put(gpa, p, {});
        try modules.append(a, .{
            .builtin_args = try builtinArgs(a, c, &m),
            .root_file = if (root) |lp| try ctx.resolve(lp) else null,
            .generated_root = if (root) |lp| switch (lp) {
                .generated => |g| .{ .file = @backingInt(g.index), .up = g.flags.up, .sub_path = try a.dupe(u8, g.sub_path.slice(c)) },
                else => null,
            } else null,
            .imports = imports,
        });
    }

    // The subcommand and compiler backend for builtin come from the compile step rooted at the
    // module (they determine output_mode / is_test / zig_backend); other modules use build-obj.
    // The same module is often the root of both an executable and a test, in which case the test
    // is used: `std.testing.allocator` and the like in test blocks depend on `builtin.is_test`
    const chosen = try a.alloc(?usize, modules.items.len);
    @memset(chosen, null);
    for (c.steps, 0..) |*src, si| switch (src.extended.get(c.extra)) {
        .compile => |comp| {
            const index = module_ids.getIndex(comp.root_module) orelse continue;
            if (chosen[index]) |prev| if (c.steps[prev].extended.get(c.extra).compile.flags3.kind.isTest() or !comp.flags3.kind.isTest()) continue;
            chosen[index] = si;
        },
        else => {},
    };
    for (chosen, modules.items) |step, *mod| {
        const comp = c.steps[step orelse continue].extended.get(c.extra).compile;
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, mod.builtin_args);
        args.items[0] = switch (comp.flags3.kind) {
            .exe => "build-exe",
            .lib => "build-lib",
            .obj => "build-obj",
            .@"test" => "test",
            .test_obj => "test-obj",
        };
        if (comp.flags3.kind == .test_obj) try args.append(a, "--test-no-exec");
        // The compiler backend determines `zig_backend` in builtin (vector layout depends on it)
        if (comp.flags2.use_llvm.toBool()) |on| try args.append(a, if (on) "-fllvm" else "-fno-llvm");
        mod.builtin_args = args.items;
    }

    const producers = try a.alloc(?u32, c.generated_files_len);
    @memset(producers, null);
    for (c.steps, 0..) |*step, si| {
        var v: ProducerVisitor = .{ .producers = producers, .step = @intCast(si) };
        walkGeneratedFiles(c, step, &v);
    }

    const std_root = try std.fs.path.join(a, &.{ env.std_dir, "std.zig" });
    const default_diag = for (steps, 0..) |s, si| {
        if (s.kind == .top_level and std.mem.eql(u8, s.name, "check")) break @as(u32, @intCast(si));
    } else @backingInt(c.default_step);
    const diagnostics_steps = try a.dupe(u32, &.{default_diag});
    const roots = try a.dupe([]const u8, package_roots.keys());
    // Nothing may be allocated after the arena state is copied into the result: new
    // buffers are not in the copied state and would leak when freed
    return .{
        .arena = arena_state.state,
        .build_root = ctx.build_root,
        .local_cache_root = ctx.local_cache_root,
        .package_roots = roots,
        .std_root = std_root,
        .steps = steps,
        .modules = modules.items,
        .default_step = @backingInt(c.default_step),
        .producers = producers,
        .diagnostics_steps = diagnostics_steps,
    };
}

const ProducerVisitor = struct {
    producers: []?u32,
    step: u32,

    fn visit(v: *ProducerVisitor, file: ?Configuration.GeneratedFileIndex) void {
        const i = @backingInt(file orelse return);
        if (i < v.producers.len) v.producers[i] = v.step;
    }
};

/// Enumerates the generated files a step produces (same traversal as the maker uses when
/// reporting `bsp_step_completed`)
fn walkGeneratedFiles(c: *const Configuration, step: *const Configuration.Step, v: *ProducerVisitor) void {
    switch (step.extended.get(c.extra)) {
        .check_file, .fail, .fmt, .install_artifact, .install_dir, .install_file, .top_level, .update_source_files => {},
        .compile => |compile| {
            v.visit(compile.emit_directory.value);
            v.visit(compile.generated_docs.value);
            v.visit(compile.generated_asm.value);
            v.visit(compile.generated_bin.value);
            v.visit(compile.generated_pdb.value);
            v.visit(compile.generated_implib.value);
            v.visit(compile.generated_llvm_bc.value);
            v.visit(compile.generated_llvm_ir.value);
            v.visit(compile.generated_h.value);
        },
        .config_header => |h| v.visit(h.generated_dir),
        .find_program => |f| v.visit(f.found_path),
        .obj_copy => |o| {
            v.visit(o.output_file);
            v.visit(o.debug_file.value);
        },
        .options => |o| v.visit(o.generated_file),
        .run => |run| {
            if (run.captured_stdout.value) |out| v.visit(out.generated_file);
            if (run.captured_stderr.value) |out| v.visit(out.generated_file);
            for (run.args.slice) |arg| v.visit(arg.get(c).generated.value);
        },
        .translate_c => |t| v.visit(t.output_file),
        .write_file => |w| v.visit(w.generated_directory),
    }
}

/// Converts a generated file path reported by the maker (prefix + sub path) to an absolute path
pub fn generatedPath(gpa: Allocator, model: *const ProjectModel, env: *const ZigEnv, prefix: std.zig.Server.Message.PathPrefix, sub_path: []const u8) Allocator.Error![]u8 {
    const base: []const u8 = switch (prefix) {
        // The maker's cwd is the build root
        .cwd, .build_root => model.build_root,
        .zig_lib => env.lib_dir,
        .global_cache => env.global_cache_dir,
        .local_cache => blk: {
            // Hand-written models in tests may leave the local cache directory unset; models from
            // `convert` always have an absolute path
            std.debug.assert(std.fs.path.isAbsolute(model.local_cache_root));
            break :blk model.local_cache_root;
        },
    };
    return std.fs.path.resolveAlloc(gpa, &.{ base, sub_path });
}

/// Module arguments that affect `builtin.zig`, written the same way the build system passes them
/// to the compiler (see appendModuleFlags in Maker/Step/Compile.zig)
fn builtinArgs(a: Allocator, c: *const Configuration, m: *const Configuration.Module) Allocator.Error![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(a, "build-obj");
    const flags = .{
        .{ "strip", m.flags.strip },
        .{ "single-threaded", m.flags.single_threaded },
        .{ "omit-frame-pointer", m.flags2.omit_frame_pointer },
        .{ "error-tracing", m.flags2.error_tracing },
        .{ "sanitize-thread", m.flags.sanitize_thread },
        .{ "fuzz", m.flags.fuzz },
        .{ "valgrind", m.flags2.valgrind },
        .{ "PIC", m.flags2.pic },
    };
    inline for (flags) |f| if (f[1].toBool()) |on| try args.append(a, if (on) "-f" ++ f[0] else "-fno-" ++ f[0]);
    switch (m.flags.unwind_tables) {
        .none => try args.append(a, "-fno-unwind-tables"),
        .sync => try args.append(a, "-funwind-tables"),
        .async => try args.append(a, "-fasync-unwind-tables"),
        .default => {},
    }
    switch (m.flags.optimize) {
        .debug => try args.append(a, "-Odebug"),
        .safe => try args.append(a, "-Osafe"),
        .fast => try args.append(a, "-Ofast"),
        .small => try args.append(a, "-Osmall"),
        .default => {},
    }
    if (m.flags.code_model != .default) try args.appendSlice(a, &.{ "-mcmodel", @tagName(m.flags.code_model) });
    if (m.resolved_target.get(c)) |rt| if (rt.unwrapQuery(c)) |query| {
        try args.appendSlice(a, &.{ "-target", try query.zigTriple(a), "-mcpu", try query.serializeCpuAlloc(a) });
    };
    if (m.flags2.link_libc == .true) try args.append(a, "-lc");
    if (m.flags2.link_libcpp == .true) try args.append(a, "-lc++");
    return args.items;
}

fn internModule(gpa: Allocator, ids: *std.AutoArrayHashMapUnmanaged(Configuration.Module.Index, void), m: Configuration.Module.Index) Allocator.Error!u32 {
    const gop = try ids.getOrPut(gpa, m);
    return @intCast(gop.index);
}

const Ctx = struct {
    arena: Allocator,
    c: *const Configuration,
    build_root: []const u8,
    local_cache_root: []const u8,
    env: *const ZigEnv,

    /// Resolves to an absolute path; returns null for paths that cannot be known before the
    /// build, such as generated files
    fn resolve(ctx: Ctx, lp: Configuration.LazyPath) Allocator.Error!?[]const u8 {
        const c = ctx.c;
        return switch (lp) {
            .source_path => |sp| blk: {
                const sub = sp.sub_path.slice(c);
                const package = sp.owner.get(c) orelse break :blk try ctx.join(ctx.build_root, sub);
                break :blk try ctx.join(try ctx.packageRoot(package), sub);
            },
            .relative => |rel| blk: {
                const base: []const u8 = switch (rel.flags.base) {
                    .cwd, .build_root => ctx.build_root,
                    .local_cache => ctx.local_cache_root,
                    .global_cache => ctx.env.global_cache_dir,
                    .zig_lib => ctx.env.lib_dir,
                    else => break :blk null,
                };
                break :blk try ctx.join(base, rel.sub_path.slice(c));
            },
            .generated => null,
        };
    }

    /// Root directory of a dependency package (absolute path): the path the maker gives is
    /// relative to its cwd (i.e. the build root) or absolute
    fn packageRoot(ctx: Ctx, package: Configuration.Package) Allocator.Error![]const u8 {
        return std.fs.path.resolveAlloc(ctx.arena, &.{ ctx.build_root, package.root_path.slice(ctx.c) });
    }

    /// Root directory (absolute path) of the dependency package fetched by hash that contains
    /// `lp`; null when `lp` is not in such a package
    fn fetchedPackageRoot(ctx: Ctx, lp: Configuration.LazyPath) Allocator.Error!?[]const u8 {
        const sp = switch (lp) {
            .source_path => |sp| sp,
            else => return null,
        };
        const package = sp.owner.get(ctx.c) orelse return null;
        const root = try ctx.packageRoot(package);
        return if (isFetched(root, package.hash.slice(ctx.c))) root else null;
    }

    fn join(ctx: Ctx, a: []const u8, b: []const u8) Allocator.Error![]const u8 {
        if (b.len == 0) return a;
        return std.fs.path.resolveAlloc(ctx.arena, &.{ a, b });
    }
};

/// Whether the dependency package with root directory `root` and hash `hash` was fetched: the
/// maker stores fetched packages in the `<hash>` subdirectory of the package directory
/// (`--pkg-dir`, `--system`, or `<build root>/zig-pkg`). A package given by `--fork` uses the
/// directory the user specifies
fn isFetched(root: []const u8, hash: []const u8) bool {
    return hash.len != 0 and std.mem.eql(u8, std.fs.path.basename(root), hash);
}

test isFetched {
    const native = @import("../util/test_path.zig").native;
    const hash = "zlinter-0.0.1-OjQ08eFlFQAb4BLnwZNNE3R5Dx2TI67EIpAsy2h0ZyoC";
    try std.testing.expect(isFetched(native("/p/zig-pkg/" ++ hash), hash));
    try std.testing.expect(isFetched(native("/shared/pkgs/" ++ hash), hash));
    try std.testing.expect(!isFetched(native("/home/me/zlinter"), hash));
    try std.testing.expect(!isFetched(native("/p"), ""));
}

test localCacheRoot {
    const native = @import("../util/test_path.zig").native;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = native("/p");
    try std.testing.expectEqualStrings(native("/p/.zig-cache"), try localCacheRoot(a, root, ".zig-cache/c/0123"));
    // `ZIG_LOCAL_CACHE_DIR` / `--cache-dir` is a relative path: relative to the build root
    try std.testing.expectEqualStrings(native("/p/relcache"), try localCacheRoot(a, root, "relcache/c/0123"));
    try std.testing.expectEqualStrings(native("/altcache"), try localCacheRoot(a, root, "../altcache/c/0123"));
    try std.testing.expectEqualStrings(native("/elsewhere/cache"), try localCacheRoot(a, root, native("/elsewhere/cache/c/0123")));
    // The local cache directory is the build root itself
    try std.testing.expectEqualStrings(root, try localCacheRoot(a, root, "c/0123"));
    // When no cache is used, the build graph is under `tmp`
    try std.testing.expectEqualStrings(native("/p/sub/cache"), try localCacheRoot(a, root, "sub/cache/tmp/1f"));
}

test {
    _ = @import("project_test.zig");
}
