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

/// 服务器工作线程的栈大小：只占地址空间，用到的部分才分配内存
const worker_stack_size = 64 * 1024 * 1024;
/// 工作线程上读事务可占用的栈（见 `engine.StackBudget`），为两次检查之间的占用留出余量
const worker_stack_budget = 48 * 1024 * 1024;

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
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            try std.Io.File.stdout().writeStreamingAll(init.io, za.version ++ "\n");
            return 0;
        } else if (std.mem.eql(u8, arg, "--help")) {
            try std.Io.File.stdout().writeStreamingAll(init.io, usage);
            return 0;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return 1;
        }
    }

    // ReleaseSafe 下 `init.gpa` 是查错用的 `SafeAllocator`：每次分配附带元数据与调用栈，小分配所在的桶
    // 要等其中全部释放才归还，长时间运行时常驻内存远超实际使用。只在 Debug 下保留它（退出时报告泄漏）。
    // 不用 `std.heap.smp_allocator`：它的空闲链表按线程槽位分开，缓存值在工作线程上分配、在清扫的线程上释放，
    // 释放的块分配方取不到，常驻内存随会话持续增长（见 `SharedAllocator`）
    const backing = if (builtin.mode == .debug) init.gpa else za.util.SharedAllocator.allocator;
    // 不用 `init.io`：它的工作线程的栈是默认大小，很深的依赖链要多次中断、分段计算
    var threaded: std.Io.Threaded = .init(backing, .{
        .stack_size = worker_stack_size,
        .argv0 = .init(init.minimal.args),
        .environ = init.minimal.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var in_buf: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &in_buf);
    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    var writer: za.lsp.transport.Writer = .{ .io = io, .inner = &stdout.interface };

    // 统计存活的堆内存（`zig-analyzer/status`）
    var counting: za.util.mem.Counting = .{ .child = backing };
    var server: za.Server = undefined;
    try server.init(io, counting.allocator(), &writer);
    // 请求在工作线程上执行；无法创建工作线程时在调用方的线程（可能是主线程）上执行，主线程仍按默认的栈上限
    server.db.stack_budget = .{ .main = std.Thread.getCurrentId(), .worker_bytes = worker_stack_budget };
    server.heap = &counting;
    server.environ = init.minimal.environ;
    defer server.deinit();
    return server.run(&stdin.interface);
}
