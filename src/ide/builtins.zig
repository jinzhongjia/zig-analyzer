//! Metadata of the official builtin functions of the supported zig versions.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Dialect = @import("../syntax/Parse.zig").Dialect;
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

/// The documentation of `entry` for the user's zig version. The tables are generated from the
/// sources of 0.17.1; those of 0.17.0 give the same text with its own version in the links and notes.
pub fn documentation(arena: Allocator, entry: *const Entry, dialect: Dialect) Allocator.Error![]const u8 {
    return switch (dialect) {
        .zig_0_17_0 => std.mem.replaceOwned(u8, arena, entry.documentation, version, "0.17.0"),
        .zig_0_17_1 => entry.documentation,
    };
}

test documentation {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (entries) |*entry| {
        try std.testing.expectEqualStrings(entry.documentation, try documentation(a, entry, .zig_0_17_1));
        const old = try documentation(a, entry, .zig_0_17_0);
        try std.testing.expect(std.mem.indexOf(u8, old, version) == null);
        try std.testing.expect(std.mem.indexOf(u8, old, "0.17.0") != null);
    }
    const old = try documentation(a, get("@sizeOf").?, .zig_0_17_0);
    try std.testing.expect(std.mem.indexOf(u8, old, "https://ziglang.org/documentation/0.17.0/#sizeOf") != null);
    try std.testing.expect(std.mem.indexOf(u8, old, "Zig 0.17.0 Language Reference") != null);
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
