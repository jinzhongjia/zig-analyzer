//! 服务器发现磁盘上的外部改动（git checkout、代码生成、其他编辑器）：客户端不能动态注册文件监听时（Linux 上的
//! Neovim 默认如此），或配置 `files.watcher` 为 `server` 时。
//!
//! 关注的文件：驻留过的 `.zig` / `.zon` 文件（分析会按需从磁盘读取被 import 的任意文件），以及各工作区根目录的
//! `build.zig`、`build.zig.zon`、`zig-analyzer.zon`；不含不会改变的依赖库（见 `Server.watchable`）。变化按
//! `workspace/didChangeWatchedFiles` 的通知处理，与客户端的通知走同一条路径；打开的文档以缓冲区为准，编辑器中的保存由
//! `didSave` 处理，跳过。
//!
//! 监听这些文件所在的目录，使用操作系统的原生通知：Linux 用 inotify，macOS 用 FSEvents，Windows 用目录变化通知。
//! 目录尚不存在时监听最近一级存在的祖先目录，它出现后改为监听它自己，其中已经存在的关注文件按新建处理。驻留了新文件、
//! 根目录增减、目录新建或删除、通知丢失时重新计算要监听的目录。
//!
//! 轮询（定期检查大小与修改时间）只作为最后的退路：原生通知不可用（其他平台、初始化失败），或个别目录超出监听数量
//! 上限时，只对这些目录中的文件轮询。

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const za = @import("../zig_analyzer.zig");
const types = za.lsp.types;
const uri = za.base.uri;
const Vfs = za.base.Vfs;
const Server = @import("Server.zig");
const Config = @import("Config.zig");

const log = std.log.scoped(.watch);

/// 收到通知后再等这么久没有新的通知才处理：一次 git checkout 改动的大量文件合为一批
const debounce_ms = 50;
/// 持续有通知时最多推迟这么久
const max_debounce_ms = 500;
/// 轮询时两次检查之间的等待至少是一次检查耗时的这么多倍：文件很多时拉长间隔，轮询占用的时间不超过约 5%
const min_idle_factor = 20;

/// 原生通知报告的一项变化
const Event = struct {
    /// 绝对路径；`overflow` 时为空表示所有文件
    path: []const u8,
    kind: Kind,

    const Kind = enum {
        /// 文件内容可能变了
        changed,
        /// 新建或移入了这个名字（可能是目录）
        created,
        /// 删除或移出了这个名字（可能是目录）
        removed,
        /// 新建或移入了目录
        dir_created,
        /// 监听的目录自身或其中的子目录被删除、移走
        dir_gone,
        /// 通知丢失（队列溢出等）：`path` 下的文件都可能变了
        overflow,
    };
};

