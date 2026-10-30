const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ErrorBundle = std.zig.ErrorBundle;
const compiler = @import("compiler.zig");
const live = @import("live.zig");
const offsets = @import("../util/offsets.zig");
const native = @import("../util/test_path.zig").native;
const error_bundle = @import("../project/error_bundle.zig");

const main_text =
    \\pub fn main() void {
    \\    var unused = 1;
    \\    const x: u32 = "s";
    \\    _ = x;
    \\}
    \\
;

/// Builds an error with a location in the error bundle
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
        if (std.mem.endsWith(u8, path, "caller.zig")) return gpa.dupe(u8, caller_text) catch null;
        return null;
    }
};

fn buildResult() !*compiler.BuildResult {
    const gpa = testing.allocator;
    var wip: ErrorBundle.Wip = try .init(gpa);
    defer wip.deinit();
    try addError(&wip, "src/main.zig", main_text, "unused", "unused local variable");
    try addError(&wip, "src/main.zig", main_text, "\"s\"", "expected type 'u32', found '*const [1:0]u8'");
    // A duplicate report (from another compile step) and an error without a location
    try addError(&wip, "src/main.zig", main_text, "unused", "unused local variable");
    try wip.addRootErrorMessage(.{ .msg = try wip.addString("undefined symbol: foo") });
    var eb = try wip.toOwnedBundle("");
    defer eb.deinit(gpa);
    var dummy: u8 = 0;
    return compiler.collect(gpa, &.{eb}, native("/proj"), native("/proj/build.zig"), &dummy, Disk.read);
}

test "collect: path resolution, dedup, errors without location, AstGen flag" {
    const r = try buildResult();
    defer r.release(testing.allocator);
    const main = r.files.get(native("/proj/src/main.zig")).?;
    try testing.expectEqual(2, main.items.len);
    try testing.expect(main.items[0].is_astgen); // unused local variable is also an ast-check error
    try testing.expect(!main.items[1].is_astgen); // the type error comes from Sema
    const build_zig = r.files.get(native("/proj/build.zig")).?;
    try testing.expectEqualStrings("undefined symbol: foo", build_zig.items[0].message);
}

test "a build result stays valid while a reader holds a reference after the owner released it" {
    const r = try buildResult();
    const reader = r.retain();
    // The owner's result is replaced by a new one
    r.release(testing.allocator);
    const main = reader.files.get(native("/proj/src/main.zig")).?;
    try testing.expectEqual(2, main.items.len);
    try testing.expectEqualStrings("unused local variable", main.items[0].message);
    reader.release(testing.allocator);
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
    const r = try buildResult();
    defer r.release(testing.allocator);
    const msgs = try mergeMessages(arena.allocator(), main_text, true, r.files.getPtr(native("/proj/src/main.zig")).?);
    try testing.expectEqual(2, msgs.len);
    try testing.expectEqualStrings("zig@1:8: unused local variable", msgs[0]);
    try testing.expectEqualStrings("zig@2:19: expected type 'u32', found '*const [1:0]u8'", msgs[1]);
}

test "merge: live diagnostics plus remapped Sema errors with unsaved edits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try buildResult();
    defer r.release(testing.allocator);
    const result = r.files.getPtr(native("/proj/src/main.zig")).?;

    // Insert a line at the start of the file: the Sema error moves down one line; the AstGen error
    // now comes from live
    const edited = try std.mem.concat(arena.allocator(), u8, &.{ "// new comment\n", main_text });
    const msgs = try mergeMessages(arena.allocator(), edited, true, result);
    try testing.expectEqual(2, msgs.len);
    try testing.expectEqualStrings("zig ast-check@2:8: unused local variable", msgs[0]);
    try testing.expectEqualStrings("zig@3:19: expected type 'u32', found '*const [1:0]u8'", msgs[1]);

    // Modify the line of the Sema error: the error is hidden until the build result after a save
    const touched = try std.mem.replaceOwned(u8, arena.allocator(), main_text, "\"s\"", "\"t\"");
    const msgs2 = try mergeMessages(arena.allocator(), touched, true, result);
    try testing.expectEqual(1, msgs2.len);
    try testing.expectEqualStrings("zig ast-check@1:8: unused local variable", msgs2[0]);
}

test "merge: non-adjacent edits only hide their own lines" {
    const text =
        \\fn a() void {
        \\    const x: u32 = "s";
        \\    const y: u32 = 1;
        \\    const z: u32 = "t";
        \\}
        \\
    ;
    const first: u32 = @intCast(std.mem.indexOf(u8, text, "\"s\"").?);
    const second: u32 = @intCast(std.mem.indexOf(u8, text, "\"t\"").?);
    const result: compiler.FileResult = .{ .base_text = text, .items = &.{
        .{ .start = first, .end = first + 3, .message = "first", .is_astgen = false, .notes = &.{} },
        .{ .start = second, .end = second + 3, .message = "second", .is_astgen = false, .notes = &.{} },
    } };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Insert one line at the top and one at the bottom: both unmodified errors in between should be
    // kept
    const edited = try std.mem.concat(a, u8, &.{ "// top\n", text, "// bottom\n" });
    const msgs = try mergeMessages(a, edited, false, &result);
    try testing.expectEqual(2, msgs.len);
    try testing.expectEqualStrings("zig@2:19: first", msgs[0]);
    try testing.expectEqualStrings("zig@4:19: second", msgs[1]);
}

