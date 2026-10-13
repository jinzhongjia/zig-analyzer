//! 路径与 URI 的性质测试，两种驱动方式共用同一组性质：
//!
//! - 固定种子的伪随机循环：每次 `zig build test` 都在所有平台上运行；
//! - `std.testing.fuzz`：`zig build test --fuzz=<次数>` 时由覆盖率引导的模糊测试驱动。
//!
//! 两种路径风格在任何平台上都会测试，Windows 规则不必等到 Windows 机器上才暴露问题。

const std = @import("std");
const testing = std.testing;
const uri = @import("uri.zig");
const Style = uri.Style;
const Vfs = @import("Vfs.zig");
const Entropy = @import("../util/Entropy.zig");

/// 文件名中的字符：普通字符、URI 需要编码的特殊字符、多字节 UTF-8
const name_pieces = [_][]const u8{
    "a", "Z",   "0",   "_",    "-", ".", " ", "%", "#", "?", "+", "&", "=", "@", "!", "~", ",",
    ";", "'",   "(",   ")",    "[", "]", "{", "}", "$",
    "中",
    "é",
    "😀",
    ":", "%20", "%3A", "file",
};

fn genComponent(e: *Entropy, out: *std.ArrayList(u8), comptime style: Style) !void {
    // 偶尔生成 `.`、`..`、空组件，交给规范化处理
    switch (e.below(10)) {
        0 => return out.appendSlice(testing.allocator, "."),
        1 => return out.appendSlice(testing.allocator, ".."),
        2 => return,
        else => {},
    }
    const n = 1 + e.below(6);
    for (0..n) |_| {
        const piece = e.pick([]const u8, &name_pieces);
        // Windows 的 `:` 只出现在盘符中（NTFS 备用数据流不在考虑范围内）
        if (style == .windows and std.mem.eql(u8, piece, ":")) continue;
        try out.appendSlice(testing.allocator, piece);
    }
}

/// 生成一个（未必规范的）绝对路径
fn genPath(e: *Entropy, out: *std.ArrayList(u8), comptime style: Style) !void {
    const a = testing.allocator;
    switch (style) {
        .posix => try out.append(a, '/'),
        .windows => if (e.below(4) == 0) {
            // UNC：\\server\share\
            try out.appendSlice(a, if (e.below(2) == 0) "\\\\" else "//");
            try out.appendSlice(a, e.pick([]const u8, &.{ "server", "srv-1", "host.local" }));
            try out.append(a, '\\');
            try out.appendSlice(a, e.pick([]const u8, &.{ "share", "c$", "Data" }));
            try out.append(a, '\\');
        } else {
            const letter = "acdzACDZ"[e.below(8)];
            try out.append(a, letter);
            try out.appendSlice(a, if (e.below(2) == 0) ":\\" else ":/");
        },
    }
    const n = e.below(6);
    for (0..n) |i| {
        if (i != 0) {
            const sep: u8 = if (style == .windows and e.below(2) == 0) '/' else std.fs.path.sep_posix;
            try out.append(a, if (style == .windows and sep == '/') '/' else if (style == .windows) '\\' else '/');
            if (e.below(8) == 0) try out.append(a, if (style == .windows) '\\' else '/'); // 重复分隔符
        }
        try genComponent(e, out, style);
    }
    if (e.below(6) == 0) try out.append(a, if (style == .windows) '\\' else '/'); // 末尾分隔符
}

/// 性质：规范化幂等；URI 往返；生成的 URI 只含合法字符
fn checkPathProperties(comptime style: Style, e: *Entropy) !void {
    const a = testing.allocator;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(a);
    try genPath(e, &raw, style);

    const normalized = try Vfs.normalize(style, a, raw.items) orelse return error.TestUnexpectedResult;
    defer a.free(normalized);
    const again = (try Vfs.normalize(style, a, normalized)).?;
    defer a.free(again);
    try expectEqualPaths(normalized, again, raw.items);

    if (style == .windows) {
        try testing.expect(std.mem.indexOfScalar(u8, normalized, '/') == null);
        if (normalized[1] == ':') try testing.expect(std.ascii.isUpper(normalized[0]));
    }

    const u = try uri.fromPathStyle(style, a, normalized);
    defer a.free(u);
    try testing.expect(std.mem.startsWith(u8, u, "file://"));
    for (u["file://".len..]) |c| {
        const ok = std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~/%:", c) != null;
        if (!ok) {
            std.debug.print("URI contains invalid character '{c}': {s}\n", .{ c, u });
            return error.TestUnexpectedResult;
        }
    }
    const back = try uri.toPathStyle(style, a, u);
    defer a.free(back);
    try expectEqualPaths(normalized, back, raw.items);
}

fn expectEqualPaths(expected: []const u8, actual: []const u8, raw: []const u8) !void {
    if (std.mem.eql(u8, expected, actual)) return;
    std.debug.print("path mismatch\n  raw: {s}\n  expected: {s}\n  actual: {s}\n", .{ raw, expected, actual });
    return error.TestUnexpectedResult;
}

