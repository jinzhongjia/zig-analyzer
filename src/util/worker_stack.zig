//! Stacks of the server's worker threads (the `std.Io.Threaded` the executable creates). Deep
//! dependency chains of queries run on them, so they are much larger than the default.

const std = @import("std");
const builtin = @import("builtin");

/// Stack a worker thread can use. On Windows this is also the executable's stack reserve
/// (`SizeOfStackReserve`, set by build.zig), which new threads take as their reserve.
pub const size = 64 * 1024 * 1024;

/// Stack a read transaction may use on a worker thread (see `engine.StackBudget`), leaving
/// headroom for the usage between two checks
pub const budget = 48 * 1024 * 1024;

/// The `stack_size` given to `std.Io.Threaded`.
///
/// POSIX: `std.Thread` maps a stack of this size, which takes only address space until it is
/// used.
///
/// Windows: `std.Thread` passes `stack_size` to `NtCreateThreadEx` as the initial commit, with the
/// executable's default reserve. Committed stack is charged against the system commit limit at
/// once and for the life of the thread (and pool workers live until the server exits), so
/// workers get the smallest commit `std.Thread` passes (64 KiB) and the reserve of `size` from
/// the executable; the stack is committed as it grows, up to the reserve.
pub const threaded_stack_size = if (builtin.os.tag == .windows) 64 * 1024 else size;

const testing = std.testing;

const windows_probe = struct {
    const windows = std.os.windows;

    /// x64 / arm64 layout
    const MEMORY_BASIC_INFORMATION = extern struct {
        BaseAddress: ?*anyopaque,
        AllocationBase: ?*anyopaque,
        AllocationProtect: u32,
        PartitionId: u16,
        RegionSize: usize,
        State: u32,
        Protect: u32,
        Type: u32,
    };
    extern "kernel32" fn VirtualQuery(address: ?*const anyopaque, buffer: *MEMORY_BASIC_INFORMATION, length: usize) callconv(.winapi) usize;

    /// Private memory the process has committed (its commit charge)
    fn commitCharge() !usize {
        var counters: windows.PROCESS.VM_COUNTERS = undefined;
        switch (windows.ntdll.NtQueryInformationProcess(windows.GetCurrentProcess(), .VmCounters, &counters, @sizeOf(windows.PROCESS.VM_COUNTERS), null)) {
            .SUCCESS => return counters.PagefileUsage,
            else => return error.CannotQueryCommitCharge,
        }
    }

    const Probe = struct {
        /// Address space reserved for the stack of the thread that ran `run`
        reserved: usize = 0,
        /// Commit charge of the process while that thread exists
        commit: usize = 0,
        failed: bool = false,

        fn run(p: *Probe) void {
            var local: u8 = 0;
            std.mem.doNotOptimizeAway(&local);
            var info: MEMORY_BASIC_INFORMATION = undefined;
            if (VirtualQuery(&local, &info, @sizeOf(MEMORY_BASIC_INFORMATION)) == 0) {
                p.failed = true;
                return;
            }
            p.reserved = @intFromPtr(windows.teb().NtTib.StackBase) - @intFromPtr(info.AllocationBase);
            p.commit = commitCharge() catch {
                p.failed = true;
                return;
            };
        }
    };
};

test "worker stacks reserve their full size but commit only what they use" {
    // Each worker thread committed its whole 64 MiB stack on Windows for as long as it lived
    if (builtin.os.tag != .windows or @sizeOf(usize) != 8) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .stack_size = threaded_stack_size });
    defer threaded.deinit();
    const io = threaded.io();
    const before = try windows_probe.commitCharge();
    var probe: windows_probe.Probe = .{};
    var task = try io.concurrent(windows_probe.Probe.run, .{&probe});
    task.await(io);
    try testing.expect(!probe.failed);
    try testing.expect(probe.reserved >= size);
    try testing.expect(probe.commit -| before < size / 4);
}
