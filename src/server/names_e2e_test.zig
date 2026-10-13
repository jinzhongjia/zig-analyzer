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
