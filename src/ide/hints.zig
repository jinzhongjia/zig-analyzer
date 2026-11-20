//! Analyzer-owned diagnostics: hints that do not come from the compiler. They are published with
//! the source `zig-analyzer`, carry a stable code, and can be suppressed by comments in the
//! analyzed file (see `suppression.zig`). Compiler diagnostics are never suppressed: published
//! diagnostics must equal the compiler's output (see `docs/diagnostics.md`).

const std = @import("std");

/// Source of every analyzer-owned diagnostic
pub const source = "zig-analyzer";

/// Code of the hint on code that is not compiled under the current build configuration
pub const inactive_code = "inactive";
/// Code of the hint on a private declaration that no code in its file uses
pub const unused_code = "unused.declaration";

/// Families whose hints a suppression comment may name. Naming hints use `naming.<rule>`, lint
/// hints `lint.<rule>`.
const families = [_][]const u8{ "naming", "unused", "inactive", "lint" };

/// The code of a diagnostic that a suppression comment may remove: analyzer-owned hints only,
/// never compiler diagnostics (their source is `zig`)
pub fn suppressible(diagnostic_source: []const u8, code: []const u8) ?[]const u8 {
    if (!std.mem.eql(u8, diagnostic_source, source)) return null;
    if (!isSuppressible(code)) return null;
    return code;
}

/// Whether a suppression comment may name `code`
pub fn isSuppressible(code: []const u8) bool {
    for (families) |family| if (familyMatches(family, code)) return true;
    return false;
}

/// Whether `prefix` names `code` or its family: they are equal, or `code` continues after a `.`
/// (`naming` names `naming.type`, but `naming.t` names neither `naming.type` nor `naming.ts`)
pub fn familyMatches(prefix: []const u8, code: []const u8) bool {
    if (prefix.len > code.len) return false;
    if (!std.mem.eql(u8, prefix, code[0..prefix.len])) return false;
    return prefix.len == code.len or code[prefix.len] == '.';
}

test "a family names its codes at the dot boundary" {
    try std.testing.expect(familyMatches("naming", "naming"));
    try std.testing.expect(familyMatches("naming", "naming.type"));
    try std.testing.expect(familyMatches("unused", "unused.declaration"));
    try std.testing.expect(!familyMatches("naming.t", "naming.type"));
    try std.testing.expect(!familyMatches("naming", "naming2.type"));
    try std.testing.expect(!familyMatches("nam", "naming"));
}

test "only analyzer-owned hint families are suppressible" {
    try std.testing.expect(isSuppressible("naming.type"));
    try std.testing.expect(isSuppressible("unused.declaration"));
    try std.testing.expect(isSuppressible("inactive"));
    try std.testing.expect(!isSuppressible("E0001"));
}

test "compiler diagnostics are never suppressible" {
    try std.testing.expectEqualStrings("naming.type", suppressible(source, "naming.type").?);
    try std.testing.expectEqual(null, suppressible("zig", "naming.type"));
    try std.testing.expectEqual(null, suppressible(source, "E0001"));
}
