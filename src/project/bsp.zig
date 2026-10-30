//! Build system protocol (BSP, `zig build --listen=-`) client.
//!
//! The message format is defined by `std.zig.Server` / `std.zig.Client`: an 8-byte header (tag,
//! body length, little-endian) + body.
//! Non-watch mode is used: `bsp_build_steps` is sent once each time a build is needed, and the
//! maker waits for the next request after the build finishes.
//! (The 0.17 maker panics when it receives a new request while watching, and the steps to build
//! cannot be changed in watch mode.)

const std = @import("std");
const Watchdog = @import("../util/watchdog.zig").Watchdog;
const native_os = @import("builtin").os.tag;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ErrorBundle = std.zig.ErrorBundle;
const ServerMessage = std.zig.Server.Message;
const ClientMessage = std.zig.Client.Message;
const error_bundle = @import("error_bundle.zig");
const Vfs = @import("../base/Vfs.zig");
const ZigEnv = @import("ZigEnv.zig");

const log = std.log.scoped(.bsp);

pub const protocol_version = std.zig.Server.build_system_version;

pub const StepCompleted = struct {
    step: u32,
    status: ServerMessage.BuildStepCompleted.Status,
    /// Errors of the step (compile errors of a compile step, etc.)
    errors: ErrorBundle,
    /// Paths of the generated files the step produced
    generated: []GeneratedFile = &.{},
};

pub const GeneratedFile = struct {
    /// Index of the generated file in the build graph
    file: u32,
    prefix: ServerMessage.PathPrefix,
    sub_path: []u8,
};

pub const Event = union(enum) {
    handshake: ServerMessage.Handshake,
    /// Path of the build graph file (relative to the maker's cwd, i.e. the build root)
    configuration: []u8,
    /// build.zig itself failed to compile
    configuration_failed: ErrorBundle,
    build_started,
    step_started: u32,
    step_completed: StepCompleted,
    build_completed,

    pub fn deinit(e: *Event, gpa: Allocator) void {
        switch (e.*) {
            .configuration => |p| gpa.free(p),
            .configuration_failed => |*eb| eb.deinit(gpa),
            .step_completed => |*sc| {
                sc.errors.deinit(gpa);
                freeGenerated(gpa, sc.generated);
            },
            else => {},
        }
        e.* = undefined;
    }
};

pub const DecodeError = error{ InvalidMessage, OutOfMemory };

/// Decodes one server message; returns null for messages unrelated to BSP.
pub fn decode(gpa: Allocator, tag: ServerMessage.Tag, body: []const u8) DecodeError!?Event {
    var r: Io.Reader = .fixed(body);
    switch (tag) {
        .bsp_handshake => return .{ .handshake = r.takeStruct(ServerMessage.Handshake, .little) catch return error.InvalidMessage },
        .bsp_configuration => return .{ .configuration = try gpa.dupe(u8, body) },
        .bsp_configuration_failed => return .{ .configuration_failed = checked(gpa, try allocErrorBundle(gpa, body), "zig build (configuration)", .{}) },
        .bsp_build_started => return .build_started,
        .bsp_build_completed => return .build_completed,
        .bsp_step_started => return .{ .step_started = r.takeInt(u32, .little) catch return error.InvalidMessage },
        .bsp_step_completed => {
            const hdr = r.takeStruct(ServerMessage.BuildStepCompleted, .little) catch return error.InvalidMessage;
            const eb = try readErrorBundle(gpa, &r, hdr.error_bundle);
            errdefer {
                var owned = eb;
                owned.deinit(gpa);
            }
            const generated = try decodeGenerated(gpa, &r, hdr.generated_files_len);
            const step = @backingInt(hdr.step_index);
            return .{ .step_completed = .{
                .step = step,
                .status = hdr.status,
                .errors = checked(gpa, eb, "zig build (step {d})", .{step}),
                .generated = generated,
            } };
        },
        else => return null,
    }
}

/// The error bundle in a message body that starts with a `ServerMessage.ErrorBundle` header
/// (see `readErrorBundle`)
fn allocErrorBundle(gpa: Allocator, body: []const u8) DecodeError!ErrorBundle {
    var r: Io.Reader = .fixed(body);
    const hdr = r.takeStruct(ServerMessage.ErrorBundle, .little) catch return error.InvalidMessage;
    return readErrorBundle(gpa, &r, hdr);
}

