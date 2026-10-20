//! 测试用：把 posix 写法的绝对路径转为本机绝对路径（Windows 上加盘符并改用反斜杠），
//! 使依赖本机路径规则的代码在各平台上得到相同的结果。

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

/// 同 `native`，路径在运行时才知道（如从测试 fixture 中解析出来）
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
