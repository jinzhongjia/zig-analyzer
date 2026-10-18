//! 校验子进程回传的 `std.zig.ErrorBundle`。
//!
//! ErrorBundle 的格式没有版本号：用户 zig 与 zig-analyzer 编译时的版本不同时，单文件编译读取的就是另一个
//! 版本的编译器产出的数据。标准库的读取函数（`getErrorMessage`、`getNotes`、`nullTerminatedString` 等）与
//! `diagnostics/compiler.zig` 按布局读取引用链时都不检查下标，格式不符时会越界读取，因此使用前先校验。

const std = @import("std");
const ErrorBundle = std.zig.ErrorBundle;

const list_words = fieldCount(ErrorBundle.ErrorMessageList);
const message_words = fieldCount(ErrorBundle.ErrorMessage);
const location_words = fieldCount(ErrorBundle.SourceLocation);
const trace_words = fieldCount(ErrorBundle.ReferenceTrace);

/// 附注与引用链中的位置的最大嵌套深度，使校验的递归有界：自引用与环都会超出它。
/// 编译器产出的附注只有一层，引用链中的位置不再带引用链
const max_depth = 32;

/// 读取总量的上限是 `extra.len` 的倍数。标准库构造的错误包中各结构互不重叠、只被引用一次，读取总量不超过
/// `extra.len`；共用结构的错误包也能通过，而大量指向同一结构的引用（读取量随嵌套层数指数增长）被拒绝
const max_reads_per_word = 4;

/// `eb` 中本项目与它调用的标准库函数会读取的内容是否都在范围内：
/// - 消息列表、各条消息与逐层的附注、源位置与其后的引用链都在 `extra` 内；
/// - 消息、路径、源码行、引用名与 compile log 的下标都指向 `string_bytes` 中以 0 结尾的字符串；
/// - 引用链中没有位置的项（隐藏标记）的 `decl_name` 是隐藏的引用数而不是字符串，与引用链长度相加后不超出 u32。
///
/// 行列、span 与 `count` 等数值不检查，使用方要能处理任意值。空的错误包（`extra` 为空）合法。
pub fn isValid(eb: ErrorBundle) bool {
    if (eb.extra.len == 0) return true;
    // 下标都是 u32：标准库与 `diagnostics/compiler.zig` 用 u32 计算结构之后的位置
    if (eb.extra.len > std.math.maxInt(u32)) return false;
    var v: Validator = .{
        .eb = eb,
        .last_nul = std.mem.lastIndexOfScalar(u8, eb.string_bytes, 0),
        .budget = @as(u64, eb.extra.len) * max_reads_per_word,
    };
    if (!v.take(0, list_words)) return false;
    const list = eb.getErrorMessageList();
    // `getCompileLogOutput` 在没有输出（下标为 0）时同样读取这个字符串
    if (!v.string(list.compile_log_text)) return false;
    if (!v.take(list.start, list.len)) return false;
    for (eb.getMessages()) |mi| if (!v.message(@backingInt(mi), 0)) return false;
    return true;
}

