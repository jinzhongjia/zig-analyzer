//! 虚拟文件系统：路径 ↔ `FileId` 的驻留表。文件内容作为 `FileText` input 存放在查询引擎中。

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Vfs = @This();

pub const FileId = enum(u32) {
    _,

    pub fn index(id: FileId) u32 {
        return @backingInt(id);
    }
};

gpa: Allocator,
io: Io,
/// 同一文件可能在读事务中被 import 解析驻留，因此需要加锁
mutex: Io.Mutex = .init,
/// 规范化后的绝对路径，下标即 FileId
paths: std.StringArrayHashMapUnmanaged(void) = .empty,

pub fn init(io: Io, gpa: Allocator) Vfs {
    return .{ .io = io, .gpa = gpa };
}

pub fn deinit(vfs: *Vfs) void {
    for (vfs.paths.keys()) |p| vfs.gpa.free(p);
    vfs.paths.deinit(vfs.gpa);
    vfs.* = undefined;
}

/// 驻留路径。`path` 必须是绝对路径，会被规范化（消除 `.`、`..` 与重复分隔符）。
pub fn intern(vfs: *Vfs, file_path: []const u8) Allocator.Error!FileId {
    std.debug.assert(std.fs.path.isAbsolute(file_path));
    const normalized = try std.fs.path.resolveAlloc(vfs.gpa, &.{file_path});

    vfs.mutex.lockUncancelable(vfs.io);
    defer vfs.mutex.unlock(vfs.io);
    const gop = vfs.paths.getOrPut(vfs.gpa, normalized) catch |err| {
        vfs.gpa.free(normalized);
        return err;
    };
    if (gop.found_existing) vfs.gpa.free(normalized);
    return @fromBackingInt(@intCast(gop.index));
}

pub fn lookup(vfs: *Vfs, file_path: []const u8) Allocator.Error!?FileId {
    const normalized = try std.fs.path.resolveAlloc(vfs.gpa, &.{file_path});
    defer vfs.gpa.free(normalized);
    vfs.mutex.lockUncancelable(vfs.io);
    defer vfs.mutex.unlock(vfs.io);
    return if (vfs.paths.getIndex(normalized)) |i| @fromBackingInt(@intCast(i)) else null;
}

/// 返回的切片在 Vfs 生命周期内有效。
pub fn path(vfs: *Vfs, id: FileId) []const u8 {
    vfs.mutex.lockUncancelable(vfs.io);
    defer vfs.mutex.unlock(vfs.io);
    return vfs.paths.keys()[id.index()];
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

test "驻留与规范化" {
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
