//! Generates the test runner from the runner bundled with Zig:
//!
//! - The bundled runner records allocation stack traces for the testing allocator only in Debug,
//!   so under ReleaseSafe leak reports have no stack trace (which makes occasional leaks on CI
//!   impossible to track down). This adds a stack trace frame count to its allocator options.
//! - Tests that take at least `slow_seconds` are reported on stderr with their duration, so that
//!   slow tests on CI runners can be identified from the log.
//!
//! Usage: patch_test_runner <input test_runner.zig> <output>; a patch whose anchor is not found is
//! left out (with a warning)

const std = @import("std");

const slow_seconds = 10;

const Patch = struct { anchor: []const u8, replacement: []const u8, what: []const u8 };

const patches = [_]Patch{
    .{
        .anchor = ".check_write_after_free = true,",
        .replacement = ".check_write_after_free = true, .stack_trace_frames = 12,",
        .what = "stack traces of leaks stay disabled",
    },
    .{
        .anchor = "try server.serveStringMessage(.test_started, &.{});",
        .replacement = "try server.serveStringMessage(.test_started, &.{});\n" ++
            "                const za_test_start = std.Io.Clock.awake.now(testing.io);",
        .what = "slow tests are not reported",
    },
    .{
        .anchor = "testing.io_instance.deinit();\n                const leak_count",
        .replacement = std.fmt.comptimePrint(
            \\{{
            \\                    const za_elapsed = za_test_start.durationTo(std.Io.Clock.awake.now(testing.io)).toSeconds();
            \\                    if (za_elapsed >= {d}) std.debug.print("slow test ({{d}}s): {{s}}\n", .{{ za_elapsed, test_fn.name }});
            \\                }}
            \\                testing.io_instance.deinit();
            \\                const leak_count
        , .{slow_seconds}),
        .what = "slow tests are not reported",
    },
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const a = init.arena.allocator();
    var text = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .unlimited);
    // The two parts of the slow test report only work together
    var timing = true;
    for (patches[1..]) |p| {
        if (std.mem.indexOf(u8, text, p.anchor) == null) timing = false;
    }
    for (patches, 0..) |p, i| {
        if (i > 0 and !timing) {
            if (i == 1) std.log.warn("test runner code not found, {s}", .{p.what});
            continue;
        }
        const patched = try std.mem.replaceOwned(u8, a, text, p.anchor, p.replacement);
        if (std.mem.eql(u8, patched, text)) std.log.warn("test runner code not found, {s}", .{p.what});
        text = patched;
    }
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = text });
}
