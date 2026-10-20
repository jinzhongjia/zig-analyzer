//! 日志：按运行时的级别过滤后写到 stderr（客户端的输出面板），配置了文件时同时追加到文件。
//! 由可执行文件的 `std_options.logFn` 接入（见 main.zig）；级别与文件随配置 `log.level`、`log.file` 变化。

const std = @import("std");
const Io = std.Io;

var level: std.atomic.Value(u8) = .init(@backingInt(std.log.Level.info));
var mutex: Io.Mutex = .init;
var file: ?Io.File = null;
/// 文件中下一次写入的位置（追加）
var file_offset: u64 = 0;

pub fn setLevel(l: std.log.Level) void {
    level.store(@backingInt(l), .monotonic);
}

/// 日志追加到 `path`（null 为不写文件）。打不开时返回错误，原来的文件保持不变
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
    // 测试中直接调用时不写 stderr（测试的 stderr 输出会被构建系统视为异常）
    if (!@import("builtin").is_test) std.log.defaultLog(l, scope, format, args);
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const f = file orelse return;
    // 时间（Unix 毫秒）、级别、作用域、消息；过长的消息截断
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

/// panic 时写出消息、当前线程的上下文（见 `panic_context`）与调用栈：上下文写到 stderr，三者都追加到日志文件。
/// 调用栈随后由默认的 panic 处理写到 stderr。panic 可能发生在持有日志锁时，拿不到锁就只写 stderr
pub fn writePanic(msg: []const u8, first_address: ?usize) void {
    // 写日志的过程中再次 panic：不再重复，交给默认的 panic 处理
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
    // 没有上下文的线程（如主循环在两条消息之间）不写这一节
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