pub const Watcher = struct {
    server: *Server,
    gpa: Allocator,
    backend: Backend,
    listener: Vfs.Listener,
    /// 需要重新计算关注的文件与监听的目录（驻留了新文件、根目录增减）
    resync_requested: std.atomic.Value(bool) = .init(true),
    stopping: std.atomic.Value(bool) = .init(false),

    // ── 以下字段只由后台任务访问 ──
    /// 正在监听（服务器负责发现外部改动）
    active: bool = false,
    /// `files` 与 `missing` 所在的 arena；重新计算时整体替换
    state_arena: std.heap.ArenaAllocator,
    /// 关注的文件：身份键（大小写不敏感时统一为小写）→ 路径
    files: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// 关注的文件所在、还不存在的目录：身份键 → 路径（监听的是它们最近一级存在的祖先）
    missing: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// 所在目录无法监听、改为轮询的文件（路径在 `state_arena` 中）
    fallback: std.ArrayList([]const u8) = .empty,
    poller: Poller,
    /// 由客户端发现外部改动时，已按文件名补充注册的其他文件（`registerClientGlobs`）；键由 `gpa` 分配
    client_names: std.StringHashMapUnmanaged(void) = .empty,
    client_registrations: u32 = 0,
    /// 上一次轮询的耗时（见 `min_idle_factor`）
    poll_ns: i96 = 0,
    next_poll: ?Io.Timestamp = null,

    /// 在主循环中创建：之后的 `wake` / `stop` 不会丢失。原生通知不可用时退回轮询
    pub fn create(server: *Server) Allocator.Error!*Watcher {
        const gpa = server.gpa;
        const w = try gpa.create(Watcher);
        errdefer gpa.destroy(w);
        const backend: Backend = if (Native.create(gpa, server.io)) |native| .{ .native = native } else |err| blk: {
            if (Native != Unsupported) log.warn("native file watching is unavailable ({t}), checking files on disk periodically instead", .{err});
            break :blk .{ .fallback = try Fallback.create(gpa, server.io) };
        };
        w.* = .{
            .server = server,
            .gpa = gpa,
            .backend = backend,
            .listener = .{ .ctx = w, .notify = onNewPath },
            .state_arena = .init(gpa),
            .poller = .{ .gpa = gpa },
        };
        return w;
    }

    /// 后台任务结束后调用
    pub fn destroy(w: *Watcher) void {
        var names = w.client_names.keyIterator();
        while (names.next()) |k| w.gpa.free(k.*);
        w.client_names.deinit(w.gpa);
        w.backend.destroy(w.gpa);
        w.fallback.deinit(w.gpa);
        w.files.deinit(w.gpa);
        w.missing.deinit(w.gpa);
        w.state_arena.deinit();
        w.poller.deinit();
        w.gpa.destroy(w);
    }

    /// 关注的文件可能变化（根目录增减）、监听方式可能变化（配置）：在后台任务中重新计算
    pub fn requestResync(w: *Watcher) void {
        w.resync_requested.store(true, .release);
        w.backend.wake();
    }

    /// 让后台任务结束（服务器关闭）
    pub fn stop(w: *Watcher) void {
        w.stopping.store(true, .release);
        w.backend.wake();
    }

    fn onNewPath(ctx: *anyopaque) void {
        const w: *Watcher = @ptrCast(@alignCast(ctx));
        // 只在由否变是时唤醒：项目加载时会连续驻留成千上万个文件
        if (!w.resync_requested.swap(true, .acq_rel)) w.backend.wake();
    }

    /// 后台任务：服务器关闭时结束
    pub fn run(w: *Watcher) Io.Cancelable!void {
        defer w.deactivate();
        while (!w.stopping.load(.acquire)) {
            if (!w.server.watchesFiles()) {
                w.deactivate();
                // 先清除再检查：检查期间驻留的新文件会再次唤醒（见 `onNewPath`）
                w.resync_requested.store(false, .release);
                if (w.server.register_watch) w.registerClientGlobs() catch |err| switch (err) {
                    error.OutOfMemory => log.err("out of memory while registering file watchers", .{}),
                };
                w.backend.wait(null);
                var discard: std.heap.ArenaAllocator = .init(w.gpa);
                defer discard.deinit();
                var events: std.ArrayList(Event) = .empty;
                w.backend.drain(discard.allocator(), &events) catch {};
                continue;
            }
            w.step() catch |err| switch (err) {
                error.OutOfMemory => log.err("out of memory while watching files on disk", .{}),
            };
        }
    }

    /// 由客户端发现外部改动时，初始注册的 glob 只有 `.zig` 与 `.zon`：驻留过的其他文件（`@embedFile` 的文件）按
    /// 文件名补充注册（`**/<文件名>`；同名的其他文件的通知因没有驻留而被忽略）。文件名含有 glob 的特殊字符时
    /// 无法写成 glob，不注册
    fn registerClientGlobs(w: *Watcher) Allocator.Error!void {
        const server = w.server;
        var arena: std.heap.ArenaAllocator = .init(w.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const rules = try server.originRules(a);
        var out: std.Io.Writer.Allocating = .init(a);
        var added: usize = 0;
        for (0..server.vfs.count()) |i| {
            const path = server.vfs.path(@fromBackingInt(@as(u32, @intCast(i))));
            if (std.mem.endsWith(u8, path, ".zig") or std.mem.endsWith(u8, path, ".zon")) continue;
            if (!server.watchable(rules, path)) continue;
            const base = std.fs.path.basename(path);
            if (std.mem.indexOfAny(u8, base, "*?[]{}") != null or w.client_names.contains(base)) continue;
            try w.client_names.put(w.gpa, try w.gpa.dupe(u8, base), {});
            out.writer.writeAll(if (added == 0) "{\"watchers\": [" else ", ") catch return error.OutOfMemory;
            std.json.Stringify.value(.{ .globPattern = try std.fmt.allocPrint(a, "**/{s}", .{base}) }, .{}, &out.writer) catch return error.OutOfMemory;
            added += 1;
        }
        if (added == 0) return;
        out.writer.writeAll("]}") catch return error.OutOfMemory;
        const options = std.json.parseFromSliceLeaky(std.json.Value, a, out.written(), .{}) catch return error.OutOfMemory;
        w.client_registrations += 1;
        const id = try std.fmt.allocPrint(a, "zig-analyzer/didChangeWatchedFiles/{d}", .{w.client_registrations});
        server.sendRequest(.{ .string = id }, "client/registerCapability", types.RegistrationParams{ .registrations = &.{.{ .id = id, .method = "workspace/didChangeWatchedFiles", .registerOptions = options }} });
    }

    /// 一轮：（必要时）重新计算监听的目录，等待通知或轮询的时刻，处理这一批变化
    fn step(w: *Watcher) Allocator.Error!void {
        const io = w.server.io;
        var batch_arena: std.heap.ArenaAllocator = .init(w.gpa);
        defer batch_arena.deinit();
        const a = batch_arena.allocator();
        var pending: Pending = .{};

        // 先清除请求再计算：计算期间新到的请求会再次唤醒
        const requested = w.resync_requested.swap(false, .acq_rel);
        if (!w.active or requested) {
            try w.resync(a, &pending);
            w.active = true;
            if (pending.paths.count() != 0) return w.apply(a, &pending);
        }

        // 等待通知；有需要轮询的文件时最多等到下一次轮询
        const timeout_ns: ?u64 = if (w.next_poll) |at| blk: {
            const left = Io.Clock.awake.now(io).durationTo(at).nanoseconds;
            break :blk if (left <= 0) 0 else @intCast(left);
        } else null;
        w.backend.wait(timeout_ns);
        if (w.stopping.load(.acquire)) return;

        var events: std.ArrayList(Event) = .empty;
        try w.backend.drain(a, &events);
        if (events.items.len != 0) {
            // 合并一阵连续的通知
            const deadline = Io.Clock.awake.now(io).addDuration(.fromMilliseconds(max_debounce_ms));
            while (Io.Clock.awake.now(io).durationTo(deadline).nanoseconds > 0) {
                const before = events.items.len;
                w.backend.wait(debounce_ms * std.time.ns_per_ms);
                if (w.stopping.load(.acquire)) return;
                try w.backend.drain(a, &events);
                if (events.items.len == before) break;
            }
        }
        const dirs_changed = try w.handle(a, events.items, &pending);

        if (w.next_poll) |at| if (Io.Clock.awake.now(io).durationTo(at).nanoseconds <= 0) {
            const start = Io.Clock.awake.now(io);
            try w.poller.poll(io, a, w.fallback.items, &pending);
            w.poll_ns = start.durationTo(Io.Clock.awake.now(io)).nanoseconds;
            w.schedulePoll();
        };

        // 先补上新出现的目录的监听，再读取文件的状态：之后的改动都会有通知
        const requested_now = w.resync_requested.swap(false, .acq_rel);
        if (dirs_changed or requested_now) try w.resync(a, &pending);
        if (pending.paths.count() != 0) try w.apply(a, &pending);
    }

    /// 停止监听，丢弃状态：重新开始时以那时的磁盘状态为准，期间的变化不补报
    fn deactivate(w: *Watcher) void {
        if (!w.active) return;
        w.active = false;
        var none: std.ArrayList([]const u8) = .empty;
        w.backend.setDirs(w.gpa, &.{}, &none) catch {};
        none.deinit(w.gpa);
        w.files.clearRetainingCapacity();
        w.missing.clearRetainingCapacity();
        w.fallback.clearRetainingCapacity();
        _ = w.state_arena.reset(.retain_capacity);
        w.poller.reset();
        w.next_poll = null;
    }

    /// 身份键：与 Vfs 的文件身份一致，大小写不敏感时统一为小写
    fn key(w: *const Watcher, a: Allocator, path: []const u8) Allocator.Error![]const u8 {
        if (w.server.vfs.case == .sensitive) return path;
        return std.ascii.allocLowerString(a, path);
    }

    /// 重新计算关注的文件与监听的目录。此前不存在、现在出现了的目录中已经存在的关注文件记入 `pending`
    fn resync(w: *Watcher, a: Allocator, pending: *Pending) Allocator.Error!void {
        const server = w.server;
        const gpa = w.gpa;
        var next_arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer next_arena.deinit();
        const na = next_arena.allocator();

        var files: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        errdefer files.deinit(gpa);
        const rules = try server.originRules(a);
        const count = server.vfs.count();
        for (0..count) |i| {
            const path = server.vfs.path(@fromBackingInt(@as(u32, @intCast(i))));
            if (!server.watchable(rules, path)) continue;
            try files.put(gpa, try w.key(na, path), path);
        }
        {
            server.roots_mutex.lockUncancelable(server.io);
            defer server.roots_mutex.unlock(server.io);
            for (server.roots.items) |root| for ([_][]const u8{ "build.zig", "build.zig.zon", Config.project_file }) |name| {
                const path = try std.fs.path.join(na, &.{ root, name });
                try files.put(gpa, try w.key(na, path), path);
            };
        }

        // 每个文件所在的目录：存在时监听它，否则监听最近一级存在的祖先
        var dirs: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        defer dirs.deinit(gpa);
        var missing: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        errdefer missing.deinit(gpa);
        // 文件 → 监听的目录（`dirs` 的下标）
        const targets = try a.alloc(u32, files.count());
        for (files.values(), targets) |path, *target| {
            const dir = std.fs.path.dirname(path) orelse path;
            const dir_key = try w.key(na, dir);
            if (dirs.getIndex(dir_key)) |i| {
                target.* = @intCast(i);
                continue;
            }
            const watched = if (missing.get(dir_key)) |_| null else if (isDir(server.io, dir)) dir else null;
            const watch_dir = watched orelse blk: {
                try missing.put(gpa, dir_key, dir);
                break :blk ancestor(server.io, dir);
            };
            const gop = try dirs.getOrPut(gpa, try w.key(na, watch_dir));
            if (!gop.found_existing) gop.value_ptr.* = watch_dir;
            target.* = @intCast(gop.index);
        }

        var failed: std.ArrayList([]const u8) = .empty;
        defer failed.deinit(gpa);
        try w.backend.setDirs(gpa, dirs.values(), &failed);
        var failed_set: std.StringHashMapUnmanaged(void) = .empty;
        defer failed_set.deinit(gpa);
        for (failed.items) |d| try failed_set.put(gpa, try w.key(a, d), {});
        var fallback: std.ArrayList([]const u8) = .empty;
        errdefer fallback.deinit(gpa);
        if (failed_set.count() != 0) for (files.values(), targets) |path, target| {
            if (failed_set.contains(dirs.keys()[target])) try fallback.append(gpa, path);
        };

        // 此前不存在、现在出现了的目录：其中已经存在的关注文件在监听开始前就已新建
        if (w.active) {
            var appeared: std.StringHashMapUnmanaged(void) = .empty;
            defer appeared.deinit(gpa);
            for (w.missing.keys()) |k| if (!missing.contains(k)) try appeared.put(gpa, k, {});
            if (appeared.count() != 0) for (files.keys(), files.values()) |k, path| {
                const dir_key = std.fs.path.dirname(k) orelse continue;
                if (appeared.contains(dir_key)) try pending.add(a, path, .created);
            };
        }

        w.files.deinit(gpa);
        w.files = files;
        w.missing.deinit(gpa);
        w.missing = missing;
        w.fallback.deinit(gpa);
        w.fallback = fallback;
        w.state_arena.deinit();
        w.state_arena = next_arena;
        if (w.fallback.items.len == 0) {
            w.next_poll = null;
            w.poller.reset();
        } else if (w.next_poll == null) {
            w.schedulePoll();
        }
        log.debug("watching {d} directories for {d} files ({d} checked periodically)", .{ dirs.count(), w.files.count(), w.fallback.items.len });
    }

    fn schedulePoll(w: *Watcher) void {
        const interval_ns = @as(i96, w.server.poll_interval_ms.load(.monotonic)) * std.time.ns_per_ms;
        const wait_ns = @max(interval_ns, w.poll_ns * min_idle_factor);
        w.next_poll = Io.Clock.awake.now(w.server.io).addDuration(.{ .nanoseconds = wait_ns });
    }

    /// 把通知对应到关注的文件，记入 `pending`；返回目录是否有变化（需要重新计算监听的目录）
    fn handle(w: *Watcher, a: Allocator, events: []const Event, pending: *Pending) Allocator.Error!bool {
        // 目录的变化：其下关注的文件都可能变了。空路径表示所有文件
        var dirs: std.StringHashMapUnmanaged(void) = .empty;
        var all = false;
        for (events) |ev| switch (ev.kind) {
            .changed, .created, .removed => {
                const k = try w.key(a, ev.path);
                if (w.files.get(k)) |path| {
                    try pending.add(a, path, if (ev.kind == .created) .created else .changed);
                } else if (ev.kind == .created and w.leadsToMissing(k)) {
                    // 不知道是不是目录（Windows 的通知不区分）：通往不存在的目录的路径出现了
                    try dirs.put(a, k, {});
                }
            },
            .dir_created, .dir_gone, .overflow => {
                if (ev.path.len == 0) all = true else try dirs.put(a, try w.key(a, ev.path), {});
            },
        };
        if (!all and dirs.count() == 0) return false;
        for (w.files.keys(), w.files.values()) |k, path| {
            if (!all and !underAny(k, &dirs)) continue;
            try pending.add(a, path, .changed);
        }
        return true;
    }

    /// `k`（身份键）是某个不存在的目录自身或它的祖先
    fn leadsToMissing(w: *const Watcher, k: []const u8) bool {
        for (w.missing.keys()) |m| if (w.server.vfs.isUnder(m, k)) return true;
        return false;
    }

    /// 按文件此时的状态生成变化事件并交给服务器处理。打开的文档以缓冲区为准，跳过
    fn apply(w: *Watcher, a: Allocator, pending: *Pending) Allocator.Error!void {
        const server = w.server;
        var events: std.ArrayList(types.FileEvent) = .empty;
        for (pending.paths.keys(), pending.paths.values()) |path, hint| {
            if (server.isOpen(path)) continue;
            const kind: types.FileChangeType = if (stat(server.io, path) == null) .Deleted else if (hint == .created) .Created else .Changed;
            try events.append(a, .{ .uri = try uri.fromPath(a, path), .type = kind });
        }
        if (events.items.len == 0) return;
        log.debug("{d} file(s) changed on disk", .{events.items.len});
        server.applyWatchedChanges(a, events.items);
    }
};

/// 一批待处理的变化：路径 → 是否新建。路径复制到这一批的 arena 中：处理之前可能重新计算关注的文件，
/// 释放它们原来所在的 arena
const Pending = struct {
    paths: std.StringArrayHashMapUnmanaged(Hint) = .empty,

    const Hint = enum { changed, created };

    fn add(p: *Pending, a: Allocator, path: []const u8, hint: Hint) Allocator.Error!void {
        const gop = try p.paths.getOrPut(a, path);
        if (gop.found_existing) {
            if (hint == .created) gop.value_ptr.* = hint;
            return;
        }
        gop.key_ptr.* = a.dupe(u8, path) catch |err| {
            _ = p.paths.pop();
            return err;
        };
        gop.value_ptr.* = hint;
    }
};

/// `k` 是 `dirs` 中某个目录自身或在其下
fn underAny(k: []const u8, dirs: *const std.StringHashMapUnmanaged(void)) bool {
    var cur: ?[]const u8 = k;
    while (cur) |c| : (cur = std.fs.path.dirname(c)) {
        if (dirs.contains(c)) return true;
    }
    return false;
}

fn isDir(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// `dir` 最近一级存在的祖先目录（根目录总是存在）
fn ancestor(io: Io, dir: []const u8) []const u8 {
    var cur = dir;
    while (std.fs.path.dirname(cur)) |parent| : (cur = parent) {
        if (isDir(io, parent)) return parent;
    }
    return cur;
}

/// 文件在磁盘上的状态；不存在时为 null
const Stamp = struct {
    size: u64,
    mtime: i96,
};

fn stat(io: Io, path: []const u8) ?Stamp {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    if (st.kind == .directory) return null;
    return .{ .size = st.size, .mtime = st.mtime.nanoseconds };
}

/// 轮询：检查一组文件的大小与修改时间。第一次检查到一个文件时只记下它的状态，之后的变化才算
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

    /// 检查 `paths`，变化记入 `pending`；不在 `paths` 中的文件不再记录
    fn poll(p: *Poller, io: Io, a: Allocator, paths: []const []const u8, pending: *Pending) Allocator.Error!void {
        var current: std.StringArrayHashMapUnmanaged(?Stamp) = .empty;
        for (paths) |path| try current.put(a, path, stat(io, path));
        var i: usize = p.seen.count();
        while (i > 0) {
            i -= 1;
            if (current.contains(p.seen.keys()[i])) continue;
            p.gpa.free(p.seen.keys()[i]);
            p.seen.swapRemoveAt(i);
        }
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
            if (before == null and now == null) continue;
            if (before != null and now != null and std.meta.eql(before.?, now.?)) continue;
            try pending.add(a, path, if (before == null) .created else .changed);
        }
    }
};

