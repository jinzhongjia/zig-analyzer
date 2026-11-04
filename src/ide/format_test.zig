//! Consistency of the renderers in `render/` with the real `zig fmt`.

const std = @import("std");
const testing = std.testing;
const ZigEnv = @import("../project/ZigEnv.zig");
const format = @import("format.zig");
const Renderer = format.Renderer;

/// Array and tuple initializers, where the renderers of the supported versions differ, written
/// the way they are before formatting
const zig_cases = [_][]const u8{
    // One line
    "const a = .{ 1, 2, 3 };\n",
    "const a = .{ 1, 2, 3, };\n",
    "const a = [_]u8{ 1, 2, 3 };\n",
    "const a = [_]u8{0,0,0,0,};\n",
    "const a = .{};\n",
    // A trailing comma on its own line or after the last element
    "const a = [16]u8{\n0,0,0,0, };\n",
    "const a = [16]u8{0,0,0,0,\n};\n",
    // Multiline elements
    "const a = .{ .{\n1,\n2,\n}, 3 };\n",
    "const a = .{ 1, .{\n2,\n3,\n}, 4, };\n",
    "const a = .{\n    .{ 1, 2 },\n    .{\n        3,\n        4,\n    },\n    5, 6,\n};\n",
    "const a = .{ f(\n1,\n2,\n), 3, };\n",
    "const a = .{ \\\\x\n, 1 };\n",
    "const a = .{\n    \\\\x\n    \\\\y\n    ,\n    1, 2,\n    3,\n};\n",
    // Rows and column alignment
    "const a = .{\n    1, 22, 333,\n    4444, 5, 66,\n    777, 8888, 9,\n};\n",
    "const a = .{\n    1, 2, //\n    3, 4, //\n    5, 6, //\n};\n",
    "const a = .{\n    1,\n    2, 3, //\n    4, 5,\n    6, 7, //\n};\n",
    "const a = [_]u8{\n    1, 2,\n    3, 4,\n    5, 6,\n    7,\n};\n",
    "const a = .{\n    1, 2, 3,\n    4,\n    5, 6,\n};\n",
    // Non-ASCII text: its display width is not its byte count
    "const a = .{\n    \"é\", \"s\",\n    \"long\", \"é\",\n};\n",
    "const a = .{\n    \"日本語\", 1, //\n    2, \"é\", //\n};\n",
    "const a = .{\n    1,\n    2, 3, '±', //\n    4, 5,\n    6, 7, //\n};\n",
    "const a = .{ \"é\", \"s\", \"é\",\n};\n",
    // Line comments
    "const a = .{ 1, // c\n2 };\n",
    "const a = .{ 1, 2, // c\n3, 4, // d\n};\n",
    "const a = .{\n    // c\n    1, 2,\n    // d\n    3, 4,\n};\n",
    "const a = .{\n    1, // c\n\n    // d\n    2,\n};\n",
    "const a = .{\n    1,\n    2,\n    // last\n};\n",
    // Blank lines
    "const a = .{\n    1,\n\n    2,\n};\n",
    "const a = .{\n    1,\n\n    2, //\n    3,\n\n    4, 5, //\n    6,\n\n    7,\n\n    8,\n};\n",
    "const a = .{\n    1, 2,\n\n    3, 4,\n};\n",
    "const a = .{\n\n    1,\n\n\n    2,\n\n};\n",
    "const a = .{ 1,\n\n2, 3,\n\n4, };\n",
    "const a = .{\n    .{ 1, 2 },\n\n    .{ 3, 4 },\n\n    5,\n};\n",
    // `zig fmt: off` and `zig fmt: on`
    "const a = .{\n    // zig fmt: off\n    1,   2,\n    // zig fmt: on\n    3,   4,\n};\n",
    "const a = .{\n    .{\n        0, // zig fmt: off\n    },\n    1, 2, // zig fmt: on\n    3,\n    4,\n};\n",
    "const b = .{\n    // zig fmt: off\n    .{\n        0, // zig fmt: on\n    },\n    1, 2, //\n    3, 4,\n};\n",
    "const c = .{\n    .{\n        // zig fmt: off\n        0, // zig fmt: on\n    },\n    1, 2, //\n    3, 4,\n};\n",
    "// zig fmt: off\nconst a = .{ 1,  2 };\n// zig fmt: on\nconst b = .{ 1,  2 };\n",
    "const a = .{ 1, // zig fmt: off\n2,   3, // zig fmt: on\n4,   5, };\n",
    // The versions differ: blank lines kept or removed
    "const a = .{ 333,\n\n22, // c\n };\n",
    "const a = .{ \"s\",\n\n333, // zig fmt: off\nabc };\n",
    "const a = .{ \"é\",\n\nf(a, b), // zig fmt: on\n1,\n };\n",
    // The versions differ: elements of one line kept together or split
    "const a = .{ 333,\n.{\n1,\n2,\n}, \"s\", // c\n1, abc, // c\n };\n",
    "const a = .{ \"é\",\n\"é\", // c\nabc, .{ 1, 2 }, // c\n };\n",
    "const a = .{ \"s\",\n333, \"é\", // c\n.{ 1, 2 },\n1, abc, // c\n };\n",
    "const a = .{ 22, // c\n1,\n22, .{ 1, 2 }, \\\\x\n, // c\n1, abc, };\n",
    "const a = .{ .{ 1, 2 }, \\\\x\n, // c\n\"s\", .{ 1, 2 }, .{ 1, 2 }, // c\n };\n",
    // Nesting
    "const a = .{\n    .{},\n    .{\n        .{},\n        .{\n            .{},\n        },\n    },\n};\n",
    "const a = .{\n    asm (.{\n            0,\n        }\n        : [_] \"\" (_),\n    ),\n};\n",
    // Named fields and calls next to initializers
    "const a = .{ .x = 1, .y = .{ 1, 2,\n3, }, };\n",
    "fn f() void {\n    g(.{ 1, 2,\n3, 4, }, .{\n5,\n\n6,\n});\n}\n",
};