/// Reads an error bundle from the message body reader `r` using the lengths given in the header;
/// returns an empty error bundle when `extra` is empty. When the lengths exceed the remaining
/// bytes (e.g. the format does not match the standard library zig-analyzer was compiled with, so
/// the lengths are arbitrary values), returns `error.InvalidMessage` before allocating
fn readErrorBundle(gpa: Allocator, r: *Io.Reader, hdr: ServerMessage.ErrorBundle) DecodeError!ErrorBundle {
    if (@as(u64, hdr.extra_len) * @sizeOf(u32) + hdr.string_bytes_len > r.bufferedLen()) return error.InvalidMessage;
    const extra = try gpa.alloc(u32, hdr.extra_len);
    errdefer gpa.free(extra);
    r.readSliceEndian(u32, extra, .little) catch return error.InvalidMessage;
    const strings = try gpa.alloc(u8, hdr.string_bytes_len);
    errdefer gpa.free(strings);
    r.readSliceAll(strings) catch return error.InvalidMessage;
    if (extra.len == 0) {
        gpa.free(extra);
        gpa.free(strings);
        return .empty;
    }
    return .{ .string_bytes = strings, .extra = extra };
}

/// An error bundle sent back by a child process: when it is invalid (e.g. the format does not
/// match the standard library zig-analyzer was compiled with), it is freed, logged, and replaced
/// by an empty error bundle; the rest of the message is used as usual
fn checked(gpa: Allocator, eb: ErrorBundle, comptime source: []const u8, args: anytype) ErrorBundle {
    if (error_bundle.isValid(eb)) return eb;
    log.warn("discarding malformed error bundle from " ++ source, args);
    var malformed = eb;
    malformed.deinit(gpa);
    return .empty;
}

/// List of generated files: first `count` `GeneratedFile` headers, then the prefix byte and
/// sub path of each file in turn
fn decodeGenerated(gpa: Allocator, r: *Io.Reader, count: u32) DecodeError![]GeneratedFile {
    const headers = try gpa.alloc(ServerMessage.GeneratedFile, count);
    defer gpa.free(headers);
    for (headers) |*h| h.* = r.takeStruct(ServerMessage.GeneratedFile, .little) catch return error.InvalidMessage;
    const files = try gpa.alloc(GeneratedFile, count);
    var n: usize = 0;
    errdefer {
        for (files[0..n]) |f| gpa.free(f.sub_path);
        gpa.free(files);
    }
    for (headers, files) |h, *f| {
        const prefix = std.enums.fromInt(ServerMessage.PathPrefix, r.takeByte() catch return error.InvalidMessage) orelse return error.InvalidMessage;
        const sub_path = r.readAlloc(gpa, h.path_len) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidMessage,
        };
        f.* = .{ .file = @backingInt(h.index), .prefix = prefix, .sub_path = sub_path };
        n += 1;
    }
    return files;
}

fn freeGenerated(gpa: Allocator, files: []GeneratedFile) void {
    for (files) |f| gpa.free(f.sub_path);
    gpa.free(files);
}

/// Encodes a `bsp_build_steps` request (non-watch mode)
pub fn encodeBuildSteps(w: *Io.Writer, steps: []const u32) Io.Writer.Error!void {
    try w.writeStruct(ClientMessage.Header{
        .tag = .bsp_build_steps,
        .bytes_len = @intCast(@sizeOf(ClientMessage.BuildSteps) + steps.len * 4),
    }, .little);
    try w.writeStruct(ClientMessage.BuildSteps{ .step_count = @intCast(steps.len), .flags = .{ .watch = false } }, .little);
    try w.writeSliceEndian(u32, steps, .little);
}

