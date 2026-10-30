//! Virtual file system: an interning table of paths ↔ `FileId`. File contents are stored in the
//! query engine as `FileText` inputs.
//!
//! File identity is determined by the "normalized path"; on case-insensitive file systems (the
//! default on Windows and macOS), the identity key also folds the case of ASCII letters, so that
//! `C:\Work\A.zig` and `c:/work/a.zig` map to the same FileId.
//! Externally (display, building URIs), the path as first seen is used.
//!
//! Known limitation: only the case of ASCII letters (A-Z) is folded. When a path contains
//! non-ASCII letters, spellings that the file system treats as the same file but that differ in
//! bytes map to different FileIds:
//! - Case of non-ASCII letters: `Été.zig` and `été.zig` (neither NTFS nor APFS distinguishes them);
//! - The composed and decomposed Unicode forms on APFS: `é` can be U+00E9 or `e` + U+0301 (APFS
//!   does not distinguish them).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Vfs = @This();
const Style = @import("uri.zig").Style;

pub const FileId = enum(u32) {
    _,

    pub fn index(id: FileId) u32 {
        return @backingInt(id);
    }
};

pub const CaseMode = enum {
    sensitive,
    insensitive,

    /// The default file systems of Windows and macOS are case-insensitive
    pub const native: CaseMode = switch (@import("builtin").target.os.tag) {
        .windows, .macos, .ios => .insensitive,
        else => .sensitive,
    };
};

gpa: Allocator,
io: Io,
style: Style,
case: CaseMode,
/// The same file may be interned by import resolution in read transactions, so a lock is needed
mutex: Io.Mutex = .init,
/// Identity keys (normalized paths, additionally lowercased when case-insensitive); the index
/// is the FileId
keys: std.StringArrayHashMapUnmanaged(void) = .empty,
/// One-to-one with `keys`: the normalized path as first seen (original case preserved)
paths: std.ArrayList([]const u8) = .empty,
/// Notified when a new path is interned (e.g. file watching needs to watch the directories of
/// newly appearing files); called outside the lock, on the thread that interned the path
listener: std.atomic.Value(?*const Listener) = .init(null),

pub const Listener = struct {
    ctx: *anyopaque,
    /// Must be a thread-safe, lightweight operation: called whenever any thread interns a new path
    notify: *const fn (ctx: *anyopaque) void,
};

pub const Options = struct {
    style: Style = .native,
    case: CaseMode = .native,
};

pub fn init(io: Io, gpa: Allocator) Vfs {
    return initOptions(io, gpa, .{});
}

/// Specifies the path style and case mode (used in tests to cover both rule sets on any platform)
pub fn initOptions(io: Io, gpa: Allocator, options: Options) Vfs {
    return .{ .io = io, .gpa = gpa, .style = options.style, .case = options.case };
}

fn normalizeOwn(vfs: *const Vfs, file_path: []const u8) Allocator.Error!?[]u8 {
    return switch (vfs.style) {
        inline else => |style| normalize(style, vfs.gpa, file_path),
    };
}

pub fn deinit(vfs: *Vfs) void {
    for (vfs.keys.keys()) |k| vfs.gpa.free(k);
    for (vfs.paths.items) |p| vfs.gpa.free(p);
    vfs.keys.deinit(vfs.gpa);
    vfs.paths.deinit(vfs.gpa);
    vfs.* = undefined;
}

pub fn count(vfs: *Vfs) usize {
    vfs.mutex.lockUncancelable(vfs.io);
    defer vfs.mutex.unlock(vfs.io);
    return vfs.keys.count();
}

/// Derives the identity key from a normalized path (the caller owns the returned value)
fn identityKey(vfs: *const Vfs, normalized: []const u8) Allocator.Error![]u8 {
    const key = try vfs.gpa.dupe(u8, normalized);
    if (vfs.case == .insensitive) _ = std.ascii.lowerString(key, key);
    return key;
}

/// Normalizes an absolute path: removes `.`, `..`, and duplicate and trailing separators; on
/// Windows, uses backslashes throughout and uppercases the drive letter.
/// Returns null when the path is not absolute. Both styles can be called on any platform, which
/// makes testing easier.
pub fn normalize(comptime style: Style, gpa: Allocator, file_path: []const u8) Allocator.Error!?[]u8 {
    return switch (style) {
        .posix => if (std.fs.path.isAbsolutePosix(file_path)) try std.fs.path.resolveAllocPosix(gpa, &.{file_path}) else null,
        .windows => if (std.fs.path.isAbsoluteWindows(file_path)) try std.fs.path.resolveAllocWindows(gpa, &.{file_path}) else null,
    };
}

