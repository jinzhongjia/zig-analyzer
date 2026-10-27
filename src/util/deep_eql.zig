//! Compares two values structurally: slices element by element, unions by tag and payload. Used to
//! implement `eql` for query values that contain slices.

const std = @import("std");

pub fn deepEql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            inline for (s.field_names) |name| {
                if (!deepEql(@field(a, name), @field(b, name))) return false;
            }
            return true;
        },
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("untagged union: " ++ @typeName(T));
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            switch (a) {
                inline else => |va, tag| return deepEql(va, @field(b, @tagName(tag))),
            }
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("unsupported pointer: " ++ @typeName(T));
            if (a.len != b.len) return false;
            if (@typeInfo(p.child) == .int) return std.mem.eql(p.child, a, b);
            for (a, b) |x, y| if (!deepEql(x, y)) return false;
            return true;
        },
        .optional => {
            if (a == null or b == null) return a == null and b == null;
            return deepEql(a.?, b.?);
        },
        .void => return true,
        else => return a == b,
    }
}

test deepEql {
    const U = union(enum) { a: []const u8, b: ?u32, c };
    const S = struct { name: []const u8, items: []const U };
    const x: S = .{ .name = "n", .items = &.{ .{ .a = "x" }, .{ .b = 1 }, .c } };
    const y: S = .{ .name = "n", .items = &.{ .{ .a = "x" }, .{ .b = 1 }, .c } };
    const z: S = .{ .name = "n", .items = &.{ .{ .a = "x" }, .{ .b = null }, .c } };
    try std.testing.expect(deepEql(x, y));
    try std.testing.expect(!deepEql(x, z));
}