test "merge: notes in another file are remapped by that file's edits" {
    const main = "fn f() void {\n    g();\n}\n";
    const other_base = "fn g() void {\n    bad();\n}\n";
    const other_current = "// top\n" ++ other_base;
    const main_start: u32 = @intCast(std.mem.indexOf(u8, main, "g();").?);
    const note_start: u32 = @intCast(std.mem.indexOf(u8, other_base, "bad").?);
    const result: compiler.FileResult = .{ .base_text = main, .items = &.{.{
        .start = main_start,
        .end = main_start + 3,
        .message = "error",
        .is_astgen = false,
        .notes = &.{.{ .path = native("/proj/src/other.zig"), .start = note_start, .end = note_start + 3, .message = "note", .base_text = other_base }},
    }} };
    const Ctx = struct {
        fn get(_: *anyopaque, _: Allocator, path: []const u8) ?compiler.OtherFile {
            if (!std.mem.endsWith(u8, path, "other.zig")) return null;
            return .{ .uri = "file:///proj/src/other.zig", .text = other_current };
        }
    };
    var ctx: u8 = 0;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const diags = try compiler.merge(a, .{
        .text = main,
        .lines = try offsets.LineIndex.init(a, main),
        .encoding = .utf16,
        .uri = "file:///proj/src/main.zig",
        .live = null,
        .compiler = &result,
        .other_file = Ctx.get,
        .other_ctx = &ctx,
    });
    try testing.expectEqual(1, diags.len);
    const related = diags[0].relatedInformation.?[0];
    // A line is inserted at the top of the note's file: the note moves down one line
    try testing.expectEqual(2, related.location.range.start.line);
    try testing.expectEqual(4, related.location.range.start.character);
}

/// Span of the `n`th (from 0) occurrence of `needle` in `text`
fn spanOf(text: []const u8, needle: []const u8, n: usize) [2]u32 {
    var at: usize = std.mem.indexOf(u8, text, needle).?;
    for (0..n) |_| at = std.mem.indexOfPos(u8, text, at + 1, needle).?;
    return .{ @intCast(at), @intCast(at + needle.len) };
}

/// Merges a build result for `base` with one non-AstGen error on each of `spans` into the buffer
/// `text`; returns the published ranges as "line:character-line:character"
fn remappedRanges(a: Allocator, base: []const u8, text: []const u8, spans: []const [2]u32) ![]const []const u8 {
    const items = try a.alloc(compiler.Item, spans.len);
    for (items, spans) |*item, s| item.* = .{ .start = s[0], .end = s[1], .message = "error", .is_astgen = false, .notes = &.{} };
    const result: compiler.FileResult = .{ .base_text = base, .items = items };
    var dummy: u8 = 0;
    const diags = try compiler.merge(a, .{
        .text = text,
        .lines = try offsets.LineIndex.init(a, text),
        .encoding = .utf8,
        .uri = "file:///proj/src/main.zig",
        .live = null,
        .compiler = &result,
        .other_file = NoOther.get,
        .other_ctx = &dummy,
    });
    const out = try a.alloc([]const u8, diags.len);
    for (diags, out) |d, *o| o.* = try std.fmt.allocPrint(a, "{d}:{d}-{d}:{d}", .{ d.range.start.line, d.range.start.character, d.range.end.line, d.range.end.character });
    return out;
}

fn expectRanges(expected: []const []const u8, actual: []const []const u8) !void {
    errdefer for (actual) |r| std.debug.print("got {s}\n", .{r});
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, r| try testing.expectEqualStrings(e, r);
}

const two_functions =
    \\export fn f() void {
    \\}
    \\export fn g() void {
    \\    const x: u8 = 300;
    \\    _ = x;
    \\}
    \\
;

test "merge: a range after several modified regions shifts by the total length difference once" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const on_300 = &.{spanOf(two_functions, "300", 0)};
    // Guards against adding the shift of a region again for every later region, which moved the
    // error onto ";\n " or past the end of the file
    try expectRanges(&.{"4:18-4:21"}, try remappedRanges(a, two_functions, "//\n" ++ two_functions, on_300));
    // Two separated edits: a line inserted at the top and a renamed function
    const renamed = try std.mem.replaceOwned(u8, a, "//\n" ++ two_functions, "fn g()", "fn gg()");
    try expectRanges(&.{"4:18-4:21"}, try remappedRanges(a, two_functions, renamed, on_300));
    // A deleted header keeps the error
    const header = "//! a\n//! b\n//! c\n" ++ two_functions;
    try expectRanges(&.{"3:18-3:21"}, try remappedRanges(a, header, two_functions, &.{spanOf(header, "300", 0)}));
    // Two edits on lines that are all unique
    const unique = "const a = 1;\nconst b = 2;\nconst c = 3;\nconst x: u8 = 300;\n";
    const edited = "const a = 10;\nconst b = 2;\nconst c = 30;\nconst x: u8 = 300;\n";
    try expectRanges(&.{"3:14-3:17"}, try remappedRanges(a, unique, edited, &.{spanOf(unique, "300", 0)}));
}

test "merge: a note after several modified regions of its file shifts by the total length difference once" {
    const main = "fn f() void {\n    g();\n}\n";
    const main_start: u32 = @intCast(std.mem.indexOf(u8, main, "g();").?);
    const note = spanOf(two_functions, "300", 0);
    const result: compiler.FileResult = .{ .base_text = main, .items = &.{.{
        .start = main_start,
        .end = main_start + 3,
        .message = "error",
        .is_astgen = false,
        .notes = &.{.{ .path = native("/proj/src/other.zig"), .start = note[0], .end = note[1], .message = "note", .base_text = two_functions }},
    }} };
    const Ctx = struct {
        fn get(_: *anyopaque, _: Allocator, path: []const u8) ?compiler.OtherFile {
            if (!std.mem.endsWith(u8, path, "other.zig")) return null;
            return .{ .uri = "file:///proj/src/other.zig", .text = "//\n" ++ two_functions };
        }
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dummy: u8 = 0;
    const diags = try compiler.merge(a, .{
        .text = main,
        .lines = try offsets.LineIndex.init(a, main),
        .encoding = .utf8,
        .uri = "file:///proj/src/main.zig",
        .live = null,
        .compiler = &result,
        .other_file = Ctx.get,
        .other_ctx = &dummy,
    });
    try testing.expectEqual(1, diags.len);
    const range = diags[0].relatedInformation.?[0].location.range;
    try testing.expectEqual(4, range.start.line);
    try testing.expectEqual(18, range.start.character);
    try testing.expectEqual(4, range.end.line);
    try testing.expectEqual(21, range.end.character);
}

test "combine: an older result shifted over several modified regions matches the newest one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const newer_text = "//\n" ++ two_functions;
    const message = "type 'u8' cannot represent integer value '300'";
    const new = spanOf(newer_text, "300", 0);
    const old = spanOf(two_functions, "300", 0);
    const newest: compiler.FileResult = .{ .base_text = newer_text, .items = &.{
        .{ .start = new[0], .end = new[1], .message = message, .is_astgen = false, .notes = &.{} },
    } };
    const older: compiler.FileResult = .{ .base_text = two_functions, .items = &.{
        .{ .start = old[0], .end = old[1], .message = message, .is_astgen = false, .notes = &.{} },
    } };
    const c = try compiler.combine(arena.allocator(), &.{ &newest, &older });
    // Guards against shifting the older error too far, which kept it as a ghost duplicate
    try testing.expectEqual(1, c.items.len);
    try testing.expectEqual(new[0], c.items[0].start);
}

