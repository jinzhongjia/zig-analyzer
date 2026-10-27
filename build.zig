const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // tracy: with -Dtracy=<tracy source dir>, its client is compiled in, and queries and requests
    // are annotated with zones
    const tracy = b.option([]const u8, "tracy", "Enable Tracy profiling, with the path to the Tracy source checkout");
    const build_options = b.addOptions();
    build_options.addOption(bool, "tracy", tracy != null);
    build_options.addOption(bool, "zig_tests", false);

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

    // Code generation: results are written back to src/ and committed together with the sources
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

    // Corpus cross-check: checks the standard library of the current Zig by default; more
    // directories can be added: zig build corpus -- <dir>...
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

    // Run type inference over the standard library: zig build sema-corpus -Doptimize=ReleaseSafe
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

    // LSP benchmark: zig build bench -Doptimize=ReleaseSafe -- <project root> <file>...
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

    // Test runner: the runner bundled with Zig, with stack trace recording enabled for the testing
    // allocator (so that leaks can be located under ReleaseSafe too)
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

    // Tests that depend on a real zig (build system protocol, single-file compilation, end-to-end)
    // run only in test-all and test-stress: under `zig build test` zig is not found (see
    // `ZigEnv.query`), so these tests are skipped
    const generator_run = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_builtin_data.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    }));
    const test_step = b.step("test", "Run the tests that need no external tools");
    test_step.dependOn(&generator_run.step);
    test_step.dependOn(&b.addRunArtifact(analyzerTests(b, target, optimize, test_runner, tracy != null, false, null)).step);
    const all_step = b.step("test-all", "Run all tests, including those that run the zig in PATH");
    all_step.dependOn(&generator_run.step);
    all_step.dependOn(&b.addRunArtifact(analyzerTests(b, target, optimize, test_runner, tracy != null, true, null)).step);

    // Stress verification (for concurrency-related changes): run the selected tests repeatedly, one
    // after another, in server mode; every run really executes, without cached results
    const stress_step = b.step("test-stress", "Run the tests matching -Dstress-filter repeatedly in server mode");
    const stress_filter = b.option([]const u8, "stress-filter", "test-stress: run the tests whose full names contain this");
    const stress_runs = b.option(u32, "stress-runs", "test-stress: number of runs (default 50)") orelse 50;
    if (stress_filter) |filter| {
        const tests = analyzerTests(b, target, optimize, test_runner, tracy != null, true, filter);
        var prev: ?*std.Build.Step = null;
        for (0..stress_runs) |_| {
            const run = b.addRunArtifact(tests);
            run.has_side_effects = true;
            if (prev) |p| run.step.dependOn(p);
            prev = &run.step;
        }
        if (prev) |p| stress_step.dependOn(p);
    } else stress_step.dependOn(&b.addFail("test-stress needs -Dstress-filter=<part of the full test names>").step);
}

/// Tests of the analyzer itself. With `zig_tests`, the tests that depend on a real zig run too;
/// when `filter` is not null, only tests whose full name contains it are compiled
fn analyzerTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    runner: std.Build.LazyPath,
    tracy: bool,
    zig_tests: bool,
    filter: ?[]const u8,
) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption(bool, "tracy", tracy);
    options.addOption(bool, "zig_tests", zig_tests);
    const module = b.createModule(.{
        .root_source_file = b.path("src/zig_analyzer.zig"),
        .target = target,
        .optimize = optimize,
        // Keep frame pointers so that leak report stack traces are complete in optimized modes
        .omit_frame_pointer = false,
    });
    module.addOptions("build_options", options);
    return b.addTest(.{
        .root_module = module,
        .test_runner = .{ .path = runner, .mode = .server },
        .filters = if (filter) |f| b.dupeStrings(&.{f}) else &.{},
    });
}