/// A `zig build --listen=-` child process. The maker and the child processes it starts (compilers,
/// etc.) are kept together: in the same process group on POSIX, in the same Job Object on Windows.
/// Stopping ends the whole group without waiting for the maker to finish the current build (a
/// non-watch maker does not read its input while building, so an exit it receives is handled only
/// after the build finishes).
/// The maker's stderr is read continuously by a task of its own (a full pipe would block the
/// maker), keeping its end: problems the maker reports only there (a failing configure phase, an
/// invalid build.zig.zon) are taken from it (see `stderrOutput`).
pub const Client = struct {
    gpa: Allocator,
    io: Io,
    child: std.process.Child,
    group: Group,
    read_buffer: [64 * 1024]u8 = undefined,
    reader: Io.File.Reader = undefined,
    write_buffer: [256]u8 = undefined,
    writer: Io.File.Writer = undefined,
    write_mutex: Io.Mutex = .init,
    stderr_task: Io.Future(void) = undefined,
    /// Set when the stderr task has reached the end of the pipe (or stopped reading)
    stderr_done: Io.Event = .unset,
    stderr_mutex: Io.Mutex = .init,
    /// The end of the maker's stderr: at most `stderr_keep` bytes once it grows past twice that
    stderr_tail: std.ArrayList(u8) = .empty,

    const stderr_keep = 64 * 1024;

    pub const StartError = std.process.SpawnError || Allocator.Error || Io.ConcurrentError;

    /// Starts the maker in `build_root` with the zig of `env`. `extra_args` is passed through to
    /// `zig build` (e.g. `-Dtarget=...`).
    pub fn start(gpa: Allocator, io: Io, env: *const ZigEnv, build_root: []const u8, extra_args: []const []const u8) StartError!*Client {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ env.zig_exe, "build", "--listen=-" });
        try argv.appendSlice(gpa, extra_args);

        const c = try gpa.create(Client);
        errdefer gpa.destroy(c);
        var group: Group = .create(io);
        errdefer group.destroy(io);
        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .cwd = .{ .path = build_root },
            .environ_map = env.childEnviron(),
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = group.spawnPgid(),
            .start_suspended = group.spawnSuspended(),
        });
        group.adopt(&child);
        c.* = .{ .gpa = gpa, .io = io, .child = child, .group = group };
        errdefer {
            c.group.terminate(&c.child);
            c.child.kill(io);
        }
        c.reader = c.child.stdout.?.readerStreaming(io, &c.read_buffer);
        c.writer = c.child.stdin.?.writerStreaming(io, &c.write_buffer);
        c.stderr_task = try io.concurrent(drainStderr, .{c});
        return c;
    }

    fn drainStderr(c: *Client) void {
        defer c.stderr_done.set(c.io);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = c.child.stderr.?.readStreaming(c.io, &.{&buf}) catch return;
            c.stderr_mutex.lockUncancelable(c.io);
            defer c.stderr_mutex.unlock(c.io);
            // Out of memory: the output is dropped, but the pipe keeps being emptied
            c.stderr_tail.appendSlice(c.gpa, buf[0..n]) catch continue;
            const len = c.stderr_tail.items.len;
            if (len > 2 * stderr_keep) {
                @memmove(c.stderr_tail.items[0..stderr_keep], c.stderr_tail.items[len - stderr_keep ..]);
                c.stderr_tail.shrinkRetainingCapacity(stderr_keep);
            }
        }
    }

    /// What the maker wrote to stderr (its last 64 KiB or more), copied into memory owned by the
    /// caller. Meant for when the maker has exited or is about to (it ends the whole group so that
    /// no process keeps the pipe open), and waits up to 2 seconds for the rest of the output.
    pub fn stderrOutput(c: *Client, gpa: Allocator) Allocator.Error![]u8 {
        c.terminate();
        c.stderr_done.waitTimeout(c.io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } }) catch {};
        c.stderr_mutex.lockUncancelable(c.io);
        defer c.stderr_mutex.unlock(c.io);
        return gpa.dupe(u8, c.stderr_tail.items);
    }

    /// Blocks reading the next BSP event; returns `error.EndOfStream` when the maker exits,
    /// `error.Canceled` when the reading task is canceled, and `error.ReadFailed` for other read
    /// errors (see `readError` for the cause).
    pub fn next(c: *Client) (DecodeError || error{ EndOfStream, ReadFailed, Canceled })!Event {
        const r = &c.reader.interface;
        while (true) {
            const header = r.takeStruct(ServerMessage.Header, .little) catch |err| switch (err) {
                error.EndOfStream => return error.EndOfStream,
                error.ReadFailed => return c.readFailure(),
            };
            const body = r.readAlloc(c.gpa, header.bytes_len) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.EndOfStream => return error.EndOfStream,
                error.ReadFailed => return c.readFailure(),
            };
            defer c.gpa.free(body);
            if (try decode(c.gpa, header.tag, body)) |event| return event;
        }
    }

    fn readFailure(c: *Client) error{ ReadFailed, Canceled } {
        if (c.reader.err) |e| if (e == error.Canceled) return error.Canceled;
        return error.ReadFailed;
    }

    /// The underlying error when `next` returns `error.ReadFailed`
    pub fn readError(c: *Client) ?anyerror {
        return if (c.reader.err) |e| e else null;
    }

    pub fn buildSteps(c: *Client, steps: []const u32) Io.Writer.Error!void {
        c.write_mutex.lockUncancelable(c.io);
        defer c.write_mutex.unlock(c.io);
        try encodeBuildSteps(&c.writer.interface, steps);
        try c.writer.interface.flush();
    }

    /// Immediately ends the maker and all its child processes, without waiting or reaping (it does
    /// not close the pipes and does not race with a read blocked in `next`).
    /// The reader then gets `error.EndOfStream` and calls `deinit` to reap the processes and free
    /// the resources
    pub fn terminate(c: *Client) void {
        c.group.terminate(&c.child);
    }

    /// Ends the maker and all its child processes (if still running) and frees the client.
    /// No other task may be reading in `next` when this is called.
    pub fn deinit(c: *Client) void {
        c.terminate();
        c.stderr_task.cancel(c.io);
        c.stderr_tail.deinit(c.gpa);
        c.child.kill(c.io);
        c.group.destroy(c.io);
        c.gpa.destroy(c);
    }
};

