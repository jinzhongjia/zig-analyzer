//! textDocument/formatting：使用标准库的渲染器，结果与 `zig fmt` 逐字一致。
//! 输出以行为单位的最小替换区间（公共前缀 / 后缀之外的部分），避免整篇替换导致光标与折叠丢失。

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const offsets = @import("../util/offsets.zig");
const nesting = @import("../syntax/nesting.zig");

const log = std.log.scoped(.format);

pub const Mode = enum { zig, zon };

/// 有语法错误时返回 null（与 `zig fmt` 一样拒绝格式化）；已格式化时返回空数组。
pub fn format(arena: Allocator, lines: offsets.LineIndex, mode: Mode, enc: offsets.Encoding) Allocator.Error!?[]const types.TextEdit {
    const text = lines.text;
    const source = try arena.dupeSentinel(u8, text, 0);
    const formatted = try render(arena, source, mode) orelse return null;
    if (std.mem.eql(u8, formatted, text)) return &.{};

    // 公共前缀 / 后缀按整行计算，保证替换区间落在字符边界上
    var prefix = std.mem.indexOfDiff(u8, text, formatted) orelse @min(text.len, formatted.len);
    prefix = if (std.mem.lastIndexOfScalar(u8, text[0..prefix], '\n')) |nl| nl + 1 else 0;
    var suffix: usize = 0;
    while (suffix < text.len - prefix and suffix < formatted.len - prefix and
        text[text.len - 1 - suffix] == formatted[formatted.len - 1 - suffix]) suffix += 1;
    // 后缀也从行首开始
    while (suffix > 0 and text.len - suffix > 0 and text[text.len - suffix - 1] != '\n') suffix -= 1;

    const edit: types.TextEdit = .{
        .range = lines.range(prefix, text.len - suffix, enc),
        .newText = formatted[prefix .. formatted.len - suffix],
    };
    return try arena.dupe(types.TextEdit, &.{edit});
}

/// 官方解析器与渲染器（同 `zig fmt`）的结果，有语法错误时为 null。两者逐层递归：按嵌套深度选择执行的
/// 线程，超过 `nesting.format_depth` 的文本不格式化
fn render(arena: Allocator, source: [:0]const u8, mode: Mode) Allocator.Error!?[]const u8 {
    const depth = try nesting.estimate(arena, source, nesting.format_depth);
    if (depth <= nesting.inline_depth) return renderSource(arena, source, mode);
    if (depth > nesting.format_depth) return null;
    var result: Allocator.Error!?[]const u8 = undefined;
    const thread = std.Thread.spawn(.{ .stack_size = nesting.threadStackSize(depth, nesting.format_depth) }, renderInto, .{ arena, source, mode, &result }) catch |err| {
        log.warn("cannot spawn a thread to format a deeply nested file: {t}", .{err});
        return null;
    };
    thread.join();
    return result;
}

fn renderInto(arena: Allocator, source: [:0]const u8, mode: Mode, result: *Allocator.Error!?[]const u8) void {
    result.* = renderSource(arena, source, mode);
}

fn renderSource(arena: Allocator, source: [:0]const u8, mode: Mode) Allocator.Error!?[]const u8 {
    var ast = try std.zig.Ast.parse(arena, source, .{ .mode = switch (mode) {
        .zig => .zig,
        .zon => .zon,
    } });
    if (ast.errors.len != 0) return null;
    return try ast.renderAlloc(arena);
}

const testing = std.testing;

fn applyEdit(gpa: Allocator, text: []const u8, edit: types.TextEdit) ![]u8 {
    const changes = [_]types.TextDocumentContentChangeEvent{.{ .TextDocumentContentChangePartial = .{ .range = edit.range, .text = edit.newText } }};
    return offsets.applyChanges(gpa, text, &changes, .utf16);
}

test "deeply nested source is formatted on a large stack, beyond the depth limit it is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 超过当前线程的上限，在专用线程上格式化
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(a, "const  x = ");
    for (0..3000) |_| try text.append(a, '(');
    try text.append(a, '1');
    for (0..3000) |_| try text.append(a, ')');
    try text.appendSlice(a, ";\n");
    const lines = try offsets.LineIndex.init(a, text.items);
    const edits = (try format(a, lines, .zig, .utf16)).?;
    try testing.expectEqual(1, edits.len);
    try testing.expectEqualStrings(try std.mem.replaceOwned(u8, a, text.items, "const  x", "const x"), try applyEdit(a, text.items, edits[0]));

    // 超过深度上限：拒绝
    text.clearRetainingCapacity();
    try text.appendSlice(a, "const x = ");
    for (0..nesting.format_depth) |_| try text.append(a, '(');
    try text.append(a, '1');
    for (0..nesting.format_depth) |_| try text.append(a, ')');
    try text.appendSlice(a, ";\n");
    const deep = try offsets.LineIndex.init(a, text.items);
    try testing.expectEqual(null, try format(a, deep, .zig, .utf16));
}

test format {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const text = "const a = 1;\nfn  f( )  void{}\nconst b = 2;\n";
    const lines = try offsets.LineIndex.init(a, text);
    const edits = (try format(a, lines, .zig, .utf16)).?;
    try testing.expectEqual(1, edits.len);
    // 只替换第二行
    try testing.expectEqual(1, edits[0].range.start.line);
    try testing.expectEqual(2, edits[0].range.end.line);
    try testing.expectEqualStrings("const a = 1;\nfn f() void {}\nconst b = 2;\n", try applyEdit(a, text, edits[0]));

    const ok = try offsets.LineIndex.init(a, "const a = 1;\n");
    try testing.expectEqual(0, (try format(a, ok, .zig, .utf16)).?.len);

    const bad = try offsets.LineIndex.init(a, "const a = ;\n");
    try testing.expectEqual(null, try format(a, bad, .zig, .utf16));
}
