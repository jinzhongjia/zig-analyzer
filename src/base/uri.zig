//! Conversion between `file://` URIs and file system paths.
//!
//! Both path styles are implemented as an explicit parameter (`Style`), so the Windows rules can
//! also be tested on any platform:
//!
//! | Path                         | URI                              |
//! |------------------------------|----------------------------------|
//! | `/home/a b/x.zig`            | `file:///home/a%20b/x.zig`       |
//! | `C:\work\x.zig`              | `file:///C:/work/x.zig`          |
//! | `\\server\share\x.zig` (UNC) | `file://server/share/x.zig`      |
//!
//! Parsing accepts VS Code's spellings: lowercase drive letters, the colon encoded as `%3A`, and
//! `file://localhost/`; the local form without an authority, `file:/home/x.zig` (RFC 8089); and
//! on Windows, UNC paths after an empty authority, `file:////server/share/x.zig` and
//! `file://///server/share/x.zig` (RFC 8089 Appendix E.3.2).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Error = error{ UnsupportedScheme, InvalidUri } || Allocator.Error;

pub const Style = enum {
    posix,
    windows,

    pub const native: Style = if (builtin.target.os.tag == .windows) .windows else .posix;
};

pub fn toPath(gpa: Allocator, uri: []const u8) Error![]u8 {
    return toPathStyle(.native, gpa, uri);
}

pub fn fromPath(gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    return fromPathStyle(.native, gpa, path);
}

/// The URI has the `file` scheme: `toPath` fails with `UnsupportedScheme` exactly when it does not
pub fn isFile(uri: []const u8) bool {
    const scheme = "file:";
    return uri.len >= scheme.len and std.ascii.eqlIgnoreCase(uri[0..scheme.len], scheme);
}

