//! 查询统计的文本报告：基准工具、语料工具与慢请求日志共用。

const std = @import("std");
const engine = @import("engine.zig");
const QueryStats = engine.QueryStats;

/// query 的显示名：类型全名的最后两段（如 `queries.Infer`）
pub fn shortName(full: []const u8) []const u8 {
    const last = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    const prev = std.mem.lastIndexOfScalar(u8, full[0..last], '.') orelse return full;
    return full[prev + 1 ..];
}

/// 按自身耗时降序列出前 `limit` 个执行过的 query：执行次数、命中率、cutoff、结果不完整的次数、
/// 累计 / 自身 / 最长耗时、memo 数
pub fn writeTable(w: *std.Io.Writer, names: []const []const u8, stats: []const QueryStats, limit: usize) std.Io.Writer.Error!void {
    var order: [256]usize = undefined;
    const n = @min(stats.len, order.len);
    for (order[0..n], 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order[0..n], stats, struct {
        fn gt(s: []const QueryStats, a: usize, b: usize) bool {
            return s[a].self_ns > s[b].self_ns;
        }
    }.gt);
    try w.print("{s:<28} {s:>9} {s:>6} {s:>8} {s:>8} {s:>10} {s:>10} {s:>9} {s:>8}\n", .{ "query", "execs", "hit%", "cutoffs", "incompl", "total ms", "self ms", "max ms", "memos" });
    var shown: usize = 0;
    for (order[0..n]) |i| {
        const q = stats[i];
        if (q.executions == 0) continue;
        if (shown == limit) break;
        shown += 1;
        const reads = q.executions + q.hits;
        const hit_pct = if (reads == 0) 0 else 100 * @as(f64, @floatFromInt(q.hits)) / @as(f64, @floatFromInt(reads));
        try w.print("{s:<28} {d:>9} {d:>5.1}% {d:>8} {d:>8} {d:>10.1} {d:>10.1} {d:>9.1} {d:>8}\n", .{
            shortName(names[i]), q.executions, hit_pct, q.cutoffs, q.incomplete, ms(q.total_ns), ms(q.self_ns), ms(q.max_ns), q.memos,
        });
    }
}

pub fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

test shortName {
    try std.testing.expectEqualStrings("queries.Infer", shortName("sema.queries.Infer"));
    try std.testing.expectEqualStrings("Infer", shortName("Infer"));
}
