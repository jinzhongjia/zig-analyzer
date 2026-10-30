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
            .root_file = if (root) |lp| try ctx.resolve(lp) else null,
            .generated_root = if (root) |lp| switch (lp) {
                .generated => |g| .{ .file = @backingInt(g.index), .up = g.flags.up, .sub_path = try a.dupe(u8, g.sub_path.slice(c)) },
                else => null,
            } else null,
            .imports = imports,
        });
    }

    // The options each module sets itself
    const own = try gpa.alloc(ModuleOptions, module_ids.count());
    defer gpa.free(own);
    for (module_ids.keys(), own) |id, *o| o.* = try moduleOptions(a, c, &id.get(c));
    var builtins: Builtins = .{};
    defer builtins.index.deinit(gpa);
    for (c.steps, steps) |*src, *dst| switch (src.extended.get(c.extra)) {
        .compile => |comp| {
            dst.kind.compile.modules = try compileBuiltins(gpa, a, c, &comp, &module_ids, own, &builtins);
            if (comp.flags3.kind.isTest()) dst.kind.compile.root = try ctx.testRunner(&comp);
        },
        else => {},
    };

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
        .builtins = builtins.list.items,
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

/// Number of module options that affect `builtin.zig` (the slots of `ModuleOptions.args`)
const option_count = 12;

/// The options of a module that affect `builtin.zig`, each written as the arguments the build
/// system passes to the compiler (see appendModuleFlags in Maker/Step/Compile.zig); null for an
/// option the module does not set, which the compiler takes from the module it is created for
const ModuleOptions = struct {
    args: [option_count]?[]const []const u8 = @splat(null),
    /// libc and libc++ are linked into the whole compilation when any module links them
    link_libc: bool = false,
    link_libcpp: bool = false,
};

fn moduleOptions(a: Allocator, c: *const Configuration, m: *const Configuration.Module) Allocator.Error!ModuleOptions {
    var o: ModuleOptions = .{
        .link_libc = m.flags2.link_libc == .true,
        .link_libcpp = m.flags2.link_libcpp == .true,
    };
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
    inline for (flags, 0..) |f, i| if (f[1].toBool()) |on| {
        o.args[i] = if (on) &.{"-f" ++ f[0]} else &.{"-fno-" ++ f[0]};
    };
    o.args[flags.len] = switch (m.flags.unwind_tables) {
        .none => &.{"-fno-unwind-tables"},
        .sync => &.{"-funwind-tables"},
        .async => &.{"-fasync-unwind-tables"},
        .default => null,
    };
    o.args[flags.len + 1] = switch (m.flags.optimize) {
        .debug => &.{"-Odebug"},
        .safe => &.{"-Osafe"},
        .fast => &.{"-Ofast"},
        .small => &.{"-Osmall"},
        .default => null,
    };
    if (m.flags.code_model != .default) o.args[flags.len + 2] = try a.dupe([]const u8, &.{ "-mcmodel", @tagName(m.flags.code_model) });
    if (m.resolved_target.get(c)) |rt| if (rt.unwrapQuery(c)) |query| {
        o.args[flags.len + 3] = try a.dupe([]const u8, &.{ "-target", try query.zigTriple(a), "-mcpu", try query.serializeCpuAlloc(a) });
    };
    comptime std.debug.assert(flags.len + 4 == option_count);
    return o;
}

/// The distinct argument lists of `builtin.zig` (`ProjectModel.builtins`)
const Builtins = struct {
    list: std.ArrayList(ProjectModel.Builtin) = .empty,
    index: std.HashMapUnmanaged([]const []const u8, u32, ArgsContext, std.hash_map.default_max_load_percentage) = .empty,

    const ArgsContext = struct {
        pub fn hash(_: ArgsContext, args: []const []const u8) u64 {
            var h: std.hash.Wyhash = .init(0);
            for (args) |arg| {
                h.update(arg);
                h.update(&.{0});
            }
            return h.final();
        }
        pub fn eql(_: ArgsContext, x: []const []const u8, y: []const []const u8) bool {
            if (x.len != y.len) return false;
            for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
            return true;
        }
    };

    /// Index of `args` in `list`; `args` is copied when it is new
    fn intern(b: *Builtins, gpa: Allocator, a: Allocator, args: []const []const u8) Allocator.Error!u32 {
        const gop = try b.index.getOrPut(gpa, args);
        if (!gop.found_existing) {
            gop.key_ptr.* = try a.dupe([]const u8, args);
            gop.value_ptr.* = @intCast(b.list.items.len);
            try b.list.append(a, .{ .args = gop.key_ptr.* });
        }
        return gop.value_ptr.*;
    }
};