/// Resolves `sub_path` against the absolute path `base` following the rules of
/// `std.fs.path.resolve`. Returns null when the result is not absolute: on Windows, a path
/// relative to another drive (e.g. `D:a.zig`) is still relative after resolution. A non-null
/// result can be passed to `intern`.
/// Both styles can be called on any platform, which makes testing easier.
pub fn resolve(comptime style: Style, gpa: Allocator, base: []const u8, sub_path: []const u8) Allocator.Error!?[]u8 {
    const isAbsolute, const resolveAlloc = switch (style) {
        .posix => .{ std.fs.path.isAbsolutePosix, std.fs.path.resolveAllocPosix },
        .windows => .{ std.fs.path.isAbsoluteWindows, std.fs.path.resolveAllocWindows },
    };
    const resolved = try resolveAlloc(gpa, &.{ base, sub_path });
    if (isAbsolute(resolved)) return resolved;
    gpa.free(resolved);
    return null;
}

/// Whether `file_path` is the directory `dir` itself or lies under it (both are normalized
/// absolute paths). Consistent with the file identity rules: when case-insensitive, the case of
/// ASCII letters is ignored
pub fn isUnder(vfs: *const Vfs, file_path: []const u8, dir: []const u8) bool {
    return switch (vfs.style) {
        inline else => |style| isUnderStyle(style, vfs.case, file_path, dir),
    };
}

/// Same as `isUnder`, with the path style and case rule given explicitly, for testing
pub fn isUnderStyle(comptime style: Style, case: CaseMode, file_path: []const u8, dir: []const u8) bool {
    if (file_path.len < dir.len) return false;
    const prefix = file_path[0..dir.len];
    const same = switch (case) {
        .sensitive => std.mem.eql(u8, prefix, dir),
        .insensitive => std.ascii.eqlIgnoreCase(prefix, dir),
    };
    if (!same) return false;
    const path_type: std.fs.path.PathType = switch (style) {
        .posix => .posix,
        .windows => .windows,
    };
    if (file_path.len == dir.len) return true;
    return path_type.isSep(u8, file_path[dir.len]) or (dir.len > 0 and path_type.isSep(u8, dir[dir.len - 1]));
}

/// Whether the normalized absolute paths `x` and `y` name the same file or directory, under the
/// same rules as `isUnder`
pub fn samePath(vfs: *const Vfs, x: []const u8, y: []const u8) bool {
    return x.len == y.len and vfs.isUnder(x, y);
}

/// The innermost of the directories `roots` that contains `file_path` (see `isUnder`); null when
/// none does
pub fn rootOf(vfs: *const Vfs, roots: []const []const u8, file_path: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (roots) |root| {
        if (vfs.isUnder(file_path, root) and (best == null or root.len > best.?.len)) best = root;
    }
    return best;
}

/// `file_path` as shown to the user: relative to the innermost of the workspace folders `roots`
/// that contains it, otherwise the absolute path
pub fn shownPath(vfs: *const Vfs, roots: []const []const u8, file_path: []const u8) []const u8 {
    const root = vfs.rootOf(roots, file_path) orelse return file_path;
    return std.mem.trimStart(u8, file_path[root.len..], "/\\");
}

/// Interns a path. The caller must ensure that `file_path` is absolute; the path is normalized
/// (see `normalize`).
pub fn intern(vfs: *Vfs, file_path: []const u8) Allocator.Error!FileId {
    const normalized = try vfs.normalizeOwn(file_path) orelse unreachable;
    errdefer vfs.gpa.free(normalized);
    const key = try vfs.identityKey(normalized);
    errdefer vfs.gpa.free(key);

    const index, const added = blk: {
        vfs.mutex.lockUncancelable(vfs.io);
        defer vfs.mutex.unlock(vfs.io);
        try vfs.paths.ensureUnusedCapacity(vfs.gpa, 1);
        const gop = try vfs.keys.getOrPut(vfs.gpa, key);
        if (gop.found_existing) {
            vfs.gpa.free(key);
            vfs.gpa.free(normalized);
        } else {
            vfs.paths.appendAssumeCapacity(normalized);
        }
        break :blk .{ gop.index, !gop.found_existing };
    };
    if (added) if (vfs.listener.load(.acquire)) |l| l.notify(l.ctx);
    return @fromBackingInt(@intCast(index));
}

