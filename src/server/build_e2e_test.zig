//! End-to-end: how the options of the build graph's compilations reach analysis (`builtin`, the
//! standard library, `@import("root")`, and type layouts).

const std = @import("std");
const testing = std.testing;
const za = @import("../zig_analyzer.zig");
const fixture = za.project.fixture;
const Harness = @import("test_harness.zig").Harness;

const Empty = struct {};

/// A server started on a temporary project, initialized with `options` (JSON)
const Session = struct {
    project: fixture.Project,
    h: Harness,

    fn start(s: *Session, files: []const fixture.File, options: []const u8) !void {
        return s.startFolders(files, &.{}, options);
    }

    /// Like `start`, with the given subdirectories of the project as the workspace folders (the
    /// project root itself when empty)
    fn startFolders(s: *Session, files: []const fixture.File, folders: []const []const u8, options: []const u8) !void {
        s.project = try fixture.Project.create(files);
        errdefer s.project.deinit();
        try s.h.start();
        const a = s.h.arena.allocator();
        const root_uri = try za.base.uri.fromPath(a, s.project.root);
        const init_options = try std.json.parseFromSliceLeaky(std.json.Value, a, options, .{});
        const Folder = struct { uri: []const u8, name: []const u8 };
        const list = try a.alloc(Folder, folders.len);
        for (folders, list) |f, *l| l.* = .{ .uri = try s.uri(f), .name = f };
        if (folders.len == 0) {
            _ = try s.h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{}, .initializationOptions = init_options });
        } else {
            _ = try s.h.request("initialize", .{ .workspaceFolders = list, .capabilities = Empty{}, .initializationOptions = init_options });
        }
        try s.h.notify("initialized", Empty{});
    }

    fn finish(s: *Session) void {
        _ = s.h.request("shutdown", {}) catch {};
        s.h.notify("exit", {}) catch {};
        s.h.finish();
        s.project.deinit();
    }

    fn uri(s: *Session, path: []const u8) ![]const u8 {
        const a = s.h.arena.allocator();
        return za.base.uri.fromPath(a, try s.project.path(a, path));
    }

    /// Opens the project file `path` with its text on disk and returns its URI
    fn open(s: *Session, path: []const u8, text: []const u8) ![]const u8 {
        const u = try s.uri(path);
        try s.h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = u, .languageId = "zig", .version = 1, .text = text } });
        return u;
    }

    fn waitIdle(s: *Session) !void {
        _ = try s.h.request("zig-analyzer/waitIdle", {});
    }

    fn hover(s: *Session, u: []const u8, text: []const u8, needle: []const u8) ![]const u8 {
        const resp = try s.h.request("textDocument/hover", .{ .textDocument = .{ .uri = u }, .position = position(text, needle, 0) });
        const result = resp.object.get("result").?;
        if (result == .null) return "null";
        return result.object.get("contents").?.object.get("value").?.string;
    }

    /// Definition at the start of `needle`: "file:line" (the file name only)
    fn definition(s: *Session, u: []const u8, text: []const u8, needle: []const u8) ![]const u8 {
        const resp = try s.h.request("textDocument/definition", .{ .textDocument = .{ .uri = u }, .position = position(text, needle, 0) });
        const result = resp.object.get("result").?;
        const target = switch (result) {
            .null => return "null",
            .array => |arr| if (arr.items.len == 1) arr.items[0] else return "several",
            else => result,
        };
        return s.label(target.object.get("uri").?.string, target.object.get("range").?);
    }

    /// The path of the file `uri` relative to the project root (or the file name when it is
    /// outside), with the 0-based line of `range`
    fn label(s: *Session, target_uri: []const u8, range: std.json.Value) ![]const u8 {
        const a = s.h.arena.allocator();
        const path = try za.base.uri.toPath(a, target_uri);
        const rel = if (std.mem.startsWith(u8, path, s.project.root)) path[s.project.root.len + 1 ..] else std.fs.path.basename(path);
        const line = range.object.get("start").?.object.get("line").?.integer;
        return std.fmt.allocPrint(a, "{s}:{d}", .{ rel, line });
    }

    /// Completion labels after `after` in `text`
    fn completion(s: *Session, u: []const u8, text: []const u8, after: []const u8) ![]const []const u8 {
        const resp = try s.h.request("textDocument/completion", .{ .textDocument = .{ .uri = u }, .position = position(text, after, after.len) });
        var labels: std.ArrayList([]const u8) = .empty;
        const result = resp.object.get("result").?;
        const items = switch (result) {
            .array => |arr| arr.items,
            .object => |o| o.get("items").?.array.items,
            else => &.{},
        };
        for (items) |item| try labels.append(s.h.arena.allocator(), item.object.get("label").?.string);
        return labels.items;
    }

    /// Start lines of the inactive-code hints last published for `u`
    fn inactiveLines(s: *Session, u: []const u8) ![]const i64 {
        var last: []const i64 = &.{};
        for (try s.h.notifications("textDocument/publishDiagnostics")) |m| {
            const params = m.object.get("params").?.object;
            if (!std.mem.eql(u8, params.get("uri").?.string, u)) continue;
            var lines: std.ArrayList(i64) = .empty;
            for (params.get("diagnostics").?.array.items) |d| {
                if (!std.mem.startsWith(u8, d.object.get("message").?.string, "code is inactive")) continue;
                try lines.append(s.h.arena.allocator(), d.object.get("range").?.object.get("start").?.object.get("line").?.integer);
            }
            last = lines.items;
        }
        return last;
    }

    /// References of the name at `needle` (including the declaration), sorted, as "file:line"
    fn references(s: *Session, u: []const u8, text: []const u8, needle: []const u8) ![]const u8 {
        const resp = try s.h.request("textDocument/references", .{ .textDocument = .{ .uri = u }, .position = position(text, needle, 0), .context = .{ .includeDeclaration = true } });
        var out: std.ArrayList([]const u8) = .empty;
        for (resp.object.get("result").?.array.items) |l| try out.append(s.h.arena.allocator(), try s.label(l.object.get("uri").?.string, l.object.get("range").?));
        return s.sorted(out.items);
    }

    /// Edits of renaming the name at `needle` to `new_name`, sorted, as "file:line:character";
    /// every edited file must exist on disk
    fn rename(s: *Session, u: []const u8, text: []const u8, needle: []const u8, new_name: []const u8) ![]const u8 {
        const a = s.h.arena.allocator();
        const resp = try s.h.request("textDocument/rename", .{ .textDocument = .{ .uri = u }, .position = position(text, needle, 0), .newName = new_name });
        var out: std.ArrayList([]const u8) = .empty;
        var it = resp.object.get("result").?.object.get("changes").?.object.iterator();
        while (it.next()) |kv| {
            try std.Io.Dir.cwd().access(testing.io, try za.base.uri.toPath(a, kv.key_ptr.*), .{});
            for (kv.value_ptr.array.items) |e| {
                try testing.expectEqualStrings(new_name, e.object.get("newText").?.string);
                const at = e.object.get("range").?.object.get("start").?.object;
                try out.append(a, try std.fmt.allocPrint(a, "{s}:{d}", .{ try s.label(kv.key_ptr.*, e.object.get("range").?), at.get("character").?.integer }));
            }
        }
        return s.sorted(out.items);
    }

    /// Document highlights of the name at `needle`, sorted, as "line:character"
    fn highlights(s: *Session, u: []const u8, text: []const u8, needle: []const u8) ![]const u8 {
        const a = s.h.arena.allocator();
        const resp = try s.h.request("textDocument/documentHighlight", .{ .textDocument = .{ .uri = u }, .position = position(text, needle, 0) });
        var out: std.ArrayList([]const u8) = .empty;
        for (resp.object.get("result").?.array.items) |hl| {
            const at = hl.object.get("range").?.object.get("start").?.object;
            try out.append(a, try std.fmt.allocPrint(a, "{d}:{d}", .{ at.get("line").?.integer, at.get("character").?.integer }));
        }
        return s.sorted(out.items);
    }

    fn sorted(s: *Session, items: [][]const u8) ![]const u8 {
        std.mem.sort([]const u8, items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        return std.mem.join(s.h.arena.allocator(), " ", items);
    }

    /// The path of the single definition at the start of `needle`, which must exist on disk
    fn definitionPath(s: *Session, u: []const u8, text: []const u8, needle: []const u8) ![]const u8 {
        const a = s.h.arena.allocator();
        const resp = try s.h.request("textDocument/definition", .{ .textDocument = .{ .uri = u }, .position = position(text, needle, 0) });
        const result = resp.object.get("result").?;
        const target = switch (result) {
            .array => |arr| blk: {
                try testing.expectEqual(1, arr.items.len);
                break :blk arr.items[0];
            },
            else => result,
        };
        const path = try za.base.uri.toPath(a, target.object.get("uri").?.string);
        try std.Io.Dir.cwd().access(testing.io, path, .{});
        return path;
    }
};

