const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ErrorBundle = std.zig.ErrorBundle;
const compiler = @import("compiler.zig");
const live = @import("live.zig");
const offsets = @import("../util/offsets.zig");
const native = @import("../util/test_path.zig").native;

const main_text =
    \\pub fn main() void {
    \\    var unused = 1;
    \\    const x: u32 = "s";
    \\    _ = x;
    \\}
    \\
;

/// 构造一个带位置的错误包
fn addError(wip: *ErrorBundle.Wip, path: []const u8, text: []const u8, needle: []const u8, msg: []const u8) !void {
    const start: u32 = @intCast(std.mem.indexOf(u8, text, needle).?);
    try wip.addRootErrorMessage(.{
        .msg = try wip.addString(msg),
        .src_loc = try wip.addSourceLocation(.{
            .src_path = try wip.addString(path),
            .line = 0,
            .column = 0,
            .span_start = start,
            .span_main = start,
            .span_end = start + @as(u32, @intCast(needle.len)),
        }),
    });
}

const Disk = struct {
    fn read(_: *anyopaque, gpa: Allocator, path: []const u8) ?[]u8 {
        if (std.mem.endsWith(u8, path, "main.zig")) return gpa.dupe(u8, main_text) catch null;
        return null;
    }
};

fn buildResult() !compiler.BuildResult {
    const gpa = testing.allocator;
    var wip: ErrorBundle.Wip = try .init(gpa);
    defer wip.deinit();
    try addError(&wip, "src/main.zig", main_text, "unused", "unused local variable");
    try addError(&wip, "src/main.zig", main_text, "\"s\"", "expected type 'u32', found '*const [1:0]u8'");
    // 重复报告（另一个 compile step）与没有位置的错误
    try addError(&wip, "src/main.zig", main_text, "unused", "unused local variable");
    try wip.addRootErrorMessage(.{ .msg = try wip.addString("undefined symbol: foo") });
    var eb = try wip.toOwnedBundle("");
    defer eb.deinit(gpa);
    var dummy: u8 = 0;
    return compiler.collect(gpa, &.{eb}, native("/proj"), native("/proj/build.zig"), &dummy, Disk.read);
}

test "collect: path resolution, dedup, errors without location, AstGen flag" {
    var r = try buildResult();
    defer r.deinit(testing.allocator);
    const main = r.files.get(native("/proj/src/main.zig")).?;
    try testing.expectEqual(2, main.items.len);
    try testing.expect(main.items[0].is_astgen); // unused local variable 也是 ast-check 错误
    try testing.expect(!main.items[1].is_astgen); // 类型错误来自 Sema
    const build_zig = r.files.get(native("/proj/build.zig")).?;
    try testing.expectEqualStrings("undefined symbol: foo", build_zig.items[0].message);
}

const NoOther = struct {
    fn get(_: *anyopaque, _: Allocator, _: []const u8) ?compiler.OtherFile {
        return null;
    }
};

fn mergeMessages(arena: Allocator, text: []const u8, use_live: bool, result: ?*const compiler.FileResult) ![]const []const u8 {
    const l = try live.check(arena, text, .zig);
    var dummy: u8 = 0;
    const diags = try compiler.merge(arena, .{
        .text = text,
        .lines = try offsets.LineIndex.init(arena, text),
        .encoding = .utf16,
        .uri = "file:///proj/src/main.zig",
        .live = if (use_live) l else null,
        .compiler = result,
        .other_file = NoOther.get,
        .other_ctx = &dummy,
    });
    const out = try arena.alloc([]const u8, diags.len);
    for (diags, out) |d, *o| o.* = try std.fmt.allocPrint(arena, "{s}@{d}:{d}: {s}", .{ d.source.?, d.range.start.line, d.range.start.character, d.message.string });
    return out;
}

test "merge: only compiler diagnostics when the buffer matches the build" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var r = try buildResult();
    defer r.deinit(testing.allocator);
    const msgs = try mergeMessages(arena.allocator(), main_text, true, r.files.getPtr(native("/proj/src/main.zig")).?);
    try testing.expectEqual(2, msgs.len);
    try testing.expectEqualStrings("zig@1:8: unused local variable", msgs[0]);
    try testing.expectEqualStrings("zig@2:19: expected type 'u32', found '*const [1:0]u8'", msgs[1]);
}

test "merge: live diagnostics plus remapped Sema errors with unsaved edits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var r = try buildResult();
    defer r.deinit(testing.allocator);
    const result = r.files.getPtr(native("/proj/src/main.zig")).?;

    // 在文件开头插入一行：Sema 错误整体下移一行；AstGen 错误改由 live 提供
    const edited = try std.mem.concat(arena.allocator(), u8, &.{ "// 新注释\n", main_text });
    const msgs = try mergeMessages(arena.allocator(), edited, true, result);
    try testing.expectEqual(2, msgs.len);
    try testing.expectEqualStrings("zig ast-check@2:8: unused local variable", msgs[0]);
    try testing.expectEqualStrings("zig@3:19: expected type 'u32', found '*const [1:0]u8'", msgs[1]);

    // 修改 Sema 错误所在的行：该错误隐藏，等保存后的构建结果
    const touched = try std.mem.replaceOwned(u8, arena.allocator(), main_text, "\"s\"", "\"t\"");
    const msgs2 = try mergeMessages(arena.allocator(), touched, true, result);
    try testing.expectEqual(1, msgs2.len);
    try testing.expectEqualStrings("zig ast-check@1:8: unused local variable", msgs2[0]);
}

test "merge: live only without build result; no live outside the compile set" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(1, (try mergeMessages(arena.allocator(), main_text, true, null)).len);
    try testing.expectEqual(0, (try mergeMessages(arena.allocator(), main_text, false, null)).len);
}