test "combine: each note is shifted from the text its own build read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const main = "fn f() void {\n    g();\n    h();\n}\n";
    const g = spanOf(main, "g()", 0);
    const h = spanOf(main, "h()", 0);
    // other.zig gained a line between the two builds; the newest build read the current text
    const newer_other = "//\n" ++ two_functions;
    const new_note = spanOf(newer_other, "300", 0);
    const old_note = spanOf(two_functions, "300", 0);
    const newest: compiler.FileResult = .{ .base_text = main, .items = &.{.{
        .start = g[0],
        .end = g[1],
        .message = "newer error",
        .is_astgen = false,
        .notes = &.{.{ .path = native("/proj/src/other.zig"), .start = new_note[0], .end = new_note[1], .message = "note", .base_text = newer_other }},
    }} };
    const older: compiler.FileResult = .{ .base_text = main, .items = &.{.{
        .start = h[0],
        .end = h[1],
        .message = "older error",
        .is_astgen = false,
        .notes = &.{.{ .path = native("/proj/src/other.zig"), .start = old_note[0], .end = old_note[1], .message = "note", .base_text = two_functions }},
    }} };
    const c = try compiler.combine(a, &.{ &newest, &older });
    const Ctx = struct {
        fn get(_: *anyopaque, _: Allocator, path: []const u8) ?compiler.OtherFile {
            if (!std.mem.endsWith(u8, path, "other.zig")) return null;
            return .{ .uri = "file:///proj/src/other.zig", .text = newer_other };
        }
    };
    var dummy: u8 = 0;
    const diags = try compiler.merge(a, .{
        .text = main,
        .lines = try offsets.LineIndex.init(a, main),
        .encoding = .utf8,
        .uri = "file:///proj/src/main.zig",
        .live = null,
        .compiler = &c,
        .other_file = Ctx.get,
        .other_ctx = &dummy,
    });
    try testing.expectEqual(2, diags.len);
    for (diags) |d| {
        const range = d.relatedInformation.?[0].location.range;
        try testing.expectEqual(4, range.start.line);
        try testing.expectEqual(18, range.start.character);
    }
}

const repeated_lines =
    \\pub fn main() void {
    \\    zero();
    \\    one();
    \\    two();
    \\}
    \\
    \\fn zero() void {
    \\    const w: u8 = 256;
    \\    _ = w;
    \\}
    \\
    \\fn one() void {
    \\    const v: u8 = 300;
    \\    _ = v;
    \\}
    \\
    \\fn two() void {
    \\    const v: u8 = 300;
    \\    _ = v;
    \\}
    \\
;

test "merge: unchanged repeated lines next to an edit keep their errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spans = &.{ spanOf(repeated_lines, "256", 0), spanOf(repeated_lines, "300", 0), spanOf(repeated_lines, "300", 1) };
    // Guards against treating every unchanged run of repeated lines (`}`, blank lines, duplicated
    // statements) between unique lines as modified, which hid the errors on them
    try expectRanges(&.{ "7:18-7:21", "12:18-12:21", "17:18-17:21" }, try remappedRanges(a, repeated_lines, repeated_lines ++ "// trailing comment\n", spans));
    const changed = try std.mem.replaceOwned(u8, a, repeated_lines, "fn one() void {\n    const v: u8 = 300;", "fn one() void {\n    const v: u8 = 30;");
    try expectRanges(&.{ "7:18-7:21", "17:18-17:21" }, try remappedRanges(a, repeated_lines, changed, spans));
    try expectRanges(&.{ "8:18-8:21", "13:18-13:21", "18:18-18:21" }, try remappedRanges(a, repeated_lines, "// top\n" ++ repeated_lines, spans));

    // Fixing one of two identical statements keeps the error on the other one
    const duplicated =
        \\fn f() void {
        \\    var list = std.ArrayList(u8).init(allocator);
        \\    _ = &list;
        \\}
        \\fn g() void {
        \\    var list = std.ArrayList(u8).init(allocator);
        \\    _ = &list;
        \\}
        \\
    ;
    const fixed = try std.mem.replaceOwned(u8, a, duplicated, "fn f() void {\n    var list = std.ArrayList(u8).init(allocator);", "fn f() void {\n    var list: std.ArrayList(u8) = .empty;");
    try expectRanges(&.{"5:33-5:37"}, try remappedRanges(a, duplicated, fixed, &.{ spanOf(duplicated, "init", 0), spanOf(duplicated, "init", 1) }));
}

test "merge: lines that differ only in the line terminator keep their errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const crlf = "pub fn main() void {\r\n    f();\r\n    const v: u8 = 300;\r\n    _ = v;\r\n}\r\nfn f() void {\r\n    const w: i8 = 200;\r\n    _ = w;\r\n}\r\n";
    const lf = try std.mem.replaceOwned(u8, a, crlf, "\r\n", "\n");
    // Guards against treating every line as modified when the disk text uses CRLF and the buffer
    // LF, which hid all compiler errors; a range may also cross a line terminator
    const spans = &.{ spanOf(crlf, "f();\r\n    const", 0), spanOf(crlf, "300", 0), spanOf(crlf, "200", 0) };
    try expectRanges(&.{ "1:4-2:9", "2:18-2:21", "6:18-6:21" }, try remappedRanges(a, crlf, lf, spans));

    // A mixed-EOL disk text against a buffer normalized to CRLF
    const mixed = "pub fn main() void {\r\n    f();\r\n    const v: u8 = 300;\n    _ = v;\n}\r\nfn f() void {\n    const w: i8 = 200;\r\n    _ = w;\r\n}\r\n";
    const normalized = try std.mem.replaceOwned(u8, a, lf, "\n", "\r\n");
    try expectRanges(&.{ "2:18-2:21", "6:18-6:21" }, try remappedRanges(a, mixed, normalized, &.{ spanOf(mixed, "300", 0), spanOf(mixed, "200", 0) }));
}