/// Position `skip` bytes after the start of `needle` in `text`
fn position(text: []const u8, needle: []const u8, skip: usize) struct { line: u32, character: u32 } {
    const offset = std.mem.indexOf(u8, text, needle).? + skip;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..offset], '\n')) |i| i + 1 else 0;
    return .{ .line = @intCast(std.mem.count(u8, text[0..offset], "\n")), .character = @intCast(offset - line_start) };
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

const inherit_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\    const util = b.createModule(.{ .root_source_file = b.path("src/util.zig") });
    \\    const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\        .imports = &.{.{ .name = "util", .module = util }},
    \\    }) });
    \\    b.step("check", "Check").dependOn(&exe.step);
    \\}
    \\
;

const inherit_main =
    \\const util = @import("util");
    \\pub const ps = @sizeOf(usize);
    \\pub fn main() void {
    \\    _ = util.kind();
    \\}
    \\
;

const inherit_util =
    \\const builtin = @import("builtin");
    \\pub const opt = builtin.optimize;
    \\pub const ps = @sizeOf(usize);
    \\pub const mode = builtin.output_mode;
    \\pub fn kind() []const u8 {
    \\    if (builtin.optimize == .debug) {
    \\        return "debug";
    \\    } else {
    \\        return "release";
    \\    }
    \\}
    \\
