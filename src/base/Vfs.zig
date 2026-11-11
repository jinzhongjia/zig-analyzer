//! Virtual file system: an interning table of paths ↔ `FileId`. File contents are stored in the
//! query engine as `FileText` inputs.
//!
//! File identity is determined by the "normalized path"; on case-insensitive file systems, the
//! identity key also folds the case of ASCII letters, so that `C:\Work\A.zig` and
//! `c:/work/a.zig` map to the same FileId, while on case-sensitive ones the exact bytes count,
//! as they do for the compiler. Windows file systems are case-insensitive; on macOS the rule
//! is asked of each volume, since APFS and HFS+ volumes can be formatted either way (see
//! `CaseRule`); other systems are case-sensitive.
//! Externally (display, building URIs), the path as first seen is used.
//!
//! Identity is lexical: symbolic links are not resolved, and only the case of ASCII letters
//! (A-Z) is folded. Spellings that the file system treats as the same file but that differ in
//! bytes map to different FileIds: a path through a symbolic link and its target; the case of
//! non-ASCII letters (`Été.zig` and `été.zig`, which neither NTFS nor APFS distinguishes); the
//! composed and decomposed Unicode forms on APFS (`é` can be U+00E9 or `e` + U+0301). Where a
//! tool and the client spell one file differently, the server adds the other spelling as an
//! alias of the file it already knows (see `alias`), so both spellings map to one FileId.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

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

    /// The default of the system's file systems (case-insensitive on Windows and macOS), for
    /// comparisons made without a Vfs; file identity asks each volume (see `CaseRule.native`)
    pub const native: CaseMode = switch (builtin.target.os.tag) {
        .windows, .macos, .ios => .insensitive,
        else => .sensitive,
    };
};

/// How the case rule of a path is decided
pub const CaseRule = union(enum) {
    /// Every path follows one rule
    fixed: CaseMode,
    /// Each volume has its own rule, which the function asks of the file system for an
    /// existing file or directory (null when it cannot tell, e.g. when the path does not exist:
    /// the rule of its nearest ancestor that it can tell applies)
    per_volume: *const fn (target: [:0]const u8) ?CaseMode,

    pub const sensitive: CaseRule = .{ .fixed = .sensitive };
    pub const insensitive: CaseRule = .{ .fixed = .insensitive };

    /// Windows file systems are case-insensitive. APFS and HFS+ volumes are case-insensitive by
    /// default but can be formatted case-sensitive, so on macOS each volume is asked.
    pub const native: CaseRule = if (builtin.target.os.tag.isDarwin())
        .{ .per_volume = darwinCase }
    else if (builtin.target.os.tag == .windows) .insensitive else .sensitive;
};

/// `pathconf(_PC_CASE_SENSITIVE)`: 1 on a case-sensitive volume, 0 on a case-insensitive one
fn darwinCase(target: [:0]const u8) ?CaseMode {
    const c = struct {
        extern "c" fn pathconf(target: [*:0]const u8, name: c_int) c_long;
        const _PC_CASE_SENSITIVE = 11;
    };
    return switch (c.pathconf(target.ptr, c._PC_CASE_SENSITIVE)) {
        1 => .sensitive,
        0 => .insensitive,
        else => null,
    };
}

gpa: Allocator,
io: Io,
style: Style,
case: CaseRule,
/// The same file may be interned by import resolution in read transactions, so a lock is needed
mutex: Io.Mutex = .init,
/// Identity keys (normalized paths, additionally lowercased when case-insensitive); the index
/// is the FileId
keys: std.StringArrayHashMapUnmanaged(void) = .empty,
/// One-to-one with `keys`: the normalized path as first seen (original case preserved)
paths: std.ArrayList([]const u8) = .empty,
/// Each entry of `paths` → its FileId. A path spelled exactly as a file was first seen names that
/// file: it normalizes to itself, and its identity key is the file's, since FileIds are never
/// removed and the case rule found for a directory does not change (see `caseOf`). `intern` and
/// `lookup` check it first, which saves normalizing the path and deriving its identity key for
/// the paths that import resolution and the compile set computation pass again and again.
by_path: std.StringHashMapUnmanaged(FileId) = .empty,
/// Other spellings of interned files (see `alias`): identity key → FileId. An alias is kept for
/// the lifetime of the Vfs, as FileIds are.
aliases: std.StringHashMapUnmanaged(FileId) = .empty,
/// Notified when a new path is interned (e.g. file watching needs to watch the directories of
/// newly appearing files); called outside the lock, on the thread that interned the path
listener: std.atomic.Value(?*const Listener) = .init(null),
/// Under `CaseRule.per_volume`: the case rule found for each path asked so far (see `caseOf`);
/// guarded by `case_mutex`
case_cache: std.StringHashMapUnmanaged(CaseMode) = .empty,
case_mutex: Io.Mutex = .init,