// ── 监听方式 ──────────────────────────────────────────────────────────

const Backend = union(enum) {
    native: *Native,
    fallback: *Fallback,

    fn destroy(b: Backend, gpa: Allocator) void {
        switch (b) {
            inline else => |x| x.destroy(gpa),
        }
    }

    /// 唤醒等待中的后台任务；任何线程都可以调用
    fn wake(b: Backend) void {
        switch (b) {
            inline else => |x| x.wake(),
        }
    }

    /// 监听的目录改为 `dirs`（绝对路径）；无法监听的目录追加到 `failed`（取自 `dirs`）。只在后台任务中调用
    fn setDirs(b: Backend, gpa: Allocator, dirs: []const []const u8, failed: *std.ArrayList([]const u8)) Allocator.Error!void {
        switch (b) {
            inline else => |x| try x.setDirs(gpa, dirs, failed),
        }
    }

    /// 等到有通知、被唤醒或超时（null 为不超时）
    fn wait(b: Backend, timeout_ns: ?u64) void {
        switch (b) {
            inline else => |x| x.wait(timeout_ns),
        }
    }

    /// 取出已经到达的通知（不等待），路径分配在 `a` 中
    fn drain(b: Backend, a: Allocator, out: *std.ArrayList(Event)) Allocator.Error!void {
        switch (b) {
            inline else => |x| try x.drain(a, out),
        }
    }
};

