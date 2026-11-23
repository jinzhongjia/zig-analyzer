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

/// Whether requests record a trace: `captureIfSlow` is the only consumer of `Ctx.trace`, and
/// `logReport` writes what it built; nothing is recorded when the threshold is 0
pub fn traceEnabled(server: *Server) bool {
    return server.config.load(.acquire).slow_request_ms != 0;
}

/// A slow request report: self time summed per query and the slow paths in the call tree, built
/// before the read transaction ends (describing a key reads the ItemTree) and logged after it.
pub const Report = struct {
    method: []const u8,
    ns: u64,
    queries: usize,
    body: []const u8,
};

/// Builds the report of a request that took longer than `log.slow_request_ms`; null when the
/// request is not reported. The report's memory is allocated from `ctx.gpa` and stays valid until
/// the caller's arena is freed.
pub fn captureIfSlow(server: *Server, ctx: *Db.Ctx, method: []const u8, t0: Io.Timestamp, trace: *const za.db.Trace) ?Report {
    // In tests, request times vary with machine load, and warn writes to stderr, which makes the
    // build output show a misleading `failed command`; the report contents are covered by tests
    // that call writeSlowReport directly
    if (@import("builtin").is_test) return null;
    // The trace is recorded only when `traceEnabled` was true when the request began
    if (ctx.trace == null) return null;
    const threshold = server.config.load(.acquire).slow_request_ms;
    if (threshold == 0) return null;
    const ns: u64 = @intCast(@max(0, t0.durationTo(Io.Clock.awake.now(server.io)).nanoseconds));
    if (ns < @as(u64, threshold) * std.time.ns_per_ms) return null;
    var out: std.Io.Writer.Allocating = .init(ctx.gpa);
    // The call tree only expands nodes taking at least 2% of the total time (at least 1 ms)
    writeSlowReport(server, &out.writer, ctx, trace, @max(std.time.ns_per_ms, ns / 50)) catch {
        out.deinit();
        return null;
    };
    return .{ .method = method, .ns = ns, .queries = trace.events.items.len, .body = out.written() };
}

/// Writes a report built by `captureIfSlow`; called outside the read transaction.
pub fn logReport(report: Report) void {
    log.warn("slow request {s}: {d:.1} ms, {d} queries executed\n{s}", .{ report.method, za.db_report.ms(report.ns), report.queries, report.body });
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
    try sumSelfTime(ctx.gpa, events, &self_by_query, &count_by_query);
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

/// Sums self time and counts per query in one pass over the pre-order events: a node's self time is
/// its total time minus the time of its direct children, summed on a stack of the open ancestors
fn sumSelfTime(
    gpa: std.mem.Allocator,
    events: []const za.db.Trace.Event,
    self_by_query: *[Db.query_types.len]u64,
    count_by_query: *[Db.query_types.len]u32,
) !void {
    const Open = struct {
        event: *const za.db.Trace.Event,
        child_ns: u64 = 0,
    };
    var open: std.ArrayList(Open) = .empty;
    defer open.deinit(gpa);
    for (events) |*e| {
        // Events at or below this depth end the runs of their deeper predecessors
        while (open.items.len > 0 and open.items[open.items.len - 1].event.depth >= e.depth) {
            const done = open.pop().?;
            self_by_query[done.event.query] += done.event.ns -| done.child_ns;
        }
        if (open.items.len > 0 and open.items[open.items.len - 1].event.depth + 1 == e.depth) {
            open.items[open.items.len - 1].child_ns += e.ns;
        }
        count_by_query[e.query] += 1;
        try open.append(gpa, .{ .event = e });
    }
    while (open.pop()) |done| {
        self_by_query[done.event.query] += done.event.ns -| done.child_ns;
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

test "self time equals the subtree scan" {
    const gpa = std.testing.allocator;
    const Event = za.db.Trace.Event;
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(gpa);

    // Roots and siblings, grandchildren, a child that takes longer than its parent (saturating
    // subtraction), and a deep chain below the second root
    const fixed = [_]Event{
        .{ .query = 0, .key = 0, .depth = 0, .ns = 100 },
        .{ .query = 1, .key = 0, .depth = 1, .ns = 30 },
        .{ .query = 2, .key = 0, .depth = 2, .ns = 10 },
        .{ .query = 0, .key = 0, .depth = 2, .ns = 5 },
        .{ .query = 1, .key = 0, .depth = 1, .ns = 40 },
        .{ .query = 2, .key = 0, .depth = 2, .ns = 70 },
        .{ .query = 0, .key = 0, .depth = 3, .ns = 20 },
        .{ .query = 1, .key = 0, .depth = 2, .ns = 1 },
        .{ .query = 2, .key = 0, .depth = 1, .ns = 0 },
        .{ .query = 0, .key = 0, .depth = 0, .ns = 60 },
        .{ .query = 1, .key = 0, .depth = 1, .ns = 10 },
    };
    try events.appendSlice(gpa, &fixed);
    for (0..200) |i| {
        try events.append(gpa, .{
            .query = @intCast(i % 3),
            .key = 0,
            .depth = @intCast(i + 2),
            .ns = @intCast(1 + i % 7),
        });
    }

    // Reference: the subtree scan this one replaces, O(n x depth)
    var want_self: [Db.query_types.len]u64 = @splat(0);
    var want_count: [Db.query_types.len]u32 = @splat(0);
    for (events.items, 0..) |e, i| {
        var children: u64 = 0;
        var j = i + 1;
        while (j < events.items.len and events.items[j].depth > e.depth) : (j += 1) {
            if (events.items[j].depth == e.depth + 1) children += events.items[j].ns;
        }
        want_self[e.query] += e.ns -| children;
        want_count[e.query] += 1;
    }

    var got_self: [Db.query_types.len]u64 = @splat(0);
    var got_count: [Db.query_types.len]u32 = @splat(0);
    try sumSelfTime(gpa, events.items, &got_self, &got_count);
    try std.testing.expectEqualDeep(want_self, got_self);
    try std.testing.expectEqualDeep(want_count, got_count);
}
