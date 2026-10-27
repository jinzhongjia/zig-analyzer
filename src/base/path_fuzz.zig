//! Property tests for paths and URIs; two drivers share the same set of properties:
//!
//! - A pseudo-random loop with a fixed seed: runs on every platform in every `zig build test`;
//! - `std.testing.fuzz`: driven by coverage-guided fuzzing with `zig build test --fuzz=<count>`.
//!
//! Both path styles are tested on every platform, so problems with the Windows rules do not
//! have to wait for a Windows machine to surface.

const std = @import("std");
const testing = std.testing;
const uri = @import("uri.zig");
const Style = uri.Style;
const Vfs = @import("Vfs.zig");
const Entropy = @import("../util/Entropy.zig");

/// Characters in file names: ordinary characters, special characters that URIs must encode,
/// and multi-byte UTF-8
const name_pieces = [_][]const u8{
    "a", "Z",   "0",   "_",    "-", ".", " ", "%", "#", "?", "+", "&", "=", "@", "!", "~", ",",
    ";", "'",   "(",   ")",    "[", "]", "{", "}", "$",
    "中",
    "é",
    "😀",
    ":", "%20", "%3A", "file",
};

fn genComponent(e: *Entropy, out: *std.ArrayList(u8), comptime style: Style) !void {
    // Occasionally generate `.`, `..`, and empty components, left for normalization to handle
    switch (e.below(10)) {
        0 => return out.appendSlice(testing.allocator, "."),
        1 => return out.appendSlice(testing.allocator, ".."),
        2 => return,
        else => {},
    }
    const n = 1 + e.below(6);
    for (0..n) |_| {
        const piece = e.pick([]const u8, &name_pieces);
        // On Windows, `:` appears only in drive letters (NTFS alternate data streams are
        // out of scope)
        if (style == .windows and std.mem.eql(u8, piece, ":")) continue;
        try out.appendSlice(testing.allocator, piece);
    }
}

/// Generates an absolute path (not necessarily normalized)
fn genPath(e: *Entropy, out: *std.ArrayList(u8), comptime style: Style) !void {
    const a = testing.allocator;
    switch (style) {
        .posix => try out.append(a, '/'),
        .windows => if (e.below(4) == 0) {
            // UNC: \\server\share\
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
            if (e.below(8) == 0) try out.append(a, if (style == .windows) '\\' else '/'); // duplicate separator
        }
        try genComponent(e, out, style);
    }
    if (e.below(6) == 0) try out.append(a, if (style == .windows) '\\' else '/'); // trailing separator
}

/// Properties: normalization is idempotent; URIs round-trip; generated URIs contain
/// only valid characters
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

/// Property: parsing any input as a URI never crashes; on success the result contains no NUL,
/// and converting it again is stable
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

/// Properties: in case-insensitive mode, paths that differ only in ASCII case are the same file,
/// and the spelling seen first is kept externally;
/// in case-sensitive mode, paths are the same file if and only if they are identical after
/// normalization
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