const Validator = struct {
    eb: ErrorBundle,
    /// `string_bytes` 中最后一个 0 的位置：字符串下标不超过它时，从下标往后一定能读到终止符
    last_nul: ?usize,
    /// 还能读取的 `extra` 字数
    budget: u64,

    /// 读取 `extra[index..][0..len]`：要在范围内，且不超出读取总量
    fn take(v: *Validator, index: u64, len: u64) bool {
        if (index + len > v.eb.extra.len or len > v.budget) return false;
        v.budget -= len;
        return true;
    }

    fn string(v: *const Validator, index: ErrorBundle.String) bool {
        const last = v.last_nul orelse return false;
        return index <= last;
    }

    /// 消息与它的附注。附注也是消息，标准库渲染时逐层递归
    fn message(v: *Validator, index: u32, depth: u32) bool {
        if (depth > max_depth or !v.take(index, message_words)) return false;
        const mi: ErrorBundle.MessageIndex = @fromBackingInt(index);
        const msg = v.eb.getErrorMessage(mi);
        if (!v.string(msg.msg)) return false;
        if (msg.src_loc != .none and !v.location(@backingInt(msg.src_loc), depth + 1)) return false;
        if (!v.take(@as(u64, index) + message_words, msg.notes_len)) return false;
        for (v.eb.getNotes(mi)) |note| if (!v.message(@backingInt(note), depth + 1)) return false;
        return true;
    }

    /// 源位置与其后的引用链
    fn location(v: *Validator, index: u32, depth: u32) bool {
        if (depth > max_depth or !v.take(index, location_words)) return false;
        const loc = v.eb.getSourceLocation(@fromBackingInt(index));
        if (!v.string(loc.src_path)) return false;
        if (loc.source_line != 0 and !v.string(loc.source_line)) return false;
        const first = @as(u64, index) + location_words;
        if (!v.take(first, @as(u64, loc.reference_trace_len) * trace_words)) return false;
        // 每项按字段顺序存放 `decl_name` 与 `src_loc`
        for (0..loc.reference_trace_len) |k| {
            const at: usize = @intCast(first + k * trace_words);
            const decl_name = v.eb.extra[at];
            const ref_loc = v.eb.extra[at + 1];
            if (ref_loc != @backingInt(ErrorBundle.SourceLocationIndex.none)) {
                if (!v.string(decl_name) or !v.location(ref_loc, depth + 1)) return false;
            } else if (decl_name != 0) {
                // 隐藏标记：渲染为 `-freference-trace=<隐藏数 + 引用链长度 - 1>`，按 u32 先加后减
                if (@as(u64, decl_name) + loc.reference_trace_len > std.math.maxInt(u32)) return false;
            }
        }
        return true;
    }
};

fn fieldCount(comptime T: type) comptime_int {
    return @typeInfo(T).@"struct".field_names.len;
}

const testing = std.testing;

/// 用标准库构造的合法错误包，以及其中各结构在 `extra` 中的下标
const Fixture = struct {
    eb: ErrorBundle,
    /// 带附注、源码行与引用链（一个有位置的引用、一个隐藏计数）的消息
    root: u32,
    err_loc: u32,
    /// 没有位置的消息，它的附注还带有附注
    chain: u32,
    nested: u32,

    fn init() !Fixture {
        const gpa = testing.allocator;
        var wip: ErrorBundle.Wip = try .init(gpa);
        defer wip.deinit();
        const ref_loc = try wip.addSourceLocation(.{
            .src_path = try wip.addString("caller.zig"),
            .line = 2,
            .column = 4,
            .span_start = 40,
            .span_main = 40,
            .span_end = 48,
            .source_line = try wip.addString("    m.main();"),
        });
        const note_loc = try wip.addSourceLocation(.{ .src_path = try wip.addString("main.zig"), .line = 3, .column = 8, .span_start = 50, .span_main = 50, .span_end = 51 });
        const err_loc = try wip.addSourceLocation(.{
            .src_path = try wip.addString("main.zig"),
            .line = 2,
            .column = 19,
            .span_start = 30,
            .span_main = 30,
            .span_end = 33,
            .source_line = try wip.addString("    const x: u32 = \"s\";"),
            .reference_trace_len = 2,
        });
        try wip.addReferenceTrace(.{ .decl_name = try wip.addString("f"), .src_loc = ref_loc });
        // 隐藏计数大于 `string_bytes` 的长度：误当作字符串下标时校验失败
        try wip.addReferenceTrace(.{ .decl_name = 100000, .src_loc = .none });
        try wip.addRootErrorMessageWithNotes(
            .{ .msg = try wip.addString("expected type 'u32', found '*const [1:0]u8'"), .count = 2, .src_loc = err_loc, .notes_len = 1 },
            &.{.{ .msg = try wip.addString("a note"), .src_loc = note_loc }},
        );

        const unused_loc = try wip.addSourceLocation(.{ .src_path = try wip.addString("main.zig"), .line = 1, .column = 8, .span_start = 25, .span_main = 25, .span_end = 31, .reference_trace_len = 1 });
        try wip.addReferenceTrace(.{ .decl_name = 0, .src_loc = .none });
        try wip.addRootErrorMessage(.{ .msg = try wip.addString("unused local variable"), .src_loc = unused_loc });

        // 附注的附注
        try wip.addRootErrorMessage(.{ .msg = try wip.addString("undefined symbol: foo"), .notes_len = 1 });
        const chain_notes = try wip.reserveNotes(1);
        const nested = try wip.addErrorMessage(.{ .msg = try wip.addString("referenced here"), .notes_len = 1 });
        const nested_notes = try wip.reserveNotes(1);
        const leaf = try wip.addErrorMessage(.{ .msg = try wip.addString("and here") });
        wip.extra.items[chain_notes] = @backingInt(nested);
        wip.extra.items[nested_notes] = @backingInt(leaf);

        const root = @backingInt(wip.root_list.items[0]);
        const chain = @backingInt(wip.root_list.items[2]);
        return .{
            .eb = try wip.toOwnedBundle("@as(comptime_int, 3)\n"),
            .root = root,
            .err_loc = @backingInt(err_loc),
            .chain = chain,
            .nested = @backingInt(nested),
        };
    }

    fn deinit(f: *Fixture) void {
        f.eb.deinit(testing.allocator);
    }
};

