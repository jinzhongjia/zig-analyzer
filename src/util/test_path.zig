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

test toWindows {
    const std = @import("std");
    try std.testing.expectEqualStrings("C:\\p\\src\\main.zig", toWindows("/p/src/main.zig"));
}