;

test "build integration: a module without its own target and optimize mode inherits them from the compilation" {
    var s: Session = undefined;
    try s.start(&.{
        .{ .path = "build.zig", .text = inherit_build },
        .{ .path = "src/main.zig", .text = inherit_main },
        .{ .path = "src/util.zig", .text = inherit_util },
    },
        \\{"build": {"args": ["-Doptimize=ReleaseFast", "-Dtarget=x86-linux"]}, "diagnostics": {"inactive_code": true}}
    );
    defer s.finish();
    const main_uri = try s.open("src/main.zig", inherit_main);
    const util_uri = try s.open("src/util.zig", inherit_util);
    try s.waitIdle();

    // `util` was analyzed for the native target in Debug as an object
    try testing.expectEqualStrings("```zig\nconst opt: Optimize = .fast\n```", try s.hover(util_uri, inherit_util, "opt ="));
    try testing.expectEqualStrings("```zig\nconst mode: OutputMode = .Exe\n```", try s.hover(util_uri, inherit_util, "mode ="));
    try testing.expectEqualStrings("```zig\nconst ps: comptime_int = 4\n```", try s.hover(util_uri, inherit_util, "ps ="));
    try testing.expectEqualStrings("```zig\nconst ps: comptime_int = 4\n```", try s.hover(main_uri, inherit_main, "ps ="));
    // Only the Debug branch is inactive
    try testing.expectEqualSlices(i64, &.{5}, try s.inactiveLines(util_uri));
}

const test_root_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = b.graph.host,
    \\    }) });
    \\    b.installArtifact(exe);
    \\    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    \\    b.step("test", "Run tests").dependOn(&b.addRunArtifact(exe_tests).step);
    \\}
    \\
;

const test_root_main =
    \\const std = @import("std");
    \\const builtin = @import("builtin");
    \\pub const in_test = if (builtin.is_test) @as(u8, 1) else @as(u16, 2);
    \\pub fn main() void {
    \\    if (!builtin.is_test) {
    \\        std.debug.print("hello from the app\n", .{});
    \\    }
    \\}
    \\test "main does not crash" {
    \\    main();
    \\}
    \\
;

test "build integration: builtin.is_test follows the compilation used for diagnostics" {
    var s: Session = undefined;
    try s.start(&.{
        .{ .path = "build.zig", .text = test_root_build },
        .{ .path = "src/main.zig", .text = test_root_main },
    },
        \\{"diagnostics": {"inactive_code": true}}
    );
    defer s.finish();
    const main_uri = try s.open("src/main.zig", test_root_main);
    try s.waitIdle();

    // The default install step compiles the module as an executable, not as a test
    try testing.expectEqualStrings("```zig\nconst in_test: u16 = 2\n```", try s.hover(main_uri, test_root_main, "in_test ="));
    // Only the test arm is inactive, not the code the executable runs
    try testing.expectEqualSlices(i64, &.{2}, try s.inactiveLines(main_uri));
}

