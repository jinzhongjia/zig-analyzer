const std = @import("std");
const shapes = @import("shapes.zig");

pub fn main() void {
    const square = shapes.Square{ .side = 3 };
    const total = shapes.area(square);
    std.debug.print("{}\n", .{total});
}

test "area" {
    try std.testing.expectEqual(@as(u32, 9), shapes.area(.{ .side = 3 }));
}