const Native = switch (builtin.os.tag) {
    .linux => Inotify,
    .macos => FsEvents,
    .windows => DirNotify,
    else => Unsupported,
};

const Unsupported = struct {
    fn create(_: Allocator, _: Io) error{Unsupported}!*Unsupported {
        return error.Unsupported;
    }
    fn destroy(_: *Unsupported, _: Allocator) void {
        unreachable;
    }
    fn wake(_: *Unsupported) void {
        unreachable;
    }
    fn setDirs(_: *Unsupported, _: Allocator, _: []const []const u8, _: *std.ArrayList([]const u8)) Allocator.Error!void {
        unreachable;
    }
    fn wait(_: *Unsupported, _: ?u64) void {
        unreachable;
    }
    fn drain(_: *Unsupported, _: Allocator, _: *std.ArrayList(Event)) Allocator.Error!void {
        unreachable;
    }
};

/// 没有原生通知：所有目录都无法监听（文件全部轮询），只提供唤醒
const Fallback = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    signaled: bool = false,

    fn create(gpa: Allocator, io: Io) Allocator.Error!*Fallback {
        const f = try gpa.create(Fallback);
        f.* = .{ .io = io };
        return f;
    }

    fn destroy(f: *Fallback, gpa: Allocator) void {
        gpa.destroy(f);
    }

    fn wake(f: *Fallback) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.signaled = true;
        f.cond.signal(f.io);
    }

    fn setDirs(_: *Fallback, gpa: Allocator, dirs: []const []const u8, failed: *std.ArrayList([]const u8)) Allocator.Error!void {
        try failed.appendSlice(gpa, dirs);
    }

    fn wait(f: *Fallback, timeout_ns: ?u64) void {
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        const deadline: ?Io.Timestamp = if (timeout_ns) |ns| Io.Clock.awake.now(f.io).addDuration(.{ .nanoseconds = ns }) else null;
        while (!f.signaled) {
            if (deadline) |d| {
                f.cond.waitTimeout(f.io, &f.mutex, .{ .deadline = .{ .raw = d, .clock = .awake } }) catch break;
            } else f.cond.waitUncancelable(f.io, &f.mutex);
        }
        f.signaled = false;
    }

    fn drain(_: *Fallback, _: Allocator, _: *std.ArrayList(Event)) Allocator.Error!void {}
};

