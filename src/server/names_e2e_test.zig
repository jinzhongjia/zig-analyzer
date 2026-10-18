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

/// definition 的结果：「文件名:行」
fn gotoAt(h: *Harness, uri: []const u8, text: []const u8, needle: []const u8) ![]const u8 {
    return gotoWith(h, "textDocument/definition", uri, text, needle);
}

/// 跳转结果：「文件名:行」，多个目标以空格连接
fn gotoWith(h: *Harness, comptime method: []const u8, uri: []const u8, text: []const u8, needle: []const u8) ![]const u8 {
    const resp = try h.request(method, .{ .textDocument = .{ .uri = uri }, .position = position(text, needle) });
    const result = resp.object.get("result").?;
    const targets = switch (result) {
        .null => return "null",
        .array => |arr| arr.items,
        else => &.{result},
    };
    var labels: std.ArrayList([]const u8) = .empty;
    for (targets) |target| {
        const target_uri = target.object.get("uri").?.string;
        const line = target.object.get("range").?.object.get("start").?.object.get("line").?.integer;
        try labels.append(h.arena.allocator(), try std.fmt.allocPrint(h.arena.allocator(), "{s}:{d}", .{ target_uri[std.mem.lastIndexOfScalar(u8, target_uri, '/').? + 1 ..], line }));
    }
    return std.mem.join(h.arena.allocator(), " ", labels.items);
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

const test_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\    const mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    \\    const exe = b.addExecutable(.{ .name = "demo", .root_module = mod });
    \\    b.installArtifact(exe);
    \\    const tests = b.addTest(.{ .root_module = mod });
    \\    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
    \\}
    \\
;

const test_main =
    \\const std = @import("std");
    \\const builtin = @import("builtin");
    \\pub fn main() void {}
    \\test "uses the testing allocator" {
    \\    const gpa = std.testing.allocator;
    \\    const t = if (builtin.is_test) @as(u8, 1) else @as(u16, 2);
    \\    _ = .{ gpa, t };
    \\}
    \\
;

