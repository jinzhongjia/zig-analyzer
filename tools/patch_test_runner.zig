//! 生成测试运行器：Zig 自带的运行器只在 Debug 下为测试分配器记录分配处的调用栈，ReleaseSafe 下
//! 泄漏报告没有调用栈（CI 上偶发的泄漏因此无从定位）。这里给它的分配器选项加上调用栈帧数。
//!
//! 用法：patch_test_runner <输入 test_runner.zig> <输出>；找不到要修改的选项时原样输出

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