/// 按标准库读取函数与 `diagnostics/compiler.zig` 的方式读取全部内容：越界时 panic
fn readAll(eb: ErrorBundle) void {
    if (eb.extra.len == 0) return;
    std.mem.doNotOptimizeAway(eb.getCompileLogOutput().len);
    for (eb.getMessages()) |mi| readMessage(eb, mi);
}

fn readMessage(eb: ErrorBundle, mi: ErrorBundle.MessageIndex) void {
    const msg = eb.getErrorMessage(mi);
    std.mem.doNotOptimizeAway(eb.nullTerminatedString(msg.msg).len);
    if (msg.src_loc != .none) readLocation(eb, msg.src_loc);
    for (eb.getNotes(mi)) |note| readMessage(eb, note);
}

fn readLocation(eb: ErrorBundle, index: ErrorBundle.SourceLocationIndex) void {
    const loc = eb.getSourceLocation(index);
    std.mem.doNotOptimizeAway(eb.nullTerminatedString(loc.src_path).len);
    if (loc.source_line != 0) std.mem.doNotOptimizeAway(eb.nullTerminatedString(loc.source_line).len);
    const first = @backingInt(index) + location_words;
    for (0..loc.reference_trace_len) |k| {
        const decl_name = eb.extra[first + k * trace_words];
        const ref_loc: ErrorBundle.SourceLocationIndex = @fromBackingInt(eb.extra[first + k * trace_words + 1]);
        if (ref_loc != .none) {
            std.mem.doNotOptimizeAway(eb.nullTerminatedString(decl_name).len);
            readLocation(eb, ref_loc);
        } else if (decl_name != 0) {
            std.mem.doNotOptimizeAway(decl_name + loc.reference_trace_len - 1);
        }
    }
}

test "valid error bundle: notes, source lines, reference traces and compile log" {
    var f: Fixture = try .init();
    defer f.deinit();
    try testing.expect(isValid(f.eb));
    try testing.expect(isValid(.empty));
    readAll(f.eb);
    // 夹具遵循标准库的约定：标准库能渲染它
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try f.eb.renderToWriter(.{}, &w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "100000 reference(s) hidden; use '-freference-trace=100001'") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "note: and here") != null);
}