test "build integration: builtin.is_test in single-file mode matches the single-file compile" {
    var s: Session = undefined;
    try s.start(&.{.{ .path = "one.zig", .text = test_root_main }},
        \\{"diagnostics": {"inactive_code": true}}
    );
    defer s.finish();
    const one_uri = try s.open("one.zig", test_root_main);
    try s.waitIdle();

    try testing.expectEqualStrings("```zig\nconst in_test: u16 = 2\n```", try s.hover(one_uri, test_root_main, "in_test ="));
    try testing.expectEqualSlices(i64, &.{2}, try s.inactiveLines(one_uri));
}

fn testRunnerBuild(comptime runner: []const u8) []const u8 {
    return
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const mod = b.addModule("mylib", .{ .root_source_file = b.path("src/root.zig"), .target = b.standardTargetOptions(.{}) });
    \\    const mod_tests = b.addTest(.{ .root_module = mod
    ++ runner ++
        \\ });
        \\    b.step("test", "Run tests").dependOn(&b.addRunArtifact(mod_tests).step);
        \\    b.step("check", "Check").dependOn(&mod_tests.step);
        \\}
        \\
    ;
}

const test_runner_root =
    \\const std = @import("std");
    \\pub const custom_marker = 1;
    \\const helper = @import("helper.zig");
    \\test "which root" {
    \\    try std.testing.expectEqualStrings("test runner", helper.which());
    \\}
    \\
;

const test_runner_helper =
    \\const root = @import("root");
    \\pub fn which() []const u8 {
    \\    if (@hasDecl(root, "custom_marker")) {
    \\        return "user root";
    \\    } else {
    \\        return "test runner";
    \\    }
    \\}
    \\fn probe() void {
    \\    _ = root.
    \\}
    \\
;

test "build integration: @import(\"root\") in a test compilation is the test runner" {
    var s: Session = undefined;
    try s.start(&.{
        .{ .path = "build.zig", .text = comptime testRunnerBuild("") },
        .{ .path = "src/root.zig", .text = test_runner_root },
        .{ .path = "src/helper.zig", .text = test_runner_helper },
    },
        \\{"diagnostics": {"inactive_code": true}}
    );
    defer s.finish();
    const helper_uri = try s.open("src/helper.zig", test_runner_helper);
    try s.waitIdle();

    try testing.expectEqualStrings("test_runner.zig:0", try s.definition(helper_uri, test_runner_helper, "\"root\""));
    const labels = try s.completion(helper_uri, test_runner_helper, "_ = root.");
    try testing.expect(!contains(labels, "custom_marker"));
    try testing.expect(contains(labels, "std_options"));
    // The branch the test runner compiles is not inactive
    try testing.expectEqualSlices(i64, &.{2}, try s.inactiveLines(helper_uri));
}

test "build integration: @import(\"root\") in a test compilation with a custom test runner" {
    var s: Session = undefined;
    try s.start(&.{
        .{ .path = "build.zig", .text = comptime testRunnerBuild(", .test_runner = .{ .path = b.path(\"runner.zig\"), .mode = .simple }") },
        .{ .path = "runner.zig", .text = "pub const custom_marker = 2;\npub fn main() void {}\n" },
        .{ .path = "src/root.zig", .text = test_runner_root },
        .{ .path = "src/helper.zig", .text = test_runner_helper },
    },
        \\{"diagnostics": {"inactive_code": true}}
    );
    defer s.finish();
    const helper_uri = try s.open("src/helper.zig", test_runner_helper);
    try s.waitIdle();

    try testing.expectEqualStrings("runner.zig:0", try s.definition(helper_uri, test_runner_helper, "\"root\""));
    try testing.expectEqualSlices(i64, &.{4}, try s.inactiveLines(helper_uri));
}

const lib_dir_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const t = b.addTest(.{
    \\        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = b.graph.host }),
    \\        .zig_lib_dir = b.path("mylib"),
    \\    });
    \\    b.step("check", "Compile the tests").dependOn(&t.step);
    \\}
    \\
;

const lib_dir_main =
    \\const std = @import("std");
    \\
    \\test "local std marker" {
    \\    const marker = std.math.verifyMarker;
    \\    _ = marker;
    \\    _ = std.math.
    \\}
    \\
