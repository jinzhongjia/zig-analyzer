//! Mutex for very short critical sections taken at a high rate by several threads (the metadata
//! of the query engine, the InternPool): a thread that finds it held first spins briefly, and
//! sleeps only when it stays held.
//!
//! `Io.Mutex` puts a waiting thread to sleep on a futex right away, and the next unlock then has
//! to wake it with another system call. When the critical sections are much shorter than a sleep
//! and a wakeup, two threads taking the lock in quick succession keep sleeping and waking each
//! other (a lock convoy), and spend most of their time in the kernel instead of computing.

const std = @import("std");
const Io = std.Io;

const SpinMutex = @This();

inner: Io.Mutex = .init,

/// Attempts to take the lock before sleeping; each attempt waits one `spinLoopHint`
const spins = 100;

pub fn lockUncancelable(m: *SpinMutex, io: Io) void {
    if (m.inner.tryLock()) return;
    for (0..spins) |_| {
        std.atomic.spinLoopHint();
        if (m.inner.state.load(.monotonic) == .unlocked and m.inner.tryLock()) return;
    }
    m.inner.lockUncancelable(io);
}

pub fn unlock(m: *SpinMutex, io: Io) void {
    m.inner.unlock(io);
}

test "excludes concurrent increments" {
    const io = std.testing.io;
    var m: SpinMutex = .{};
    var n: usize = 0;
    const Worker = struct {
        fn run(mm: *SpinMutex, nn: *usize) void {
            for (0..10_000) |_| {
                mm.lockUncancelable(std.testing.io);
                defer mm.unlock(std.testing.io);
                nn.* += 1;
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &m, &n });
    for (threads) |t| t.join();
    m.lockUncancelable(io);
    defer m.unlock(io);
    try std.testing.expectEqual(40_000, n);
}