/// Linux：inotify 监听各个目录（不递归），eventfd 用于唤醒
const Inotify = struct {
    const linux = std.os.linux;
    const IN = linux.IN;

    gpa: Allocator,
    fd: linux.fd_t,
    wake_fd: linux.fd_t,
    /// 监听描述符 → 目录路径（属于 `gpa`，与 `by_path` 的键共用）
    by_wd: std.AutoArrayHashMapUnmanaged(i32, [:0]u8) = .empty,
    by_path: std.StringArrayHashMapUnmanaged(i32) = .empty,
    /// 已经提示过达到了监听数量上限
    warned: bool = false,
    buf: [64 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined,

    const mask = IN.CLOSE_WRITE | IN.CREATE | IN.DELETE | IN.MOVED_FROM | IN.MOVED_TO |
        IN.DELETE_SELF | IN.MOVE_SELF | IN.ONLYDIR | IN.EXCL_UNLINK;

    fn create(gpa: Allocator, _: Io) error{ OutOfMemory, InotifyUnavailable }!*Inotify {
        const fd_rc = linux.inotify_init1(IN.CLOEXEC | IN.NONBLOCK);
        if (linux.errno(fd_rc) != .SUCCESS) return error.InotifyUnavailable;
        const fd: linux.fd_t = @intCast(fd_rc);
        errdefer _ = linux.close(fd);
        const wake_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(wake_rc) != .SUCCESS) return error.InotifyUnavailable;
        const wake_fd: linux.fd_t = @intCast(wake_rc);
        errdefer _ = linux.close(wake_fd);
        const n = try gpa.create(Inotify);
        n.* = .{ .gpa = gpa, .fd = fd, .wake_fd = wake_fd };
        return n;
    }

    fn destroy(n: *Inotify, gpa: Allocator) void {
        _ = linux.close(n.fd);
        _ = linux.close(n.wake_fd);
        for (n.by_wd.values()) |p| gpa.free(p);
        n.by_wd.deinit(gpa);
        n.by_path.deinit(gpa);
        gpa.destroy(n);
    }

    fn wake(n: *Inotify) void {
        const one: u64 = 1;
        _ = linux.write(n.wake_fd, @ptrCast(&one), @sizeOf(u64));
    }

    fn setDirs(n: *Inotify, gpa: Allocator, dirs: []const []const u8, failed: *std.ArrayList([]const u8)) Allocator.Error!void {
        var want: std.StringHashMapUnmanaged(void) = .empty;
        defer want.deinit(gpa);
        for (dirs) |d| try want.put(gpa, d, {});
        var i = n.by_path.count();
        while (i > 0) {
            i -= 1;
            if (want.contains(n.by_path.keys()[i])) continue;
            const wd = n.by_path.values()[i];
            _ = linux.inotify_rm_watch(n.fd, wd);
            n.forget(wd);
        }
        for (dirs) |d| {
            if (n.by_path.contains(d)) continue;
            const z = try gpa.dupeSentinel(u8, d, 0);
            const rc = linux.inotify_add_watch(n.fd, z, mask);
            const err = linux.errno(rc);
            // 同一个目录的另一种写法（经由符号链接）：一个监听只能对应一个路径
            const duplicate = err == .SUCCESS and n.by_wd.contains(@intCast(rc));
            if (err != .SUCCESS or duplicate) {
                gpa.free(z);
                if ((err == .NOSPC or err == .NOMEM) and !n.warned) {
                    n.warned = true;
                    log.warn("inotify watch limit reached (fs.inotify.max_user_watches), some directories are checked periodically instead", .{});
                }
                try failed.append(gpa, d);
                continue;
            }
            const wd: i32 = @intCast(rc);
            try n.by_wd.put(gpa, wd, z);
            try n.by_path.put(gpa, z, wd);
        }
    }

    /// 不再记录监听 `wd`（已被移除）
    fn forget(n: *Inotify, wd: i32) void {
        const kv = n.by_wd.fetchSwapRemove(wd) orelse return;
        _ = n.by_path.swapRemove(kv.value);
        n.gpa.free(kv.value);
    }

    fn wait(n: *Inotify, timeout_ns: ?u64) void {
        var fds = [_]std.posix.pollfd{
            .{ .fd = n.fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = n.wake_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ms: i32 = if (timeout_ns) |ns| @intCast(@min(ns / std.time.ns_per_ms, std.math.maxInt(i32))) else -1;
        _ = std.posix.poll(&fds, ms) catch {};
    }

    fn drain(n: *Inotify, a: Allocator, out: *std.ArrayList(Event)) Allocator.Error!void {
        var counter: u64 = undefined;
        _ = linux.read(n.wake_fd, @ptrCast(&counter), @sizeOf(u64));
        while (true) {
            const rc = linux.read(n.fd, &n.buf, n.buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return,
            }
            var offset: usize = 0;
            while (offset + @sizeOf(linux.inotify_event) <= rc) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&n.buf[offset]));
                offset += @sizeOf(linux.inotify_event) + ev.len;
                try n.event(a, ev, out);
            }
        }
    }

    fn event(n: *Inotify, a: Allocator, ev: *const linux.inotify_event, out: *std.ArrayList(Event)) Allocator.Error!void {
        if (ev.mask & IN.Q_OVERFLOW != 0) return out.append(a, .{ .path = "", .kind = .overflow });
        const dir = n.by_wd.get(ev.wd) orelse return;
        if (ev.getName()) |name| {
            const is_dir = ev.mask & IN.ISDIR != 0;
            const kind: Event.Kind = if (ev.mask & (IN.CREATE | IN.MOVED_TO) != 0)
                (if (is_dir) .dir_created else .created)
            else if (ev.mask & (IN.DELETE | IN.MOVED_FROM) != 0)
                (if (is_dir) .dir_gone else .removed)
            else
                .changed;
            return out.append(a, .{ .path = try std.fs.path.join(a, &.{ dir, name }), .kind = kind });
        }
        // 监听的目录自身被删除、移走（之后的通知随 inode 而来，路径已不对）或所在的文件系统被卸载
        if (ev.mask & (IN.DELETE_SELF | IN.MOVE_SELF | IN.IGNORED | IN.UNMOUNT) == 0) return;
        try out.append(a, .{ .path = try a.dupe(u8, dir), .kind = .dir_gone });
        if (ev.mask & IN.IGNORED == 0) _ = linux.inotify_rm_watch(n.fd, ev.wd);
        n.forget(ev.wd);
    }
};

