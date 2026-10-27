//! textDocument/formatting: uses the standard library renderer, matching `zig fmt` exactly.
//! Outputs the minimal replacement range in whole lines (the part outside the common prefix /
//! suffix), avoiding a whole-document replacement that would lose the cursor and folds.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const offsets = @import("../util/offsets.zig");
const nesting = @import("../syntax/nesting.zig");

const log = std.log.scoped(.format);

pub const Mode = enum { zig, zon };

/// Returns null on syntax errors (refusing to format, like `zig fmt`); returns an empty array
/// when the text is already formatted.
pub fn format(arena: Allocator, lines: offsets.LineIndex, mode: Mode, enc: offsets.Encoding) Allocator.Error!?[]const types.TextEdit {
    const text = lines.text;
    const formatted = try renderText(arena, text, mode) orelse return null;
    if (std.mem.eql(u8, formatted, text)) return &.{};
    const d = lineDiff(text, formatted);
    const edit: types.TextEdit = .{
        .range = lines.range(d.start, d.old_end, enc),
        .newText = formatted[d.start..d.new_end],
    };
    return try arena.dupe(types.TextEdit, &.{edit});
}

/// Result of `zig fmt` on the text; null on syntax errors or when nesting is too deep
pub fn renderText(arena: Allocator, text: []const u8, mode: Mode) Allocator.Error!?[]const u8 {
    return render(arena, try arena.dupeSentinel(u8, text, 0), mode);
}

/// Minimal replacement range that turns `old` into `new`: the part outside the common prefix and
/// suffix, computed in whole lines, with the range falling on character boundaries.
/// `old[start..old_end]` is replaced with `new[start..new_end]`
pub fn lineDiff(old: []const u8, new: []const u8) struct { start: usize, old_end: usize, new_end: usize } {
    var prefix = std.mem.indexOfDiff(u8, old, new) orelse @min(old.len, new.len);
    prefix = if (std.mem.lastIndexOfScalar(u8, old[0..prefix], '\n')) |nl| nl + 1 else 0;
    var suffix: usize = 0;
    while (suffix < old.len - prefix and suffix < new.len - prefix and
        old[old.len - 1 - suffix] == new[new.len - 1 - suffix]) suffix += 1;
    // The suffix also starts at the beginning of a line
    while (suffix > 0 and old.len - suffix > 0 and old[old.len - suffix - 1] != '\n') suffix -= 1;
    return .{ .start = prefix, .old_end = old.len - suffix, .new_end = new.len - suffix };
}

/// Result of the official parser and renderer (same as `zig fmt`); null on syntax errors. Both
/// recurse once per nesting level: the thread to run on is chosen by nesting depth, and text
/// nested deeper than `nesting.format_depth` is not formatted
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
    // Beyond the limit of the current thread: formatted on a dedicated thread
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

    // Beyond the depth limit: rejected
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
    // Only the second line is replaced
    try testing.expectEqual(1, edits[0].range.start.line);
    try testing.expectEqual(2, edits[0].range.end.line);
    try testing.expectEqualStrings("const a = 1;\nfn f() void {}\nconst b = 2;\n", try applyEdit(a, text, edits[0]));

    const ok = try offsets.LineIndex.init(a, "const a = 1;\n");
    try testing.expectEqual(0, (try format(a, ok, .zig, .utf16)).?.len);

    const bad = try offsets.LineIndex.init(a, "const a = ;\n");
    try testing.expectEqual(null, try format(a, bad, .zig, .utf16));
}
