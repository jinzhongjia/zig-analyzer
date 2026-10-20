//! 监视客户端进程（`initialize` 的 `processId`）：它退出后服务器随之退出。客户端退出时 stdin 通常随之关闭（见
//! `Server.run`），但管道的写端可能被客户端的其他子进程继承而一直不关闭。
//!
//! 等待操作系统的进程退出通知：Linux 用 pidfd（内核 5.3 起），macOS 与 BSD 用 kqueue 的 `EVFILT_PROC`，Windows 等待
//! 进程句柄。都用不了时（内核较旧、沙箱禁止、没有权限打开进程、其他平台）才定期检查进程是否还在（轮询），这是最后的退路。

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.server);

pub const Outcome = enum {
    /// 客户端进程已退出（或打开时已经不存在）
    exited,
    /// 被 `stop` 结束（服务器关闭）
    stopped,
};

pub const Watch = struct {
    io: Io,
    pid: i32,
    native: ?Native,
    /// 打开时进程已经不存在
    gone: bool = false,
    /// 轮询的间隔（毫秒）
    poll_interval_ms: u32 = 2000,
    // ── 轮询时的停止通知 ──
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    stopped: bool = false,

    /// 在调用 `wait` 的任务开始之前创建：之后的 `stop` 不会丢失
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

    /// `wait` 返回后调用
    pub fn destroy(w: *Watch, gpa: Allocator) void {
        if (w.native) |*n| n.close();
        gpa.destroy(w);
    }

    /// 等到客户端进程退出，或被 `stop` 结束
    pub fn wait(w: *Watch) Outcome {
        if (w.gone) return .exited;
        if (w.native) |*n| {
            if (n.wait()) |outcome| return outcome;
            log.warn("waiting for the client process {d} to exit failed, checking it periodically instead", .{w.pid});
        }
        return w.poll();
    }

    /// 让 `wait` 返回 `.stopped`；任何线程都可以调用，在 `wait` 之前调用也有效
    pub fn stop(w: *Watch) void {
        {
            w.mutex.lockUncancelable(w.io);
            defer w.mutex.unlock(w.io);
            w.stopped = true;
        }
        w.cond.signal(w.io);
        if (w.native) |*n| n.stop();
    }

    /// 轮询：每隔 `poll_interval_ms` 检查一次进程是否还在
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

/// 打开原生通知的结果
fn Open(comptime T: type) type {
    return union(enum) {
        watching: T,
        /// 进程已经不存在
        gone,
        /// 原生通知不可用（原因）
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

/// Linux：进程退出后 pidfd 变为可读；eventfd 用于停止
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

/// macOS 与 BSD：kqueue 等待进程的 `NOTE_EXIT`；管道用于停止
const Kqueue = struct {
    const c = std.c;
    const Kevent = std.posix.Kevent;
    /// 区分两个事件的 udata
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

/// Windows：进程退出后进程句柄变为有信号；事件对象用于停止
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

/// 进程是否仍在运行；无法确定时（如没有权限）按仍在运行处理
fn processAlive(pid: i32) bool {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const handle = win32.OpenProcess(win32.SYNCHRONIZE, 0, @bitCast(pid)) orelse
            return windows.GetLastError() != .INVALID_PARAMETER;
        defer windows.CloseHandle(handle);
        // 已退出的进程处于有信号状态
        return win32.WaitForSingleObject(handle, 0) != win32.WAIT_OBJECT_0;
    }
    // 信号 0 只检查进程是否存在
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

/// 测试用：stdin 关闭后退出的子进程
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
    // 关闭 stdin 后子进程退出（尚未回收时退出通知就已到达）
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
    // 退出后未回收的进程（僵尸进程）仍然存在，回收后才检查得到
    finishChild(&child);
    try testing.expectEqual(Outcome.exited, w.wait());

    var other = try spawnChild();
    defer finishChild(&other);
    var s: Watch = .{ .io = testing.io, .pid = other.id.?, .native = null };
    s.stop();
    try testing.expectEqual(Outcome.stopped, s.wait());
}
