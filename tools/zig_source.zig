//! The official Zig sources of the pinned version (tools/zig/metadata.json): metadata and
//! validation shared by the generators.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const pinned_version = "0.17.1";

pub const Metadata = struct {
    version: []const u8,
    source_archive: []const u8,
    source_archive_sha256: []const u8,
    langref_path: []const u8,
    langref_sha256: []const u8,
    builtin_registry_path: []const u8,
    builtin_registry_sha256: []const u8,
    build_zig_zon_path: []const u8,
    build_zig_zon_sha256: []const u8,
    documentation_url: []const u8,
    license: []const u8,
};

fn invalid(comptime fmt: []const u8, args: anytype) error{InvalidOfficialSource} {
    // Tests construct invalid input on purpose; printing to stderr would put a misleading
    // `failed command` in the build output
    if (!@import("builtin").is_test) std.debug.print("official source: " ++ fmt ++ "\n", args);
    return error.InvalidOfficialSource;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn checkHash(bytes: []const u8, expected: []const u8, name: []const u8) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!eql(&actual, expected)) return invalid("{s} SHA-256 mismatch: expected {s}, got {s}", .{ name, expected, actual });
}

pub fn validateMetadata(a: Allocator, metadata: Metadata, compiler_version: []const u8) !void {
    if (!eql(metadata.version, pinned_version) or !eql(metadata.version, compiler_version))
        return invalid("version mismatch: generator {s}, official inputs {s}, compiler {s}", .{ pinned_version, metadata.version, compiler_version });
    const archive = try std.fmt.allocPrint(a, "https://ziglang.org/download/{s}/zig-{s}.tar.xz", .{ metadata.version, metadata.version });
    const docs = try std.fmt.allocPrint(a, "https://ziglang.org/documentation/{s}/", .{metadata.version});
    if (!eql(metadata.source_archive, archive) or !eql(metadata.documentation_url, docs) or
        !eql(metadata.langref_path, "doc/langref.html.in") or !eql(metadata.builtin_registry_path, "lib/std/zig/BuiltinFn.zig") or
        !eql(metadata.build_zig_zon_path, "doc/build.zig.zon.md") or
        !eql(metadata.license, "MIT") or metadata.source_archive_sha256.len != 64)
        return invalid("unexpected official source provenance for Zig {s}", .{metadata.version});
}