/// The line of the maker's stderr that says why it failed: the first one that is neither empty nor
/// an `info:` or `warning:` line (e.g. `error: invalid option: "nope"`, `panic: ...` of a panicking
/// `build()`, `unable to parse target ...`); null when there is none
pub fn failureSummary(stderr: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "info: ") or std.mem.startsWith(u8, line, "warning: ")) continue;
        return line;
    }
    return null;
}

/// The maker and its child processes as a whole.
///
/// POSIX: the maker joins the process group whose leader is a watchdog process (`sh`). The
/// watchdog blocks reading a pipe whose write end only the server holds, and on end of input
/// sends SIGKILL to the whole process group: however the server exits (including being SIGKILLed
/// or crashing), the operating system closes the write end, and the maker and the compilers end
/// with it. When the watchdog cannot be started, the maker forms its own group, and the whole
/// group is ended only when the server stops it explicitly.
///
/// Windows: the maker is started suspended, put into a Job Object with KILL_ON_JOB_CLOSE set,
/// and then resumed; the child processes it starts afterwards are all in the job. When the
/// server exits, the handle is closed with it and all processes in the job end.
const Group = switch (native_os) {
    .windows => struct {
        job: ?std.os.windows.HANDLE,

        fn create(io: Io) @This() {
            _ = io;
            const job = win32.CreateJobObjectW(null, null) orelse {
                log.warn("cannot create a job object for zig build: child processes may outlive zig-analyzer", .{});
                return .{ .job = null };
            };
            var info = std.mem.zeroes(win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
            info.BasicLimitInformation.LimitFlags = win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if (win32.SetInformationJobObject(job, win32.JobObjectExtendedLimitInformation, &info, @sizeOf(win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION)) == 0) {
                std.os.windows.CloseHandle(job);
                log.warn("cannot configure the job object for zig build: child processes may outlive zig-analyzer", .{});
                return .{ .job = null };
            }
            return .{ .job = job };
        }

        fn spawnPgid(_: *const @This()) ?std.posix.pid_t {
            return null;
        }

        fn spawnSuspended(g: *const @This()) bool {
            return g.job != null;
        }

        /// Puts the maker into the job, then resumes it; if it cannot be put in, only the maker
        /// itself can be ended
        fn adopt(g: *@This(), child: *std.process.Child) void {
            const job = g.job orelse return;
            if (win32.AssignProcessToJobObject(job, child.id.?) == 0) {
                log.warn("cannot assign zig build to a job object: child processes may outlive zig-analyzer", .{});
                std.os.windows.CloseHandle(job);
                g.job = null;
            }
            _ = std.os.windows.ntdll.NtResumeThread(child.thread_handle, null);
        }

        fn terminate(g: *@This(), child: *std.process.Child) void {
            if (g.job) |job| {
                _ = win32.TerminateJobObject(job, 1);
            } else if (child.id) |handle| {
                _ = std.os.windows.ntdll.NtTerminateProcess(handle, @fromBackingInt(1));
            }
        }

        fn destroy(g: *@This(), io: Io) void {
            _ = io;
            if (g.job) |job| std.os.windows.CloseHandle(job);
            g.job = null;
        }
    },
    else => struct {
        watchdog: ?std.process.Child,
        /// Process group ID: the watchdog's pid; without a watchdog, the maker's pid (known
        /// after it starts)
        pgid: std.posix.pid_t = 0,

        fn create(io: Io) @This() {
            const watchdog = std.process.spawn(io, .{
                .argv = &.{ "/bin/sh", "-c", "read _; kill -9 0" },
                .stdin = .pipe,
                .stdout = .ignore,
                .stderr = .ignore,
                .pgid = 0,
            }) catch |err| {
                log.warn("cannot start the watchdog of zig build ({t}): child processes may outlive zig-analyzer", .{err});
                return .{ .watchdog = null };
            };
            return .{ .watchdog = watchdog, .pgid = watchdog.id.? };
        }

        /// Joins the watchdog's process group; without a watchdog, forms its own group
        fn spawnPgid(g: *const @This()) ?std.posix.pid_t {
            return g.pgid;
        }

        fn spawnSuspended(_: *const @This()) bool {
            return false;
        }

        fn adopt(g: *@This(), child: *std.process.Child) void {
            if (g.watchdog == null) g.pgid = child.id.?;
        }

        fn terminate(g: *@This(), _: *std.process.Child) void {
            // The group leader (the watchdog or the maker) is reaped only in `deinit`, so the
            // group ID cannot be reused before then. 0 means the caller's own process group
            if (g.pgid > 0) std.posix.kill(-g.pgid, .KILL) catch {};
        }

        /// Reaps the watchdog. When the maker has ended, its child processes may still be in the
        /// group: the whole group is ended first
        fn destroy(g: *@This(), io: Io) void {
            if (g.watchdog) |*w| {
                std.posix.kill(-g.pgid, .KILL) catch {};
                w.kill(io);
            }
            g.watchdog = null;
        }
    },
};

const win32 = struct {
    const HANDLE = std.os.windows.HANDLE;
    const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
        PerProcessUserTimeLimit: i64,
        PerJobUserTimeLimit: i64,
        LimitFlags: u32,
        MinimumWorkingSetSize: usize,
        MaximumWorkingSetSize: usize,
        ActiveProcessLimit: u32,
        Affinity: usize,
        PriorityClass: u32,
        SchedulingClass: u32,
    };
    const IO_COUNTERS = extern struct {
        ReadOperationCount: u64,
        WriteOperationCount: u64,
        OtherOperationCount: u64,
        ReadTransferCount: u64,
        WriteTransferCount: u64,
        OtherTransferCount: u64,
    };
    const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
        BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
        IoInfo: IO_COUNTERS,
        ProcessMemoryLimit: usize,
        JobMemoryLimit: usize,
        PeakProcessMemoryUsed: usize,
        PeakJobMemoryUsed: usize,
    };
    const JobObjectExtendedLimitInformation: c_int = 9;
    const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x2000;
    extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn SetInformationJobObject(job: HANDLE, class: c_int, info: *const anyopaque, len: u32) callconv(.winapi) c_int;
    extern "kernel32" fn AssignProcessToJobObject(job: HANDLE, process: HANDLE) callconv(.winapi) c_int;
    extern "kernel32" fn TerminateJobObject(job: HANDLE, exit_code: u32) callconv(.winapi) c_int;
};

