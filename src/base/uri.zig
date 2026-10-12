//! `file://` URI 与文件系统路径互转。

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Error = error{ UnsupportedScheme, InvalidUri } || Allocator.Error;

/// `file:///a%20b/c.zig` → `/a b/c.zig`；Windows 下 `file:///c%3A/x` → `c:\x`
pub fn toPath(gpa: Allocator, uri: []const u8) Error![]u8 {
    return toPathFor(builtin.target.os.tag == .windows, gpa, uri);
}

/// `/a b/c.zig` → `file:///a%20b/c.zig`
pub fn fromPath(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    return fromPathFor(builtin.target.os.tag == .windows, gpa, path);
}

fn toPathFor(comptime windows: bool, gpa: Allocator, uri: []const u8) Error![]u8 {
    const prefix = "file://";
    if (!std.ascii.startsWithIgnoreCase(uri, prefix)) return error.UnsupportedScheme;
    var rest = uri[prefix.len..];
    // 去掉 authority（通常为空，`file://localhost/...` 也视为本地）
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidUri;
    rest = rest[slash..];
    if (std.mem.indexOfAny(u8, rest, "?#")) |end| rest = rest[0..end];

    const buf = try gpa.dupe(u8, rest);
    errdefer gpa.free(buf);
    var path = std.Uri.percentDecodeInPlace(buf);

    if (windows) {
        // `/c:/x` → `c:\x`
        if (path.len >= 3 and path[0] == '/' and std.ascii.isAlphabetic(path[1]) and path[2] == ':') path = path[1..];
        for (path) |*c| if (c.* == '/') {
            c.* = '\\';
        };
    }
    const result = try gpa.dupe(u8, path);
    gpa.free(buf);
    return result;
}

fn fromPathFor(comptime windows: bool, gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    w.writeAll("file://") catch return error.OutOfMemory;
    if (windows and path.len >= 2 and path[1] == ':') w.writeByte('/') catch return error.OutOfMemory;
    for (path) |c| {
        const ch = if (windows and c == '\\') '/' else c;
        if (isUnreserved(ch) or ch == '/' or (windows and ch == ':')) {
            w.writeByte(ch) catch return error.OutOfMemory;
        } else {
            w.print("%{X:0>2}", .{ch}) catch return error.OutOfMemory;
        }
    }
    return out.toOwnedSlice();
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

test "posix 往返" {
    const gpa = std.testing.allocator;
    const uri = try fromPathFor(false, gpa, "/home/u/my project/a+b.zig");
    defer gpa.free(uri);
    try std.testing.expectEqualStrings("file:///home/u/my%20project/a%2Bb.zig", uri);
    const path = try toPathFor(false, gpa, uri);
    defer gpa.free(path);
    try std.testing.expectEqualStrings("/home/u/my project/a+b.zig", path);
}

test "windows 往返" {
    const gpa = std.testing.allocator;
    const uri = try fromPathFor(true, gpa, "C:\\work\\x y.zig");
    defer gpa.free(uri);
    try std.testing.expectEqualStrings("file:///C:/work/x%20y.zig", uri);
    // VS Code 会把冒号编码为 %3A，盘符小写
    const path = try toPathFor(true, gpa, "file:///c%3A/work/x%20y.zig");
    defer gpa.free(path);
    try std.testing.expectEqualStrings("c:\\work\\x y.zig", path);
}

test "非 file scheme" {
    try std.testing.expectError(error.UnsupportedScheme, toPath(std.testing.allocator, "untitled:Untitled-1"));
}