/// macOS：FSEvents（递归监听，由系统服务管理）。动态加载 CoreServices，不依赖 SDK；回调在自建的串行队列上执行，
/// 收到的变化在这个队列上暂存，后台任务经 `dispatch_sync` 取走
const FsEvents = struct {
    const dispatch = std.c.dispatch;

    gpa: Allocator,
    io: Io,
    lib: std.DynLib,
    sym: Symbols,
    queue: dispatch.queue_t,
    sem: dispatch.semaphore_t,
    stream: ?FSEventStreamRef = null,
    cf_paths: []?CFStringRef = &.{},
    cf_array: ?CFArrayRef = null,
    /// 当前的监听根（属于 `gpa`）
    roots: std.ArrayList([:0]u8) = .empty,
    /// 监听根的真实路径与写法不同时：FSEvents 报告真实路径，换回写法
    aliases: std.ArrayList(Alias) = .empty,
    /// 回调收到、尚未取走的变化（只在 `queue` 上访问；路径属于 `gpa`）
    queued: std.ArrayList(Event) = .empty,

    const Alias = struct { real: []u8, written: []const u8 };

    /// FSEvents 对监听路径的个数有未公开的上限（据称 4096）
    const max_roots = 2048;

    const Symbols = struct {
        FSEventStreamCreate: *const fn (
            allocator: ?*const anyopaque,
            callback: *const fn (ConstFSEventStreamRef, ?*anyopaque, usize, *anyopaque, [*]const EventFlags, [*]const u64) callconv(.c) void,
            ctx: ?*const StreamContext,
            paths_to_watch: CFArrayRef,
            since_when: u64,
            latency: f64,
            flags: CreateFlags,
        ) callconv(.c) ?FSEventStreamRef,
        FSEventStreamSetDispatchQueue: *const fn (stream: FSEventStreamRef, queue: dispatch.queue_t) callconv(.c) void,
        FSEventStreamStart: *const fn (stream: FSEventStreamRef) callconv(.c) bool,
        FSEventStreamStop: *const fn (stream: FSEventStreamRef) callconv(.c) void,
        FSEventStreamInvalidate: *const fn (stream: FSEventStreamRef) callconv(.c) void,
        FSEventStreamRelease: *const fn (stream: FSEventStreamRef) callconv(.c) void,
        CFRelease: *const fn (cf: *const anyopaque) callconv(.c) void,
        CFArrayCreate: *const fn (allocator: ?*const anyopaque, values: [*]const ?CFStringRef, num_values: isize, call_backs: ?*const anyopaque) callconv(.c) ?CFArrayRef,
        CFStringCreateWithCString: *const fn (allocator: ?*const anyopaque, c_str: [*:0]const u8, encoding: u32) callconv(.c) ?CFStringRef,
    };

    const CFStringRef = *const opaque {};
    const CFArrayRef = *const opaque {};
    const FSEventStreamRef = *opaque {};
    const ConstFSEventStreamRef = *const opaque {};
    const cf_string_encoding_utf8 = 0x08000100;
    const since_now = std.math.maxInt(u64);

    const StreamContext = extern struct {
        version: isize = 0,
        info: ?*anyopaque,
        retain: ?*const anyopaque = null,
        release: ?*const anyopaque = null,
        copy_description: ?*const anyopaque = null,
    };

    const CreateFlags = packed struct(u32) {
        use_cf_types: bool = false,
        no_defer: bool = false,
        watch_root: bool = false,
        ignore_self: bool = false,
        file_events: bool = false,
        _: u27 = 0,
    };

    const EventFlags = packed struct(u32) {
        must_scan_sub_dirs: bool,
        user_dropped: bool,
        kernel_dropped: bool,
        event_ids_wrapped: bool,
        history_done: bool,
        root_changed: bool,
        mount: bool,
        unmount: bool,
        item_created: bool,
        item_removed: bool,
        item_inode_meta_mod: bool,
        item_renamed: bool,
        item_modified: bool,
        item_finder_info_mod: bool,
        item_change_owner: bool,
        item_xattr_mod: bool,
        item_is_file: bool,
        item_is_dir: bool,
        item_is_symlink: bool,
        _: u13,
    };

    fn create(gpa: Allocator, io: Io) error{ OutOfMemory, OpenFrameworkFailed, MissingSymbol, SystemResources }!*FsEvents {
        var lib = std.DynLib.open("/System/Library/Frameworks/CoreServices.framework/CoreServices") catch return error.OpenFrameworkFailed;
        errdefer lib.close();
        var sym: Symbols = undefined;
        inline for (@typeInfo(Symbols).@"struct".field_names, @typeInfo(Symbols).@"struct".field_types) |name, T| {
            @field(sym, name) = lib.lookup(T, name) orelse return error.MissingSymbol;
        }
        const sem = dispatch.semaphore_create(0) orelse return error.SystemResources;
        errdefer sem.as_object().release();
        const queue = dispatch.queue_create("zig-analyzer-watch", .SERIAL()) orelse return error.SystemResources;
        errdefer queue.as_object().release();
        const f = try gpa.create(FsEvents);
        f.* = .{ .gpa = gpa, .io = io, .lib = lib, .sym = sym, .queue = queue, .sem = sem };
        return f;
    }

    fn destroy(f: *FsEvents, gpa: Allocator) void {
        f.stopStream();
        f.clearRoots();
        f.roots.deinit(gpa);
        f.aliases.deinit(gpa);
        for (f.queued.items) |e| gpa.free(e.path);
        f.queued.deinit(gpa);
        f.queue.as_object().release();
        f.sem.as_object().release();
        f.lib.close();
        gpa.destroy(f);
    }

    fn wake(f: *FsEvents) void {
        _ = f.sem.signal();
    }

    fn wait(f: *FsEvents, timeout_ns: ?u64) void {
        const when: dispatch.time_t = if (timeout_ns) |ns| .time(.NOW, @intCast(@min(ns, std.math.maxInt(i64)))) else .FOREVER;
        _ = f.sem.wait(when);
    }

    fn setDirs(f: *FsEvents, gpa: Allocator, dirs: []const []const u8, failed: *std.ArrayList([]const u8)) Allocator.Error!void {
        // 嵌套的目录只保留最外层：监听是递归的
        const sorted = try gpa.dupe([]const u8, dirs);
        defer gpa.free(sorted);
        std.mem.sort([]const u8, sorted, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        var roots: std.ArrayList([]const u8) = .empty;
        defer roots.deinit(gpa);
        for (sorted) |d| {
            if (roots.items.len != 0 and under(d, roots.items[roots.items.len - 1])) continue;
            try roots.append(gpa, d);
        }
        // 目录太多时监听整个文件系统：代价大，但仍是原生通知
        if (roots.items.len > max_roots) {
            roots.clearRetainingCapacity();
            try roots.append(gpa, "/");
        }
        if (roots.items.len == f.roots.items.len) {
            for (roots.items, f.roots.items) |x, y| {
                if (!std.mem.eql(u8, x, y)) break;
            } else return;
        }

        f.stopStream();
        f.clearRoots();
        for (roots.items) |r| try f.roots.append(gpa, try gpa.dupeSentinel(u8, r, 0));
        for (f.roots.items) |r| {
            const real = Io.Dir.cwd().realPathFileAlloc(f.io, r, gpa) catch continue;
            if (std.mem.eql(u8, real, r)) {
                gpa.free(real);
                continue;
            }
            f.aliases.append(gpa, .{ .real = real, .written = r }) catch |err| {
                gpa.free(real);
                return err;
            };
        }
        if (f.roots.items.len == 0) return;
        f.startStream() catch {
            log.warn("cannot start FSEvents stream, checking files on disk periodically instead", .{});
            try failed.appendSlice(gpa, dirs);
        };
    }

    fn under(path: []const u8, dir: []const u8) bool {
        if (!std.mem.startsWith(u8, path, dir)) return false;
        return path.len == dir.len or path[dir.len] == '/' or std.mem.eql(u8, dir, "/");
    }

    fn startStream(f: *FsEvents) error{ OutOfMemory, StartFailed }!void {
        const s = f.sym;
        f.cf_paths = try f.gpa.alloc(?CFStringRef, f.roots.items.len);
        @memset(f.cf_paths, null);
        for (f.roots.items, f.cf_paths) |r, *p| p.* = s.CFStringCreateWithCString(null, r.ptr, cf_string_encoding_utf8) orelse return error.OutOfMemory;
        f.cf_array = s.CFArrayCreate(null, f.cf_paths.ptr, @intCast(f.cf_paths.len), null) orelse return error.OutOfMemory;
        const ctx: StreamContext = .{ .info = f };
        const stream = s.FSEventStreamCreate(null, callback, &ctx, f.cf_array.?, since_now, @as(f64, debounce_ms) / 1000.0, .{
            .watch_root = true,
            .file_events = true,
        }) orelse return error.StartFailed;
        s.FSEventStreamSetDispatchQueue(stream, f.queue);
        if (!s.FSEventStreamStart(stream)) {
            s.FSEventStreamInvalidate(stream);
            s.FSEventStreamRelease(stream);
            return error.StartFailed;
        }
        f.stream = stream;
    }

    fn stopStream(f: *FsEvents) void {
        const s = f.sym;
        if (f.stream) |stream| {
            s.FSEventStreamStop(stream);
            s.FSEventStreamInvalidate(stream);
            s.FSEventStreamRelease(stream);
            f.stream = null;
        }
        if (f.cf_array) |arr| s.CFRelease(arr);
        f.cf_array = null;
        for (f.cf_paths) |p| if (p) |x| s.CFRelease(x);
        f.gpa.free(f.cf_paths);
        f.cf_paths = &.{};
    }

    fn clearRoots(f: *FsEvents) void {
        for (f.aliases.items) |al| f.gpa.free(al.real);
        f.aliases.clearRetainingCapacity();
        for (f.roots.items) |r| f.gpa.free(r);
        f.roots.clearRetainingCapacity();
    }

    fn callback(
        _: ConstFSEventStreamRef,
        info: ?*anyopaque,
        count: usize,
        paths_ptr: *anyopaque,
        flags_ptr: [*]const EventFlags,
        _: [*]const u64,
    ) callconv(.c) void {
        const f: *FsEvents = @ptrCast(@alignCast(info));
        const paths: [*]const [*:0]const u8 = @ptrCast(@alignCast(paths_ptr));
        for (paths[0..count], flags_ptr[0..count]) |p, fl| {
            if (fl.history_done) continue;
            const kind: Event.Kind = if (fl.must_scan_sub_dirs or fl.user_dropped or fl.kernel_dropped)
                .overflow
            else if (fl.root_changed)
                .dir_gone
            else if (fl.item_is_dir)
                (if (fl.item_removed) .dir_gone else if (fl.item_created or fl.item_renamed) .dir_created else continue)
            else if (fl.item_created and !fl.item_removed)
                .created
            else
                .changed;
            const path = f.gpa.dupe(u8, std.mem.span(p)) catch continue;
            f.queued.append(f.gpa, .{ .path = path, .kind = kind }) catch f.gpa.free(path);
        }
        _ = f.sem.signal();
    }

    fn drain(f: *FsEvents, a: Allocator, out: *std.ArrayList(Event)) Allocator.Error!void {
        const Take = struct {
            f: *FsEvents,
            taken: std.ArrayList(Event) = .empty,
            fn run(ctx: ?*anyopaque) callconv(.c) void {
                const t: *@This() = @ptrCast(@alignCast(ctx));
                t.taken = t.f.queued;
                t.f.queued = .empty;
            }
        };
        var take: Take = .{ .f = f };
        dispatch.sync_f(f.queue, &take, Take.run);
        defer {
            for (take.taken.items) |e| f.gpa.free(e.path);
            take.taken.deinit(f.gpa);
        }
        for (take.taken.items) |e| try out.append(a, .{ .path = try f.written(a, e.path), .kind = e.kind });
    }

    /// 真实路径换回监听根的写法
    fn written(f: *const FsEvents, a: Allocator, path: []const u8) Allocator.Error![]const u8 {
        for (f.aliases.items) |al| if (under(path, al.real)) {
            return std.mem.concat(a, u8, &.{ al.written, path[al.real.len..] });
        };
        return a.dupe(u8, path);
    }
};

/// Windows：各个目录的变化通知（不递归）。通知完成时以 APC 回调到发起它的线程（后台任务），在可警报的等待中执行；
/// 唤醒用一个事件对象
const DirNotify = struct {
    const windows = std.os.windows;

    gpa: Allocator,
    wake_event: windows.HANDLE,
    dirs: std.StringArrayHashMapUnmanaged(*Directory) = .empty,
    /// 通知已完成、等待处理的目录（APC 中加入）
    ready: std.DoublyLinkedList = .{},

    const Directory = struct {
        path: []u8,
        handle: windows.HANDLE,
        state: enum { idle, listening, ready } = .idle,
        iosb: windows.IO_STATUS_BLOCK = undefined,
        /// 网络上的目录一次通知至多 64 KB
        buffer: [64 * 1024]u8 align(@alignOf(windows.FILE.NOTIFY.INFORMATION)) = undefined,
        ready_node: std.DoublyLinkedList.Node = .{},
    };

    fn create(gpa: Allocator, _: Io) error{ OutOfMemory, SystemResources }!*DirNotify {
        var event: windows.HANDLE = undefined;
        switch (windows.ntdll.NtCreateEvent(&event, windows.ACCESS_MASK.Specific.Event.ALL_ACCESS, null, .Synchronization, .FALSE)) {
            .SUCCESS => {},
            else => return error.SystemResources,
        }
        errdefer windows.CloseHandle(event);
        const d = try gpa.create(DirNotify);
        d.* = .{ .gpa = gpa, .wake_event = event };
        return d;
    }

    fn destroy(d: *DirNotify, gpa: Allocator) void {
        for (d.dirs.values()) |dir| d.close(dir);
        d.dirs.deinit(gpa);
        windows.CloseHandle(d.wake_event);
        gpa.destroy(d);
    }

    fn wake(d: *DirNotify) void {
        _ = windows.ntdll.NtSetEvent(d.wake_event, null);
    }

    fn wait(d: *DirNotify, timeout_ns: ?u64) void {
        if (timeout_ns) |ns| {
            const interval: windows.LARGE_INTEGER = -@as(windows.LARGE_INTEGER, @intCast(@min(ns / 100, std.math.maxInt(i63))));
            _ = windows.ntdll.NtWaitForSingleObject(d.wake_event, .TRUE, &interval);
        } else {
            _ = windows.ntdll.NtWaitForSingleObject(d.wake_event, .TRUE, null);
        }
    }

    fn setDirs(d: *DirNotify, gpa: Allocator, dirs: []const []const u8, failed: *std.ArrayList([]const u8)) Allocator.Error!void {
        var want: std.StringHashMapUnmanaged(void) = .empty;
        defer want.deinit(gpa);
        for (dirs) |p| try want.put(gpa, p, {});
        var i = d.dirs.count();
        while (i > 0) {
            i -= 1;
            if (want.contains(d.dirs.keys()[i])) continue;
            const dir = d.dirs.values()[i];
            d.dirs.swapRemoveAt(i);
            d.close(dir);
        }
        for (dirs) |p| {
            if (d.dirs.contains(p)) continue;
            const dir = d.open(p) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try failed.append(gpa, p);
                    continue;
                },
            };
            d.dirs.put(gpa, dir.path, dir) catch |err| {
                d.close(dir);
                return err;
            };
        }
    }

    fn open(d: *DirNotify, path: []const u8) !*Directory {
        const path_w = try std.Io.Threaded.sliceToPrefixedFileW(null, path, .{});
        var handle: windows.HANDLE = undefined;
        var iosb: windows.IO_STATUS_BLOCK = undefined;
        switch (windows.ntdll.NtCreateFile(
            &handle,
            .{
                .SPECIFIC = .{ .FILE_DIRECTORY = .{ .LIST = true } },
                .STANDARD = .{ .SYNCHRONIZE = true },
                .GENERIC = .{ .READ = true },
            },
            &.{ .RootDirectory = null, .ObjectName = @constCast(&path_w.string()) },
            &iosb,
            null,
            .{},
            .VALID_FLAGS,
            .OPEN,
            .{ .DIRECTORY_FILE = true, .IO = .ASYNCHRONOUS, .OPEN_FOR_BACKUP_INTENT = true },
            null,
            0,
        )) {
            .SUCCESS => {},
            else => return error.CannotOpenDirectory,
        }
        errdefer windows.CloseHandle(handle);
        const dir = try d.gpa.create(Directory);
        errdefer d.gpa.destroy(dir);
        dir.* = .{ .path = try d.gpa.dupe(u8, path), .handle = handle };
        errdefer d.gpa.free(dir.path);
        try d.listen(dir);
        return dir;
    }

    fn listen(d: *DirNotify, dir: *Directory) !void {
        switch (windows.ntdll.NtNotifyChangeDirectoryFileEx(
            dir.handle,
            null,
            &notifyApc,
            d,
            &dir.iosb,
            &dir.buffer,
            dir.buffer.len,
            .{ .FILE_NAME = true, .DIR_NAME = true, .SIZE = true, .LAST_WRITE = true, .CREATION = true },
            .FALSE,
            .Notify,
        )) {
            .SUCCESS, .PENDING => dir.state = .listening,
            else => return error.CannotWatchDirectory,
        }
    }

    fn notifyApc(context: ?*anyopaque, iosb: *windows.IO_STATUS_BLOCK, _: windows.ULONG) align(std.Io.Threaded.apc_align) callconv(.winapi) void {
        const d: *DirNotify = @ptrCast(@alignCast(context));
        const dir: *Directory = @fieldParentPtr("iosb", iosb);
        d.ready.append(&dir.ready_node);
        dir.state = .ready;
    }

    /// 取消进行中的通知，等它的 APC 执行完后关闭
    fn close(d: *DirNotify, dir: *Directory) void {
        if (dir.state == .listening) {
            var cancel_iosb: windows.IO_STATUS_BLOCK = undefined;
            _ = windows.ntdll.NtCancelIoFileEx(dir.handle, &dir.iosb, &cancel_iosb);
            while (dir.state == .listening) std.Io.Threaded.waitForApcOrAlert();
        }
        if (dir.state == .ready) d.ready.remove(&dir.ready_node);
        windows.CloseHandle(dir.handle);
        d.gpa.free(dir.path);
        d.gpa.destroy(dir);
    }

    fn drain(d: *DirNotify, a: Allocator, out: *std.ArrayList(Event)) Allocator.Error!void {
        var gone: std.ArrayList(*Directory) = .empty;
        while (d.ready.popFirst()) |node| {
            const dir: *Directory = @fieldParentPtr("ready_node", node);
            dir.state = .idle;
            switch (dir.iosb.u.Status) {
                .SUCCESS => {
                    if (dir.iosb.Information == 0) {
                        try out.append(a, .{ .path = try a.dupe(u8, dir.path), .kind = .overflow });
                    } else try parse(a, dir, out);
                },
                // 变化太多，缓冲区装不下
                .NOTIFY_ENUM_DIR => try out.append(a, .{ .path = try a.dupe(u8, dir.path), .kind = .overflow }),
                .CANCELLED => continue,
                // 目录被删除等：不再监听，重新计算时按那时的情况处理
                else => {
                    try out.append(a, .{ .path = try a.dupe(u8, dir.path), .kind = .dir_gone });
                    try gone.append(a, dir);
                    continue;
                },
            }
            d.listen(dir) catch {
                try out.append(a, .{ .path = try a.dupe(u8, dir.path), .kind = .dir_gone });
                try gone.append(a, dir);
            };
        }
        for (gone.items) |dir| {
            _ = d.dirs.swapRemove(dir.path);
            d.close(dir);
        }
    }

    fn parse(a: Allocator, dir: *Directory, out: *std.ArrayList(Event)) Allocator.Error!void {
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        var offset: usize = 0;
        while (true) {
            const info: *windows.FILE.NOTIFY.INFORMATION = @ptrCast(@alignCast(&dir.buffer[offset]));
            const name = name_buf[0..std.unicode.wtf16LeToWtf8(&name_buf, info.fileName())];
            const kind: Event.Kind = switch (info.Action) {
                1, 5 => .created, // 新建、改名后的新名字
                2, 4 => .removed, // 删除、改名前的旧名字
                else => .changed,
            };
            try out.append(a, .{ .path = try std.fs.path.join(a, &.{ dir.path, name }), .kind = kind });
            if (info.NextEntryOffset == 0) break;
            offset += info.NextEntryOffset;
        }
    }
};