pub const SingleFileResult = struct {
    /// Error bundle (empty when there are no errors). Relative paths in the errors are relative
    /// to the directory of the file
    errors: ErrorBundle,
    /// Files read by the compilation that are under the file's directory (absolute paths,
    /// including files that are imported but do not exist): a change to any of them may change
    /// the compile result. Files elsewhere, such as in the standard library, are not included
    inputs: []const []const u8,

    pub fn deinit(r: *SingleFileResult, gpa: Allocator) void {
        r.errors.deinit(gpa);
        for (r.inputs) |p| gpa.free(p);
        gpa.free(r.inputs);
        r.* = undefined;
    }
};

/// Single-file mode (no build.zig): runs `zig build-obj -fno-emit-bin --listen=- <file>` with the
/// zig of `env` and requests one compilation
pub fn compileSingleFile(gpa: Allocator, io: Io, env: *const ZigEnv, file_path: []const u8) !SingleFileResult {
    const dir = std.fs.path.dirname(file_path) orelse ".";
    var child = try std.process.spawn(io, .{
        .argv = &.{ env.zig_exe, "build-obj", "-fno-emit-bin", "--listen=-", std.fs.path.basename(file_path) },
        .cwd = .{ .path = dir },
        .environ_map = env.childEnviron(),
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);
    var watchdog: Watchdog = .{};
    watchdog.start(io, child.id.?, .{ .duration = .{ .raw = Io.Duration.fromSeconds(120), .clock = .awake } });
    defer watchdog.stop();

    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &read_buffer);
    var write_buffer: [64]u8 = undefined;
    var writer = child.stdin.?.writerStreaming(io, &write_buffer);
    const w = &writer.interface;
    try w.writeStruct(ClientMessage.Header{ .tag = .update, .bytes_len = 0 }, .little);
    try w.flush();

    const result = try receiveSingleFile(gpa, &reader.interface, file_path);
    w.writeStruct(ClientMessage.Header{ .tag = .exit, .bytes_len = 0 }, .little) catch {};
    w.flush() catch {};
    return result;
}

/// Reads compiler messages until this compilation finishes (`error_bundle` or `emit_digest`)
fn receiveSingleFile(gpa: Allocator, r: *Io.Reader, file_path: []const u8) !SingleFileResult {
    const dir = std.fs.path.dirname(file_path) orelse ".";
    var inputs: std.ArrayList([]const u8) = .empty;
    defer {
        for (inputs.items) |p| gpa.free(p);
        inputs.deinit(gpa);
    }
    while (true) {
        const header = try r.takeStruct(ServerMessage.Header, .little);
        const body = try r.readAlloc(gpa, header.bytes_len);
        defer gpa.free(body);
        var errors: ErrorBundle = switch (header.tag) {
            .error_bundle => checked(gpa, try allocErrorBundle(gpa, body), "zig build-obj {s}", .{file_path}),
            .emit_digest => .empty,
            .file_system_inputs => {
                // Paths separated by 0, each starting with a path prefix byte (`PathPrefix` plus
                // one). When a file is compiled on its own, both cwd and the build root are the
                // file's directory (the latter is used on a cache hit); only paths with these two
                // prefixes are kept, not those in the standard library or caches
                var it = std.mem.splitScalar(u8, body, 0);
                while (it.next()) |prefixed| {
                    if (prefixed.len < 2) continue;
                    const prefix = std.enums.fromInt(ServerMessage.PathPrefix, prefixed[0] -% 1) orelse continue;
                    if (prefix != .cwd and prefix != .build_root) continue;
                    // When the format does not match, a path may be an arbitrary string: one that
                    // does not resolve to an absolute path (see `Vfs.resolve`) cannot be interned
                    // and is skipped
                    const p = try Vfs.resolve(.native, gpa, dir, prefixed[1..]) orelse continue;
                    errdefer gpa.free(p);
                    try inputs.append(gpa, p);
                }
                continue;
            },
            else => continue,
        };
        errdefer errors.deinit(gpa);
        return .{ .errors = errors, .inputs = try inputs.toOwnedSlice(gpa) };
    }
}