pub const Listener = struct {
    ctx: *anyopaque,
    /// Must be a thread-safe, lightweight operation: called whenever any thread interns a new path
    notify: *const fn (ctx: *anyopaque) void,
};

pub const Options = struct {
    style: Style = .native,
    case: CaseRule = .native,
};

pub fn init(io: Io, gpa: Allocator) Vfs {
    return initOptions(io, gpa, .{});
}

/// Specifies the path style and case rule (used in tests to cover both rule sets on any platform)
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
    var aliases = vfs.aliases.keyIterator();
    while (aliases.next()) |k| vfs.gpa.free(k.*);
    vfs.keys.deinit(vfs.gpa);
    vfs.paths.deinit(vfs.gpa);
    vfs.by_path.deinit(vfs.gpa);
    vfs.aliases.deinit(vfs.gpa);
    var cached = vfs.case_cache.keyIterator();
    while (cached.next()) |k| vfs.gpa.free(k.*);
    vfs.case_cache.deinit(vfs.gpa);
    vfs.* = undefined;
}

pub fn count(vfs: *Vfs) usize {
    vfs.mutex.lockUncancelable(vfs.io);
    defer vfs.mutex.unlock(vfs.io);
    return vfs.keys.count();
}

/// Derives the identity key from a normalized path (the caller owns the returned value)
fn identityKey(vfs: *Vfs, normalized: []const u8) Allocator.Error![]u8 {
    const key = try vfs.gpa.dupe(u8, normalized);
    // A path without capital letters is its own key under either rule
    const has_upper = for (normalized) |c| {
        if (std.ascii.isUpper(c)) break true;
    } else false;
    if (has_upper and vfs.caseOfFile(normalized) == .insensitive) _ = std.ascii.lowerString(key, key);
    return key;
}

fn dirname(vfs: *const Vfs, target: []const u8) ?[]const u8 {
    return switch (vfs.style) {
        .posix => std.fs.path.dirnamePosix(target),
        .windows => std.fs.path.dirnameWindows(target),
    };
}

/// The case rule of the volume that holds the file at the normalized absolute path
/// `file_path`: that of its directory, which is asked once for all the files in it
pub fn caseOfFile(vfs: *Vfs, file_path: []const u8) CaseMode {
    return switch (vfs.case) {
        .fixed => |mode| mode,
        .per_volume => vfs.caseOf(vfs.dirname(file_path) orelse file_path),
    };
}