;

test "build integration: @import(\"std\") follows the zig_lib_dir of the compilation" {
    var s: Session = undefined;
    try s.start(&.{
        .{ .path = "build.zig", .text = lib_dir_build },
        .{ .path = "src/main.zig", .text = lib_dir_main },
        .{ .path = "mylib/std/std.zig", .text = "pub const math = @import(\"math.zig\");\n" },
        .{ .path = "mylib/std/math.zig", .text = "pub const pi = 3.14;\npub const verifyMarker: u32 = 42;\n" },
    }, "{}");
    defer s.finish();
    const main_uri = try s.open("src/main.zig", lib_dir_main);
    try s.waitIdle();

    try testing.expectEqualStrings("mylib/std/math.zig:1", try s.definition(main_uri, lib_dir_main, "verifyMarker"));
    try testing.expectEqualStrings("```zig\nconst marker: u32 = 42\n```", try s.hover(main_uri, lib_dir_main, "marker ="));
    try testing.expect(contains(try s.completion(main_uri, lib_dir_main, "_ = std.math."), "verifyMarker"));
}

const lib_tree_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const t = b.addTest(.{
    \\        .root_module = b.createModule(.{ .root_source_file = b.path("lib/std/std.zig"), .target = b.graph.host }),
    \\        .zig_lib_dir = b.path("lib"),
    \\    });
    \\    b.step("check", "Compile the tests").dependOn(&t.step);
    \\}
    \\
;

const lib_tree_mem = "pub fn trimEnd() void {}\n";

const lib_tree_tar =
    \\const std = @import("std");
    \\pub fn next() void {
    \\    std.mem.trimEnd();
    \\}
    \\
;

test "build integration: references in a standard library tree compiled with its own zig_lib_dir" {
    var s: Session = undefined;
    try s.start(&.{
        .{ .path = "build.zig", .text = lib_tree_build },
        .{ .path = "lib/std/std.zig", .text = "pub const mem = @import(\"mem.zig\");\npub const tar = @import(\"tar.zig\");\n" },
        .{ .path = "lib/std/mem.zig", .text = lib_tree_mem },
        .{ .path = "lib/std/tar.zig", .text = lib_tree_tar },
    }, "{}");
    defer s.finish();
    const mem_uri = try s.open("lib/std/mem.zig", lib_tree_mem);
    const tar_uri = try s.open("lib/std/tar.zig", lib_tree_tar);
    try s.waitIdle();

    // `@import("std")` in the tree is the tree's own standard library, not the installed one
    try testing.expectEqualStrings("lib/std/mem.zig:0", try s.definition(tar_uri, lib_tree_tar, "trimEnd"));
    try testing.expectEqualStrings("lib/std/mem.zig:0 lib/std/tar.zig:2", try s.references(mem_uri, lib_tree_mem, "trimEnd"));
}

const cross_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const gen = b.addExecutable(.{ .name = "gen", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("tools/gen.zig"),
    \\        .target = b.graph.host,
    \\    }) });
    \\    const run = b.addRunArtifact(gen);
    \\    const table = run.addOutputFileArg("table.zig");
    \\    const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = target,
    \\    }) });
    \\    exe.root_module.addAnonymousImport("table", .{ .root_source_file = table });
    \\    b.installArtifact(exe);
    \\    b.step("check", "Check").dependOn(&exe.step);
    \\}
    \\
;

const cross_gen =
    \\const std = @import("std");
    \\pub const sep = std.fs.path.sep;
    \\pub const log_level = std.options.log_level;
    \\pub fn main(init: std.process.Init) !void {
    \\    const args = try init.minimal.args.toSlice(init.arena.allocator());
    \\    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = "pub const value = 1;\n" });
    \\}
    \\
;

const cross_main =
    \\const std = @import("std");
    \\const builtin = @import("builtin");
    \\const table = @import("table");
    \\pub const std_options: std.Options = .{ .log_level = .err };
    \\pub const os_tag = builtin.os.tag;
    \\pub const sep = std.fs.path.sep;
    \\pub const fd = @typeName(std.posix.fd_t);
    \\pub const log_level = std.options.log_level;
    \\pub fn sepKind() u32 {
    \\    if (std.fs.path.sep == '\\') {
    \\        return 1;
    \\    } else {
    \\        return 2;
    \\    }
    \\}
    \\pub fn main() void {
    \\    _ = sepKind();
    \\    _ = table.value;
    \\}
    \\
