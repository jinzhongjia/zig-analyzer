const std = @import("std");
const worker_stack = @import("src/util/worker_stack.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // tracy: with -Dtracy=<tracy source dir>, its client is compiled in, and queries and requests
    // are annotated with zones
    const tracy = b.option([]const u8, "tracy", "Enable Tracy profiling, with the path to the Tracy source checkout");
    const build_options = b.addOptions();
    build_options.addOption(bool, "tracy", tracy != null);
    build_options.addOption(bool, "zig_tests", false);
    build_options.addOption([]const u8, "version", gitVersion(b));

    const mod = b.createModule(.{
        .root_source_file = b.path("src/zig_analyzer.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", build_options);
    mod.addAnonymousImport("default_config", .{ .root_source_file = b.path("zig-analyzer.default.zon") });
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
    setStackReserve(exe);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run zig-analyzer").dependOn(&run_cmd.step);

    const check = b.step("check", "Check that everything compiles");
    check.dependOn(&exe.step);

    // A Windows build must start on every Windows 10 release (Zig's minimum): its imports from
    // system DLLs must not postdate Windows 10 1507 (see tools/check_windows_imports.zig)
    const check_imports = b.addExecutable(.{
        .name = "check_windows_imports",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_windows_imports.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    if (target.result.os.tag == .windows and
        @backingInt(target.result.os.version_range.windows.min) <= @backingInt(std.Target.Os.WindowsVersion.win10))
    {
        const check_imports_run = b.addRunArtifact(check_imports);
        check_imports_run.addArtifactArg(exe);
        check_imports_run.addDirectoryArg(std.Build.LazyPath.zig_lib.path(b, "libc/mingw/lib32"));
        check.dependOn(&check_imports_run.step);
    }

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
    const gen_manifest = b.addExecutable(.{
        .name = "gen_manifest_data",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_manifest_data.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const gen_manifest_run = b.addRunArtifact(gen_manifest);
    gen_manifest_run.addFileArg(b.path("tools/zig/build.zig.zon.md"));
    gen_manifest_run.addFileArg(b.path("tools/zig/metadata.json"));
    const manifest_data = gen_manifest_run.addOutputFileArg("manifest_data.zig");
    update_sources.addCopyFileToSource(manifest_data, "src/ide/manifest_data.zig");
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

    // Smoke test of a released executable:
    // zig build release-smoke -- <zig-analyzer> <project root> [<expected version>]
    const release_smoke = b.addExecutable(.{
        .name = "release-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/release_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zig_analyzer", .module = mod }},
        }),
    });
    const release_smoke_run = b.addRunArtifact(release_smoke);
    release_smoke_run.addPassthruArgs();
    b.step("release-smoke", "Check a released executable over LSP (see tools/release_smoke.zig)").dependOn(&release_smoke_run.step);

    // Release notes: zig build changelog -- <version>
    const changelog = b.addExecutable(.{
        .name = "changelog",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/changelog.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const changelog_run = b.addRunArtifact(changelog);
    changelog_run.addPassthruArgs();
    b.step("changelog", "Add the section of a version to CHANGELOG.md (see tools/changelog.zig)").dependOn(&changelog_run.step);

    // Test runner: the runner bundled with Zig, with stack trace recording enabled for the testing
    // allocator (so that leaks can be located under ReleaseSafe too), unwound with frame pointers
    // on aarch64 Darwin (see tools/patch_test_runner.zig)
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

    // check also compiles every tool: CI runs only some of them, and a tool that nothing compiles
    // stops compiling unnoticed when the analyzer's interfaces change
    for ([_]*std.Build.Step.Compile{ check_imports, gen_lsp, gen_builtins, gen_manifest, corpus, sema_corpus, bench, release_smoke, changelog, patch_runner }) |tool| check.dependOn(&tool.step);

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
    const manifest_generator_run = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_manifest_data.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    }));
    const imports_checker_run = b.addRunArtifact(b.addTest(.{ .root_module = check_imports.root_module }));
    const changelog_test_run = b.addRunArtifact(b.addTest(.{ .root_module = changelog.root_module }));
    const test_step = b.step("test", "Run the tests that need no external tools");
    test_step.dependOn(&generator_run.step);
    test_step.dependOn(&manifest_generator_run.step);
    test_step.dependOn(&imports_checker_run.step);
    test_step.dependOn(&changelog_test_run.step);
    test_step.dependOn(&runAnalyzerTests(b, analyzerTests(b, target, optimize, test_runner, tracy != null, false, null)).step);
    const all_step = b.step("test-all", "Run all tests, including those that run the zig in PATH");
    all_step.dependOn(&generator_run.step);
    all_step.dependOn(&manifest_generator_run.step);
    all_step.dependOn(&imports_checker_run.step);
    all_step.dependOn(&changelog_test_run.step);
    all_step.dependOn(&runAnalyzerTests(b, analyzerTests(b, target, optimize, test_runner, tracy != null, true, null)).step);

    // Stress verification (for concurrency-related changes): run the selected tests repeatedly, one
    // after another, in server mode; every run really executes, without cached results
    const stress_step = b.step("test-stress", "Run the tests matching -Dstress-filter repeatedly in server mode");
    const stress_filter = b.option([]const u8, "stress-filter", "test-stress: run the tests whose full names contain this");
    const stress_runs = b.option(u32, "stress-runs", "test-stress: number of runs (default 50)") orelse 50;
    if (stress_filter) |filter| {
        const tests = analyzerTests(b, target, optimize, test_runner, tracy != null, true, filter);
        var prev: ?*std.Build.Step = null;
        for (0..stress_runs) |_| {
            const run = runAnalyzerTests(b, tests);
            run.has_side_effects = true;
            if (prev) |p| run.step.dependOn(p);
            prev = &run.step;
        }
        if (prev) |p| stress_step.dependOn(p);
    } else stress_step.dependOn(&b.addFail("test-stress needs -Dstress-filter=<part of the full test names>").step);
}

/// The version of the release this source is or follows; its tag is `v` followed by it
const version = @import("build.zig.zon").version;

/// The version when the tag of `version` is not reachable, or when git cannot tell the commit
const fallback_version = version ++ "-dev";

/// `version` when HEAD is the commit of its tag; after the tag, followed by the number of commits
/// since the tag and the current commit as build metadata (`0.1.0+12.gd8b0905`). Without the tag
/// (`version` bumped but not yet tagged), `fallback_version` with the current commit
/// (`0.1.0-dev+d8b0905`). Without git or a repository, `fallback_version` and a warning.
fn gitVersion(b: *std.Build) []const u8 {
    // Commits and tags change what git prints without changing anything the configure cache tracks
    b.graph.poisonCache();
    // `v<version>-<count>-g<commit>`
    if (gitOutput(b, &.{ "git", "describe", "--tags", "--long", "--match", "v" ++ version })) |described| {
        var parts = std.mem.splitBackwardsScalar(u8, described, '-');
        const commit = parts.first();
        const count = parts.next().?;
        if (std.mem.eql(u8, count, "0")) return version;
        return b.fmt("{s}+{s}.{s}", .{ version, count, commit });
    }
    if (gitOutput(b, &.{ "git", "rev-parse", "--short", "HEAD" })) |commit|
        return b.fmt("{s}+{s}", .{ fallback_version, commit });
    std.log.warn("no version information from git (not installed, or not a git repository): the version is {s}", .{fallback_version});
    return fallback_version;
}

/// The trimmed standard output of `argv` run in the build root; null when it fails in any way
fn gitOutput(b: *std.Build, argv: []const []const u8) ?[]const u8 {
    const root = b.root.toString(b.graph.arena) catch @panic("OOM");
    return switch (b.runFallible(argv, .{ .stderr_behavior = .ignore, .cwd = .{ .path = root } })) {
        .success => |stdout| std.mem.trim(u8, stdout, " \t\r\n"),
        .spawn_failed, .bad_exit_code, .crashed => null,
    };
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
    // Fixed, so that a new commit alone does not rebuild the tests
    options.addOption([]const u8, "version", fallback_version);
    const module = b.createModule(.{
        .root_source_file = b.path("src/zig_analyzer.zig"),
        .target = target,
        .optimize = optimize,
        // Keep frame pointers so that leak report stack traces are complete in optimized modes, and
        // so that the test runner can unwind with them on aarch64 Darwin
        .omit_frame_pointer = false,
    });
    module.addOptions("build_options", options);
    module.addAnonymousImport("default_config", .{ .root_source_file = b.path("zig-analyzer.default.zon") });
    const tests = b.addTest(.{
        .root_module = module,
        .test_runner = .{ .path = runner, .mode = .server },
        .filters = if (filter) |f| b.dupeStrings(&.{f}) else &.{},
    });
    setStackReserve(tests);
    return tests;
}

/// Runs the analyzer tests without the cache directory overrides of the environment. The fixtures
/// are created under `.zig-cache/tmp` of the current directory: with `ZIG_GLOBAL_CACHE_DIR` naming
/// that `.zig-cache` (as setup-zig does in CI), every fixture file is inside the global cache and
/// is classified as generated; with `ZIG_LOCAL_CACHE_DIR` set, the makers of the fixtures put
/// their local caches outside the fixtures' build roots
fn runAnalyzerTests(b: *std.Build, tests: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = b.addRunArtifact(tests);
    run.removeEnvironmentVariable("ZIG_GLOBAL_CACHE_DIR");
    run.removeEnvironmentVariable("ZIG_LOCAL_CACHE_DIR");
    return run;
}

/// Windows: threads take the executable's stack reserve as theirs, and the worker threads of
/// the server get only a small initial commit (see src/util/worker_stack.zig)
fn setStackReserve(compile: *std.Build.Step.Compile) void {
    if (compile.rootModuleTarget().os.tag == .windows) compile.stack_size = worker_stack.size;
}
