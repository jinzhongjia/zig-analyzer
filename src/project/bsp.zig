//! 构建系统协议（BSP，`zig build --listen=-`）客户端。
//!
//! 消息格式由 `std.zig.Server` / `std.zig.Client` 定义：8 字节头部（tag、body 长度，小端）+ body。
//! 使用非 watch 模式：每次需要构建时发送一次 `bsp_build_steps`，maker 构建完成后等待下一次请求。
//! （0.17 的 maker 在 watch 期间收到新请求会 panic，且 watch 模式下无法改变要构建的 step。）

const std = @import("std");
const native_os = @import("builtin").os.tag;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ErrorBundle = std.zig.ErrorBundle;
const ServerMessage = std.zig.Server.Message;
const ClientMessage = std.zig.Client.Message;

const log = std.log.scoped(.bsp);

pub const protocol_version = std.zig.Server.build_system_version;

pub const StepCompleted = struct {
    step: u32,
    status: ServerMessage.BuildStepCompleted.Status,
    /// 该 step 的错误（compile step 的编译错误等）
    errors: ErrorBundle,
    /// 该 step 产出的生成文件路径
    generated: []GeneratedFile = &.{},
};

pub const GeneratedFile = struct {
    /// 构建图中的生成文件编号
    file: u32,
    prefix: ServerMessage.PathPrefix,
    sub_path: []u8,
};

pub const Event = union(enum) {
    handshake: ServerMessage.Handshake,
    /// 构建图文件路径（相对于 maker 的 cwd，即构建根目录）
    configuration: []u8,
    /// build.zig 本身编译失败
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

/// 解码一条服务端消息；与 BSP 无关的消息返回 null。
pub fn decode(gpa: Allocator, tag: ServerMessage.Tag, body: []const u8) DecodeError!?Event {
    var r: Io.Reader = .fixed(body);
    switch (tag) {
        .bsp_handshake => return .{ .handshake = r.takeStruct(ServerMessage.Handshake, .little) catch return error.InvalidMessage },
        .bsp_configuration => return .{ .configuration = try gpa.dupe(u8, body) },
        .bsp_configuration_failed => return .{ .configuration_failed = std.zig.Server.allocErrorBundle(gpa, body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.EndOfStream => return error.InvalidMessage,
        } },
        .bsp_build_started => return .build_started,
        .bsp_build_completed => return .build_completed,
        .bsp_step_started => return .{ .step_started = r.takeInt(u32, .little) catch return error.InvalidMessage },
        .bsp_step_completed => {
            const hdr = r.takeStruct(ServerMessage.BuildStepCompleted, .little) catch return error.InvalidMessage;
            const eb_len = hdr.error_bundle.extra_len;
            const extra = try gpa.alloc(u32, eb_len);
            errdefer gpa.free(extra);
            r.readSliceEndian(u32, extra, .little) catch return error.InvalidMessage;
            const strings = try gpa.alloc(u8, hdr.error_bundle.string_bytes_len);
            errdefer gpa.free(strings);
            r.readSliceAll(strings) catch return error.InvalidMessage;
            const generated = try decodeGenerated(gpa, &r, hdr.generated_files_len);
            return .{ .step_completed = .{
                .step = @backingInt(hdr.step_index),
                .status = hdr.status,
                .errors = if (eb_len == 0) blk: {
                    gpa.free(extra);
                    gpa.free(strings);
                    break :blk .empty;
                } else .{ .string_bytes = strings, .extra = extra },
                .generated = generated,
            } };
        },
        else => return null,
    }
}

/// 生成文件列表：先是 `count` 个 `GeneratedFile` 头部，然后依次是每个文件的前缀字节与子路径
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

/// 编码 `bsp_build_steps` 请求（非 watch 模式）
pub fn encodeBuildSteps(w: *Io.Writer, steps: []const u32) Io.Writer.Error!void {
    try w.writeStruct(ClientMessage.Header{
        .tag = .bsp_build_steps,
        .bytes_len = @intCast(@sizeOf(ClientMessage.BuildSteps) + steps.len * 4),
    }, .little);
    try w.writeStruct(ClientMessage.BuildSteps{ .step_count = @intCast(steps.len), .flags = .{ .watch = false } }, .little);
    try w.writeSliceEndian(u32, steps, .little);
}

/// 一个 `zig build --listen=-` 子进程。maker 及其启动的编译器等子进程放在一起：POSIX 上是同一个进程组，
/// Windows 上是同一个 Job Object。停止时结束整组，不等 maker 跑完当前的构建（非 watch 模式的 maker 构建
/// 期间不读取输入，收到的 exit 要等构建结束才处理）。
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

    pub const StartError = std.process.SpawnError || Allocator.Error;

    /// 在 `build_root` 下启动 maker。`extra_args` 透传给 `zig build`（如 `-Dtarget=...`）。
    pub fn start(gpa: Allocator, io: Io, zig_exe: []const u8, build_root: []const u8, extra_args: []const []const u8) StartError!*Client {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ zig_exe, "build", "--listen=-" });
        try argv.appendSlice(gpa, extra_args);

        const c = try gpa.create(Client);
        errdefer gpa.destroy(c);
        var group: Group = .create(io);
        errdefer group.destroy(io);
        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .cwd = .{ .path = build_root },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .pgid = group.spawnPgid(),
            .start_suspended = group.spawnSuspended(),
        });
        group.adopt(&child);
        c.* = .{ .gpa = gpa, .io = io, .child = child, .group = group };
        c.reader = c.child.stdout.?.readerStreaming(io, &c.read_buffer);
        c.writer = c.child.stdin.?.writerStreaming(io, &c.write_buffer);
        return c;
    }

    /// 阻塞读取下一个 BSP 事件；maker 退出时返回 `error.EndOfStream`，读取任务被取消时返回
    /// `error.Canceled`，其他读取错误为 `error.ReadFailed`（具体原因见 `readError`）。
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

    /// `next` 返回 `error.ReadFailed` 时的底层错误
    pub fn readError(c: *Client) ?anyerror {
        return if (c.reader.err) |e| e else null;
    }

    pub fn buildSteps(c: *Client, steps: []const u32) Io.Writer.Error!void {
        c.write_mutex.lockUncancelable(c.io);
        defer c.write_mutex.unlock(c.io);
        try encodeBuildSteps(&c.writer.interface, steps);
        try c.writer.interface.flush();
    }

    /// 立即结束 maker 及其全部子进程，不等待、不回收（不关闭管道，不与阻塞在 `next` 中的读取竞争）。
    /// 读取方随后得到 `error.EndOfStream`，再调用 `deinit` 回收进程与资源
    pub fn terminate(c: *Client) void {
        c.group.terminate(&c.child);
    }

    /// 结束 maker 及其全部子进程（若仍在运行）并释放。调用时不能有其他任务在 `next` 中读取。
    pub fn deinit(c: *Client) void {
        c.terminate();
        c.child.kill(c.io);
        c.group.destroy(c.io);
        c.gpa.destroy(c);
    }
};