test "malformed error bundles are rejected" {
    const gpa = testing.allocator;
    var f: Fixture = try .init();
    defer f.deinit();
    const eb = f.eb;
    const extra_len: u32 = @intCast(eb.extra.len);
    const strings_len: u32 = @intCast(eb.string_bytes.len);
    const list_start = eb.getErrorMessageList().start;
    const trace = f.err_loc + location_words;
    const Case = struct { name: []const u8, at: u32, value: u32 };
    const cases = [_]Case{
        .{ .name = "message string out of range", .at = f.root, .value = strings_len },
        .{ .name = "list length past the end", .at = 0, .value = extra_len },
        .{ .name = "list start past the end", .at = 1, .value = extra_len - 1 },
        .{ .name = "compile log out of range", .at = 2, .value = strings_len },
        .{ .name = "message index out of range", .at = list_start, .value = extra_len - 2 },
        .{ .name = "src_loc out of range", .at = f.root + 2, .value = extra_len - 4 },
        .{ .name = "notes_len out of range", .at = f.root + 3, .value = extra_len },
        .{ .name = "note index out of range", .at = f.root + message_words, .value = std.math.maxInt(u32) },
        .{ .name = "src_path out of range", .at = f.err_loc, .value = std.math.maxInt(u32) },
        .{ .name = "source_line out of range", .at = f.err_loc + 6, .value = strings_len + 1 },
        .{ .name = "reference_trace_len out of range", .at = f.err_loc + 7, .value = extra_len },
        .{ .name = "reference name out of range", .at = trace, .value = strings_len },
        .{ .name = "reference location out of range", .at = trace + 1, .value = extra_len },
        .{ .name = "hidden reference count overflows", .at = trace + trace_words, .value = std.math.maxInt(u32) - 1 },
        .{ .name = "note refers to its own message", .at = f.root + message_words, .value = f.root },
        .{ .name = "note refers to an ancestor", .at = f.nested + message_words, .value = f.chain },
        .{ .name = "reference location refers to itself", .at = trace + 1, .value = f.err_loc },
    };
    for (cases) |c| {
        const extra = try gpa.dupe(u32, eb.extra);
        defer gpa.free(extra);
        extra[c.at] = c.value;
        const bad: ErrorBundle = .{ .string_bytes = eb.string_bytes, .extra = extra };
        if (isValid(bad)) {
            std.debug.print("accepted: {s}\n", .{c.name});
            return error.TestUnexpectedResult;
        }
    }

    // 最后一个字符串（compile log）没有终止符
    const strings = try gpa.dupe(u8, eb.string_bytes);
    defer gpa.free(strings);
    strings[strings.len - 1] = 'x';
    try testing.expect(!isValid(.{ .string_bytes = strings, .extra = eb.extra }));
    // 没有字符串、消息列表不完整
    try testing.expect(!isValid(.{ .string_bytes = &.{}, .extra = eb.extra }));
    try testing.expect(!isValid(.{ .string_bytes = eb.string_bytes, .extra = eb.extra[0..2] }));
}

test "nested and shared references are bounded" {
    const gpa = testing.allocator;
    // 每条消息的两个附注都指向上一层的消息：逐层展开时读取量是 2^levels
    for ([_]u32{ 2, 30 }, [_]bool{ true, false }) |levels, expected| {
        var extra: std.ArrayList(u32) = .empty;
        defer extra.deinit(gpa);
        try extra.appendSlice(gpa, &.{ 1, 0, 0 });
        var prev: u32 = 0;
        for (0..levels + 1) |level| {
            const index: u32 = @intCast(extra.items.len);
            try extra.appendSlice(gpa, &.{ 0, 1, 0, @as(u32, if (level == 0) 0 else 2) });
            if (level != 0) try extra.appendSlice(gpa, &.{ prev, prev });
            prev = index;
        }
        extra.items[1] = @intCast(extra.items.len);
        try extra.append(gpa, prev);
        const eb: ErrorBundle = .{ .string_bytes = "\x00", .extra = extra.items };
        try testing.expectEqual(expected, isValid(eb));
        if (expected) readAll(eb);
    }
}

test "every accepted mutation of a valid error bundle can be read" {
    const gpa = testing.allocator;
    var f: Fixture = try .init();
    defer f.deinit();
    const eb = f.eb;
    const extra = try gpa.dupe(u32, eb.extra);
    defer gpa.free(extra);
    const strings = try gpa.dupe(u8, eb.string_bytes);
    defer gpa.free(strings);
    const extra_len: u32 = @intCast(extra.len);
    const strings_len: u32 = @intCast(strings.len);
    for (extra, 0..) |original, i| {
        const values = [_]u32{ 0, 1, 2, 3, @intCast(i), extra_len - 1, extra_len, extra_len + 1, strings_len - 1, strings_len, std.math.maxInt(u32) - 1, std.math.maxInt(u32) };
        for (values) |value| {
            extra[i] = value;
            const mutated: ErrorBundle = .{ .string_bytes = strings, .extra = extra };
            if (isValid(mutated)) readAll(mutated);
        }
        extra[i] = original;
    }
    for (strings, 0..) |original, i| {
        strings[i] = if (original == 0) 'x' else 0;
        const mutated: ErrorBundle = .{ .string_bytes = strings, .extra = extra };
        if (isValid(mutated)) readAll(mutated);
        strings[i] = original;
    }
    for (0..extra.len) |n| {
        const truncated: ErrorBundle = .{ .string_bytes = strings, .extra = extra[0..n] };
        if (isValid(truncated)) readAll(truncated);
    }
    for (0..strings.len) |n| {
        const truncated: ErrorBundle = .{ .string_bytes = strings[0..n], .extra = extra };
        if (isValid(truncated)) readAll(truncated);
    }
}
