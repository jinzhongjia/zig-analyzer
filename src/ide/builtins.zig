//! Metadata of the official builtin functions, matching the current compiler version.
const std = @import("std");
const data = @import("builtin_data.zig");

pub const Entry = struct {
    name: []const u8,
    signature: ?[]const u8,
    parameters: []const []const u8,
    documentation: []const u8,
    variadic: bool,
    documented: bool,
    source_url: []const u8,
    compiler_param_count: ?u8,
};

pub const entries: []const Entry = &data.entries;
pub const version = data.version;

const index = index: {
    @setEvalBranchQuota(20000);
    var pairs: [entries.len]struct { []const u8, usize } = undefined;
    for (entries, 0..) |entry, i| pairs[i] = .{ entry.name, i };
    break :index std.StaticStringMap(usize).initComptime(pairs);
};

pub fn get(name: []const u8) ?*const Entry {
    return &entries[index.get(name) orelse return null];
}

comptime {
    @setEvalBranchQuota(20000);
    const registry = std.zig.BuiltinFn.list;
    if (registry.keys().len != entries.len)
        @compileError("builtin metadata coverage differs from compiler; run zig build gen");
    for (entries) |entry| {
        const compiler = registry.get(entry.name) orelse
            @compileError("builtin metadata name missing from compiler registry: " ++ entry.name);
        if (compiler.param_count != entry.compiler_param_count)
            @compileError("builtin metadata arity differs from compiler registry: " ++ entry.name);
    }
}
