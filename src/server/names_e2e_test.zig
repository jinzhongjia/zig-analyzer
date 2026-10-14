//! 端到端：goto definition 与补全（跨模块、进入标准库、单文件模式下按需加载标准库）。

const std = @import("std");
const testing = std.testing;
const za = @import("../zig_analyzer.zig");
const fixture = za.project.fixture;
const Harness = @import("test_harness.zig").Harness;

const Empty = struct {};

const main_text =
    \\const std = @import("std");
    \\const lib = @import("lib");
    \\pub fn main() void {
    \\    lib.hello();
    \\    const A = std.mem.Allocator;
    \\    _ = A;
    \\    std.mem.
    \\}
    \\
;

const project_files = [_]fixture.File{
    .{ .path = "build.zig", .text = fixture.basic[0].text },
    .{ .path = "src/main.zig", .text = main_text },
    .{ .path = "src/lib.zig", .text = "pub fn hello() void {}\n" },
};

fn position(text: []const u8, needle: []const u8) struct { line: u32, character: u32 } {
    const offset = std.mem.indexOf(u8, text, needle).?;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..offset], '\n')) |i| i + 1 else 0;
    return .{ .line = @intCast(std.mem.count(u8, text[0..offset], "\n")), .character = @intCast(offset - line_start) };
}

/// 跳转结果：「文件名:行」
fn gotoAt(h: *Harness, uri: []const u8, text: []const u8, needle: []const u8) ![]const u8 {
    const resp = try h.request("textDocument/definition", .{ .textDocument = .{ .uri = uri }, .position = position(text, needle) });
    const result = resp.object.get("result").?;
    if (result == .null) return "null";
    const target = result.object;
    const target_uri = target.get("uri").?.string;
    const line = target.get("range").?.object.get("start").?.object.get("line").?.integer;
    return std.fmt.allocPrint(h.arena.allocator(), "{s}:{d}", .{ target_uri[std.mem.lastIndexOfScalar(u8, target_uri, '/').? + 1 ..], line });
}

fn completionLabels(h: *Harness, uri: []const u8, line: u32, character: u32) ![]const []const u8 {
    const resp = try h.request("textDocument/completion", .{ .textDocument = .{ .uri = uri }, .position = .{ .line = line, .character = character } });
    var labels: std.ArrayList([]const u8) = .empty;
    for (resp.object.get("result").?.array.items) |item| try labels.append(h.arena.allocator(), item.object.get("label").?.string);
    return labels.items;
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// 标准库中 `pub const Allocator = ...` 所在的行
fn stdAllocatorLine(h: *Harness) !i64 {
    const env = h.server.zigEnv().?;
    const path = try std.fs.path.join(h.arena.allocator(), &.{ env.std_dir, "mem.zig" });
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, h.arena.allocator(), .unlimited);
    return position(text, "pub const Allocator").line;
}

