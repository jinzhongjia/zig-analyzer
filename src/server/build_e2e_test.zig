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
        s.project = try fixture.Project.create(files);
        errdefer s.project.deinit();
        try s.h.start();
        const a = s.h.arena.allocator();
        const root_uri = try za.base.uri.fromPath(a, s.project.root);
        const init_options = try std.json.parseFromSliceLeaky(std.json.Value, a, options, .{});
        _ = try s.h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{}, .initializationOptions = init_options });
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
        const a = s.h.arena.allocator();
        const resp = try s.h.request("textDocument/references", .{ .textDocument = .{ .uri = u }, .position = position(text, needle, 0), .context = .{ .includeDeclaration = true } });
        var out: std.ArrayList([]const u8) = .empty;
        for (resp.object.get("result").?.array.items) |l| try out.append(a, try s.label(l.object.get("uri").?.string, l.object.get("range").?));
        std.mem.sort([]const u8, out.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        return std.mem.join(a, " ", out.items);
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
