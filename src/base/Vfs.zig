//! 虚拟文件系统：路径 ↔ `FileId` 的驻留表。文件内容作为 `FileText` input 存放在查询引擎中。
//!
//! 文件身份由「规范化路径」决定；在大小写不敏感的文件系统上（Windows、macOS 的默认设置），
//! 身份键还会统一 ASCII 字母的大小写，使 `C:\Work\A.zig` 与 `c:/work/a.zig` 映射到同一个 FileId。
//! 对外（显示、构造 URI）使用第一次见到的路径写法。
//!
//! 已知限制：只统一 ASCII 字母；NTFS 的 Unicode 大写映射与 APFS 的 Unicode 规范化不等价未处理。

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

    /// Windows 与 macOS 的默认文件系统不区分大小写
    pub const native: CaseMode = switch (@import("builtin").target.os.tag) {
        .windows, .macos, .ios => .insensitive,
        else => .sensitive,
    };
};

gpa: Allocator,
io: Io,
style: Style,
case: CaseMode,
/// 同一文件可能在读事务中被 import 解析驻留，因此需要加锁
mutex: Io.Mutex = .init,
/// 身份键（规范化路径，大小写不敏感时再统一为小写），下标即 FileId
keys: std.StringArrayHashMapUnmanaged(void) = .empty,
/// 与 `keys` 一一对应：第一次见到的规范化路径（保留原始大小写）
paths: std.ArrayList([]const u8) = .empty,

pub const Options = struct {
    style: Style = .native,
    case: CaseMode = .native,
};

pub fn init(io: Io, gpa: Allocator) Vfs {
    return initOptions(io, gpa, .{});
}

/// 指定路径风格与大小写模式（测试中用于在任意平台上覆盖两种规则）
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

/// 由规范化路径得到身份键（调用方拥有返回值）
fn identityKey(vfs: *const Vfs, normalized: []const u8) Allocator.Error![]u8 {
    const key = try vfs.gpa.dupe(u8, normalized);
    if (vfs.case == .insensitive) _ = std.ascii.lowerString(key, key);
    return key;
}

/// 规范化绝对路径：消除 `.`、`..`、重复与末尾分隔符；Windows 下统一使用反斜杠并把盘符转为大写。
/// 不是绝对路径时返回 null。两种风格在任何平台上都可调用，便于测试。
pub fn normalize(comptime style: Style, gpa: Allocator, file_path: []const u8) Allocator.Error!?[]u8 {
    return switch (style) {
        .posix => if (std.fs.path.isAbsolutePosix(file_path)) try std.fs.path.resolveAllocPosix(gpa, &.{file_path}) else null,
        .windows => if (std.fs.path.isAbsoluteWindows(file_path)) try std.fs.path.resolveAllocWindows(gpa, &.{file_path}) else null,
    };
}

/// 按 `std.fs.path.resolve` 的规则把 `sub_path` 相对于绝对路径 `base` 解析。结果不是绝对路径时返回 null：
/// Windows 上另一驱动器的相对路径（如 `D:a.zig`）解析后仍是相对路径。返回非 null 时可以传给 `intern`。
/// 两种风格在任何平台上都可调用，便于测试。
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

/// 驻留路径。调用方须保证 `file_path` 是绝对路径；路径会被规范化（见 `normalize`）。
pub fn intern(vfs: *Vfs, file_path: []const u8) Allocator.Error!FileId {
    const normalized = try vfs.normalizeOwn(file_path) orelse unreachable;
    errdefer vfs.gpa.free(normalized);
    const key = try vfs.identityKey(normalized);
    errdefer vfs.gpa.free(key);

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
    return @fromBackingInt(@intCast(gop.index));
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

/// 返回的切片在 Vfs 生命周期内有效。
pub fn path(vfs: *Vfs, id: FileId) []const u8 {
    vfs.mutex.lockUncancelable(vfs.io);
    defer vfs.mutex.unlock(vfs.io);
    return vfs.paths.items[id.index()];
}

pub const ReadError = error{ Canceled, OutOfMemory, FileTooBig };

/// 从磁盘读取文件；文件不存在或不可读时返回 null。
pub fn readFromDisk(vfs: *Vfs, id: FileId, gpa: Allocator) ReadError!?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(vfs.io, vfs.path(id), gpa, .limited(max_file_size)) catch |err| switch (err) {
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.FileTooBig,
        else => null,
    };
}

/// 超过此大小的文件不加载（与 Zig 编译器对单个源文件的限制同量级）
pub const max_file_size = 64 * 1024 * 1024;

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
        // 另一驱动器的相对路径：错误包格式不符时，路径下标可能指向源码行中间的 `x: u32 = 1;`
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
