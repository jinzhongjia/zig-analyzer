//! 引擎的 input query。

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const Vfs = @import("Vfs.zig");

/// 文件内容；`null` 表示文件不存在或尚未加载。
pub const FileText = struct {
    pub const Key = Vfs.FileId;
    pub const Value = ?[]const u8;
    pub const kind: engine.Kind = .input;
    pub const default: Value = null;

    pub fn eql(a: Value, b: Value) bool {
        if (a == null or b == null) return a == null and b == null;
        return std.mem.eql(u8, a.?, b.?);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        if (v.*) |text| gpa.free(text);
    }

    pub fn bytes(v: Value) usize {
        return if (v) |text| text.len else 0;
    }
};