/// The case rule of the volume that holds the normalized absolute path `target` (a directory,
/// or a file)
pub fn caseOf(vfs: *Vfs, target: []const u8) CaseMode {
    const probe = switch (vfs.case) {
        .fixed => |mode| return mode,
        .per_volume => |p| p,
    };
    {
        vfs.case_mutex.lockUncancelable(vfs.io);
        defer vfs.case_mutex.unlock(vfs.io);
        if (vfs.case_cache.get(target)) |mode| return mode;
    }
    // A path that does not exist (or is too long to ask about) is on the volume of its nearest
    // ancestor that can be asked; when none can, the default of APFS (case-insensitive) applies
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    var current: ?[]const u8 = target;
    const mode: CaseMode = while (current) |p| : (current = vfs.dirname(p)) {
        if (p.len >= buf.len) continue;
        @memcpy(buf[0..p.len], p);
        buf[p.len] = 0;
        if (probe(buf[0..p.len :0])) |m| break m;
    } else .insensitive;
    vfs.case_mutex.lockUncancelable(vfs.io);
    defer vfs.case_mutex.unlock(vfs.io);
    const gop = vfs.case_cache.getOrPut(vfs.gpa, target) catch return mode;
    if (!gop.found_existing) gop.key_ptr.* = vfs.gpa.dupe(u8, target) catch {
        vfs.case_cache.removeByPtr(gop.key_ptr);
        return mode;
    };
    gop.value_ptr.* = mode;
    return mode;
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
/// absolute paths). Consistent with the file identity rules: on a case-insensitive volume (that
/// of `dir`), the case of ASCII letters is ignored
pub fn isUnder(vfs: *Vfs, file_path: []const u8, dir: []const u8) bool {
    return switch (vfs.style) {
        inline else => |style| isUnderStyle(style, .insensitive, file_path, dir) and
            (std.mem.startsWith(u8, file_path, dir) or vfs.caseOf(dir) == .insensitive),
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
pub fn samePath(vfs: *Vfs, x: []const u8, y: []const u8) bool {
    return x.len == y.len and vfs.isUnder(x, y);
}

/// The innermost of the directories `roots` that contains `file_path` (see `isUnder`); null when
/// none does
pub fn rootOf(vfs: *Vfs, roots: []const []const u8, file_path: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (roots) |root| {
        if (vfs.isUnder(file_path, root) and (best == null or root.len > best.?.len)) best = root;
    }
    return best;
}

/// `file_path` as shown to the user: relative to the innermost of the workspace folders `roots`
/// that contains it, otherwise the absolute path
pub fn shownPath(vfs: *Vfs, roots: []const []const u8, file_path: []const u8) []const u8 {
    const root = vfs.rootOf(roots, file_path) orelse return file_path;
    return std.mem.trimStart(u8, file_path[root.len..], "/\\");
}

/// Interns a path. The caller must ensure that `file_path` is absolute; the path is normalized
/// (see `normalize`). An alias (see `alias`) maps to the file it was added for.
pub fn intern(vfs: *Vfs, file_path: []const u8) Allocator.Error!FileId {
    if (vfs.firstSeen(file_path)) |id| return id;
    const normalized = try vfs.normalizeOwn(file_path) orelse unreachable;
    errdefer vfs.gpa.free(normalized);
    const key = try vfs.identityKey(normalized);
    errdefer vfs.gpa.free(key);

    const index, const added = blk: {
        vfs.mutex.lockUncancelable(vfs.io);
        defer vfs.mutex.unlock(vfs.io);
        try vfs.paths.ensureUnusedCapacity(vfs.gpa, 1);
        try vfs.by_path.ensureUnusedCapacity(vfs.gpa, 1);
        if (vfs.aliases.count() != 0 and !vfs.keys.contains(key)) if (vfs.aliases.get(key)) |id| {
            vfs.gpa.free(key);
            vfs.gpa.free(normalized);
            return id;
        };
        const gop = try vfs.keys.getOrPut(vfs.gpa, key);
        if (gop.found_existing) {
            vfs.gpa.free(key);
            vfs.gpa.free(normalized);
        } else {
            vfs.paths.appendAssumeCapacity(normalized);
            const entry = vfs.by_path.getOrPutAssumeCapacity(normalized);
            if (!entry.found_existing) entry.value_ptr.* = @fromBackingInt(@intCast(gop.index));
        }
        break :blk .{ gop.index, !gop.found_existing };
    };
    if (added) if (vfs.listener.load(.acquire)) |l| l.notify(l.ctx);
    return @fromBackingInt(@intCast(index));
}

pub fn lookup(vfs: *Vfs, file_path: []const u8) Allocator.Error!?FileId {
    if (vfs.firstSeen(file_path)) |id| return id;
    const normalized = try vfs.normalizeOwn(file_path) orelse return null;
    defer vfs.gpa.free(normalized);
    const key = try vfs.identityKey(normalized);
    defer vfs.gpa.free(key);
    vfs.mutex.lockUncancelable(vfs.io);
    defer vfs.mutex.unlock(vfs.io);
    if (vfs.keys.getIndex(key)) |i| return @fromBackingInt(@intCast(i));
    return vfs.aliases.get(key);
}

/// The file first seen spelled exactly as `file_path` (see `by_path`)
fn firstSeen(vfs: *Vfs, file_path: []const u8) ?FileId {
    vfs.mutex.lockUncancelable(vfs.io);
    defer vfs.mutex.unlock(vfs.io);
    return vfs.by_path.get(file_path);
}

/// Makes the absolute path `file_path` another spelling of `id`: `intern` and `lookup` return
/// `id` for it from now on, while `path(id)` stays the spelling `id` was interned with. Used
/// when a tool and the client spell one file differently (see `realPath`). Nothing changes
/// when `file_path` is already interned or an alias.
pub fn alias(vfs: *Vfs, file_path: []const u8, id: FileId) Allocator.Error!void {
    const normalized = try vfs.normalizeOwn(file_path) orelse return;
    defer vfs.gpa.free(normalized);
    const key = try vfs.identityKey(normalized);
    vfs.mutex.lockUncancelable(vfs.io);
    defer vfs.mutex.unlock(vfs.io);
    if (vfs.keys.contains(key)) return vfs.gpa.free(key);
    const gop = vfs.aliases.getOrPut(vfs.gpa, key) catch |err| {
        vfs.gpa.free(key);
        return err;
    };
    if (gop.found_existing) return vfs.gpa.free(key);
    gop.value_ptr.* = id;
}

/// The path of the existing file `file_path` with symbolic links resolved and names spelled as
/// the file system stores them (on macOS, the Unicode form and case of the names on disk); two
/// spellings name the same file when their real paths are equal. Null when the file cannot be
/// reached.
pub fn realPath(io: Io, gpa: Allocator, file_path: []const u8) Allocator.Error!?[:0]u8 {
    return Io.Dir.cwd().realPathFileAlloc(io, file_path, gpa) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
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

test "alias: another spelling maps to the interned file, which keeps its own path" {
    const t = std.testing;
    var vfs: Vfs = .initOptions(t.io, t.allocator, .{ .style = .posix, .case = .insensitive });
    defer vfs.deinit();
    const id = try vfs.intern("/cellar/zig/lib/std/mem.zig");
    const other = try vfs.intern("/other.zig");
    try vfs.alias("/opt/lib/zig/std/./mem.zig", id);
    try t.expectEqual(id, (try vfs.lookup("/opt/lib/zig/std/mem.zig")).?);
    try t.expectEqual(id, (try vfs.lookup("/OPT/lib/zig/std/mem.zig")).?);
    try t.expectEqual(id, try vfs.intern("/opt/lib/zig/std/mem.zig"));
    try t.expectEqualStrings("/cellar/zig/lib/std/mem.zig", vfs.path(id));
    try t.expectEqual(2, vfs.count());
    // An interned path or an existing alias is not redirected
    try vfs.alias("/other.zig", id);
    try t.expectEqual(other, (try vfs.lookup("/other.zig")).?);
    try vfs.alias("/opt/lib/zig/std/mem.zig", other);
    try t.expectEqual(id, (try vfs.lookup("/opt/lib/zig/std/mem.zig")).?);
}

test "case-sensitive: different spellings are different files" {
    const t = std.testing;
    var vfs: Vfs = .initOptions(t.io, t.allocator, .{ .style = .posix, .case = .sensitive });
    defer vfs.deinit();
    try t.expect(try vfs.intern("/a/B.zig") != try vfs.intern("/a/b.zig"));
    try t.expectEqual(null, try vfs.lookup("/A/b.zig"));
}

test "the spelling a file was first seen with maps to that file under every rule" {
    const t = std.testing;
    const Volumes = struct {
        fn probe(target: [:0]const u8) ?CaseMode {
            return if (std.mem.startsWith(u8, target, "/cs")) .sensitive else .insensitive;
        }
    };
    inline for (.{
        Options{ .style = .posix, .case = .{ .fixed = .sensitive } },
        Options{ .style = .posix, .case = .{ .fixed = .insensitive } },
        Options{ .style = .posix, .case = .{ .per_volume = Volumes.probe } },
        Options{ .style = .windows, .case = .{ .fixed = .insensitive } },
    }) |options| {
        var vfs: Vfs = .initOptions(t.io, t.allocator, options);
        defer vfs.deinit();
        const spellings: []const []const u8 = switch (options.style) {
            .posix => &.{ "/Work/Src/A.zig", "/work/src/a.zig", "/Work/./Src/../Src/A.zig", "/cs/Parser.zig", "/cs/parser.zig", "/work/b.zig" },
            .windows => &.{ "c:/Work/Src/A.zig", "C:\\work\\src\\a.zig", "C:\\Work\\Src\\B.zig" },
        };
        var ids: [6]FileId = undefined;
        for (spellings, 0..) |s, i| ids[i] = try vfs.intern(s);
        const files = vfs.count();
        for (spellings, 0..) |s, i| {
            const stored = vfs.path(ids[i]);
            try t.expectEqual(ids[i], try vfs.intern(stored));
            try t.expectEqual(ids[i], (try vfs.lookup(stored)).?);
            try t.expectEqual(ids[i], try vfs.intern(s));
        }
        try t.expectEqual(files, vfs.count());
    }
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

test "per-volume case rule: names differing in case are one file only on case-insensitive volumes" {
    // `/cs` is a case-sensitive volume (such as a case-sensitive APFS volume on macOS) mounted
    // on a case-insensitive one, where `Parser.zig` and `parser.zig` are different files, as the
    // compiler sees them
    const t = std.testing;
    const Volumes = struct {
        var asked: std.ArrayList([]const u8) = .empty;

        fn probe(target: [:0]const u8) ?CaseMode {
            asked.append(t.allocator, t.allocator.dupe(u8, target) catch unreachable) catch unreachable;
            // Only these directories exist
            for ([_][]const u8{ "/", "/cs", "/cs/src", "/home", "/home/src" }) |dir| {
                if (!std.mem.eql(u8, target, dir)) continue;
                return if (std.mem.startsWith(u8, target, "/cs")) .sensitive else .insensitive;
            }
            return null;
        }
    };
    defer {
        for (Volumes.asked.items) |p| t.allocator.free(p);
        Volumes.asked.deinit(t.allocator);
    }
    var vfs: Vfs = .initOptions(t.io, t.allocator, .{ .style = .posix, .case = .{ .per_volume = Volumes.probe } });
    defer vfs.deinit();

    // Both orders of interning
    const upper = try vfs.intern("/cs/src/Parser.zig");
    const lower = try vfs.intern("/cs/src/parser.zig");
    try t.expect(upper != lower);
    try t.expectEqual(lower, (try vfs.lookup("/cs/src/parser.zig")).?);
    try t.expectEqual(upper, (try vfs.lookup("/cs/src/Parser.zig")).?);
    try t.expectEqualStrings("/cs/src/Parser.zig", vfs.path(upper));
    const lower2 = try vfs.intern("/home/src/parser.zig");
    try t.expectEqual(lower2, try vfs.intern("/home/src/Parser.zig"));
    // A directory that does not exist is on the volume of its nearest existing ancestor
    try t.expect(try vfs.intern("/cs/new/A.zig") != try vfs.intern("/cs/new/a.zig"));
    try t.expectEqual(try vfs.intern("/home/new/A.zig"), try vfs.intern("/home/new/a.zig"));
    // Directory comparisons follow the volume of the directory
    try t.expect(!vfs.isUnder("/cs/Src/a.zig", "/cs/src"));
    try t.expect(vfs.isUnder("/home/Src/a.zig", "/home/src"));
    try t.expect(!vfs.samePath("/cs/SRC", "/cs/src"));
    try t.expect(vfs.samePath("/home/SRC", "/home/src"));
    // Each directory is asked once
    const asked = Volumes.asked.items.len;
    _ = try vfs.intern("/cs/src/Lexer.zig");
    _ = try vfs.lookup("/home/src/Lexer.zig");
    try t.expectEqual(asked, Volumes.asked.items.len);
}

test "native case rule agrees with the file system of the temporary directory" {
    // On macOS, a case-sensitive volume keeps `Parser.zig` and `parser.zig` apart
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "Parser.zig", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const upper = try std.fs.path.join(t.allocator, &.{ root, "Parser.zig" });
    defer t.allocator.free(upper);
    const lower = try std.fs.path.join(t.allocator, &.{ root, "parser.zig" });
    defer t.allocator.free(lower);
    const same_on_disk = if (tmp.dir.access(t.io, "parser.zig", .{})) true else |_| false;

    var vfs: Vfs = .init(t.io, t.allocator);
    defer vfs.deinit();
    try t.expectEqual(same_on_disk, try vfs.intern(upper) == try vfs.intern(lower));
}
