//! 服务器轮询磁盘上的外部改动（git checkout、代码生成、其他编辑器）：客户端不能动态注册文件监听时
//! （Linux 上的 Neovim 默认如此），或配置 `files.watcher` 为 `server` 时。
//!
//! 定期检查已知文件与各工作区根目录的项目文件（`build.zig`、`build.zig.zon`、`zig-analyzer.json`）的大小与修改时间，
//! 变化按 `workspace/didChangeWatchedFiles` 的通知处理，与客户端的通知走同一条路径。不检查的文件：
//! - 从未接触过的文件：与分析无关，被 import 时再从磁盘加载；
//! - Zig 安装目录与全局缓存中的文件：不会改变；
//! - 打开的文档：以缓冲区为准，编辑器中的保存由 `didSave` 处理。
//!
//! 第一次检查到一个文件时只记下它的状态，之后的变化才产生事件。

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const za = @import("../zig_analyzer.zig");
const types = za.lsp.types;
const uri = za.base.uri;
const Vfs = za.base.Vfs;
const Server = @import("Server.zig");
const Config = @import("Config.zig");

const log = std.log.scoped(.watch);

/// 文件在磁盘上的状态；不存在时为 null
const Stamp = struct {
    size: u64,
    mtime: i96,
};

/// 两次检查之间的等待至少是一次检查耗时的这么多倍：文件很多、检查本身较慢时拉长间隔，轮询占用的时间不超过约 5%
const min_idle_factor = 20;

/// 后台任务：每隔 `Server.poll_interval_ms` 检查一次（见 `min_idle_factor`），服务器关闭时结束（取消时在等待中返回）
pub fn run(server: *Server) Io.Cancelable!void {
    var poller: Poller = .{ .gpa = server.gpa };
    defer poller.deinit();
    var busy_ns: i96 = 0;
    while (true) {
        const interval_ns = @as(i96, server.poll_interval_ms.load(.monotonic)) * std.time.ns_per_ms;
        const wait_ns = @max(interval_ns, busy_ns * min_idle_factor);
        try (Io.Clock.Duration{ .raw = .{ .nanoseconds = wait_ns }, .clock = .awake }).sleep(server.io);
        if (server.isShuttingDown()) return;
        // 关闭轮询时丢弃记下的状态：重新开启后以那时的状态为准，期间的变化不补报
        if (!server.pollsFiles()) {
            poller.reset();
            busy_ns = 0;
            continue;
        }
        const start = Io.Clock.awake.now(server.io);
        poller.poll(server) catch |err| switch (err) {
            error.OutOfMemory => log.err("out of memory while checking files on disk", .{}),
        };
        busy_ns = start.durationTo(Io.Clock.awake.now(server.io)).nanoseconds;
    }
}

const Poller = struct {
    gpa: Allocator,
    /// 路径（属于 `gpa`）→ 上一次检查时的状态
    seen: std.StringArrayHashMapUnmanaged(?Stamp) = .empty,

    fn deinit(p: *Poller) void {
        p.reset();
        p.seen.deinit(p.gpa);
    }

    fn reset(p: *Poller) void {
        for (p.seen.keys()) |k| p.gpa.free(k);
        p.seen.clearRetainingCapacity();
    }

    fn poll(p: *Poller, server: *Server) Allocator.Error!void {
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const paths = try candidates(server, a);

        // 本次检查的文件与状态；不再检查的文件（打开了、根目录被移除）不再记录
        var current: std.StringArrayHashMapUnmanaged(?Stamp) = .empty;
        for (paths) |path| try current.put(a, path, stat(server.io, path));
        var i: usize = p.seen.count();
        while (i > 0) {
            i -= 1;
            if (current.contains(p.seen.keys()[i])) continue;
            p.gpa.free(p.seen.keys()[i]);
            p.seen.swapRemoveAt(i);
        }

        var events: std.ArrayList(types.FileEvent) = .empty;
        for (current.keys(), current.values()) |path, now| {
            const gop = try p.seen.getOrPut(p.gpa, path);
            if (!gop.found_existing) {
                gop.key_ptr.* = p.gpa.dupe(u8, path) catch |err| {
                    p.seen.swapRemoveAt(gop.index);
                    return err;
                };
                gop.value_ptr.* = now;
                continue;
            }
            const before = gop.value_ptr.*;
            gop.value_ptr.* = now;
            const kind: types.FileChangeType = if (before == null and now == null)
                continue
            else if (before == null)
                .Created
            else if (now == null)
                .Deleted
            else if (std.meta.eql(before.?, now.?))
                continue
            else
                .Changed;
            try events.append(a, .{ .uri = try uri.fromPath(a, path), .type = kind });
        }
        if (events.items.len == 0) return;
        log.info("{d} file(s) changed on disk", .{events.items.len});
        server.applyWatchedChanges(a, events.items);
    }
};

/// 要检查的文件（路径分配在 `a` 中，不重复）
fn candidates(server: *Server, a: Allocator) Allocator.Error![]const []const u8 {
    var out: std.StringArrayHashMapUnmanaged(void) = .empty;
    const count = server.vfs.count();
    for (0..count) |i| {
        const file: Vfs.FileId = @fromBackingInt(@as(u32, @intCast(i)));
        const path = server.vfs.path(file);
        if (!std.mem.endsWith(u8, path, ".zig") and !std.mem.endsWith(u8, path, ".zon")) continue;
        if (Server.isVirtual(path) or server.fileDurability(path) != .low) continue;
        {
            server.docs_mutex.lockUncancelable(server.io);
            defer server.docs_mutex.unlock(server.io);
            if (server.open_docs.contains(file)) continue;
        }
        try out.put(a, path, {});
    }
    server.roots_mutex.lockUncancelable(server.io);
    defer server.roots_mutex.unlock(server.io);
    for (server.roots.items) |root| {
        for ([_][]const u8{ "build.zig", "build.zig.zon", Config.project_file }) |name| {
            try out.put(a, try std.fs.path.join(a, &.{ root, name }), {});
        }
    }
    return out.keys();
}

fn stat(io: Io, path: []const u8) ?Stamp {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    if (st.kind == .directory) return null;
    return .{ .size = st.size, .mtime = st.mtime.nanoseconds };
}