test "a module that is also the root of a test step is analyzed as a test" {
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = test_build },
        .{ .path = "src/main.zig", .text = test_main },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(h.arena.allocator(), try project.path(h.arena.allocator(), "src/main.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = test_main } });
    _ = try h.request("zig-analyzer/waitIdle", {});

    try testing.expectEqualStrings("```zig\nconst t: u8 = 1\n```", try hoverText(&h, uri, test_main, "t ="));
    try testing.expectEqualStrings("```zig\nconst gpa: Allocator\n```", try hoverText(&h, uri, test_main, "gpa ="));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

const inactive_main =
    \\const debug = false;
    \\pub fn main() void {
    \\    if (debug) {
    \\        @panic("never");
    \\    }
    \\}
    \\
;

/// exe 与 test 各自创建模块、共用根文件：两者的 dep 指向不同的包，test 的模块另有 helper
const shared_root_build =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\    const pkg_a = b.createModule(.{ .root_source_file = b.path("pkg_a/a.zig") });
    \\    const pkg_b = b.createModule(.{ .root_source_file = b.path("pkg_b/b.zig") });
    \\    const exe = b.addExecutable(.{ .name = "demo", .root_module = b.createModule(.{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\        .imports = &.{.{ .name = "dep", .module = pkg_a }},
    \\    }) });
    \\    b.installArtifact(exe);
    \\    const tests = b.addTest(.{ .root_module = b.createModule(.{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\        .imports = &.{ .{ .name = "dep", .module = pkg_b }, .{ .name = "helper", .module = pkg_b } },
    \\    }) });
    \\    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
    \\}
    \\
;

const shared_root_main =
    \\const dep = @import("dep");
    \\pub fn main() void {
    \\    _ = dep.fromA();
    \\}
    \\test "uses the helper" {
    \\    const h = @import("helper");
    \\    const w = h.fromB();
    \\    _ = w;
    \\}
    \\
;

test "a root file shared by modules with different imports resolves the imports of each module" {
    var project = try fixture.Project.create(&.{
        .{ .path = "build.zig", .text = shared_root_build },
        .{ .path = "src/main.zig", .text = shared_root_main },
        .{ .path = "pkg_a/a.zig", .text = "pub fn fromA() u32 {\n    return 1;\n}\n" },
        .{ .path = "pkg_b/b.zig", .text = "pub const Widget = struct { size: u64 };\npub fn fromB() Widget {\n    return .{ .size = 2 };\n}\n" },
    });
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(h.arena.allocator(), try project.path(h.arena.allocator(), "src/main.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = shared_root_main } });
    _ = try h.request("zig-analyzer/waitIdle", {});

    // 只有 test 的模块 import 的名字
    try testing.expectEqualStrings("b.zig:0", try gotoAt(&h, uri, shared_root_main, "\"helper\""));
    try testing.expectEqualStrings("b.zig:1", try gotoAt(&h, uri, shared_root_main, "fromB"));
    try testing.expectEqualStrings("```zig\nconst w: Widget\n```", try hoverText(&h, uri, shared_root_main, "w ="));
    // 两个模块都 import 的名字：成员取诊断 step（默认的 install，即 exe）的模块中的，import 本身列出两个模块的目标
    try testing.expectEqualStrings("a.zig:0", try gotoAt(&h, uri, shared_root_main, "fromA"));
    try testing.expectEqualStrings("a.zig:0 b.zig:0", try gotoAt(&h, uri, shared_root_main, "\"dep\""));
    try testing.expectEqualStrings("a.zig:0 b.zig:0", try gotoWith(&h, "textDocument/declaration", uri, shared_root_main, "\"dep\""));
    // 别名的使用处停在声明处
    try testing.expectEqualStrings("main.zig:0", try gotoAt(&h, uri, shared_root_main, "dep.fromA"));
    try testing.expectEqualStrings("main.zig:0", try gotoWith(&h, "textDocument/declaration", uri, shared_root_main, "dep.fromA"));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}

test "code excluded by a comptime condition is published as an unnecessary hint" {
    var project = try fixture.Project.create(&.{.{ .path = "one.zig", .text = inactive_main }});
    defer project.deinit();
    var h: Harness = undefined;
    try h.start();
    defer h.finish();
    const root_uri = try za.base.uri.fromPath(h.arena.allocator(), project.root);
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{} });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(h.arena.allocator(), try project.path(h.arena.allocator(), "one.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = inactive_main } });
    _ = try h.request("zig-analyzer/waitIdle", {});

    const published = try h.notifications("textDocument/publishDiagnostics");
    try testing.expect(published.len > 0);
    const diags = published[published.len - 1].object.get("params").?.object.get("diagnostics").?.array.items;
    var found = false;
    for (diags) |d| {
        if (!std.mem.eql(u8, d.object.get("source").?.string, "zig-analyzer")) continue;
        found = true;
        const range = d.object.get("range").?.object;
        try testing.expectEqual(2, range.get("start").?.object.get("line").?.integer);
        try testing.expectEqual(15, range.get("start").?.object.get("character").?.integer);
        try testing.expectEqual(4, range.get("end").?.object.get("line").?.integer);
        try testing.expectEqual(4, d.object.get("severity").?.integer);
        try testing.expectEqual(1, d.object.get("tags").?.array.items[0].integer);
    }
    try testing.expect(found);
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

test "type layouts follow the project's target and are recomputed when it changes" {
    // 期望值为 zig 0.17.0 的结果。两个目标的指针位宽与向量的规则相同，整数的最大对齐不同（4 与 16）
    const text =
        \\pub fn main() void {
        \\    const align_u64 = @alignOf(u64);
        \\    const size_s = @sizeOf(struct { a: u8, b: u64 });
        \\    _ = .{ align_u64, size_s };
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
    const x86 = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(),
        \\{"build": {"args": ["-Dtarget=x86-linux"]}}
    , .{});
    _ = try h.request("initialize", .{ .rootUri = root_uri, .capabilities = Empty{}, .initializationOptions = x86 });
    try h.notify("initialized", Empty{});
    const uri = try za.base.uri.fromPath(h.arena.allocator(), try project.path(h.arena.allocator(), "src/main.zig"));
    try h.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = "zig", .version = 1, .text = text } });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("```zig\nconst align_u64: comptime_int = 4\n```", try hoverText(&h, uri, text, "align_u64 ="));
    try testing.expectEqualStrings("```zig\nconst size_s: comptime_int = 12\n```", try hoverText(&h, uri, text, "size_s ="));

    const wasm = try std.json.parseFromSliceLeaky(std.json.Value, h.arena.allocator(),
        \\{"build": {"args": ["-Dtarget=wasm32-freestanding"]}}
    , .{});
    try h.notify("workspace/didChangeConfiguration", .{ .settings = wasm });
    _ = try h.request("zig-analyzer/waitIdle", {});
    try testing.expectEqualStrings("```zig\nconst align_u64: comptime_int = 8\n```", try hoverText(&h, uri, text, "align_u64 ="));
    try testing.expectEqualStrings("```zig\nconst size_s: comptime_int = 16\n```", try hoverText(&h, uri, text, "size_s ="));
    _ = try h.request("shutdown", {});
    try h.notify("exit", {});
}