const zon_cases = [_][]const u8{
    ".{ 1, 2,\n3, }\n",
    ".{\n    .a = .{\n        1,\n\n        2, //\n        3,\n    },\n}\n",
};

fn renderCase(a: std.mem.Allocator, text: []const u8, mode: format.Mode, renderer: Renderer) ![]const u8 {
    return try format.renderText(a, text, mode, renderer) orelse {
        std.debug.print("rejected: {s}\n", .{text});
        return error.TestUnexpectedResult;
    };
}

test "the renderers match zig fmt of the version in PATH" {
    var env = ZigEnv.query(testing.allocator, testing.io, null) catch |err| switch (err) {
        error.ZigNotFound => return error.SkipZigTest,
        else => |e| return e,
    };
    defer env.deinit(testing.allocator);
    const renderer = Renderer.find(env.version) orelse return error.SkipZigTest;

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const count = zig_cases.len + zon_cases.len;
    const names = try a.alloc([]const u8, count);
    const texts = try a.alloc([]const u8, count);
    const modes = try a.alloc(format.Mode, count);
    for (zig_cases, 0..) |text, i| {
        names[i] = try std.fmt.allocPrint(a, "c{d}.zig", .{i});
        texts[i] = text;
        modes[i] = .zig;
    }
    for (zon_cases, zig_cases.len..) |text, i| {
        names[i] = try std.fmt.allocPrint(a, "c{d}.zon", .{i});
        texts[i] = text;
        modes[i] = .zon;
    }
    for (names, texts) |name, text| try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = text });

    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const argv = try a.alloc([]const u8, count + 2);
    argv[0] = env.zig_exe;
    argv[1] = "fmt";
    for (names, argv[2..]) |name, *arg| arg.* = try std.fs.path.join(a, &.{ root, name });
    const result = try std.process.run(a, testing.io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term) catch |err| {
        std.debug.print("zig fmt failed:\n{s}\n", .{result.stderr});
        return err;
    };

    var differ: usize = 0;
    for (names, texts, modes) |name, text, mode| {
        const expected = try tmp.dir.readFileAlloc(testing.io, name, a, .limited(1024 * 1024));
        const actual = try renderCase(a, text, mode, renderer);
        testing.expectEqualStrings(expected, actual) catch |err| {
            std.debug.print("source of {s}:\n{s}\n", .{ name, text });
            return err;
        };
        for (std.enums.values(Renderer)) |other| {
            if (other != renderer and !std.mem.eql(u8, actual, try renderCase(a, text, mode, other))) {
                differ += 1;
                break;
            }
        }
    }
    // The cases tell the versions apart: otherwise a wrong choice of renderer would go unnoticed
    try testing.expect(differ >= 8);
}