const testing = std.testing;
const native = @import("../util/test_path.zig").native;

test "decode step completed message and error bundle" {
    const gpa = testing.allocator;
    // Build an error bundle with the standard library
    var wip: ErrorBundle.Wip = try .init(gpa);
    defer wip.deinit();
    try wip.addRootErrorMessage(.{ .msg = try wip.addString("boom") });
    var eb = try wip.toOwnedBundle("");
    defer eb.deinit(gpa);

    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.writeStruct(ServerMessage.BuildStepCompleted{
        .step_index = @fromBackingInt(7),
        .status = .failure,
        .error_bundle = .{ .extra_len = @intCast(eb.extra.len), .string_bytes_len = @intCast(eb.string_bytes.len) },
        .generated_files_len = 2,
    }, .little);
    try w.writeSliceEndian(u32, eb.extra, .little);
    try w.writeAll(eb.string_bytes);
    try w.writeStruct(ServerMessage.GeneratedFile{ .index = @fromBackingInt(3), .path_len = 15 }, .little);
    try w.writeStruct(ServerMessage.GeneratedFile{ .index = @fromBackingInt(5), .path_len = 3 }, .little);
    try w.writeByte(@backingInt(ServerMessage.PathPrefix.local_cache));
    try w.writeAll("o/abc/options.z");
    try w.writeByte(@backingInt(ServerMessage.PathPrefix.build_root));
    try w.writeAll("gen");

    var event = (try decode(gpa, .bsp_step_completed, w.buffered())).?;
    defer event.deinit(gpa);
    const sc = event.step_completed;
    try testing.expectEqual(7, sc.step);
    try testing.expectEqual(.failure, sc.status);
    try testing.expectEqual(1, sc.errors.errorMessageCount());
    try testing.expectEqualStrings("boom", sc.errors.nullTerminatedString(sc.errors.getErrorMessage(sc.errors.getMessages()[0]).msg));
    try testing.expectEqual(2, sc.generated.len);
    try testing.expectEqual(3, sc.generated[0].file);
    try testing.expectEqual(.local_cache, sc.generated[0].prefix);
    try testing.expectEqualStrings("o/abc/options.z", sc.generated[0].sub_path);
    try testing.expectEqual(.build_root, sc.generated[1].prefix);
    try testing.expectEqualStrings("gen", sc.generated[1].sub_path);

    // Truncated data is reported as an error without leaking
    w.end -= 4;
    try testing.expectError(error.InvalidMessage, decode(gpa, .bsp_step_completed, w.buffered()));
}

/// An error bundle with a single message whose string index is out of bounds
fn malformedBundle(gpa: Allocator) !ErrorBundle {
    var wip: ErrorBundle.Wip = try .init(gpa);
    defer wip.deinit();
    try wip.addRootErrorMessage(.{ .msg = try wip.addString("boom") });
    var eb = try wip.toOwnedBundle("");
    errdefer eb.deinit(gpa);
    const extra = try gpa.dupe(u32, eb.extra);
    extra[@backingInt(eb.getMessages()[0])] = std.math.maxInt(u32);
    gpa.free(eb.extra);
    return .{ .string_bytes = eb.string_bytes, .extra = extra };
}

fn writeBundle(w: *Io.Writer, eb: ErrorBundle) Io.Writer.Error!void {
    try w.writeStruct(ServerMessage.ErrorBundle{ .extra_len = @intCast(eb.extra.len), .string_bytes_len = @intCast(eb.string_bytes.len) }, .little);
    try w.writeSliceEndian(u32, eb.extra, .little);
    try w.writeAll(eb.string_bytes);
}

