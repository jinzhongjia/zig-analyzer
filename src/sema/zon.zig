//! Values of `.zon` files: `@import` of a `.zon` file yields the value in it. Without a result
//! type, it matches the compiler: struct literals are anonymous structs and array literals are
//! tuples, with all fields comptime fields; integers and characters are comptime_int, floats are
//! comptime_float, and strings are `*const [n:0]u8`. Types and values are represented the same
//! way as the same literals without a result type in source code (see `anonInit` in `infer`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Zoir = std.zig.Zoir;
const nesting = @import("../syntax/nesting.zig");
const InternPool = @import("InternPool.zig");
const Index = InternPool.Index;
const TypedValue = InternPool.TypedValue;
const value = @import("value.zig");

const log = std.log.scoped(.zon);

/// Maximum nesting depth of values (the same as the interpreter's limit for interned aggregate
/// values); deeper values are treated as unknown
const max_depth = 256;

/// Value of ZON text without a result type. Unknown when there are syntax errors or errors
/// reported by ZonGen (such as duplicate field names); without a result type the compiler reports
/// errors for `inf` and `nan`, so values containing them are unknown too.
pub fn lower(gpa: Allocator, ip: *InternPool, text: []const u8) Allocator.Error!TypedValue {
    const source = try gpa.dupeSentinel(u8, text, 0);
    defer gpa.free(source);
    const zoir = try generate(gpa, source) orelse return .unknown;
    defer zoir.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var l: Lowering = .{ .ip = ip, .zoir = &zoir, .arena = arena.allocator() };
    return l.node(.root, 0);
}

/// With a result type, the compiler parses ZON according to the result type. When the value
/// without a result type is a scalar (bool, null, integer, float, enum literal), converting it to
/// the result type gives the same result as parsing according to the result type; strings, tuples
/// and structs can be parsed according to the result type into slices, arrays, pointers or structs
/// with default values, which conversion cannot produce
pub fn isScalar(ty: Index) bool {
    return switch (ty) {
        .bool_type, .null_type, .comptime_int_type, .comptime_float_type, .enum_literal_type => true,
        else => false,
    };
}

/// Parses and runs ZonGen; null when there are errors. The official parser recurses level by
/// level: as in `live.check`, the thread to run on is chosen by nesting depth
fn generate(gpa: Allocator, source: [:0]const u8) Allocator.Error!?Zoir {
    const depth = try nesting.estimate(gpa, source, nesting.thread_depth);
    if (depth <= nesting.inline_depth) return generateSource(gpa, source);
    if (depth > nesting.thread_depth) return null;
    var result: Allocator.Error!?Zoir = undefined;
    const thread = std.Thread.spawn(.{ .stack_size = nesting.threadStackSize(depth, nesting.thread_depth) }, generateInto, .{ gpa, source, &result }) catch |err| {
        log.warn("cannot spawn a thread to parse a deeply nested ZON file: {t}", .{err});
        return null;
    };
    thread.join();
    return result;
}

fn generateInto(gpa: Allocator, source: [:0]const u8, result: *Allocator.Error!?Zoir) void {
    result.* = generateSource(gpa, source);
}

fn generateSource(gpa: Allocator, source: [:0]const u8) Allocator.Error!?Zoir {
    var tree = try Ast.parse(gpa, source, .{ .mode = .zon });
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return null;
    const zoir = try std.zig.ZonGen.generate(gpa, tree, .{});
    if (zoir.hasCompileErrors()) {
        zoir.deinit(gpa);
        return null;
    }
    return zoir;
}