test "merge: malformed compiler spans do not overflow when remapped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sema_start: u32 = @intCast(std.mem.indexOf(u8, main_text, "\"s\"").?);
    // Guards against a panic from overflow during shifting: a range near the u32 limit shifted
    // later, and a range that ends before its start shifted earlier, fall outside the u32 range
    // and are dropped
    const result: compiler.FileResult = .{ .base_text = main_text, .items = &.{
        .{ .start = sema_start, .end = sema_start + 3, .message = "sema error", .is_astgen = false, .notes = &.{} },
        .{ .start = std.math.maxInt(u32) - 1, .end = std.math.maxInt(u32), .message = "past the end", .is_astgen = false, .notes = &.{} },
        .{ .start = 30, .end = 1, .message = "end before start", .is_astgen = false, .notes = &.{} },
    } };
    // Insert at the start: ranges shift later
    const msgs = try mergeMessages(a, try std.mem.concat(a, u8, &.{ "// x\n", main_text }), false, &result);
    try testing.expectEqual(2, msgs.len);
    try testing.expectEqualStrings("zig@3:19: sema error", msgs[0]);
    try testing.expect(std.mem.endsWith(u8, msgs[1], "end before start"));
    // Delete the start: ranges shift earlier
    const msgs2 = try mergeMessages(a, main_text[4..], false, &result);
    try testing.expectEqual(2, msgs2.len);
    try testing.expectEqualStrings("zig@2:19: sema error", msgs2[0]);
    try testing.expect(std.mem.endsWith(u8, msgs2[1], "past the end"));
}

test "merge: live only without build result; no live outside the compile set" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(1, (try mergeMessages(arena.allocator(), main_text, true, null)).len);
    try testing.expectEqual(0, (try mergeMessages(arena.allocator(), main_text, false, null)).len);
}

const caller_text =
    \\const m = @import("main.zig");
    \\pub fn f() void {
    \\    m.main();
    \\}
    \\
;

const Files = struct {
    fn get(_: *anyopaque, arena: Allocator, path: []const u8) ?compiler.OtherFile {
        const text = if (std.mem.endsWith(u8, path, "caller.zig")) caller_text else if (std.mem.endsWith(u8, path, "main.zig")) main_text else return null;
        return .{ .uri = std.fmt.allocPrint(arena, "file://{s}", .{path}) catch return null, .text = text };
    }
};

/// Source location: the range of `needle` in `text`
fn location(wip: *ErrorBundle.Wip, path: []const u8, text: []const u8, needle: []const u8, reference_trace_len: u32) !ErrorBundle.SourceLocationIndex {
    const start: u32 = @intCast(std.mem.indexOf(u8, text, needle).?);
    return wip.addSourceLocation(.{
        .src_path = try wip.addString(path),
        .line = 0,
        .column = 0,
        .span_start = start,
        .span_main = start,
        .span_end = start + @as(u32, @intCast(needle.len)),
        .reference_trace_len = reference_trace_len,
    });
}

/// An error bundle with notes and reference traces: the reference trace of the first error has
/// one reference with a location and a hidden count, the second has only the hidden marker left;
/// there is also compile log output
fn traceBundle() !ErrorBundle {
    var wip: ErrorBundle.Wip = try .init(testing.allocator);
    defer wip.deinit();
    // The reference trace immediately follows the error's source location
    const ref_loc = try location(&wip, "src/caller.zig", caller_text, "m.main()", 0);
    const note_loc = try location(&wip, "src/main.zig", main_text, "x", 0);
    const err_loc = try location(&wip, "src/main.zig", main_text, "\"s\"", 2);
    try wip.addReferenceTrace(.{ .decl_name = try wip.addString("f"), .src_loc = ref_loc });
    try wip.addReferenceTrace(.{ .decl_name = 3, .src_loc = .none });
    try wip.addRootErrorMessageWithNotes(
        .{ .msg = try wip.addString("expected type 'u32', found '*const [1:0]u8'"), .src_loc = err_loc, .notes_len = 1 },
        &.{.{ .msg = try wip.addString("a note"), .src_loc = note_loc }},
    );
    const err2_loc = try location(&wip, "src/main.zig", main_text, "unused", 1);
    try wip.addReferenceTrace(.{ .decl_name = 0, .src_loc = .none });
    try wip.addRootErrorMessage(.{ .msg = try wip.addString("unused local variable"), .src_loc = err2_loc });
    try addError(&wip, "src/main.zig", main_text, "_ = x", "found compile log statement");
    return wip.toOwnedBundle("@as(comptime_int, 3)\n@as(*const [2:0]u8, \"hi\")\n");
}

const lib_v1 =
    \\pub fn get() u8 {
    \\    const big: u8 = 256;
    \\    return big;
    \\}
    \\
;
const lib_v2 = "// one\n// two\n" ++ lib_v1;

/// Disk whose `lib.zig` has the text `lib`
const LibDisk = struct {
    lib: []const u8,

    fn read(ctx: *anyopaque, gpa: Allocator, path: []const u8) ?[]u8 {
        const self: *LibDisk = @ptrCast(@alignCast(ctx));
        if (std.mem.endsWith(u8, path, "lib.zig")) return gpa.dupe(u8, self.lib) catch null;
        return Disk.read(ctx, gpa, path);
    }
};

/// Source location of `needle` in `text`, with its line, column and source line as the compiler
/// reports them
fn compilerLocation(wip: *ErrorBundle.Wip, path: []const u8, text: []const u8, needle: []const u8, reference_trace_len: u32) !ErrorBundle.SourceLocationIndex {
    const start: u32 = @intCast(std.mem.indexOf(u8, text, needle).?);
    const loc = std.zig.findLineColumn(text, start);
    return wip.addSourceLocation(.{
        .src_path = try wip.addString(path),
        .line = @intCast(loc.line),
        .column = @intCast(loc.column),
        .span_start = start,
        .span_main = start,
        .span_end = start + @as(u32, @intCast(needle.len)),
        .source_line = try wip.addString(loc.source_line),
        .reference_trace_len = reference_trace_len,
    });
}

