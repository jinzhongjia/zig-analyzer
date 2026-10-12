//! 生成的 LSP 类型所用的 JSON 辅助：联合类型、字符串字面量类型、整数枚举。

const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

/// LSP 中 `kind: "create"` 这类字符串字面量类型。解析时校验值必须相等。
pub fn StringLiteral(comptime value: []const u8) type {
    return struct {
        pub const literal = value;

        pub fn jsonParse(allocator: Allocator, source: anytype, options: json.ParseOptions) !@This() {
            const v = try json.innerParse(json.Value, allocator, source, options);
            return jsonParseFromValue(allocator, v, options);
        }

        pub fn jsonParseFromValue(_: Allocator, source: json.Value, _: json.ParseOptions) json.ParseFromValueError!@This() {
            if (source != .string or !std.mem.eql(u8, source.string, value)) return error.UnexpectedToken;
            return .{};
        }

        pub fn jsonStringify(_: @This(), jw: anytype) !void {
            try jw.write(value);
        }
    };
}

/// 整数枚举：以数字形式序列化。
pub fn IntEnum(comptime T: type) type {
    return struct {
        pub fn jsonStringify(self: T, jw: anytype) !void {
            try jw.write(@backingInt(self));
        }
    };
}

/// LSP 的 `A | B | C` 联合类型：先按 JSON 值的形状筛选变体，对象类型先严格（不允许未知字段）
/// 再宽松地尝试，取第一个成功的变体。
pub fn Union(comptime T: type) type {
    const info = @typeInfo(T).@"union";
    return struct {
        pub fn jsonParse(allocator: Allocator, source: anytype, options: json.ParseOptions) !T {
            const v = try json.innerParse(json.Value, allocator, source, options);
            return jsonParseFromValue(allocator, v, options);
        }

        pub fn jsonParseFromValue(allocator: Allocator, source: json.Value, options: json.ParseOptions) json.ParseFromValueError!T {
            for ([_]bool{ false, true }) |lenient| {
                var opts = options;
                opts.ignore_unknown_fields = lenient;
                inline for (info.field_names, info.field_types) |name, F| {
                    if (shapeMatches(F, source)) {
                        if (json.innerParseFromValue(F, allocator, source, opts)) |value| {
                            return @unionInit(T, name, value);
                        } else |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => {},
                        }
                    }
                }
            }
            return error.UnexpectedToken;
        }

        pub fn jsonStringify(self: T, jw: anytype) !void {
            switch (self) {
                inline else => |value| try jw.write(value),
            }
        }
    };
}

/// 判断 JSON 值的形状能否解析为 `T`，避免把 `"5"` 解析成整数这类误匹配。
fn shapeMatches(comptime T: type, v: json.Value) bool {
    if (T == json.Value) return true;
    return switch (@typeInfo(T)) {
        .optional => |o| v == .null or shapeMatches(o.child, v),
        .bool => v == .bool,
        .int => v == .integer or v == .number_string,
        .float => v == .integer or v == .float or v == .number_string,
        .@"enum" => if (@hasDecl(T, "jsonStringify")) v == .integer else v == .string,
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) v == .string else v == .array,
            else => shapeMatches(p.child, v),
        },
        .array => v == .array,
        .@"struct" => |s| if (s.is_tuple)
            v == .array
        else if (@hasDecl(T, "literal"))
            v == .string and std.mem.eql(u8, v.string, T.literal)
        else
            v == .object,
        .@"union" => true,
        .void => v == .null,
        else => false,
    };
}

test Union {
    const U = union(enum) {
        integer: i32,
        string: []const u8,
        point: struct { x: i32, y: i32 },
        pub const jsonParseFromValue = Union(@This()).jsonParseFromValue;
        pub const jsonParse = Union(@This()).jsonParse;
        pub const jsonStringify = Union(@This()).jsonStringify;
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("5", (try json.parseFromSliceLeaky(U, a, "\"5\"", .{})).string);
    try std.testing.expectEqual(5, (try json.parseFromSliceLeaky(U, a, "5", .{})).integer);
    try std.testing.expectEqual(2, (try json.parseFromSliceLeaky(U, a, "{\"x\":1,\"y\":2}", .{})).point.y);

    var out: std.Io.Writer.Allocating = .init(a);
    try json.Stringify.value(U{ .string = "hi" }, .{}, &out.writer);
    try std.testing.expectEqualStrings("\"hi\"", out.written());
}

test StringLiteral {
    const L = StringLiteral("create");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    _ = try json.parseFromSliceLeaky(L, arena.allocator(), "\"create\"", .{});
    try std.testing.expectError(error.UnexpectedToken, json.parseFromSliceLeaky(L, arena.allocator(), "\"delete\"", .{}));
}
