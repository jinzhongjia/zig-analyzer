//! A text buffer shared by the file text input and the parse results of the file: a parse result
//! retains the buffer instead of copying the whole text.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Text = @This();

/// Owners: the `FileText` value of the file and each parse result that reads the text
refs: std.atomic.Value(u32) = .init(1),
len: usize,

/// The text, without the sentinel byte
pub fn bytes(self: *const Text) []const u8 {
    const data: [*]const u8 = @ptrCast(self);
    return data[@sizeOf(Text)..][0..self.len];
}

/// The text followed by a sentinel byte, as the source of a parse
pub fn source(self: *const Text) [:0]const u8 {
    const data: [*]const u8 = @ptrCast(self);
    return data[@sizeOf(Text)..][0..self.len :0];
}

/// Copies `text` into a new buffer, with one reference
pub fn init(gpa: Allocator, text: []const u8) Allocator.Error!*Text {
    const buf = try gpa.alignedAlloc(u8, .of(Text), @sizeOf(Text) + text.len + 1);
    @memcpy(buf[@sizeOf(Text)..][0..text.len], text);
    buf[@sizeOf(Text) + text.len] = 0;
    const self: *Text = @ptrCast(buf.ptr);
    self.* = .{ .len = text.len };
    return self;
}

pub fn retain(self: *Text) void {
    _ = self.refs.fetchAdd(1, .monotonic);
}

/// Releases a reference; the last one frees the buffer
pub fn release(self: *Text, gpa: Allocator) void {
    if (self.refs.fetchSub(1, .acq_rel) != 1) return;
    const p: [*]align(@alignOf(Text)) u8 = @ptrCast(self);
    gpa.free(p[0 .. @sizeOf(Text) + self.len + 1]);
}

test "a text buffer keeps the text and a sentinel byte" {
    const gpa = std.testing.allocator;
    const text: *Text = try .init(gpa, "const a = 1;\n");
    text.retain();
    try std.testing.expectEqualStrings("const a = 1;\n", text.bytes());
    try std.testing.expectEqual(@as(u8, 0), text.source()[text.len]);
    text.release(gpa);
    try std.testing.expectEqualStrings("const a = 1;\n", text.bytes());
    text.release(gpa);
}