;

test "build integration: the standard library is analyzed in the compilation of the file that uses it" {
    var s: Session = undefined;
    try s.start(&.{
        .{ .path = "build.zig", .text = cross_build },
        .{ .path = "tools/gen.zig", .text = cross_gen },
        .{ .path = "src/main.zig", .text = cross_main },
    },
        \\{"build": {"args": ["-Dtarget=x86_64-windows-gnu"]}, "diagnostics": {"inactive_code": true}}
    );
    defer s.finish();
    const main_uri = try s.open("src/main.zig", cross_main);
    const gen_uri = try s.open("tools/gen.zig", cross_gen);
    try s.waitIdle();

    // The values `zig build check -Dtarget=x86_64-windows-gnu` logs for the exe: the host
    // generator, which reaches the standard library too, must not supply them
    try testing.expectEqualStrings("```zig\nconst os_tag: Tag = .windows\n```", try s.hover(main_uri, cross_main, "os_tag ="));
    try testing.expectEqualStrings("```zig\nconst sep: u8 = 92\n```", try s.hover(main_uri, cross_main, "sep ="));
    try testing.expectEqualStrings("```zig\nconst fd: *const [10:0]u8 = \"*anyopaque\"\n```", try s.hover(main_uri, cross_main, "fd ="));
    try testing.expectEqualStrings("```zig\nconst log_level: Level = .err\n```", try s.hover(main_uri, cross_main, "log_level = std"));
    // The branch the Windows compilation takes is not inactive
    try testing.expectEqualSlices(i64, &.{11}, try s.inactiveLines(main_uri));
    // The host generator keeps the host's standard library and its own root
    try testing.expectEqualStrings("```zig\nconst sep: u8 = 47\n```", try s.hover(gen_uri, cross_gen, "sep ="));
    try testing.expectEqualStrings("```zig\nconst log_level: Level = .debug\n```", try s.hover(gen_uri, cross_gen, "log_level ="));
}

const folder_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("main.zig"),
    \\        .target = b.graph.host,
    \\    }) });
    \\    b.installArtifact(exe);
    \\}
    \\
;

const folder_a_main =
    \\const std = @import("std");
    \\pub const std_options: std.Options = .{ .log_level = .err };
    \\pub const lvl = std.options.log_level;
    \\pub fn main() void {}
    \\
;

const folder_b_main =
    \\const std = @import("std");
    \\pub const lvl = std.options.log_level;
    \\pub fn main() void {}
    \\
;

test "build integration: two workspace folders read the standard library with their own root" {
    var s: Session = undefined;
    try s.startFolders(&.{
        .{ .path = "a/build.zig", .text = folder_build },
        .{ .path = "a/main.zig", .text = folder_a_main },
        .{ .path = "b/build.zig", .text = folder_build },
        .{ .path = "b/main.zig", .text = folder_b_main },
    }, &.{ "a", "b" }, "{}");
    defer s.finish();
    const a_uri = try s.open("a/main.zig", folder_a_main);
    const b_uri = try s.open("b/main.zig", folder_b_main);
    try s.waitIdle();

    try testing.expectEqualStrings("```zig\nconst lvl: Level = .err\n```", try s.hover(a_uri, folder_a_main, "lvl ="));
    // b declares no `std_options`: the default, not the first folder's
    try testing.expectEqualStrings("```zig\nconst lvl: Level = .debug\n```", try s.hover(b_uri, folder_b_main, "lvl ="));
}

const layout_build =
    \\const std = @import("std");
    \\pub const bz_usize = @sizeOf(usize);
    \\pub fn build(b: *std.Build) void {
    \\    const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = b.standardTargetOptions(.{}),
    \\    }) });
    \\    b.installArtifact(exe);
    \\    b.step("check", "Check").dependOn(&exe.step);
    \\}
    \\
;

const layout_main =
    \\pub const ps = @sizeOf(usize);
    \\pub fn main() void {}
    \\
;

const layout_orphan =
    \\const builtin = @import("builtin");
    \\pub const s_usize = @sizeOf(usize);
    \\pub const ptr_bits = builtin.target.ptrBitWidth();
    \\pub const s_c_long = @sizeOf(c_long);
    \\pub fn pick() u32 {
    \\    if (@sizeOf(usize) == 8) {
    \\        return 64;
    \\    } else {
    \\        return 32;
    \\    }
    \\}
    \\pub fn main() void {
    \\    _ = pick();
    \\}
    \\
