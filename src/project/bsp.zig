//! 构建系统协议（BSP，`zig build --listen=-`）客户端。
//!
//! 消息格式由 `std.zig.Server` / `std.zig.Client` 定义：8 字节头部（tag、body 长度，小端）+ body。
//! 使用非 watch 模式：每次需要构建时发送一次 `bsp_build_steps`，maker 构建完成后等待下一次请求。
//! （0.17 的 maker 在 watch 期间收到新请求会 panic，且 watch 模式下无法改变要构建的 step。）

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

/// 以 `ServerMessage.ErrorBundle` 头部开始的消息体中的错误包（见 `readErrorBundle`）
fn allocErrorBundle(gpa: Allocator, body: []const u8) DecodeError!ErrorBundle {
    var r: Io.Reader = .fixed(body);
    const hdr = r.takeStruct(ServerMessage.ErrorBundle, .little) catch return error.InvalidMessage;
    return readErrorBundle(gpa, &r, hdr);
}

/// 按头部给出的长度从消息体的读取器 `r` 中读取错误包；`extra` 为空时返回空的错误包。长度超出剩余的字节时
/// （如格式与 zig-analyzer 编译时的标准库不符，长度是任意值）在分配之前返回 `error.InvalidMessage`
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

/// 子进程回传的错误包：不合法时（如格式与 zig-analyzer 编译时的标准库不符）释放、记录日志并改用空的错误包，
/// 消息的其余部分照常使用
fn checked(gpa: Allocator, eb: ErrorBundle, comptime source: []const u8, args: anytype) ErrorBundle {
    if (error_bundle.isValid(eb)) return eb;
    log.warn("discarding malformed error bundle from " ++ source, args);
    var malformed = eb;
    malformed.deinit(gpa);
    return .empty;
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

pub const SingleFileResult = struct {
    /// 错误包（没有错误时为空）。错误中的相对路径相对于文件所在目录
    errors: ErrorBundle,
    /// 编译读取的、位于文件所在目录之下的文件（绝对路径，含 import 了但不存在的文件）：其中任何一个变化
    /// 都可能改变编译结果。标准库等其他位置的文件不在其中
    inputs: []const []const u8,

    pub fn deinit(r: *SingleFileResult, gpa: Allocator) void {
        r.errors.deinit(gpa);
        for (r.inputs) |p| gpa.free(p);
        gpa.free(r.inputs);
        r.* = undefined;
    }
};

/// 单文件模式（没有 build.zig）：运行 `zig build-obj -fno-emit-bin --listen=- <file>`，请求一次编译
pub fn compileSingleFile(gpa: Allocator, io: Io, zig_exe: []const u8, file_path: []const u8) !SingleFileResult {
    const dir = std.fs.path.dirname(file_path) orelse ".";
    var child = try std.process.spawn(io, .{
        .argv = &.{ zig_exe, "build-obj", "-fno-emit-bin", "--listen=-", std.fs.path.basename(file_path) },
        .cwd = .{ .path = dir },
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

/// 读取编译器的消息，直到这次编译结束（`error_bundle` 或 `emit_digest`）
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
                // 以 0 分隔的路径，第一个字节是路径前缀（`PathPrefix` 加一）。单独编译时 cwd 与构建根目录都是
                // 文件所在目录（命中缓存时用后者）；只保留这两种前缀的，不保留标准库与缓存中的
                var it = std.mem.splitScalar(u8, body, 0);
                while (it.next()) |prefixed| {
                    if (prefixed.len < 2) continue;
                    const prefix = std.enums.fromInt(ServerMessage.PathPrefix, prefixed[0] -% 1) orelse continue;
                    if (prefix != .cwd and prefix != .build_root) continue;
                    // 格式不符时路径可能是任意字符串：解析后不是绝对路径的（见 `Vfs.resolve`）不能驻留，跳过
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

/// 只有一条消息的错误包，消息的字符串下标越界
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
    // 丢弃时的警告是预期的，不写到 stderr
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
    // 曾按头部的长度先分配再读取：格式不符时长度是任意值，一次分配可达 16 GiB
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
    var result = try compileSingleFile(gpa, testing.io, project.env.zig_exe, path);
    defer result.deinit(gpa);
    const eb = result.errors;
    try testing.expectEqual(1, eb.errorMessageCount());
    const msg = eb.getErrorMessage(eb.getMessages()[0]);
    try testing.expectEqualStrings("unused local variable", eb.nullTerminatedString(msg.msg));
    try testing.expectEqualStrings("one.zig", eb.nullTerminatedString(eb.getSourceLocation(msg.src_loc).src_path));
    // 编译读取的文件：根文件自身在其中，标准库与缓存中的文件不在其中
    try testing.expectEqual(1, result.inputs.len);
    try testing.expectEqualStrings(path, result.inputs[0]);

    // 没有错误的编译：第二次命中缓存，读取的文件（包括被 import 的）仍然完整
    const ok = try project.path(gpa, "ok.zig");
    defer gpa.free(ok);
    const dep = try project.path(gpa, "dep.zig");
    defer gpa.free(dep);
    for (0..2) |_| {
        var r = try compileSingleFile(gpa, testing.io, project.env.zig_exe, ok);
        defer r.deinit(gpa);
        try testing.expectEqual(0, r.errors.errorMessageCount());
        try testing.expectEqual(2, r.inputs.len);
        for (r.inputs) |input| try testing.expect(std.mem.eql(u8, input, ok) or std.mem.eql(u8, input, dep));
    }
}

test "single-file mode: a malformed error bundle is discarded, the files read are kept" {
    const gpa = testing.allocator;
    // 丢弃时的警告是预期的，不写到 stderr
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
    // 格式不符时路径可能是任意字符串。在 Windows 上 `D:x.zig` 与 `::` 是另一驱动器的相对路径，解析后不是绝对
    // 路径；防止把它们交给 `Vfs.intern`（要求绝对路径，否则 panic）
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
