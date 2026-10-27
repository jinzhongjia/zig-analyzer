//! Generates the test runner: the runner bundled with Zig records allocation stack traces for the
//! testing allocator only in Debug, so under ReleaseSafe leak reports have no stack trace (which
//! makes occasional leaks on CI impossible to track down). This adds a stack trace frame count to
//! its allocator options.
//!
//! Usage: patch_test_runner <input test_runner.zig> <output>; when the option to modify is not
//! found, the input is written out unchanged

const std = @import("std");

const needle = ".check_write_after_free = true,";
const frames = " .stack_trace_frames = 12,";

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const a = init.arena.allocator();
    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .unlimited);
    const patched = try std.mem.replaceOwned(u8, a, text, needle, needle ++ frames);
    if (std.mem.eql(u8, patched, text)) std.log.warn("test runner options not found, stack traces of leaks stay disabled", .{});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = patched });
}