pub fn lookup(vfs: *Vfs, file_path: []const u8) Allocator.Error!?FileId {
    const normalized = try vfs.normalizeOwn(file_path) orelse return null;
    defer vfs.gpa.free(normalized);
    const key = try vfs.identityKey(normalized);
    defer vfs.gpa.free(key);
    vfs.mutex.lockUncancelable(vfs.io);
    defer vfs.mutex.unlock(vfs.io);
    return if (vfs.keys.getIndex(key)) |i| @fromBackingInt(@intCast(i)) else null;
}

/// The returned slice is valid for the lifetime of the Vfs.
pub fn path(vfs: *Vfs, id: FileId) []const u8 {
    vfs.mutex.lockUncancelable(vfs.io);
    defer vfs.mutex.unlock(vfs.io);
    return vfs.paths.items[id.index()];
}

pub const ReadError = error{ Canceled, OutOfMemory, FileTooBig };

/// Reads the file from disk; returns null when the file does not exist or is unreadable.
pub fn readFromDisk(vfs: *Vfs, id: FileId, gpa: Allocator) ReadError!?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(vfs.io, vfs.path(id), gpa, .limited(max_file_size)) catch |err| switch (err) {
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.FileTooBig,
        else => null,
    };
}

/// Files larger than this are not loaded: source positions are represented as u32
pub const max_file_size = std.math.maxInt(u32);

test "interning and normalization" {
    var vfs: Vfs = .init(std.testing.io, std.testing.allocator);
    defer vfs.deinit();
    const root = if (@import("builtin").target.os.tag == .windows) "C:\\" else "/";
    const a = try std.fs.path.join(std.testing.allocator, &.{ root, "x", "y", "..", "a.zig" });
    defer std.testing.allocator.free(a);
    const b = try std.fs.path.join(std.testing.allocator, &.{ root, "x", ".", "a.zig" });
    defer std.testing.allocator.free(b);

    const id_a = try vfs.intern(a);
    const id_b = try vfs.intern(b);
    try std.testing.expectEqual(id_a, id_b);
    try std.testing.expectEqual(id_a, (try vfs.lookup(b)).?);
    try std.testing.expect(std.mem.endsWith(u8, vfs.path(id_a), "a.zig"));
}

test "case-insensitive: spellings map to one file, first spelling is kept for display" {
    const t = std.testing;
    inline for (.{ Style.posix, Style.windows }) |style| {
        var vfs: Vfs = .initOptions(t.io, t.allocator, .{ .style = style, .case = .insensitive });
        defer vfs.deinit();
        const first, const other, const different = switch (style) {
            .posix => .{ "/Work/Src/A.zig", "/work/src/a.ZIG", "/work/src/b.zig" },
            .windows => .{ "C:\\Work\\Src\\A.zig", "c:/work/SRC/a.zig", "C:\\work\\src\\b.zig" },
        };
        const id = try vfs.intern(first);
        try t.expectEqual(id, try vfs.intern(other));
        try t.expectEqual(id, (try vfs.lookup(other)).?);
        try t.expect(id != try vfs.intern(different));
        const expected = if (style == .posix) "/Work/Src/A.zig" else "C:\\Work\\Src\\A.zig";
        try t.expectEqualStrings(expected, vfs.path(id));
    }
}

test isUnderStyle {
    const t = std.testing;
    try t.expect(isUnderStyle(.posix, .sensitive, "/work/src/a.zig", "/work"));
    try t.expect(isUnderStyle(.posix, .sensitive, "/work", "/work"));
    try t.expect(isUnderStyle(.posix, .sensitive, "/work/a.zig", "/"));
    // The directory names only share a prefix
    try t.expect(!isUnderStyle(.posix, .sensitive, "/workspace/a.zig", "/work"));
    try t.expect(!isUnderStyle(.posix, .sensitive, "/Work/a.zig", "/work"));
    try t.expect(isUnderStyle(.posix, .insensitive, "/Work/a.zig", "/work"));
    try t.expect(isUnderStyle(.windows, .insensitive, "C:\\Zig\\Lib\\std\\std.zig", "C:\\zig\\lib"));
    try t.expect(isUnderStyle(.windows, .insensitive, "C:\\a.zig", "C:\\"));
    try t.expect(!isUnderStyle(.windows, .insensitive, "C:\\zig\\library\\a.zig", "C:\\zig\\lib"));
}