test "decode: a malformed error bundle is discarded, the rest of the message is kept" {
    const gpa = testing.allocator;
    // The warning on discarding is expected; do not write it to stderr
    const prev_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = prev_level;
    var eb = try malformedBundle(gpa);
    defer eb.deinit(gpa);

    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.writeStruct(ServerMessage.BuildStepCompleted{
        .step_index = @fromBackingInt(7),
        .status = .failure,
        .error_bundle = .{ .extra_len = @intCast(eb.extra.len), .string_bytes_len = @intCast(eb.string_bytes.len) },
        .generated_files_len = 1,
    }, .little);
    try w.writeSliceEndian(u32, eb.extra, .little);
    try w.writeAll(eb.string_bytes);
    try w.writeStruct(ServerMessage.GeneratedFile{ .index = @fromBackingInt(3), .path_len = 3 }, .little);
    try w.writeByte(@backingInt(ServerMessage.PathPrefix.build_root));
    try w.writeAll("gen");
    var event = (try decode(gpa, .bsp_step_completed, w.buffered())).?;
    defer event.deinit(gpa);
    const sc = event.step_completed;
    try testing.expectEqual(7, sc.step);
    try testing.expectEqual(.failure, sc.status);
    try testing.expectEqual(0, sc.errors.extra.len);
    try testing.expectEqual(1, sc.generated.len);
    try testing.expectEqual(3, sc.generated[0].file);
    try testing.expectEqualStrings("gen", sc.generated[0].sub_path);

    w = .fixed(&buf);
    try writeBundle(&w, eb);
    var failed = (try decode(gpa, .bsp_configuration_failed, w.buffered())).?;
    defer failed.deinit(gpa);
    try testing.expectEqual(0, failed.configuration_failed.extra.len);
}

test "decode: error bundle lengths beyond the message are rejected before allocating" {
    // Memory used to be allocated by the lengths in the header before reading: when the
    // format does not match, the lengths are arbitrary, and a single allocation could reach 16 GiB
    var small: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&small);
    const gpa = fba.allocator();
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.writeStruct(ServerMessage.BuildStepCompleted{
        .step_index = @fromBackingInt(1),
        .status = .failure,
        .error_bundle = .{ .extra_len = std.math.maxInt(u32), .string_bytes_len = 8 },
        .generated_files_len = 0,
    }, .little);
    try w.writeAll("garbage!");
    try testing.expectError(error.InvalidMessage, decode(gpa, .bsp_step_completed, w.buffered()));

    w = .fixed(&buf);
    try w.writeStruct(ServerMessage.ErrorBundle{ .extra_len = 3, .string_bytes_len = std.math.maxInt(u32) }, .little);
    try w.writeAll("garbage!");
    try testing.expectError(error.InvalidMessage, decode(gpa, .bsp_configuration_failed, w.buffered()));
    try testing.expectError(error.InvalidMessage, allocErrorBundle(gpa, w.buffered()));
}

test "decode other messages" {
    const gpa = testing.allocator;
    var e1 = (try decode(gpa, .bsp_configuration, ".zig-cache/c/abc")).?;
    defer e1.deinit(gpa);
    try testing.expectEqualStrings(".zig-cache/c/abc", e1.configuration);

    var started: [4]u8 = undefined;
    std.mem.writeInt(u32, &started, 3, .little);
    try testing.expectEqual(3, (try decode(gpa, .bsp_step_started, &started)).?.step_started);
    try testing.expectEqual(Event.build_completed, (try decode(gpa, .bsp_build_completed, "")).?);
    try testing.expectEqual(null, try decode(gpa, .zig_version, "0.17.0"));
    try testing.expectError(error.InvalidMessage, decode(gpa, .bsp_step_started, "x"));
}

test encodeBuildSteps {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encodeBuildSteps(&w, &.{ 2, 5 });
    var r: Io.Reader = .fixed(w.buffered());
    const header = try r.takeStruct(ClientMessage.Header, .little);
    try testing.expectEqual(ClientMessage.Tag.bsp_build_steps, header.tag);
    const body = try r.takeStruct(ClientMessage.BuildSteps, .little);
    try testing.expectEqual(2, body.step_count);
    try testing.expect(!body.flags.watch);
    try testing.expectEqual(2, try r.takeInt(u32, .little));
    try testing.expectEqual(5, try r.takeInt(u32, .little));
}

