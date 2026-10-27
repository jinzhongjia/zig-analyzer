//! Watches the client process (the `processId` of `initialize`): when it exits, the server exits
//! too. When the client exits, stdin is usually closed as well (see `Server.run`), but the write
//! end of the pipe may be inherited by other child processes of the client and never be closed.
//!
//! Waits for the operating system's process exit notification: a pidfd on Linux (since kernel
//! 5.3), kqueue's `EVFILT_PROC` on macOS and BSD, and the process handle on Windows. Polling
//! (periodically checking whether the process still exists) is the last resort, used only when
//! none of these is available (old kernel, forbidden by a sandbox, no permission to open the
//! process, other platforms).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.server);

pub const Outcome = enum {
    /// The client process has exited (or no longer existed when opened)
    exited,
    /// Ended by `stop` (the server is shutting down)
    stopped,
};

pub const Watch = struct {
    io: Io,
    pid: i32,
    native: ?Native,
    /// The process no longer existed when opened
    gone: bool = false,
    /// Polling interval (milliseconds)
    poll_interval_ms: u32 = 2000,
    // ── Stop notification while polling ──
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    stopped: bool = false,

    /// Created before the task that calls `wait` starts: a later `stop` is not lost
    pub fn create(gpa: Allocator, io: Io, pid: i32) Allocator.Error!*Watch {
        const w = try gpa.create(Watch);
        w.* = .{ .io = io, .pid = pid, .native = null };
        switch (Native.open(pid)) {
            .watching => |n| w.native = n,
            .gone => w.gone = true,
            .unavailable => |why| if (Native != Unsupported) log.warn("cannot wait for the client process {d} to exit ({s}), checking it periodically instead", .{ pid, why }),
        }
        return w;
    }

    /// Called after `wait` returns
    pub fn destroy(w: *Watch, gpa: Allocator) void {
        if (w.native) |*n| n.close();
        gpa.destroy(w);
    }

    /// Waits until the client process exits or `stop` ends the wait
    pub fn wait(w: *Watch) Outcome {
        if (w.gone) return .exited;
        if (w.native) |*n| {
            if (n.wait()) |outcome| return outcome;
            log.warn("waiting for the client process {d} to exit failed, checking it periodically instead", .{w.pid});
        }
        return w.poll();
    }

    /// Makes `wait` return `.stopped`; can be called from any thread, and also takes effect when
    /// called before `wait`
    pub fn stop(w: *Watch) void {
        {
            w.mutex.lockUncancelable(w.io);
            defer w.mutex.unlock(w.io);
            w.stopped = true;
        }
        w.cond.signal(w.io);
        if (w.native) |*n| n.stop();
    }

    /// Polling: checks whether the process still exists every `poll_interval_ms`
    fn poll(w: *Watch) Outcome {
        w.mutex.lockUncancelable(w.io);
        defer w.mutex.unlock(w.io);
        while (!w.stopped) {
            w.cond.waitTimeout(w.io, &w.mutex, .{ .duration = .{ .raw = .fromMilliseconds(w.poll_interval_ms), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return .stopped,
            };
            if (w.stopped) break;
            if (!processAlive(w.pid)) return .exited;
        }
        return .stopped;
    }
};

/// Result of opening the native notification
fn Open(comptime T: type) type {
    return union(enum) {
        watching: T,
        /// The process no longer exists
        gone,
        /// The native notification is unavailable (the reason)
        unavailable: []const u8,
    };
}

const Native = switch (builtin.os.tag) {
    .linux => Pidfd,
    .macos, .freebsd, .netbsd, .openbsd => Kqueue,
    .windows => ProcessHandle,
    else => Unsupported,
};

const Unsupported = struct {
    fn open(_: i32) Open(Unsupported) {
        return .{ .unavailable = "unsupported platform" };
    }
    fn wait(_: *Unsupported) ?Outcome {
        unreachable;
    }
    fn stop(_: *Unsupported) void {
        unreachable;
    }
    fn close(_: *Unsupported) void {
        unreachable;
    }
};

/// Linux: the pidfd becomes readable once the process exits; an eventfd is used for stopping
const Pidfd = struct {
    const linux = std.os.linux;

    pidfd: linux.fd_t,
    stop_fd: linux.fd_t,

    fn open(pid: i32) Open(Pidfd) {
        const rc = linux.pidfd_open(pid, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .SRCH => return .gone,
            else => |err| return .{ .unavailable = @tagName(err) },
        }
        const pidfd: linux.fd_t = @intCast(rc);
        const stop_rc = linux.eventfd(0, linux.EFD.CLOEXEC);
        if (linux.errno(stop_rc) != .SUCCESS) {
            _ = linux.close(pidfd);
            return .{ .unavailable = "eventfd" };
        }
        return .{ .watching = .{ .pidfd = pidfd, .stop_fd = @intCast(stop_rc) } };
    }

    fn wait(p: *Pidfd) ?Outcome {
        var fds = [_]std.posix.pollfd{
            .{ .fd = p.pidfd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = p.stop_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.posix.poll(&fds, -1) catch return null;
        if (fds[1].revents != 0) return .stopped;
        if (fds[0].revents != 0) return .exited;
        return null;
    }

    fn stop(p: *Pidfd) void {
        const one: u64 = 1;
        _ = linux.write(p.stop_fd, @ptrCast(&one), @sizeOf(u64));
    }

    fn close(p: *Pidfd) void {
        _ = linux.close(p.pidfd);
        _ = linux.close(p.stop_fd);
    }
};

/// macOS and BSD: kqueue waits for the process's `NOTE_EXIT`; a pipe is used for stopping
const Kqueue = struct {
    const c = std.c;
    const Kevent = std.posix.Kevent;
    /// udata that tells the two events apart
    const exit_tag = 0;
    const stop_tag = 1;

    kq: c.fd_t,
    pipe: [2]c.fd_t,

    fn open(pid: i32) Open(Kqueue) {
        const kq = c.kqueue();
        if (kq < 0) return .{ .unavailable = "kqueue" };
        var pipe: [2]c.fd_t = undefined;
        if (c.pipe(&pipe) != 0) {
            _ = c.close(kq);
            return .{ .unavailable = "pipe" };
        }
        const changes = [_]Kevent{
            .{
                .ident = @intCast(pid),
                .filter = c.EVFILT.PROC,
                .flags = c.EV.ADD | c.EV.ONESHOT,
                .fflags = c.NOTE.EXIT,
                .data = 0,
                .udata = exit_tag,
            },
            .{
                .ident = @intCast(pipe[0]),
                .filter = c.EVFILT.READ,
                .flags = c.EV.ADD,
                .fflags = 0,
                .data = 0,
                .udata = stop_tag,
            },
        };
        var none: [0]Kevent = .{};
        const rc = c.kevent(kq, &changes, changes.len, &none, 0, null);
        if (rc < 0) {
            const err = std.posix.errno(rc);
            _ = c.close(kq);
            _ = c.close(pipe[0]);
            _ = c.close(pipe[1]);
            return if (err == .SRCH) .gone else .{ .unavailable = @tagName(err) };
        }
        return .{ .watching = .{ .kq = kq, .pipe = pipe } };
    }

    fn wait(k: *Kqueue) ?Outcome {
        var none: [0]Kevent = .{};
        var events: [1]Kevent = undefined;
        while (true) {
            const rc = c.kevent(k.kq, &none, 0, &events, events.len, null);
            if (rc < 0) switch (std.posix.errno(rc)) {
                .INTR => continue,
                else => return null,
            };
            if (rc == 0) continue;
            return if (events[0].udata == stop_tag) .stopped else .exited;
        }
    }

    fn stop(k: *Kqueue) void {
        _ = c.write(k.pipe[1], "x", 1);
    }

    fn close(k: *Kqueue) void {
        _ = c.close(k.kq);
        _ = c.close(k.pipe[0]);
        _ = c.close(k.pipe[1]);
    }
};

/// Windows: the process handle becomes signaled once the process exits; an event object is
/// used for stopping
const ProcessHandle = struct {
    process: *anyopaque,
    stop_event: *anyopaque,

    fn open(pid: i32) Open(ProcessHandle) {
        const windows = std.os.windows;
        const process = win32.OpenProcess(win32.SYNCHRONIZE, 0, @bitCast(pid)) orelse
            return if (windows.GetLastError() == .INVALID_PARAMETER) .gone else .{ .unavailable = "OpenProcess" };
        const event = win32.CreateEventW(null, 1, 0, null) orelse {
            windows.CloseHandle(process);
            return .{ .unavailable = "CreateEventW" };
        };
        return .{ .watching = .{ .process = process, .stop_event = event } };
    }

    fn wait(p: *ProcessHandle) ?Outcome {
        const handles = [_]*anyopaque{ p.process, p.stop_event };
        return switch (win32.WaitForMultipleObjects(handles.len, &handles, 0, win32.INFINITE)) {
            win32.WAIT_OBJECT_0 => .exited,
            win32.WAIT_OBJECT_0 + 1 => .stopped,
            else => null,
        };
    }

    fn stop(p: *ProcessHandle) void {
        _ = win32.SetEvent(p.stop_event);
    }

    fn close(p: *ProcessHandle) void {
        std.os.windows.CloseHandle(p.process);
        std.os.windows.CloseHandle(p.stop_event);
    }
};

/// Whether the process is still running; when this cannot be determined (e.g. no permission),
/// it is treated as still running
fn processAlive(pid: i32) bool {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const handle = win32.OpenProcess(win32.SYNCHRONIZE, 0, @bitCast(pid)) orelse
            return windows.GetLastError() != .INVALID_PARAMETER;
        defer windows.CloseHandle(handle);
        // A process that has exited is in the signaled state
        return win32.WaitForSingleObject(handle, 0) != win32.WAIT_OBJECT_0;
    }
    // Signal 0 only checks whether the process exists
    std.posix.kill(pid, @fromBackingInt(@intCast(0))) catch |err| return err != error.ProcessNotFound;
    return true;
}

const win32 = struct {
    const SYNCHRONIZE: u32 = 0x00100000;
    const WAIT_OBJECT_0: u32 = 0;
    const INFINITE: u32 = 0xFFFFFFFF;
    extern "kernel32" fn OpenProcess(access: u32, inherit: c_int, pid: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn WaitForSingleObject(handle: *anyopaque, ms: u32) callconv(.winapi) u32;
    extern "kernel32" fn WaitForMultipleObjects(count: u32, handles: [*]const *anyopaque, wait_all: c_int, ms: u32) callconv(.winapi) u32;
    extern "kernel32" fn CreateEventW(attributes: ?*anyopaque, manual_reset: c_int, initial_state: c_int, name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn SetEvent(event: *anyopaque) callconv(.winapi) c_int;
};

const testing = std.testing;

/// For tests: a child process that exits once its stdin is closed
fn spawnChild() !std.process.Child {
    return std.process.spawn(testing.io, .{ .argv = &.{ "/bin/sh", "-c", "read line" }, .stdin = .pipe, .stdout = .ignore, .stderr = .ignore });
}

fn finishChild(child: *std.process.Child) void {
    if (child.stdin) |s| s.close(testing.io);
    child.stdin = null;
    _ = child.wait(testing.io) catch {};
}

test "processAlive: a running child process, then its pid after it has been reaped" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var child = try spawnChild();
    const pid = child.id.?;
    try testing.expect(processAlive(pid));
    finishChild(&child);
    try testing.expect(!processAlive(pid));
}

test "watch: the exit of the process ends the wait" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var child = try spawnChild();
    defer finishChild(&child);
    const w = try Watch.create(testing.allocator, testing.io, child.id.?);
    defer w.destroy(testing.allocator);
    if (Native != Unsupported) try testing.expect(w.native != null);
    // Closing stdin makes the child exit (the exit notification arrives before it is reaped)
    child.stdin.?.close(testing.io);
    child.stdin = null;
    try testing.expectEqual(Outcome.exited, w.wait());
}

test "watch: stop ends the wait, also when it comes first" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var child = try spawnChild();
    defer finishChild(&child);
    const w = try Watch.create(testing.allocator, testing.io, child.id.?);
    defer w.destroy(testing.allocator);
    w.stop();
    try testing.expectEqual(Outcome.stopped, w.wait());
}

test "watch: a process that no longer exists counts as exited" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var child = try spawnChild();
    const pid = child.id.?;
    finishChild(&child);
    const w = try Watch.create(testing.allocator, testing.io, pid);
    defer w.destroy(testing.allocator);
    try testing.expect(w.gone);
    try testing.expectEqual(Outcome.exited, w.wait());
}

test "watch: without native notification, the process is checked periodically" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var child = try spawnChild();
    var w: Watch = .{ .io = testing.io, .pid = child.id.?, .native = null, .poll_interval_ms = 20 };
    // An exited but unreaped process (a zombie) still exists; the check detects the exit only
    // after it is reaped
    finishChild(&child);
    try testing.expectEqual(Outcome.exited, w.wait());

    var other = try spawnChild();
    defer finishChild(&other);
    var s: Watch = .{ .io = testing.io, .pid = other.id.?, .native = null };
    s.stop();
    try testing.expectEqual(Outcome.stopped, s.wait());
}
