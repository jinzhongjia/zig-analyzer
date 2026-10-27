//! Logging: filters by the runtime level and writes to stderr (the client's output panel), also
//! appending to a file when one is configured. Hooked in via the executable's `std_options.logFn`
//! (see main.zig); the level and the file change with the `log.level` and `log.file` settings.

const std = @import("std");
const Io = std.Io;

var level: std.atomic.Value(u8) = .init(@backingInt(std.log.Level.info));
var mutex: Io.Mutex = .init;
var file: ?Io.File = null;
/// Offset of the next write in the file (appending)
var file_offset: u64 = 0;

pub fn setLevel(l: std.log.Level) void {
    level.store(@backingInt(l), .monotonic);
}

/// Appends the log to `path` (null for no file). Returns an error when it cannot be opened, leaving
/// the current file unchanged.
pub fn setFile(path: ?[]const u8) !void {
    const io = std.Options.debug_io;
    const opened: ?Io.File = if (path) |p| try Io.Dir.cwd().createFile(io, p, .{ .truncate = false }) else null;
    const end = if (opened) |f| f.length(io) catch 0 else 0;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (file) |old| old.close(io);
    file = opened;
    file_offset = end;
}

pub fn logFn(comptime l: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (@backingInt(l) > level.load(.monotonic)) return;
    // When called directly in tests, does not write to stderr (the build system treats stderr
    // output from tests as an error)
    if (!@import("builtin").is_test) std.log.defaultLog(l, scope, format, args);
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
    f.writePositionalAll(io, line[0 .. text.len + 1], file_offset) catch return;
    file_offset += text.len + 1;
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
    var buf: [32 * 1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    w.print("panic: {s}\n", .{msg}) catch {};
    const context_start = w.end;
    w.writeAll("context (outermost first):\n") catch {};
    const entries_start = w.end;
    panic_context.dump(&w) catch {};
    // Threads without context (such as the main loop between two messages) omit this section
    if (w.end == entries_start) w.end = context_start;
    const context = buf[context_start..w.end];
    if (!@import("builtin").is_test) std.Io.File.stderr().writeStreamingAll(io, context) catch {};

    if (!mutex.tryLock()) return;
    defer mutex.unlock(io);
    const f = file orelse return;
    var addresses: [32]usize = undefined;
    const trace = std.debug.captureCurrentStackTrace(.{ .first_address = first_address orelse @returnAddress() }, &addresses);
    std.debug.writeStackTrace(&trace, .{ .writer = &w, .mode = .no_color }) catch {};
    const now_ms = @divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms);
    var head: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&head, "{d} ", .{now_ms}) catch "";
    f.writePositionalAll(io, prefix, file_offset) catch return;
    file_offset += prefix.len;
    f.writePositionalAll(io, w.buffered(), file_offset) catch return;
    file_offset += w.end;
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