/// The `builtin.zig` of each module in compilation `comp`, in the order the compiler creates the
/// modules: depth first along the import tables from the root module, each module taking the
/// options it does not set from the module it is first reached from. Options of the whole
/// compilation (output mode, `is_test`, link mode, libc, ...) come from the compile step
fn compileBuiltins(
    gpa: Allocator,
    a: Allocator,
    c: *const Configuration,
    comp: *const Configuration.Step.Compile,
    ids: *const std.AutoArrayHashMapUnmanaged(Configuration.Module.Index, void),
    own: []const ModuleOptions,
    builtins: *Builtins,
) Allocator.Error![]const ProjectModel.CompileModule {
    // Module → its options in this compilation
    var created: std.AutoArrayHashMapUnmanaged(u32, [option_count]?[]const []const u8) = .empty;
    defer created.deinit(gpa);
    const Visit = struct { module: Configuration.Module.Index, parent: ?usize };
    var stack: std.ArrayList(Visit) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, .{ .module = comp.root_module, .parent = null });
    while (stack.pop()) |v| {
        const id: u32 = @intCast(ids.getIndex(v.module).?);
        const gop = try created.getOrPut(gpa, id);
        if (gop.found_existing) continue;
        var options = own[id].args;
        if (v.parent) |p| for (&options, created.values()[p]) |*o, inherited| {
            if (o.* == null) o.* = inherited;
        };
        created.values()[gop.index] = options;
        const table = v.module.get(c).import_table.get(c).imports.mal;
        const targets = table.items(.module);
        var t = targets.len;
        while (t > 0) {
            t -= 1;
            try stack.append(gpa, .{ .module = targets[t], .parent = gop.index });
        }
    }

    var wide: std.ArrayList([]const u8) = .empty;
    defer wide.deinit(gpa);
    if (comp.flags3.kind == .test_obj) try wide.append(gpa, "--test-no-exec");
    // The compiler backend determines `zig_backend` (vector layout depends on it)
    if (comp.flags2.use_llvm.toBool()) |on| try wide.append(gpa, if (on) "-fllvm" else "-fno-llvm");
    if (comp.root_module.get(c).resolved_target.get(c)) |rt| if (rt.unwrapQuery(c)) |query| if (query.ofmt) |ofmt| {
        try wide.append(gpa, try std.fmt.allocPrint(a, "-ofmt={t}", .{ofmt}));
    };
    switch (comp.flags2.linkage) {
        .dynamic => try wide.append(gpa, "-dynamic"),
        .static => try wide.append(gpa, "-static"),
        .default => {},
    }
    if (comp.flags2.pie.toBool()) |on| try wide.append(gpa, if (on) "-fPIE" else "-fno-PIE");
    switch (comp.flags3.wasi_exec_model) {
        .command => try wide.append(gpa, "-mexec-model=command"),
        .reactor => try wide.append(gpa, "-mexec-model=reactor"),
        .default => {},
    }
    const libs = try linkedLibs(gpa, c, comp, ids, own);
    if (libs.cpp) try wide.append(gpa, "-lc++");
    if (libs.c) try wide.append(gpa, "-lc");

    const result = try a.alloc(ProjectModel.CompileModule, created.count());
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    for (created.keys(), created.values(), result) |module, options, *out| {
        args.clearRetainingCapacity();
        try args.append(gpa, switch (comp.flags3.kind) {
            .exe => "build-exe",
            .lib => "build-lib",
            .obj => "build-obj",
            .@"test" => "test",
            .test_obj => "test-obj",
        });
        for (options) |o| if (o) |x| try args.appendSlice(gpa, x);
        try args.appendSlice(gpa, wide.items);
        out.* = .{ .module = module, .builtin = try builtins.intern(gpa, a, args.items) };
    }
    return result;
}

const Libs = struct { c: bool = false, cpp: bool = false };

/// Whether compilation `comp` links libc and libc++: some module of it, or of a compile step it
/// links (transitively, including dynamic libraries), links them (as `getCompileDependencies` in
/// Maker/Step/Compile.zig does)
fn linkedLibs(
    gpa: Allocator,
    c: *const Configuration,
    comp: *const Configuration.Step.Compile,
    ids: *const std.AutoArrayHashMapUnmanaged(Configuration.Module.Index, void),
    own: []const ModuleOptions,
) Allocator.Error!Libs {
    // The modules of the compilation and of the compilations it links
    var modules: std.AutoArrayHashMapUnmanaged(Configuration.Module.Index, void) = .empty;
    defer modules.deinit(gpa);
    try modules.put(gpa, comp.root_module, {});
    var result: Libs = .{};
    var i: usize = 0;
    while (i < modules.count()) : (i += 1) {
        const index = modules.keys()[i];
        const m = index.get(c);
        const o = &own[ids.getIndex(index).?];
        result.c = result.c or o.link_libc;
        result.cpp = result.cpp or o.link_libcpp;
        for (m.import_table.get(c).imports.mal.items(.module)) |target| try modules.put(gpa, target, {});
        for (0..m.link_objects.len) |l| switch (m.link_objects.get(c.extra, l)) {
            .other_step => |step| try modules.put(gpa, step.ptr(c).extended.get(c.extra).compile.root_module, {}),
            else => {},
        };
    }
    return result;
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

    /// The test runner of test compilation `comp`, which the compiler makes the root module (the
    /// target of `@import("root")`): the default one in the lib directory, or the one set by the
    /// compile step
    fn testRunner(ctx: Ctx, comp: *const Configuration.Step.Compile) Allocator.Error!ProjectModel.Compile.Root {
        return switch (comp.test_runner.u) {
            .default => .{ .test_runner = try std.fs.path.join(ctx.arena, &.{ ctx.env.lib_dir, "compiler", "test_runner.zig" }) },
            .simple, .server => |lp| if (try ctx.resolve(lp.get(ctx.c))) |p| .{ .test_runner = p } else .unknown,
        };
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
