//! Work progress (LSP work done progress): project loading, builds, single-file compiles.
//!
//! Before sending progress on its own initiative, the server must request a token from the client
//! with `window/workDoneProgress/create` and receive a successful response.
//! To avoid blocking builds, `begin` returns right after sending the request; begin (and the
//! latest report) is sent once the response arrives.
//! If the progress has ended before the response arrives, nothing is sent; if the client replies
//! with an error, the token is abandoned (nothing more is sent; it is freed at `end`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Server = @import("Server.zig");

const log = std.log.scoped(.progress);

const Registry = @This();

mutex: Io.Mutex = .init,
/// The client declared support for `window.workDoneProgress` in initialize
enabled: bool = false,
next_id: u32 = 0,
/// Progress that has not ended or has not received its create response yet (keyed by the token
/// number, which is also the id of the create request)
active: std.AutoArrayHashMapUnmanaged(u32, *Progress) = .empty,

pub const Progress = struct {
    id: u32,
    title: []u8,
    message: ?[]u8 = null,
    percentage: ?u32 = null,
    state: enum { creating, active, failed } = .creating,
    ended: bool = false,
};

const Begin = struct { kind: []const u8 = "begin", title: []const u8, message: ?[]const u8 = null, percentage: ?u32 = null, cancellable: bool = false };
const Report = struct { kind: []const u8 = "report", message: ?[]const u8 = null, percentage: ?u32 = null };
const End = struct { kind: []const u8 = "end", message: ?[]const u8 = null };

pub fn deinit(reg: *Registry, gpa: Allocator) void {
    for (reg.active.values()) |p| free(gpa, p);
    reg.active.deinit(gpa);
}

fn free(gpa: Allocator, p: *Progress) void {
    gpa.free(p.title);
    if (p.message) |m| gpa.free(m);
    gpa.destroy(p);
}

/// Reclaims entries that have ended but whose create the client never answered. Their holders
/// have already called `end` and will not use the pointers again; entries that have not ended
/// are kept, to avoid dangling pointers. The caller holds `mutex`.
fn pruneLocked(reg: *Registry, gpa: Allocator) void {
    var i: usize = 0;
    while (i < reg.active.count()) {
        if (reg.active.count() < max_active) return;
        const p = reg.active.values()[i];
        if (p.state == .creating and p.ended) {
            _ = reg.active.orderedRemove(p.id);
            free(gpa, p);
        } else i += 1;
    }
}

fn tokenBuf(buf: *[32]u8, id: u32) []const u8 {
    return std.fmt.bufPrint(buf, "zig-analyzer/{d}", .{id}) catch unreachable;
}

/// Maximum number of progress entries at the same time: when the client does not answer create,
/// ended entries are reclaimed at the next begin; when none has ended (the callers still hold the
/// pointers), no new ones are created, to avoid unbounded growth
const max_active = 64;

/// Begins a progress; returns null when the client does not support progress (the other
/// functions accept null and ignore it)
pub fn begin(reg: *Registry, server: *Server, title: []const u8, percentage: bool) ?*Progress {
    const gpa = server.gpa;
    reg.mutex.lockUncancelable(server.io);
    defer reg.mutex.unlock(server.io);
    if (!reg.enabled) return null;
    if (reg.active.count() >= max_active) {
        reg.pruneLocked(gpa);
        if (reg.active.count() >= max_active) return null;
    }
    const p = gpa.create(Progress) catch return null;
    p.* = .{ .id = reg.next_id, .title = gpa.dupe(u8, title) catch {
        gpa.destroy(p);
        return null;
    }, .percentage = if (percentage) 0 else null };
    reg.next_id += 1;
    reg.active.put(gpa, p.id, p) catch {
        free(gpa, p);
        return null;
    };
    var buf: [32]u8 = undefined;
    server.sendRequest(.{ .integer = p.id }, "window/workDoneProgress/create", .{ .token = tokenBuf(&buf, p.id) });
    return p;
}

pub fn report(reg: *Registry, server: *Server, progress: ?*Progress, message: ?[]const u8, percentage: ?u32) void {
    const p = progress orelse return;
    reg.mutex.lockUncancelable(server.io);
    defer reg.mutex.unlock(server.io);
    if (message) |m| {
        const owned = server.gpa.dupe(u8, m) catch return;
        if (p.message) |old| server.gpa.free(old);
        p.message = owned;
    }
    if (percentage) |pct| p.percentage = @min(pct, 100);
    if (p.state == .active) {
        var buf: [32]u8 = undefined;
        server.sendNotification("$/progress", .{ .token = tokenBuf(&buf, p.id), .value = Report{ .message = p.message, .percentage = p.percentage } });
    }
}

pub fn end(reg: *Registry, server: *Server, progress: ?*Progress, message: ?[]const u8) void {
    const p = progress orelse return;
    reg.mutex.lockUncancelable(server.io);
    defer reg.mutex.unlock(server.io);
    p.ended = true;
    switch (p.state) {
        .active => {
            var buf: [32]u8 = undefined;
            server.sendNotification("$/progress", .{ .token = tokenBuf(&buf, p.id), .value = End{ .message = message } });
            _ = reg.active.swapRemove(p.id);
            free(server.gpa, p);
        },
        .failed => {
            _ = reg.active.swapRemove(p.id);
            free(server.gpa, p);
        },
        // Freed once the create response arrives
        .creating => {},
    }
}

/// Handles the client's response to a create request; returns false for a response unrelated to
/// progress
pub fn handleResponse(reg: *Registry, server: *Server, id: i64, ok: bool) bool {
    reg.mutex.lockUncancelable(server.io);
    defer reg.mutex.unlock(server.io);
    if (id < 0 or id > std.math.maxInt(u32)) return false;
    const p = reg.active.get(@intCast(id)) orelse return false;
    if (p.state != .creating) return true;
    if (p.ended) {
        // Already ended (the build was fast): send nothing
        _ = reg.active.swapRemove(p.id);
        free(server.gpa, p);
        return true;
    }
    if (!ok) {
        // Rejected: the holder is still using the pointer; free it at `end`
        log.info("client rejected progress token", .{});
        p.state = .failed;
        return true;
    }
    p.state = .active;
    var buf: [32]u8 = undefined;
    server.sendNotification("$/progress", .{ .token = tokenBuf(&buf, p.id), .value = Begin{ .title = p.title, .message = p.message, .percentage = p.percentage } });
    return true;
}

test "pruneLocked drops ended entries but keeps the ones still in use" {
    const gpa = std.testing.allocator;
    var reg: Registry = .{};
    defer reg.deinit(gpa);
    for (0..max_active + 10) |i| {
        const p = try gpa.create(Progress);
        p.* = .{ .id = @intCast(i), .title = try gpa.dupe(u8, "done"), .state = .creating, .ended = true };
        try reg.active.put(gpa, p.id, p);
    }
    // Progress still held by a caller
    const live = try gpa.create(Progress);
    live.* = .{ .id = max_active + 100, .title = try gpa.dupe(u8, "live") };
    try reg.active.put(gpa, live.id, live);

    reg.pruneLocked(gpa);
    try std.testing.expectEqual(max_active - 1, reg.active.count());
    try std.testing.expect(reg.active.get(live.id) != null);
}
