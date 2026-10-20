//! 软断言：不应发生、但出现时可以降级的情况（对应 rust-analyzer 的 `never!`）。Debug 构建与测试中同 `assert`，
//! 让问题尽早暴露；其余构建中每个调用处只记录一次日志，由调用方走降级路径（结果按 `unknown`、跳过这一项等）。
//! 只用于分析代码对输入数据的假设，不替代内存安全检查：继续执行会读写越界的地方仍然用 `assert` 或 `.?`。

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.assert);

/// `cond` 为 true 表示出现了不应发生的情况，调用方据此降级：`if (never(i >= len, @src(), "...")) return null;`
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

/// `never(!cond, ...)` 的另一种写法：返回 `cond`
pub fn always(cond: bool, comptime src: std.builtin.SourceLocation, comptime msg: []const u8) bool {
    return !never(!cond, src, msg);
}

test never {
    try std.testing.expect(!never(false, @src(), "not reached"));
    try std.testing.expect(always(true, @src(), "not reached"));
}
