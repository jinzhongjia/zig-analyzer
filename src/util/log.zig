//! Logging: filters by the runtime level and writes to stderr (the client's output panel), also
//! appending to a file when one is configured. Hooked in via the executable's `std_options.logFn`
//! (see main.zig); the level and the file change with the `log.level` and `log.file` settings.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

var level: std.atomic.Value(u8) = .init(@backingInt(std.log.Level.info));
var mutex: Io.Mutex = .init;
var file: ?Io.File = null;

pub fn setLevel(l: std.log.Level) void {
    level.store(@backingInt(l), .monotonic);
}

/// Appends the log to `path` (null for no file). Returns an error when it cannot be opened, leaving
/// the current file unchanged.
pub fn setFile(path: ?[]const u8) !void {
    const io = std.Options.debug_io;
    const opened: ?Io.File = if (path) |p| try openAppend(io, p) else null;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (file) |old| old.close(io);
    file = opened;
}

/// Opens `path` for writing at its end, creating it when missing. Several servers may share the
/// file, and it may be truncated by log rotation: each write goes to the end of the file as it is
/// at that moment (`O_APPEND` on POSIX; see `append` on Windows), never at an offset this process
/// keeps.
fn openAppend(io: Io, path: []const u8) !Io.File {
    if (builtin.os.tag == .windows) return Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    const posix = std.posix;
    var flags: posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    if (@hasField(posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(posix.O, "LARGEFILE")) flags.LARGEFILE = true;
    const fd = try posix.openat(posix.AT.FDCWD, path, flags, 0o666);
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Writes `bytes` at the current end of the log file, in one system call when the system writes
/// it whole, so lines of processes sharing the file do not interleave
fn append(io: Io, f: Io.File, bytes: []const u8) !void {
    if (builtin.os.tag != .windows) return f.writeStreamingAll(io, bytes);
    // The byte offset FILE_WRITE_TO_END_OF_FILE (all bits set) writes at the end of the file
    const windows = std.os.windows;
    const end_of_file: windows.LARGE_INTEGER = -1;
    var index: usize = 0;
    while (index < bytes.len) {
        const chunk = bytes[index..][0..@min(bytes.len - index, std.math.maxInt(u32))];
        var iosb: windows.IO_STATUS_BLOCK = undefined;
        switch (windows.ntdll.NtWriteFile(f.handle, null, null, null, &iosb, chunk.ptr, @intCast(chunk.len), &end_of_file, null)) {
            .SUCCESS => index += iosb.Information,
            else => return error.Unexpected,
        }
    }
}

pub fn logFn(comptime l: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (@backingInt(l) > level.load(.monotonic)) return;
    // When called directly in tests, does not write to stderr (the build system treats stderr
    // output from tests as an error)
    if (!builtin.is_test) std.log.defaultLog(l, scope, format, args);
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const f = file orelse return;
    // Time (Unix milliseconds), level, scope, message; overlong messages are truncated
    var buf: [16 * 1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const now_ms = @divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms);
    w.print("{d} {s} ({s}) ", .{ now_ms, l.asText(), @tagName(scope) }) catch {};
    w.print(format, args) catch {};
    const text = if (w.end < buf.len) w.buffered() else buf[0 .. buf.len - 1];
    var line: [16 * 1024 + 1]u8 = undefined;
    @memcpy(line[0..text.len], text);
    line[text.len] = '\n';
    append(io, f, line[0 .. text.len + 1]) catch return;
}

/// On panic, writes the message, the current thread's context (see `panic_context`), and the stack
/// trace: the context goes to stderr, and all three are appended to the log file. The stack trace
/// is then written to stderr by the default panic handler. A panic can happen while the log lock is
/// held; when the lock cannot be taken, only stderr is written.
pub fn writePanic(msg: []const u8, first_address: ?usize) void {
    // Panicking again while writing the log: do not repeat, leave it to the default panic handler
    if (writing_panic) return;
    writing_panic = true;
    const io = std.Options.debug_io;
    // The time prefix and the report go to the log file in one write
    var buf: [32 * 1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const now_ms = @divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms);
    w.print("{d} panic: {s}\n", .{ now_ms, msg }) catch {};
    const context_start = w.end;
    w.writeAll("context (outermost first):\n") catch {};
    const entries_start = w.end;
    panic_context.dump(&w) catch {};
    // Threads without context (such as the main loop between two messages) omit this section
    if (w.end == entries_start) w.end = context_start;
    const context = buf[context_start..w.end];
    if (!builtin.is_test) std.Io.File.stderr().writeStreamingAll(io, context) catch {};

    if (!mutex.tryLock()) return;
    defer mutex.unlock(io);
    const f = file orelse return;
    var addresses: [32]usize = undefined;
    const trace = std.debug.captureCurrentStackTrace(.{ .first_address = first_address orelse @returnAddress() }, &addresses);
    std.debug.writeStackTrace(&trace, .{ .writer = &w, .mode = .no_color }) catch {};
    append(io, f, w.buffered()) catch return;
}

const panic_context = @import("panic_context.zig");

threadlocal var writing_panic = false;

test "panic report: message and context are appended to the log file" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "za.log" });
    defer testing.allocator.free(path);

    try setFile(path);
    {
        var pc: panic_context.Text = .{};
        pc.enter("request {s} {s}", .{ "textDocument/hover", "file:///a.zig" });
        defer pc.leave();
        writePanic("index out of bounds", null);
        writing_panic = false;
    }
    try setFile(null);

    const text = try Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, " panic: index out of bounds\ncontext (outermost first):\n  request textDocument/hover file:///a.zig\n") != null);
}