/// A build that read `lib` as `src/lib.zig`: an error on `256` in it, and an error in main.zig with
/// a note and a reference into it
fn libBundle(lib: []const u8) !ErrorBundle {
    var wip: ErrorBundle.Wip = try .init(testing.allocator);
    defer wip.deinit();
    try wip.addRootErrorMessage(.{ .msg = try wip.addString("type 'u8' cannot represent integer value '256'"), .src_loc = try compilerLocation(&wip, "src/lib.zig", lib, "256", 0) });
    const note_loc = try compilerLocation(&wip, "src/lib.zig", lib, "big;", 0);
    const ref_loc = try location(&wip, "src/lib.zig", lib, "get", 0);
    const err_loc = try compilerLocation(&wip, "src/main.zig", main_text, "\"s\"", 1);
    try wip.addReferenceTrace(.{ .decl_name = try wip.addString("get"), .src_loc = ref_loc });
    try wip.addRootErrorMessageWithNotes(
        .{ .msg = try wip.addString("expected type 'u32', found '*const [1:0]u8'"), .src_loc = err_loc, .notes_len = 1 },
        &.{.{ .msg = try wip.addString("a note"), .src_loc = note_loc }},
    );
    return wip.toOwnedBundle("");
}

test "collect: locations in a file changed after the compiler read it are discarded" {
    const gpa = testing.allocator;
    const lib_path = native("/proj/src/lib.zig");
    const main_path = native("/proj/src/main.zig");
    var v1 = try libBundle(lib_v1);
    defer v1.deinit(gpa);

    // The disk still has the text the compiler read
    var disk: LibDisk = .{ .lib = lib_v1 };
    const same = try compiler.collect(gpa, &.{v1}, native("/proj"), native("/proj/build.zig"), &disk, LibDisk.read);
    defer same.release(gpa);
    try testing.expectEqual(std.mem.indexOf(u8, lib_v1, "256").?, same.files.get(lib_path).?.items[0].start);
    try testing.expectEqual(2, same.files.get(main_path).?.items[0].notes.len);

    // Guards against applying the spans to a text written during the build, which put the error
    // inside a comment: everything located in lib.zig is dropped
    disk.lib = lib_v2;
    const changed = try compiler.collect(gpa, &.{v1}, native("/proj"), native("/proj/build.zig"), &disk, LibDisk.read);
    defer changed.release(gpa);
    try testing.expect(changed.files.get(lib_path) == null);
    const main = changed.files.get(main_path).?;
    try testing.expectEqual(1, main.items.len);
    try testing.expectEqual(0, main.items[0].notes.len);

    // The build after the change places the error on the new text
    var v2 = try libBundle(lib_v2);
    defer v2.deinit(gpa);
    const rebuilt = try compiler.collect(gpa, &.{v2}, native("/proj"), native("/proj/build.zig"), &disk, LibDisk.read);
    defer rebuilt.release(gpa);
    const lib = rebuilt.files.get(lib_path).?;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const lines = try offsets.LineIndex.init(arena.allocator(), lib.base_text);
    const range = lines.range(lib.items[0].start, lib.items[0].end, .utf8);
    try testing.expectEqual(3, range.start.line);
    try testing.expectEqual(20, range.start.character);
    try testing.expectEqual(2, rebuilt.files.get(main_path).?.items[0].notes.len);
}

test "collect: reference trace and compile log output are kept" {
    const gpa = testing.allocator;
    var eb = try traceBundle();
    defer eb.deinit(gpa);
    var dummy: u8 = 0;
    const r = try compiler.collect(gpa, &.{eb}, native("/proj"), native("/proj/build.zig"), &dummy, Disk.read);
    defer r.release(gpa);

    const items = r.files.get(native("/proj/src/main.zig")).?.items;
    try testing.expectEqual(3, items.len);
    const err_start: u32 = @intCast(std.mem.indexOf(u8, main_text, "\"s\"").?);
    const notes = items[0].notes;
    try testing.expectEqual(3, notes.len);
    try testing.expectEqualStrings(main_text, notes[0].base_text.?);
    // The build-time text is kept for a file that notes point to even if it has no errors
    try testing.expectEqualStrings(caller_text, notes[1].base_text.?);
    try testing.expectEqualStrings("a note", notes[0].message);
    try testing.expectEqualStrings(native("/proj/src/caller.zig"), notes[1].path);
    try testing.expectEqual(std.mem.indexOf(u8, caller_text, "m.main()").?, notes[1].start);
    try testing.expectEqualStrings("referenced by: f", notes[1].message);
    // The hidden count has no location: it is placed at the start of the error, with the same
    // message as the output of zig build
    try testing.expectEqualStrings(native("/proj/src/main.zig"), notes[2].path);
    try testing.expectEqual(err_start, notes[2].start);
    try testing.expectEqual(err_start, notes[2].end);
    try testing.expectEqualStrings("3 reference(s) hidden; use '-freference-trace=4' to see all references", notes[2].message);
    try testing.expectEqual(1, items[1].notes.len);
    try testing.expectEqualStrings("remaining reference traces hidden; use '-freference-trace' to see all reference traces", items[1].notes[0].message);
    try testing.expectEqualStrings("found compile log statement", items[2].message);
    try testing.expectEqualStrings("@as(comptime_int, 3)\n@as(*const [2:0]u8, \"hi\")", items[2].compile_log);

    // When published, both the notes and the reference trace become relatedInformation
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ctx: u8 = 0;
    const diags = try compiler.merge(arena.allocator(), .{
        .text = main_text,
        .lines = try offsets.LineIndex.init(arena.allocator(), main_text),
        .encoding = .utf16,
        .uri = "file:///proj/src/main.zig",
        .live = null,
        .compiler = r.files.getPtr(native("/proj/src/main.zig")).?,
        .other_file = Files.get,
        .other_ctx = &ctx,
    });
    const related = diags[0].relatedInformation.?;
    try testing.expectEqual(3, related.len);
    try testing.expect(std.mem.endsWith(u8, related[1].location.uri, "caller.zig"));
    try testing.expectEqual(2, related[1].location.range.start.line);
    try testing.expectEqual(4, related[1].location.range.start.character);
    try testing.expectEqualStrings("referenced by: f", related[1].message);
    try testing.expectEqual(2, related[2].location.range.start.line);
    try testing.expectEqual(19, related[2].location.range.start.character);
    // The compile log output is appended to the message
    try testing.expectEqualStrings(
        \\found compile log statement
        \\
        \\Compile Log Output:
        \\@as(comptime_int, 3)
        \\@as(*const [2:0]u8, "hi")
    , diags[2].message.string);
}