/// maker 及其子进程的整体。
///
/// POSIX：maker 加入看门狗进程（`sh`）为组长的进程组。看门狗阻塞读取一个只有服务器持有写端的管道，
/// 读到输入结束时向整个进程组发 SIGKILL：服务器以任何方式退出（包括被 SIGKILL、崩溃）时，操作系统
/// 关闭写端，maker 与编译器随之结束。看门狗无法启动时 maker 自成一组，只有服务器主动停止时才结束整组。
///
/// Windows：maker 以挂起状态启动，放入设置了 KILL_ON_JOB_CLOSE 的 Job Object 后再恢复运行，之后启动的
/// 子进程都在其中；服务器退出时句柄随之关闭，Job 中的进程全部结束。
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

        /// 放入 Job 后恢复运行；放不进去时只能单独结束 maker
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
        /// 进程组号：看门狗的 pid；没有看门狗时为 maker 的 pid（启动后得知）
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

        /// 加入看门狗的进程组，没有看门狗时自成一组
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
            // 组长（看门狗或 maker）在 `deinit` 中才回收，组号在此之前不会被复用。0 表示调用者自己的进程组
            if (g.pgid > 0) std.posix.kill(-g.pgid, .KILL) catch {};
        }

        /// 回收看门狗。maker 已结束时组中可能还有它的子进程：先结束整组
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

/// 单文件模式（没有 build.zig）：运行 `zig build-obj -fno-emit-bin --listen=- <file>`，
/// 请求一次编译并返回错误包（没有错误时为空）。错误中的相对路径相对于文件所在目录。
pub fn compileSingleFile(gpa: Allocator, io: Io, zig_exe: []const u8, file_path: []const u8) !ErrorBundle {
    const dir = std.fs.path.dirname(file_path) orelse ".";
    var child = try std.process.spawn(io, .{
        .argv = &.{ zig_exe, "build-obj", "-fno-emit-bin", "--listen=-", std.fs.path.basename(file_path) },
        .cwd = .{ .path = dir },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);

    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &read_buffer);
    var write_buffer: [64]u8 = undefined;
    var writer = child.stdin.?.writerStreaming(io, &write_buffer);
    const w = &writer.interface;
    try w.writeStruct(ClientMessage.Header{ .tag = .update, .bytes_len = 0 }, .little);
    try w.flush();

    const r = &reader.interface;
    while (true) {
        const header = try r.takeStruct(ServerMessage.Header, .little);
        const body = try r.readAlloc(gpa, header.bytes_len);
        defer gpa.free(body);
        const result: ?ErrorBundle = switch (header.tag) {
            .error_bundle => std.zig.Server.allocErrorBundle(gpa, body) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.EndOfStream => return error.InvalidMessage,
            },
            .emit_digest => .empty,
            else => null,
        };
        if (result) |eb| {
            w.writeStruct(ClientMessage.Header{ .tag = .exit, .bytes_len = 0 }, .little) catch {};
            w.flush() catch {};
            return eb;
        }
    }
}

const testing = std.testing;

test "decode step completed message and error bundle" {
    const gpa = testing.allocator;
    // 用标准库构造一个错误包
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

    // 数据被截断时报错且不泄漏
    w.end -= 4;
    try testing.expectError(error.InvalidMessage, decode(gpa, .bsp_step_completed, w.buffered()));
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

test "single-file mode: compile one file and get errors" {
    var project = try @import("fixture.zig").Project.create(&.{.{ .path = "one.zig", .text =
        \\fn g() void {
        \\    var u = 1;
        \\}
        \\
    }});
    defer project.deinit();
    const gpa = testing.allocator;
    const path = try project.path(gpa, "one.zig");
    defer gpa.free(path);
    var eb = try compileSingleFile(gpa, testing.io, project.env.zig_exe, path);
    defer eb.deinit(gpa);
    try testing.expectEqual(1, eb.errorMessageCount());
    const msg = eb.getErrorMessage(eb.getMessages()[0]);
    try testing.expectEqualStrings("unused local variable", eb.nullTerminatedString(msg.msg));
    try testing.expectEqualStrings("one.zig", eb.nullTerminatedString(eb.getSourceLocation(msg.src_loc).src_path));
}