const testing = std.testing;

test "poller: changes, creation and deletion after the first check" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const a_path = try std.fs.path.join(testing.allocator, &.{ dir, "a.zig" });
    defer testing.allocator.free(a_path);
    const b_path = try std.fs.path.join(testing.allocator, &.{ dir, "b.zig" });
    defer testing.allocator.free(b_path);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "a" });

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var poller: Poller = .{ .gpa = testing.allocator };
    defer poller.deinit();
    var pending: Pending = .{};
    const paths = [_][]const u8{ a_path, b_path };
    try poller.poll(testing.io, arena.allocator(), &paths, &pending);
    try testing.expectEqual(0, pending.paths.count());

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "aa" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.zig", .data = "b" });
    try poller.poll(testing.io, arena.allocator(), &paths, &pending);
    try testing.expectEqual(Pending.Hint.changed, pending.paths.get(a_path).?);
    try testing.expectEqual(Pending.Hint.created, pending.paths.get(b_path).?);
}

// 防止待处理的变化借用关注文件的路径：同一批中重新计算关注的文件时，它们所在的 arena 被释放
test "pending changes keep their own copies of the paths" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var source = "/p/build.zig".*;
    var pending: Pending = .{};
    try pending.add(arena.allocator(), &source, .changed);
    try pending.add(arena.allocator(), &source, .created);
    @memset(&source, 'x');
    try testing.expectEqualStrings("/p/build.zig", pending.paths.keys()[0]);
    try testing.expectEqual(Pending.Hint.created, pending.paths.values()[0]);
}

