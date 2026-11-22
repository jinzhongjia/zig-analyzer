//! Slow request log: the report of a request that took longer than `log.slow_request_ms`, with the
//! query trace that led to it.

const std = @import("std");
const Io = std.Io;
const za = @import("../zig_analyzer.zig");
const Vfs = za.base.Vfs;
const database = @import("../database.zig");
const Db = database.Db;
const syntax_q = database.syntax;

const Server = @import("Server.zig");

const log = std.log.scoped(.server);

/// Logs requests that take longer than `log.slow_request_ms`: self time summed per query, and the
/// slow paths in the call tree. Called before the read transaction ends (describing a key reads
/// the ItemTree).
pub fn reportIfSlow(server: *Server, ctx: *Db.Ctx, method: []const u8, t0: Io.Timestamp, trace: *const za.db.Trace) void {
    // In tests, request times vary with machine load, and warn writes to stderr, which makes the
    // build output show a misleading `failed command`; the report contents are covered by tests
    // that call writeSlowReport directly
    if (@import("builtin").is_test) return;
    const threshold = server.config.load(.acquire).slow_request_ms;
    if (threshold == 0) return;
    const ns: u64 = @intCast(@max(0, t0.durationTo(Io.Clock.awake.now(server.io)).nanoseconds));
    if (ns < @as(u64, threshold) * std.time.ns_per_ms) return;
    var out: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer out.deinit();
    // The call tree only expands nodes taking at least 2% of the total time (at least 1 ms)
    writeSlowReport(server, &out.writer, ctx, trace, @max(std.time.ns_per_ms, ns / 50)) catch return;
    log.warn("slow request {s}: {d:.1} ms, {d} queries executed\n{s}", .{ method, za.db_report.ms(ns), trace.events.items.len, out.written() });
}

/// Maximum number of call tree lines in a slow request report
const slow_tree_lines = 40;

/// Slow request report: self time summed per query, and call tree nodes taking at least `min_ns`
pub fn writeSlowReport(server: *Server, w: *std.Io.Writer, ctx: *Db.Ctx, trace: *const za.db.Trace, min_ns: u64) !void {
    const events = trace.events.items;
    // Self time: among the events in pre-order, an event's children are the consecutive events
    // after it with a greater depth
    var self_by_query: [Db.query_types.len]u64 = @splat(0);
    var count_by_query: [Db.query_types.len]u32 = @splat(0);
    for (events, 0..) |e, i| {
        var children: u64 = 0;
        var j = i + 1;
        while (j < events.len and events[j].depth > e.depth) : (j += 1) {
            if (events[j].depth == e.depth + 1) children += events[j].ns;
        }
        self_by_query[e.query] += e.ns -| children;
        count_by_query[e.query] += 1;
    }
    var order: [Db.query_types.len]usize = undefined;
    for (&order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, &order, &self_by_query, struct {
        fn gt(t: *const [Db.query_types.len]u64, a: usize, b: usize) bool {
            return t[a] > t[b];
        }
    }.gt);
    try w.writeAll("  by query (self time):\n");
    for (order[0..@min(order.len, 8)]) |qi| {
        if (count_by_query[qi] == 0) break;
        try w.print("    {s:<26} {d:>6}x {d:>9.1} ms\n", .{ za.db_report.shortName(queryName(qi)), count_by_query[qi], za.db_report.ms(self_by_query[qi]) });
    }
    try w.writeAll("  slowest paths:\n");
    var lines: usize = 0;
    var skip_below: ?u16 = null;
    for (events) |e| {
        if (skip_below) |d| {
            if (e.depth > d) continue;
            skip_below = null;
        }
        if (e.ns < min_ns) {
            skip_below = e.depth;
            continue;
        }
        if (lines == slow_tree_lines) {
            try w.writeAll("    ...\n");
            break;
        }
        lines += 1;
        try w.splatByteAll(' ', 4 + @as(usize, e.depth) * 2);
        try w.print("{s} ", .{za.db_report.shortName(queryName(e.query))});
        try describeKey(server, w, ctx, e.query, e.key);
        try w.print(" {d:.1} ms{s}{s}\n", .{ za.db_report.ms(e.ns), if (e.cutoff) " (cutoff)" else "", if (e.failed) " (canceled)" else "" });
    }
}

fn queryName(qi: usize) []const u8 {
    inline for (Db.query_types, 0..) |Q, i| if (i == qi) return @typeName(Q);
    unreachable;
}

/// Readable form of a key: a file is shown as its file name, a member as "file name:member name",
/// and other fields are written as is
fn describeKey(server: *Server, w: *std.Io.Writer, ctx: *Db.Ctx, qi: usize, index: u32) !void {
    inline for (Db.query_types, 0..) |Q, i| if (i == qi) {
        if (Q.Key == void) return;
        return writeValue(server, w, ctx, server.db.keyAt(Q, index));
    };
}

fn writeValue(server: *Server, w: *std.Io.Writer, ctx: *Db.Ctx, value: anytype) !void {
    const T = @TypeOf(value);
    if (T == Vfs.FileId) return w.writeAll(std.fs.path.basename(server.vfs.path(value)));
    if (T == za.database.hir.OwnerKey) {
        try w.writeAll(std.fs.path.basename(server.vfs.path(value.file)));
        const tree = ctx.get(syntax_q.FileItemTree, value.file) catch return w.print("#{d}", .{@backingInt(value.item)});
        if (tree.itemOf(value.item)) |i| return w.print(":{s}", .{tree.items[i].name orelse "_"});
        return w.print("#{d}", .{@backingInt(value.item)});
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            try w.writeAll("{");
            inline for (info.field_names, 0..) |name, i| {
                if (i > 0) try w.writeAll(" ");
                try w.print("{s}=", .{name});
                try writeValue(server, w, ctx, @field(value, name));
            }
            try w.writeAll("}");
        },
        .optional => if (value) |v| try writeValue(server, w, ctx, v) else try w.writeAll("null"),
        .@"enum" => try w.print("{any}", .{value}),
        else => try w.print("{any}", .{value}),
    }
}