;

test "build integration: files in no compile step get the layout of the host, not of the project target" {
    var s: Session = undefined;
    try s.startFolders(&.{
        .{ .path = "proj/build.zig", .text = layout_build },
        .{ .path = "proj/src/main.zig", .text = layout_main },
        .{ .path = "proj/tools/orphan.zig", .text = layout_orphan },
        .{ .path = "solo/solo.zig", .text = layout_orphan },
    }, &.{ "proj", "solo" },
        \\{"build": {"args": ["-Dtarget=x86-linux"]}, "diagnostics": {"inactive_code": true}}
    );
    defer s.finish();
    const main_uri = try s.open("proj/src/main.zig", layout_main);
    const build_uri = try s.open("proj/build.zig", layout_build);
    const orphan_uri = try s.open("proj/tools/orphan.zig", layout_orphan);
    const solo_uri = try s.open("solo/solo.zig", layout_orphan);
    try s.waitIdle();

    // The project is compiled for x86-linux
    try testing.expectEqualStrings("```zig\nconst ps: comptime_int = 4\n```", try s.hover(main_uri, layout_main, "ps ="));
    // The build runner compiles build.zig for the host
    try testing.expectEqualStrings("```zig\nconst bz_usize: comptime_int = 8\n```", try s.hover(build_uri, layout_build, "bz_usize ="));
    // An unreferenced file and a detached file are compiled for the host too (`zig build-obj`
    // logs 8, 64 and 8 for them); the layout must match their own builtin
    for ([_][]const u8{ orphan_uri, solo_uri }) |u| {
        try testing.expectEqualStrings("```zig\nconst s_usize: comptime_int = 8\n```", try s.hover(u, layout_orphan, "s_usize ="));
        try testing.expectEqualStrings("```zig\nconst ptr_bits: u16 = 64\n```", try s.hover(u, layout_orphan, "ptr_bits ="));
        try testing.expectEqualStrings("```zig\nconst s_c_long: comptime_int = 8\n```", try s.hover(u, layout_orphan, "s_c_long ="));
        try testing.expectEqualSlices(i64, &.{7}, try s.inactiveLines(u));
    }
}

const options_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = b.graph.host,
    \\    }) });
    \\    b.installArtifact(exe);
    \\}
    \\
;

const options_main =
    \\const std = @import("std");
    \\pub const std_options: std.Options = .{ .log_level = .err };
    \\pub const lvl = std.options.log_level;
    \\pub fn main() void {}
    \\
;

const options_orphan =
    \\const std = @import("std");
    \\const root = @import("root");
    \\const lvl = std.options.log_level;
    \\pub fn g() u32 {
    \\    var acc: u32 = 0;
    \\    if (std.options.log_level == .debug) {
    \\        acc += 3;
    \\    } else {
    \\        acc += 4;
    \\    }
    \\    return acc;
    \\}
    \\
;

test "build integration: a file in no compile set does not read the project's std_options" {
    var s: Session = undefined;
    try s.start(&.{
        .{ .path = "build.zig", .text = options_build },
        .{ .path = "src/main.zig", .text = options_main },
        .{ .path = "src/orphan.zig", .text = options_orphan },
    },
        \\{"diagnostics": {"inactive_code": true}}
    );
    defer s.finish();
    const main_uri = try s.open("src/main.zig", options_main);
    const orphan_uri = try s.open("src/orphan.zig", options_orphan);
    try s.waitIdle();

    // The project's own compilation keeps its root
    try testing.expectEqualStrings("```zig\nconst lvl: Level = .err\n```", try s.hover(main_uri, options_main, "lvl ="));
    // Whoever compiles the orphan decides its root (`zig build-obj` and `zig test` give `.debug`):
    // no value and no inactive branch
    try testing.expectEqualStrings("```zig\nconst lvl: Level\n```", try s.hover(orphan_uri, options_orphan, "lvl ="));
    try testing.expectEqualSlices(i64, &.{}, try s.inactiveLines(orphan_uri));
}