test "under any: a path is under one of the directories, or is one of them" {
    const native = @import("../util/test_path.zig").native;
    var dirs: std.StringHashMapUnmanaged(void) = .empty;
    defer dirs.deinit(testing.allocator);
    try dirs.put(testing.allocator, native("/p/src"), {});
    try testing.expect(underAny(native("/p/src/a.zig"), &dirs));
    try testing.expect(underAny(native("/p/src/sub/b.zig"), &dirs));
    try testing.expect(underAny(native("/p/src"), &dirs));
    try testing.expect(!underAny(native("/p/srcx/a.zig"), &dirs));
    try testing.expect(!underAny(native("/p/a.zig"), &dirs));
}

/// 等到 `paths` 中的每个路径都被报告过（10 秒内）
fn expectReported(n: *Native, a: Allocator, paths: []const []const u8) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var events: std.ArrayList(Event) = .empty;
    const deadline = Io.Clock.awake.now(testing.io).addDuration(.fromSeconds(10));
    while (seen.count() < paths.len) {
        if (Io.Clock.awake.now(testing.io).durationTo(deadline).nanoseconds <= 0) return error.Timeout;
        n.wait(std.time.ns_per_s);
        events.clearRetainingCapacity();
        try n.drain(a, &events);
        for (events.items) |e| for (paths) |p| {
            if (std.mem.eql(u8, e.path, p)) try seen.put(a, p, {});
        };
    }
}

test "native watching reports changes, creation and removal in watched directories" {
    if (Native == Unsupported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "a" });

    const n = try Native.create(testing.allocator, testing.io);
    defer n.destroy(testing.allocator);
    var failed: std.ArrayList([]const u8) = .empty;
    defer failed.deinit(testing.allocator);
    try n.setDirs(testing.allocator, &.{dir}, &failed);
    try testing.expectEqual(0, failed.items.len);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const a_path = try std.fs.path.join(a, &.{ dir, "a.zig" });
    const b_path = try std.fs.path.join(a, &.{ dir, "b.zig" });

    // 改写 a.zig、新建 b.zig：两者都报告（FSEvents 会合并同一文件的多项变化，种类只作提示，由处理时的状态决定）
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "aa" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.zig", .data = "b" });
    try expectReported(n, a, &.{ a_path, b_path });
    // 删除 a.zig
    try tmp.dir.deleteFile(testing.io, "a.zig");
    try expectReported(n, a, &.{a_path});

    // 唤醒：不带通知也返回
    n.wake();
    n.wait(null);
    var events: std.ArrayList(Event) = .empty;
    try n.drain(a, &events);
}
