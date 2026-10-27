//! LSP base protocol: reading and writing JSON-RPC messages framed by `Content-Length` headers.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const ReadError = error{
    EndOfStream,
    ReadFailed,
    InvalidHeader,
    MessageTooLong,
    OutOfMemory,
};

/// Maximum size of a single message body, the same as the file size limit (open documents
/// arrive in messages)
pub const max_message_len = std.math.maxInt(u32);

/// Reads one message body; the caller owns the returned memory.
pub fn readMessage(reader: *Io.Reader, gpa: Allocator) ReadError![]u8 {
    var content_length: ?usize = null;
    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            error.ReadFailed => return error.ReadFailed,
            error.StreamTooLong => return error.InvalidHeader,
        };
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (trimmed.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.InvalidHeader;
        const name = std.mem.trim(u8, trimmed[0..colon], " ");
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidHeader;
        }
        // Other headers such as Content-Type are ignored
    }
    const len = content_length orelse return error.InvalidHeader;
    if (len > max_message_len) return error.MessageTooLong;
    return reader.readAllocAll(gpa, len) catch |err| switch (err) {
        error.EndOfStream => error.EndOfStream,
        error.ReadFailed => error.ReadFailed,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Thread-safe message writer: requests are handled concurrently in multiple tasks, and
/// responses must be written serially.
pub const Writer = struct {
    io: Io,
    inner: *Io.Writer,
    mutex: Io.Mutex = .init,

    pub fn writeMessage(w: *Writer, body: []const u8) Io.Writer.Error!void {
        w.mutex.lockUncancelable(w.io);
        defer w.mutex.unlock(w.io);
        try w.inner.print("Content-Length: {d}\r\n\r\n", .{body.len});
        try w.inner.writeAll(body);
        try w.inner.flush();
    }
};

test "read multiple messages" {
    const input = "Content-Length: 2\r\n\r\n{}" ++
        "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\ncontent-length: 4\r\n\r\nnull";
    var reader: Io.Reader = .fixed(input);
    const gpa = std.testing.allocator;

    const a = try readMessage(&reader, gpa);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("{}", a);
    const b = try readMessage(&reader, gpa);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("null", b);
    try std.testing.expectError(error.EndOfStream, readMessage(&reader, gpa));
}

test "missing Content-Length" {
    var reader: Io.Reader = .fixed("X: 1\r\n\r\n");
    try std.testing.expectError(error.InvalidHeader, readMessage(&reader, std.testing.allocator));
}

test "write message" {
    var buf: [64]u8 = undefined;
    var inner: Io.Writer = .fixed(&buf);
    var w: Writer = .{ .io = std.testing.io, .inner = &inner };
    try w.writeMessage("{}");
    try std.testing.expectEqualStrings("Content-Length: 2\r\n\r\n{}", inner.buffered());
}