const shared_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const common = b.createModule(.{ .root_source_file = b.path("src/common.zig") });
    \\    const gen = b.addExecutable(.{ .name = "gen", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("tools/gen.zig"),
    \\        .target = b.graph.host,
    \\        .imports = &.{.{ .name = "common", .module = common }},
    \\    }) });
    \\    const run = b.addRunArtifact(gen);
    \\    const table = run.addOutputFileArg("table.zig");
    \\    const exe = b.addExecutable(.{ .name = "app", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = target,
    \\        .imports = &.{.{ .name = "common", .module = common }},
    \\    }) });
    \\    exe.root_module.addAnonymousImport("table", .{ .root_source_file = table });
    \\    b.installArtifact(exe);
    \\    b.step("check", "Check").dependOn(&exe.step);
    \\}
    \\
;

const shared_common =
    \\const std = @import("std");
    \\pub const width = @sizeOf(usize);
    \\pub fn helper(x: u32) u32 {
    \\    return x + std.fs.path.sep;
    \\}
    \\
;

const shared_main =
    \\const std = @import("std");
    \\const common = @import("common");
    \\const table = @import("table");
    \\pub const sep = std.fs.path.sep;
    \\pub fn main() void {
    \\    _ = common.helper(2);
    \\    _ = table.value;
    \\}
    \\
;

const shared_gen =
    \\const std = @import("std");
    \\const common = @import("common");
    \\pub const sep = std.fs.path.sep;
    \\pub fn main(init: std.process.Init) !void {
    \\    _ = common.helper(1);
    \\    const args = try init.minimal.args.toSlice(init.arena.allocator());
    \\    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = "pub const value = 1;\n" });
    \\}
    \\
;

test "build integration: results for code analyzed in several compilations map to the real files once" {
    var s: Session = undefined;
    try s.start(&.{
        .{ .path = "build.zig", .text = shared_build },
        .{ .path = "tools/gen.zig", .text = shared_gen },
        .{ .path = "src/main.zig", .text = shared_main },
        .{ .path = "src/common.zig", .text = shared_common },
    },
        \\{"build": {"args": ["-Dtarget=x86-windows-gnu"]}}
    );
    defer s.finish();
    const main_uri = try s.open("src/main.zig", shared_main);
    const gen_uri = try s.open("tools/gen.zig", shared_gen);
    const common_uri = try s.open("src/common.zig", shared_common);
    try s.waitIdle();

    // The file shared by both compilations is analyzed in each, yet it is one file: by itself, it
    // is in the compilation that reaches it first (native compilations first: the generator)
    try testing.expectEqualStrings("```zig\nconst width: comptime_int = 8\n```", try s.hover(common_uri, shared_common, "width ="));
    for ([_][]const u8{ main_uri, gen_uri }) |u| {
        const text = if (u.ptr == main_uri.ptr) shared_main else shared_gen;
        try testing.expect(std.mem.endsWith(u8, try s.definitionPath(u, text, "helper("), "common.zig"));
    }
    try testing.expectEqualStrings("src/common.zig:2 src/main.zig:5 tools/gen.zig:4", try s.references(common_uri, shared_common, "helper("));
    try testing.expectEqualStrings("src/common.zig:2:7 src/main.zig:5:15 tools/gen.zig:4:15", try s.rename(common_uri, shared_common, "helper(", "assist"));
    try testing.expectEqualStrings("2:7", try s.highlights(common_uri, shared_common, "helper("));

    // A declaration of the standard library, which each compilation analyzes separately: one
    // definition in the installed file, and every reference once
    const sep_path = try s.definitionPath(main_uri, shared_main, "sep;");
    try testing.expect(std.mem.endsWith(u8, sep_path, "path.zig"));
    try testing.expectEqualStrings(sep_path, try s.definitionPath(gen_uri, shared_gen, "sep;"));
    try testing.expectEqualStrings(sep_path, try s.definitionPath(common_uri, shared_common, "sep;"));
    try testing.expectEqualStrings("path.zig:135 path.zig:141 path.zig:161 path.zig:27 src/common.zig:3 src/main.zig:3 tools/gen.zig:2", try s.references(main_uri, shared_main, "sep;"));
    // Each use shows the value of its own compilation
    try testing.expect(std.mem.indexOf(u8, try s.hover(main_uri, shared_main, "sep;"), "= 92") != null);
    try testing.expect(std.mem.indexOf(u8, try s.hover(gen_uri, shared_gen, "sep;"), "= 47") != null);
}