test "single-file mode: compile one file, get its errors and the files it read" {
    var project = try @import("fixture.zig").Project.create(&.{
        .{ .path = "one.zig", .text =
        \\fn g() void {
        \\    var u = 1;
        \\}
        \\
        },
        .{ .path = "ok.zig", .text = "const dep = @import(\"dep.zig\");\ncomptime {\n    _ = dep;\n}\n" },
        .{ .path = "dep.zig", .text = "pub const x = 1;\n" },
    });
    defer project.deinit();
    const gpa = testing.allocator;
    const path = try project.path(gpa, "one.zig");
    defer gpa.free(path);
    var result = try compileSingleFile(gpa, testing.io, &project.env, path);
    defer result.deinit(gpa);
    const eb = result.errors;
    try testing.expectEqual(1, eb.errorMessageCount());
    const msg = eb.getErrorMessage(eb.getMessages()[0]);
    try testing.expectEqualStrings("unused local variable", eb.nullTerminatedString(msg.msg));
    try testing.expectEqualStrings("one.zig", eb.nullTerminatedString(eb.getSourceLocation(msg.src_loc).src_path));
    // Files read by the compilation: the root file itself is included, files in the standard
    // library and caches are not
    try testing.expectEqual(1, result.inputs.len);
    try testing.expectEqualStrings(path, result.inputs[0]);

    // A compilation without errors: the second run hits the cache, and the files read (including
    // imported ones) are still complete
    const ok = try project.path(gpa, "ok.zig");
    defer gpa.free(ok);
    const dep = try project.path(gpa, "dep.zig");
    defer gpa.free(dep);
    for (0..2) |_| {
        var r = try compileSingleFile(gpa, testing.io, &project.env, ok);
        defer r.deinit(gpa);
        try testing.expectEqual(0, r.errors.errorMessageCount());
        try testing.expectEqual(2, r.inputs.len);
        for (r.inputs) |input| try testing.expect(std.mem.eql(u8, input, ok) or std.mem.eql(u8, input, dep));
    }
}

test "single-file mode: a malformed error bundle is discarded, the files read are kept" {
    const gpa = testing.allocator;
    // The warning on discarding is expected; do not write it to stderr
    const prev_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = prev_level;
    var eb = try malformedBundle(gpa);
    defer eb.deinit(gpa);
    const file = native("/proj/one.zig");

    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var inputs_buf: [64]u8 = undefined;
    var inputs: Io.Writer = .fixed(&inputs_buf);
    try inputs.writeByte(@backingInt(ServerMessage.PathPrefix.cwd) + 1);
    try inputs.writeAll("one.zig\x00");
    try inputs.writeByte(@backingInt(ServerMessage.PathPrefix.zig_lib) + 1);
    try inputs.writeAll("std/std.zig");
    try w.writeStruct(ServerMessage.Header{ .tag = .file_system_inputs, .bytes_len = @intCast(inputs.buffered().len) }, .little);
    try w.writeAll(inputs.buffered());
    const bundle_len = @sizeOf(ServerMessage.ErrorBundle) + eb.extra.len * 4 + eb.string_bytes.len;
    try w.writeStruct(ServerMessage.Header{ .tag = .error_bundle, .bytes_len = @intCast(bundle_len) }, .little);
    try writeBundle(&w, eb);

    var r: Io.Reader = .fixed(w.buffered());
    var result = try receiveSingleFile(gpa, &r, file);
    defer result.deinit(gpa);
    try testing.expectEqual(0, result.errors.extra.len);
    try testing.expectEqual(1, result.inputs.len);
    try testing.expectEqualStrings(file, result.inputs[0]);
}

test "single-file mode: files read that do not resolve to absolute paths are skipped" {
    const gpa = testing.allocator;
    const file = native("/proj/one.zig");
    // When the format does not match, a path may be an arbitrary string. On Windows, `D:x.zig`
    // and `::` are relative paths on another drive and do not resolve to absolute paths; they
    // must not be passed to `Vfs.intern` (which requires absolute paths and panics otherwise)
    var inputs_buf: [64]u8 = undefined;
    var inputs: Io.Writer = .fixed(&inputs_buf);
    for ([_][]const u8{ "one.zig", "D:x.zig", "::" }) |p| {
        try inputs.writeByte(@backingInt(ServerMessage.PathPrefix.cwd) + 1);
        try inputs.writeAll(p);
        try inputs.writeByte(0);
    }
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.writeStruct(ServerMessage.Header{ .tag = .file_system_inputs, .bytes_len = @intCast(inputs.buffered().len) }, .little);
    try w.writeAll(inputs.buffered());
    try w.writeStruct(ServerMessage.Header{ .tag = .emit_digest, .bytes_len = 0 }, .little);

    var r: Io.Reader = .fixed(w.buffered());
    var result = try receiveSingleFile(gpa, &r, file);
    defer result.deinit(gpa);
    try testing.expectEqualStrings(file, result.inputs[0]);
    for (result.inputs) |input| try testing.expect(std.fs.path.isAbsolute(input));
    try testing.expectEqual(@as(usize, if (native_os == .windows) 1 else 3), result.inputs.len);
}

test failureSummary {
    try testing.expectEqualStrings("error: invalid option: \"nope\"", failureSummary("info: x\n\nerror: invalid option: \"nope\"\r\ninfo: y\nerror: configure command exited\n").?);
    try testing.expectEqualStrings("panic: boom", failureSummary("warning: w\npanic: boom\n/a/build.zig:1:1: 0x1 in build\n").?);
    try testing.expectEqual(null, failureSummary("info: only\n\n"));
}
