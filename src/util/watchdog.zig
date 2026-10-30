//! Wait timeout for external processes: when the time is up, ends the child process (SIGKILL on
//! POSIX, `NtTerminateProcess` on Windows) so that calls blocked on a pipe read or wait return.
//! Child processes can get stuck in wrapper scripts (asdf, mise, zig on a network file system),
//! and without a timeout the shutdown would wait forever.

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

    /// `id` identifies a direct child process (its pid on POSIX, its process handle on Windows):
    /// only the value is passed, with no concurrent access to the other state of `Child`. It
    /// must stay valid until `stop` returns, so `stop` is called before the child is waited for
    /// or killed (which reaps the pid or closes the handle).
    pub fn start(w: *Watchdog, io: Io, id: std.process.Child.Id, timeout: Io.Timeout) void {
        if (builtin.os.tag == .wasi or timeout == .none) return;
        w.* = .{ .io = io };
        w.thread = std.Thread.spawn(.{}, run, .{ w, id, timeout }) catch null;
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

    fn run(w: *Watchdog, id: std.process.Child.Id, timeout: Io.Timeout) void {
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
        if (expired) terminate(id);
    }

    fn terminate(id: std.process.Child.Id) void {
        switch (builtin.os.tag) {
            .windows => _ = std.os.windows.ntdll.NtTerminateProcess(id, @fromBackingInt(killed_exit_code)),
            else => std.posix.kill(id, std.posix.SIG.KILL) catch {},
        }
    }

    /// Exit code of a child process the watchdog ended on Windows
    pub const killed_exit_code = 1;
};

const testing = std.testing;

/// A child process that runs for a minute unless ended
fn spawnHung() !std.process.Child {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "ping", "-n", "61", "127.0.0.1" },
        else => &.{ "sleep", "60" },
    };
    return std.process.spawn(testing.io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
}

test "watchdog kills a hung child" {
    // A watchdog that does nothing on Windows lets a hung zig child block shutdown forever
    if (builtin.os.tag == .wasi) return error.SkipZigTest;
    var c = try spawnHung();
    defer c.kill(testing.io);
    const started = Io.Clock.awake.now(testing.io);
    var w: Watchdog = .{};
    w.start(testing.io, c.id.?, .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(100), .clock = .awake } });
    defer w.stop();
    const term = try c.wait(testing.io);
    switch (builtin.os.tag) {
        .windows => try testing.expectEqual(std.process.Child.Term{ .exited = Watchdog.killed_exit_code }, term),
        else => switch (term) {
            .signal => |sig| try testing.expectEqual(std.posix.SIG.KILL, sig),
            else => return error.ChildDidNotTimeOut,
        },
    }
    try testing.expect(started.untilNow(testing.io, .awake).toSeconds() < 10);
}

test "watchdog leaves a finished child alone" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "cmd.exe", "/c", "exit 0" },
        else => &.{"true"},
    };
    var c = try std.process.spawn(testing.io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    defer c.kill(testing.io);
    var w: Watchdog = .{};
    w.start(testing.io, c.id.?, .{ .duration = .{ .raw = Io.Duration.fromSeconds(5), .clock = .awake } });
    const term = try c.wait(testing.io);
    w.stop();
    try testing.expect(term.success());
}
