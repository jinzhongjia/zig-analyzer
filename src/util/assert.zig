//! Soft assertions: conditions that should never happen but can be handled by degrading when they
//! do (the counterpart of rust-analyzer's `never!`). In Debug builds and tests they behave like
//! `assert`, so that problems surface early; in other builds each call site logs only once, and the
//! caller takes a degraded path (treating the result as `unknown`, skipping the item, etc.). Only
//! for assumptions that analysis code makes about input data, not a substitute for memory-safety
//! checks: where continuing would read or write out of bounds, still use `assert` or `.?`.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.assert);

/// `cond` being true means that something that should never happen did happen, and the caller
/// degrades accordingly: `if (never(i >= len, @src(), "...")) return null;`
pub fn never(cond: bool, comptime src: std.builtin.SourceLocation, comptime msg: []const u8) bool {
    if (!cond) return false;
    report(src, msg);
    return true;
}

fn report(comptime src: std.builtin.SourceLocation, comptime msg: []const u8) void {
    @branchHint(.cold);
    if (builtin.mode == .debug or builtin.is_test) std.debug.panic("{s}:{d}: {s}", .{ src.file, src.line, msg });
    const Site = struct {
        var logged: std.atomic.Value(bool) = .init(false);
    };
    if (!Site.logged.swap(true, .monotonic)) log.err("{s}:{d}: {s} (reported once)", .{ src.file, src.line, msg });
}

/// Another way to write `never(!cond, ...)`: returns `cond`
pub fn always(cond: bool, comptime src: std.builtin.SourceLocation, comptime msg: []const u8) bool {
    return !never(!cond, src, msg);
}

test never {
    try std.testing.expect(!never(false, @src(), "not reached"));
    try std.testing.expect(always(true, @src(), "not reached"));
}