pub fn toPathStyle(comptime style: Style, gpa: Allocator, uri: []const u8) Error![]u8 {
    if (!isFile(uri)) return error.UnsupportedScheme;
    var rest = uri["file:".len..];
    if (std.mem.indexOfAny(u8, rest, "?#")) |end| rest = rest[0..end];

    // `file://authority/path`, or the local form `file:/path` without an authority (RFC 8089);
    // an empty authority or localhost means the local machine; on Windows, anything else is
    // treated as a UNC host name
    const authority, const encoded_path = if (std.mem.startsWith(u8, rest, "//")) blk: {
        const slash = std.mem.indexOfScalarPos(u8, rest, 2, '/') orelse rest.len;
        break :blk .{ rest[2..slash], rest[slash..] };
    } else if (std.mem.startsWith(u8, rest, "/")) .{ "", rest } else return error.InvalidUri;
    const is_local = authority.len == 0 or std.ascii.eqlIgnoreCase(authority, "localhost");
    if (!is_local and style == .posix) return error.InvalidUri;
    if (encoded_path.len == 0 and is_local) return error.InvalidUri;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    // On Windows, a UNC path may also follow an empty authority, with its two leading slashes
    // (`file:////host/share/x`) or with one more (`file://///host/share/x`), as RFC 8089
    // Appendix E.3.2 describes; Neovim spells paths that start with `//` this way
    if (style == .windows and authority.len == 0 and std.mem.startsWith(u8, encoded_path, "//")) {
        const unc = if (std.mem.startsWith(u8, encoded_path, "///")) encoded_path[1..] else encoded_path;
        try appendDecoded(gpa, &out, unc);
        for (out.items) |*c| {
            if (c.* == '/') c.* = '\\';
        }
        // The host name must not be empty
        if (out.items.len == 2 or out.items[2] == '\\') return error.InvalidUri;
        return out.toOwnedSlice(gpa);
    }
    if (!is_local) {
        try out.appendSlice(gpa, "\\\\");
        try appendDecoded(gpa, &out, authority);
        // The host name must not be empty or contain path separators
        const host = out.items[2..];
        if (host.len == 0 or std.mem.indexOfAny(u8, host, "\\/") != null) return error.InvalidUri;
    }
    const path_start = out.items.len;
    try appendDecoded(gpa, &out, encoded_path);

    if (style == .windows) {
        for (out.items[path_start..]) |*c| {
            if (c.* == '/') c.* = '\\';
        }
        if (is_local) {
            // `\c:\x` → `C:\x`
            const p = out.items;
            if (p.len >= 3 and p[0] == '\\' and std.ascii.isAlphabetic(p[1]) and p[2] == ':' and (p.len == 3 or p[3] == '\\')) {
                _ = out.orderedRemove(0);
                out.items[0] = std.ascii.toUpper(out.items[0]);
                if (out.items.len == 2) try out.append(gpa, '\\');
            } else return error.InvalidUri; // a local Windows path must have a drive letter
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Percent-decodes; rejects raw control characters, decoded NUL bytes, and invalid escape
/// sequences
fn appendDecoded(gpa: Allocator, out: *std.ArrayList(u8), encoded: []const u8) Error!void {
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        const c = encoded[i];
        if (std.ascii.isControl(c)) return error.InvalidUri;
        if (c != '%') {
            try out.append(gpa, c);
            continue;
        }
        if (i + 2 >= encoded.len) return error.InvalidUri;
        const byte = std.fmt.parseInt(u8, encoded[i + 1 .. i + 3], 16) catch return error.InvalidUri;
        if (byte == 0) return error.InvalidUri;
        try out.append(gpa, byte);
        i += 2;
    }
}

pub fn fromPathStyle(comptime style: Style, gpa: Allocator, path: []const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    write: {
        w.writeAll("file://") catch break :write;
        var rest = path;
        if (style == .windows) {
            if (std.mem.startsWith(u8, path, "\\\\") or std.mem.startsWith(u8, path, "//")) {
                // UNC: `\\server\share\x` → `file://server/share/x`
                rest = path[2..];
                const end = std.mem.indexOfAny(u8, rest, "\\/") orelse rest.len;
                encode(w, style, rest[0..end]) catch break :write;
                rest = rest[end..];
            } else if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') {
                w.writeByte('/') catch break :write;
                w.writeByte(std.ascii.toUpper(path[0])) catch break :write;
                w.writeByte(':') catch break :write;
                rest = path[2..];
            }
        }
        encode(w, style, rest) catch break :write;
        return out.toOwnedSlice();
    }
    return error.OutOfMemory;
}

fn encode(w: *std.Io.Writer, comptime style: Style, raw: []const u8) std.Io.Writer.Error!void {
    for (raw) |c| {
        const ch = if (style == .windows and c == '\\') '/' else c;
        if (isUnreserved(ch) or ch == '/') {
            try w.writeByte(ch);
        } else {
            try w.print("%{X:0>2}", .{ch});
        }
    }
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

const testing = std.testing;

fn expectToPath(comptime style: Style, uri: []const u8, expected: []const u8) !void {
    const path = try toPathStyle(style, testing.allocator, uri);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings(expected, path);
}

fn expectFromPath(comptime style: Style, path: []const u8, expected: []const u8) !void {
    const uri = try fromPathStyle(style, testing.allocator, path);
    defer testing.allocator.free(uri);
    try testing.expectEqualStrings(expected, uri);
}

test "posix" {
    try expectFromPath(.posix, "/home/u/my project/a+b.zig", "file:///home/u/my%20project/a%2Bb.zig");
    try expectToPath(.posix, "file:///home/u/my%20project/a%2Bb.zig", "/home/u/my project/a+b.zig");
    try expectToPath(.posix, "file://localhost/tmp/x.zig", "/tmp/x.zig");
    try expectToPath(.posix, "FILE:///tmp/x.zig?query#frag", "/tmp/x.zig");
    try expectToPath(.posix, "file:///tmp/%E2%82%AC.zig", "/tmp/€.zig");
    try testing.expectError(error.InvalidUri, toPathStyle(.posix, testing.allocator, "file://server/share/x"));
}

test "windows drive letters" {
    try expectFromPath(.windows, "C:\\work\\x y.zig", "file:///C:/work/x%20y.zig");
    try expectFromPath(.windows, "c:\\work", "file:///C:/work");
    // VS Code: lowercase drive letter, encoded colon
    try expectToPath(.windows, "file:///c%3A/work/x%20y.zig", "C:\\work\\x y.zig");
    try expectToPath(.windows, "file:///C:/work/x.zig", "C:\\work\\x.zig");
    try expectToPath(.windows, "file:///d:", "D:\\");
    try testing.expectError(error.InvalidUri, toPathStyle(.windows, testing.allocator, "file:///work/x.zig"));
}

test "windows UNC" {
    try expectFromPath(.windows, "\\\\server\\share\\a b.zig", "file://server/share/a%20b.zig");
    try expectToPath(.windows, "file://server/share/a%20b.zig", "\\\\server\\share\\a b.zig");
}

test "windows UNC after an empty authority (RFC 8089 Appendix E.3.2)" {
    try expectToPath(.windows, "file:////server/share/a%20b.zig", "\\\\server\\share\\a b.zig");
    try expectToPath(.windows, "file://///server/share/a%20b.zig", "\\\\server\\share\\a b.zig");
    try expectToPath(.windows, "file:////wsl.localhost/Ubuntu/home/u/x.zig", "\\\\wsl.localhost\\Ubuntu\\home\\u\\x.zig");
    for ([_][]const u8{ "file:////", "file://///", "file://////server/share/x.zig", "file:////%2Fserver/share" }) |bad| {
        try testing.expectError(error.InvalidUri, toPathStyle(.windows, testing.allocator, bad));
    }
    // A POSIX path may start with two slashes
    try expectToPath(.posix, "file:////server/share/x.zig", "//server/share/x.zig");
}

test "local form without an authority (RFC 8089 file:/path)" {
    try expectToPath(.posix, "file:/tmp/x.zig", "/tmp/x.zig");
    try expectToPath(.posix, "File:/home/a%20b/x.zig?q", "/home/a b/x.zig");
    try expectToPath(.windows, "file:/C:/x.zig", "C:\\x.zig");
    try expectToPath(.windows, "file:/c%3A/work/x.zig", "C:\\work\\x.zig");
    try testing.expectError(error.InvalidUri, toPathStyle(.posix, testing.allocator, "file:tmp/x.zig"));
    try testing.expectError(error.InvalidUri, toPathStyle(.windows, testing.allocator, "file:/work/x.zig"));
}

test "invalid URI" {
    const bad = [_][]const u8{ "untitled:Untitled-1", "file:", "file://", "file:///a%zz", "file:///a%2", "file:///a%00b", "file:///a\x00b", "file:///a\nb" };
    for (bad) |b| {
        try testing.expect(std.meta.isError(toPathStyle(.posix, testing.allocator, b)));
        try testing.expect(std.meta.isError(toPathStyle(.windows, testing.allocator, b)));
    }
}

test {
    _ = @import("path_fuzz.zig");
}