test "log file: append with level filter" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "za.log" });
    defer testing.allocator.free(path);

    defer setLevel(.info);
    setLevel(.info);
    try setFile(path);
    logFn(.info, .log_test, "first {d}", .{1});
    logFn(.debug, .log_test, "filtered", .{});
    try setFile(path);
    logFn(.warn, .log_test, "second", .{});
    try setFile(null);

    const text = try Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(text);
    try testing.expectEqual(2, std.mem.count(u8, text, "\n"));
    try testing.expect(std.mem.indexOf(u8, text, "info (log_test) first 1\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "warning (log_test) second\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "filtered") == null);
}

test "log file: lines written by another process to the same file are kept" {
    // Guards against writing at an offset only this process advances, which overwrote the lines
    // other writers appended and left a gap of NUL bytes after the file was truncated
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "za.log" });
    defer testing.allocator.free(path);

    defer setLevel(.info);
    setLevel(.info);
    try setFile(path);
    logFn(.info, .log_test, "first", .{});
    {
        // Another writer appends a line
        const other = try Io.Dir.cwd().openFile(testing.io, path, .{ .mode = .write_only });
        defer other.close(testing.io);
        try other.writePositionalAll(testing.io, "other\n", try other.length(testing.io));
    }
    logFn(.info, .log_test, "second", .{});
    {
        const text = try Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .unlimited);
        defer testing.allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        try testing.expect(std.mem.endsWith(u8, lines.next().?, " info (log_test) first"));
        try testing.expectEqualStrings("other", lines.next().?);
        try testing.expect(std.mem.endsWith(u8, lines.next().?, " info (log_test) second"));
        try testing.expectEqualStrings("", lines.rest());
    }
    // The file is truncated from outside (log rotation): the next line starts the file
    {
        const other = try Io.Dir.cwd().createFile(testing.io, path, .{});
        other.close(testing.io);
    }
    logFn(.info, .log_test, "third", .{});
    try setFile(null);
    const text = try Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.endsWith(u8, text, " info (log_test) third\n"));
    try testing.expectEqual(1, std.mem.count(u8, text, "\n"));
    try testing.expect(std.mem.indexOfScalar(u8, text, 0) == null);
}
