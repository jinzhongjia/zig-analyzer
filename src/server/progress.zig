//! 工作进度（LSP work done progress）：项目加载、构建、单文件编译。
//!
//! 服务器主动发进度前必须先用 `window/workDoneProgress/create` 向客户端申请 token 并收到成功响应。
//! 为不阻塞构建，`begin` 发出申请后立即返回；响应到达时再补发 begin（及最近一次 report）。
//! 若响应到达前进度已结束，则不再发送；客户端回复错误则放弃该 token（不再发送，`end` 时释放）。

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Server = @import("Server.zig");

const log = std.log.scoped(.progress);

const Registry = @This();

mutex: Io.Mutex = .init,
/// 客户端在 initialize 中声明支持 `window.workDoneProgress`
enabled: bool = false,
next_id: u32 = 0,
/// 尚未结束或尚未收到 create 响应的进度（键为 token 序号，同时也是 create 请求的 id）
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

/// 回收已结束、但客户端从未回复 create 的条目。持有者已经调用 `end`，不会再使用指针；
/// 未结束的条目留着，避免悬空指针。调用者持有 `mutex`
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

/// 同时存在的进度上限：客户端不回复 create 时，已结束的条目会在下一次 begin 时回收；
/// 全部未结束（调用方仍持有指针）时不再新建，避免无界增长
const max_active = 64;

/// 开始一个进度；客户端不支持时返回 null（其余函数接受 null 并忽略）
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
        // 等 create 响应到达后再释放
        .creating => {},
    }
}

/// 处理客户端对 create 请求的响应；不是进度相关的响应时返回 false
pub fn handleResponse(reg: *Registry, server: *Server, id: i64, ok: bool) bool {
    reg.mutex.lockUncancelable(server.io);
    defer reg.mutex.unlock(server.io);
    if (id < 0 or id > std.math.maxInt(u32)) return false;
    const p = reg.active.get(@intCast(id)) orelse return false;
    if (p.state != .creating) return true;
    if (p.ended) {
        // 已经结束（构建很快）：不再发送
        _ = reg.active.swapRemove(p.id);
        free(server.gpa, p);
        return true;
    }
    if (!ok) {
        // 被拒绝：持有者仍在使用该指针，等 `end` 时再释放
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
    // 仍被调用方持有的进度
    const live = try gpa.create(Progress);
    live.* = .{ .id = max_active + 100, .title = try gpa.dupe(u8, "live") };
    try reg.active.put(gpa, live.id, live);

    reg.pruneLocked(gpa);
    try std.testing.expectEqual(max_active - 1, reg.active.count());
    try std.testing.expect(reg.active.get(live.id) != null);
}
