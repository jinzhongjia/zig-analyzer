const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // tracy：-Dtracy=<tracy 源码目录> 时编译其客户端，query 与请求以 zone 标注
    const tracy = b.option([]const u8, "tracy", "Enable Tracy profiling, with the path to the Tracy source checkout");
    const build_options = b.addOptions();
    build_options.addOption(bool, "tracy", tracy != null);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/zig_analyzer.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", build_options);
    if (tracy) |dir| {
        mod.addCSourceFile(.{
            .file = .{ .cwd_relative = b.pathJoin(&.{ dir, "public", "TracyClient.cpp" }) },
            .flags = &.{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined" },
        });
        mod.link_libc = true;
        mod.link_libcpp = true;
        if (target.result.os.tag == .windows) {
            mod.linkSystemLibrary("dbghelp", .{});
            mod.linkSystemLibrary("ws2_32", .{});
        }
    }

    const exe = b.addExecutable(.{
        .name = "zig-analyzer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zig_analyzer", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run zig-analyzer").dependOn(&run_cmd.step);

    const check = b.step("check", "Check that everything compiles");
    check.dependOn(&exe.step);

    // 生成代码：结果写回 src/，与源码一起提交
    const gen_step = b.step("gen", "Regenerate LSP types and other generated code");
    const gen_lsp = b.addExecutable(.{
        .name = "gen_lsp_types",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_lsp_types.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const gen_lsp_run = b.addRunArtifact(gen_lsp);
    gen_lsp_run.addFileArg(b.path("tools/metaModel.json"));
    const lsp_types = gen_lsp_run.addOutputFileArg("types.zig");
    const update_sources = b.addUpdateSourceFiles();
    update_sources.addCopyFileToSource(lsp_types, "src/lsp/types.zig");
    const gen_builtins = b.addExecutable(.{
        .name = "gen_builtin_data",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_builtin_data.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const gen_builtins_run = b.addRunArtifact(gen_builtins);
    gen_builtins_run.addFileArg(b.path("tools/zig/langref.html.in"));
    gen_builtins_run.addFileArg(b.path("tools/zig/metadata.json"));
    gen_builtins_run.addFileArg(std.Build.LazyPath.zig_lib.path(b, "std/zig/BuiltinFn.zig"));
    const builtin_data = gen_builtins_run.addOutputFileArg("builtin_data.zig");
    update_sources.addCopyFileToSource(builtin_data, "src/ide/builtin_data.zig");
    gen_step.dependOn(&update_sources.step);

    // 语料对拍：默认校验当前 Zig 的标准库，可追加目录：zig build corpus -- <目录>...
    const corpus = b.addExecutable(.{
        .name = "corpus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/corpus.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zig_analyzer", .module = mod }},
        }),
    });
    const corpus_run = b.addRunArtifact(corpus);
    corpus_run.addDirectoryArg(std.Build.LazyPath.zig_lib.path(b, "std"));
    corpus_run.addPassthruArgs();
    b.step("corpus", "Validate the CST parser against a Zig source corpus").dependOn(&corpus_run.step);

    // 在标准库上运行类型推导：zig build sema-corpus -Doptimize=ReleaseSafe
    const sema_corpus = b.addExecutable(.{
        .name = "sema-corpus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/sema_corpus.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zig_analyzer", .module = mod }},
        }),
    });
    const sema_corpus_run = b.addRunArtifact(sema_corpus);
    sema_corpus_run.addDirectoryArg(std.Build.LazyPath.zig_lib.path(b, "std"));
    sema_corpus_run.addPassthruArgs();
    b.step("sema-corpus", "Run type inference over the standard library").dependOn(&sema_corpus_run.step);

    // LSP 基准：zig build bench -Doptimize=ReleaseSafe -- <项目根目录> <文件>...
    const bench = b.addExecutable(.{
        .name = "lsp-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/lsp_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zig_analyzer", .module = mod }},
        }),
    });
    const bench_run = b.addRunArtifact(bench);
    bench_run.addArtifactArg(exe);
    bench_run.addPassthruArgs();
    b.step("bench", "Measure LSP latencies against a project (see tools/lsp_bench.zig)").dependOn(&bench_run.step);
    check.dependOn(&bench.step);

    // 测试运行器：在 Zig 自带的运行器上开启测试分配器的调用栈记录（ReleaseSafe 下泄漏也能定位）
    const patch_runner = b.addExecutable(.{
        .name = "patch_test_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/patch_test_runner.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const patch_run = b.addRunArtifact(patch_runner);
    patch_run.addFileArg(std.Build.LazyPath.zig_lib.path(b, "compiler/test_runner.zig"));
    const test_runner = patch_run.addOutputFileArg("test_runner.zig");

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/zig_analyzer.zig"),
        .target = target,
        .optimize = optimize,
        .omit_frame_pointer = false,
    });
    test_mod.addOptions("build_options", build_options);
    const test_step = b.step("test", "Run all tests");
    const generator_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_builtin_data.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(generator_tests).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        // 保留帧指针：优化模式下泄漏报告的调用栈才完整
        .root_module = test_mod,
        .test_runner = .{ .path = test_runner, .mode = .server },
    })).step);
}
