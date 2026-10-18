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

test "merge: malformed compiler spans do not overflow when remapped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sema_start: u32 = @intCast(std.mem.indexOf(u8, main_text, "\"s\"").?);
    // 防止平移时溢出而 panic：接近 u32 上限的区间后移、终点在起点之前的区间前移后不在 u32 范围内，丢弃
    const result: compiler.FileResult = .{ .base_text = main_text, .items = &.{
        .{ .start = sema_start, .end = sema_start + 3, .message = "sema error", .is_astgen = false, .notes = &.{} },
        .{ .start = std.math.maxInt(u32) - 1, .end = std.math.maxInt(u32), .message = "past the end", .is_astgen = false, .notes = &.{} },
        .{ .start = 30, .end = 1, .message = "end before start", .is_astgen = false, .notes = &.{} },
    } };
    // 在开头插入：区间后移
    const msgs = try mergeMessages(a, try std.mem.concat(a, u8, &.{ "// x\n", main_text }), false, &result);
    try testing.expectEqual(2, msgs.len);
    try testing.expectEqualStrings("zig@3:19: sema error", msgs[0]);
    try testing.expect(std.mem.endsWith(u8, msgs[1], "end before start"));
    // 删去开头：区间前移
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

/// 源位置：`needle` 在 `text` 中的区间
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

