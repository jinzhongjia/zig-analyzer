const std = @import("std");
const builtin = @import("builtin");
const za = @import("zig_analyzer");

/// 级别由配置在运行时决定（`log.level`），编译期不过滤
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = za.util.log.logFn,
};

/// panic 时先把当前线程的上下文（请求、文件、执行中的 query）与调用栈写入日志，再按默认方式结束进程
pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    za.util.log.writePanic(msg, first_trace_addr orelse @returnAddress());
    std.debug.defaultPanic(msg, first_trace_addr orelse @returnAddress());
}

const usage =
    \\Usage: zig-analyzer [options]
    \\
    \\Zig language server (LSP) over stdio.
    \\
    \\Options:
    \\  --version   print version
    \\  --help      print this help
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            try std.Io.File.stdout().writeStreamingAll(io, za.version ++ "\n");
            return 0;
        } else if (std.mem.eql(u8, arg, "--help")) {
            try std.Io.File.stdout().writeStreamingAll(io, usage);
            return 0;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return 1;
        }
    }

    var in_buf: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &in_buf);
    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    var writer: za.lsp.transport.Writer = .{ .io = io, .inner = &stdout.interface };

    // ReleaseSafe 下 `init.gpa` 是查错用的 `SafeAllocator`：每次分配附带元数据与调用栈，小分配所在的桶
    // 要等其中全部释放才归还，长时间运行时常驻内存远超实际使用。只在 Debug 下保留它（退出时报告泄漏）
    const backing = if (builtin.mode == .debug) init.gpa else std.heap.smp_allocator;
    // 统计存活的堆内存（`zig-analyzer/status`）
    var counting: za.util.mem.Counting = .{ .child = backing };
    var server: za.Server = undefined;
    try server.init(io, counting.allocator(), &writer);
    server.heap = &counting;
    defer server.deinit();
    return server.run(&stdin.interface);
}