test "listener: notified once per new path" {
    const t = std.testing;
    var vfs: Vfs = .init(t.io, t.allocator);
    defer vfs.deinit();
    var notified: usize = 0;
    const listener: Listener = .{ .ctx = &notified, .notify = struct {
        fn notify(ctx: *anyopaque) void {
            const n: *usize = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    }.notify };
    vfs.listener.store(&listener, .release);
    const root = if (@import("builtin").target.os.tag == .windows) "C:\\" else "/";
    const a = try std.fs.path.join(t.allocator, &.{ root, "a.zig" });
    defer t.allocator.free(a);
    const b = try std.fs.path.join(t.allocator, &.{ root, "b.zig" });
    defer t.allocator.free(b);
    _ = try vfs.intern(a);
    _ = try vfs.intern(a);
    _ = try vfs.intern(b);
    try t.expectEqual(2, notified);
}

test "case-sensitive: different spellings are different files" {
    const t = std.testing;
    var vfs: Vfs = .initOptions(t.io, t.allocator, .{ .style = .posix, .case = .sensitive });
    defer vfs.deinit();
    try t.expect(try vfs.intern("/a/B.zig") != try vfs.intern("/a/b.zig"));
    try t.expectEqual(null, try vfs.lookup("/A/b.zig"));
}

test "resolve: results that are not absolute paths are rejected" {
    const t = std.testing;
    const Case = struct { base: []const u8, sub_path: []const u8, expected: ?[]const u8 };
    const posix = [_]Case{
        .{ .base = "/proj", .sub_path = "src/../a.zig", .expected = "/proj/a.zig" },
        .{ .base = "/proj", .sub_path = "/other/b.zig", .expected = "/other/b.zig" },
        .{ .base = "/proj", .sub_path = "x: u32 = 1;", .expected = "/proj/x: u32 = 1;" },
    };
    const windows = [_]Case{
        .{ .base = "C:\\proj", .sub_path = "src/../a.zig", .expected = "C:\\proj\\a.zig" },
        .{ .base = "C:\\proj", .sub_path = "D:\\other\\b.zig", .expected = "D:\\other\\b.zig" },
        .{ .base = "C:\\proj", .sub_path = "\\\\server\\share\\c.zig", .expected = "\\\\server\\share\\c.zig" },
        .{ .base = "C:\\proj", .sub_path = "C:a.zig", .expected = "C:\\proj\\a.zig" },
        // Paths relative to another drive: when the error bundle format does not match, a path
        // index may point into the middle of a source line, at `x: u32 = 1;`
        .{ .base = "C:\\proj", .sub_path = "x: u32 = 1;", .expected = null },
        .{ .base = "C:\\proj", .sub_path = "D:a.zig", .expected = null },
        .{ .base = "C:\\proj", .sub_path = "::", .expected = null },
    };
    inline for (.{ Style.posix, Style.windows }, .{ &posix, &windows }) |style, cases| {
        var vfs: Vfs = .initOptions(t.io, t.allocator, .{ .style = style });
        defer vfs.deinit();
        for (cases) |c| {
            const resolved = try resolve(style, t.allocator, c.base, c.sub_path);
            defer if (resolved) |p| t.allocator.free(p);
            if (c.expected) |expected| {
                try t.expectEqualStrings(expected, resolved.?);
                _ = try vfs.intern(resolved.?);
            } else {
                try t.expectEqual(null, resolved);
            }
        }
    }
}

test "samePath follows the case rule of file identity" {
    const native = @import("../util/test_path.zig").native;
    var insensitive: Vfs = .initOptions(std.testing.io, std.testing.allocator, .{ .case = .insensitive });
    defer insensitive.deinit();
    var sensitive: Vfs = .initOptions(std.testing.io, std.testing.allocator, .{ .case = .sensitive });
    defer sensitive.deinit();
    try std.testing.expect(insensitive.samePath(native("/w/MyProj"), native("/w/myproj")));
    try std.testing.expect(!sensitive.samePath(native("/w/MyProj"), native("/w/myproj")));
    try std.testing.expect(sensitive.samePath(native("/w/MyProj"), native("/w/MyProj")));
    try std.testing.expect(!insensitive.samePath(native("/w/myproj/src"), native("/w/myproj")));
}
