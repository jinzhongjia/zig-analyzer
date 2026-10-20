//! panic 上下文：每个线程记下正在做的事（处理的请求、发布诊断的文件、执行中的 query），panic 时与消息一起
//! 写入日志。Zig 没有栈展开，panic 总是结束进程；调用栈只说明在哪段代码，这里补上是哪个请求、哪个文件。
//!
//! 条目是调用方栈上的值，按嵌套顺序链接：进入时 `push`，离开时 `pop`（同一线程内后进先出）。

const std = @import("std");
const Io = std.Io;

pub const Entry = struct {
    prev: ?*const Entry = null,
    data: *const anyopaque,
    /// 写出条目的描述（一行，不含换行）。panic 时调用：不能分配内存、不能获取锁
    write: *const fn (data: *const anyopaque, w: *Io.Writer) Io.Writer.Error!void,
};

threadlocal var top: ?*const Entry = null;

/// `entry` 须在 `pop` 之前保持有效
pub fn push(entry: *Entry) void {
    entry.prev = top;
    top = entry;
}

pub fn pop(entry: *const Entry) void {
    std.debug.assert(top == entry);
    top = entry.prev;
}

/// 一行文字描述的条目，文字在进入时格式化并保存在条目自身中（过长时截断）
pub const Text = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,
    entry: Entry = undefined,

    /// `t` 须在 `leave` 之前保持在同一地址
    pub fn enter(t: *Text, comptime format: []const u8, args: anytype) void {
        var w: Io.Writer = .fixed(&t.buf);
        w.print(format, args) catch {};
        t.len = w.end;
        t.entry = .{ .data = t, .write = write };
        push(&t.entry);
    }

    pub fn leave(t: *const Text) void {
        pop(&t.entry);
    }

    fn write(data: *const anyopaque, w: *Io.Writer) Io.Writer.Error!void {
        const t: *const Text = @ptrCast(@alignCast(data));
        try w.writeAll(t.buf[0..t.len]);
    }
};

/// 写出当前线程的条目，外层在前，每条一行。没有条目时不写
pub fn dump(w: *Io.Writer) Io.Writer.Error!void {
    var entries: [64]*const Entry = undefined;
    var n: usize = 0;
    var e = top;
    while (e) |entry| : (e = entry.prev) {
        if (n == entries.len) break;
        entries[n] = entry;
        n += 1;
    }
    var i = n;
    while (i > 0) {
        i -= 1;
        try w.writeAll("  ");
        try entries[i].write(entries[i].data, w);
        try w.writeByte('\n');
    }
}

test "entries nest and are written outermost first" {
    const testing = std.testing;
    var outer: Text = .{};
    outer.enter("request {s}", .{"textDocument/hover"});
    defer outer.leave();
    {
        var inner: Text = .{};
        inner.enter("query {s}", .{"Infer"});
        defer inner.leave();
        var buf: [256]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        try dump(&w);
        try testing.expectEqualStrings("  request textDocument/hover\n  query Infer\n", w.buffered());
    }
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try dump(&w);
    try testing.expectEqualStrings("  request textDocument/hover\n", w.buffered());
}