test "goto definition and completion across modules and into std" {
    var project = try fixture.Project.create(&project_files);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(h.arena.allocator(), try project.path(h.arena.allocator(), "src/main.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = main_text } });
    _ = try h.request("zig-analyzer/waitIdle", {});

    try testing.expectEqualStrings("lib.zig:0", try gotoAt(&h, uri, main_text, "hello"));
    try testing.expectEqualStrings("lib.zig:0", try gotoAt(&h, uri, main_text, "\"lib\""));
    const expected = try std.fmt.allocPrint(h.arena.allocator(), "mem.zig:{d}", .{try stdAllocatorLine(&h)});
    try testing.expectEqualStrings(expected, try gotoAt(&h, uri, main_text, "Allocator;"));
    try testing.expectEqualStrings("main.zig:4", try gotoAt(&h, uri, main_text, "A;"));

    // `std.mem.` 之后：标准库 mem 的 pub 声明
    const p = position(main_text, "std.mem.\n");
    const labels = try completionLabels(&h, uri, p.line, p.character + @as(u32, "std.mem.".len));
    try testing.expect(contains(labels, "Allocator"));
    try testing.expect(contains(labels, "eql"));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "single-file mode: std is loaded on demand for name resolution" {
    const text =
        \\const std = @import("std");
        \\pub fn main() void {
        \\    _ = std.mem.Allocator;
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{.{ .path = "one.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(h.arena.allocator(), try project.path(h.arena.allocator(), "one.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});

    const expected = try std.fmt.allocPrint(h.arena.allocator(), "mem.zig:{d}", .{try stdAllocatorLine(&h)});
    try testing.expectEqualStrings(expected, try gotoAt(&h, uri, text, "Allocator"));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "types through the real std: hover, member completion and inlay hints" {
    const text =
        \\const std = @import("std");
        \\fn use(gpa: std.mem.Allocator, list: []const u8) void {
        \\    const n = list.len;
        \\    _ = n;
        \\    gpa.
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{.{ .path = "one.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(h.arena.allocator(), try project.path(h.arena.allocator(), "one.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});

    const hover_resp = try h.request("textDocument/hover", .{ .textDocument = .{ .uri = uri }, .position = position(text, "gpa:") });
    const value = hover_resp.object.get("result").?.object.get("contents").?.object.get("value").?.string;
    try testing.expectEqualStrings("```zig\ngpa: Allocator\n```", value);

    const p = position(text, "gpa.\n");
    const labels = try completionLabels(&h, uri, p.line, p.character + 4);
    for ([_][]const u8{ "ptr", "vtable", "alloc", "free" }) |l| {
        testing.expect(contains(labels, l)) catch |err| {
            std.debug.print("missing completion `{s}`\n", .{l});
            return err;
        };
    }

    const hints = try h.request("textDocument/inlayHint", .{ .textDocument = .{ .uri = uri }, .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 6, .character = 0 } } });
    const first = hints.object.get("result").?.array.items[0].object;
    try testing.expectEqualStrings(": usize", first.get("label").?.string);
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "generic std containers through LSP: hover, completion and inlay hints" {
    const text =
        \\const std = @import("std");
        \\fn use(gpa: std.mem.Allocator) !void {
        \\    var list: std.ArrayList(u32) = .empty;
        \\    try list.append(gpa, 1);
        \\    const last = list.getLast();
        \\    _ = last;
        \\    list.
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{.{ .path = "one.zig", .text = text }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(h.arena.allocator(), try project.path(h.arena.allocator(), "one.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});

    const hover_resp = try h.request("textDocument/hover", .{ .textDocument = .{ .uri = uri }, .position = position(text, "list:") });
    const value = hover_resp.object.get("result").?.object.get("contents").?.object.get("value").?.string;
    try testing.expectEqualStrings("```zig\nvar list: Aligned(u32, null)\n```", value);

    const p = position(text, "list.\n");
    const labels = try completionLabels(&h, uri, p.line, p.character + 5);
    for ([_][]const u8{ "items", "capacity", "append", "getLast", "deinit" }) |l| {
        testing.expect(contains(labels, l)) catch |err| {
            std.debug.print("missing completion `{s}`\n", .{l});
            return err;
        };
    }

    const hints = try h.request("textDocument/inlayHint", .{ .textDocument = .{ .uri = uri }, .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 8, .character = 0 } } });
    var found = false;
    for (hints.object.get("result").?.array.items) |hint| {
        if (std.mem.eql(u8, hint.object.get("label").?.string, ": u32")) found = true;
    }
    try testing.expect(found);
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

const builtin_main =
    \\const builtin = @import("builtin");
    \\pub fn main() void {
    \\    const os = builtin.os.tag;
    \\    const m = builtin.mode;
    \\    _ = .{ os, m };
    \\}
    \\
;

fn hoverText(h: *Harness, uri: []const u8, text: []const u8, needle: []const u8) ![]const u8 {
    const resp = try h.request("textDocument/hover", .{ .textDocument = .{ .uri = uri }, .position = position(text, needle) });
    const result = resp.object.get("result").?;
    if (result == .null) return "null";
    return result.object.get("contents").?.object.get("value").?.string;
}

test "@import(\"builtin\") follows the module's target and optimize mode" {
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = fixture.basic[0].text },
        .{ .path = "src/main.zig", .text = builtin_main },
        .{ .path = "src/lib.zig", .text = "pub fn hello() void {}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    const options = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(),
        \\{"build": {"args": ["-Dtarget=x86_64-linux", "-Doptimize=ReleaseFast"]}}
    , .{});
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{}, .initializationOptions = options });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(h.arena.allocator(), try project.path(h.arena.allocator(), "src/main.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = builtin_main } });
    _ = try h.request("zig-analyzer/waitIdle", {});

    try testing.expectEqualStrings("```zig\nconst os: Tag = .linux\n```", try hoverText(&h, uri, builtin_main, "os ="));
    try testing.expectEqualStrings("```zig\nconst m: Optimize = .fast\n```", try hoverText(&h, uri, builtin_main, "m ="));
    const target = try gotoAt(&h, uri, builtin_main, "\"builtin\"");
    try testing.expect(std.mem.startsWith(u8, target, "builtin.zig:"));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "@import(\"builtin\") in single-file mode is the host target" {
    var project = try fixture.Project.create(&.{.{ .path = "one.zig", .text = builtin_main }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(h.arena.allocator(), try project.path(h.arena.allocator(), "one.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = builtin_main } });
    _ = try h.request("zig-analyzer/waitIdle", {});

    const expected = try std.fmt.allocPrint(h.arena.allocator(), "```zig\nconst os: Tag = .{t}\n```", .{@import("builtin").os.tag});
    try testing.expectEqualStrings(expected, try hoverText(&h, uri, builtin_main, "os ="));
    try testing.expectEqualStrings("```zig\nconst m: Optimize = .debug\n```", try hoverText(&h, uri, builtin_main, "m ="));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

const sizes_main =
    \\const std = @import("std");
    \\pub fn main() void {
    \\    const size = @sizeOf(usize);
    \\    const max = std.math.maxInt(usize);
    \\    const vec = @sizeOf(@Vector(2, u8));
    \\    _ = .{ size, max, vec };
    \\}
    \\
;

/// 打开 `files` 组成的项目中的 main.zig，返回 `size`、`max` 与 `vec` 的 hover
fn sizesHover(files: []const fixture.File, build_args: ?[]const u8) !struct { size: []const u8, max: []const u8, vec: []const u8 } {
    var project = try fixture.Project.create(files);
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    const options: ?std.json.Value = if (build_args) |args| try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), args, .{}) else null;
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{}, .initializationOptions = options });
    try h.notify("initialized", Empty{});
    const main_path = for (files) |f| {
        if (std.mem.endsWith(u8, f.path, "main.zig")) break f.path;
    } else unreachable;
    const uri = try za.base.uri.fromPath(h.arena.allocator(), try project.path(h.arena.allocator(), main_path));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = sizes_main } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const size = try testing.allocator.dupe(u8, try hoverText(&h, uri, sizes_main, "size ="));
    errdefer testing.allocator.free(size);
    const max = try testing.allocator.dupe(u8, try hoverText(&h, uri, sizes_main, "max ="));
    errdefer testing.allocator.free(max);
    const vec = try testing.allocator.dupe(u8, try hoverText(&h, uri, sizes_main, "vec ="));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
    return .{ .size = size, .max = max, .vec = vec };
}

test "pointer width follows the project's target" {
    const wasm = try sizesHover(&.{
        .{ .path = "build.zig", .text = fixture.basic[0].text },
        .{ .path = "src/main.zig", .text = sizes_main },
        .{ .path = "src/lib.zig", .text = "pub fn hello() void {}\n" },
    },
        \\{"build": {"args": ["-Dtarget=wasm32-freestanding"]}}
    );
    defer testing.allocator.free(wasm.size);
    defer testing.allocator.free(wasm.max);
    defer testing.allocator.free(wasm.vec);
    try testing.expectEqualStrings("```zig\nconst size: comptime_int = 4\n```", wasm.size);
    try testing.expectEqualStrings("```zig\nconst max: comptime_int = 4294967295\n```", wasm.max);
    // wasm32 默认使用 LLVM 后端：向量按字节数对齐
    try testing.expectEqualStrings("```zig\nconst vec: comptime_int = 2\n```", wasm.vec);

    // 同时有 x86_64（自研后端）与 wasm32（LLVM）两个目标：指针位宽与向量的规则都不一致，与大小相关的值
    // 为未知（不给出可能错误的值）。不用宿主目标：x86_64-windows 的 Debug 默认也用 LLVM，向量的规则与 wasm32 相同
    const mixed = try sizesHover(&.{
        .{ .path = "build.zig", .text =
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const host = b.addObject(.{ .name = "host", .root_module = b.createModule(.{
        \\        .root_source_file = b.path("main.zig"),
        \\        .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux }),
        \\    }), .use_llvm = false });
        \\    const wasm = b.addObject(.{ .name = "wasm", .root_module = b.createModule(.{
        \\        .root_source_file = b.path("main.zig"),
        \\        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        \\    }) });
        \\    const check = b.step("check", "Check");
        \\    check.dependOn(&host.step);
        \\    check.dependOn(&wasm.step);
        \\}
        \\
        },
        .{ .path = "main.zig", .text = sizes_main },
    }, null);
    defer testing.allocator.free(mixed.size);
    defer testing.allocator.free(mixed.max);
    defer testing.allocator.free(mixed.vec);
    try testing.expectEqualStrings("```zig\nconst size: comptime_int\n```", mixed.size);
    try testing.expectEqualStrings("```zig\nconst max: comptime_int\n```", mixed.max);
    try testing.expectEqualStrings("```zig\nconst vec: comptime_int\n```", mixed.vec);

    // 单文件模式：本机
    const single = try sizesHover(&.{.{ .path = "main.zig", .text = sizes_main }}, null);
    defer testing.allocator.free(single.size);
    defer testing.allocator.free(single.max);
    defer testing.allocator.free(single.vec);
    const expected = try std.fmt.allocPrint(testing.allocator, "```zig\nconst size: comptime_int = {d}\n```", .{@sizeOf(usize)});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, single.size);
}

test "results depending on pointer width are recomputed when the target changes" {
    // 不 import 任何文件：结果只经由 TargetAbi 依赖目标（不依赖模块图）
    const text =
        \\pub fn main() void {
        \\    const size = @sizeOf(usize);
        \\    _ = size;
        \\}
        \\
    ;
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = fixture.basic[0].text },
        .{ .path = "src/main.zig", .text = text },
        .{ .path = "src/lib.zig", .text = "pub fn hello() void {}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    const wasm = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(),
        \\{"build": {"args": ["-Dtarget=wasm32-freestanding"]}}
    , .{});
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{}, .initializationOptions = wasm });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(h.arena.allocator(), try project.path(h.arena.allocator(), "src/main.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("```zig\nconst size: comptime_int = 4\n```", try hoverText(&h, uri, text, "size ="));

    // 去掉 -Dtarget：项目重启，目标变为本机
    const host = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(), "{}", .{});
    try h.notify("workspace/didChangeConfiguration", .{ .settings = host });
    _ = try h.request("zig-analyzer/waitIdle", {});
    const expected = try std.fmt.allocPrint(h.arena.allocator(), "```zig\nconst size: comptime_int = {d}\n```", .{@sizeOf(usize)});
    try testing.expectEqualStrings(expected, try hoverText(&h, uri, text, "size ="));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}