const Lowering = struct {
    ip: *InternPool,
    zoir: *const Zoir,
    arena: Allocator,

    fn node(l: *Lowering, n: Zoir.Node.Index, depth: u32) Allocator.Error!TypedValue {
        const ip = l.ip;
        switch (n.get(l.zoir)) {
            .true => return .{ .ty = .bool_type, .val = .true_value },
            .false => return .{ .ty = .bool_type, .val = .false_value },
            .null => return .{ .ty = .null_type, .val = .null_value },
            .pos_inf, .neg_inf, .nan => return .unknown,
            .int_literal => |int| switch (int) {
                .small => |x| return l.comptimeInt(x),
                // Integers beyond i128 have no value representation
                .big => |b| return if (b.toInt(i128)) |x| l.comptimeInt(x) else |_| .{ .ty = .comptime_int_type },
            },
            .char_literal => |c| return l.comptimeInt(c),
            .float_literal => |x| return .{ .ty = .comptime_float_type, .val = try value.floatValue(ip, .comptime_float_type, x) },
            .enum_literal => |name| return .{ .ty = .enum_literal_type, .val = try ip.get(.{ .enum_literal = name.get(l.zoir) }) },
            .string_literal => |s| {
                const ty = try ip.stringLiteralType(s.len);
                return .{ .ty = ty, .val = try ip.get(.{ .bytes = .{ .ty = ty, .bytes = s } }) };
            },
            .empty_literal => {
                const ty = try ip.get(.{ .tuple_type = .{ .types = &.{} } });
                return .{ .ty = ty, .val = try value.aggregate(ip, l.arena, ty, &.{}) };
            },
            .array_literal => |elems| return l.container(null, elems, depth),
            .struct_literal => |s| return l.container(s.names, s.vals, depth),
        }
    }

    fn comptimeInt(l: *Lowering, x: i128) Allocator.Error!TypedValue {
        return .{ .ty = .comptime_int_type, .val = try l.ip.get(.{ .int_value = .{ .ty = .comptime_int_type, .value = x } }) };
    }

    /// A tuple (`names` is null) or an anonymous struct. All fields are comptime fields, with the
    /// values belonging to the type; when the type of any field is unknown, the whole value is
    /// unknown
    fn container(l: *Lowering, names: ?[]const Zoir.NullTerminatedString, elems: Zoir.Node.Index.Range, depth: u32) Allocator.Error!TypedValue {
        if (depth >= max_depth) return .unknown;
        const ip = l.ip;
        const types = try l.arena.alloc(Index, elems.len);
        const values = try l.arena.alloc(Index, elems.len);
        var known = true;
        for (types, values, 0..) |*t, *v, i| {
            const field = try l.node(elems.at(@intCast(i)), depth + 1);
            if (field.ty == .unknown) return .unknown;
            t.* = field.ty;
            v.* = field.val orelse .unknown;
            if (field.val == null) known = false;
        }
        const ty = if (names) |ns| blk: {
            const strs = try l.arena.alloc([]const u8, ns.len);
            for (ns, strs) |name, *s| s.* = name.get(l.zoir);
            break :blk try ip.get(.{ .anon_struct_type = .{ .names = strs, .types = types, .values = values } });
        } else try ip.get(.{ .tuple_type = .{ .types = types, .values = values } });
        return .{ .ty = ty, .val = if (known) try value.aggregate(ip, l.arena, ty, values) else null };
    }
};

const testing = std.testing;

test "ZON text lowers to the value without a result type" {
    var ip: InternPool = try .init(testing.allocator, testing.io);
    defer ip.deinit();
    const tv = try lower(testing.allocator, &ip, ".{ .x = -1, .list = .{ 'a', 2.5, .{} }, .name = \"hi\", .on = true, .none = null, .mode = .fast }");
    try testing.expect(tv.val != null);
    const s = ip.key(tv.ty).anon_struct_type;
    try testing.expectEqual(6, s.names.len);
    try testing.expectEqualStrings("list", s.names[1]);
    try testing.expectEqual(Index.comptime_int_type, s.types[0]);
    try testing.expectEqual(@as(?i128, -1), value.intOf(&ip, s.values[0]));
    const list = ip.key(s.types[1]).tuple_type;
    try testing.expectEqual(Index.comptime_int_type, list.types[0]);
    try testing.expectEqual(@as(?i128, 'a'), value.intOf(&ip, list.values[0]));
    try testing.expectEqual(Index.comptime_float_type, list.types[1]);
    try testing.expectEqual(0, ip.key(list.types[2]).tuple_type.types.len);
    try testing.expectEqual(try ip.stringLiteralType(2), s.types[2]);
    try testing.expectEqualStrings("hi", ip.key(s.values[2]).bytes.bytes);
    try testing.expectEqual(Index.true_value, s.values[3]);
    try testing.expectEqual(Index.null_value, s.values[4]);
    try testing.expectEqualStrings("fast", ip.key(s.values[5]).enum_literal);
}

test "ZON text the compiler rejects without a result type has no value" {
    var ip: InternPool = try .init(testing.allocator, testing.io);
    defer ip.deinit();
    // Syntax errors, duplicate field names, inf / nan without a result type
    for ([_][]const u8{ ".{ .x = 1, ", ".{ .x = 1, .x = 2 }", ".{ .f = inf }", "-inf", "nan" }) |text| {
        try testing.expectEqual(Index.unknown, (try lower(testing.allocator, &ip, text)).ty);
    }
}

test "ZON values nested beyond the limit are unknown" {
    var ip: InternPool = try .init(testing.allocator, testing.io);
    defer ip.deinit();
    for ([_]struct { u32, bool }{ .{ max_depth, true }, .{ max_depth + 1, false } }) |c| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(testing.allocator);
        for (0..c[0]) |_| try text.appendSlice(testing.allocator, ".{");
        try text.append(testing.allocator, '1');
        try text.appendNTimes(testing.allocator, '}', c[0]);
        const tv = try lower(testing.allocator, &ip, text.items);
        try testing.expectEqual(c[1], tv.val != null);
        if (!c[1]) try testing.expectEqual(Index.unknown, tv.ty);
    }
}
