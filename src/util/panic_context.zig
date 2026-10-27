//! Panic context: each thread records what it is doing (the request being handled, the file whose
//! diagnostics are being published, the query being executed), which is written to the log together
//! with the message on panic. Zig has no stack unwinding, so a panic always ends the process; the
//! stack trace only shows which code was running, and this adds which request and which file.
//!
//! Entries are values on the callers' stacks, linked in nesting order: `push` on entering, `pop` on
//! leaving (last in, first out within a thread).

const std = @import("std");
const Io = std.Io;

pub const Entry = struct {
    prev: ?*const Entry = null,
    data: *const anyopaque,
    /// Writes the description of the entry (one line, without a newline). Called on panic: must not
    /// allocate memory or acquire locks.
    write: *const fn (data: *const anyopaque, w: *Io.Writer) Io.Writer.Error!void,
};

threadlocal var top: ?*const Entry = null;

/// `entry` must stay valid until `pop`
pub fn push(entry: *Entry) void {
    entry.prev = top;
    top = entry;
}

pub fn pop(entry: *const Entry) void {
    std.debug.assert(top == entry);
    top = entry.prev;
}

/// Entry described by one line of text; the text is formatted when entering and kept in the entry
/// itself (truncated when too long)
pub const Text = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,
    entry: Entry = undefined,

    /// `t` must stay at the same address until `leave`
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

/// Writes the current thread's entries, outermost first, one per line. Writes nothing when there
/// are no entries.
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