/// Converts and publishes `eb` if it passes validation (once for the build-time text and once for
/// a modified text); returns whether it passed validation
fn collectIfValid(eb: ErrorBundle) !bool {
    if (!error_bundle.isValid(eb)) return false;
    const gpa = testing.allocator;
    var dummy: u8 = 0;
    const r = try compiler.collect(gpa, &.{eb}, native("/proj"), native("/proj/build.zig"), &dummy, Disk.read);
    defer r.release(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for (r.files.keys(), r.files.values()) |path, *fr| {
        // Paths in the result are interned into the Vfs and must be absolute paths
        try testing.expect(std.fs.path.isAbsolute(path));
        for (fr.items) |item| for (item.notes) |n| try testing.expect(std.fs.path.isAbsolute(n.path));
        for ([_][]const u8{ fr.base_text, try std.mem.concat(a, u8, &.{ "// x\n", fr.base_text }) }) |text| {
            _ = try compiler.merge(a, .{
                .text = text,
                .lines = try offsets.LineIndex.init(a, text),
                .encoding = .utf16,
                .uri = "file:///proj/src/main.zig",
                .live = null,
                .compiler = fr,
                .other_file = Files.get,
                .other_ctx = &dummy,
            });
        }
    }
    return true;
}

test "collect: every mutation of an error bundle that passes validation can be converted" {
    // Guards against out-of-bounds reads: runs the real collect and merge on error bundles that
    // pass validation, so they panic here if they read anything the validation does not cover
    const gpa = testing.allocator;
    var eb = try traceBundle();
    defer eb.deinit(gpa);
    const extra = try gpa.dupe(u32, eb.extra);
    defer gpa.free(extra);
    const strings = try gpa.dupe(u8, eb.string_bytes);
    defer gpa.free(strings);
    const extra_len: u32 = @intCast(extra.len);
    const strings_len: u32 = @intCast(strings.len);
    var accepted: usize = 0;
    for (extra, 0..) |original, i| {
        const values = [_]u32{ 0, 1, 2, 3, @intCast(i), extra_len - 1, extra_len, strings_len - 1, strings_len, std.math.maxInt(u32) - 1, std.math.maxInt(u32) };
        for (values) |value| {
            extra[i] = value;
            if (try collectIfValid(.{ .string_bytes = strings, .extra = extra })) accepted += 1;
        }
        extra[i] = original;
    }
    for (strings, 0..) |original, i| {
        strings[i] = if (original == 0) 'x' else 0;
        if (try collectIfValid(.{ .string_bytes = strings, .extra = extra })) accepted += 1;
        strings[i] = original;
    }
    for (0..extra.len) |n| {
        if (try collectIfValid(.{ .string_bytes = strings, .extra = extra[0..n] })) accepted += 1;
    }
    try testing.expect(accepted > 0);
}

test "collect: paths that do not resolve to absolute paths count as missing locations" {
    const gpa = testing.allocator;
    var wip: ErrorBundle.Wip = try .init(gpa);
    defer wip.deinit();
    // In a malformed error bundle, path indices may point to arbitrary strings. On Windows these
    // are paths relative to another drive and do not resolve to absolute paths; guards against
    // interning them as files (`Vfs.intern` requires absolute paths and panics otherwise).
    const ref_loc = try location(&wip, "D:caller.zig", caller_text, "m.main()", 0);
    const note_loc = try location(&wip, "::", main_text, "x", 0);
    const err_loc = try location(&wip, "x: u32 = 1;", main_text, "\"s\"", 1);
    try wip.addReferenceTrace(.{ .decl_name = try wip.addString("f"), .src_loc = ref_loc });
    try wip.addRootErrorMessageWithNotes(
        .{ .msg = try wip.addString("expected type 'u32', found '*const [1:0]u8'"), .src_loc = err_loc, .notes_len = 1 },
        &.{.{ .msg = try wip.addString("a note"), .src_loc = note_loc }},
    );
    var eb = try wip.toOwnedBundle("");
    defer eb.deinit(gpa);
    var dummy: u8 = 0;
    const r = try compiler.collect(gpa, &.{eb}, native("/proj"), native("/proj/build.zig"), &dummy, Disk.read);
    defer r.release(gpa);

    try testing.expectEqual(1, r.files.count());
    const path = r.files.keys()[0];
    try testing.expect(std.fs.path.isAbsolute(path));
    const item = r.files.values()[0].items[0];
    try testing.expectEqual(2, item.notes.len);
    for (item.notes) |n| try testing.expect(std.fs.path.isAbsolute(n.path));
    try testing.expectEqualStrings("referenced by: f", item.notes[1].message);
    if (@import("builtin").os.tag == .windows) {
        // Treated as having no location: the error is attached to the start of build.zig, and the
        // notes and reference trace are placed at the start of the error
        try testing.expectEqualStrings(native("/proj/build.zig"), path);
        try testing.expectEqual(0, item.start);
        try testing.expectEqual(0, item.end);
        for (item.notes) |n| {
            try testing.expectEqualStrings(path, n.path);
            try testing.expectEqual(0, n.start);
            try testing.expectEqual(0, n.end);
        }
    }
}

test "collect: spans that end before they start become empty" {
    const gpa = testing.allocator;
    var wip: ErrorBundle.Wip = try .init(gpa);
    defer wip.deinit();
    const reversed: ErrorBundle.SourceLocation = .{ .src_path = try wip.addString("src/main.zig"), .line = 0, .column = 0, .span_start = 30, .span_main = 30, .span_end = 1 };
    try wip.addRootErrorMessageWithNotes(
        .{ .msg = try wip.addString("end before start"), .src_loc = try wip.addSourceLocation(reversed), .notes_len = 1 },
        &.{.{ .msg = try wip.addString("a note"), .src_loc = try wip.addSourceLocation(reversed) }},
    );
    var eb = try wip.toOwnedBundle("");
    defer eb.deinit(gpa);
    var dummy: u8 = 0;
    const r = try compiler.collect(gpa, &.{eb}, native("/proj"), native("/proj/build.zig"), &dummy, Disk.read);
    defer r.release(gpa);
    // Guards against publishing a Range that ends before it starts: it becomes an empty range at
    // the start
    const item = r.files.get(native("/proj/src/main.zig")).?.items[0];
    try testing.expectEqual(30, item.start);
    try testing.expectEqual(30, item.end);
    try testing.expectEqual(30, item.notes[0].start);
    try testing.expectEqual(30, item.notes[0].end);
}

test "combine: results of several compilations of the same file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try buildResult();
    defer r.release(testing.allocator);
    const newest = r.files.getPtr(native("/proj/src/main.zig")).?;
    const unused = newest.items[0];
    const sema = newest.items[1];

    // Same text: duplicate errors are kept only once
    const extra: compiler.Item = .{ .start = 0, .end = 3, .message = "another error", .is_astgen = false, .notes = &.{} };
    const same: compiler.FileResult = .{ .base_text = main_text, .items = &.{ sema, extra } };
    // An older text (`= 1` was `= 100` then): non-AstGen errors are shifted onto the newest text;
    // AstGen errors and errors inside the modified region are dropped
    const old_text = try std.mem.replaceOwned(u8, a, main_text, "= 1;", "= 100;");
    const edited: u32 = @intCast(std.mem.indexOf(u8, old_text, "100").?);
    const old: compiler.FileResult = .{ .base_text = old_text, .items = &.{
        .{ .start = sema.start + 2, .end = sema.end + 2, .message = "old error", .is_astgen = false, .notes = &.{} },
        .{ .start = unused.start, .end = unused.end, .message = "old AstGen error", .is_astgen = true, .notes = &.{} },
        .{ .start = edited, .end = edited + 3, .message = "in the edit", .is_astgen = false, .notes = &.{} },
    } };
    const c = try compiler.combine(a, &.{ newest, &same, &old });
    try testing.expectEqualStrings(main_text, c.base_text);
    try testing.expectEqual(4, c.items.len);
    try testing.expectEqualStrings(unused.message, c.items[0].message);
    try testing.expectEqualStrings(sema.message, c.items[1].message);
    try testing.expectEqualStrings("another error", c.items[2].message);
    try testing.expectEqualStrings("old error", c.items[3].message);
    try testing.expectEqual(sema.start, c.items[3].start);
    try testing.expectEqual(sema.end, c.items[3].end);
}

