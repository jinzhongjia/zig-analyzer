//! Input queries of the engine.

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine = @import("../db/engine.zig");
const Vfs = @import("Vfs.zig");
/// The reference-counted text buffer of `FileText`
pub const Text = @import("../util/Text.zig");

/// File contents; `null` means the file does not exist or has not been loaded yet.
/// The value holds one reference to the buffer, which the parse results of the file share.
pub const FileText = struct {
    pub const Key = Vfs.FileId;
    pub const Value = ?*Text;
    pub const kind: engine.Kind = .input;
    pub const default: Value = null;

    pub fn eql(a: Value, b: Value) bool {
        if (a == null or b == null) return a == null and b == null;
        return std.mem.eql(u8, a.?.bytes(), b.?.bytes());
    }

    /// Taking a pointer parameter is the engine's uniform signature for query `deinit` (see
    /// `db/engine.zig`); only `v.*` is read here.
    pub fn deinit(v: *Value, gpa: Allocator) void {
        if (v.*) |text| text.release(gpa);
    }

    pub fn bytes(v: Value) usize {
        return if (v) |text| text.len else 0;
    }
};

/// The user's source files under the workspace root directories, sorted and without duplicates
/// (see `server/workspace_files.zig`)
pub const WorkspaceFiles = struct {
    pub const Key = void;
    pub const Value = []const Vfs.FileId;
    pub const kind: engine.Kind = .input;
    pub const default: Value = &.{};

    pub fn eql(a: Value, b: Value) bool {
        return std.mem.eql(Vfs.FileId, a, b);
    }

    pub fn deinit(v: *Value, gpa: Allocator) void {
        gpa.free(v.*);
    }
};
