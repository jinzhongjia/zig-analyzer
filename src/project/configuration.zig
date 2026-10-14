//! 把构建系统协议给出的构建图（`std.Build.Configuration`）转换为 `ProjectModel`。
//!
//! 构建图的二进制格式由标准库定义，只有在用户 zig 与 zig-analyzer 编译时的版本一致时才能加载
//! （见 `ZigEnv.matchesBuiltin`）。

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Configuration = std.Build.Configuration;
const ProjectModel = @import("../base/ProjectModel.zig");
const ZigEnv = @import("ZigEnv.zig");

/// 读取 maker 给出的构建图文件（`path` 相对于构建根目录）并转换
pub fn load(gpa: Allocator, io: Io, build_root: []const u8, path: []const u8, env: *const ZigEnv) !ProjectModel {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var dir = try Io.Dir.cwd().openDir(io, build_root, .{});
    defer dir.close(io);
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const conf = try Configuration.loadFile(scratch.allocator(), io, file);
    return convert(gpa, &conf, build_root, env);
}

pub fn convert(gpa: Allocator, c: *const Configuration, build_root: []const u8, env: *const ZigEnv) Allocator.Error!ProjectModel {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const a = arena_state.allocator();

    const ctx: Ctx = .{ .arena = a, .c = c, .build_root = try a.dupe(u8, build_root), .env = env };

    // 模块按 Configuration.Module.Index 去重，下标为发现顺序
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

    // 沿 import 表发现全部模块（迭代过程中 module_ids 会增长）
    var modules: std.ArrayList(ProjectModel.Module) = .empty;
    var i: usize = 0;
    while (i < module_ids.count()) : (i += 1) {
        const m = module_ids.keys()[i].get(c);
        const table = m.import_table.get(c).imports.mal;
        const imports = try a.alloc(ProjectModel.Import, table.len);
        for (table.items(.name), table.items(.module), imports) |name, target, *out| {
            out.* = .{ .name = try a.dupe(u8, name.slice(c)), .module = try internModule(gpa, &module_ids, target) };
        }
        const root = if (m.root_source_file.unwrap()) |lp| lp.get(c) else null;
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

    // builtin 的子命令与编译后端取以该模块为根的 compile step（决定 output_mode / is_test / zig_backend），
    // 其他模块按 build-obj
    for (c.steps) |*src| switch (src.extended.get(c.extra)) {
        .compile => |comp| {
            const index = module_ids.getIndex(comp.root_module) orelse continue;
            const mod = &modules.items[index];
            if (!std.mem.eql(u8, mod.builtin_args[0], "build-obj")) continue;
            var args: std.ArrayList([]const u8) = .empty;
            try args.appendSlice(a, mod.builtin_args);
            args.items[0] = switch (comp.flags3.kind) {
                .exe => "build-exe",
                .lib => "build-lib",
                .obj, .test_obj => "build-obj",
                .@"test" => "test",
            };
            // 编译后端决定 builtin 中的 `zig_backend`（向量的布局取决于它）
            if (comp.flags2.use_llvm.toBool()) |on| try args.append(a, if (on) "-fllvm" else "-fno-llvm");
            mod.builtin_args = args.items;
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
    // arena 的状态复制进结果之后不能再分配：新增的缓冲区不在复制的状态中，释放时会泄漏
    return .{
        .arena = arena_state.state,
        .build_root = ctx.build_root,
        .std_root = std_root,
        .steps = steps,
        .modules = modules.items,
        .default_step = @backingInt(c.default_step),
        .producers = producers,
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

/// 枚举 step 产出的生成文件（与 maker 上报 `bsp_step_completed` 时的遍历一致）
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

/// maker 上报的生成文件路径（前缀 + 子路径）转为绝对路径
pub fn generatedPath(gpa: Allocator, build_root: []const u8, env: *const ZigEnv, prefix: std.zig.Server.Message.PathPrefix, sub_path: []const u8) Allocator.Error![]u8 {
    const base: []const u8 = switch (prefix) {
        // maker 的 cwd 就是构建根目录
        .cwd, .build_root => build_root,
        .zig_lib => env.lib_dir,
        .global_cache => env.global_cache_dir,
        .local_cache => return std.fs.path.resolveAlloc(gpa, &.{ build_root, ".zig-cache", sub_path }),
    };
    return std.fs.path.resolveAlloc(gpa, &.{ base, sub_path });
}

/// 影响 `builtin.zig` 的模块参数，与构建系统传给编译器的写法一致（见 Maker/Step/Compile.zig 的 appendModuleFlags）
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
    env: *const ZigEnv,

    /// 解析为绝对路径；生成文件等构建前无法确定的路径返回 null
    fn resolve(ctx: Ctx, lp: Configuration.LazyPath) Allocator.Error!?[]const u8 {
        const c = ctx.c;
        return switch (lp) {
            .source_path => |sp| blk: {
                const sub = sp.sub_path.slice(c);
                const package = sp.owner.get(c) orelse break :blk try ctx.join(ctx.build_root, sub);
                // 依赖包的根路径相对于 maker 的 cwd（即构建根目录）或为绝对路径
                const root = package.root_path.slice(c);
                const abs_root = if (std.fs.path.isAbsolute(root)) root else try ctx.join(ctx.build_root, root);
                break :blk try ctx.join(abs_root, sub);
            },
            .relative => |rel| blk: {
                const base: []const u8 = switch (rel.flags.base) {
                    .cwd, .build_root => ctx.build_root,
                    .local_cache => try ctx.join(ctx.build_root, ".zig-cache"),
                    .global_cache => ctx.env.global_cache_dir,
                    .zig_lib => ctx.env.lib_dir,
                    else => break :blk null,
                };
                break :blk try ctx.join(base, rel.sub_path.slice(c));
            },
            .generated => null,
        };
    }

    fn join(ctx: Ctx, a: []const u8, b: []const u8) Allocator.Error![]const u8 {
        if (b.len == 0) return a;
        return std.fs.path.resolveAlloc(ctx.arena, &.{ a, b });
    }
};

test {
    _ = @import("project_test.zig");
}