/// An error bundle with a single error ("unused local variable") and `log_text` as the compile log
/// output
fn unusedWithLog(log_text: []const u8) !ErrorBundle {
    var wip: ErrorBundle.Wip = try .init(testing.allocator);
    defer wip.deinit();
    try addError(&wip, "src/main.zig", main_text, "unused", "unused local variable");
    return wip.toOwnedBundle(log_text);
}

test "compile log: kept apart from the message for dedup and the AstGen flag" {
    const gpa = testing.allocator;
    // Several compile steps report the same AstGen error, some with compile log output (attached to
    // the first error when there is no "found compile log statement")
    var plain = try unusedWithLog("");
    defer plain.deinit(gpa);
    var log1 = try unusedWithLog("@as(comptime_int, 1)\n");
    defer log1.deinit(gpa);
    var log2 = try unusedWithLog("@as(comptime_int, 2)\n");
    defer log2.deinit(gpa);
    var dummy: u8 = 0;
    const r = try compiler.collect(gpa, &.{ plain, log1, log1, log2 }, native("/proj"), native("/proj/build.zig"), &dummy, Disk.read);
    defer r.release(gpa);
    const result = r.files.getPtr(native("/proj/src/main.zig")).?;
    // Guards against the same error showing up several times, and no longer being recognized as an
    // AstGen error, because it carries a compile log: only one is kept, and the output of every
    // step is merged into it
    try testing.expectEqual(1, result.items.len);
    const item = result.items[0];
    try testing.expect(item.is_astgen);
    try testing.expectEqualStrings("unused local variable", item.message);
    try testing.expectEqualStrings("@as(comptime_int, 1)\n@as(comptime_int, 2)", item.compile_log);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Combining the results of several compilations also keeps only one, with the output merged
    // into the kept one
    var without_log = item;
    without_log.compile_log = "";
    const other: compiler.FileResult = .{ .base_text = main_text, .items = &.{without_log} };
    const c = try compiler.combine(a, &.{ &other, result });
    try testing.expectEqual(1, c.items.len);
    try testing.expectEqualStrings(item.compile_log, c.items[0].compile_log);

    // The text matches the build: the output is appended to the message
    const msgs = try mergeMessages(a, main_text, true, result);
    try testing.expectEqual(1, msgs.len);
    try testing.expectEqualStrings("zig@1:8: unused local variable\n\nCompile Log Output:\n@as(comptime_int, 1)\n@as(comptime_int, 2)", msgs[0]);
    // Unsaved changes: the AstGen error comes only from live and does not duplicate the compiler's.
    // Guards against losing the compile log with the hidden error: it is published on its own at
    // the error's start
    const edited = try std.mem.concat(a, u8, &.{ "// new comment\n", main_text });
    const msgs2 = try mergeMessages(a, edited, true, result);
    try testing.expectEqual(2, msgs2.len);
    try testing.expectEqualStrings("zig ast-check@2:8: unused local variable", msgs2[0]);
    try testing.expectEqualStrings("zig@2:8: Compile Log Output:\n@as(comptime_int, 1)\n@as(comptime_int, 2)", msgs2[1]);
    // The line of the error is modified: the log is at the start of the modified region
    const changed_line = try std.mem.replaceOwned(u8, a, main_text, "var unused = 1;", "var unused = 12;");
    const msgs3 = try mergeMessages(a, changed_line, false, result);
    try testing.expectEqual(1, msgs3.len);
    try testing.expectEqualStrings("zig@1:0: Compile Log Output:\n@as(comptime_int, 1)\n@as(comptime_int, 2)", msgs3[0]);
}

