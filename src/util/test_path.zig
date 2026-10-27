//! For tests: converts a posix-style absolute path to a native absolute path (on Windows, adds a
//! drive letter and switches to backslashes), so that code that depends on native path rules gets
//! the same results on every platform.

const builtin = @import("builtin");

pub fn native(comptime posix: []const u8) []const u8 {
    if (builtin.os.tag != .windows) return posix;
    return toWindows(posix);
}

fn toWindows(comptime posix: []const u8) []const u8 {
    return &struct {
        const value = blk: {
            var buf: [posix.len + 2]u8 = undefined;
            buf[0..2].* = "C:".*;
            for (posix, buf[2..]) |c, *out| out.* = if (c == '/') '\\' else c;
            break :blk buf;
        };
    }.value;
}

/// Same as `native`, for paths known only at runtime (e.g. parsed from a test fixture)
pub fn nativeAlloc(a: @import("std").mem.Allocator, posix: []const u8) ![]const u8 {
    if (builtin.os.tag != .windows) return a.dupe(u8, posix);
    const out = try a.alloc(u8, posix.len + 2);
    out[0..2].* = "C:".*;
    for (posix, out[2..]) |c, *o| o.* = if (c == '/') '\\' else c;
    return out;
}

test toWindows {
    const std = @import("std");
    try std.testing.expectEqualStrings("C:\\p\\src\\main.zig", toWindows("/p/src/main.zig"));
}