/// 性质：任意输入作为 URI 解析都不会崩溃；成功时结果不含 NUL，且再转换一次保持稳定
fn checkArbitraryUri(comptime style: Style, input: []const u8) !void {
    const a = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "file://");
    try buf.appendSlice(a, input);

    const path = uri.toPathStyle(style, a, buf.items) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidUri, error.UnsupportedScheme => return,
    };
    defer a.free(path);
    try testing.expect(std.mem.indexOfScalar(u8, path, 0) == null);

    const u = try uri.fromPathStyle(style, a, path);
    defer a.free(u);
    const path2 = uri.toPathStyle(style, a, u) catch |err| {
        std.debug.print("round trip failed {t}\n  input: {s}\n  path: {s}\n  URI: {s}\n", .{ err, buf.items, path, u });
        return error.TestUnexpectedResult;
    };
    defer a.free(path2);
    try expectEqualPaths(path, path2, buf.items);
}

/// 性质：大小写不敏感模式下，只差 ASCII 大小写的路径是同一个文件，对外保留第一次的写法；
/// 敏感模式下，当且仅当规范化后完全相同才是同一个文件
fn checkCaseProperties(comptime style: Style, e: *Entropy) !void {
    const a = testing.allocator;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(a);
    try genPath(e, &raw, style);
    const variant = try a.dupe(u8, raw.items);
    defer a.free(variant);
    for (variant) |*c| {
        if (std.ascii.isAlphabetic(c.*) and e.below(2) == 0) c.* ^= 0x20;
    }

    inline for (.{ Vfs.CaseMode.insensitive, Vfs.CaseMode.sensitive }) |case| {
        var vfs: Vfs = .initOptions(testing.io, a, .{ .style = style, .case = case });
        defer vfs.deinit();
        const id = try vfs.intern(raw.items);
        const id2 = try vfs.intern(variant);
        const n1 = (try Vfs.normalize(style, a, raw.items)).?;
        defer a.free(n1);
        const n2 = (try Vfs.normalize(style, a, variant)).?;
        defer a.free(n2);
        switch (case) {
            .insensitive => {
                try testing.expectEqual(id, id2);
                try testing.expectEqual(id, (try vfs.lookup(variant)).?);
                try testing.expectEqualStrings(n1, vfs.path(id));
            },
            .sensitive => try testing.expectEqual(std.mem.eql(u8, n1, n2), id == id2),
        }
    }
}

fn checkAll(input: []const u8) !void {
    var e1: Entropy = .{ .bytes = input };
    try checkPathProperties(.posix, &e1);
    var e2: Entropy = .{ .bytes = input };
    try checkPathProperties(.windows, &e2);
    var e3: Entropy = .{ .bytes = input };
    try checkCaseProperties(.posix, &e3);
    var e4: Entropy = .{ .bytes = input };
    try checkCaseProperties(.windows, &e4);
    try checkArbitraryUri(.posix, input);
    try checkArbitraryUri(.windows, input);
}

test "path properties: fixed-seed random input" {
    var prng: std.Random.DefaultPrng = .init(0x5eed_9a7f);
    var buf: [96]u8 = undefined;
    for (0..Entropy.iterations(20_000)) |_| {
        const len = prng.random().uintLessThan(usize, buf.len + 1);
        prng.random().bytes(buf[0..len]);
        try checkAll(buf[0..len]);
    }
}

test "path properties: coverage-guided fuzzing" {
    try testing.fuzz({}, struct {
        fn one(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const len = smith.slice(&buf);
            try checkAll(buf[0..len]);
        }
    }.one, .{ .corpus = &.{ "C:\\a", "/a b/c", "\\\\server\\share", "%3A%2F%00", "///c%3A/x" } });
}

test "Windows drive letter case and separators normalize to the same path" {
    const a = testing.allocator;
    const forms = [_][]const u8{ "c:\\Work\\x.zig", "C:/Work/x.zig", "c:\\Work\\.\\sub\\..\\x.zig", "C:\\\\Work\\x.zig\\" };
    for (forms) |f| {
        const n = (try Vfs.normalize(.windows, a, f)).?;
        defer a.free(n);
        try testing.expectEqualStrings("C:\\Work\\x.zig", n);
    }
    // UNC
    const unc = (try Vfs.normalize(.windows, a, "//server/share/dir/../x.zig")).?;
    defer a.free(unc);
    try testing.expectEqualStrings("\\\\server\\share\\x.zig", unc);
}

test "relative paths are not absolute" {
    try testing.expectEqual(null, try Vfs.normalize(.posix, testing.allocator, "a/b"));
    try testing.expectEqual(null, try Vfs.normalize(.windows, testing.allocator, "a\\b"));
    try testing.expectEqual(null, try Vfs.normalize(.windows, testing.allocator, "C:a\\b"));
}
