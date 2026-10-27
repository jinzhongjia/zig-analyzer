//! Wait timeout for external processes: when the time is up, sends SIGKILL to the pid so that calls
//! blocked on a pipe read or wait return. Child processes can get stuck in wrapper scripts (asdf,
//! mise, zig on a network file system), and without a timeout the shutdown would wait forever.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

pub const Watchdog = struct {
    io: Io = undefined,
    thread: ?std.Thread = null,
    state: State = .{},

    const State = struct {
        mutex: Io.Mutex = .init,
        cond: Io.Condition = .init,
        done: bool = false,
    };

    /// `pid` is the pid of a direct child process: only the value is passed, with no concurrent
    /// access to the other state of `Child`
    pub fn start(w: *Watchdog, io: Io, pid: std.process.Child.Id, timeout: Io.Timeout) void {
        switch (builtin.os.tag) {
            .windows, .wasi => {},
            else => {
                if (timeout == .none) return;
                w.* = .{ .io = io };
                const unix_pid: std.posix.pid_t = pid;
                w.thread = std.Thread.spawn(.{}, run, .{ w, unix_pid, timeout }) catch null;
            },
        }
    }

    /// Cancels the watchdog and waits for it to exit; called after the child process exits normally
    pub fn stop(w: *Watchdog) void {
        const thread = w.thread orelse return;
        w.state.mutex.lockUncancelable(w.io);
        w.state.done = true;
        w.state.cond.broadcast(w.io);
        w.state.mutex.unlock(w.io);
        thread.join();
        w.thread = null;
    }

    fn run(w: *Watchdog, pid: std.posix.pid_t, timeout: Io.Timeout) void {
        const io = w.io;
        const deadline = timeout.toDeadline(io);
        var expired = false;
        w.state.mutex.lockUncancelable(io);
        while (!w.state.done) {
            w.state.cond.waitTimeout(io, &w.state.mutex, deadline) catch |err| switch (err) {
                error.Timeout => {
                    expired = true;
                    break;
                },
                error.Canceled => {},
            };
        }
        w.state.mutex.unlock(io);
        if (expired) std.posix.kill(pid, std.posix.SIG.KILL) catch {};
    }
};

const testing = std.testing;

test "watchdog kills a hung child" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const child = try std.process.spawn(testing.io, .{ .argv = &.{ "sleep", "60" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    var c = child;
    defer c.kill(testing.io);
    var w: Watchdog = .{};
    w.start(testing.io, c.id.?, .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(100), .clock = .awake } });
    defer w.stop();
    const term = try c.wait(testing.io);
    switch (term) {
        .signal => |sig| try testing.expectEqual(std.posix.SIG.KILL, sig),
        else => return error.ChildDidNotTimeOut,
    }
}

test "watchdog leaves a finished child alone" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const child = try std.process.spawn(testing.io, .{ .argv = &.{"true"}, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    var c = child;
    defer c.kill(testing.io);
    var w: Watchdog = .{};
    w.start(testing.io, c.id.?, .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(500), .clock = .awake } });
    const term = try c.wait(testing.io);
    w.stop();
    try testing.expect(term.success());
}