test "the copies of the renderers are those of the version in PATH" {
    var env = ZigEnv.query(testing.allocator, testing.io, null) catch |err| switch (err) {
        error.ZigNotFound => return error.SkipZigTest,
        else => |e| return e,
    };
    defer env.deinit(testing.allocator);
    const copy = switch (Renderer.find(env.version) orelse return error.SkipZigTest) {
        .zig_0_17_0 => @embedFile("render/zig_0_17_0.zig"),
        .zig_0_17_1 => @embedFile("render/zig_0_17_1.zig"),
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fs.path.join(a, &.{ env.lib_dir, "std", "zig", "Ast", "Render.zig" });
    const official = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(16 * 1024 * 1024));
    // The only change: the copies are not inside the standard library
    const expected = try std.mem.replaceOwned(u8, a, official, "@import(\"../../std.zig\")", "@import(\"std\")");
    try testing.expect(std.mem.eql(u8, expected, copy));
}

test "every supported version has its renderer, and others use the built one" {
    for (ZigEnv.supported_versions) |version| try testing.expect(Renderer.find(version) != null);
    try testing.expectEqual(.zig_0_17_0, Renderer.of("0.17.0"));
    try testing.expectEqual(.zig_0_17_1, Renderer.of("0.17.1"));
    try testing.expectEqual(Renderer.built, Renderer.of("0.18.0-dev.1+abc"));
    try testing.expectEqual(null, Renderer.find("0.17.2"));
}

test "blank lines in array initializers follow the renderer" {
    // Expected values are the results of `zig fmt` of each version: formatting by the zig
    // zig-analyzer was built with disagreed with the other version here
    const source = "const a = .{\n    1,\n\n    2, //\n    3,\n\n    4, 5, //\n    6,\n\n    7,\n\n    8,\n};\n";
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "const a = .{\n    1,\n    2, //\n    3,\n    4, 5, //\n    6, 7,\n\n    8,\n};\n",
        try renderCase(a, source, .zig, .zig_0_17_0),
    );
    try testing.expectEqualStrings(
        "const a = .{\n    1,\n\n    2, //\n    3,\n\n    4, 5, //\n    6, 7,\n\n    8,\n};\n",
        try renderCase(a, source, .zig, .zig_0_17_1),
    );
}

test "syntax only one version's parser accepts reaches either renderer without a crash" {
    // Which of these parse depends on the zig zig-analyzer was built with, and the renderer on the
    // user's zig: every combination must give a result or refuse
    const cases = [_]struct { source: []const u8, accepted_by: Renderer }{
        .{ .source = "extern fn f(\n    /// doc\n    ...,\n) void;\n", .accepted_by = .zig_0_17_0 },
        .{ .source = "const T = [*c// note\n]u8;\n", .accepted_by = .zig_0_17_1 },
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (cases) |case| for (std.enums.values(Renderer)) |renderer| {
        const result = try format.renderText(a, case.source, .zig, renderer);
        try testing.expectEqual(case.accepted_by == Renderer.built, result != null);
    };
}