/// 带附注与引用链的错误包：第一条错误的引用链有一个有位置的引用、一个隐藏计数，第二条只剩隐藏标记，
/// 还有 compile log 的输出
fn traceBundle() !ErrorBundle {
    var wip: ErrorBundle.Wip = try .init(testing.allocator);
    defer wip.deinit();
    // 引用链紧跟在错误的源位置之后
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

test "collect: reference trace and compile log output are kept" {
    const gpa = testing.allocator;
    var eb = try traceBundle();
    defer eb.deinit(gpa);
    var dummy: u8 = 0;
    var r = try compiler.collect(gpa, &.{eb}, native("/proj"), native("/proj/build.zig"), &dummy, Disk.read);
    defer r.deinit(gpa);

    const items = r.files.get(native("/proj/src/main.zig")).?.items;
    try testing.expectEqual(3, items.len);
    const err_start: u32 = @intCast(std.mem.indexOf(u8, main_text, "\"s\"").?);
    const notes = items[0].notes;
    try testing.expectEqual(3, notes.len);
    try testing.expectEqualStrings("a note", notes[0].message);
    try testing.expectEqualStrings(native("/proj/src/caller.zig"), notes[1].path);
    try testing.expectEqual(std.mem.indexOf(u8, caller_text, "m.main()").?, notes[1].start);
    try testing.expectEqualStrings("referenced by: f", notes[1].message);
    // 隐藏计数没有位置：放在错误的起点，文案与 zig build 的输出相同
    try testing.expectEqualStrings(native("/proj/src/main.zig"), notes[2].path);
    try testing.expectEqual(err_start, notes[2].start);
    try testing.expectEqual(err_start, notes[2].end);
    try testing.expectEqualStrings("3 reference(s) hidden; use '-freference-trace=4' to see all references", notes[2].message);
    try testing.expectEqual(1, items[1].notes.len);
    try testing.expectEqualStrings("remaining reference traces hidden; use '-freference-trace' to see all reference traces", items[1].notes[0].message);
    try testing.expectEqualStrings("found compile log statement", items[2].message);
    try testing.expectEqualStrings("@as(comptime_int, 3)\n@as(*const [2:0]u8, \"hi\")", items[2].compile_log);

    // 发布时附注与引用链都成为 relatedInformation
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
    // compile log 的输出接在文案之后
    try testing.expectEqualStrings(
        \\found compile log statement
        \\
        \\Compile Log Output:
        \\@as(comptime_int, 3)
        \\@as(*const [2:0]u8, "hi")
    , diags[2].message.string);
}

/// `eb` 通过校验时转换并发布（按构建时的文本与有修改的文本各发布一次），返回是否通过校验
fn collectIfValid(eb: ErrorBundle) !bool {
    if (!error_bundle.isValid(eb)) return false;
    const gpa = testing.allocator;
    var dummy: u8 = 0;
    var r = try compiler.collect(gpa, &.{eb}, native("/proj"), native("/proj/build.zig"), &dummy, Disk.read);
    defer r.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for (r.files.values()) |*fr| {
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
    // 防止越界读取：对通过校验的错误包运行真正的 collect 与 merge，它们读取了校验没有覆盖的内容时在这里 panic
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

test "combine: results of several compilations of the same file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try buildResult();
    defer r.deinit(testing.allocator);
    const newest = r.files.getPtr(native("/proj/src/main.zig")).?;
    const unused = newest.items[0];
    const sema = newest.items[1];

    // 同一文本：重复的错误只保留一条
    const extra: compiler.Item = .{ .start = 0, .end = 3, .message = "another error", .is_astgen = false, .notes = &.{} };
    const same: compiler.FileResult = .{ .base_text = main_text, .items = &.{ sema, extra } };
    // 较旧的文本（`= 1` 当时是 `= 100`）：非 AstGen 错误平移到最新的文本上，AstGen 错误与落在修改区域内的丢弃
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

/// 只有一条错误（"unused local variable"）的错误包，compile log 的输出为 `log_text`
fn unusedWithLog(log_text: []const u8) !ErrorBundle {
    var wip: ErrorBundle.Wip = try .init(testing.allocator);
    defer wip.deinit();
    try addError(&wip, "src/main.zig", main_text, "unused", "unused local variable");
    return wip.toOwnedBundle(log_text);
}

test "compile log: kept apart from the message for dedup and the AstGen flag" {
    const gpa = testing.allocator;
    // 几个 compile step 报告同一个 AstGen 错误，其中一些带有 compile log 的输出（没有
    // "found compile log statement" 时附在第一条错误上）
    var plain = try unusedWithLog("");
    defer plain.deinit(gpa);
    var log1 = try unusedWithLog("@as(comptime_int, 1)\n");
    defer log1.deinit(gpa);
    var log2 = try unusedWithLog("@as(comptime_int, 2)\n");
    defer log2.deinit(gpa);
    var dummy: u8 = 0;
    var r = try compiler.collect(gpa, &.{ plain, log1, log1, log2 }, native("/proj"), native("/proj/build.zig"), &dummy, Disk.read);
    defer r.deinit(gpa);
    const result = r.files.getPtr(native("/proj/src/main.zig")).?;
    // 防止同一错误因带有 compile log 而显示多次、不再被识别为 AstGen 错误：只保留一条，各个 step 的输出并到这一条上
    try testing.expectEqual(1, result.items.len);
    const item = result.items[0];
    try testing.expect(item.is_astgen);
    try testing.expectEqualStrings("unused local variable", item.message);
    try testing.expectEqualStrings("@as(comptime_int, 1)\n@as(comptime_int, 2)", item.compile_log);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // 多次编译的结果合并时同样只保留一条，输出并到保留的那条上
    var without_log = item;
    without_log.compile_log = "";
    const other: compiler.FileResult = .{ .base_text = main_text, .items = &.{without_log} };
    const c = try compiler.combine(a, &.{ &other, result });
    try testing.expectEqual(1, c.items.len);
    try testing.expectEqualStrings(item.compile_log, c.items[0].compile_log);

    // 文本与构建时一致：输出接在文案之后
    const msgs = try mergeMessages(a, main_text, true, result);
    try testing.expectEqual(1, msgs.len);
    try testing.expectEqualStrings("zig@1:8: unused local variable\n\nCompile Log Output:\n@as(comptime_int, 1)\n@as(comptime_int, 2)", msgs[0]);
    // 有未保存修改：AstGen 错误只由 live 提供，不与编译器的那条重复
    const edited = try std.mem.concat(a, u8, &.{ "// 新注释\n", main_text });
    const msgs2 = try mergeMessages(a, edited, true, result);
    try testing.expectEqual(1, msgs2.len);
    try testing.expectEqualStrings("zig ast-check@2:8: unused local variable", msgs2[0]);
}