test "compile log: attached to an error in the build root rather than one sorted before it" {
    const gpa = testing.allocator;
    var wip: ErrorBundle.Wip = try .init(gpa);
    defer wip.deinit();
    // The compiler sorts errors in the standard library first; with other errors it reports no
    // "found compile log statement"
    try addError(&wip, native("/usr/lib/zig/std/Io/Writer.zig"), main_text, "unused", "invalid format string 's' for type 'comptime_int'");
    try addError(&wip, "src/main.zig", main_text, "\"s\"", "expected type 'u32', found '*const [1:0]u8'");
    var eb = try wip.toOwnedBundle("@as(comptime_int, 24)\n");
    defer eb.deinit(gpa);
    var dummy: u8 = 0;
    const r = try compiler.collect(gpa, &.{eb}, native("/proj"), native("/proj/build.zig"), &dummy, Disk.read);
    defer r.release(gpa);
    // Guards against attaching the output to the error in the standard library
    try testing.expectEqualStrings("", r.files.get(native("/usr/lib/zig/std/Io/Writer.zig")).?.items[0].compile_log);
    try testing.expectEqualStrings("@as(comptime_int, 24)", r.files.get(native("/proj/src/main.zig")).?.items[0].compile_log);
}

test "collect: notes of an error without a location outlive the fallback path" {
    const gpa = testing.allocator;
    var wip: ErrorBundle.Wip = try .init(gpa);
    defer wip.deinit();
    try wip.addRootErrorMessageWithNotes(
        .{ .msg = try wip.addString("undefined symbol: _za_missing"), .notes_len = 1 },
        &.{.{ .msg = try wip.addString("referenced by /proj/.zig-cache/o/x/linkerr_zcu.o:_main.main") }},
    );
    var eb = try wip.toOwnedBundle("");
    defer eb.deinit(gpa);
    const fallback = try gpa.dupe(u8, native("/proj/build.zig"));
    defer gpa.free(fallback);
    var dummy: u8 = 0;
    const r = try compiler.collect(gpa, &.{eb}, native("/proj"), fallback, &dummy, Disk.read);
    defer r.release(gpa);
    // The caller reuses the memory of its path after the call
    @memset(fallback, 'x');
    // Guards against keeping the caller's path as the note's path
    try testing.expectEqualStrings(native("/proj/build.zig"), r.files.keys()[0]);
    const item = r.files.values()[0].items[0];
    try testing.expectEqual(1, item.notes.len);
    try testing.expectEqualStrings(native("/proj/build.zig"), item.notes[0].path);
    try testing.expectEqualStrings("referenced by /proj/.zig-cache/o/x/linkerr_zcu.o:_main.main", item.notes[0].message);
}

/// An error at `"s"` with the note "called inline here" at `note_needle`
fn addInlineError(wip: *ErrorBundle.Wip, note_needle: []const u8) !void {
    const err_loc = try location(wip, "src/main.zig", main_text, "\"s\"", 0);
    const note_loc = try location(wip, "src/main.zig", main_text, note_needle, 0);
    try wip.addRootErrorMessageWithNotes(
        .{ .msg = try wip.addString("expected type 'u32', found '*const [1:0]u8'"), .src_loc = err_loc, .notes_len = 1 },
        &.{.{ .msg = try wip.addString("called inline here"), .src_loc = note_loc }},
    );
}

test "collect and combine: errors that differ only in their notes are kept apart" {
    const gpa = testing.allocator;
    var wip: ErrorBundle.Wip = try .init(gpa);
    defer wip.deinit();
    try addInlineError(&wip, "unused");
    try addInlineError(&wip, "_ = x");
    // A repeat with the same note is still the same error
    try addInlineError(&wip, "unused");
    var eb = try wip.toOwnedBundle("");
    defer eb.deinit(gpa);
    var dummy: u8 = 0;
    const r = try compiler.collect(gpa, &.{eb}, native("/proj"), native("/proj/build.zig"), &dummy, Disk.read);
    defer r.release(gpa);
    const result = r.files.getPtr(native("/proj/src/main.zig")).?;
    // Guards against merging the errors of two inline call sites into one
    try testing.expectEqual(2, result.items.len);
    try testing.expectEqual(std.mem.indexOf(u8, main_text, "unused").?, result.items[0].notes[0].start);
    try testing.expectEqual(std.mem.indexOf(u8, main_text, "_ = x").?, result.items[1].notes[0].start);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const first: compiler.FileResult = .{ .base_text = main_text, .items = result.items[0..1] };
    const second: compiler.FileResult = .{ .base_text = main_text, .items = result.items[1..2] };
    const c = try compiler.combine(arena.allocator(), &.{ &first, &second, result });
    try testing.expectEqual(2, c.items.len);
    try testing.expectEqual(std.mem.indexOf(u8, main_text, "_ = x").?, c.items[1].notes[0].start);
}

test "collect: repeat counts of messages and notes are kept" {
    const gpa = testing.allocator;
    var wip: ErrorBundle.Wip = try .init(gpa);
    defer wip.deinit();
    const err_loc = try location(&wip, "src/main.zig", main_text, "\"s\"", 0);
    const note_loc = try location(&wip, "src/main.zig", main_text, "unused", 0);
    try wip.addRootErrorMessageWithNotes(
        .{ .msg = try wip.addString("evaluation exceeded 1000 backwards branches"), .src_loc = err_loc, .notes_len = 2 },
        &.{
            .{ .msg = try wip.addString("called at comptime here"), .src_loc = note_loc, .count = 3 },
            .{ .msg = try wip.addString("called at comptime here"), .src_loc = err_loc },
        },
    );
    var eb = try wip.toOwnedBundle("");
    defer eb.deinit(gpa);
    var dummy: u8 = 0;
    const r = try compiler.collect(gpa, &.{eb}, native("/proj"), native("/proj/build.zig"), &dummy, Disk.read);
    defer r.release(gpa);
    const notes = r.files.get(native("/proj/src/main.zig")).?.items[0].notes;
    // Guards against dropping the count that the compiler prints
    try testing.expectEqualStrings("called at comptime here (3 times)", notes[0].message);
    try testing.expectEqualStrings("called at comptime here", notes[1].message);
}
