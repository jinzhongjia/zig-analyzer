const std = @import("std");
const builtin = @import("builtin");
const za = @import("zig_analyzer");

/// The level is decided at runtime by the configuration (`log.level`); no compile-time filtering
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = za.util.log.logFn,
};

/// On panic, first writes the current thread's context (request, file, running queries) and the
/// stack trace to the log, then ends the process in the default way
pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    za.util.log.writePanic(msg, first_trace_addr orelse @returnAddress());
    std.debug.defaultPanic(msg, first_trace_addr orelse @returnAddress());
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    switch (za.lsp.cli.parse(args[1..])) {
        .serve => {},
        .version => {
            try std.Io.File.stdout().writeStreamingAll(init.io, za.version ++ "\n");
            return 0;
        },
        .help => {
            try std.Io.File.stdout().writeStreamingAll(init.io, za.lsp.cli.usage);
            return 0;
        },
        .invalid => |invalid| {
            std.log.err("{f}", .{invalid});
            return 1;
        },
    }

    // In ReleaseSafe, `init.gpa` is the error-checking `SafeAllocator`: every allocation carries
    // metadata and a stack trace, and a bucket of small allocations is returned only once all of
    // them are freed, so over a long run the resident memory far exceeds actual usage. It is kept
    // only in Debug (where it reports leaks at exit).
    // `std.heap.smp_allocator` is not used: its free lists are split by thread slot, and cached
    // values are allocated on worker threads but freed on the sweeping thread, so the allocating
    // side cannot get the freed blocks back, and the resident memory keeps growing over the
    // session (see `PagedAllocator`)
    const backing = if (builtin.mode == .debug) init.gpa else za.util.PagedAllocator.allocator;
    // `init.io` is not used: its worker threads have the default stack size, so a very deep
    // dependency chain would have to be interrupted many times and computed in segments
    var threaded: std.Io.Threaded = .init(backing, .{
        .stack_size = za.util.worker_stack.threaded_stack_size,
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

    // Counts the live heap memory (`zig-analyzer/status`)
    var counting: za.util.mem.Counting = .{ .child = backing };
    var server: za.Server = undefined;
    try server.init(io, counting.allocator(), &writer);
    // Requests run on worker threads; when no worker thread can be created, they run on the
    // caller's thread (possibly the main thread), and the main thread still has the default
    // stack limit
    server.db.stack_budget = .{ .main = std.Thread.getCurrentId(), .worker_bytes = za.util.worker_stack.budget };
    server.heap = &counting;
    if (builtin.mode != .debug) server.allocator_stats = &za.util.PagedAllocator.stats;
    server.environ = init.minimal.environ;
    defer server.deinit();
    return server.run(&stdin.interface);
}
